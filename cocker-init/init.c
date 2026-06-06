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
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
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

/* Tiny inline DNS proxy.
 *
 * The cockerd DNS resolver binds on the host at <dns_ip>:<dns_port> (default
 * 5300 — port 53 is reserved on macOS). Inside the container, libc reads
 * /etc/resolv.conf which has no port column, so apps query port 53 by
 * default. We spawn this proxy as a child of PID 1, bind UDP 0.0.0.0:53
 * (works because PID 1 runs as root inside the VM) and tunnel every datagram
 * to the host's cockerd resolver — but over TCP (DNS-over-TCP, RFC 1035
 * §4.2.2). Why TCP and not UDP : Apple's App Sandbox silently drops UDP
 * packets that reach a user-signed daemon (cockerd) via the vmnet kernel
 * extension. TCP from VM to host works fine. Same wire format, two extra
 * bytes for length prefix.
 *
 * Iterative — fine for a sub-second resolution rate. Caller continues; child
 * runs forever until VM shutdown sends SIGTERM.
 */
static int dns_tcp_forward(const char *dns_ip, int dns_port,
                           const char *query, size_t qlen,
                           char *response, size_t resp_max) {
    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) return -1;

    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(sfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(dns_port);
    inet_pton(AF_INET, dns_ip, &dst.sin_addr);

    if (connect(sfd, (struct sockaddr *)&dst, sizeof(dst)) < 0) { close(sfd); return -1; }

    unsigned char prefix[2] = {
        (unsigned char)((qlen >> 8) & 0xFF),
        (unsigned char)(qlen & 0xFF)
    };
    if (write(sfd, prefix, 2) != 2) { close(sfd); return -1; }
    ssize_t w = 0;
    while ((size_t)w < qlen) {
        ssize_t n = write(sfd, query + w, qlen - w);
        if (n <= 0) { close(sfd); return -1; }
        w += n;
    }

    unsigned char rp[2];
    ssize_t pr = 0;
    while (pr < 2) {
        ssize_t n = read(sfd, rp + pr, 2 - pr);
        if (n <= 0) { close(sfd); return -1; }
        pr += n;
    }
    size_t resp_len = ((size_t)rp[0] << 8) | rp[1];
    if (resp_len == 0 || resp_len > resp_max) { close(sfd); return -1; }

    ssize_t rr = 0;
    while ((size_t)rr < resp_len) {
        ssize_t n = read(sfd, response + rr, resp_len - rr);
        if (n <= 0) { close(sfd); return -1; }
        rr += n;
    }
    close(sfd);
    return (int)resp_len;
}

