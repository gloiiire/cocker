/*
 * spec.c — load /cocker-spec written by cockerd.
 *
 * Wire format (mirrors RootfsBootstrap.encodeSpec on the Swift side) :
 *
 *   line 1 : argv     — NUL-separated entries, terminated by \n
 *   line 2 : env      — NUL-separated KEY=VALUE entries, terminated by \n
 *   line 3 : workdir  — single string, terminated by \n
 *
 * We use a single static buffer for the whole file so the env entries we
 * hand to putenv() remain valid for the lifetime of the process — putenv
 * does not copy.
 */

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "cocker_init.h"

int spec_load(char **argv, int max) {
    int spec_fd = open("/cocker-spec", O_RDONLY);
    if (spec_fd < 0) {
        info("no /cocker-spec found, defaulting to /bin/sh");
        argv[0] = (char *)"/bin/sh";
        argv[1] = NULL;
        return 1;
    }

    static char spec_buf[65536];
    ssize_t spec_len = read(spec_fd, spec_buf, sizeof(spec_buf) - 1);
    close(spec_fd);
    if (spec_len < 0) die("read /cocker-spec: %s", strerror(errno));
    spec_buf[spec_len] = '\0';

    int argc = 0;

    /* line 1 : argv */
    char *p = spec_buf;
    char *line_end = memchr(p, '\n', spec_len);
    if (line_end) {
        *line_end = '\0';
        char *q = p;
        while (q < line_end && argc < max - 1) {
            argv[argc++] = q;
            q += strlen(q) + 1;
        }
        argv[argc] = NULL;
        p = line_end + 1;
    }

    /* line 2 : env */
    ssize_t remaining = spec_buf + spec_len - p;
    line_end = remaining > 0 ? memchr(p, '\n', remaining) : NULL;
    if (line_end) {
        *line_end = '\0';
        char *q = p;
        while (q < line_end) {
            if (*q && strchr(q, '=')) putenv(q);
            q += strlen(q) + 1;
        }
        p = line_end + 1;
    }

    /* line 3 : workdir */
    remaining = spec_buf + spec_len - p;
    line_end = remaining > 0 ? memchr(p, '\n', remaining) : NULL;
    if (line_end) {
        *line_end = '\0';
        if (*p && chdir(p) < 0)
            info("chdir %s failed: %s", p, strerror(errno));
    }

    return argc;
}
