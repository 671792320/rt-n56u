/* Comprehensive LAN device discovery helper for Padavan.
 *
 * Active discovery:
 *   - ONVIF WS-Discovery: 239.255.255.250:3702
 *   - SSDP/UPnP:          239.255.255.250:1900
 *   - Hikvision SADP:    239.255.255.250:37020
 *   - Dahua DHIP:        239.255.255.251:37810
 *
 * Passive discovery:
 *   - ARP packets
 *   - IPv4 packets seen on the selected interface
 *
 * The selected interface may be a VLAN such as eth2.1 with no IPv4
 * address. Multicast transmission is explicitly bound to the interface
 * index instead of relying on the routing table.
 */
#include <arpa/inet.h>
#include <getopt.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netpacket/packet.h>
#include <linux/if_ether.h>
#include <linux/if_arp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

#define ONVIF_ADDR      "239.255.255.250"
#define ONVIF_PORT      3702
#define SSDP_ADDR       "239.255.255.250"
#define SSDP_PORT       1900
#define HIK_ADDR        "239.255.255.250"
#define HIK_PORT        37020
#define DAHUA_ADDR      "239.255.255.251"
#define DAHUA_PORT      37810
#define BUF_SIZE        8192
#define MAX_DEVICES     256

struct discover_ctx {
    int fd_onvif;
    int fd_ssdp;
    int fd_hik;
    int fd_dahua;
    int fd_raw;
    const char *ifname;
    unsigned int ifindex;
};

struct seen_entry {
    char key[80];
};

static struct seen_entry seen[MAX_DEVICES];
static int seen_count;

static int seen_add(const char *key)
{
    int i;
    if (!key || !*key)
        return 0;
    for (i = 0; i < seen_count; i++) {
        if (!strcmp(seen[i].key, key))
            return 0;
    }
    if (seen_count < MAX_DEVICES) {
        strncpy(seen[seen_count].key, key, sizeof(seen[seen_count].key) - 1);
        seen[seen_count].key[sizeof(seen[seen_count].key) - 1] = 0;
        seen_count++;
    }
    return 1;
}

static void extract_tag(const char *x, const char *tag, char *o, size_t n)
{
    char a[96], b[96];
    const char *p, *q;
    size_t l;

    if (!x || !tag || !o || !n)
        return;
    snprintf(a, sizeof(a), "<%s>", tag);
    snprintf(b, sizeof(b), "</%s>", tag);
    p = strstr(x, a);
    if (!p)
        return;
    p += strlen(a);
    q = strstr(p, b);
    if (!q)
        return;
    l = (size_t)(q - p);
    if (l >= n)
        l = n - 1;
    memcpy(o, p, l);
    o[l] = 0;
}

static void print_ipv4_device(const char *kind, const char *ip, const char *mac)
{
    char key[80];
    snprintf(key, sizeof(key), "%s:%s:%s", kind, ip ? ip : "", mac ? mac : "");
    if (!seen_add(key))
        return;
    printf("DEVICE type=%s IP=%s", kind, ip ? ip : "-");
    if (mac && *mac)
        printf(" MAC=%s", mac);
    printf("\n");
    fflush(stdout);
}

static void print_text_device(const char *kind, const char *ip, const char *text)
{
    char key[80];
    snprintf(key, sizeof(key), "%s:%s", kind, ip ? ip : "");
    if (!seen_add(key))
        return;
    printf("DEVICE type=%s IP=%s", kind, ip ? ip : "-");
    if (text && *text)
        printf(" INFO=%s", text);
    printf("\n");
    fflush(stdout);
}

static int make_udp_receiver(const char *group, int port, unsigned int ifindex)
{
    int fd, reuse = 1, ttl = 2;
    struct sockaddr_in b;
    struct ip_mreqn m;
    struct ip_mreqn mi;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket UDP");
        return -1;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0) {
        perror("SO_REUSEADDR");
        close(fd);
        return -1;
    }

    memset(&b, 0, sizeof(b));
    b.sin_family = AF_INET;
    b.sin_port = htons((unsigned short)port);
    b.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&b, sizeof(b)) < 0) {
        perror("bind UDP");
        close(fd);
        return -1;
    }

    memset(&mi, 0, sizeof(mi));
    mi.imr_ifindex = (int)ifindex;
    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &mi, sizeof(mi)) < 0) {
        perror("IP_MULTICAST_IF");
        close(fd);
        return -1;
    }
    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0) {
        perror("IP_MULTICAST_TTL");
    }

    memset(&m, 0, sizeof(m));
    if (!inet_aton(group, &m.imr_multiaddr)) {
        fprintf(stderr, "bad multicast address: %s\n", group);
        close(fd);
        return -1;
    }
    m.imr_ifindex = (int)ifindex;
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, sizeof(m)) < 0) {
        perror("IP_ADD_MEMBERSHIP");
        close(fd);
        return -1;
    }
    return fd;
}

