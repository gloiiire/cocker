/*
 * cocker-init — minimal Linux init (PID 1) for cocker containers
 *
 * Boot sequence:
 *   1. Mount /proc, /sys, /dev as virtual filesystems
 *   2. Read /proc/cmdline to get cocker.* params from cockerd
 *   3. Mount the virtiofs share "root" as the rootfs
 *   4. switch_root into it
 *   5. Setup hostname, env vars from cmdline
 *   6. exec the container's command
 *
 * Cross-compile from macOS:
 *   zig cc -target aarch64-linux-musl -static -O2 -o cocker-init init.c
 *
 * The output is then packaged into an initrd cpio archive.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <errno.h>

#define die(fmt, ...) do { \
    fprintf(stderr, "[cocker-init] FATAL: " fmt "\n", ##__VA_ARGS__); \
    sleep(2); \
    reboot(RB_HALT_SYSTEM); \
    _exit(1); \
} while (0)

#define info(fmt, ...) fprintf(stderr, "[cocker-init] " fmt "\n", ##__VA_ARGS__)

/* Read /proc/cmdline into a buffer */
static int read_cmdline(char *buf, size_t size) {
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    /* Strip trailing newline */
    char *nl = strchr(buf, '\n');
    if (nl) *nl = '\0';
    return 0;
}

/* Find a cocker.KEY=VALUE in cmdline. Returns malloc'd value, or NULL */
static char *cmdline_get(const char *cmdline, const char *key) {
    char needle[256];
    snprintf(needle, sizeof(needle), "cocker.%s=", key);
    const char *p = cmdline;
    size_t needle_len = strlen(needle);

    while ((p = strstr(p, needle))) {
        /* Must be at start or preceded by space */
        if (p != cmdline && p[-1] != ' ') {
            p += needle_len;
            continue;
        }
        const char *start = p + needle_len;
        const char *end = strchr(start, ' ');
        size_t len = end ? (size_t)(end - start) : strlen(start);
        char *value = malloc(len + 1);
        if (!value) return NULL;
        memcpy(value, start, len);
        value[len] = '\0';
        return value;
    }
    return NULL;
}

/* Iterate all cocker.env.KEY=VALUE from cmdline and setenv() them
 * (legacy — env vient maintenant de /cocker-spec) */
__attribute__((unused))
static void setup_env_from_cmdline(const char *cmdline) {
    const char *p = cmdline;
    while ((p = strstr(p, "cocker.env."))) {
        if (p != cmdline && p[-1] != ' ') { p += 11; continue; }
        const char *key_start = p + 11;
        const char *eq = strchr(key_start, '=');
        if (!eq) break;
        const char *val_end = strchr(eq, ' ');
        size_t val_len = val_end ? (size_t)(val_end - eq - 1) : strlen(eq + 1);
        size_t key_len = eq - key_start;
        char key[128], val[1024];
        if (key_len >= sizeof(key)) { p = eq; continue; }
        memcpy(key, key_start, key_len); key[key_len] = '\0';
        if (val_len >= sizeof(val)) val_len = sizeof(val) - 1;
        memcpy(val, eq + 1, val_len); val[val_len] = '\0';
        setenv(key, val, 1);
        p = val_end ? val_end : eq + 1 + val_len;
    }
}

/* Tokenize a command string into argv[]
 * (legacy — argv vient maintenant de /cocker-spec NUL-séparé) */
__attribute__((unused))
static int parse_argv(char *cmd, char **argv, int max) {
    int argc = 0;
    char *p = cmd;
    while (*p && argc < max - 1) {
        while (*p == ' ') p++;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ') p++;
        if (*p) *p++ = '\0';
    }
    argv[argc] = NULL;
    return argc;
}

/* Mount the virtiofs rootfs tag "root" at /newroot, then switch_root */
static void switch_to_virtiofs(void) {
    if (mkdir("/newroot", 0755) < 0 && errno != EEXIST)
        die("mkdir /newroot: %s", strerror(errno));

    if (mount("root", "/newroot", "virtiofs", 0, NULL) < 0)
        die("mount virtiofs /newroot: %s", strerror(errno));

    info("virtiofs rootfs mounted at /newroot");

    /* Move /proc, /sys, /dev into the new root */
    mkdir("/newroot/proc", 0755);
    mkdir("/newroot/sys", 0755);
    mkdir("/newroot/dev", 0755);
    mkdir("/newroot/run", 0755);
    mkdir("/newroot/tmp", 0755);

    mount("/proc", "/newroot/proc", NULL, MS_MOVE, NULL);
    mount("/sys",  "/newroot/sys",  NULL, MS_MOVE, NULL);
    mount("/dev",  "/newroot/dev",  NULL, MS_MOVE, NULL);

    /* tmpfs for /tmp and /run */
    mount("tmpfs", "/newroot/run", "tmpfs", MS_NOSUID | MS_NODEV,
          "mode=755,size=64m");
    mount("tmpfs", "/newroot/tmp", "tmpfs", MS_NOSUID | MS_NODEV,
          "mode=1777,size=64m");

    /* chdir + chroot equivalent of pivot_root */
    if (chdir("/newroot") < 0) die("chdir /newroot: %s", strerror(errno));
    if (mount("/newroot", "/", NULL, MS_MOVE, NULL) < 0)
        die("move /newroot to /: %s", strerror(errno));
    if (chroot(".") < 0) die("chroot: %s", strerror(errno));
    if (chdir("/") < 0) die("chdir /: %s", strerror(errno));
}