static void start_dns_proxy(const char *dns_ip, int dns_port) {
    pid_t pid = fork();
    if (pid < 0) {
        info("dns-proxy fork: %s", strerror(errno));
        return;
    }
    if (pid != 0) {
        info("dns-proxy spawned (pid=%d, upstream=%s:%d via TCP)",
             pid, dns_ip, dns_port);
        return;
    }

    int listen_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (listen_fd < 0) _exit(1);

    int yes = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in laddr;
    memset(&laddr, 0, sizeof(laddr));
    laddr.sin_family = AF_INET;
    laddr.sin_port = htons(53);
    laddr.sin_addr.s_addr = INADDR_ANY;
    if (bind(listen_fd, (struct sockaddr *)&laddr, sizeof(laddr)) < 0) {
        fprintf(stderr, "[cocker-init] dns-proxy bind :53: %s\n",
                strerror(errno));
        _exit(1);
    }

    char query[65536];
    char response[65536];
    while (1) {
        struct sockaddr_in client;
        socklen_t cl = sizeof(client);
        ssize_t n = recvfrom(listen_fd, query, sizeof(query), 0,
                             (struct sockaddr *)&client, &cl);
        if (n <= 0) continue;

        int m = dns_tcp_forward(dns_ip, dns_port, query, (size_t)n,
                                response, sizeof(response));
        if (m <= 0) continue;  // silent — upstream may be a stub for now

        sendto(listen_fd, response, m, 0, (struct sockaddr *)&client, cl);
    }
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

    /* IP discovery :
     *   1. up de l'interface eth0
     *   2. démarrer udhcpc (DHCP client) pour obtenir une IP DHCP de vmnet
     *   3. récupérer l'IP via ioctl + écrire dans /cocker-ip
     * Le daemon poll ce fichier via virtiofs pour configurer le port
     * forwarding TCP host → container.
     */
    {
        /* Up de lo (loopback) — sinon le DNS proxy à 127.0.0.1:53 est
         * inatteignable depuis la même VM. */
        int up_sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (up_sock >= 0) {
            struct ifreq ifr;
            memset(&ifr, 0, sizeof(ifr));
            strncpy(ifr.ifr_name, "lo", IFNAMSIZ - 1);
            if (ioctl(up_sock, SIOCGIFFLAGS, &ifr) == 0) {
                ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
                ioctl(up_sock, SIOCSIFFLAGS, &ifr);
            }
            /* Up de eth0 (ifconfig eth0 up) */
            memset(&ifr, 0, sizeof(ifr));
            strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
            if (ioctl(up_sock, SIOCGIFFLAGS, &ifr) == 0) {
                ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
                if (ioctl(up_sock, SIOCSIFFLAGS, &ifr) != 0)
                    info("ifup eth0: %s", strerror(errno));
            }
            close(up_sock);
        }

        /* Lance udhcpc en background. Plusieurs chemins possibles selon
         * la distro : busybox dans Alpine, dhclient ailleurs. */
        const char *dhcp_clients[] = {
            "/sbin/udhcpc", "/usr/sbin/udhcpc",
            "/sbin/dhclient", "/usr/sbin/dhclient",
            NULL
        };
        pid_t dhcp_pid = -1;
        for (int i = 0; dhcp_clients[i]; i++) {
            if (access(dhcp_clients[i], X_OK) != 0) continue;
            dhcp_pid = fork();
            if (dhcp_pid == 0) {
                if (strstr(dhcp_clients[i], "udhcpc")) {
                    execl(dhcp_clients[i], "udhcpc", "-i", "eth0",
                          "-t", "3", "-n", "-q", "-f", (char *)NULL);
                } else {
                    execl(dhcp_clients[i], "dhclient", "-1", "eth0", (char *)NULL);
                }
                _exit(127);
            }
            info("started DHCP client %s (pid %d)", dhcp_clients[i], dhcp_pid);
            break;
        }
        if (dhcp_pid > 0) {
            int dhcp_status;
            waitpid(dhcp_pid, &dhcp_status, 0);
        } else {
            info("no DHCP client found (udhcpc/dhclient), trying static IP read");
        }

        /* udhcpc overwrites /etc/resolv.conf with the vmnet gateway DNS
         * (192.168.64.1) which short-circuits container name resolution.
         * We instead point libc at our local DNS proxy on 127.0.0.1:53 and
         * spawn the proxy which tunnels to the cockerd resolver at
         * <cocker.dns>:<cocker.dns_port>. */
        {
            char *dns_ip = cmdline_get(cmdline, "dns");
            char *dns_port_s = cmdline_get(cmdline, "dns_port");
            int dns_port = dns_port_s ? atoi(dns_port_s) : 5300;
            if (dns_port <= 0 || dns_port > 65535) dns_port = 5300;

            if (dns_ip) {
                start_dns_proxy(dns_ip, dns_port);

                int rc_fd = open("/etc/resolv.conf",
                                 O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (rc_fd >= 0) {
                    const char *rc =
                        "# generated by cocker-init (post-DHCP)\n"
                        "nameserver 127.0.0.1\n"
                        "search cocker\n"
                        "options ndots:0 timeout:1 attempts:2\n";
                    write(rc_fd, rc, strlen(rc));
                    close(rc_fd);
                    info("pinned /etc/resolv.conf to 127.0.0.1 "
                         "(proxy → %s:%d)", dns_ip, dns_port);
                }
                free(dns_ip);
            }
            if (dns_port_s) free(dns_port_s);
        }

        /* Lit l'IP eth0 — retry rapide au cas où DHCP en cours */
        int sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (sock >= 0) {
            char ip_str[INET_ADDRSTRLEN] = {0};
            for (int try = 0; try < 20; try++) {
                struct ifreq ifr;
                memset(&ifr, 0, sizeof(ifr));
                strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
                if (ioctl(sock, SIOCGIFADDR, &ifr) == 0) {
                    struct sockaddr_in *ipaddr = (struct sockaddr_in *)&ifr.ifr_addr;
                    if (inet_ntop(AF_INET, &ipaddr->sin_addr, ip_str, sizeof(ip_str)))
                        break;
                }
                usleep(100000);  /* 100ms */
            }
            close(sock);
            if (ip_str[0]) {
                info("eth0 IP=%s", ip_str);
                int ip_fd = open("/cocker-ip", O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (ip_fd >= 0) {
                    write(ip_fd, ip_str, strlen(ip_str));
                    fsync(ip_fd);
                    close(ip_fd);
                }
            } else {
                info("no IP on eth0 after DHCP attempt");
            }
        }
    }

    /* eth1 — cocker L2 switch fabric (10.42.0.0/16).
     *
     * Configured statically from the kernel cmdline. cockerd allocates IP +
     * MAC for each container and runs a userspace L2 switch on the host that
     * forwards Ethernet frames between containers. This interface is what
     * makes container-to-container networking work — Apple's vmnet on eth0
     * isolates VMs from each other, but eth1 sees all peer containers
     * directly. No gateway is reachable on this fabric (cockerd doesn't
     * answer ARP for 10.42.0.1) — it's a flat inter-container LAN only.
     *
     * If cocker.cnet_ip is absent (old daemon, --net=none, etc.) we skip
     * eth1 setup silently.
     */
    {
        char *cnet_ip = cmdline_get(cmdline, "cnet_ip");
        if (cnet_ip) {
            /* "10.42.0.5/16" → strip the prefix length */
            char *slash = strchr(cnet_ip, '/');
            if (slash) *slash = '\0';

            int sock = socket(AF_INET, SOCK_DGRAM, 0);
            if (sock >= 0) {
                struct ifreq ifr;

                /* Bring eth1 up */
                memset(&ifr, 0, sizeof(ifr));
                strncpy(ifr.ifr_name, "eth1", IFNAMSIZ - 1);
                if (ioctl(sock, SIOCGIFFLAGS, &ifr) == 0) {
                    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
                    if (ioctl(sock, SIOCSIFFLAGS, &ifr) != 0)
                        info("ifup eth1: %s", strerror(errno));
                } else {
                    info("eth1 SIOCGIFFLAGS: %s (no switch fabric ?)", strerror(errno));
                }

                /* Set IP */
                memset(&ifr, 0, sizeof(ifr));
                strncpy(ifr.ifr_name, "eth1", IFNAMSIZ - 1);
                {
                    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
                    sin->sin_family = AF_INET;
                    if (inet_pton(AF_INET, cnet_ip, &sin->sin_addr) == 1) {
                        if (ioctl(sock, SIOCSIFADDR, &ifr) != 0)
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
                    if (ioctl(sock, SIOCSIFNETMASK, &ifr) != 0)
                        info("eth1 SIOCSIFNETMASK: %s", strerror(errno));
                }

                close(sock);
            }
            free(cnet_ip);
        }
    }

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

    /*
     * Fork + wait pattern : on garde PID 1 vivant pour éviter le kernel panic
     * quand la commande container exit. Sans ça, exec direct = quand le shell
     * meurt, le kernel panic "Attempted to kill init!" et la VM tourne en
     * boucle à ~200% CPU jusqu'à kill manuel (vu en vrai sur M3 Max).
     */
    pid_t child = fork();
    if (child < 0)
        die("fork: %s", strerror(errno));

    if (child == 0) {
        execvp(child_argv[0], child_argv);
        fprintf(stderr, "[cocker-init] execvp %s: %s\n", child_argv[0], strerror(errno));
        _exit(127);
    }

    /* PID 1 : reap zombies + wait child principal */
    int status = 0;
    while (1) {
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

    /* Shutdown propre — évite le kernel panic. */
    sync();
    reboot(RB_POWER_OFF);
    _exit(exitcode);
}
