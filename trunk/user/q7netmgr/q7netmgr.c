/*
 * q7netmgr - Q7 LAN event/state-machine foundation.
 *
 * This first implementation is deliberately conservative: it watches the
 * physical LAN link and records state. DHCP probing and network switching
 * are kept as explicit phases so the existing Padavan LAN configuration is
 * never unexpectedly destroyed during development.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_IFACE "eth2.1"
#define DEFAULT_INTERVAL 1
#define STATE_FILE "/var/run/q7netmgr.state"
#define LOG_FILE "/var/log/q7netmgr.log"

static volatile sig_atomic_t running = 1;

static void stop_handler(int sig)
{
    (void)sig;
    running = 0;
}

static int read_carrier(const char *ifname)
{
    char path[128];
    char buf[8];
    int fd, n;

    snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", ifname);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    return (buf[0] == '1') ? 1 : 0;
}

static void write_state(const char *ifname, int link, const char *phase)
{
    FILE *f = fopen(STATE_FILE, "w");
    if (!f)
        return;
    fprintf(f, "interface=%s\nlink=%d\nphase=%s\n", ifname, link, phase);
    fclose(f);
}

static void log_event(const char *ifname, int link, const char *phase)
{
    FILE *f = fopen(LOG_FILE, "a");
    time_t now;
    if (!f)
        return;
    now = time(NULL);
    fprintf(f, "%ld interface=%s link=%d phase=%s\n",
            (long)now, ifname, link, phase);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *ifname = DEFAULT_IFACE;
    int interval = DEFAULT_INTERVAL;
    int old_link = -2;
    int link;
    int opt;

    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 't':
            interval = atoi(optarg);
            if (interval < 1) interval = 1;
            if (interval > 60) interval = 60;
            break;
        case 'h':
        default:
            printf("Usage: %s [-i interface] [-t seconds]\n", argv[0]);
            return (opt == 'h') ? 0 : 1;
        }
    }

    signal(SIGTERM, stop_handler);
    signal(SIGINT, stop_handler);

    mkdir("/var/run", 0755);
    mkdir("/var/log", 0755);

    while (running) {
        link = read_carrier(ifname);
        if (link != old_link) {
            const char *phase;
            if (link == 1)
                phase = "LINK_UP";
            else if (link == 0)
                phase = "LINK_DOWN";
            else
                phase = "LINK_UNKNOWN";
            log_event(ifname, link, phase);
            write_state(ifname, link, phase);
            old_link = link;
        }
        sleep(interval);
    }

    return 0;
}
