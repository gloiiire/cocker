/*
 * cmdline.c — read and parse the Linux kernel command line passed by cockerd.
 *
 * cockerd encodes per-container parameters as `cocker.<key>=<value>` tokens
 * separated by spaces. We don't pull in the kernel option parser ; a small
 * substring scan is enough.
 */

#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include "cocker_init.h"

int read_cmdline(char *buf, size_t size) {
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    char *nl = strchr(buf, '\n');
    if (nl) *nl = '\0';
    return 0;
}

char *cmdline_get(const char *cmdline, const char *key) {
    char needle[256];
    snprintf(needle, sizeof(needle), "cocker.%s=", key);
    const char *p = cmdline;
    size_t needle_len = strlen(needle);

    while ((p = strstr(p, needle))) {
        /* Token must start at the beginning of cmdline or be space-prefixed */
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
