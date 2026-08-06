/*
 * health_poll.c — guest-side worker for HEALTHCHECK CMD probes.
 *
 * Apple's VZ vsock callback (which we'd otherwise use for cocker exec
 * from a daemon-internal loop) doesn't fire reliably. So both sides
 * communicate through plain files on the virtiofs share that
 * cocker-init mounted as rootfs : cockerd writes a request file ; this
 * loop polls for it, runs the command (killing it after timeout), and
 * writes the result back.
 *
 * Wire format :
 *
 *   /healthcheck/cmd-<seq>     First line "TIMEOUT=<seconds>\n" (optional),
 *                              then argv joined with NUL ('\0') separators.
 *   /healthcheck/result-<seq>  "<exit_code>\n<output>" : decimal exit on
 *                              the first line, then up to 4 KB of the
 *                              child's combined stdout+stderr.
 *
 * Files are renamed into place atomically so cockerd never reads a
 * half-written payload.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "cocker_init.h"

#define HC_DIR "/healthcheck"
#define HC_MAX_ARGV 64
#define HC_MAX_BUF  (16 * 1024)
#define HC_MAX_OUTPUT 4096      /* Docker per-probe log cap. */
#define HC_DEFAULT_TIMEOUT 30

/* Split a NUL-separated argv blob (in place) into argv pointers.
 * Returns the count, capped to HC_MAX_ARGV-1. */
static int split_argv(char *buf, ssize_t len, char **argv) {
    int n = 0;
    char *p = buf;
    char *end = buf + len;
    while (p < end && n < HC_MAX_ARGV - 1) {
        argv[n++] = p;
        while (p < end && *p != '\0' && *p != '\n') p++;
        if (p < end) { *p = '\0'; p++; }
    }
    argv[n] = NULL;
    if (n > 0 && argv[n - 1][0] == '\0') { argv[--n] = NULL; }
    return n;
}

/* Run one request file. Writes the child's stdout+stderr (up to
 * HC_MAX_OUTPUT bytes) into `output_buf` ; sets `*output_len` to the
 * captured size. Returns the child's exit code, or 124 if the kernel
 * SIGKILL hit the deadline (Docker's reserved code for "timed out"). */
