/*
 * exec_listener.c — in-VM vsock listener for `cocker exec`.
 *
 * cockerd opens a vsock connection to port 9000 inside the container, writes
 * a JSON request, and reads back the child's combined stdout/stderr line by
 * line until EOF. Protocol :
 *
 *   Request  : single line of JSON, NL-terminated :
 *              {"cmd": ["sh","-c","echo hi"], "env": {"FOO":"bar"}}
 *
 *   Response : raw child output (stdout + stderr merged). When the child
 *              exits, the listener emits one final line
 *                  __COCKER_EXIT__<code>\n
 *              and closes the socket. The Swift client treats the magic line
 *              as end-of-stream.
 *
 * The listener runs as a forked subprocess of init so failures don't take
 * down PID 1. The kernel needs CONFIG_VHOST_VSOCK / virtio-vsock enabled.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <linux/vm_sockets.h>

#include "cocker_init.h"

#define EXEC_VSOCK_PORT 9000
#define EXEC_BUF_SIZE   (256 * 1024)
#define MAX_ARGV        128
#define MAX_ENV         128
/* **B17 mitigation** : cap concurrent exec workers so a flood of
 * `cocker exec` calls can't fork-bomb the VM (typical container has 512 MB
 * of RAM and each worker eats 1 to 2 MB of resident set ; ~256 concurrent
 * workers would OOM-kill the listener itself, which then takes the whole
 * vsock channel down). The reaper installed in exec_listener_spawn keeps
 * `worker_count` accurate as children exit. */
#define MAX_CONCURRENT_WORKERS 32

static volatile sig_atomic_t worker_count = 0;

/* Return a pointer to the VALUE of the top-level object key `key` (e.g.
 * "tty"), or NULL if that key is absent. Walks the outermost JSON object at
 * brace-depth 1 only, honoring string escapes and nested object/array spans,
 * so nothing inside a value is ever mistaken for a top-level key. This kills
 * two whole classes of bug at once :
 *   1. JSON key ordering — JSONEncoder guarantees none, so the old parser
 *      (which searched `tty`/`env` relative to `cmd`) silently dropped the
 *      PTY or the env whenever the order flipped. A structural top-level walk
 *      is order-independent.
 *   2. Same-named nested keys / values — an argument like `exec c tty`, OR an
 *      environment variable literally named `tty` (`{"env":{"tty":"x"},...}`),
 *      would otherwise be read as the top-level `tty` field. Because we only
 *      match keys at depth 1 and skip each value wholesale, nested `"tty"` /
 *      `"env"` text can never be picked up.
 * Runs on the pristine buffer, before the argv loop plants NUL terminators. */
static char *top_level_value(char *buf, const char *key) {
    char *p = strchr(buf, '{');
    if (!p) return NULL;
    p++;  /* now inside the top object, depth 1 */
    size_t keylen = strlen(key);
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',') p++;
        if (*p == '}' || *p == '\0') return NULL;   /* end of top object */
        if (*p != '"') return NULL;                 /* malformed */
        char *k = p + 1;
        char *ke = k;
        while (*ke && *ke != '"') { if (*ke == '\\' && ke[1]) ke += 2; else ke++; }
        if (*ke != '"') return NULL;
        size_t klen = (size_t)(ke - k);
        p = ke + 1;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p != ':') return NULL;
        p++;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        char *value = p;
        if (klen == keylen && strncmp(k, key, keylen) == 0) return value;
        /* Not our key — skip its value wholesale so nested braces/brackets,
         * strings and escapes never leak into the depth-1 scan. */
        if (*p == '"') {
            p++;
            while (*p && *p != '"') { if (*p == '\\' && p[1]) p += 2; else p++; }
            if (*p == '"') p++;
        } else if (*p == '{' || *p == '[') {
            int depth = 0, in_str = 0;
            for (; *p; p++) {
                if (in_str) {
                    if (*p == '\\' && p[1]) { p++; continue; }
                    if (*p == '"') in_str = 0;
                } else if (*p == '"') {
                    in_str = 1;
                } else if (*p == '{' || *p == '[') {
                    depth++;
                } else if (*p == '}' || *p == ']') {
                    depth--;
                    if (depth == 0) { p++; break; }
                }
            }
        } else {
            /* bare literal : true / false / null / number */
            while (*p && *p != ',' && *p != '}' && *p != ']'
                   && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
        }
    }
    return NULL;
}

