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

/* MARK: - spec.c */

/* Read and parse /cocker-spec written by cockerd. Sets argv (NULL-terminated)
 * with the container's command, applies env via putenv(), and chdir()s into
 * the workdir if any. argv slots beyond `max` are silently dropped.
 *
 * Returns the number of argv entries (>= 1 on success), or 0 if the spec
 * file is missing — in which case the caller should default to /bin/sh. */
int spec_load(char **argv, int max);

#endif /* COCKER_INIT_H */
