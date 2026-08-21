#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#define BUF_SIZE 4096

static void usage(const char *p)
{
    printf("Usage: %s -n name -a address -p port -m message [-t seconds]\n", p);
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int decode_message(const char *in, unsigned char *out, int max)
{
    int n = 0, h1, h2;
    const char *p;
    if (!in) return 0;
    if (!strncmp(in, "hex:", 4)) {
        p = in + 4;
        while (*p && n < max) {
            while (*p == ' ' || *p == ':' || *p == ',' || *p == '\\') p++;
            if (!p[0]) break;
            h1 = hexval(p[0]);
            h2 = hexval(p[1]);
            if (h1 < 0 || h2 < 0) return -1;
            out[n++] = (unsigned char)((h1 << 4) | h2);
            p += 2;
        }
        return n;
    }
    n = (int)strlen(in);
    if (n > max) n = max;
    memcpy(out, in, n);
    return n;
}

int main(int argc, char **argv)
{
    const char *name = "UDP";
    const char *addr = "255.255.255.255";
    const char *message = "";
    int port = 0, timeout = 3, opt;
    int fd, yes = 1, n, maxfd;
    unsigned char payload[BUF_SIZE], buf[BUF_SIZE];
    struct sockaddr_in dst, src;
    socklen_t sl = sizeof(src);
    fd_set rfds;
    struct timeval tv;

    while ((opt = getopt(argc, argv, "n:a:p:m:t:h")) != -1) {
        switch (opt) {
        case 'n': name = optarg; break;
        case 'a': addr = optarg; break;
        case 'p': port = atoi(optarg); break;
        case 'm': message = optarg; break;
        case 't': timeout = atoi(optarg); break;
        default: usage(argv[0]); return 2;
        }
    }
    if (port < 1 || port > 65535 || timeout < 1) {
        usage(argv[0]);
        return 2;
    }

    n = decode_message(message, payload, sizeof(payload));
    if (n < 0) {
        fprintf(stderr, "[%s] invalid hex payload\n", name);
        return 2;
    }

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 2;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((unsigned short)port);
    if (inet_aton(addr, &dst.sin_addr) == 0) {
        fprintf(stderr, "[%s] invalid address %s\n", name, addr);
        close(fd);
        return 2;
    }

    if (sendto(fd, payload, n, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        fprintf(stderr, "[%s] send failed: %s\n", name, strerror(errno));
        close(fd);
        return 1;
    }
    printf("[udp] name=%s dst=%s:%d probe sent\n", name, addr, port);
    fflush(stdout);

    maxfd = fd + 1;
    tv.tv_sec = timeout;
    tv.tv_usec = 0;
    while (select(maxfd, &rfds, NULL, NULL, &tv) > 0) {
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = timeout;
        tv.tv_usec = 0;
        if (select(maxfd, &rfds, NULL, NULL, &tv) <= 0) break;
        n = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&src, &sl);
        if (n <= 0) break;
        {
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &src.sin_addr, ip, sizeof(ip));
            printf("DEVICE type=UDP-CUSTOM NAME=%s IP=%s PORT=%d LEN=%d\n", name, ip, ntohs(src.sin_port), n);
            fflush(stdout);
        }
    }
    close(fd);
    return 0;
}
