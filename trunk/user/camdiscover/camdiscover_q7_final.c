/* Q7 LAN discovery final helper.
 * The discovery socket can use a temporary target-LAN source IPv4 stored in
 * /tmp/lan_discovery_runtime/lan_discovery_status_target_ip.  This keeps the
 * original standard probes and the WebUI custom-probe interface usable.
 */
#include <arpa/inet.h>
#include <getopt.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>

#define ONVIF_ADDR "239.255.255.250"
#define SSDP_ADDR "239.255.255.250"
#define HIK_ADDR "239.255.255.250"
#define DAHUA_ADDR "239.255.255.251"
#define ONVIF_PORT 3702
#define SSDP_PORT 1900
#define HIK_PORT 37020
#define DAHUA_PORT 37810
#define BUF_SIZE 8192
#define MAX_CUSTOM 128
#define MAX_NAME 64
#define MAX_ADDR 64
#define MAX_PAYLOAD 1024
#define MAX_SEEN 512

struct custom_probe {
    int fd;
    int port;
    char name[MAX_NAME];
    char addr[MAX_ADDR];
    char payload[MAX_PAYLOAD];
};

struct discover_ctx {
    int fd_onvif, fd_ssdp, fd_hik, fd_dahua, fd_raw;
    const char *ifname;
    unsigned int ifindex;
    struct in_addr source_addr;
    int has_source_addr;
    struct custom_probe custom[MAX_CUSTOM];
    int custom_count;
};

static char seen[MAX_SEEN][128];
static int seen_count;

static unsigned int get_ifindex(const char *ifname)
{
    int fd;
    struct ifreq ifr;
    if (!ifname || !*ifname) return 0;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 0;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) { close(fd); return 0; }
    close(fd);
    return (unsigned int)ifr.ifr_ifindex;
}

static int seen_add(const char *key)
{
    int i;
    if (!key || !*key) return 0;
    for (i = 0; i < seen_count; ++i) if (!strcmp(seen[i], key)) return 0;
    if (seen_count < MAX_SEEN) {
        strncpy(seen[seen_count], key, sizeof(seen[seen_count]) - 1);
        seen[seen_count][sizeof(seen[seen_count]) - 1] = 0;
        ++seen_count;
    }
    return 1;
}

static void print_device(const char *kind, const char *ip, const char *info)
{
    char key[128];
    if (!ip || !*ip) return;
    snprintf(key, sizeof(key), "%s:%s", kind ? kind : "IP", ip);
    if (!seen_add(key)) return;
    printf("DEVICE type=%s IP=%s", kind ? kind : "IP", ip);
    if (info && *info) printf(" INFO=%s", info);
    printf("\n");
    fflush(stdout);
}

static void hex_encode(const unsigned char *buf, size_t len, char *out, size_t outlen)
{
    static const char h[] = "0123456789ABCDEF";
    size_t i, n = 0, max = len > 48 ? 48 : len;
    if (!outlen) return;
    for (i = 0; i < max && n + 2 < outlen; ++i) {
        out[n++] = h[(buf[i] >> 4) & 0x0f];
        out[n++] = h[buf[i] & 0x0f];
    }
    out[n] = 0;
}

static int url_hex(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void url_decode(char *out, size_t n, const char *in)
{
    size_t i = 0, j = 0;
    while (in && in[i] && j + 1 < n) {
        if (in[i] == '%' && in[i + 1] && in[i + 2]) {
            int a = url_hex(in[i + 1]), b = url_hex(in[i + 2]);
            if (a >= 0 && b >= 0) { out[j++] = (char)((a << 4) | b); i += 3; continue; }
        }
        out[j++] = in[i] == '+' ? ' ' : in[i];
        ++i;
    }
    out[j] = 0;
}

static int bind_source(int fd, const struct in_addr *source, int has_source)
{
    struct sockaddr_in a;
    if (!has_source || !source || source->s_addr == INADDR_ANY) return 0;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr = *source;
    a.sin_port = 0;
    return bind(fd, (struct sockaddr *)&a, sizeof(a));
}

static int make_udp_receiver(const char *group, int port, unsigned int ifindex,
                             const struct in_addr *source, int has_source)
{
    int fd, reuse = 1, ttl = 2, loop = 0;
    struct sockaddr_in b;
    struct ip_mreqn m, mi;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    memset(&b, 0, sizeof(b));
    b.sin_family = AF_INET;
    b.sin_port = htons((unsigned short)port);
    b.sin_addr.s_addr = (has_source && source) ? source->s_addr : htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&b, sizeof(b)) < 0) { close(fd); return -1; }

    memset(&mi, 0, sizeof(mi));
    if (has_source && source) mi.imr_address = *source;
    mi.imr_ifindex = (int)ifindex;
    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &mi, sizeof(mi)) < 0) { close(fd); return -1; }
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop));

    memset(&m, 0, sizeof(m));
    if (!inet_aton(group, &m.imr_multiaddr)) { close(fd); return -1; }
    if (has_source && source) m.imr_address = *source;
    m.imr_ifindex = (int)ifindex;
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, sizeof(m)) < 0) { close(fd); return -1; }
    return fd;
}

