/*
 * dns_proxy.c — in-VM DNS proxy that bridges /etc/resolv.conf to cockerd.
 *
 * Apps in the container read /etc/resolv.conf which has no port column,
 * so they query 127.0.0.1:53. We spawn a child that binds UDP :53 (PID 1
 * runs as root inside the VM, no capabilities issue) and tunnels each
 * datagram to cockerd over vsock using DNS-over-TCP framing
 * (RFC 1035 §4.2.2 — 2-byte length prefix + DNS message).
 *
 * Why vsock and not TCP/UDP via vmnet : Apple's App Sandbox silently
 * drops payload data from the vmnet kernel extension to user-signed
 * daemons (cockerd). vsock bypasses vmnet entirely.
 */

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/vm_sockets.h>
#include "cocker_init.h"

/* Forward one DNS query over a fresh vsock TCP-stream connection to
 * (CID=2, vsock_port). Returns the number of response bytes (>0) on
 * success, -1 on any error. Caller passes the raw DNS query bytes. */
static int dns_vsock_forward(unsigned int vsock_port,
                             const char *query, size_t qlen,
                             char *response, size_t resp_max) {
    int sfd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (sfd < 0) return -1;

    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(sfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_vm dst;
    memset(&dst, 0, sizeof(dst));
    dst.svm_family = AF_VSOCK;
    dst.svm_cid = 2;  /* VMADDR_CID_HOST */
    dst.svm_port = vsock_port;

    if (connect(sfd, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        close(sfd); return -1;
    }

    /* 2-byte length prefix + query body */
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

    /* Response : 2-byte length, then body. */
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

pid_t dns_proxy_spawn(unsigned int vsock_port) {
    pid_t pid = fork();
    if (pid < 0) {
        info("dns-proxy fork: %s", strerror(errno));
        return -1;
    }
    if (pid != 0) {
        info("dns-proxy spawned (pid=%d, upstream=vsock CID=2 port=%u via TCP)",
             pid, vsock_port);
        return pid;
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
        fprintf(stderr, "[cocker-init] dns-proxy bind :53: %s\n", strerror(errno));
        _exit(1);
    }

    /* Iterative loop. DNS queries are tiny and sub-millisecond ; one in
     * flight at a time is plenty for any reasonable workload. */
    char query[65536];
    char response[65536];
    for (;;) {
        struct sockaddr_in client;
        socklen_t cl = sizeof(client);
        ssize_t n = recvfrom(listen_fd, query, sizeof(query), 0,
                             (struct sockaddr *)&client, &cl);
        if (n <= 0) continue;

        int m = dns_vsock_forward(vsock_port, query, (size_t)n,
                                  response, sizeof(response));
        if (m <= 0) continue;  /* upstream silent — swallow, client times out */

        sendto(listen_fd, response, m, 0, (struct sockaddr *)&client, cl);
    }
}
