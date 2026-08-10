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

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "cocker_init.h"

int spec_resolve_user(const char *spec, unsigned int *uid, unsigned int *gid) {
    if (!spec || !*spec) return -1;

    /* Numeric forms : "1234" or "1234:5678". */
    if (isdigit((unsigned char)spec[0])) {
        char *colon = strchr(spec, ':');
        char *endp = NULL;
        long u = strtol(spec, &endp, 10);
        if (u < 0 || (endp != colon && *endp != '\0')) return -1;
        long g = u;  /* default gid = uid when only uid given */
        if (colon) {
            g = strtol(colon + 1, &endp, 10);
            if (g < 0 || *endp != '\0') return -1;
        }
        *uid = (unsigned int)u; *gid = (unsigned int)g;
        return 0;
    }

    /* Symbolic form : "name" → look up in /etc/passwd. We do this manually
     * because the static-musl build can't call getpwnam_r without dragging
     * in the NSS machinery, which inflates the binary and pulls dynamic
     * libraries at runtime. */
    FILE *fp = fopen("/etc/passwd", "r");
    if (!fp) return -1;
    char line[512];
    int found = -1;
    while (fgets(line, sizeof(line), fp)) {
        /* Format : name:passwd:uid:gid:gecos:home:shell */
        char *name = strtok(line, ":");
        if (!name || strcmp(name, spec) != 0) continue;
        strtok(NULL, ":");  /* passwd */
        char *uid_s = strtok(NULL, ":");
        char *gid_s = strtok(NULL, ":");
        if (!uid_s || !gid_s) break;
        *uid = (unsigned int)atoi(uid_s);
        *gid = (unsigned int)atoi(gid_s);
        found = 0;
        break;
    }
    fclose(fp);
    return found;
}

#define SPEC_MAGIC_V2 "COCKER\x02"
#define SPEC_MAGIC_V3 "COCKER\x03"
#define SPEC_MAGIC_V4 "COCKER\x04"
#define SPEC_MAGIC_V5 "COCKER\x05"
#define SPEC_MAGIC_V6 "COCKER\x06"
#define SPEC_MAGIC_V7 "COCKER\x07"
#define SPEC_MAGIC_LEN 7
#define SPEC_BUF_SIZE  (256 * 1024)

/* user_spec is filled from the (optional) v3 `user` trailer and consumed by
 * init.c to setuid/setgid before exec'ing the container's command. Empty
 * string means "run as root" (default). */
char user_spec[256];

/* v4 caps trailer : privileged flag + cap_add / cap_drop arrays of cap
 * numbers (already resolved). Apply via caps_apply before execvp. */
int cap_add_spec[64];
int cap_add_spec_len = 0;
int cap_drop_spec[64];
int cap_drop_spec_len = 0;
int privileged_spec = 0;
int read_only_spec = 0;
char *tmpfs_spec[SPEC_LIST_MAX];       int tmpfs_spec_len = 0;
char *add_host_spec[SPEC_LIST_MAX];    int add_host_spec_len = 0;
char *dns_spec[SPEC_LIST_MAX];         int dns_spec_len = 0;
char *dns_search_spec[SPEC_LIST_MAX];  int dns_search_spec_len = 0;

/* v5 stop-signal trailer. POSIX signal number (e.g. 3 = SIGQUIT,
 * 15 = SIGTERM). 0 = init's default SIGTERM. Forwarded by init.c's
 * SIGTERM handler to the child container process so nginx-style apps
 * configured to graceful-shutdown on SIGQUIT actually receive SIGQUIT
 * instead of being killed without notice. */
int stop_signal_spec = 0;

/* v6 : does the container's main process get a controlling terminal, and at
 * what size. See spec_load(). */
