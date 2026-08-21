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
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Use the kernel UAPI networking headers consistently.  The old Padavan
 * uClibc headers expose duplicate definitions when net/if.h/netpacket/packet.h
 * are mixed with linux/if_arp.h. */
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_arp.h>
#include <linux/if_packet.h>

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
static char self_mac[32];
static char self_ips[16][INET_ADDRSTRLEN];
static int self_ip_count;

static unsigned int get_ifindex(const char *ifname)
{
    int fd;
    struct ifreq ifr;

    if (!ifname || !*ifname)
        return 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return 0;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        close(fd);
        return 0;
    }
    close(fd);
    return (unsigned int)ifr.ifr_ifindex;
}

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

static int is_self_ip(const char *ip)
{
    int i;
    if (!ip || !*ip) return 0;
    for (i = 0; i < self_ip_count; i++)
        if (!strcmp(self_ips[i], ip)) return 1;
    return 0;
}

static void load_self_addresses(void)
{
    int fd;
    char buf[4096];
    struct ifconf ifc;
    struct ifreq *ifr;
    int i, n;

    self_ip_count = 0;
    self_mac[0] = 0;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    memset(&ifc, 0, sizeof(ifc));
    ifc.ifc_len = sizeof(buf);
    ifc.ifc_buf = buf;
    if (ioctl(fd, SIOCGIFCONF, &ifc) == 0) {
        n = ifc.ifc_len / (int)sizeof(struct ifreq);
        ifr = ifc.ifc_req;
        for (i = 0; i < n && self_ip_count < 16; i++) {
            struct sockaddr_in *sa = (struct sockaddr_in *)&ifr[i].ifr_addr;
            if (sa->sin_family == AF_INET &&
                inet_ntop(AF_INET, &sa->sin_addr, self_ips[self_ip_count], INET_ADDRSTRLEN))
                self_ip_count++;
        }
    }
    close(fd);
}

static void load_self_mac(const char *ifname)
{
    int fd;
    struct ifreq ifr;
    unsigned char *m;
    if (!ifname) return;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) == 0) {
        m = (unsigned char *)ifr.ifr_hwaddr.sa_data;
        snprintf(self_mac, sizeof(self_mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                 m[0], m[1], m[2], m[3], m[4], m[5]);
    }
    close(fd);
}

static void print_ipv4_device(const char *kind, const char *ip, const char *mac)
{
    char key[80];
    if (is_self_ip(ip)) return;
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
    if (is_self_ip(ip)) return;
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
    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0)
        perror("IP_MULTICAST_TTL");

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
    return (n == (ssize_t)len) ? 0 : -1;
}

static int send_onvif_probe(int fd, int port)
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
    return send_multicast(fd, ONVIF_ADDR, port, p, (size_t)n);
}

static int send_ssdp_probe(int fd, int port)
{
    static const char p[] =
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        "MAN: \"ssdp:discover\"\r\n"
        "MX: 2\r\n"
        "ST: ssdp:all\r\n"
        "USER-AGENT: Padavan-camdiscover/1.0\r\n\r\n";
    return send_multicast(fd, SSDP_ADDR, port, p, strlen(p));
}

static int send_hik_probe(int fd, int port)
{
    static const char p[] =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n"
        "<Probe>\r\n"
        "<Uuid>00000000-0000-0000-0000-000000000000</Uuid>\r\n"
        "<Types>inquiry</Types>\r\n"
        "</Probe>\r\n";
    return send_multicast(fd, HIK_ADDR, port, p, strlen(p));
}

static int send_dahua_probe(int fd, int port)
{
    unsigned char frame[320];
    unsigned int *u;
    static const char body[] =
        "{\"method\":\"DHDiscover.search\",\"params\":{\"mac\":\"\",\"uni\":1}}";
    size_t blen = strlen(body);

    if (blen + 32 > sizeof(frame))
        return -1;
    u = (unsigned int *)frame;
    u[0] = 32;
    u[1] = 0x50494844;
    u[2] = 0;
    u[3] = 0;
    u[4] = (unsigned int)blen;
    u[5] = 0;
    u[6] = (unsigned int)blen;
    u[7] = 0;
    memcpy(frame + 32, body, blen);
    return send_multicast(fd, DAHUA_ADDR, port, (const char *)frame, 32 + blen);
}