/* Mount additional volume virtiofs shares (vol0, vol1, ...) at the paths
 * specified in cmdline: cocker.vol0=vol0:/data */
static void mount_volumes(const char *cmdline) {
    for (int i = 0; i < 32; i++) {
        char key[16];
        snprintf(key, sizeof(key), "vol%d", i);
        char *spec = cmdline_get(cmdline, key);
        if (!spec) break;

        /* spec format: "vol0:/path/in/container" */
        char *colon = strchr(spec, ':');
        if (!colon) { free(spec); continue; }
        *colon = '\0';
        const char *tag = spec;
        const char *path = colon + 1;

        /* mkdir -p path */
        char tmp[512];
        snprintf(tmp, sizeof(tmp), "%s", path);
        for (char *p = tmp + 1; *p; p++) {
            if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
        }
        mkdir(tmp, 0755);

        if (mount(tag, path, "virtiofs", 0, NULL) < 0)
            info("mount %s -> %s failed: %s", tag, path, strerror(errno));
        else
            info("mounted volume %s at %s", tag, path);
        free(spec);
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    /* Bring up initial /proc, /sys, /dev before reading cmdline */
    mkdir("/proc", 0755);
    mkdir("/sys",  0755);
    mkdir("/dev",  0755);

    if (mount("proc",     "/proc", "proc",     0, NULL) < 0)
        die("mount /proc: %s", strerror(errno));
    if (mount("sysfs",    "/sys",  "sysfs",    0, NULL) < 0)
        die("mount /sys: %s", strerror(errno));
    if (mount("devtmpfs", "/dev",  "devtmpfs", 0, NULL) < 0)
        info("mount /dev: %s (continuing)", strerror(errno));

    char cmdline[4096];
    if (read_cmdline(cmdline, sizeof(cmdline)) < 0)
        die("read /proc/cmdline: %s", strerror(errno));

    info("booted from kernel cmdline");

    /* Read container ID/name for logging */
    char *cid  = cmdline_get(cmdline, "id");
    char *name = cmdline_get(cmdline, "name");
    info("container id=%s name=%s", cid ? cid : "?", name ? name : "?");

    /* Setup hostname */
    char *hostname = cmdline_get(cmdline, "hostname");
    if (hostname) {
        sethostname(hostname, strlen(hostname));
        info("hostname=%s", hostname);
        free(hostname);
    } else if (name) {
        sethostname(name, strlen(name));
    }

    /* Switch to the virtiofs rootfs */
    switch_to_virtiofs();

    /* Mount any volume shares */
    mount_volumes(cmdline);

    /*
     * Lit /cocker-spec écrit par cockerd avant le boot.
     * Format (3 lignes, chaque champ NUL-séparé) :
     *   argv0\0argv1\0...\n
     *   env0\0env1\0...\n
     *   workdir\n
     * Plus robuste que la kernel cmdline (qui mange les espaces/quotes).
     */
    char *child_argv[128];
    int argc_count = 0;
    int spec_fd = open("/cocker-spec", O_RDONLY);
    if (spec_fd < 0) {
        info("no /cocker-spec found, defaulting to /bin/sh");
        child_argv[0] = "/bin/sh";
        child_argv[1] = NULL;
        argc_count = 1;
    } else {
        static char spec_buf[65536];
        ssize_t spec_len = read(spec_fd, spec_buf, sizeof(spec_buf) - 1);
        close(spec_fd);
        if (spec_len < 0) die("read /cocker-spec: %s", strerror(errno));
        spec_buf[spec_len] = '\0';

        /* Ligne 1 : argv (champs NUL séparés, ligne terminée par \n) */
        char *p = spec_buf;
        char *line_end = memchr(p, '\n', spec_len);
        if (line_end) {
            *line_end = '\0';  /* termine la ligne pour les strlen() suivants */
            char *q = p;
            while (q < line_end && argc_count < 127) {
                child_argv[argc_count++] = q;
                q += strlen(q) + 1;  /* saute le NUL séparateur */
            }
            child_argv[argc_count] = NULL;
            p = line_end + 1;
        }

        /* Ligne 2 : env (KEY=VALUE NUL séparés, ligne terminée par \n) */
        ssize_t remaining = spec_buf + spec_len - p;
        line_end = remaining > 0 ? memchr(p, '\n', remaining) : NULL;
        if (line_end) {
            *line_end = '\0';
            char *q = p;
            while (q < line_end) {
                if (*q && strchr(q, '=')) {
                    putenv(q);  /* le buffer static reste valide pour l'environnement */
                }
                q += strlen(q) + 1;
            }
            p = line_end + 1;
        }

        /* Ligne 3 : workdir */
        remaining = spec_buf + spec_len - p;
        line_end = remaining > 0 ? memchr(p, '\n', remaining) : NULL;
        if (line_end) {
            *line_end = '\0';
            if (*p && chdir(p) < 0)
                info("chdir %s failed: %s", p, strerror(errno));
        }
    }

    if (argc_count == 0 || child_argv[0] == NULL)
        die("empty command in /cocker-spec");

    info("exec: %s (argc=%d)", child_argv[0], argc_count);

    /* exec the container's command as PID 1 */
    execvp(child_argv[0], child_argv);

    /* If we get here, exec failed */
    die("execvp %s: %s", child_argv[0], strerror(errno));
}
