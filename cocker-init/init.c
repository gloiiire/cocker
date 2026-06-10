/*
 * cocker-init — minimal Linux init (PID 1) for cocker containers.
 *
 * Boot sequence :
 *   1.  Mount /proc, /sys, /dev as virtual filesystems
 *   2.  Read /proc/cmdline to get cocker.* params from cockerd
 *   3.  Set the hostname
 *   4.  Mount the virtiofs share "root" as the rootfs and switch_root into it
 *   5.  Mount additional volume virtiofs shares (vol0, vol1, …) at the paths
 *       passed via cocker.vol* cmdline params
 *   6.  Bring up lo + eth0 (DHCP) + eth1 (cocker switch fabric, static)
 *   7.  Spawn the in-VM DNS proxy (vsock to cockerd)
 *   8.  Pin /etc/resolv.conf to 127.0.0.1 so libc uses our proxy
 *   9.  Read /cocker-spec and exec the container's command
 *  10.  fork+wait pattern so PID 1 stays alive (prevents kernel panic)
 *  11.  When the container exits, reboot(RB_POWER_OFF)
 *
 * Cross-compile from macOS :
 *   zig cc -target aarch64-linux-musl -static -O2 -o cocker-init \
 *          init.c cmdline.c net.c dns_proxy.c spec.c
 *
 * The output is then packaged into an initrd cpio archive.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/reboot.h>
#include "cocker_init.h"

/* Set right before the child fork so the SIGTERM handler in PID 1 can
 * relay the container's STOPSIGNAL to it. Volatile because the handler
 * runs in async signal context. */
static volatile pid_t g_child_pid = 0;

/* SIGTERM handler installed only when stop_signal_spec is set. Forwards
 * the configured signal (e.g. SIGQUIT for nginx) to the container's main
 * process so STOPSIGNAL semantics actually reach the workload. */
static void forward_stop_signal_to_child(int sig) {
    /* Note : runs in async signal context — only write(2) is safe. We
     * skip fprintf/info() and emit one terse marker line so console
     * tail tells us the relay is alive. */
    const char *msg = "[cocker-init] forwarding stop signal to child\n";
    write(2, msg, strlen(msg));
    (void)sig;
    if (g_child_pid > 0 && stop_signal_spec > 0) {
        kill(g_child_pid, stop_signal_spec);
    }
}

/* Mount the virtiofs rootfs tag "root" at /newroot, then switch_root */
static void switch_to_virtiofs(void) {
    if (mkdir("/newroot", 0755) < 0 && errno != EEXIST)
        die("mkdir /newroot: %s", strerror(errno));

    if (mount("root", "/newroot", "virtiofs", 0, NULL) < 0)
        die("mount virtiofs /newroot: %s", strerror(errno));

    info("virtiofs rootfs mounted at /newroot");

    mkdir("/newroot/proc", 0755);
    mkdir("/newroot/sys", 0755);
    mkdir("/newroot/dev", 0755);
    mkdir("/newroot/run", 0755);
    mkdir("/newroot/tmp", 0755);

    mount("/proc", "/newroot/proc", NULL, MS_MOVE, NULL);
    mount("/sys",  "/newroot/sys",  NULL, MS_MOVE, NULL);
    mount("/dev",  "/newroot/dev",  NULL, MS_MOVE, NULL);

    mount("tmpfs", "/newroot/run", "tmpfs", MS_NOSUID | MS_NODEV,
          "mode=755,size=64m");
    mount("tmpfs", "/newroot/tmp", "tmpfs", MS_NOSUID | MS_NODEV,
          "mode=1777,size=64m");

    /* devpts : required for openpty()/openpty-allocated /dev/pts/N pairs.
     * Without this `cocker exec -t` fails at openpty() inside the listener. */
    mkdir("/newroot/dev/pts", 0755);
    mount("devpts", "/newroot/dev/pts", "devpts",
          MS_NOSUID | MS_NOEXEC,
          "mode=620,ptmxmode=000");

    if (chdir("/newroot") < 0) die("chdir /newroot: %s", strerror(errno));
    if (mount("/newroot", "/", NULL, MS_MOVE, NULL) < 0)
        die("move /newroot to /: %s", strerror(errno));
    if (chroot(".") < 0) die("chroot: %s", strerror(errno));
    if (chdir("/") < 0) die("chdir /: %s", strerror(errno));
}

