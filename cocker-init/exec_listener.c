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

/* Scan from the `[` that opens the cmd array to its matching `]`, honoring
 * quoted strings and backslash escapes so a `]` inside an argument value
 * doesn't end the array early. Returns the `]` position, or NULL if the
 * array is unterminated. Operates on the still-pristine buffer. */
static char *cmd_array_end(char *open_bracket) {
    char *q = open_bracket + 1;
    int in_str = 0;
    while (*q) {
        if (in_str) {
            if (*q == '\\' && q[1]) { q += 2; continue; }
            if (*q == '"') in_str = 0;
        } else if (*q == '"') {
            in_str = 1;
        } else if (*q == ']') {
            return q;
        }
        q++;
    }
    return NULL;
}

/* Locate `needle` (e.g. "\"tty\"") in `buf`, skipping any match that falls
 * inside the cmd array span (lo, hi). Two properties matter here :
 *   1. It runs on the pristine buffer *before* the argv loop plants NUL
 *      terminators into cmd's string values — so it is immune to JSON key
 *      ordering (JSONEncoder guarantees none). A from-`p`-after-cmd search
 *      used to miss `tty`/`env` whenever they preceded `cmd`, and a
 *      whole-buffer strstr used to stop dead at the first NUL the argv loop
 *      had written.
 *   2. Skipping the cmd span stops a command argument that literally
 *      contains the text `"tty"` or `"env"` (e.g. `cocker exec c tty`) from
 *      being mistaken for the top-level field. */
static char *find_top_field(char *buf, const char *needle, char *lo, char *hi) {
    char *s = buf;
    while ((s = strstr(s, needle)) != NULL) {
        if (lo && hi && s > lo && s < hi) { s = hi; continue; }
        return s;
    }
    return NULL;
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
                              int *tty_out) {
    /* NUL-terminate */
    if (buf_len >= EXEC_BUF_SIZE) buf_len = EXEC_BUF_SIZE - 1;
    buf[buf_len] = '\0';

    *tty_out = 0;
    argv[0] = NULL;
    env_out[0] = NULL;

    /* --- locate cmd array ---
     * Locate the colon that terminates the `"cmd"` key, then the *next*
     * non-whitespace char must be a `[`. The pre-fix code used
     * `strchr(p, '[')` which would also accept `"cmd":"[hack]"`, parsing
     * it as an empty argv array. Constraining the scan to a literal
     * `: WS* [` makes the parser closer to a real JSON peek. */
    char *p = strstr(buf, "\"cmd\"");
    if (!p) return 0;
    p = strchr(p, ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '[') return 0;
    char *cmd_open = p;
    char *cmd_close = cmd_array_end(cmd_open);

    /* --- tty & env location --- done on the pristine buffer and outside
     * the cmd span BEFORE the argv loop below mutates cmd's values. This is
     * the fix for the order-dependent `exec -it` breakage : previously tty
     * was only seen if it preceded cmd and env only if it followed cmd, so a
     * given daemon boot (JSONEncoder's key order is randomized per process)
     * could silently drop the PTY or the environment for its whole lifetime.
     * env is *parsed* further down, after argv — its region lies outside the
     * cmd array, so the argv loop leaves it pristine. */
    char *t = find_top_field(buf, "\"tty\"", cmd_open, cmd_close);
    if (t) {
        t = strchr(t, ':');
        if (t) {
            t++;
            while (*t == ' ' || *t == '\t') t++;
            if (*t == 't') *tty_out = 1;  /* "true" */
        }
    }
    char *env_field = find_top_field(buf, "\"env\"", cmd_open, cmd_close);

    /* --- argv --- (mutates cmd's string values in place) */
    p = cmd_open + 1;
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
    int tty = 0;
    int argc = parse_exec_request(buf, (size_t)r, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
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
        if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) != 0) {
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
            dup2(client_fd, STDIN_FILENO);
            dup2(client_fd, STDOUT_FILENO);
            dup2(client_fd, STDERR_FILENO);
            if (client_fd > STDERR_FILENO) close(client_fd);
        }

        for (int i = 0; env_out[i]; i++) putenv(env_out[i]);

        execvp(argv[0], argv);
        fprintf(stderr, "[cocker-init] exec %s: %s\n", argv[0], strerror(errno));
        _exit(127);
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
        for (;;) {
            FD_ZERO(&rfds);
            FD_SET(master_fd, &rfds);
            FD_SET(client_fd, &rfds);
            int maxfd = master_fd > client_fd ? master_fd : client_fd;
            struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
            int rv = select(maxfd + 1, &rfds, NULL, NULL, &tv);
            if (rv < 0) { if (errno == EINTR) continue; break; }
            if (FD_ISSET(master_fd, &rfds)) {
                ssize_t n = read(master_fd, buf, sizeof(buf));
                if (n <= 0) break;
                write(client_fd, buf, (size_t)n);
            }
            if (FD_ISSET(client_fd, &rfds)) {
                ssize_t n = read(client_fd, buf, sizeof(buf));
                if (n <= 0) break;
                write(master_fd, buf, (size_t)n);
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
