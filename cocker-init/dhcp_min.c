/*
 * dhcp_min.c — minimal embedded DHCPv4 client.
 *
 * Why we need an in-tree client at all : cocker-init runs as PID 1 in
 * the container VM and used to shell out to /sbin/udhcpc (busybox) or
 * /sbin/dhclient (Debian/Ubuntu) from the rootfs. Images that don't
 * bundle either — most slim Python / Node base images, distroless,
 * scratch-derived — leave eth0 with no IP at all. cockerd's portfwd
 * then fallbacks to routing host traffic at 127.0.0.1 inside the VM,
 * which loops back to the cockerd-side wrapper instead of the app.
 *
 * Wire format reference : RFC 2131 (BOOTP frame) + RFC 2132 (options).
 *
 * Scope of what we implement :
 *   - Single iface (eth0). Multi-iface containers are out of scope.
 *   - DHCPDISCOVER → DHCPOFFER → DHCPREQUEST → DHCPACK happy path.
 *   - Three retries with linear backoff. vmnet's bootpd is on the
 *     same host and answers in ~1 ms when ready, so a generous
 *     1-second budget per retry covers cold-start jitter.
 *   - We parse only the options we need : router (3), subnet (1),
 *     lease (51), server-id (54), DNS (6). cockerd doesn't read
 *     DNS from the lease — its in-VM DNS proxy short-circuits before
 *     resolv.conf even matters.
 *
 * What we deliberately skip :
 *   - DHCPRELEASE on container stop. The VM disappears entirely ;
 *     bootpd will recycle the lease via the dhcpd_leases TTL.
 *   - Renewal. cocker containers are short-lived enough that
 *     half-lease renewals would be machinery for nothing.
 *   - Routing table setup. We just set IP + netmask + gateway via
 *     ioctl SIOCSIFADDR / SIOCADDRT, matching what udhcpc's default
 *     dhclient.script would do.
 */

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <net/if.h>
#include <net/route.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include "cocker_init.h"

#define DHCP_MAGIC      0x63825363u
#define DHCP_DISCOVER   1
#define DHCP_OFFER      2
#define DHCP_REQUEST    3
#define DHCP_ACK        5
#define BOOTP_REQUEST   1

#define OPT_PAD         0
#define OPT_SUBNET      1
#define OPT_ROUTER      3
#define OPT_DNS         6
#define OPT_REQ_IP      50
#define OPT_LEASE_TIME  51
#define OPT_MSG_TYPE    53
#define OPT_SERVER_ID   54
#define OPT_PARAM_LIST  55
#define OPT_END         255

/* BOOTP frame layout — packed so the wire bytes line up with the
 * field offsets. Total fixed header is 240 bytes ; options follow. */
struct __attribute__((packed)) dhcp_pkt {
    uint8_t  op;           /* 1 = request */
    uint8_t  htype;        /* 1 = Ethernet */
    uint8_t  hlen;         /* 6 */
    uint8_t  hops;
    uint32_t xid;
    uint16_t secs;
    uint16_t flags;        /* 0x8000 = broadcast reply */
    uint32_t ciaddr;
    uint32_t yiaddr;       /* server fills this in OFFER/ACK */
    uint32_t siaddr;
    uint32_t giaddr;
    uint8_t  chaddr[16];   /* client hardware addr (MAC + zeros) */
    uint8_t  sname[64];
    uint8_t  file[128];
    uint32_t magic;        /* 0x63825363 */
    uint8_t  options[312]; /* enough for a typical OFFER */
};

/* Read eth0's MAC into out[6]. Returns 0 on success, -1 on failure. */
static int read_eth0_mac(uint8_t *out) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
    int rc = ioctl(s, SIOCGIFHWADDR, &ifr);
    close(s);
    if (rc != 0) return -1;
    memcpy(out, ifr.ifr_hwaddr.sa_data, 6);
    return 0;
}

/* Append a TLV option to `opts` at `*pos`, advancing it. */
static void put_opt(uint8_t *opts, size_t *pos, uint8_t code, const void *val, uint8_t len) {
    opts[(*pos)++] = code;
    opts[(*pos)++] = len;
    memcpy(opts + *pos, val, len);
    *pos += len;
}