/* Recursively mkdir all components of `path` (mkdir -p). */
static void mkdirp(const char *path) {
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

/* Detect whether the device already holds an ext4 (or ext2/3) filesystem.
 * The ext family stores its superblock at offset 1024 with magic 0xEF53
 * at offset 56 of the superblock (= absolute offset 1080). Any other
 * pattern means "format me". */
static int has_ext_fs(const char *device) {
    int fd = open(device, O_RDONLY);
    if (fd < 0) return 0;
    if (lseek(fd, 1080, SEEK_SET) < 0) { close(fd); return 0; }
    unsigned char buf[2] = {0};
    ssize_t n = read(fd, buf, 2);
    close(fd);
    return (n == 2 && buf[0] == 0x53 && buf[1] == 0xEF);
}

/* fork + execvp + wait. Returns the child's exit status, or -1 on
 * fork/exec failure. Used for one-shot helpers like mkfs.ext4 that
 * we don't keep around. Sets PATH explicitly in the child because
 * cocker-init (PID 1) inherits no environment from the kernel and
 * execvp's default search would otherwise miss /sbin (where Alpine
 * and Debian ship mkfs.ext4, useradd, etc.). */
static int run_cmd(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        execvp(argv[0], argv);
        // execvp returned → couldn't find the binary. Tell the caller
        // explicitly so the failure log includes which command was tried.
        fprintf(stderr, "[cocker-init] execvp(%s) failed: %s\n",
                argv[0], strerror(errno));
        _exit(127);
    }
    int status;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (!WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

/* Per-container volume mounts driven by the kernel cmdline.
 *
 * Spec format : `cocker.vol<N>=<type>:<source>:<target>`
 *   - type = "virtiofs"  → mount source as virtiofs tag (legacy, bind
 *                          mounts, also fallback for volumes created
 *                          before block storage).
 *   - type = "blk"       → mount source (a device path like /dev/vda)
 *                          as ext4. If the device has no filesystem
 *                          yet, mkfs.ext4 it from the image's PATH
 *                          first. Block storage is the default for
 *                          new named volumes since 0.5.13 — fixes
 *                          chown / chmod EPERM under Apple virtiofs.
 *
 * Legacy format `<tag>:<target>` (one less colon) is recognized too so
 * older daemons that still emit the old shape keep working. */
static void mount_volumes(const char *cmdline) {
    for (int i = 0; i < 32; i++) {
        char key[16];
        snprintf(key, sizeof(key), "vol%d", i);
        char *spec = cmdline_get(cmdline, key);
        if (!spec) break;

        /* Try new format <type>:<source>:<target> first, fall back to
         * legacy <tag>:<target> if the spec only has one colon. */
        char *c1 = strchr(spec, ':');
        if (!c1) { free(spec); continue; }
        *c1 = '\0';
        char *after_c1 = c1 + 1;
        char *c2 = strchr(after_c1, ':');

        const char *type;
        const char *source;
        const char *target;
        if (c2) {
            *c2 = '\0';
            type = spec;
            source = after_c1;
            target = c2 + 1;
        } else {
            // Legacy : assume virtiofs.
            type = "virtiofs";
            source = spec;
            target = after_c1;
        }

        mkdirp(target);

        if (strcmp(type, "virtiofs") == 0) {
            if (mount(source, target, "virtiofs", 0, NULL) < 0)
                info("mount virtiofs %s -> %s failed: %s", source, target, strerror(errno));
            else
                info("mounted volume %s at %s (virtiofs)", source, target);
        } else if (strcmp(type, "blk") == 0) {
            if (!has_ext_fs(source)) {
                info("volume %s has no filesystem, formatting ext4 …", source);
                char *mkfs_argv[] = {
                    (char *)"mkfs.ext4", (char *)"-F", (char *)"-q",
                    (char *)source, NULL
                };
                int rc = run_cmd(mkfs_argv);
                if (rc != 0) {
                    info("mkfs.ext4 %s failed (rc=%d) — image likely lacks e2fsprogs ; "
                         "install it in your Dockerfile (apt-get install e2fsprogs / "
                         "apk add e2fsprogs) so cocker-init can format named volumes on "
                         "first attach", source, rc);
                    free(spec);
                    continue;
                }
            }
            if (mount(source, target, "ext4", 0, NULL) < 0) {
                info("mount ext4 %s -> %s failed: %s", source, target, strerror(errno));
            } else {
                info("mounted volume %s at %s (ext4 block)", source, target);
                /* Remove the lost+found directory that mke2fs creates.
                 * Postgres' initdb refuses to use a non-empty data dir
                 * ("It contains a lost+found directory, perhaps due to
                 * it being a mount point"), and many other apps make
                 * similar assumptions. Best-effort : rmdir fails with
                 * ENOTEMPTY if fsck has populated it, in which case the
                 * user has bigger problems anyway. */
                char lostfound[1024];
                snprintf(lostfound, sizeof(lostfound), "%s/lost+found", target);
                if (rmdir(lostfound) == 0) {
                    info("  cleared lost+found in %s (postgres-friendly)", target);
                }
            }
        } else {
            info("unknown volume type %s for vol%d (spec=%s:%s:%s) — skipped",
                 type, i, type, source, target);
        }
        free(spec);
    }
}

/* Cross-arch builds : cockerd shares ~/.cocker/qemu via virtiofs tag "qemu"
 * when the build container is labelled with com.cocker.qemu-arch. We
 * mount that tag at /opt/cocker/qemu/ so qemu.c's binfmt_register can
 * find the binary on the path it advertises to the kernel. No-op on
 * native-arch runs. */
static void mount_qemu_share(void) {
    if (access("/opt/cocker/qemu", F_OK) == 0) return;
    if (mkdir("/opt", 0755) < 0 && errno != EEXIST) return;
    if (mkdir("/opt/cocker", 0755) < 0 && errno != EEXIST) return;
    if (mkdir("/opt/cocker/qemu", 0755) < 0 && errno != EEXIST) return;
    /* Try mounting ; silently skip if the host didn't ship the share
     * (every native-arch build hits this path — no log spam). */
    if (mount("qemu", "/opt/cocker/qemu", "virtiofs", MS_RDONLY, NULL) == 0) {
        info("mounted qemu-user-static share at /opt/cocker/qemu");
    }
}

/* Write /etc/resolv.conf pointing at the in-VM DNS proxy. udhcpc clobbers
 * this file with the vmnet gateway DNS, so we rewrite it AFTER DHCP runs. */
static void pin_resolv_conf(unsigned int vsock_port) {
    int fd = open("/etc/resolv.conf", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    const char *rc =
        "# generated by cocker-init (post-DHCP)\n"
        "nameserver 127.0.0.1\n"
        "search cocker\n"
        "options ndots:0 timeout:1 attempts:2\n";
    write(fd, rc, strlen(rc));
    close(fd);
    info("pinned /etc/resolv.conf to 127.0.0.1 (proxy → vsock CID=2 port=%u)",
         vsock_port);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    /* Bring up initial /proc, /sys, /dev before reading cmdline. */
    mkdir("/proc", 0755);
    mkdir("/sys",  0755);
    mkdir("/dev",  0755);

    if (mount("proc",     "/proc", "proc",     0, NULL) < 0)
        die("mount /proc: %s", strerror(errno));
    if (mount("sysfs",    "/sys",  "sysfs",    0, NULL) < 0)
        die("mount /sys: %s", strerror(errno));
    if (mount("devtmpfs", "/dev",  "devtmpfs", 0, NULL) < 0)
        info("mount /dev: %s (continuing)", strerror(errno));

    /* devtmpfs gives us device nodes (null, zero, console, tty…) but
     * NOT the /dev/fd → /proc/self/fd indirection that POSIX programs
     * rely on. initdb (postgres), shell process substitution (`<(cmd)`),
     * and a pile of build tools open `/dev/fd/N` to slurp from a passed
     * file descriptor — without these symlinks they fail with ENOENT.
     * Distro initramfses usually create these via udev or rc-script ;
     * cocker-init's minimal /dev mount has to do it by hand. */
    symlink("/proc/self/fd",    "/dev/fd");
    symlink("/proc/self/fd/0",  "/dev/stdin");
    symlink("/proc/self/fd/1",  "/dev/stdout");
    symlink("/proc/self/fd/2",  "/dev/stderr");

    char cmdline[4096];
    if (read_cmdline(cmdline, sizeof(cmdline)) < 0)
        die("read /proc/cmdline: %s", strerror(errno));

    info("booted from kernel cmdline");

    char *cid  = cmdline_get(cmdline, "id");
    char *name = cmdline_get(cmdline, "name");
    info("container id=%s name=%s", cid ? cid : "?", name ? name : "?");

    char *hostname = cmdline_get(cmdline, "hostname");
    if (hostname) {
        sethostname(hostname, strlen(hostname));
        info("hostname=%s", hostname);
        free(hostname);
    } else if (name) {
        sethostname(name, strlen(name));
    }

    switch_to_virtiofs();
    mount_volumes(cmdline);

    /* `--shm-size` : Linux gives /dev/shm only 64 MB by default which
     * postgres / redis / chromium / pytorch routinely overrun. When the
     * user passes --shm-size=N to `cocker run`, we re-mount /dev/shm
     * tmpfs with `size=Nm`. Done after switch_to_virtiofs so the mount
     * lands on the post-switch /dev (otherwise it gets shadowed). The
     * remount uses MS_REMOUNT semantics when /dev/shm already exists,
     * or a fresh tmpfs mount when it doesn't (busybox-based images
     * sometimes ship without /dev/shm at all). */
    {
        char *shm_mb_s = cmdline_get(cmdline, "shm_mb");
        if (shm_mb_s) {
            unsigned long mb = strtoul(shm_mb_s, NULL, 10);
            if (mb > 0) {
                char opts[64];
                snprintf(opts, sizeof(opts), "size=%lum", mb);
                mkdir("/dev/shm", 01777);
                if (mount("tmpfs", "/dev/shm", "tmpfs",
                          MS_NOSUID | MS_NODEV, opts) < 0) {
                    /* Fallback to remount when /dev/shm was already
                     * mounted by devtmpfs. */
                    if (mount("tmpfs", "/dev/shm", "tmpfs",
                              MS_REMOUNT | MS_NOSUID | MS_NODEV, opts) < 0) {
                        info("/dev/shm size=%lum: %s", mb, strerror(errno));
                    } else {
                        info("/dev/shm remounted size=%lum", mb);
                    }
                } else {
                    info("/dev/shm mounted size=%lum", mb);
                }
            }
            free(shm_mb_s);
        }
    }

    /* Workaround Apple virtiofsd bug that breaks shadow-utils (groupadd,
     * useradd) — must happen BEFORE pin_resolv_conf so the runtime pin
     * lands on the tmpfs overlay and doesn't accidentally persist into
     * the rootfs at exit. See etc_overlay.c for the full story. */
    etc_overlay_setup();

    /* Networking. */
    net_bring_up_loopback();
    net_setup_eth0_dhcp();

    /* DNS proxy first (so resolv.conf pin makes sense). */
    {
        char *vsock_port_s = cmdline_get(cmdline, "dns_vsock_port");
        unsigned int vsock_port = vsock_port_s ? (unsigned int)atoi(vsock_port_s) : 5353;
        if (vsock_port == 0) vsock_port = 5353;
        dns_proxy_spawn(vsock_port);
        pin_resolv_conf(vsock_port);
        if (vsock_port_s) free(vsock_port_s);
    }

    net_setup_eth1_static(cmdline);

    /* Cross-platform builds : mount the qemu-user-static share cockerd
     * provided over virtiofs (no-op when share absent), then register
     * the QEMU user-mode emulator via binfmt_misc so any foreign-arch
     * ELF the build's RUN steps invoke gets transparently emulated. */
    mount_qemu_share();
    qemu_register_binfmt(cmdline);

    /* Spawn the in-VM vsock listener that serves `cocker exec` requests.
     * Runs in a separate subprocess so it survives independently of the
     * main container command. */
    exec_listener_spawn();

    /* Load the container spec (argv + env + workdir + user + caps). MUST
     * happen before health_poll_spawn — the worker forks off this process
     * and inherits a copy of the user_spec / cap arrays. Inverting the
     * order leaves the worker with empty defaults and Dockerfile USER
     * silently goes ignored for healthchecks. */
    char *child_argv[128];
    int argc_count = spec_load(child_argv, 128);
    if (argc_count == 0 || child_argv[0] == NULL)
        die("empty command in /cocker-spec");

    /* Spawn the healthcheck polling worker. cockerd writes one cmd file
     * per probe via virtiofs ; the worker runs it and writes the result
     * back. Bypasses the VZ vsock callback flakiness entirely. */
    health_poll_spawn();

    info("exec: %s (argc=%d)", child_argv[0], argc_count);

    /* Fork + wait : keep PID 1 alive so the kernel doesn't panic when the
     * container's command exits. */
    pid_t child = fork();
    if (child < 0) die("fork: %s", strerror(errno));

    /* When the container's STOPSIGNAL is set (e.g. nginx → SIGQUIT), arm
     * every plausible shutdown signal in PID 1 so we can relay the
     * configured signal to the child. VZ requestStop's exact mapping
     * varies (kernel may turn the ACPI button into SIGINT, SIGTERM,
     * SIGPWR, or SIGHUP depending on the configuration), so we catch
     * the full set instead of guessing.
     *
     * If STOPSIGNAL is unset (== 0), we install the same handler with
     * stop_signal_spec defaulting to SIGTERM, which preserves the prior
     * behaviour : sh's default action on SIGTERM is to exit, so trap
     * handlers run normally. */
    g_child_pid = child;
    if (stop_signal_spec <= 0) stop_signal_spec = 15;  /* default SIGTERM */
    if (stop_signal_spec < 32) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = forward_stop_signal_to_child;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT,  &sa, NULL);
        sigaction(SIGHUP,  &sa, NULL);
        sigaction(SIGPWR,  &sa, NULL);
    }

    /* Publish the container child's PID to a well-known path so the
     * exec_listener subprocess (separate address space — can't read
     * g_child_pid directly) can find it for stop-signal delivery. The
     * file is small and recreated on every boot ; nothing reads it
     * before init writes it because the listener only forks AFTER
     * spec_load + child fork. */
    if (child > 0) {
        FILE *cpf = fopen("/cocker-child.pid", "w");
        if (cpf) {
            fprintf(cpf, "%d\n", (int)child);
            fclose(cpf);
        }
    }

    if (child == 0) {
        /* Caps first — drop unwanted ones from the bounded set BEFORE
         * setuid. With SECBIT_NOROOT off (the default), root keeps full
         * caps on uid change ; once we setuid to an unprivileged user the
         * surviving caps are bounded by what we narrowed here. */
        caps_apply(privileged_spec,
                   cap_add_spec, cap_add_spec_len,
                   cap_drop_spec, cap_drop_spec_len);

        /* Apply Dockerfile USER if the spec set one. Order matters :
         * setgid() first (still root, can change gid), then setuid() locks
         * in the unprivileged identity. Failures are fatal because silently
         * running as root after the user asked for "appuser" is a security
         * hazard. */
        if (user_spec[0]) {
            unsigned int uid = 0, gid = 0;
            if (spec_resolve_user(user_spec, &uid, &gid) != 0) {
                fprintf(stderr, "[cocker-init] unknown user '%s'\n", user_spec);
                _exit(126);
            }
            if (setgid(gid) != 0) {
                fprintf(stderr, "[cocker-init] setgid(%u): %s\n", gid, strerror(errno));
                _exit(126);
            }
            if (setuid(uid) != 0) {
                fprintf(stderr, "[cocker-init] setuid(%u): %s\n", uid, strerror(errno));
                _exit(126);
            }
        }
        execvp(child_argv[0], child_argv);
        fprintf(stderr, "[cocker-init] execvp %s: %s\n",
                child_argv[0], strerror(errno));
        _exit(127);
    }

    int status = 0;
    for (;;) {
        pid_t r = waitpid(-1, &status, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) break;
            die("waitpid: %s", strerror(errno));
        }
        if (r == child) break;
    }

    int exitcode = 0;
    if (WIFEXITED(status))         exitcode = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))  exitcode = 128 + WTERMSIG(status);

    info("container exited with code %d", exitcode);

    /* Persist the exit code to the shared rootfs so cockerd can read
     * it after the VM is gone. Console-based capture races VZ's
     * teardown — the kernel sometimes powers off before init's stderr
     * drains to the host-side pipe — and `cocker stop` then reports
     * exit 0 regardless of what the container actually returned. The
     * file path is fixed ("/cocker-exit-code") so the daemon can find
     * it without coordination.
     *
     * fdatasync() + the rootfs-level sync below force the write to
     * commit through the virtiofs server to the host filesystem before
     * the VM is allowed to power off. Without it the kernel may buffer
     * the dirty page and lose it on the abrupt teardown. */
    int ecfd = open("/cocker-exit-code", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (ecfd >= 0) {
        char buf[16];
        int len = snprintf(buf, sizeof(buf), "%d\n", exitcode);
        if (len > 0) write(ecfd, buf, (size_t)len);
        fsync(ecfd);
        close(ecfd);
        info("wrote /cocker-exit-code = %d", exitcode);
    } else {
        info("FAILED to open /cocker-exit-code : %s", strerror(errno));
    }

    /* Belt-and-suspenders : flush stderr to the console too. The file
     * is the source of truth ; the console line is for human inspection
     * via `cocker logs`. */
    fflush(stderr);
    fflush(stdout);

    /* Reverse the /etc tmpfs overlay so this container's RUN-step
     * modifications (added users, package configs, …) land in the
     * virtiofs rootfs before the VM powers off. resolv.conf et al. are
     * preserved at their image-time content. Must precede sync(). */
    etc_overlay_sync_back();

    sync();

    reboot(RB_POWER_OFF);
    _exit(exitcode);
}
