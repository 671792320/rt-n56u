/*
 * camdiscover - lightweight multicast discovery helper for Padavan/Q7.
 *
 * First stage implements ONVIF WS-Discovery without external libraries.
 * The program deliberately only reports discoveries; network configuration
 * belongs to the future q7netmgr component.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define ONVIF_ADDR "239.255.255.250"
#define ONVIF_PORT 3702
#define BUF_SIZE 4096
#define DEFAULT_TIMEOUT 3

static void usage(const char *p)
{
    printf("Usage: %s [-i interface] [-t seconds]\n", p);
    printf("  -i IFACE   network interface\n");
    printf("  -t SEC     discovery timeout (default %d)\n", DEFAULT_TIMEOUT);
}

static void extract_xml_value(const char *xml, const char *tag, char *out, size_t n)
{
    char open[64], close[64];
    const char *a, *b;
    size_t len;

    if (!xml || !tag || !out || n == 0)
        return;
    snprintf(open, sizeof(open), "<%s>", tag);
    snprintf(close, sizeof(close), "</%s>", tag);
    a = strstr(xml, open);
    if (!a)
        return;
    a += strlen(open);
    b = strstr(a, close);
    if (!b)
        return;
    len = (size_t)(b - a);
    if (len >= n)
        len = n - 1;
    memcpy(out, a, len);
    out[len] = '\0';
}

static int send_probe(int fd, const struct sockaddr_in *dst)
{
    char probe[2048];
    unsigned long now = (unsigned long)time(NULL);
    int n;

    n = snprintf(probe, sizeof(probe),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\""
        " xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\""
        " xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\""
        " xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">"
        "<e:Header>"
        "<w:MessageID>uuid:camdiscover-%lu</w:MessageID>"
        "<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
        "<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
        "</e:Header>"
        "<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>"
        "<d:Scopes/></d:Probe></e:Body></e:Envelope>", now);

    if (n < 0 || n >= (int)sizeof(probe))
        return -1;

    return (int)sendto(fd, probe, (size_t)n, 0,
                       (const struct sockaddr *)dst, sizeof(*dst));
}

static void receive_replies(int fd, int timeout)
{
    fd_set rfds;
    struct timeval tv;
    struct sockaddr_in src;
    socklen_t slen;
    char buf[BUF_SIZE];
    int left = timeout;

    while (left > 0) {
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = left;
        tv.tv_usec = 0;

        if (select(fd + 1, &rfds, NULL, NULL, &tv) <= 0)
            break;

        slen = sizeof(src);
        memset(&src, 0, sizeof(src));
        {
            ssize_t r = recvfrom(fd, buf, sizeof(buf) - 1, 0,
                                 (struct sockaddr *)&src, &slen);
            char xaddr[512] = "";
            char scopes[1024] = "";
            char types[512] = "";
            if (r <= 0)
                continue;
            buf[r] = '\0';
            extract_xml_value(buf, "d:XAddrs", xaddr, sizeof(xaddr));
            extract_xml_value(buf, "d:Scopes", scopes, sizeof(scopes));
            extract_xml_value(buf, "d:Types", types, sizeof(types));
            printf("ONVIF IP=%s", inet_ntoa(src.sin_addr));
            if (xaddr[0])
                printf(" XAddrs=%s", xaddr);
            if (types[0])
                printf(" Types=%s", types);
            if (scopes[0])
                printf(" Scopes=%s", scopes);
            printf("\n");
            fflush(stdout);
        }
        left = 1;
    }
}

int main(int argc, char **argv)
{
    int fd, timeout = DEFAULT_TIMEOUT, opt;
    const char *ifname = NULL;
    struct sockaddr_in bind_addr, dst;
    struct ip_mreqn mreq;
    unsigned int ifindex = 0;
    int ttl = 1;
    int reuse = 1;

    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 't':
            timeout = atoi(optarg);
            if (timeout < 1) timeout = 1;
            if (timeout > 30) timeout = 30;
            break;
        case 'h':
        default:
            usage(argv[0]);
            return (opt == 'h') ? 0 : 1;
        }
    }

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0)
        perror("SO_REUSEADDR");

    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(ONVIF_PORT);
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        close(fd);
        return 1;
    }

    if (ifname) {
        ifindex = if_nametoindex(ifname);
        if (!ifindex) {
            fprintf(stderr, "interface not found: %s\n", ifname);
            close(fd);
            return 1;
        }
    }

    memset(&mreq, 0, sizeof(mreq));
    inet_aton(ONVIF_ADDR, &mreq.imr_multiaddr);
    mreq.imr_address.s_addr = htonl(INADDR_ANY);
    mreq.imr_ifindex = (int)ifindex;
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        perror("IP_ADD_MEMBERSHIP");
        close(fd);
        return 1;
    }

    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0)
        perror("IP_MULTICAST_TTL");

    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(ONVIF_PORT);
    inet_aton(ONVIF_ADDR, &dst.sin_addr);

    if (send_probe(fd, &dst) < 0) {
        perror("sendto");
        close(fd);
        return 1;
    }

    receive_replies(fd, timeout);
    close(fd);
    return 0;
}