static int send_multicast(int fd, const char *group, int port, const char *data, size_t len)
{
    struct sockaddr_in d;
    ssize_t n;

    memset(&d, 0, sizeof(d));
    d.sin_family = AF_INET;
    d.sin_port = htons((unsigned short)port);
    if (!inet_aton(group, &d.sin_addr))
        return -1;

    n = sendto(fd, data, len, 0, (struct sockaddr *)&d, sizeof(d));
    if (n < 0) {
        return -1;
    }
    return (n == (ssize_t)len) ? 0 : -1;
}

static int send_onvif_probe(int fd)
{
    char p[2048];
    int n;

    n = snprintf(p, sizeof(p),
        "<?xml version=\"1.0\"?>"
        "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" "
        "xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" "
        "xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" "
        "xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">"
        "<e:Header>"
        "<w:MessageID>uuid:camdiscover-%lu</w:MessageID>"
        "<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
        "<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
        "</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>"
        "</d:Probe></e:Body></e:Envelope>", (unsigned long)time(NULL));
    if (n < 0 || n >= (int)sizeof(p))
        return -1;
    return send_multicast(fd, ONVIF_ADDR, ONVIF_PORT, p, (size_t)n);
}

static int send_ssdp_probe(int fd)
{
    static const char p[] =
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        "MAN: \"ssdp:discover\"\r\n"
        "MX: 2\r\n"
        "ST: ssdp:all\r\n"
        "USER-AGENT: Padavan-camdiscover/1.0\r\n\r\n";
    return send_multicast(fd, SSDP_ADDR, SSDP_PORT, p, strlen(p));
}

static int send_hik_probe(int fd)
{
    static const char p[] =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n"
        "<Probe>\r\n"
        "<Uuid>00000000-0000-0000-0000-000000000000</Uuid>\r\n"
        "<Types>inquiry</Types>\r\n"
        "</Probe>\r\n";
    return send_multicast(fd, HIK_ADDR, HIK_PORT, p, strlen(p));
}

static int send_dahua_probe(int fd)
{
    char body[256];
    unsigned char frame[320];
    unsigned int *u;
    size_t blen;

    static const char method[] =
        "{\"method\":\"DHDiscover.search\",\"params\":{\"mac\":\"\",\"uni\":1}}";
    blen = strlen(method);
    if (blen + 32 > sizeof(frame))
        return -1;
    memcpy(body, method, blen + 1);

    u = (unsigned int *)frame;
    u[0] = 32;
    u[1] = 0x50494844; /* "DHIP" */
    u[2] = 0;
    u[3] = 0;
    u[4] = (unsigned int)blen;
    u[5] = 0;
    u[6] = (unsigned int)blen;
    u[7] = 0;
    memcpy(frame + 32, body, blen);
    return send_multicast(fd, DAHUA_ADDR, DAHUA_PORT, (const char *)frame, 32 + blen);
}

static void handle_onvif(int fd)
{
    char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char a[1024], t[1024];
    char ip[INET_ADDRSTRLEN];

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0)
        return;
    x[n] = 0;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    a[0] = 0;
    t[0] = 0;
    extract_tag(x, "d:XAddrs", a, sizeof(a));
    if (!a[0]) extract_tag(x, "wsd:XAddrs", a, sizeof(a));
    if (!a[0]) extract_tag(x, "XAddrs", a, sizeof(a));
    extract_tag(x, "d:Types", t, sizeof(t));
    if (!t[0]) extract_tag(x, "wsd:Types", t, sizeof(t));
    if (a[0]) {
        char info[1200];
        snprintf(info, sizeof(info), "XAddrs=%s Types=%s", a, t);
        print_text_device("ONVIF", ip, info);
    } else {
        print_text_device("ONVIF", ip, t);
    }
}

static void handle_ssdp(int fd)
{
    char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char ip[INET_ADDRSTRLEN];
    char info[512];
    const char *p;

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0)
        return;
    x[n] = 0;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    info[0] = 0;
    p = strstr(x, "Server:");
    if (!p) p = strstr(x, "SERVER:");
    if (p) {
        p += 7;
        while (*p == ' ' || *p == '\t') p++;
        snprintf(info, sizeof(info), "SSDP Server=%.*s", 200, p);
    } else if (strstr(x, "NOTIFY")) {
        snprintf(info, sizeof(info), "SSDP NOTIFY");
    } else {
        snprintf(info, sizeof(info), "SSDP response");
    }
    print_text_device("SSDP", ip, info);
}

