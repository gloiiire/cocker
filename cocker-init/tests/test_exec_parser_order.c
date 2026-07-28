/*
 * test_exec_parser_order.c — correctness test for the in-VM exec JSON
 * scanner in exec_listener.c.
 *
 * The fuzz harness (fuzz_exec_parser.c) only proves the parser never
 * crashes / leaks. It never asserts that `cmd`, `env` and `tty` are actually
 * recovered — which is exactly how the order-dependent PTY bug survived :
 * Swift's JSONEncoder emits the three top-level keys in a per-process random
 * order, and the old parser only saw `tty` when it preceded `cmd` and `env`
 * when it followed `cmd`. A given daemon boot could therefore drop the PTY
 * (or the environment) for its whole lifetime.
 *
 * This test drives the parser with all six key orderings plus a couple of
 * adversarial argument values and asserts full recovery each time.
 *
 * Build & run :
 *   clang -g -O1 -fsanitize=address -Wall -Werror \
 *         cocker-init/tests/test_exec_parser_order.c -o /tmp/test_exec_parser_order
 *   /tmp/test_exec_parser_order
 *
 * NOTE : carries a synced copy of parse_exec_request + helpers, same
 * convention as fuzz_exec_parser.c. Keep all three in sync when the
 * production parser in exec_listener.c changes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXEC_BUF_SIZE   (256 * 1024)
#define MAX_ARGV        128
#define MAX_ENV         128

/* ---- synced copy of exec_listener.c's parser + top_level_value ---- */
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

/* ---- test scaffolding ---- */
static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { fprintf(stderr, "  FAIL: %s\n", (msg)); failures++; } \
} while (0)

/* Is "KEY=VALUE" present in env_out ? */
static int env_has(char **env_out, const char *kv) {
    for (int i = 0; env_out[i]; i++) {
        if (strcmp(env_out[i], kv) == 0) return 1;
    }
    return 0;
}

static void free_env(char **env_out) {
    for (int i = 0; env_out[i]; i++) free(env_out[i]);
}

/* Run the parser on `json` and assert the full expected exec request :
 * argv == ["sh","-c","echo hi"], tty == 1, env == {FOO=bar, PATH=/usr/bin}. */
static void expect_full(const char *label, const char *json) {
    char buf[EXEC_BUF_SIZE];
    size_t n = strlen(json);
    memcpy(buf, json, n + 1);

    char *argv[MAX_ARGV];
    char *env_out[MAX_ENV];
    int tty = 0;
    int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);

    fprintf(stderr, "case: %s\n", label);
    CHECK(argc == 3, "argc should be 3");
    if (argc == 3) {
        CHECK(strcmp(argv[0], "sh") == 0, "argv[0] == sh");
        CHECK(strcmp(argv[1], "-c") == 0, "argv[1] == -c");
        CHECK(strcmp(argv[2], "echo hi") == 0, "argv[2] == echo hi");
    }
    CHECK(tty == 1, "tty should be 1");
    CHECK(env_has(env_out, "FOO=bar"), "env should contain FOO=bar");
    CHECK(env_has(env_out, "PATH=/usr/bin"), "env should contain PATH=/usr/bin");
    if (argc > 0) free_env(env_out);
}