static int send_to_addr(int fd, const char *addr, int port, const void *data, size_t len)
{
    struct sockaddr_in d;
    ssize_t n;
    memset(&d, 0, sizeof(d));
    d.sin_family = AF_INET;
    d.sin_port = htons((unsigned short)port);
    if (!inet_aton(addr, &d.sin_addr)) return -1;
    n = sendto(fd, data, len, 0, (struct sockaddr *)&d, sizeof(d));
    return n == (ssize_t)len ? 0 : -1;
}

static int send_onvif(int fd)
{
    char p[2048];
    int n = snprintf(p, sizeof(p),
        "<?xml version=\"1.0\"?><e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><e:Header><w:MessageID>uuid:q7-camdiscover-%lu</w:MessageID><w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>",
        (unsigned long)time(NULL));
    return n > 0 && n < (int)sizeof(p) ? send_to_addr(fd, ONVIF_ADDR, ONVIF_PORT, p, (size_t)n) : -1;
}

static int send_ssdp(int fd)
{
    static const char p[] =
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\nUSER-AGENT: Padavan-Q7-camdiscover/1.0\r\n\r\n";
    return send_to_addr(fd, SSDP_ADDR, SSDP_PORT, p, strlen(p));
}

static int send_hik(int fd)
{
    static const char p[] =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<Probe>\r\n<Uuid>00000000-0000-0000-0000-000000000000</Uuid>\r\n<Types>inquiry</Types>\r\n</Probe>\r\n";
    return send_to_addr(fd, HIK_ADDR, HIK_PORT, p, strlen(p));
}

static int send_dahua(int fd)
{
    unsigned char frame[320];
    unsigned int *u = (unsigned int *)frame;
    static const char body[] = "{\"method\":\"DHDiscover.search\",\"params\":{\"mac\":\"\",\"uni\":1}}";
    size_t blen = strlen(body);
    if (blen + 32 > sizeof(frame)) return -1;
    memset(frame, 0, sizeof(frame));
    u[0] = 32; u[1] = 0x50494844; u[4] = (unsigned int)blen; u[6] = (unsigned int)blen;
    memcpy(frame + 32, body, blen);
    return send_to_addr(fd, DAHUA_ADDR, DAHUA_PORT, frame, 32 + blen);
}

static const char *find_ci(const char *s, const char *needle)
{
    size_t n;
    const char *p;
    if (!s || !needle || !*needle) return NULL;
    n = strlen(needle);
    for (p = s; *p; ++p) if (!strncasecmp(p, needle, n)) return p;
    return NULL;
}

static void extract_line_ci(const char *buf, const char *name, char *out, size_t n)
{
    const char *p;
    size_t i = 0;
    if (!out || !n) return;
    out[0] = 0;
    p = find_ci(buf, name);
    if (!p) return;
    p += strlen(name);
    while (*p == ' ' || *p == '\t' || *p == ':') ++p;
    while (*p && *p != '\r' && *p != '\n' && i + 1 < n) out[i++] = *p++;
    out[i] = 0;
}

