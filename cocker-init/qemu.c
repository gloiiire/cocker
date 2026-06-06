/*
 * qemu.c — register QEMU user-mode emulators with binfmt_misc.
 *
 * `cocker buildx build --platform linux/amd64` on an arm64 host needs the
 * kernel to know "when you execute an x86_64 ELF, run /opt/cocker/qemu/qemu-
 * x86_64-static <the binary> instead". This is what binfmt_misc was built for.
 *
 * The QEMU binary itself is shipped by cockerd via a virtiofs share. cockerd
 * passes its in-VM path via two cmdline params :
 *
 *   cocker.qemu_arch=x86_64        (one of x86_64, aarch64, riscv64, …)
 *   cocker.qemu_path=/opt/cocker/qemu/qemu-x86_64-static
 *
 * If either is missing we silently skip — the common case (native builds) is
 * always supported and we don't want the VM to fail because qemu wasn't shipped.
 */

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cocker_init.h"

/* Magic / mask strings copied from qemu-user-static upstream `qemu-binfmt-conf.sh` */
struct binfmt_entry {
    const char *arch;
    const char *magic;
    const char *mask;
    int offset;
};

static const struct binfmt_entry table[] = {
    /* x86_64 ELF */
    { "x86_64",
      "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00",
      "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff",
      0 },
    /* aarch64 ELF (running on x86_64 host) */
    { "aarch64",
      "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00",
      "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff",
      0 },
    /* riscv64 ELF */
    { "riscv64",
      "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xf3\\x00",
      "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff",
      0 },
    { NULL, NULL, NULL, 0 }
};

static const struct binfmt_entry *find_entry(const char *arch) {
    for (const struct binfmt_entry *e = table; e->arch; e++) {
        if (strcmp(e->arch, arch) == 0) return e;
    }
    return NULL;
}

void qemu_register_binfmt(const char *cmdline) {
    char *arch = cmdline_get(cmdline, "qemu_arch");
    char *path = cmdline_get(cmdline, "qemu_path");
    if (!arch || !path) {
        free(arch); free(path);
        return;  /* not a cross-platform build */
    }

    const struct binfmt_entry *e = find_entry(arch);
    if (!e) {
        info("qemu: unknown arch %s, skipping binfmt registration", arch);
        free(arch); free(path);
        return;
    }

    /* Mount binfmt_misc if not already mounted. /proc/sys/fs/binfmt_misc
     * is normally registered automatically when CONFIG_BINFMT_MISC is
     * built in, but the userland sysfs view requires the binfmt_misc
     * filesystem to be mounted. */
    mkdir("/proc/sys/fs/binfmt_misc", 0755);
    if (mount("binfmt_misc", "/proc/sys/fs/binfmt_misc", "binfmt_misc",
              0, NULL) < 0 && errno != EBUSY) {
        info("qemu: mount binfmt_misc: %s", strerror(errno));
        free(arch); free(path);
        return;
    }

    int fd = open("/proc/sys/fs/binfmt_misc/register", O_WRONLY);
    if (fd < 0) {
        info("qemu: open binfmt_misc/register: %s", strerror(errno));
        free(arch); free(path);
        return;
    }

    /* Wire format : :name:type:offset:magic:mask:interpreter:flags */
    char line[2048];
    int n = snprintf(line, sizeof(line),
        ":qemu-%s:M:%d:%s:%s:%s:OC",
        e->arch, e->offset, e->magic, e->mask, path);
    if (n > 0 && (size_t)n < sizeof(line)) {
        if (write(fd, line, n) < 0) {
            info("qemu: register %s: %s", e->arch, strerror(errno));
        } else {
            info("qemu: registered binfmt_misc handler for %s → %s",
                 e->arch, path);
        }
    }
    close(fd);

    free(arch); free(path);
}
