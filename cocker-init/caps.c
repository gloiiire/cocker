/*
 * caps.c — Linux capability gymnastics for cocker-init.
 *
 * Cocker mirrors Docker's default container set : a hand-picked 14 caps
 * deemed safe enough for everyday workloads. `--cap-add` widens the
 * bounded set ; `--cap-drop` narrows it. `--privileged` keeps the full
 * kernel set (40+ caps).
 *
 * We don't link libcap (would balloon the static binary and pull in NSS
 * machinery). Instead we drive the bounded set directly with
 * prctl(PR_CAPBSET_DROP) and read the per-cap names through a small
 * static table. The permitted/effective sets are not touched — the
 * child execvp's as root by default, so they take their values from the
 * bounded set at exec time.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <linux/capability.h>

#include "cocker_init.h"

/* Docker's default container set, by cap number. Keep in sync with
 * https://docs.docker.com/engine/reference/run/#runtime-privilege-and-linux-capabilities */
static const int default_caps[] = {
    CAP_CHOWN,            // 0
    CAP_DAC_OVERRIDE,     // 1
    CAP_FOWNER,           // 3
    CAP_FSETID,           // 4
    CAP_KILL,             // 5
    CAP_SETGID,           // 6
    CAP_SETUID,           // 7
    CAP_SETPCAP,          // 8
    CAP_NET_BIND_SERVICE, // 10
    CAP_NET_RAW,          // 13
    CAP_SYS_CHROOT,       // 18
    CAP_MKNOD,            // 27
    CAP_AUDIT_WRITE,      // 29
    CAP_SETFCAP,          // 31
};
#define DEFAULT_CAPS_LEN (sizeof(default_caps) / sizeof(default_caps[0]))

/* String name (without "CAP_" prefix, uppercase) → integer. Returns -1 on
 * unknown name. We mirror Docker semantics : accept both "NET_ADMIN" and
 * "CAP_NET_ADMIN". */
int cap_resolve_name(const char *name) {
    if (!name || !*name) return -1;
    if (strncmp(name, "CAP_", 4) == 0) name += 4;

#define M(n) if (strcmp(name, #n) == 0) return CAP_##n
    M(CHOWN); M(DAC_OVERRIDE); M(DAC_READ_SEARCH); M(FOWNER); M(FSETID);
    M(KILL); M(SETGID); M(SETUID); M(SETPCAP); M(LINUX_IMMUTABLE);
    M(NET_BIND_SERVICE); M(NET_BROADCAST); M(NET_ADMIN); M(NET_RAW);
    M(IPC_LOCK); M(IPC_OWNER); M(SYS_MODULE); M(SYS_RAWIO); M(SYS_CHROOT);
    M(SYS_PTRACE); M(SYS_PACCT); M(SYS_ADMIN); M(SYS_BOOT); M(SYS_NICE);
    M(SYS_RESOURCE); M(SYS_TIME); M(SYS_TTY_CONFIG); M(MKNOD); M(LEASE);
    M(AUDIT_WRITE); M(AUDIT_CONTROL); M(SETFCAP); M(MAC_OVERRIDE);
    M(MAC_ADMIN); M(SYSLOG); M(WAKE_ALARM); M(BLOCK_SUSPEND); M(AUDIT_READ);
    M(PERFMON); M(BPF); M(CHECKPOINT_RESTORE);
#undef M
    return -1;
}

static int cap_in_array(const int *arr, int len, int cap) {
    for (int i = 0; i < len; i++) if (arr[i] == cap) return 1;
    return 0;
}

/* Apply the resolved cap policy : build the final allowed set from
 * (defaults + caps_add) − caps_drop, then drop every cap NOT in the
 * final set from the bounded set. Privileged mode is a no-op.
 *
 * Note : on a static-musl Linux kernel, CAP_LAST_CAP isn't necessarily
 * available at compile time. We probe up to a safe ceiling (60) and stop
 * at the first cap the kernel refuses (EINVAL) — that's the de-facto
 * boundary on the running kernel. */
void caps_apply(int privileged,
                const int *cap_add, int cap_add_len,
                const int *cap_drop, int cap_drop_len) {
    if (privileged) {
        info("caps: privileged mode, keeping full kernel set");
        return;
    }

    /* Build allowed = defaults ∪ cap_add − cap_drop. */
    int allowed[64];
    int allowed_len = 0;
    for (int i = 0; i < (int)DEFAULT_CAPS_LEN; i++) {
        if (!cap_in_array(cap_drop, cap_drop_len, default_caps[i])) {
            allowed[allowed_len++] = default_caps[i];
        }
    }
    for (int i = 0; i < cap_add_len; i++) {
        if (!cap_in_array(allowed, allowed_len, cap_add[i])
            && !cap_in_array(cap_drop, cap_drop_len, cap_add[i])) {
            allowed[allowed_len++] = cap_add[i];
        }
    }

    /* Drop every cap NOT in `allowed` from the bounded set. The kernel
     * silently caps the inheritable/effective sets to a subset of the
     * bounded set on the next execve, which is what we want for security
     * without touching capset() ourselves. */
    int dropped = 0;
    for (int cap = 0; cap < 60; cap++) {
        if (cap_in_array(allowed, allowed_len, cap)) continue;
        int rc = prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
        if (rc == 0) {
            dropped++;
        } else if (errno == EINVAL) {
            /* Reached the end of caps the running kernel knows about. */
            break;
        }
        /* EPERM means we don't have CAP_SETPCAP — bail loudly rather
         * than half-apply the policy. */
        if (rc < 0 && errno == EPERM) {
            info("caps: PR_CAPBSET_DROP(%d): %s (need CAP_SETPCAP)", cap, strerror(errno));
            return;
        }
    }
    info("caps: bounded set narrowed (%d caps allowed, %d dropped)",
         allowed_len, dropped);
}