/* Scan options for `code`. Returns pointer to the value (after type+len)
 * and writes the length into *out_len. NULL if not present. */
static const uint8_t *find_opt(const uint8_t *opts, size_t opts_len, uint8_t code, uint8_t *out_len) {
    size_t i = 0;
    while (i < opts_len) {
        uint8_t c = opts[i++];
        if (c == OPT_PAD) continue;
        if (c == OPT_END) break;
        if (i >= opts_len) break;
        uint8_t l = opts[i++];
        if (i + l > opts_len) break;
        if (c == code) {
            *out_len = l;
            return opts + i;
        }
        i += l;
    }
    return NULL;
}

/* Build a DISCOVER or REQUEST packet body. server_id and req_ip are in
 * network byte order ; pass 0 for DISCOVER. */
static size_t build_dhcp(struct dhcp_pkt *p, uint32_t xid, uint8_t msg_type,
                         const uint8_t mac[6], uint32_t req_ip, uint32_t server_id) {
    memset(p, 0, sizeof(*p));
    p->op = BOOTP_REQUEST;
    p->htype = 1;
    p->hlen = 6;
    p->xid = xid;
    p->flags = htons(0x8000); /* broadcast — we have no IP yet */
    memcpy(p->chaddr, mac, 6);
    p->magic = htonl(DHCP_MAGIC);

    size_t pos = 0;
    put_opt(p->options, &pos, OPT_MSG_TYPE, &msg_type, 1);
    if (msg_type == DHCP_REQUEST) {
        put_opt(p->options, &pos, OPT_REQ_IP, &req_ip, 4);
        put_opt(p->options, &pos, OPT_SERVER_ID, &server_id, 4);
    }
    uint8_t params[] = {OPT_SUBNET, OPT_ROUTER, OPT_DNS, OPT_LEASE_TIME};
    put_opt(p->options, &pos, OPT_PARAM_LIST, params, sizeof(params));
    p->options[pos++] = OPT_END;
    return offsetof(struct dhcp_pkt, options) + pos;
}

/* Open a UDP socket bound to eth0's :68, set broadcast + RCVTIMEO. */
static int open_dhcp_sock(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    /* Bind to device eth0 — without this, the kernel routes 0.0.0.0
     * via the default iface (loopback when no IP is configured) and
     * the OFFER's broadcast never reaches our socket. */
    setsockopt(s, SOL_SOCKET, SO_BINDTODEVICE, "eth0", 4);
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(68);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(s); return -1;
    }
    return s;
}

/* Apply IP + netmask to eth0, set default route via gateway. */
int configure_iface(uint32_t ip, uint32_t netmask, uint32_t gateway) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;

    sin->sin_addr.s_addr = ip;
    if (ioctl(s, SIOCSIFADDR, &ifr) != 0) { close(s); return -1; }

    sin->sin_addr.s_addr = netmask;
    if (ioctl(s, SIOCSIFNETMASK, &ifr) != 0) { close(s); return -1; }

    /* Add default route via gateway. */
    struct rtentry rt;
    memset(&rt, 0, sizeof(rt));
    struct sockaddr_in *dst = (struct sockaddr_in *)&rt.rt_dst;
    struct sockaddr_in *gw  = (struct sockaddr_in *)&rt.rt_gateway;
    struct sockaddr_in *gm  = (struct sockaddr_in *)&rt.rt_genmask;
    dst->sin_family = AF_INET; dst->sin_addr.s_addr = 0;
    gw->sin_family  = AF_INET; gw->sin_addr.s_addr  = gateway;
    gm->sin_family  = AF_INET; gm->sin_addr.s_addr  = 0;
    rt.rt_flags = RTF_UP | RTF_GATEWAY;
    rt.rt_dev = (char *)"eth0";
    /* Best-effort : if a route already exists (because the cnet
     * fabric added one) we still want the iface configured, so we
     * don't fail the whole flow on SIOCADDRT EEXIST. */
    ioctl(s, SIOCADDRT, &rt);

    close(s);
    return 0;
}

/* Send a packet, read up to one response with the matching xid + msg
 * type. server_addr is filled on success. */