int tty_spec = 0;
int tty_rows_spec = 0;
int tty_cols_spec = 0;

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

    int has_user = 0, has_caps = 0, has_stop = 0, has_tty = 0, has_v7 = 0;
    if (memcmp(p, SPEC_MAGIC_V7, SPEC_MAGIC_LEN) == 0) {
        has_user = 1; has_caps = 1; has_stop = 1; has_tty = 1; has_v7 = 1;
    } else if (memcmp(p, SPEC_MAGIC_V6, SPEC_MAGIC_LEN) == 0) {
        has_user = 1; has_caps = 1; has_stop = 1; has_tty = 1;
    } else if (memcmp(p, SPEC_MAGIC_V5, SPEC_MAGIC_LEN) == 0) {
        has_user = 1; has_caps = 1; has_stop = 1;
    } else if (memcmp(p, SPEC_MAGIC_V4, SPEC_MAGIC_LEN) == 0) {
        has_user = 1; has_caps = 1;
    } else if (memcmp(p, SPEC_MAGIC_V3, SPEC_MAGIC_LEN) == 0) {
        has_user = 1;
    } else if (memcmp(p, SPEC_MAGIC_V2, SPEC_MAGIC_LEN) != 0) {
        die("/cocker-spec magic mismatch");
    }
    p += SPEC_MAGIC_LEN;
    user_spec[0] = '\0';  /* default → run as root */

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
        p += wd_len;
        out += wd_len + 1;
    }

    /* user (v3+ only ; v2 specs stop after workdir). */
    if (has_user && p + 4 <= end) {
        unsigned int user_len = read_u32_be(p); p += 4;
        if (user_len > 0 && p + user_len <= end
            && user_len < sizeof(user_spec)) {
            memcpy(user_spec, p, user_len);
            user_spec[user_len] = '\0';
        }
        p += user_len;
    }

    /* caps (v4+) : privileged byte + cap_add list + cap_drop list. */
    if (has_caps && p + 1 <= end) {
        privileged_spec = (*p != 0); p += 1;
        /* cap_add */
        if (p + 4 > end) return n;
        unsigned int n_add = read_u32_be(p); p += 4;
        for (unsigned int i = 0; i < n_add && i < 64; i++) {
            if (p + 4 > end) break;
            int cap_num = (int)read_u32_be(p); p += 4;
            cap_add_spec[cap_add_spec_len++] = cap_num;
        }
        /* cap_drop */
        if (p + 4 > end) return n;
        unsigned int n_drop = read_u32_be(p); p += 4;
        for (unsigned int i = 0; i < n_drop && i < 64; i++) {
            if (p + 4 > end) break;
            int cap_num = (int)read_u32_be(p); p += 4;
            cap_drop_spec[cap_drop_spec_len++] = cap_num;
        }
    }

    /* stop signal (v5+) : POSIX signal number. 0 = use init's default. */
    if (has_stop && p + 4 <= end) {
        stop_signal_spec = (int)read_u32_be(p); p += 4;
    }

    /* tty + geometry (v6+). Without a controlling terminal the container's
     * main process sees isatty() == false, so shells run non-interactive and
     * anything that redraws is wrong. 0x0 means "keep the console's size". */
    if (has_tty && p + 1 <= end) {
        tty_spec = (*p != 0); p += 1;
        if (p + 8 <= end) {
            tty_rows_spec = (int)read_u32_be(p); p += 4;
            tty_cols_spec = (int)read_u32_be(p); p += 4;
        }
    }

    /* v7 : read-only root, tmpfs mounts, extra hosts, DNS. Four flags the
     * CLI accepted and nothing honoured. Each list is length-prefixed, and
     * `out`/`strings` is the same arena argv and env already point into, so
     * these survive for the life of the process. */
    if (has_v7 && p + 1 <= end) {
        read_only_spec = (*p != 0); p += 1;

        struct { char **arr; int *len; int max; } lists[] = {
            { tmpfs_spec,      &tmpfs_spec_len,      SPEC_LIST_MAX },
            { add_host_spec,   &add_host_spec_len,   SPEC_LIST_MAX },
            { dns_spec,        &dns_spec_len,        SPEC_LIST_MAX },
            { dns_search_spec, &dns_search_spec_len, SPEC_LIST_MAX },
        };
        for (unsigned int li = 0; li < sizeof(lists) / sizeof(lists[0]); li++) {
            if (p + 4 > end) break;
            unsigned int count = read_u32_be(p); p += 4;
            for (unsigned int i = 0; i < count; i++) {
                if (p + 4 > end) break;
                unsigned int len = read_u32_be(p); p += 4;
                if (p + len > end) break;
                if (out + len + 1 > sizeof(strings)) break;
                memcpy(strings + out, p, len);
                strings[out + len] = '\0';
                if (*lists[li].len < lists[li].max)
                    lists[li].arr[(*lists[li].len)++] = strings + out;
                out += len + 1;
                p += len;
            }
        }
    }

    return n;
}
