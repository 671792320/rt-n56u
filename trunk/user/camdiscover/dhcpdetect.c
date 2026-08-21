/* DHCP server presence detector for Padavan/Q7.
 * Sends a raw DHCPDISCOVER and only listens for matching OFFER/ACK replies.
 * It never installs a lease or changes the interface address.
 * Exit: 0 DHCP found, 1 no DHCP/error.
 */
#include <arpa/inet.h>
#include <getopt.h>
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DHCP_CLIENT_PORT 68
#define DHCP_SERVER_PORT 67
#define DHCP_COOKIE 0x63825363UL
#define DHCP_DISCOVER 1
#define DHCP_OFFER 2
#define DHCP_ACK 5

struct dhcp_packet {
    unsigned char op, htype, hlen, hops;
    unsigned int xid;
    unsigned short secs, flags;
    unsigned int ciaddr, yiaddr, siaddr, giaddr;
    unsigned char chaddr[16];
    unsigned char sname[64];
    unsigned char file[128];
    unsigned char options[312];
};

static unsigned short ip_checksum(const void *data, int len)
{
    const unsigned short *p = (const unsigned short *)data;
    unsigned int sum = 0;
    while (len > 1) { sum += *p++; len -= 2; }
    if (len) sum += *(const unsigned char *)p << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (unsigned short)~sum;
}

static int get_ifinfo(const char *ifname, int *ifindex, unsigned char mac[6])
{
    int fd; struct ifreq ifr;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) { close(fd); return -1; }
    *ifindex = ifr.ifr_ifindex;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) { close(fd); return -1; }
    memcpy(mac, ifr.ifr_hwaddr.sa_data, 6);
    close(fd); return 0;
}

static int send_discover(int fd, int ifindex, const unsigned char mac[6], unsigned int xid)
{
    unsigned char frame[1600];
    struct ethhdr *eth = (struct ethhdr *)frame;
    unsigned char *ip = frame + ETH_HLEN;
    unsigned char *udp = ip + 20;
    struct dhcp_packet *d = (struct dhcp_packet *)(udp + 8);
    struct sockaddr_ll to;
    unsigned char *o;
    int dhcplen, iplen;

    memset(frame, 0, sizeof(frame));
    memset(eth->h_dest, 0xff, ETH_ALEN);
    memcpy(eth->h_source, mac, ETH_ALEN);
    eth->h_proto = htons(ETH_P_IP);
    memset(d, 0, sizeof(*d));
    d->op = 1; d->htype = 1; d->hlen = 6; d->xid = htonl(xid);
    d->flags = htons(0x8000); memcpy(d->chaddr, mac, 6);
    o = d->options;
    *(unsigned int *)o = htonl(DHCP_COOKIE); o += 4;
    *o++ = 53; *o++ = 1; *o++ = DHCP_DISCOVER;
    *o++ = 55; *o++ = 4; *o++ = 1; *o++ = 3; *o++ = 6; *o++ = 15;
    *o++ = 61; *o++ = 7; *o++ = 1; memcpy(o, mac, 6); o += 6;
    *o++ = 255;
    dhcplen = (int)((unsigned char *)o - (unsigned char *)d);

    memset(ip, 0, 20); ip[0] = 0x45; ip[8] = 64; ip[9] = IPPROTO_UDP;
    iplen = 20 + 8 + dhcplen;
    *(unsigned short *)(ip + 2) = htons((unsigned short)iplen);
    *(unsigned int *)(ip + 12) = htonl(INADDR_ANY);
    *(unsigned int *)(ip + 16) = htonl(INADDR_BROADCAST);
    *(unsigned short *)(ip + 10) = ip_checksum(ip, 20);
    *(unsigned short *)(udp + 0) = htons(DHCP_CLIENT_PORT);
    *(unsigned short *)(udp + 2) = htons(DHCP_SERVER_PORT);
    *(unsigned short *)(udp + 4) = htons((unsigned short)(8 + dhcplen));
    *(unsigned short *)(udp + 6) = 0;

    memset(&to, 0, sizeof(to)); to.sll_family = AF_PACKET;
    to.sll_ifindex = ifindex; to.sll_halen = ETH_ALEN;
    memset(to.sll_addr, 0xff, ETH_ALEN);
    return sendto(fd, frame, ETH_HLEN + iplen, 0,
                  (struct sockaddr *)&to, sizeof(to)) < 0 ? -1 : 0;
}