static void handle_standard(int fd, const char *kind)
{
    unsigned char x[BUF_SIZE];
    char ip[INET_ADDRSTRLEN], info[1200], location[900], server[400], hex[160];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;

    n = recvfrom(fd, x, sizeof(x) - 1, 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
    x[n] = 0;
    if (!inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip))) return;
    location[0] = server[0] = info[0] = 0;

    if (!strcmp(kind, "SSDP")) {
        extract_line_ci((char *)x, "LOCATION", location, sizeof(location));
        extract_line_ci((char *)x, "SERVER", server, sizeof(server));
        if (location[0]) snprintf(info, sizeof(info), "LOCATION=%s SERVER=%s", location, server);
        else if (server[0]) snprintf(info, sizeof(info), "SERVER=%s", server);
        else snprintf(info, sizeof(info), "SSDP response");
    } else if (!strcmp(kind, "ONVIF")) {
        extract_line_ci((char *)x, "XAddrs", location, sizeof(location));
        if (location[0]) snprintf(info, sizeof(info), "XAddrs=%s", location);
        else snprintf(info, sizeof(info), "ONVIF response");
    } else {
        hex_encode(x, (size_t)n, hex, sizeof(hex));
        snprintf(info, sizeof(info), "%s response len=%ld HEX=%s", kind, (long)n, hex);
    }

    print_device(kind, ip, info);
    printf("[camdiscover] %s RX %s:%d bytes=%ld\n", kind, ip, ntohs(s.sin_port), (long)n);
    fflush(stdout);
}

static int load_custom(const char *path, struct discover_ctx *c)
{
    FILE *f;
    char line[1800], *a, *b, *d, *e;
    int i;
    f = fopen(path, "r");
    if (!f) return 0;
    while (fgets(line, sizeof(line), f) && c->custom_count < MAX_CUSTOM) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        a = strchr(line, '|'); if (!a) continue; *a++ = 0;
        b = strchr(a, '|'); if (!b) continue; *b++ = 0;
        d = strchr(b, '|'); if (!d) continue; *d++ = 0;
        e = strchr(d, '|'); if (!e) continue; *e++ = 0;
        if (strcmp(e, "1")) continue;
        i = c->custom_count++;
        c->custom[i].fd = -1;
        url_decode(c->custom[i].name, sizeof(c->custom[i].name), line);
        url_decode(c->custom[i].addr, sizeof(c->custom[i].addr), a);
        c->custom[i].port = atoi(b);
        url_decode(c->custom[i].payload, sizeof(c->custom[i].payload), d);
        c->custom[i].fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (c->custom[i].fd >= 0 && bind_source(c->custom[i].fd, &c->source_addr, c->has_source_addr) < 0) {
            close(c->custom[i].fd); c->custom[i].fd = -1;
        }
        if (c->custom[i].fd >= 0) {
            int reuse = 1; struct sockaddr_in rb;
            setsockopt(c->custom[i].fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
            memset(&rb, 0, sizeof(rb)); rb.sin_family = AF_INET; rb.sin_port = htons((unsigned short)c->custom[i].port); rb.sin_addr.s_addr = htonl(INADDR_ANY);
            if (bind(c->custom[i].fd, (struct sockaddr *)&rb, sizeof(rb)) < 0) { close(c->custom[i].fd); c->custom[i].fd = -1; }
        }
        if (c->custom[i].fd < 0) fprintf(stdout, "[camdiscover] custom %s listen UDP/%d FAILED\n", c->custom[i].name, c->custom[i].port);
        else fprintf(stdout, "[camdiscover] custom %s listen %s:%d\n", c->custom[i].name, c->custom[i].addr, c->custom[i].port);
        fflush(stdout);
    }
    fclose(f);
    return c->custom_count;
}

static void send_custom(struct discover_ctx *c)
{
    int i, fd, rc;
    for (i = 0; i < c->custom_count; ++i) {
        fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) continue;
        if (bind_source(fd, &c->source_addr, c->has_source_addr) < 0) { close(fd); continue; }
        rc = send_to_addr(fd, c->custom[i].addr, c->custom[i].port,
                          c->custom[i].payload, strlen(c->custom[i].payload));
        printf("[camdiscover] custom %s probe %s\n", c->custom[i].name, rc == 0 ? "sent" : "FAILED");
        fflush(stdout);
        close(fd);
    }
}

