/*
 * fuzz_exec_parser.c — libFuzzer harness for the in-VM JSON scanner used
 * by exec_listener.c.
 *
 * The real parser sits inside exec_listener.c and depends on Linux headers
 * (`linux/vm_sockets.h`, `pty.h`). We can't link those on macOS where the
 * developer runs `swift test`, so this file carries a verbatim copy of
 * `parse_exec_request` — small enough that the duplication cost is lower
 * than the cost of weaving conditional compilation into exec_listener.c.
 * When the real parser changes, sync this copy and re-run the fuzzer.
 *
 * Build & run :
 *
 *   clang -g -O1 -fsanitize=fuzzer,address \
 *         cocker-init/tests/fuzz_exec_parser.c \
 *         -o /tmp/fuzz_exec_parser
 *   /tmp/fuzz_exec_parser -max_len=4096 -timeout=10
 *
 * The harness drives the parser with the libFuzzer corpus interface :
 *   LLVMFuzzerTestOneInput(data, size)
 * Any crash / leak / heap-overflow trips ASAN and produces a crash file
 * the maintainer can replay with `./fuzz_exec_parser crash-…`.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXEC_BUF_SIZE   (256 * 1024)
#define MAX_ARGV        128
#define MAX_ENV         128

/* Verbatim copy of exec_listener.c's parse_exec_request (+ top_level_value)
 * — keep these synchronized when the production parser changes. */
static char *top_level_value(char *buf, const char *key) {
    char *p = strchr(buf, '{');
    if (!p) return NULL;
    p++;
    size_t keylen = strlen(key);
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',') p++;
        if (*p == '}' || *p == '\0') return NULL;
        if (*p != '"') return NULL;
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
            while (*p && *p != ',' && *p != '}' && *p != ']'
                   && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
        }
    }
    return NULL;
}

static int parse_exec_request(char *buf, size_t buf_len,
                              char **argv, int argv_max,
                              char **env_out, int env_max,
                              int *tty_out) {
    if (buf_len >= EXEC_BUF_SIZE) buf_len = EXEC_BUF_SIZE - 1;
    buf[buf_len] = '\0';

    *tty_out = 0;
    argv[0] = NULL;
    env_out[0] = NULL;

    char *cmd_open = top_level_value(buf, "cmd");
    if (!cmd_open || *cmd_open != '[') return 0;

    char *t = top_level_value(buf, "tty");
    if (t && *t == 't') *tty_out = 1;

    char *env_field = top_level_value(buf, "env");

    char *p = cmd_open + 1;
    int argc = 0;
    while (*p && argc < argv_max - 1) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t') p++;
        if (*p == ']') break;
        if (*p != '"') break;
        p++;
        char *start = p;
        char *write = p;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
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
        p++;
    }
    argv[argc] = NULL;
    if (argc == 0 || argv[0] == NULL || argv[0][0] == '\0') return 0;

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

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Bound the input to what the real listener accepts (parser
     * truncates at EXEC_BUF_SIZE anyway, but staying under it makes the
     * coverage signal cleaner). */
    if (size >= EXEC_BUF_SIZE) size = EXEC_BUF_SIZE - 1;
    static char scratch[EXEC_BUF_SIZE];
    memcpy(scratch, data, size);
    scratch[size] = '\0';

    char *argv[MAX_ARGV];
    char *env_out[MAX_ENV];
    int tty = 0;
    int rc = parse_exec_request(scratch, size, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
    /* Mirror the listener's free path so libFuzzer sees us release the
     * heap allocations (no leak finding on benign inputs). */
    if (rc > 0) {
        for (int i = 0; env_out[i]; i++) free(env_out[i]);
    }
    return 0;
}

#ifndef LIBFUZZER
/* Standalone main : useful for replaying a single crash file without
 * pulling in libFuzzer (`./fuzz_exec_parser crash-…`). */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { fclose(f); return 1; }
    size_t r = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    LLVMFuzzerTestOneInput(buf, r);
    free(buf);
    return 0;
}
#endif