int main(void) {
    /* The six key orderings JSONEncoder may emit for {cmd, env, tty}. */
    expect_full("cmd,env,tty",
        "{\"cmd\":[\"sh\",\"-c\",\"echo hi\"],\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"},\"tty\":true}\n");
    expect_full("cmd,tty,env",
        "{\"cmd\":[\"sh\",\"-c\",\"echo hi\"],\"tty\":true,\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"}}\n");
    expect_full("env,cmd,tty",
        "{\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"},\"cmd\":[\"sh\",\"-c\",\"echo hi\"],\"tty\":true}\n");
    expect_full("env,tty,cmd",
        "{\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"},\"tty\":true,\"cmd\":[\"sh\",\"-c\",\"echo hi\"]}\n");
    expect_full("tty,cmd,env",
        "{\"tty\":true,\"cmd\":[\"sh\",\"-c\",\"echo hi\"],\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"}}\n");
    expect_full("tty,env,cmd",
        "{\"tty\":true,\"env\":{\"FOO\":\"bar\",\"PATH\":\"/usr/bin\"},\"cmd\":[\"sh\",\"-c\",\"echo hi\"]}\n");

    /* Regression : a command literally named `tty` must NOT enable the PTY
     * just because the bytes `"tty"` appear inside the cmd array. */
    {
        char buf[EXEC_BUF_SIZE];
        const char *json = "{\"cmd\":[\"tty\"],\"env\":{}}\n";
        size_t n = strlen(json); memcpy(buf, json, n + 1);
        char *argv[MAX_ARGV]; char *env_out[MAX_ENV]; int tty = 0;
        int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
        fprintf(stderr, "case: cmd=[tty] (no tty field)\n");
        CHECK(argc == 1 && strcmp(argv[0], "tty") == 0, "argv[0] == tty");
        CHECK(tty == 0, "tty must stay 0 for `exec c tty`");
        if (argc > 0) free_env(env_out);
    }

    /* Regression : a command literally named `env` must NOT be mistaken for
     * the env object ; a real tty field after it must still be honored. */
    {
        char buf[EXEC_BUF_SIZE];
        const char *json = "{\"cmd\":[\"env\"],\"tty\":true}\n";
        size_t n = strlen(json); memcpy(buf, json, n + 1);
        char *argv[MAX_ARGV]; char *env_out[MAX_ENV]; int tty = 0;
        int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
        fprintf(stderr, "case: cmd=[env] tty=true (no env field)\n");
        CHECK(argc == 1 && strcmp(argv[0], "env") == 0, "argv[0] == env");
        CHECK(tty == 1, "tty must be honored after cmd=[env]");
        CHECK(env_out[0] == NULL, "env must be empty for `exec c env`");
        if (argc > 0) free_env(env_out);
    }

    /* Regression (found by adversarial review) : an environment variable
     * literally named `tty` must NOT steal the top-level `tty` field. With
     * .sortedKeys the env object is emitted before the top-level tty, so a
     * naive "first `tty` outside the cmd span" search would read the nested
     * env key/value and drop the PTY. */
    {
        char buf[EXEC_BUF_SIZE];
        const char *json = "{\"cmd\":[\"sh\"],\"env\":{\"tty\":\"x\"},\"tty\":true}\n";
        size_t n = strlen(json); memcpy(buf, json, n + 1);
        char *argv[MAX_ARGV]; char *env_out[MAX_ENV]; int tty = 0;
        int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
        fprintf(stderr, "case: env has key named tty, top-level tty=true\n");
        CHECK(argc == 1 && strcmp(argv[0], "sh") == 0, "argv[0] == sh");
        CHECK(tty == 1, "top-level tty must win over nested env key 'tty'");
        CHECK(env_has(env_out, "tty=x"), "env should still contain tty=x");
        if (argc > 0) free_env(env_out);
    }

    /* Regression : an env var named `env`, plus a top-level tty. */
    {
        char buf[EXEC_BUF_SIZE];
        const char *json = "{\"cmd\":[\"sh\"],\"env\":{\"env\":\"y\"},\"tty\":true}\n";
        size_t n = strlen(json); memcpy(buf, json, n + 1);
        char *argv[MAX_ARGV]; char *env_out[MAX_ENV]; int tty = 0;
        int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
        fprintf(stderr, "case: env has key named env, top-level tty=true\n");
        CHECK(tty == 1, "top-level tty must be honored");
        CHECK(env_has(env_out, "env=y"), "env should contain env=y");
        if (argc > 0) free_env(env_out);
    }

    /* Regression : an env VALUE containing the text `tty` and no top-level
     * tty field must leave tty disabled. */
    {
        char buf[EXEC_BUF_SIZE];
        const char *json = "{\"cmd\":[\"sh\"],\"env\":{\"FOO\":\"tty\"}}\n";
        size_t n = strlen(json); memcpy(buf, json, n + 1);
        char *argv[MAX_ARGV]; char *env_out[MAX_ENV]; int tty = 0;
        int argc = parse_exec_request(buf, n, argv, MAX_ARGV, env_out, MAX_ENV, &tty);
        fprintf(stderr, "case: env value contains 'tty', no top-level tty\n");
        CHECK(tty == 0, "tty must stay 0 when only an env value contains 'tty'");
        CHECK(env_has(env_out, "FOO=tty"), "env should contain FOO=tty");
        if (argc > 0) free_env(env_out);
    }

    if (failures == 0) {
        fprintf(stderr, "\n\xe2\x9c\x85 all exec-parser ordering cases passed\n");
        return 0;
    }
    fprintf(stderr, "\n\xe2\x9d\x8c %d exec-parser assertion(s) failed\n", failures);
    return 1;
}