static void handle_custom(struct custom_probe *p)
{
    unsigned char x[BUF_SIZE];
    char ip[INET_ADDRSTRLEN], info[128];
    struct sockaddr_in s; socklen_t sl = sizeof(s); ssize_t n;
    n = recvfrom(p->fd, x, sizeof(x), 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
    if (!inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip))) return;
    snprintf(info, sizeof(info), "%s response len=%ld", p->name, (long)n);
    print_device(p->name, ip, info);
    printf("[camdiscover] custom %s RX %s:%d bytes=%ld\n", p->name, ip, ntohs(s.sin_port), (long)n);
    fflush(stdout);
}

static int load_source(const char *explicit_source, struct in_addr *out)
{
    FILE *f; char buf[64];
    if (explicit_source && inet_aton(explicit_source, out)) return 1;
    f = fopen("/tmp/lan_discovery_runtime/lan_discovery_status_target_ip", "r");
    if (!f) return 0;
    if (!fgets(buf, sizeof(buf), f)) { fclose(f); return 0; }
    fclose(f);
    buf[strcspn(buf, "\r\n \t")] = 0;
    return inet_aton(buf, out) ? 1 : 0;
}

int main(int argc, char **argv)
{
    struct discover_ctx c;
    const char *ifname = NULL, *custom_path = NULL, *explicit_source = NULL;
    int timeout = 10, onvif = 1, ssdp = 1, hik = 1, dahua = 1, raw = 1;
    int onvif_port = ONVIF_PORT, ssdp_port = SSDP_PORT, hik_port = HIK_PORT, dahua_port = DAHUA_PORT;
    int opt, rc, i, maxfd;
    struct timeval tv; fd_set rfds; time_t end;

    memset(&c, 0, sizeof(c));
    c.fd_onvif = c.fd_ssdp = c.fd_hik = c.fd_dahua = c.fd_raw = -1;

    while ((opt = getopt(argc, argv, "i:t:o:s:k:d:O:S:H:D:A:C:I:")) != -1) {
        switch (opt) {
        case 'i': ifname = optarg; break;
        case 't': timeout = atoi(optarg); break;
        case 'o': onvif_port = atoi(optarg); break;
        case 's': ssdp_port = atoi(optarg); break;
        case 'k': hik_port = atoi(optarg); break;
        case 'd': dahua_port = atoi(optarg); break;
        case 'O': onvif = atoi(optarg) != 0; break;
        case 'S': ssdp = atoi(optarg) != 0; break;
        case 'H': hik = atoi(optarg) != 0; break;
        case 'D': dahua = atoi(optarg) != 0; break;
        case 'A': raw = atoi(optarg) != 0; break;
        case 'C': custom_path = optarg; break;
        case 'I': explicit_source = optarg; break;
        default: break;
        }
    }
    if (!ifname) ifname = "br0";
    if (timeout < 1) timeout = 1;
    if (timeout > 60) timeout = 60;
    c.ifname = ifname;
    c.ifindex = get_ifindex(ifname);
    c.has_source_addr = load_source(explicit_source, &c.source_addr);
    if (!c.ifindex) { fprintf(stderr, "[camdiscover] interface %s not found\n", ifname); return 1; }

    if (onvif) c.fd_onvif = make_udp_receiver(ONVIF_ADDR, onvif_port, c.ifindex, &c.source_addr, c.has_source_addr);
    if (ssdp) c.fd_ssdp = make_udp_receiver(SSDP_ADDR, ssdp_port, c.ifindex, &c.source_addr, c.has_source_addr);
    if (hik) c.fd_hik = make_udp_receiver(HIK_ADDR, hik_port, c.ifindex, &c.source_addr, c.has_source_addr);
    if (dahua) c.fd_dahua = make_udp_receiver(DAHUA_ADDR, dahua_port, c.ifindex, &c.source_addr, c.has_source_addr);
    if (raw) {
        c.fd_raw = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
        if (c.fd_raw >= 0) {
            struct sockaddr_ll sll; memset(&sll, 0, sizeof(sll));
            sll.sll_family = AF_PACKET; sll.sll_ifindex = (int)c.ifindex; sll.sll_protocol = htons(ETH_P_ALL);
            if (bind(c.fd_raw, (struct sockaddr *)&sll, sizeof(sll)) < 0) { close(c.fd_raw); c.fd_raw = -1; }
        }
    }
    if (custom_path) load_custom(custom_path, &c);

    printf("[camdiscover] iface=%s ifindex=%u timeout=%d source=%s\n", c.ifname, c.ifindex, timeout,
           c.has_source_addr ? (explicit_source && *explicit_source ? explicit_source : "runtime") : "auto");
    printf("[camdiscover] sockets ONVIF=%d SSDP=%d HIK=%d DAHUA=%d RAW=%d custom=%d\n",
           c.fd_onvif, c.fd_ssdp, c.fd_hik, c.fd_dahua, c.fd_raw, c.custom_count);
    printf("[camdiscover] probes enabled: ONVIF=%d SSDP=%d HIK=%d DAHUA=%d ARP=%d\n", onvif, ssdp, hik, dahua, raw);
    fflush(stdout);

    if (c.custom_count) send_custom(&c);
    if (c.fd_onvif >= 0) { rc = send_to_addr(c.fd_onvif, ONVIF_ADDR, onvif_port, "", 0); (void)rc; }
    if (c.fd_onvif >= 0) { rc = send_onvif(c.fd_onvif); printf("[camdiscover] ONVIF probe %s\n", rc == 0 ? "sent" : "FAILED"); }
    if (c.fd_ssdp >= 0) { rc = send_ssdp(c.fd_ssdp); printf("[camdiscover] SSDP probe %s\n", rc == 0 ? "sent" : "FAILED"); }
    if (c.fd_hik >= 0) { rc = send_hik(c.fd_hik); printf("[camdiscover] HIK probe %s\n", rc == 0 ? "sent" : "FAILED"); }
    if (c.fd_dahua >= 0) { rc = send_dahua(c.fd_dahua); printf("[camdiscover] DAHUA probe %s\n", rc == 0 ? "sent" : "FAILED"); }
    fflush(stdout);

    end = time(NULL) + timeout;
    while (time(NULL) < end) {
        FD_ZERO(&rfds); maxfd = -1;
        if (c.fd_onvif >= 0) { FD_SET(c.fd_onvif, &rfds); if (c.fd_onvif > maxfd) maxfd = c.fd_onvif; }
        if (c.fd_ssdp >= 0) { FD_SET(c.fd_ssdp, &rfds); if (c.fd_ssdp > maxfd) maxfd = c.fd_ssdp; }
        if (c.fd_hik >= 0) { FD_SET(c.fd_hik, &rfds); if (c.fd_hik > maxfd) maxfd = c.fd_hik; }
        if (c.fd_dahua >= 0) { FD_SET(c.fd_dahua, &rfds); if (c.fd_dahua > maxfd) maxfd = c.fd_dahua; }
        for (i = 0; i < c.custom_count; ++i) if (c.custom[i].fd >= 0) { FD_SET(c.custom[i].fd, &rfds); if (c.custom[i].fd > maxfd) maxfd = c.custom[i].fd; }
        if (maxfd < 0) break;
        tv.tv_sec = 1; tv.tv_usec = 0;
        rc = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (rc <= 0) continue;
        if (c.fd_onvif >= 0 && FD_ISSET(c.fd_onvif, &rfds)) handle_standard(c.fd_onvif, "ONVIF");
        if (c.fd_ssdp >= 0 && FD_ISSET(c.fd_ssdp, &rfds)) handle_standard(c.fd_ssdp, "SSDP");
        if (c.fd_hik >= 0 && FD_ISSET(c.fd_hik, &rfds)) handle_standard(c.fd_hik, "HIK");
        if (c.fd_dahua >= 0 && FD_ISSET(c.fd_dahua, &rfds)) handle_standard(c.fd_dahua, "DAHUA");
        for (i = 0; i < c.custom_count; ++i) if (c.custom[i].fd >= 0 && FD_ISSET(c.custom[i].fd, &rfds)) handle_custom(&c.custom[i]);
    }

    if (c.fd_onvif >= 0) close(c.fd_onvif);
    if (c.fd_ssdp >= 0) close(c.fd_ssdp);
    if (c.fd_hik >= 0) close(c.fd_hik);
    if (c.fd_dahua >= 0) close(c.fd_dahua);
    if (c.fd_raw >= 0) close(c.fd_raw);
    for (i = 0; i < c.custom_count; ++i) if (c.custom[i].fd >= 0) close(c.custom[i].fd);
    return 0;
}
