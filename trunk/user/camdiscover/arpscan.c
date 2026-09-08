/*
 * Q7主动ARP扫描工具。
 *
 * 设计目标：
 * 1. 在同一个二层广播域内主动探测指定IPv4网段，而不是等待设备自己发ARP。
 * 2. 只处理ARP，不抓取普通IPv4流量，避免把局域网中的电脑、手机、服务器等
 *    普通主机全部当成“未知设备”被动计入设备列表。
 * 3. 一个进程批量发送整段ARP请求，再统一等待响应，避免启动数百个arping进程。
 * 4. Q7的eth2.1是VLAN接口，可能没有自己的IPv4地址；这种情况下使用br0的
 *    IPv4/掩码作为扫描参考和ARP源地址，但ARP帧仍然从eth2.1发出。
 * 5. 默认扫描本机接口所在/24网段；可以通过多个-s参数追加其它已发现网段。
 * 6. DHCP检测完成后，如果检测到了上级网关，则自动把网关所在/24加入扫描，
 *    这样Q7自身是192.168.2.1、现场网关是192.168.1.1时，也能继续主动扫描192.168.1.0/24。
 * 7. 兼容802.1Q VLAN封装的ARP回包，并输出发送/接收统计，便于现场排查。
 */
#include <arpa/inet.h>
#include <getopt.h>
#include <linux/if.h>
#include <linux/if_arp.h>
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

#define MAX_SUBNETS 16
#define MAC_TEXT_LEN 32
#define IP_TEXT_LEN 16
#define BUF_SIZE 2048
#define ETH_FRAME_MIN 60

typedef struct {
    unsigned int network;
    unsigned int mask;
    int prefix;
} subnet_t;

static unsigned long total_sent;
static unsigned long total_received;
static unsigned long total_valid;

static int parse_ipv4(const char *text, unsigned int *out)
{
    struct in_addr a;
    if (!text || !out || inet_aton(text, &a) == 0)
        return -1;
    *out = ntohl(a.s_addr);
    return 0;
}

static void ipv4_text(unsigned int ip, char *out, size_t out_len)
{
    struct in_addr a;
    a.s_addr = htonl(ip);
    if (!inet_ntop(AF_INET, &a, out, out_len))
        snprintf(out, out_len, "0.0.0.0");
}

static int parse_subnet(const char *text, subnet_t *out)
{
    char buf[64], *slash;
    unsigned int ip, mask;
    int prefix;

    if (!text || !out)
        return -1;
    snprintf(buf, sizeof(buf), "%s", text);
    slash = strchr(buf, '/');
    if (!slash)
        return -1;
    *slash++ = 0;
    prefix = atoi(slash);
    if (prefix != 24)
        return -1;
    if (parse_ipv4(buf, &ip) < 0)
        return -1;
    mask = 0xffffff00U;
    out->network = ip & mask;
    out->mask = mask;
    out->prefix = prefix;
    return 0;
}

static int subnet_equal(const subnet_t *a, const subnet_t *b)
{
    return a->network == b->network && a->prefix == b->prefix;
}

static int add_subnet(subnet_t *list, int *count, const subnet_t *s)
{
    int i;
    if (!list || !count || !s || s->prefix != 24)
        return -1;
    for (i = 0; i < *count; ++i)
        if (subnet_equal(&list[i], s))
            return 0;
    if (*count >= MAX_SUBNETS)
        return -1;
    list[*count] = *s;
    (*count)++;
    return 0;
}

static int get_iface_index_mac(int fd, const char *ifname, int *ifindex,
                               unsigned char mac[6])
{
    struct ifreq ifr;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0)
        return -1;
    *ifindex = ifr.ifr_ifindex;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0)
        return -1;
    memcpy(mac, ifr.ifr_hwaddr.sa_data, 6);
    return 0;
}

static int get_iface_ipv4(int fd, const char *ifname, unsigned int *ip, unsigned int *mask)
{
    struct ifreq ifr;
    struct sockaddr_in *sa;

    if (!ifname || !ip || !mask)
        return -1;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) != 0)
        return -1;
    sa = (struct sockaddr_in *)&ifr.ifr_addr;
    if (sa->sin_family != AF_INET)
        return -1;
    *ip = ntohl(sa->sin_addr.s_addr);

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFNETMASK, &ifr) != 0)
        return -1;
    sa = (struct sockaddr_in *)&ifr.ifr_netmask;
    if (sa->sin_family != AF_INET)
        return -1;
    *mask = ntohl(sa->sin_addr.s_addr);
    return 0;
}

