#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/*
 * recvmsg-based wrapper used only by camdiscover.c.  camdiscover.c is built
 * with -Drecvfrom=camdiscover_recvfrom, while this file is compiled normally,
 * so the wrapper can provide realtime RX diagnostics without changing the
 * discovery parser itself.
 */
static void print_safe_rx(const char *ip, unsigned int port, int fd, ssize_t n)
{
    if (ip && *ip)
        fprintf(stdout, "[camdiscover] RX fd=%d src=%s:%u bytes=%ld\n", fd, ip, port, (long)n);
    else
        fprintf(stdout, "[camdiscover] RX fd=%d bytes=%ld\n", fd, (long)n);
    fflush(stdout);
}

ssize_t camdiscover_recvfrom(int fd, void *buf, size_t len, int flags,
                             struct sockaddr *src, socklen_t *srclen)
{
    struct iovec iov;
    struct msghdr msg;
    ssize_t n;
    char ip[INET6_ADDRSTRLEN];
    unsigned int port = 0;

    memset(&msg, 0, sizeof(msg));
    memset(&iov, 0, sizeof(iov));
    iov.iov_base = buf;
    iov.iov_len = len;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_name = src;
    msg.msg_namelen = srclen ? *srclen : 0;

    n = recvmsg(fd, &msg, flags);
    if (n < 0)
        return n;

    if (srclen)
        *srclen = msg.msg_namelen;

    ip[0] = 0;
    if (src && msg.msg_namelen >= sizeof(sa_family_t)) {
        if (src->sa_family == AF_INET && msg.msg_namelen >= sizeof(struct sockaddr_in)) {
            const struct sockaddr_in *a = (const struct sockaddr_in *)src;
            inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
            port = ntohs(a->sin_port);
        } else if (src->sa_family == AF_INET6 && msg.msg_namelen >= sizeof(struct sockaddr_in6)) {
            const struct sockaddr_in6 *a6 = (const struct sockaddr_in6 *)src;
            inet_ntop(AF_INET6, &a6->sin6_addr, ip, sizeof(ip));
            port = ntohs(a6->sin6_port);
        }
    }

    /* Never dump packet contents or arbitrary bytes to stdout. */
    print_safe_rx(ip, port, fd, n);
    return n;
}
