/*
 * cocker_init.h — shared declarations for the cocker-init modules.
 *
 * The init binary used to live in a single ~700-line init.c. It's now split
 * by responsibility :
 *
 *   cmdline.c   — parse cocker.* params from /proc/cmdline
 *   net.c       — bring up lo / eth0 (DHCP) / eth1 (static, cocker switch)
 *   dns_proxy.c — bind 127.0.0.1:53, tunnel queries to cockerd over vsock
 *   spec.c      — parse /cocker-spec written by cockerd (argv + env + workdir)
 *   init.c      — main : virtiofs rootfs, hostname, fork+wait child
 *
 * All modules share the logging macros and a couple of helpers declared here.
 */

#ifndef COCKER_INIT_H
#define COCKER_INIT_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/reboot.h>

/* Fatal — log, sleep so the message reaches the host, then halt. */
#define die(fmt, ...) do { \
    fprintf(stderr, "[cocker-init] FATAL: " fmt "\n", ##__VA_ARGS__); \
    sleep(2); \
    reboot(RB_HALT_SYSTEM); \
    _exit(1); \
} while (0)

/* Informational log line — always goes to stderr (the VM console). */
#define info(fmt, ...) fprintf(stderr, "[cocker-init] " fmt "\n", ##__VA_ARGS__)

/* MARK: - cmdline.c */

/* Read /proc/cmdline (NUL-terminated, trailing newline stripped) into buf.
 * Returns 0 on success, -1 on error. */
int read_cmdline(char *buf, size_t size);

/* Find "cocker.<key>=<value>" in cmdline. Returns malloc()'d value or NULL
 * if the key isn't present. Caller frees. */
char *cmdline_get(const char *cmdline, const char *key);

/* MARK: - net.c */

/* Bring loopback up (so the DNS proxy on 127.0.0.1:53 is reachable). */
void net_bring_up_loopback(void);

/* Bring eth0 up and run udhcpc / dhclient. Writes the obtained IPv4 into
 * /cocker-ip so cockerd can pick it up via virtiofs. */
void net_setup_eth0_dhcp(void);

/* Configure eth1 statically from cmdline parameters (cocker.cnet_ip,
 * cocker.cnet_mac). No-op if cocker.cnet_ip is absent. */
void net_setup_eth1_static(const char *cmdline);

/* MARK: - dns_proxy.c */

/* Spawn the in-VM DNS proxy that binds 0.0.0.0:53 and tunnels every UDP
 * datagram to cockerd over vsock (CID=2, port=vsock_port). Returns the
 * child pid (parent), or 0 in the child. */
pid_t dns_proxy_spawn(unsigned int vsock_port);

/* MARK: - qemu.c */

/* Register a QEMU user-mode emulator with the kernel's binfmt_misc facility so
 * the VM can transparently execute foreign-architecture binaries (e.g. x86_64
 * ELFs on an arm64 host kernel). Reads cocker.qemu_path / cocker.qemu_arch from
 * the kernel cmdline. No-op if either is absent. */
void qemu_register_binfmt(const char *cmdline);

/* MARK: - exec_listener.c */

/* Spawn the in-VM vsock listener that accepts `cocker exec` requests on
 * port 9000. Returns the child pid (parent) or 0 in the listener child. */
pid_t exec_listener_spawn(void);

/* MARK: - health_poll.c */

/* Spawn the guest-side healthcheck polling worker. The worker watches
 * /healthcheck/cmd-* files (written by cockerd via virtiofs), runs each
 * command, and writes the exit code to /healthcheck/result-<seq>. */
pid_t health_poll_spawn(void);

/* MARK: - spec.c */

/* Read and parse /cocker-spec written by cockerd. Sets argv (NULL-terminated)
 * with the container's command, applies env via putenv(), and chdir()s into
 * the workdir if any. argv slots beyond `max` are silently dropped.
 *
 * Returns the number of argv entries (>= 1 on success), or 0 if the spec
 * file is missing — in which case the caller should default to /bin/sh. */
int spec_load(char **argv, int max);

/* Populated by spec_load() from the v3 `user` trailer. Empty string ↔ no
 * setuid (run as root). Format mirrors Docker : "name", "uid", or "uid:gid".
 * init.c reads this to resolve and apply credentials before execvp(). */
extern char user_spec[256];

/* Resolve `spec` ("user", "uid", or "uid:gid") into uid+gid by consulting
 * /etc/passwd if necessary. Returns 0 on success, -1 on failure. */
int spec_resolve_user(const char *spec, unsigned int *uid, unsigned int *gid);

/* MARK: - caps.c */

/* Resolve a cap name (with or without "CAP_" prefix) to its kernel cap
 * number. Returns -1 on unknown. */
int cap_resolve_name(const char *name);

/* Apply the cap policy : narrow the bounded set to (defaults ∪ cap_add) −
 * cap_drop. Privileged mode skips the dropping entirely. Must be called
 * before execvp() in the container child. */
void caps_apply(int privileged,
                const int *cap_add, int cap_add_len,
                const int *cap_drop, int cap_drop_len);

/* Populated by spec_load() from the v4 caps trailer. The arrays hold cap
 * numbers (not names) and are usable directly by caps_apply. */
extern int cap_add_spec[64];
extern int cap_add_spec_len;
extern int cap_drop_spec[64];
extern int cap_drop_spec_len;
extern int privileged_spec;
/// POSIX signal number (e.g. 3 = SIGQUIT). 0 = default (SIGTERM).
/// Populated by spec_load() from the v5 spec format trailer. Consumed by
/// init.c's SIGTERM handler : when the host issues `VZ requestStop` /
/// `cocker stop` (sends SIGTERM to PID 1), we relay this signal to the
/// container child instead so STOPSIGNAL Dockerfiles work.
extern int stop_signal_spec;

/* MARK: - etc_overlay.c */

/* Bind-mount a tmpfs copy of /etc over the virtiofs /etc to work around
 * an Apple virtiofsd bug that breaks shadow-utils (groupadd, useradd,
 * usermod). See etc_overlay.c for the full diagnosis. Best-effort : on
 * failure logs and continues — caller behaviour is unaffected. */
void etc_overlay_setup(void);

/* Reverse the overlay : copy tmpfs /etc back to virtiofs /etc so the
 * container's modifications persist into the rootfs. Skips runtime-only
 * files (resolv.conf, hostname, hosts). Safe to call even if setup
 * never ran or failed. Called from init.c just before sync()+reboot(). */
void etc_overlay_sync_back(void);

#endif /* COCKER_INIT_H */