static int get_ifinfo(const char *ifname, int *ifindex, unsigned char mac[6],
                      unsigned int *ip, unsigned int *mask)
{
    int fd;
    int ip_ok = 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;

    if (get_iface_index_mac(fd, ifname, ifindex, mac) < 0) {
        close(fd);
        return -1;
    }

    /* Q7的eth2.1通常没有L3地址，所以回退到br0获取本机IPv4。 */
    if (get_iface_ipv4(fd, ifname, ip, mask) == 0) {
        ip_ok = 1;
    } else if (strcmp(ifname, "br0") != 0 && get_iface_ipv4(fd, "br0", ip, mask) == 0) {
        ip_ok = 1;
    }

    close(fd);
    return ip_ok ? 0 : -1;
}

static void mac_text(const unsigned char *m, char *out, size_t out_len)
{
    snprintf(out, out_len, "%02x:%02x:%02x:%02x:%02x:%02x",
             m[0], m[1], m[2], m[3], m[4], m[5]);
}

static int same_mac(const unsigned char *a, const unsigned char *b)
{
    return memcmp(a, b, 6) == 0;
}

static int send_arp_request(int fd, int ifindex, const unsigned char src_mac[6],
                            unsigned int src_ip, unsigned int target_ip)
{
    unsigned char frame[ETH_FRAME_MIN];
    struct ethhdr *eth = (struct ethhdr *)frame;
    struct arphdr *arp = (struct arphdr *)(frame + ETH_HLEN);
    unsigned char *p = frame + ETH_HLEN + sizeof(struct arphdr);
    struct sockaddr_ll to;

    memset(frame, 0, sizeof(frame));
    memset(eth->h_dest, 0xff, ETH_ALEN);
    memcpy(eth->h_source, src_mac, ETH_ALEN);
    eth->h_proto = htons(ETH_P_ARP);

    arp->ar_hrd = htons(ARPHRD_ETHER);
    arp->ar_pro = htons(ETH_P_IP);
    arp->ar_hln = ETH_ALEN;
    arp->ar_pln = 4;
    arp->ar_op = htons(ARPOP_REQUEST);

    memcpy(p, src_mac, 6);
    memcpy(p + 6, &src_ip, 4);
    memset(p + 10, 0, 6);
    memcpy(p + 16, &target_ip, 4);

    memset(&to, 0, sizeof(to));
    to.sll_family = AF_PACKET;
    to.sll_ifindex = ifindex;
    to.sll_halen = ETH_ALEN;
    memset(to.sll_addr, 0xff, ETH_ALEN);

    if (sendto(fd, frame, sizeof(frame), 0,
               (struct sockaddr *)&to, sizeof(to)) == (ssize_t)sizeof(frame)) {
        total_sent++;
        return 0;
    }
    return -1;
}

static int handle_arp(const unsigned char *buf, int len,
                      const unsigned char self_mac[6], unsigned int self_ip)
{
    const struct ethhdr *eth;
    const struct arphdr *arp;
    const unsigned char *p;
    unsigned int sender_ip;
    char ip[IP_TEXT_LEN], mac[MAC_TEXT_LEN];
    unsigned short op, proto;
    int off = ETH_HLEN;

    if (len < ETH_HLEN)
        return 0;

    total_received++;
    eth = (const struct ethhdr *)buf;
    proto = ntohs(eth->h_proto);

    /* 兼容802.1Q VLAN封装的ARP回包。 */
    if (proto == ETH_P_8021Q) {
        if (len < ETH_HLEN + 4)
            return 0;
        proto = ntohs(*(const unsigned short *)(buf + 16));
        off += 4;
    }

    if (proto != ETH_P_ARP)
        return 0;
    if (len < off + (int)sizeof(struct arphdr) + 20)
        return 0;

    arp = (const struct arphdr *)(buf + off);
    if (ntohs(arp->ar_pro) != ETH_P_IP || arp->ar_hln != 6 || arp->ar_pln != 4)
        return 0;
    op = ntohs(arp->ar_op);
    if (op != ARPOP_REPLY && op != ARPOP_REQUEST)
        return 0;

    p = buf + off + sizeof(struct arphdr);
    memcpy(&sender_ip, p + 6, 4);
    if (ntohl(sender_ip) == self_ip || same_mac(p, self_mac))
        return 0;

    ipv4_text(ntohl(sender_ip), ip, sizeof(ip));
    mac_text(p, mac, sizeof(mac));
    total_valid++;
    printf("DEVICE type=ARP IP=%s MAC=%s\n", ip, mac);
    fflush(stdout);
    return 1;
}

static int scan_subnet(int fd, int ifindex, const unsigned char mac[6],
                       unsigned int src_ip, const subnet_t *s)
{
    unsigned int host;
    unsigned int target;
    char network[IP_TEXT_LEN];

    ipv4_text(s->network, network, sizeof(network));
    printf("[arpscan] 扫描网段 %s/%d\n", network, s->prefix);
    fflush(stdout);

    for (host = 1; host < 255; ++host) {
        target = s->network | host;
        if (target == src_ip)
            continue;
        send_arp_request(fd, ifindex, mac, htonl(src_ip), htonl(target));
    }
    return 0;
}

