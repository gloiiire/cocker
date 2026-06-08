/*
 * etc_overlay.c — workaround Apple's virtiofs bug that breaks shadow-utils.
 *
 * Symptom : groupadd/useradd/usermod all fail with
 *   "failure while writing changes to /etc/{group,passwd}"
 * because Apple's virtiofsd leaves the atomic-replace temp file
 * (/etc/group+ etc.) in an inconsistent FUSE state — lstat() reports it
 * as a regular file with mode 0o000 and size 0, but open(O_RDONLY) on
 * the same path returns ENOENT. Confirmed with python:3.11-slim and
 * macOS 14/15. Apple's virtiofs is closed-source and we have no
 * control over the daemon-side implementation.
 *
 * Workaround : at boot, copy /etc into a fresh tmpfs and bind-mount the
 * tmpfs over /etc. shadow-utils' atomic-replace then runs entirely on
 * the Linux kernel's tmpfs and bypasses virtiofs.
 *
 * Persistence : at container exit, the tmpfs contents get copied back
 * into the virtiofs /etc so RUN-step modifications (added users,
 * package install configs, …) survive into the rootfs. Two exclusions :
 *   - /etc/resolv.conf : pinned at boot to cocker's DNS proxy
 *     (127.0.0.1), should NOT clobber the image's original.
 *   - /etc/hostname / /etc/hosts : runtime-only, same logic.
 *
 * Memory cost : tmpfs caps at 64 MiB (way more than any sane /etc).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include "cocker_init.h"

#define ETC_OVERLAY_DIR  "/run/cocker-etc"
#define COPY_BUF_SIZE    (64 * 1024)

/* Sync-back skip list : files cocker-init or the runtime writes that
 * should NOT be persisted into the image rootfs. */
static int should_skip_on_sync(const char *relpath) {
    static const char *blacklist[] = {
        "resolv.conf",
        "hostname",
        "hosts",
        NULL
    };
    for (int i = 0; blacklist[i]; i++) {
        if (strcmp(relpath, blacklist[i]) == 0) return 1;
    }
    return 0;
}

/* read/write a regular file's bytes. Returns 0 on success, -1 on error. */
static int copy_file_data(int sfd, int dfd) {
    char buf[COPY_BUF_SIZE];
    ssize_t n;
    while ((n = read(sfd, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dfd, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += w;
        }
    }
    return n < 0 ? -1 : 0;
}

/* Recursively copy `src` into `dst`. Handles regular files, directories,
 * and symlinks (not following them — preserves the link). Skip filter
 * applies only at top level via the `relpath` argument propagated by the
 * caller. Best-effort : individual file failures are logged, not fatal. */
static int copy_tree(const char *src, const char *dst, int apply_skip) {
    DIR *d = opendir(src);
    if (!d) {
        info("etc-overlay: opendir(%s): %s", src, strerror(errno));
        return -1;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;

        if (apply_skip && should_skip_on_sync(e->d_name))
            continue;

        char srcp[4096], dstp[4096];
        snprintf(srcp, sizeof(srcp), "%s/%s", src, e->d_name);
        snprintf(dstp, sizeof(dstp), "%s/%s", dst, e->d_name);

        struct stat st;
        if (lstat(srcp, &st) < 0) {
            info("etc-overlay: lstat(%s): %s", srcp, strerror(errno));
            continue;
        }

        if (S_ISDIR(st.st_mode)) {
            if (mkdir(dstp, st.st_mode & 0777) < 0 && errno != EEXIST) {
                info("etc-overlay: mkdir(%s): %s", dstp, strerror(errno));
                continue;
            }
            chown(dstp, st.st_uid, st.st_gid);
            chmod(dstp, st.st_mode & 07777);
            copy_tree(srcp, dstp, 0);  // skip filter is top-level only
        } else if (S_ISLNK(st.st_mode)) {
            char target[4096];
            ssize_t n = readlink(srcp, target, sizeof(target) - 1);
            if (n <= 0) continue;
            target[n] = '\0';
            unlink(dstp);  // remove dst if it exists, symlink fails on EEXIST
            if (symlink(target, dstp) == 0) {
                lchown(dstp, st.st_uid, st.st_gid);
            }
        } else if (S_ISREG(st.st_mode)) {
            int sfd = open(srcp, O_RDONLY);
            if (sfd < 0) continue;
            int dfd = open(dstp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (dfd < 0) { close(sfd); continue; }
            if (copy_file_data(sfd, dfd) == 0) {
                fchmod(dfd, st.st_mode & 07777);
                fchown(dfd, st.st_uid, st.st_gid);
            }
            close(sfd);
            close(dfd);
        }
        // Skip devices/FIFOs/sockets — never seen in /etc on standard images
    }
    closedir(d);
    return 0;
}

/* Boot-time hook : copy /etc → tmpfs, bind tmpfs over /etc.
 * Called from init.c after switch_to_virtiofs(), BEFORE pin_resolv_conf
 * so the pin lands on the tmpfs version. */
void etc_overlay_setup(void) {
    if (mkdir(ETC_OVERLAY_DIR, 0755) < 0 && errno != EEXIST) {
        info("etc-overlay: mkdir %s: %s", ETC_OVERLAY_DIR, strerror(errno));
        return;
    }
    if (mount("tmpfs", ETC_OVERLAY_DIR, "tmpfs",
              MS_NOSUID | MS_NODEV, "size=64m") < 0) {
        info("etc-overlay: mount tmpfs: %s", strerror(errno));
        return;
    }
    if (copy_tree("/etc", ETC_OVERLAY_DIR, 0) < 0) {
        info("etc-overlay: copy /etc → tmpfs failed (continuing without overlay)");
        umount2(ETC_OVERLAY_DIR, MNT_DETACH);
        return;
    }
    if (mount(ETC_OVERLAY_DIR, "/etc", NULL, MS_BIND, NULL) < 0) {
        info("etc-overlay: bind %s → /etc: %s",
             ETC_OVERLAY_DIR, strerror(errno));
        umount2(ETC_OVERLAY_DIR, MNT_DETACH);
        return;
    }
    info("etc-overlay: tmpfs bind-mounted on /etc (virtiofs bug workaround)");
}

/* Exit-time hook : umount the bind to expose virtiofs /etc, copy tmpfs
 * contents back so RUN modifications persist. Called from init.c just
 * before sync()+reboot(). Skips runtime-only files (resolv.conf etc.).
 *
 * Safe to call even if etc_overlay_setup() never ran or failed — the
 * umount2 will return EINVAL and we bail out cleanly. */
void etc_overlay_sync_back(void) {
    if (umount2("/etc", 0) < 0) {
        // Either the overlay never set up, or someone else holds /etc.
        // Either way, no sync-back is possible.
        return;
    }
    copy_tree(ETC_OVERLAY_DIR, "/etc", 1);  // apply skip filter for resolv.conf etc.
    umount2(ETC_OVERLAY_DIR, MNT_DETACH);
    info("etc-overlay: synced back to virtiofs (resolv.conf preserved)");
}
