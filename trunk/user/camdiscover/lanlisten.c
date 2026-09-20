/*
 * Q7 LAN实时IPv4/ARP监听器。
 *
 * 用一个长期运行的AF_PACKET进程替代“tcpdump + FIFO + Shell逐包解析”：
 * 1. 监听ARP和IPv4；
 * 2. 同时登记IPv4源IP、目的IP及对应二层MAC；
 * 3. 每个IP/MAC组合默认60秒最多输出一次，避免视频流量把Shell和日志打爆；
 * 4. 事件直接追加到/tmp运行文件，不启动sed/awk/ip/logger子进程；
 * 5. 只监听，不主动探测；ARP扫描和协议探测仍由主动发现模块负责。
 */
#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <linux/if.h>
#include <linux/if_arp.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <netinet/ip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define MAX_SEEN 512
#define EVENT_FILE_DEFAULT "/tmp/lan_discovery_runtime/tcpdump_discovery_events.txt"
#define EMIT_COOLDOWN 60
#define SNAPLEN 96

typedef struct {
    unsigned char mac[6];
    unsigned long ip;
    time_t last_seen;
    int valid;
} seen_item_t;

static seen_item_t seen[MAX_SEEN];
static FILE *event_fp;

static int is_private_ip(unsigned long ip)
{
    unsigned int first = (unsigned int)((ip >> 24) & 0xff);
    unsigned int second = (unsigned int)((ip >> 16) & 0xff);

    /* 只允许RFC1918私有地址，禁止公网IPv4进入LAN目标网段。 */
    if (first == 10)
        return 1;
    if (first == 172 && second >= 16 && second <= 31)
        return 1;
    if (first == 192 && second == 168)
        return 1;
    return 0;
}

static int is_unicast_ip(unsigned long ip)
{
    unsigned int first = (unsigned int)((ip >> 24) & 0xff);
    unsigned int second = (unsigned int)((ip >> 16) & 0xff);
    unsigned int last = (unsigned int)(ip & 0xff);

    if (ip == 0 || ip == 0xffffffffUL)
        return 0;
    if (first == 127 || first >= 224)
        return 0;
    if (last == 0 || last == 255)
        return 0;

    /* LAN目标范围只接受RFC1918私有地址，禁止公网IPv4进入目标网段状态机。 */
    if (first == 10)
        return 1;
    if (first == 172 && second >= 16 && second <= 31)
        return 1;
    if (first == 192 && second == 168)
        return 1;

    return 0;
}

static void ip_text(unsigned long ip, char *out, size_t len)
{
    snprintf(out, len, "%lu.%lu.%lu.%lu",
             (ip >> 24) & 0xff,
             (ip >> 16) & 0xff,
             (ip >> 8) & 0xff,
             ip & 0xff);
}