static int parse_reply(const unsigned char *buf, int len, unsigned int xid,
                       const unsigned char mac[6], char *server, size_t sn,
                       char *offer, size_t on)
{
    const struct ethhdr *eth; const unsigned char *ip, *udp, *p, *end;
    const struct dhcp_packet *d; unsigned int cookie, server_addr = 0;
    int ihl, dhcplen, type = 0;
    if (len < ETH_HLEN + 20 + 8 + 240) return 0;
    eth = (const struct ethhdr *)buf;
    if (ntohs(eth->h_proto) != ETH_P_IP) return 0;
    ip = buf + ETH_HLEN; if ((ip[0] >> 4) != 4) return 0;
    ihl = (ip[0] & 15) * 4;
    if (ihl < 20 || len < ETH_HLEN + ihl + 8 || ip[9] != IPPROTO_UDP) return 0;
    udp = ip + ihl;
    if (ntohs(*(const unsigned short *)(udp + 0)) != DHCP_SERVER_PORT ||
        ntohs(*(const unsigned short *)(udp + 2)) != DHCP_CLIENT_PORT) return 0;
    d = (const struct dhcp_packet *)(udp + 8);
    dhcplen = len - ETH_HLEN - ihl - 8;
    if (dhcplen < 240 || d->op != 2 || ntohl(d->xid) != xid) return 0;
    if (memcmp(d->chaddr, mac, 6) != 0) return 0;
    memcpy(&cookie, d->options, 4); if (ntohl(cookie) != DHCP_COOKIE) return 0;
    p = d->options + 4; end = d->options + dhcplen - 236;
    while (p < end) {
        unsigned int code = *p++, olen;
        if (code == 0) continue; if (code == 255) break;
        if (p >= end) break; olen = *p++; if (p + olen > end) break;
        if (code == 53 && olen >= 1) type = p[0];
        else if (code == 54 && olen == 4) memcpy(&server_addr, p, 4);
        p += olen;
    }
    if (server && sn && server_addr) inet_ntop(AF_INET, &server_addr, server, sn);
    if (offer && on) inet_ntop(AF_INET, &d->yiaddr, offer, on);
    return type;
}

static void usage(const char *p)
{
    printf("Usage: %s [-i interface] [-t seconds]\n", p);
    printf("  -i interface   interface (default eth2.1)\n");
    printf("  -t seconds     timeout 1..10 (default 3)\n");
}

int main(int argc, char **argv)
{
    const char *ifname = "eth2.1"; int timeout = 3, opt, ifindex, fd, i;
    unsigned char mac[6], buf[2048]; unsigned int xid; struct sockaddr_ll ba;
    time_t end; char server[INET_ADDRSTRLEN] = "-", offer[INET_ADDRSTRLEN] = "-";
    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        if (opt == 'i') ifname = optarg;
        else if (opt == 't') { timeout = atoi(optarg); if (timeout < 1) timeout = 1; if (timeout > 10) timeout = 10; }
        else { usage(argv[0]); return opt == 'h' ? 0 : 1; }
    }
    if (get_ifinfo(ifname, &ifindex, mac) < 0) {
        fprintf(stderr, "[dhcpdetect] interface %s unavailable\n", ifname); return 1;
    }
    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) { perror("[dhcpdetect] socket"); return 1; }
    memset(&ba, 0, sizeof(ba)); ba.sll_family = AF_PACKET; ba.sll_ifindex = ifindex; ba.sll_protocol = htons(ETH_P_ALL);
    if (bind(fd, (struct sockaddr *)&ba, sizeof(ba)) < 0) { perror("[dhcpdetect] bind"); close(fd); return 1; }
    xid = (unsigned int)time(NULL) ^ (unsigned int)getpid() ^ ((unsigned int)mac[2] << 16) ^ ((unsigned int)mac[5] << 8);
    printf("[dhcpdetect] interface=%s timeout=%d\n", ifname, timeout);
    for (i = 0; i < 2; i++) if (send_discover(fd, ifindex, mac, xid + i) < 0) { perror("[dhcpdetect] DHCPDISCOVER"); close(fd); return 1; }
    end = time(NULL) + timeout;
    while (time(NULL) < end) {
        fd_set rfds; struct timeval tv; int left = (int)(end - time(NULL)), n;
        if (left < 1) left = 1; tv.tv_sec = left > 1 ? 1 : left; tv.tv_usec = 0;
        FD_ZERO(&rfds); FD_SET(fd, &rfds); n = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (n <= 0) continue; n = recv(fd, buf, sizeof(buf), 0); if (n <= 0) continue;
        for (i = 0; i < 2; i++) {
            int type = parse_reply(buf, n, xid + i, mac, server, sizeof(server), offer, sizeof(offer));
            if (type == DHCP_OFFER || type == DHCP_ACK) {
                printf("[dhcpdetect] DHCP server found type=%s server=%s offer=%s\n",
                       type == DHCP_OFFER ? "OFFER" : "ACK", server, offer);
                close(fd); return 0;
            }
        }
    }
    printf("[dhcpdetect] no DHCP server reply\n"); close(fd); return 1;
}
