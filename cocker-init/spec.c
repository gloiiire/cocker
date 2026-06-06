/*
 * spec.c — load /cocker-spec written by cockerd.
 *
 * Wire format v2 (mirrors RootfsBootstrap.encodeSpec on the Swift side) —
 * length-prefixed binary so argv values can carry any byte, including
 * newlines. The v1 line-separated format broke on `bash -c "a\nb"`.
 *
 *   magic    : "COCKER\x02" (7 bytes)
 *   argc     : u32 BE
 *     for each : u32 BE length, then bytes (UTF-8)
 *   envc     : u32 BE
 *     for each : u32 BE length, then bytes
 *   wd_len   : u32 BE
 *   wd_bytes
 *
 * Values aren't NUL-terminated on the wire ; we copy them into a separate
 * `strings` buffer and append a NUL, then hand the pointers to execvp() /
 * putenv(). The buffer lives forever (static) because putenv() does not
 * copy the value.
 */

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "cocker_init.h"

#define SPEC_MAGIC "COCKER\x02"
#define SPEC_MAGIC_LEN 7
#define SPEC_BUF_SIZE  (256 * 1024)

static unsigned int read_u32_be(const unsigned char *p) {
    return ((unsigned int)p[0] << 24) |
           ((unsigned int)p[1] << 16) |
           ((unsigned int)p[2] <<  8) |
           ((unsigned int)p[3]);
}

int spec_load(char **argv, int max) {
    int spec_fd = open("/cocker-spec", O_RDONLY);
    if (spec_fd < 0) {
        info("no /cocker-spec found, defaulting to /bin/sh");
        argv[0] = (char *)"/bin/sh";
        argv[1] = NULL;
        return 1;
    }

    static char spec_buf[SPEC_BUF_SIZE];
    ssize_t spec_len = read(spec_fd, spec_buf, sizeof(spec_buf));
    close(spec_fd);
    if (spec_len < 0) die("read /cocker-spec: %s", strerror(errno));
    if (spec_len < SPEC_MAGIC_LEN + 4)
        die("/cocker-spec too short (%zd bytes)", spec_len);

    const unsigned char *p = (const unsigned char *)spec_buf;
    const unsigned char *end = (const unsigned char *)spec_buf + spec_len;

    if (memcmp(p, SPEC_MAGIC, SPEC_MAGIC_LEN) != 0)
        die("/cocker-spec magic mismatch");
    p += SPEC_MAGIC_LEN;

    /* All strings get copied into this buffer with a NUL terminator so
     * argv[] and the putenv() entries can point at them. */
    static char strings[SPEC_BUF_SIZE];
    size_t out = 0;

    /* argv */
    if (p + 4 > end) die("/cocker-spec truncated at argc");
    unsigned int argc = read_u32_be(p); p += 4;
    int n = 0;
    for (unsigned int i = 0; i < argc; i++) {
        if (p + 4 > end) die("/cocker-spec truncated at argv[%u]", i);
        unsigned int len = read_u32_be(p); p += 4;
        if (p + len > end) die("/cocker-spec truncated at argv[%u] body", i);
        if (out + len + 1 > sizeof(strings)) die("/cocker-spec too big (argv)");
        memcpy(strings + out, p, len);
        strings[out + len] = '\0';
        if (n < max - 1) argv[n++] = strings + out;
        out += len + 1;
        p += len;
    }
    argv[n] = NULL;

    /* env */
    if (p + 4 > end) die("/cocker-spec truncated at envc");
    unsigned int envc = read_u32_be(p); p += 4;
    for (unsigned int i = 0; i < envc; i++) {
        if (p + 4 > end) die("/cocker-spec truncated at env[%u]", i);
        unsigned int len = read_u32_be(p); p += 4;
        if (p + len > end) die("/cocker-spec truncated at env[%u] body", i);
        if (out + len + 1 > sizeof(strings)) die("/cocker-spec too big (env)");
        memcpy(strings + out, p, len);
        strings[out + len] = '\0';
        if (memchr(strings + out, '=', len)) {
            putenv(strings + out);
        }
        out += len + 1;
        p += len;
    }

    /* workdir */
    if (p + 4 > end) die("/cocker-spec truncated at workdir");
    unsigned int wd_len = read_u32_be(p); p += 4;
    if (p + wd_len > end) die("/cocker-spec truncated at workdir body");
    if (wd_len > 0) {
        if (out + wd_len + 1 > sizeof(strings)) die("/cocker-spec too big (wd)");
        memcpy(strings + out, p, wd_len);
        strings[out + wd_len] = '\0';
        const char *wd = strings + out;
        if (*wd && chdir(wd) < 0)
            info("chdir %s failed: %s", wd, strerror(errno));
    }

    return n;
}