static void mac_text(const unsigned char *mac, char *out, size_t len)
{
    snprintf(out, len, "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static int mac_is_multicast(const unsigned char *mac)
{
    return (mac[0] & 1) != 0;
}

static int should_emit(unsigned long ip, const unsigned char *mac, time_t now)
{
    int i;
    int free_index = -1;
    int oldest_index = -1;
    time_t oldest = 0;

    for (i = 0; i < MAX_SEEN; ++i) {
        if (!seen[i].valid) {
            if (free_index < 0)
                free_index = i;
            continue;
        }

        if (seen[i].ip == ip && memcmp(seen[i].mac, mac, 6) == 0) {
            if ((now - seen[i].last_seen) < EMIT_COOLDOWN)
                return 0;
            seen[i].last_seen = now;
            return 1;
        }

        if (oldest_index < 0 || seen[i].last_seen < oldest) {
            oldest = seen[i].last_seen;
            oldest_index = i;
        }
    }

    i = free_index >= 0 ? free_index : oldest_index;
    if (i >= 0) {
        seen[i].valid = 1;
        seen[i].ip = ip;
        memcpy(seen[i].mac, mac, 6);
        seen[i].last_seen = now;
    }
    return 1;
}

static void emit_event(const char *source,
                       unsigned long ip,
                       const unsigned char *mac,
                       time_t now)
{
    char ipbuf[32];
    char macbuf[32];

    if (!is_unicast_ip(ip) || !is_private_ip(ip) || mac_is_multicast(mac))
        return;
    if (!should_emit(ip, mac, now))
        return;
    if (!event_fp)
        return;

    ip_text(ip, ipbuf, sizeof(ipbuf));
    mac_text(mac, macbuf, sizeof(macbuf));
    fprintf(event_fp, "%s|%s|%s|%ld\n", ipbuf, macbuf, source, (long)now);
    fflush(event_fp);
}

static int iface_info(const char *ifname, int *ifindex)
{
    int fd;
    struct ifreq ifr;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        close(fd);
        return -1;
    }

    *ifindex = ifr.ifr_ifindex;
    close(fd);
    return 0;
}

static void process_arp(const unsigned char *buf, int len,
                        const char *event_file, time_t now)
{
    int offset = ETH_HLEN;
    unsigned short proto;
    const struct arphdr *arp;
    const unsigned char *p;
    unsigned long sender_ip;
    (void)event_file;

    if (len < ETH_HLEN + (int)sizeof(struct arphdr) + 20)
        return;

    memcpy(&proto, buf + 12, sizeof(proto));
    if (ntohs(proto) == ETH_P_8021Q) {
        offset += 4;
        if (len < offset + (int)sizeof(struct arphdr) + 20)
            return;
    }

    arp = (const struct arphdr *)(buf + offset);
    if (ntohs(arp->ar_pro) != ETH_P_IP ||
        arp->ar_hrd != htons(ARPHRD_ETHER) ||
        arp->ar_hln != ETH_ALEN ||
        arp->ar_pln != 4)
        return;

    p = buf + offset + sizeof(struct arphdr);
    memcpy(&sender_ip, p + 6, 4);
    emit_event("ARP", ntohl(sender_ip), p, now);
}

static void process_ipv4(const unsigned char *buf, int len,
                         const char *event_file, time_t now)
{
    int offset = ETH_HLEN;
    int ihl;
    const struct iphdr *ip;
    const struct ethhdr *eth;
    unsigned short proto;
    unsigned long src;
    (void)event_file;

    if (len < ETH_HLEN + 20)
        return;

    eth = (const struct ethhdr *)buf;
    if (ntohs(eth->h_proto) == ETH_P_8021Q) {
        if (len < ETH_HLEN + 4 + 20)
            return;
        offset += 4;
        memcpy(&proto, buf + 16, sizeof(proto));
        if (ntohs(proto) != ETH_P_IP)
            return;
    } else if (ntohs(eth->h_proto) != ETH_P_IP) {
        return;
    }

    ip = (const struct iphdr *)(buf + offset);
    if (ip->version != 4)
        return;

    ihl = ip->ihl * 4;
    if (ihl < 20 || offset + ihl > len)
        return;

    src = ntohl(ip->saddr);

    /*
     * 实时监听只登记“进入LAN口的数据源地址”。
     * 目的IP不能作为目标设备依据，否则Q7收到的外部访问流量会把
     * 公网地址误认为LAN目标网段，进而触发错误SNAT。
     */
    emit_event("TCP/IP", src, eth->h_source, now);
}

int main(int argc, char **argv)
{
    const char *ifname = "eth2.1";
    const char *event_file = EVENT_FILE_DEFAULT;
    int ifindex, fd, opt;
    unsigned char buf[SNAPLEN];
    struct sockaddr_ll sa;

    while ((opt = getopt(argc, argv, "i:e:h")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 'e':
            event_file = optarg;
            break;
        case 'h':
            printf("Usage: %s [-i interface] [-e event_file]\n", argv[0]);
            return 0;
        default:
            return 1;
        }
    }

    if (iface_info(ifname, &ifindex) < 0) {
        openlog("lan-autodiscover", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "【二层监听】接口不可用：%s", ifname);
        closelog();
        return 1;
    }

    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        openlog("lan-autodiscover", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "【二层监听】无法创建AF_PACKET监听：%s", strerror(errno));
        closelog();
        return 1;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sll_family = AF_PACKET;
    sa.sll_ifindex = ifindex;
    sa.sll_protocol = htons(ETH_P_ALL);

    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        openlog("lan-autodiscover", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "【二层监听】绑定接口失败：%s", strerror(errno));
        closelog();
        close(fd);
        return 1;
    }

    event_fp = fopen(event_file, "a");
    if (!event_fp) {
        openlog("lan-autodiscover", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "【二层监听】无法打开事件文件：%s", event_file);
        closelog();
        close(fd);
        return 1;
    }

    openlog("lan-autodiscover", LOG_PID, LOG_USER);
    syslog(LOG_INFO, "【二层监听】实时监听启动：接口=%s，事件抑制=%ds", ifname, EMIT_COOLDOWN);

    for (;;) {
        fd_set rfds;
        struct timeval tv;
        int n;
        struct sockaddr_ll from;
        socklen_t from_len;
        time_t now;
        const struct ethhdr *eth;

        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = 1;
        tv.tv_usec = 0;

        n = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            syslog(LOG_ERR, "【二层监听】select失败：%s", strerror(errno));
            break;
        }
        if (n == 0)
            continue;

        from_len = sizeof(from);
        n = recvfrom(fd, buf, sizeof(buf), 0,
                     (struct sockaddr *)&from, &from_len);
        if (n < ETH_HLEN)
            continue;

        if (from.sll_pkttype == PACKET_OUTGOING)
            continue;

        now = time(NULL);
        eth = (const struct ethhdr *)buf;

        if (ntohs(eth->h_proto) == ETH_P_ARP ||
            ntohs(eth->h_proto) == ETH_P_8021Q)
            process_arp(buf, n, event_file, now);

        process_ipv4(buf, n, event_file, now);
    }

    fclose(event_fp);
    close(fd);
    closelog();
    return 0;
}