static int top_level_string_copy(char *buf, const char *key,
                                 char *out, size_t out_size) {
    char *p = top_level_value(buf, key);
    if (!p || *p != '"' || out_size == 0) return 0;
    p++;
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < out_size) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') out[n++] = '\n';
            else if (*p == 't') out[n++] = '\t';
            else if (*p == 'r') out[n++] = '\r';
            else out[n++] = *p;
            p++;
        } else {
            out[n++] = *p++;
        }
    }
    if (*p != '"') return 0;
    out[n] = '\0';
    return 1;
}

/* Very small in-place JSON scanner — handles the two specific shapes
 * cockerd sends (`{"cmd":[...],"env":{...},"tty":bool}` in any key order).
 * Not a general decoder.
 *
 * Returns the number of argv entries on success, 0 on parse error. argv and
 * env_out are filled with pointers into `buf`, which the caller owns. */
static int parse_exec_request(char *buf, size_t buf_len,
                              char **argv, int argv_max,
                              char **env_out, int env_max,
                              int *tty_out, int *rows_out, int *cols_out) {
    /* NUL-terminate */
    if (buf_len >= EXEC_BUF_SIZE) buf_len = EXEC_BUF_SIZE - 1;
    buf[buf_len] = '\0';

    *tty_out = 0;
    /* 0 means "the host didn't say" — openpty then uses its default and the
     * child sees the usual 80x24. */
    *rows_out = 0;
    *cols_out = 0;
    argv[0] = NULL;
    env_out[0] = NULL;

    /* --- locate cmd / tty / env as TOP-LEVEL keys --- on the pristine
     * buffer, before the argv loop below mutates cmd's values. Using a
     * depth-1 structural walk makes the parser independent of JSON key order
     * (JSONEncoder guarantees none) AND immune to same-named nested keys or
     * values — e.g. an env var literally named `tty` no longer steals the
     * top-level `tty` field. env is *parsed* further down, after argv; its
     * region lies outside the cmd array, so the argv loop leaves it pristine. */
    char *cmd_open = top_level_value(buf, "cmd");
    if (!cmd_open || *cmd_open != '[') return 0;

    char *t = top_level_value(buf, "tty");
    if (t && *t == 't') *tty_out = 1;  /* value is the literal `true` */

    /* Terminal geometry, so a `-t` exec starts at the caller's real size
     * instead of the 80x24 openpty default. Anything that redraws — vim,
     * top, a shell prompt — is wrong until the first resize otherwise. */
    char *r = top_level_value(buf, "rows");
    if (r) *rows_out = atoi(r);
    char *c = top_level_value(buf, "cols");
    if (c) *cols_out = atoi(c);

    char *env_field = top_level_value(buf, "env");

    /* --- argv --- (mutates cmd's string values in place) */
    char *p = cmd_open + 1;
    int argc = 0;
    while (*p && argc < argv_max - 1) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t') p++;
        if (*p == ']') break;
        if (*p != '"') break;
        p++;  /* opening quote */
        char *start = p;
        char *write = p;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
                /* simple JSON escapes */
                char esc = p[1];
                if (esc == 'n') *write++ = '\n';
                else if (esc == 't') *write++ = '\t';
                else if (esc == 'r') *write++ = '\r';
                else *write++ = esc;
                p += 2;
            } else {
                *write++ = *p++;
            }
        }
        if (*p != '"') break;
        *write = '\0';
        argv[argc++] = start;
        p++;  /* closing quote */
    }
    argv[argc] = NULL;

    /* B16 hardening : reject the request if argv[0] is empty or absent.
     * execvp("", ...) returns ENOENT immediately ; sending an empty argv
     * deeper into the listener would just waste a fork and write an
     * unhelpful 127. */
    if (argc == 0 || argv[0] == NULL || argv[0][0] == '\0') return 0;

    /* --- env --- parse from the pre-located pointer (see note above). */
    int envc = 0;
    char *e = env_field;
    if (e) {
        e = strchr(e, '{');
        if (e) {
            e++;
            while (*e && envc < env_max - 1) {
                while (*e == ' ' || *e == ',' || *e == '\n' || *e == '\t') e++;
                if (*e == '}') break;
                if (*e != '"') break;
                e++;
                char *key = e;
                while (*e && *e != '"') e++;
                if (*e != '"') break;
                *e = '\0'; e++;
                while (*e && *e != ':') e++;
                if (!*e) break;
                e++;
                while (*e == ' ' || *e == '\t') e++;
                if (*e != '"') break;
                e++;
                char *val_start = e;
                char *val_write = e;
                while (*e && *e != '"') {
                    if (*e == '\\' && e[1]) {
                        *val_write++ = e[1]; e += 2;
                    } else {
                        *val_write++ = *e++;
                    }
                }
                if (*e != '"') break;
                *val_write = '\0';
                /* Build "KEY=VALUE" by moving val one byte right so we can
                 * stick a '=' before it.  Easier: malloc a fresh buffer. */
                size_t klen = strlen(key);
                size_t vlen = strlen(val_start);
                char *kv = (char *)malloc(klen + 1 + vlen + 1);
                if (!kv) break;
                memcpy(kv, key, klen);
                kv[klen] = '=';
                memcpy(kv + klen + 1, val_start, vlen);
                kv[klen + 1 + vlen] = '\0';
                env_out[envc++] = kv;
                e++;
            }
        }
    }
    env_out[envc] = NULL;

    return argc;
}