static int dhcp_send_and_recv(int sock, uint8_t target_msg,
                              const struct dhcp_pkt *send_pkt, size_t send_len,
                              struct dhcp_pkt *recv_pkt, size_t *recv_len,
                              uint32_t expected_xid) {
    struct sockaddr_in dst = {0};
    dst.sin_family = AF_INET;
    dst.sin_port = htons(67);
    dst.sin_addr.s_addr = htonl(INADDR_BROADCAST);

    if (sendto(sock, send_pkt, send_len, 0,
               (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        return -1;
    }

    /* Loop until a matching packet arrives or recv times out. Other
     * containers on the same vmnet bridge can broadcast their own DHCP
     * traffic ; we drop replies whose xid doesn't match ours. */
    for (int tries = 0; tries < 8; tries++) {
        ssize_t n = recv(sock, recv_pkt, sizeof(*recv_pkt), 0);
        if (n < (ssize_t)offsetof(struct dhcp_pkt, options) + 1) continue;
        if (recv_pkt->xid != expected_xid) continue;
        if (ntohl(recv_pkt->magic) != DHCP_MAGIC) continue;

        size_t opts_len = (size_t)n - offsetof(struct dhcp_pkt, options);
        uint8_t mt_len = 0;
        const uint8_t *mt = find_opt(recv_pkt->options, opts_len, OPT_MSG_TYPE, &mt_len);
        if (!mt || mt_len < 1 || mt[0] != target_msg) continue;

        *recv_len = (size_t)n;
        return 0;
    }
    return -1;
}

/* Try one full DISCOVER → OFFER → REQUEST → ACK cycle. Returns 0 on
 * success ; -1 on any step failure (caller can retry). */
int dhcp_embedded_lease(void) {
    uint8_t mac[6];
    if (read_eth0_mac(mac) != 0) {
        info("dhcp-min: read MAC failed");
        return -1;
    }
    int sock = open_dhcp_sock();
    if (sock < 0) {
        info("dhcp-min: socket bind :68 failed (%s)", strerror(errno));
        return -1;
    }

    /* Random xid so concurrent neighbors don't collide. PID+time is
     * plenty unique inside a fresh VM. */
    uint32_t xid = (uint32_t)((getpid() << 16) ^ (uint32_t)time(NULL));

    /* --- DISCOVER --- */
    struct dhcp_pkt out, in;
    size_t out_len = build_dhcp(&out, xid, DHCP_DISCOVER, mac, 0, 0);
    size_t in_len = 0;
    if (dhcp_send_and_recv(sock, DHCP_OFFER, &out, out_len, &in, &in_len, xid) != 0) {
        info("dhcp-min: no OFFER received");
        close(sock); return -1;
    }

    uint32_t offered_ip = in.yiaddr;
    size_t opts_len = in_len - offsetof(struct dhcp_pkt, options);

    uint8_t sid_len = 0;
    const uint8_t *sid = find_opt(in.options, opts_len, OPT_SERVER_ID, &sid_len);
    uint32_t server_id = (sid && sid_len == 4) ? *(uint32_t *)sid : 0;

    /* --- REQUEST --- */
    out_len = build_dhcp(&out, xid, DHCP_REQUEST, mac, offered_ip, server_id);
    if (dhcp_send_and_recv(sock, DHCP_ACK, &out, out_len, &in, &in_len, xid) != 0) {
        info("dhcp-min: no ACK received");
        close(sock); return -1;
    }

    opts_len = in_len - offsetof(struct dhcp_pkt, options);
    uint8_t mlen = 0, glen = 0;
    const uint8_t *mp = find_opt(in.options, opts_len, OPT_SUBNET, &mlen);
    const uint8_t *gp = find_opt(in.options, opts_len, OPT_ROUTER, &glen);
    uint32_t netmask = (mp && mlen == 4) ? *(uint32_t *)mp : htonl(0xFFFFFF00);
    uint32_t gateway = (gp && glen >= 4) ? *(uint32_t *)gp : 0;

    close(sock);

    if (configure_iface(in.yiaddr, netmask, gateway) != 0) {
        info("dhcp-min: configure_iface failed (%s)", strerror(errno));
        return -1;
    }

    char ip_str[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &in.yiaddr, ip_str, sizeof(ip_str));
    info("dhcp-min: leased %s via internal client", ip_str);
    return 0;
}