static void handle_onvif(int fd)
{
    char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char a[1024], t[1024], info[1200];
    char ip[INET_ADDRSTRLEN];

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
    x[n] = 0;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    a[0] = 0; t[0] = 0;
    extract_tag(x, "d:XAddrs", a, sizeof(a));
    if (!a[0]) extract_tag(x, "wsd:XAddrs", a, sizeof(a));
    if (!a[0]) extract_tag(x, "XAddrs", a, sizeof(a));
    extract_tag(x, "d:Types", t, sizeof(t));
    if (!t[0]) extract_tag(x, "wsd:Types", t, sizeof(t));
    if (a[0]) {
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
    char ip[INET_ADDRSTRLEN], info[512];
    const char *p;

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
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
    char ip[INET_ADDRSTRLEN], info[512];
    char desc[256], serial[256], dtype[128];

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
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
    char ip[INET_ADDRSTRLEN], info[512];
    const char *p;
    const char *q;
    size_t l;

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
    x[n] = 0;
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
    if (n < (ssize_t)sizeof(struct ethhdr)) return;

    proto = ntohs(*(unsigned short *)(buf + 12));
    ipoff = sizeof(struct ethhdr);
    if (proto == ETH_P_8021Q && n >= (ssize_t)(ipoff + 4)) {
        proto = ntohs(*(unsigned short *)(buf + 16));
        ipoff += 4;
    }
    mac_to_text(buf + 6, mac, sizeof(mac));
    if (self_mac[0] && !strcasecmp(mac, self_mac)) return;

    if (proto == ETH_P_ARP && n >= (ssize_t)(ipoff + sizeof(struct arphdr) + 20)) {
        ah = (struct arphdr *)(buf + ipoff);
        if (ntohs(ah->ar_hrd) == ARPHRD_ETHER && ntohs(ah->ar_pro) == ETH_P_IP) {
            unsigned char *arp = buf + ipoff + sizeof(struct arphdr);
            inet_ntop(AF_INET, arp + 6, ip, sizeof(ip));
            print_ipv4_device("ARP", ip, mac);
        }
        return;
    }

    if (proto == ETH_P_IP && n >= (ssize_t)(ipoff + sizeof(struct iphdr))) {
        ih = (struct iphdr *)(buf + ipoff);
        if (ih->version != 4 || ih->ihl < 5) return;
        if (ntohs(ih->tot_len) < ih->ihl * 4) return;
        inet_ntop(AF_INET, &ih->saddr, ip, sizeof(ip));
        if (strcmp(ip, "0.0.0.0") != 0 && strcmp(ip, "127.0.0.1") != 0)
            print_ipv4_device("IP", ip, mac);
    }
}

static void usage(const char *p)
{
    printf("Usage: %s [-i interface] [-t seconds] [-o onvif] [-s ssdp] [-k hik] [-d dahua] [-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1]\n", p);
    printf("  -i interface   discovery interface (default br0)\n");
    printf("  -t seconds     discovery window, 1..60 (default 10)\n");
    printf("  -o/-s/-k/-d    protocol destination ports\n");
    printf("  -O/-S/-H/-D    enable ONVIF/SSDP/HIK-SADP/DAHUA-DHIP\n");
    printf("  -A              enable ARP/IPv4 passive discovery\n");
}

int main(int argc, char **argv)
{
    const char *ifname = NULL;
    int timeout = 10;
    int onvif_port = ONVIF_PORT, ssdp_port = SSDP_PORT;
    int hik_port = HIK_PORT, dahua_port = DAHUA_PORT;
    int enable_onvif = 1, enable_ssdp = 1, enable_hik = 1;
    int enable_dahua = 1, enable_raw = 1;
    int opt;
    struct discover_ctx c;
    time_t end;
    int rc;

    memset(&c, 0, sizeof(c));
    c.fd_onvif = c.fd_ssdp = c.fd_hik = c.fd_dahua = c.fd_raw = -1;

    while ((opt = getopt(argc, argv, "i:t:o:s:k:d:O:S:H:D:A:h")) != -1) {
        if (opt == 'i') {
            ifname = optarg;
        } else if (opt == 't') {
            timeout = atoi(optarg);
            if (timeout < 1) timeout = 1;
            if (timeout > 60) timeout = 60;
        } else if (opt == 'o') onvif_port = atoi(optarg);
        else if (opt == 's') ssdp_port = atoi(optarg);
        else if (opt == 'k') hik_port = atoi(optarg);
        else if (opt == 'd') dahua_port = atoi(optarg);
        else if (opt == 'O') enable_onvif = atoi(optarg) ? 1 : 0;
        else if (opt == 'S') enable_ssdp = atoi(optarg) ? 1 : 0;
        else if (opt == 'H') enable_hik = atoi(optarg) ? 1 : 0;
        else if (opt == 'D') enable_dahua = atoi(optarg) ? 1 : 0;
        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;
        else {
            usage(argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    if (!ifname) ifname = "br0";
    c.ifname = ifname;
    c.ifindex = get_ifindex(ifname);
    load_self_addresses();
    load_self_mac(ifname);
    if (!c.ifindex) {
        fprintf(stderr, "camdiscover: interface %s not found\n", ifname);
        return 1;
    }

    printf("[camdiscover] interface=%s ifindex=%u timeout=%d ports=%d/%d/%d/%d protocols=%d%d%d%d raw=%d\n",
           c.ifname, c.ifindex, timeout, onvif_port, ssdp_port, hik_port, dahua_port,
           enable_onvif, enable_ssdp, enable_hik, enable_dahua, enable_raw);
    fflush(stdout);

    if (enable_onvif) c.fd_onvif = make_udp_receiver(ONVIF_ADDR, onvif_port, c.ifindex);
    if (enable_ssdp) c.fd_ssdp = make_udp_receiver(SSDP_ADDR, ssdp_port, c.ifindex);
    if (enable_hik) c.fd_hik = make_udp_receiver(HIK_ADDR, hik_port, c.ifindex);
    if (enable_dahua) c.fd_dahua = make_udp_receiver(DAHUA_ADDR, dahua_port, c.ifindex);

    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;
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
        rc = send_onvif_probe(c.fd_onvif, onvif_port);
        printf("[camdiscover] ONVIF probe %s\n", rc == 0 ? "sent" : "FAILED");
    } else printf("[camdiscover] ONVIF socket FAILED\n");
    if (c.fd_ssdp >= 0) {
        rc = send_ssdp_probe(c.fd_ssdp, ssdp_port);
        printf("[camdiscover] SSDP probe %s\n", rc == 0 ? "sent" : "FAILED");
    } else printf("[camdiscover] SSDP socket FAILED\n");
    if (c.fd_hik >= 0) {
        rc = send_hik_probe(c.fd_hik, hik_port);
        printf("[camdiscover] HIK-SADP probe %s\n", rc == 0 ? "sent" : "FAILED");
    } else printf("[camdiscover] HIK-SADP socket FAILED\n");
    if (c.fd_dahua >= 0) {
        rc = send_dahua_probe(c.fd_dahua, dahua_port);
        printf("[camdiscover] DAHUA-DHIP probe %s\n", rc == 0 ? "sent" : "FAILED");
    } else printf("[camdiscover] DAHUA-DHIP socket FAILED\n");
    fflush(stdout);

    end = time(NULL) + timeout;
    while (time(NULL) < end) {
        fd_set rfds;
        struct timeval tv;
        int maxfd = -1;
        int left = (int)(end - time(NULL));

        if (left < 0) left = 0;
        FD_ZERO(&rfds);
        if (c.fd_onvif >= 0) { FD_SET(c.fd_onvif, &rfds); if (c.fd_onvif > maxfd) maxfd = c.fd_onvif; }
        if (c.fd_ssdp >= 0) { FD_SET(c.fd_ssdp, &rfds); if (c.fd_ssdp > maxfd) maxfd = c.fd_ssdp; }
        if (c.fd_hik >= 0) { FD_SET(c.fd_hik, &rfds); if (c.fd_hik > maxfd) maxfd = c.fd_hik; }
        if (c.fd_dahua >= 0) { FD_SET(c.fd_dahua, &rfds); if (c.fd_dahua > maxfd) maxfd = c.fd_dahua; }
        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &rfds); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }
        if (maxfd < 0) break;

        tv.tv_sec = left > 1 ? 1 : left;
        tv.tv_usec = 0;
        if (select(maxfd + 1, &rfds, NULL, NULL, &tv) < 0)
            continue;
        if (c.fd_onvif >= 0 && FD_ISSET(c.fd_onvif, &rfds)) handle_onvif(c.fd_onvif);
        if (c.fd_ssdp >= 0 && FD_ISSET(c.fd_ssdp, &rfds)) handle_ssdp(c.fd_ssdp);
        if (c.fd_hik >= 0 && FD_ISSET(c.fd_hik, &rfds)) handle_hik(c.fd_hik);
        if (c.fd_dahua >= 0 && FD_ISSET(c.fd_dahua, &rfds)) handle_dahua(c.fd_dahua);
        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &rfds)) handle_raw(c.fd_raw);
    }

    if (c.fd_onvif >= 0) close(c.fd_onvif);
    if (c.fd_ssdp >= 0) close(c.fd_ssdp);
    if (c.fd_hik >= 0) close(c.fd_hik);
    if (c.fd_dahua >= 0) close(c.fd_dahua);
    if (c.fd_raw >= 0) close(c.fd_raw);
    return 0;
}