/* Read up to `max` bytes or until a '\n' lands in the buffer. Returns the
 * number of bytes read (including the newline). */
static ssize_t read_request_line(int fd, char *buf, size_t max) {
    size_t total = 0;
    while (total < max - 1) {
        ssize_t n = read(fd, buf + total, 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;  /* EOF before NL */
        total += n;
        if (buf[total - 1] == '\n') break;
    }
    buf[total] = '\0';
    return (ssize_t)total;
}

/* Handle a single accepted connection: parse the request, spawn the child,
 * stream its output, send the exit marker, then close. */
static void handle_one(int client_fd) {
    /* Restore SIGCHLD to its default behaviour : the listener parent sets
     * it to SIG_IGN to reap accept-time grandchildren without zombies, but
     * that propagates through fork, and our own waitpid() needs the kernel
     * to actually keep the child's exit status around. Without this reset
     * waitpid returns -1/ECHILD and we never write the exit marker — the
     * host side reads forever, exec appears to hang. */
    signal(SIGCHLD, SIG_DFL);

    static char buf[EXEC_BUF_SIZE];
    ssize_t r = read_request_line(client_fd, buf, EXEC_BUF_SIZE);
    if (r <= 0) {
        const char *err = "__COCKER_EXIT__1\n";
        write(client_fd, err, strlen(err));
        close(client_fd);
        return;
    }

    /* Stop-signal short-circuit. cockerd uses the same vsock port for
     * both exec and "send signal" — the latter has no `cmd` field but
     * carries `{"signal":"SIGNAME"}`. We catch it here BEFORE the
     * full exec request parser because the absence of "cmd" would
     * otherwise return 0 and look like a parse error.
     *
     * Resolves the target PID by reading /cocker-child.pid (init writes
     * its main child's PID there right after fork). Replies with one
     * line — "__COCKER_SIGNAL_OK__\n" on success or
     * "__COCKER_SIGNAL_ERR__<reason>\n" otherwise — and closes. */
    /* Terminal resize : {"resize":true,"rows":N,"cols":N}.
     *
     * `cocker run -it` sets the console's winsize once at start, from the
     * spec. Resizing the host window afterwards left the container at the
     * old size, so anything that redraws — vim, top, a shell's line editor —
     * wrapped at the wrong column for the rest of the session. There is no
     * room for a control message in the console byte stream (it belongs to
     * the application), so it comes over the same vsock the exec listener
     * already serves.
     *
     * Applies to /dev/console, which init made the main process's
     * controlling terminal; the kernel then sends SIGWINCH to its
     * foreground process group for us. */
    if (strstr(buf, "\"resize\"") && !strstr(buf, "\"cmd\"")) {
        int rows = 0, cols = 0;
        char *rp = strstr(buf, "\"rows\"");
        if (rp && (rp = strchr(rp, ':'))) rows = atoi(rp + 1);
        char *cp = strstr(buf, "\"cols\"");
        if (cp && (cp = strchr(cp, ':'))) cols = atoi(cp + 1);

        const char *reply = "__COCKER_RESIZE_ERR__\n";
        if (rows > 0 && cols > 0) {
            int fd = open("/dev/console", O_RDWR | O_NOCTTY);
            if (fd >= 0) {
                struct winsize ws;
                memset(&ws, 0, sizeof(ws));
                ws.ws_row = (unsigned short)rows;
                ws.ws_col = (unsigned short)cols;
                if (ioctl(fd, TIOCSWINSZ, &ws) == 0) reply = "__COCKER_RESIZE_OK__\n";
                close(fd);
            }
        }
        write(client_fd, reply, strlen(reply));
        close(client_fd);
        return;
    }

    if (strstr(buf, "\"signal\"") && !strstr(buf, "\"cmd\"")) {
        char *sp = strstr(buf, "\"signal\"");
        sp = strchr(sp, ':');
        int signum = 0;
        if (sp) {
            sp++;
            while (*sp == ' ' || *sp == '\t') sp++;
            if (*sp == '"') {
                sp++;
                char *end = strchr(sp, '"');
                if (end) {
                    *end = '\0';
                    /* Reuse the same name mapping the Swift side knows. */
                    if (!strcmp(sp, "SIGHUP") || !strcmp(sp, "HUP")) signum = 1;
                    else if (!strcmp(sp, "SIGINT") || !strcmp(sp, "INT")) signum = 2;
                    else if (!strcmp(sp, "SIGQUIT") || !strcmp(sp, "QUIT")) signum = 3;
                    else if (!strcmp(sp, "SIGKILL") || !strcmp(sp, "KILL")) signum = 9;
                    else if (!strcmp(sp, "SIGUSR1") || !strcmp(sp, "USR1")) signum = 10;
                    else if (!strcmp(sp, "SIGUSR2") || !strcmp(sp, "USR2")) signum = 12;
                    else if (!strcmp(sp, "SIGTERM") || !strcmp(sp, "TERM")) signum = 15;
                    else signum = atoi(sp);
                }
            } else {
                signum = atoi(sp);
            }
        }
        const char *reply;
        if (signum > 0 && signum < 32) {
            FILE *cpf = fopen("/cocker-child.pid", "r");
            pid_t target = 0;
            if (cpf) { int v = 0; if (fscanf(cpf, "%d", &v) == 1) target = (pid_t)v; fclose(cpf); }
            /* Debug breadcrumb : write what we tried to do to a file the
             * host can read after the VM stops. Critical for diagnosing
             * "ack=OK but trap never fired" cases — without this we don't
             * know if kill() returned 0 because the signal landed or
             * because the kernel silently dropped it. */
            if (target > 1) {
                if (kill(target, signum) == 0) {
                    reply = "__COCKER_SIGNAL_OK__\n";
                } else {
                    reply = "__COCKER_SIGNAL_ERR__kill\n";
                }
            } else {
                reply = "__COCKER_SIGNAL_ERR__no-child-pid\n";
            }
        } else {
            reply = "__COCKER_SIGNAL_ERR__bad-signal\n";
        }
        write(client_fd, reply, strlen(reply));
        close(client_fd);
        return;
    }

    char *argv[MAX_ARGV];
    char *env_out[MAX_ENV];
    char workdir[4096] = "";
    char user[256] = "";
    int tty = 0;
    int rows = 0, cols = 0;
    (void)top_level_string_copy(buf, "workdir", workdir, sizeof(workdir));
    (void)top_level_string_copy(buf, "user", user, sizeof(user));
    int argc = parse_exec_request(buf, (size_t)r, argv, MAX_ARGV, env_out, MAX_ENV,
                                  &tty, &rows, &cols);
    if (argc == 0) {
        const char *err = "parse error\n__COCKER_EXIT__2\n";
        write(client_fd, err, strlen(err));
        close(client_fd);
        return;
    }

    int master_fd = -1;
    int slave_fd = -1;
    if (tty) {
        /* openpty allocates a /dev/pts/N pair. The master stays on the
         * listener side and gets relayed to the client socket ; the slave
         * is dup'd into the child's stdin/stdout/stderr after setsid +
         * TIOCSCTTY so the child sees a real controlling terminal. */
        struct winsize ws;
        struct winsize *wsp = NULL;
        if (rows > 0 && cols > 0) {
            memset(&ws, 0, sizeof(ws));
            ws.ws_row = (unsigned short)rows;
            ws.ws_col = (unsigned short)cols;
            wsp = &ws;
        }
        if (openpty(&master_fd, &slave_fd, NULL, NULL, wsp) != 0) {
            const char *err = "openpty failed\n__COCKER_EXIT__3\n";
            write(client_fd, err, strlen(err));
            close(client_fd);
            return;
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        if (master_fd >= 0) close(master_fd);
        if (slave_fd >= 0) close(slave_fd);
        const char *err = "fork failed\n__COCKER_EXIT__3\n";
        write(client_fd, err, strlen(err));
        close(client_fd);
        return;
    }
    if (pid == 0) {
        /* Child. Two paths : pty mode hooks up the slave as controlling
         * terminal ; non-pty mode just dups the raw socket as before. */
        if (tty) {
            if (master_fd >= 0) close(master_fd);
            setsid();
            ioctl(slave_fd, TIOCSCTTY, 0);
            dup2(slave_fd, STDIN_FILENO);
            dup2(slave_fd, STDOUT_FILENO);
            dup2(slave_fd, STDERR_FILENO);
            if (slave_fd > STDERR_FILENO) close(slave_fd);
            if (client_fd > STDERR_FILENO) close(client_fd);
        } else {
            /* Non-TTY exec : the same vsock fd carries stdin from the
             * host (anything after the request's terminator newline is
             * stdin bytes) and child's stdout / stderr the other way.
             * Pre-`cocker exec -i` stdin forwarding, only stdout / stderr
             * were dup'd ; programs that read stdin (`cat`, `sort`,
             * `wc -l`) saw EOF immediately because the inherited stdin
             * was the listener parent's vsock fd after its own NL-bounded
             * read had drained the request line. Adding STDIN_FILENO
             * here lets the child block on more input until the host
             * shutdown(SHUT_WR)'s the socket. */
            /* Capability policy BEFORE the dup2 below.
             *
             * Same policy as the container's main process — this was
             * missing, so `cocker exec` handed out the FULL kernel bounding
             * set while the main process ran with docker's restricted
             * default (a80425fb vs 1ffffffffff, measured on one container).
             *
             * Before the dup2 because caps_apply logs, and once client_fd is
             * stdout that log lands in the caller's stream: `cocker exec c
             * echo ping` returned "[cocker-init] caps: bounded set narrowed
             * (…)ping" instead of "ping" — a broken contract for every
             * script that parses exec output, and caught only by merging
             * this branch with the others and running 12-exec-after-start.
             *
             * Still before setgid/setuid, as init.c orders it: with
             * SECBIT_NOROOT off root keeps its capabilities across a uid
             * change, so narrowing the bounding set first is what bounds
             * whatever survives. */
            caps_apply(privileged_spec,
                       cap_add_spec, cap_add_spec_len,
                       cap_drop_spec, cap_drop_spec_len);

            dup2(client_fd, STDIN_FILENO);
            dup2(client_fd, STDOUT_FILENO);
            dup2(client_fd, STDERR_FILENO);
            if (client_fd > STDERR_FILENO) close(client_fd);
        }

        for (int i = 0; env_out[i]; i++) putenv(env_out[i]);

        if (workdir[0] && chdir(workdir) != 0) {
            fprintf(stderr, "[cocker-init] chdir %s: %s\n", workdir, strerror(errno));
            _exit(126);
        }

        if (user[0]) {
            unsigned int uid = 0, gid = 0;
            if (spec_resolve_user(user, &uid, &gid) != 0
                || setgid((gid_t)gid) != 0 || setuid((uid_t)uid) != 0) {
                fprintf(stderr, "[cocker-init] user %s: %s\n", user, strerror(errno));
                _exit(126);
            }
        }

        execvp(argv[0], argv);
        fprintf(stderr, "[cocker-init] exec %s: %s\n", argv[0], strerror(errno));
        _exit(exec_failure_code(errno));
    }

    /* Parent in pty mode : relay master_fd <-> client_fd. We dup the
     * master into client_fd direction in a small select loop so the host
     * sees pty output and can write input back. */
    if (tty && master_fd >= 0) {
        close(slave_fd);
        /* Best-effort relay : read from master, write to client. Stop on
         * any error / EOF, then we'll waitpid the child and emit marker. */
        fd_set rfds;
        char buf[4096];
        /* The host may close its stdin long before the command finishes —
         * `printf … | cocker exec -it c sh`, or a user pressing Ctrl-D. That
         * must not end the session: the child keeps running and its output
         * still has to reach the host. Breaking the loop here abandoned that
         * output and closed the socket the host was still reading, which it
         * saw as ECONNRESET. */
        int client_eof = 0;
        for (;;) {
            FD_ZERO(&rfds);
            FD_SET(master_fd, &rfds);
            if (!client_eof) FD_SET(client_fd, &rfds);
            int maxfd = master_fd;
            if (!client_eof && client_fd > maxfd) maxfd = client_fd;
            struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
            int rv = select(maxfd + 1, &rfds, NULL, NULL, &tv);
            if (rv < 0) { if (errno == EINTR) continue; break; }
            if (FD_ISSET(master_fd, &rfds)) {
                ssize_t n = read(master_fd, buf, sizeof(buf));
                if (n <= 0) break;
                write(client_fd, buf, (size_t)n);
            }
            if (!client_eof && FD_ISSET(client_fd, &rfds)) {
                ssize_t n = read(client_fd, buf, sizeof(buf));
                if (n <= 0) {
                    /* Deliver EOF to the child the way a terminal does — ^D
                     * on the master — then stop watching this side and keep
                     * pumping the child's output until it exits. */
                    client_eof = 1;
                    char eot = 0x04;
                    write(master_fd, &eot, 1);
                } else {
                    write(master_fd, buf, (size_t)n);
                }
            }
            /* Detect child exit non-blocking : if waitpid would reap, break. */
            int wstat;
            pid_t r2 = waitpid(pid, &wstat, WNOHANG);
            if (r2 == pid) break;
        }
        close(master_fd);
    }

    /* Parent : wait for child, then send the exit marker. */
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    int code = WIFEXITED(status) ? WEXITSTATUS(status)
             : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
             : 1;
    char marker[64];
    int len = snprintf(marker, sizeof(marker), "__COCKER_EXIT__%d\n", code);
    write(client_fd, marker, (size_t)len);
    close(client_fd);

    /* Free the env entries we allocated in parse_exec_request. */
    for (int i = 0; env_out[i]; i++) free(env_out[i]);
}

/* B17 reaper : keep `worker_count` accurate as children exit. We can't use
 * SIG_IGN (the pre-fix behaviour) and still track active workers — the
 * kernel discards SIGCHLD without giving us a hook. Installing an explicit
 * handler that drains all pending exits via WNOHANG gives us both : no
 * zombie accumulation AND an accurate gauge for admission control. */
static void exec_listener_reaper(int sig) {
    (void)sig;
    int saved = errno;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
        if (worker_count > 0) worker_count--;
    }
    errno = saved;
}

/* Background listener loop. Forks a separate process so a crash here doesn't
 * take down PID 1. */
pid_t exec_listener_spawn(void) {
    pid_t pid = fork();
    if (pid < 0) {
        info("exec-listener: fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid > 0) {
        info("exec-listener: spawned (pid=%d)", pid);
        return pid;
    }

    /* Child : the listener itself. The reaper above replaces SIG_IGN so
     * we can keep `worker_count` accurate without leaking zombies. */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = exec_listener_reaper;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NOCLDSTOP | SA_RESTART;
    sigaction(SIGCHLD, &sa, NULL);

    int sfd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (sfd < 0) {
        info("exec-listener: socket(AF_VSOCK): %s", strerror(errno));
        _exit(1);
    }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = EXEC_VSOCK_PORT;

    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        info("exec-listener: bind: %s", strerror(errno));
        _exit(1);
    }
    if (listen(sfd, 4) < 0) {
        info("exec-listener: listen: %s", strerror(errno));
        _exit(1);
    }
    info("exec-listener ready on vsock port %d", EXEC_VSOCK_PORT);

    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            info("exec-listener: accept: %s", strerror(errno));
            continue;
        }
        info("exec-listener: accepted connection (cfd=%d)", cfd);
        /* Admission control : the parent tracks active worker count via the
         * SIGCHLD reaper above. Past MAX_CONCURRENT_WORKERS we tell the
         * client to back off rather than forking unbounded children that
         * collectively OOM-kill the listener. */
        if (worker_count >= MAX_CONCURRENT_WORKERS) {
            const char *busy =
                "exec listener at capacity, try again shortly\n"
                "__COCKER_EXIT__16\n";
            write(cfd, busy, strlen(busy));
            close(cfd);
            continue;
        }
        /* Each request handled in a fresh child so parallel execs don't
         * block each other. */
        pid_t wpid = fork();
        if (wpid == 0) {
            close(sfd);
            handle_one(cfd);
            _exit(0);
        }
        if (wpid > 0) worker_count++;
        close(cfd);
    }
}
