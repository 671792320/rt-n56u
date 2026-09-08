/*
 * Q7二层网络健康监视器。
 *
 * 只用于网络异常检测，不把任何普通IPv4流量加入设备列表。
 *
 * 检测项目：
 * 1. 广播包速率：连续达到阈值时报告广播风暴。
 * 2. 本机MAC回流：收到源MAC等于本机MAC的帧时报告疑似二层环路。
 *
 * Q7只有一个RJ45，因此如果交换网络中的广播/未知单播被环路反复转发，
 * 这个工具可以作为现场排障提示，但“疑似环路”仍属于异常迹象，不等同于
 * 专业交换机STP诊断结果。
 */
#include <getopt.h>
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BUF_SIZE 2048
#define DEFAULT_BCAST_THRESHOLD 1000
#define DEFAULT_LOOP_THRESHOLD 1

typedef struct {
    unsigned long long total;
    unsigned long long broadcast;
    unsigned long long self_source;
} health_counter_t;

static int get_iface_info(const char *ifname, int *ifindex, unsigned char mac[6])
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

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) {
        close(fd);
        return -1;
    }
    memcpy(mac, ifr.ifr_hwaddr.sa_data, 6);
    close(fd);
    return 0;
}

static int mac_equal(const unsigned char *a, const unsigned char *b)
{
    return memcmp(a, b, 6) == 0;
}

static void emit_health(const health_counter_t *c, int bcast_threshold,
                        int loop_threshold)
{
    const char *state = "OK";
    if (c->self_source >= (unsigned long long)loop_threshold &&
        c->broadcast >= (unsigned long long)bcast_threshold)
        state = "LOOP_BROADCAST";
    else if (c->self_source >= (unsigned long long)loop_threshold)
        state = "LOOP_SUSPECTED";
    else if (c->broadcast >= (unsigned long long)bcast_threshold)
        state = "BROADCAST_STORM";

    printf("HEALTH state=%s broadcast=%llu total=%llu self=%llu\n",
           state, c->broadcast, c->total, c->self_source);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *ifname = "eth2.1";
    int bcast_threshold = DEFAULT_BCAST_THRESHOLD;
    int loop_threshold = DEFAULT_LOOP_THRESHOLD;
    int ifindex, fd, opt;
    unsigned char self_mac[6], buf[BUF_SIZE];

    while ((opt = getopt(argc, argv, "i:b:l:h")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 'b':
            bcast_threshold = atoi(optarg);
            if (bcast_threshold < 100)
                bcast_threshold = 100;
            if (bcast_threshold > 100000)
                bcast_threshold = 100000;
            break;
        case 'l':
            loop_threshold = atoi(optarg);
            if (loop_threshold < 1)
                loop_threshold = 1;
            if (loop_threshold > 1000)
                loop_threshold = 1000;
            break;
        default:
            printf("Usage: %s [-i interface] [-b broadcast/s] [-l self-source/s]\n", argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    if (get_iface_info(ifname, &ifindex, self_mac) < 0) {
        fprintf(stderr, "[lanhealth] interface %s unavailable\n", ifname);
        return 1;
    }

    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        perror("[lanhealth] socket");
        return 1;
    }

    {
        struct sockaddr_ll sa;
        memset(&sa, 0, sizeof(sa));
        sa.sll_family = AF_PACKET;
        sa.sll_ifindex = ifindex;
        sa.sll_protocol = htons(ETH_P_ALL);
        if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            perror("[lanhealth] bind");
            close(fd);
            return 1;
        }
    }

    printf("[lanhealth] iface=%s ifindex=%d broadcast_threshold=%d loop_threshold=%d\n",
           ifname, ifindex, bcast_threshold, loop_threshold);
    fflush(stdout);

    for (;;) {
        health_counter_t c;
        time_t start = time(NULL);
        memset(&c, 0, sizeof(c));

        while (time(NULL) == start) {
            fd_set rfds;
            struct timeval tv;
            int n;

            FD_ZERO(&rfds);
            FD_SET(fd, &rfds);
            tv.tv_sec = 0;
            tv.tv_usec = 200000;

            n = select(fd + 1, &rfds, NULL, NULL, &tv);
            if (n <= 0)
                continue;
            if (!FD_ISSET(fd, &rfds))
                continue;

            n = recv(fd, buf, sizeof(buf), 0);
            if (n < ETH_HLEN)
                continue;

            c.total++;
            if (mac_equal(buf, self_mac))
                c.self_source++;
            if (buf[0] == 0xff && buf[1] == 0xff && buf[2] == 0xff &&
                buf[3] == 0xff && buf[4] == 0xff && buf[5] == 0xff)
                c.broadcast++;
        }

        emit_health(&c, bcast_threshold, loop_threshold);
    }

    close(fd);
    return 0;
}