static int run_request(const char *path,
                       char *output_buf, size_t *output_len) {
    *output_len = 0;
    output_buf[0] = '\0';

    int fd = open(path, O_RDONLY);
    if (fd < 0) return 1;
    static char buf[HC_MAX_BUF];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 1;
    buf[n] = '\0';

    /* Optional TIMEOUT=<seconds>\n header. Skip past it before argv split.
     * Accepts fractional seconds : `--health-timeout 1.5s` round-trips
     * through `strtod` here instead of being truncated to 1. We work in
     * milliseconds internally so the poll() deadline calculus stays in
     * whole numbers without losing the sub-second precision. */
    long timeout_ms = HC_DEFAULT_TIMEOUT * 1000;
    char *argv_start = buf;
    ssize_t argv_len = n;
    if (strncmp(buf, "TIMEOUT=", 8) == 0) {
        char *nl = memchr(buf, '\n', (size_t)n);
        if (nl) {
            *nl = '\0';
            char *end = NULL;
            double secs = strtod(buf + 8, &end);
            if (secs > 0.0) {
                timeout_ms = (long)(secs * 1000.0 + 0.5);
            } else {
                timeout_ms = HC_DEFAULT_TIMEOUT * 1000;
            }
            argv_start = nl + 1;
            argv_len = n - (argv_start - buf);
        }
    }
    int timeout = (int)((timeout_ms + 999) / 1000); /* used only for the 124 path */
    (void)timeout;

    char *argv[HC_MAX_ARGV];
    int argc = split_argv(argv_start, argv_len, argv);
    if (argc == 0) return 1;

    /* Pipe to capture child's combined stdout+stderr. */
    int pipefd[2];
    if (pipe(pipefd) < 0) return 1;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        return 1;
    }
    if (pid == 0) {
        signal(SIGCHLD, SIG_DFL);
        /* Redirect stdout + stderr into the pipe ; the parent reads from
         * pipefd[0] for at most HC_MAX_OUTPUT bytes. */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        if (pipefd[1] > STDERR_FILENO) close(pipefd[1]);
        if (user_spec[0]) {
            unsigned int uid = 0, gid = 0;
            if (spec_resolve_user(user_spec, &uid, &gid) == 0) {
                if (setgid(gid) != 0) _exit(126);
                if (setuid(uid) != 0) _exit(126);
            }
        }
        execvp(argv[0], argv);
        _exit(exec_failure_code(errno));
    }

    close(pipefd[1]);
    /* Read from the pipe with a deadline. If the child overruns we send
     * SIGKILL and report 124. Use poll() so the read doesn't outlive the
     * timeout when the child just hangs without ever writing. */
    struct timespec start_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);
    size_t collected = 0;
    int timed_out = 0;
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_ms = (now.tv_sec - start_ts.tv_sec) * 1000
                        + (now.tv_nsec - start_ts.tv_nsec) / 1000000;
        long remaining = timeout_ms - elapsed_ms;
        if (remaining <= 0) { timed_out = 1; break; }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, (int)remaining);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) { timed_out = 1; break; }
        if (pfd.revents & POLLIN) {
            size_t space = HC_MAX_OUTPUT - collected - 1;
            if (space == 0) {
                /* Still drain the pipe so the child doesn't block on a
                 * full pipe buffer ; just discard once buffer is full. */
                char dump[1024];
                ssize_t d = read(pipefd[0], dump, sizeof(dump));
                if (d <= 0) break;
                continue;
            }
            ssize_t r = read(pipefd[0], output_buf + collected, space);
            if (r < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (r == 0) break; /* EOF — child closed pipe */
            collected += (size_t)r;
            output_buf[collected] = '\0';
        } else if (pfd.revents & (POLLHUP | POLLERR)) {
            /* Drain any final bytes after HUP. */
            ssize_t r = read(pipefd[0], output_buf + collected,
                             HC_MAX_OUTPUT - collected - 1);
            if (r > 0) {
                collected += (size_t)r;
                output_buf[collected] = '\0';
            }
            break;
        }
    }
    close(pipefd[0]);

    if (timed_out) {
        /* Kernel SIGKILL so a hung probe can't pile up across intervals. */
        kill(pid, SIGKILL);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    *output_len = collected;
    if (timed_out) return 124;
    return WIFEXITED(status) ? WEXITSTATUS(status)
         : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
         : 1;
}

/* Write result-<seq> atomically. Format : "<exit>\n" followed by the
 * captured output (no trailing newline added so cockerd sees exactly
 * what the probe printed). */
static void write_result(const char *seq, int code,
                         const char *output, size_t output_len) {
    char tmp[256], final[256];
    snprintf(tmp, sizeof(tmp), HC_DIR "/.result-%s.tmp", seq);
    snprintf(final, sizeof(final), HC_DIR "/result-%s", seq);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char header[32];
    int hlen = snprintf(header, sizeof(header), "%d\n", code);
    if (hlen > 0) write(fd, header, (size_t)hlen);
    if (output_len > 0) write(fd, output, output_len);
    fsync(fd);
    close(fd);
    rename(tmp, final);
}

static void poll_loop(void) {
    mkdir(HC_DIR, 0755);
    signal(SIGCHLD, SIG_DFL);

    caps_apply(privileged_spec,
               cap_add_spec, cap_add_spec_len,
               cap_drop_spec, cap_drop_spec_len);

    static char output_buf[HC_MAX_OUTPUT];

    for (;;) {
        DIR *d = opendir(HC_DIR);
        if (!d) { sleep(1); continue; }
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (strncmp(e->d_name, "cmd-", 4) != 0) continue;
            const char *seq = e->d_name + 4;
            char path[256];
            snprintf(path, sizeof(path), HC_DIR "/%s", e->d_name);
            size_t out_len = 0;
            int code = run_request(path, output_buf, &out_len);
            write_result(seq, code, output_buf, out_len);
            unlink(path);
        }
        closedir(d);
        usleep(250 * 1000);
    }
}

pid_t health_poll_spawn(void) {
    pid_t pid = fork();
    if (pid < 0) {
        info("health-poll: fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid > 0) {
        info("health-poll: spawned (pid=%d)", pid);
        return pid;
    }
    poll_loop();
    _exit(0);
}
