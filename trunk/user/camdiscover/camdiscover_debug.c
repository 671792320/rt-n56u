#include <stdio.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>

/*
 * Transparent recvfrom wrapper.  camdiscover.c is compiled with
 * -Drecvfrom=camdiscover_recvfrom.  Keep this wrapper silent in production:
 * packet-level RX diagnostics are not useful to the WebUI and can flood the
 * system log when many devices answer multicast/broadcast probes.
 */
ssize_t camdiscover_recvfrom(int fd, void *buf, size_t len, int flags,
                             struct sockaddr *src, socklen_t *srclen)
{
    (void)fd;
    (void)buf;
    (void)len;
    return recvfrom(fd, buf, len, flags, src, srclen);
}