static void add_dhcp_gateway_subnet(subnet_t *subnets, int *subnet_count)
{
    FILE *f;
    char line[512], gateway[IP_TEXT_LEN];
    subnet_t s;
    char network[IP_TEXT_LEN];

    f = fopen("/tmp/dhcpdetect_lan.log", "r");
    if (!f)
        return;

    gateway[0] = 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = strstr(line, "gateway=");
        if (!p)
            continue;
        p += 8;
        if (sscanf(p, "%15s", gateway) == 1)
            break;
    }
    fclose(f);

    if (!gateway[0] || parse_ipv4(gateway, &s.network) < 0)
        return;
    s.mask = 0xffffff00U;
    s.network &= s.mask;
    s.prefix = 24;

    if (add_subnet(subnets, subnet_count, &s) == 0) {
        ipv4_text(s.network, network, sizeof(network));
        printf("[arpscan] 根据DHCP网关自动加入网段 %s/24\n", network);
        fflush(stdout);
    }
}

int main(int argc, char **argv)
{
    const char *ifname = "eth2.1";
    int timeout = 2, opt, ifindex, fd, i;
    unsigned char mac[6], buf[BUF_SIZE];
    unsigned int ip = 0, mask = 0;
    subnet_t subnets[MAX_SUBNETS];
    int subnet_count = 0;
    fd_set rfds;
    struct timeval tv;
    time_t end;
    char source_ip[IP_TEXT_LEN];

    memset(subnets, 0, sizeof(subnets));
    total_sent = 0;
    total_received = 0;
    total_valid = 0;

    while ((opt = getopt(argc, argv, "i:t:s:h")) != -1) {
        if (opt == 'i') {
            ifname = optarg;
        } else if (opt == 't') {
            timeout = atoi(optarg);
            if (timeout < 1) timeout = 1;
            if (timeout > 5) timeout = 5;
        } else if (opt == 's') {
            subnet_t s;
            if (parse_subnet(optarg, &s) == 0)
                add_subnet(subnets, &subnet_count, &s);
            else
                fprintf(stderr, "[arpscan] 跳过不支持的网段 %s（当前主动扫描支持/24）\n", optarg);
        } else {
            printf("Usage: %s [-i interface] [-t seconds] [-s network/24]\n", argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    if (get_ifinfo(ifname, &ifindex, mac, &ip, &mask) < 0) {
        fprintf(stderr, "[arpscan] interface %s unavailable（无法取得本机IPv4，已尝试br0回退）\n", ifname);
        return 1;
    }

    ipv4_text(ip, source_ip, sizeof(source_ip));
    if ((mask & 0xffffff00U) == 0xffffff00U) {
        subnet_t local;
        local.network = ip & 0xffffff00U;
        local.mask = 0xffffff00U;
        local.prefix = 24;
        add_subnet(subnets, &subnet_count, &local);
    }

    /* DHCP检测得到的上级网关可能与Q7本机LAN网段不同，自动追加其/24。 */
    add_dhcp_gateway_subnet(subnets, &subnet_count);

    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ARP));
    if (fd < 0) {
        perror("[arpscan] socket");
        return 1;
    }

    {
        struct sockaddr_ll ba;
        memset(&ba, 0, sizeof(ba));
        ba.sll_family = AF_PACKET;
        ba.sll_ifindex = ifindex;
        ba.sll_protocol = htons(ETH_P_ARP);
        if (bind(fd, (struct sockaddr *)&ba, sizeof(ba)) < 0) {
            perror("[arpscan] bind");
            close(fd);
            return 1;
        }
    }

    printf("[arpscan] iface=%s ifindex=%d source_ip=%s subnet_count=%d timeout=%d\n",
           ifname, ifindex, source_ip, subnet_count, timeout);
    fflush(stdout);

    for (i = 0; i < subnet_count; ++i)
        scan_subnet(fd, ifindex, mac, ip, &subnets[i]);

    end = time(NULL) + timeout;
    while (time(NULL) < end) {
        int left = (int)(end - time(NULL));
        int n;
        if (left < 1) left = 1;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = left;
        tv.tv_usec = 0;
        n = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (n <= 0) {
            if (n < 0)
                continue;
            break;
        }
        if (FD_ISSET(fd, &rfds)) {
            n = recv(fd, buf, sizeof(buf), 0);
            if (n > 0)
                handle_arp(buf, n, mac, ip);
        }
    }

    printf("[arpscan] 扫描完成：发送=%lu，收到ARP帧=%lu，有效设备响应=%lu\n",
           total_sent, total_received, total_valid);
    fflush(stdout);
    close(fd);
    return 0;
}
