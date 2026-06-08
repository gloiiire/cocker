/*
 * net.c — bring up the container's network interfaces.
 *
 *   lo   : loopback so the in-VM DNS proxy on 127.0.0.1:53 is reachable.
 *   eth0 : Apple vmnet NAT for outbound internet. We run udhcpc/dhclient
 *          to grab a lease, then read the assigned IP back via SIOCGIFADDR
 *          and report it to cockerd by writing /cocker-ip on the virtiofs
 *          share. cockerd polls that file to wire up host port-forwarding.
 *   eth1 : the cocker L2 switch fabric. cockerd allocates the IP/MAC and
 *          passes them on the kernel cmdline (cocker.cnet_ip/_mac), so we
 *          just plumb them with SIOCSIFADDR / SIOCSIFNETMASK.
 */

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include "cocker_init.h"

static int ifup(int sock, const char *name) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) != 0) return -1;
    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    return ioctl(sock, SIOCSIFFLAGS, &ifr);
}

void net_bring_up_loopback(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return;
    ifup(s, "lo");
    close(s);
}

/* Spawn a DHCP client and return its exit code, or -1 on fork failure.
 * Splits the spawn out of run_dhcp_client so the caller can retry. */
static int spawn_dhcp_attempt(const char *client) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (strstr(client, "udhcpc")) {
            /* -t 10 : up to 10 DISCOVER packets at 1 s intervals before
             *         giving up. The default 3 races against vmnet's
             *         bootpd, especially on cold-cache VM cold boots.
             * -n    : exit (don't daemonize) on lease failure
             * -q    : exit (don't daemonize) on lease success
             * -f    : foreground (no syslog detach) so wait() works.   */
            execl(client, "udhcpc", "-i", "eth0",
                  "-t", "10", "-n", "-q", "-f", (char *)NULL);
        } else {
            execl(client, "dhclient", "-1", "eth0", (char *)NULL);
        }
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static void run_dhcp_client(void) {
    /* Several distros, several paths — busybox in Alpine, dhclient elsewhere. */
    const char *clients[] = {
        "/sbin/udhcpc", "/usr/sbin/udhcpc",
        "/sbin/dhclient", "/usr/sbin/dhclient",
        NULL,
    };
    const char *client = NULL;
    for (int i = 0; clients[i]; i++) {
        if (access(clients[i], X_OK) == 0) { client = clients[i]; break; }
    }
    if (!client) { info("no DHCP client found (udhcpc/dhclient)"); return; }

    /* Two attempts back-to-back. If the first udhcpc exits non-zero, vmnet's
     * bootpd may not have been ready yet (cold cache) — a 1 s sleep usually
     * smooths it out. cockerd has a host-side fallback via
     * /var/db/dhcpd_leases for the case where this still fails. */
    for (int attempt = 0; attempt < 2; attempt++) {
        info("started DHCP client %s (attempt %d)", client, attempt + 1);
        int rc = spawn_dhcp_attempt(client);
        if (rc == 0) return;
        info("DHCP attempt %d failed (rc=%d)", attempt + 1, rc);
        sleep(1);
    }
}

static void report_eth0_ip(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return;

    char ip_str[INET_ADDRSTRLEN] = {0};
    for (int try = 0; try < 20; try++) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof(ifr));
        strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
        if (ioctl(s, SIOCGIFADDR, &ifr) == 0) {
            struct sockaddr_in *a = (struct sockaddr_in *)&ifr.ifr_addr;
            if (inet_ntop(AF_INET, &a->sin_addr, ip_str, sizeof(ip_str))) break;
        }
        usleep(100000);
    }
    close(s);

    if (ip_str[0]) {
        info("eth0 IP=%s", ip_str);
        int fd = open("/cocker-ip", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, ip_str, strlen(ip_str));
            fsync(fd);
            close(fd);
        }
    } else {
        info("no IP on eth0 after DHCP attempt");
    }
}

void net_setup_eth0_dhcp(void) {
    /* The rootfs we boot from is a clonefile of the image's rootfs, so a
     * stale /cocker-ip from a previous build VM or container persists into
     * fresh containers. cockerd polls that file every 100 ms ; if it reads
     * the stale value before we get around to overwriting it after DHCP,
     * port-forwarding gets wired to the wrong IP. Truncate up front so
     * cockerd sees an empty file (and keeps polling) until DHCP succeeds. */
    int trunc_fd = open("/cocker-ip", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (trunc_fd >= 0) close(trunc_fd);

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s >= 0) {
        if (ifup(s, "eth0") != 0) info("ifup eth0: %s", strerror(errno));
        close(s);
    }
    run_dhcp_client();
    report_eth0_ip();
}

void net_setup_eth1_static(const char *cmdline) {
    char *cnet_ip = cmdline_get(cmdline, "cnet_ip");
    if (!cnet_ip) return;

    /* "10.42.0.5/16" → drop the prefix length, we hardcode /16 below. */
    char *slash = strchr(cnet_ip, '/');
    if (slash) *slash = '\0';

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { free(cnet_ip); return; }

    if (ifup(s, "eth1") != 0)
        info("eth1 ifup: %s (interface may not exist yet)", strerror(errno));

    /* Set IP */
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth1", IFNAMSIZ - 1);
    {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
        sin->sin_family = AF_INET;
        if (inet_pton(AF_INET, cnet_ip, &sin->sin_addr) == 1) {
            if (ioctl(s, SIOCSIFADDR, &ifr) != 0)
                info("eth1 SIOCSIFADDR: %s", strerror(errno));
            else
                info("eth1 IP=%s/16", cnet_ip);
        }
    }

    /* Netmask 255.255.0.0 (/16) */
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth1", IFNAMSIZ - 1);
    {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_netmask;
        sin->sin_family = AF_INET;
        sin->sin_addr.s_addr = htonl(0xFFFF0000);
        if (ioctl(s, SIOCSIFNETMASK, &ifr) != 0)
            info("eth1 SIOCSIFNETMASK: %s", strerror(errno));
    }

    close(s);
    free(cnet_ip);
}
