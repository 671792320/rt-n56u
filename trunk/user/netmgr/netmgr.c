/* Generic Padavan LAN link monitor. No board-specific assumptions. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_IFACE "br0"
#define DEFAULT_INTERVAL 1
#define STATE_FILE "/var/run/netmgr.state"
#define LOG_FILE "/var/log/netmgr.log"

static volatile sig_atomic_t running = 1;

static void stop_handler(int sig) { (void)sig; running = 0; }

static int read_carrier(const char *ifname)
{
    char path[128], buf[8];
    int fd, n;
    snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", ifname);
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return buf[0] == '1' ? 1 : 0;
}

static void record_state(const char *ifname, int link, const char *phase)
{
    FILE *f;
    time_t now = time(NULL);
    f = fopen(STATE_FILE, "w");
    if (f) {
        fprintf(f, "interface=%s\nlink=%d\nphase=%s\ntime=%ld\n", ifname, link, phase, (long)now);
        fclose(f);
    }
    f = fopen(LOG_FILE, "a");
    if (f) {
        fprintf(f, "%ld interface=%s link=%d phase=%s\n", (long)now, ifname, link, phase);
        fclose(f);
    }
    printf("[netmgr] interface=%s link=%s phase=%s\n", ifname,
           link == 1 ? "UP" : link == 0 ? "DOWN" : "UNKNOWN", phase);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *ifname = DEFAULT_IFACE;
    int interval = DEFAULT_INTERVAL, old_link = -2, link, opt;
    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {
        if (opt == 'i') ifname = optarg;
        else if (opt == 't') { interval = atoi(optarg); if (interval < 1) interval = 1; if (interval > 60) interval = 60; }
        else { printf("Usage: %s [-i interface] [-t seconds]\n", argv[0]); return opt == 'h' ? 0 : 1; }
    }
    signal(SIGTERM, stop_handler);
    signal(SIGINT, stop_handler);
    mkdir("/var/run", 0755);
    mkdir("/var/log", 0755);
    while (running) {
        link = read_carrier(ifname);
        if (link != old_link) {
            record_state(ifname, link, link == 1 ? "LINK_UP" : link == 0 ? "LINK_DOWN" : "LINK_UNKNOWN");
            old_link = link;
        }
        sleep(interval);
    }
    return 0;
}