static void handle_hik(int fd)
{
    char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char ip[INET_ADDRSTRLEN];
    char info[512];
    char desc[256], serial[256], dtype[128];

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0)
        return;
    x[n] = 0;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    desc[0] = serial[0] = dtype[0] = 0;
    extract_tag(x, "DeviceDescription", desc, sizeof(desc));
    extract_tag(x, "DeviceSN", serial, sizeof(serial));
    extract_tag(x, "DeviceType", dtype, sizeof(dtype));
    snprintf(info, sizeof(info), "Model=%s SN=%s DeviceType=%s", desc, serial, dtype);
    print_text_device("HIK-SADP", ip, info);
}

static void handle_dahua(int fd)
{
    unsigned char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char ip[INET_ADDRSTRLEN];
    char info[512];
    const char *p;
    const char *q;
    size_t l;

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0)
        return;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    p = (const char *)x;
    q = strstr(p, "deviceInfo");
    if (q) {
        l = (size_t)(q - p);
        if (l > 250) l = 250;
        snprintf(info, sizeof(info), "DHIP response %.*s", (int)l, q);
    } else {
        snprintf(info, sizeof(info), "DHIP discovery response len=%ld", (long)n);
    }
    print_text_device("DAHUA-DHIP", ip, info);
}

static void mac_to_text(const unsigned char *m, char *out, size_t n)
{
    snprintf(out, n, "%02x:%02x:%02x:%02x:%02x:%02x",
             m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void handle_raw(int fd)
{
    unsigned char buf[4096];
    struct sockaddr_ll from;
    socklen_t fl = sizeof(from);
    ssize_t n;
    unsigned short proto;
    unsigned int ipoff;
    char mac[32], ip[INET_ADDRSTRLEN];
    struct iphdr *ih;
    struct arphdr *ah;

    n = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);
    if (n < (ssize_t)sizeof(struct ethhdr))
        return;

    proto = ntohs(*(unsigned short *)(buf + 12));
    ipoff = sizeof(struct ethhdr);
    if (proto == ETH_P_8021Q && n >= (ssize_t)(ipoff + 4)) {
        proto = ntohs(*(unsigned short *)(buf + 16));
        ipoff += 4;
    }

    mac_to_text(buf + 6, mac, sizeof(mac));

    if (proto == ETH_P_ARP && n >= (ssize_t)(ipoff + sizeof(struct arphdr) + 8)) {
        ah = (struct arphdr *)(buf + ipoff);
        if (ntohs(ah->ar_hrd) == ARPHRD_ETHER && ntohs(ah->ar_pro) == ETH_P_IP) {
            unsigned char *arp = buf + ipoff + sizeof(struct arphdr);
            if (n >= (ssize_t)(ipoff + sizeof(struct arphdr) + 20)) {
                inet_ntop(AF_INET, arp + 6, ip, sizeof(ip));
                print_ipv4_device("ARP", ip, mac);
            }
        }
        return;
    }

    if (proto == ETH_P_IP && n >= (ssize_t)(ipoff + sizeof(struct iphdr))) {
        ih = (struct iphdr *)(buf + ipoff);
        if (ih->version != 4 || ih->ihl < 5)
            return;
        if (ntohs(ih->tot_len) < ih->ihl * 4)
            return;
        inet_ntop(AF_INET, &ih->saddr, ip, sizeof(ip));
        if (strcmp(ip, "0.0.0.0") != 0 && strcmp(ip, "127.0.0.1") != 0)
            print_ipv4_device("IP", ip, mac);
    }
}

static void usage(const char *p)
{
    printf("Usage: %s [-i interface] [-t seconds]\n", p);
    printf("  -i interface   interface to discover on (recommended: eth2.1)\n");
    printf("  -t seconds     discovery window, 1..60 (default 10)\n");
    printf("\nActive: ONVIF, SSDP/UPnP, Hikvision SADP, Dahua DHIP\n");
    printf("Passive: ARP and IPv4 device observation\n");
}

int main(int argc, char **argv)
{
    const char *ifname = NULL;
    int timeout = 10;
    int opt;
    struct discover_ctx c;
    time_t end;
    int rc;

    memset(&c, 0, sizeof(c));
    c.fd_onvif = c.fd_ssdp = c.fd_hik = c.fd_dahua = c.fd_raw = -1;

    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        if (opt == 'i') {
            ifname = optarg;
        } else if (opt == 't') {
            timeout = atoi(optarg);
            if (timeout < 1) timeout = 1;
            if (timeout > 60) timeout = 60;
        } else {
            usage(argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    if (!ifname)
        ifname = "br0";
    c.ifname = ifname;
    c.ifindex = if_nametoindex(ifname);
    if (!c.ifindex) {
        fprintf(stderr, "camdiscover: interface %s not found\n", ifname);
        return 1;
    }

    printf("[camdiscover] interface=%s ifindex=%u timeout=%d\n",
           c.ifname, c.ifindex, timeout);
    fflush(stdout);

    c.fd_onvif = make_udp_receiver(ONVIF_ADDR, ONVIF_PORT, c.ifindex);
    c.fd_ssdp = make_udp_receiver(SSDP_ADDR, SSDP_PORT, c.ifindex);
    c.fd_hik = make_udp_receiver(HIK_ADDR, HIK_PORT, c.ifindex);
    c.fd_dahua = make_udp_receiver(DAHUA_ADDR, DAHUA_PORT, c.ifindex);

    c.fd_raw = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (c.fd_raw >= 0) {
        struct sockaddr_ll sll;
        memset(&sll, 0, sizeof(sll));
        sll.sll_family = AF_PACKET;
        sll.sll_ifindex = (int)c.ifindex;
        sll.sll_protocol = htons(ETH_P_ALL);
        if (bind(c.fd_raw, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
            perror("bind raw");
            close(c.fd_raw);
            c.fd_raw = -1;
        }
    } else {
        perror("socket AF_PACKET");
    }

    if (c.fd_onvif >= 0) {
        rc = send_onvif_probe(c.fd_onvif);
        printf("[camdiscover] ONVIF probe %s\n", rc == 0 ? "sent" : "FAILED");
    }
    if (c.fd_ssdp >= 0) {
        rc = send_ssdp_probe(c.fd_ssdp);
        printf("[camdiscover] SSDP probe %s\n", rc == 0 ? "sent" : "FAILED");
    }
    if (c.fd_hik >= 0) {
        rc = send_hik_probe(c.fd_hik);
        printf("[camdiscover] HIK-SADP probe %s\n", rc == 0 ? "sent" : "FAILED");
    }
    if (c.fd_dahua >= 0) {
        rc = send_dahua_probe(c.fd_dahua);
        printf("[camdiscover] DAHUA-DHIP probe %s\n", rc == 0 ? "sent" : "FAILED");
    }
    fflush(stdout);

    end = time(NULL) + timeout;
    while (time(NULL) < end) {
        fd_set r;
        struct timeval tv;
        int maxfd = -1;

        FD_ZERO(&r);
        if (c.fd_onvif >= 0) { FD_SET(c.fd_onvif, &r); if (c.fd_onvif > maxfd) maxfd = c.fd_onvif; }
        if (c.fd_ssdp >= 0) { FD_SET(c.fd_ssdp, &r); if (c.fd_ssdp > maxfd) maxfd = c.fd_ssdp; }
        if (c.fd_hik >= 0) { FD_SET(c.fd_hik, &r); if (c.fd_hik > maxfd) maxfd = c.fd_hik; }
        if (c.fd_dahua >= 0) { FD_SET(c.fd_dahua, &r); if (c.fd_dahua > maxfd) maxfd = c.fd_dahua; }
        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &r); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }
        if (maxfd < 0)
            break;

        tv.tv_sec = (long)(end - time(NULL));
        tv.tv_usec = 0;
        if (tv.tv_sec < 0)
            break;
        rc = select(maxfd + 1, &r, NULL, NULL, &tv);
        if (rc <= 0)
            continue;

        if (c.fd_onvif >= 0 && FD_ISSET(c.fd_onvif, &r)) handle_onvif(c.fd_onvif);
        if (c.fd_ssdp >= 0 && FD_ISSET(c.fd_ssdp, &r)) handle_ssdp(c.fd_ssdp);
        if (c.fd_hik >= 0 && FD_ISSET(c.fd_hik, &r)) handle_hik(c.fd_hik);
        if (c.fd_dahua >= 0 && FD_ISSET(c.fd_dahua, &r)) handle_dahua(c.fd_dahua);
        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &r)) handle_raw(c.fd_raw);
    }

    if (c.fd_onvif >= 0) close(c.fd_onvif);
    if (c.fd_ssdp >= 0) close(c.fd_ssdp);
    if (c.fd_hik >= 0) close(c.fd_hik);
    if (c.fd_dahua >= 0) close(c.fd_dahua);
    if (c.fd_raw >= 0) close(c.fd_raw);

    printf("[camdiscover] finished devices=%d\n", seen_count);
    fflush(stdout);
    return 0;
}
