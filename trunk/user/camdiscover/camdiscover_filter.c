/* Wrapper for camdiscover: hide the router's own IP/MAC from discovery output. */
#include <arpa/inet.h>
#include <linux/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_LOCAL 32
#define LINE_SIZE 2048

static char local_ips[MAX_LOCAL][INET_ADDRSTRLEN];
static int local_ip_count;
static char local_macs[MAX_LOCAL][32];
static int local_mac_count;

static void add_local_ip(const char *ip)
{
    int i;
    if (!ip || !*ip || !strcmp(ip, "0.0.0.0")) return;
    for (i = 0; i < local_ip_count; i++)
        if (!strcmp(local_ips[i], ip)) return;
    if (local_ip_count < MAX_LOCAL) {
        strncpy(local_ips[local_ip_count], ip, sizeof(local_ips[0]) - 1);
        local_ips[local_ip_count][sizeof(local_ips[0]) - 1] = 0;
        local_ip_count++;
    }
}

static void collect_if(const char *ifname)
{
    int fd, i;
    struct ifreq ifr;
    char ip[INET_ADDRSTRLEN];
    unsigned char *m;
    char mac[32];

    if (!ifname || !*ifname) return;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip))) add_local_ip(ip);
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) == 0) {
        m = (unsigned char *)ifr.ifr_hwaddr.sa_data;
        if (m[0] || m[1] || m[2] || m[3] || m[4] || m[5]) {
            snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                     m[0], m[1], m[2], m[3], m[4], m[5]);
            for (i = 0; i < local_mac_count; i++)
                if (!strcasecmp(mac, local_macs[i])) { close(fd); return; }
            if (local_mac_count < MAX_LOCAL) {
                strncpy(local_macs[local_mac_count], mac, sizeof(local_macs[0]) - 1);
                local_macs[local_mac_count][sizeof(local_macs[0]) - 1] = 0;
                local_mac_count++;
            }
        }
    }
    close(fd);
}

static int is_local_line(const char *line)
{
    char ip[INET_ADDRSTRLEN];
    char mac[32];
    const char *p, *q;
    int i;

    p = strstr(line, " IP=");
    if (p) {
        p += 4; q = strchr(p, ' ');
        if (!q) q = p + strlen(p);
        if ((size_t)(q - p) < sizeof(ip)) {
            memcpy(ip, p, (size_t)(q - p)); ip[q - p] = 0;
            for (i = 0; i < local_ip_count; i++)
                if (!strcmp(ip, local_ips[i])) return 1;
        }
    }
    p = strstr(line, " MAC=");
    if (p) {
        p += 5; q = strchr(p, ' ');
        if (!q) q = p + strlen(p);
        if ((size_t)(q - p) < sizeof(mac)) {
            memcpy(mac, p, (size_t)(q - p)); mac[q - p] = 0;
            for (i = 0; i < local_mac_count; i++)
                if (!strcasecmp(mac, local_macs[i])) return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    int pipefd[2], status, i;
    pid_t pid;
    FILE *fp;
    char line[LINE_SIZE];
    const char *ifname = "br0";

    for (i = 1; i + 1 < argc; i++)
        if (!strcmp(argv[i], "-i")) ifname = argv[i + 1];

    collect_if(ifname);
    collect_if("br0");
    collect_if("eth2");
    collect_if("eth2.1");
    collect_if("ra0");

    if (pipe(pipefd) < 0) return 1;
    pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return 1; }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execv("/usr/bin/camdiscover.raw", argv);
        _exit(127);
    }
    close(pipefd[1]);
    fp = fdopen(pipefd[0], "r");
    if (!fp) { close(pipefd[0]); return 1; }
    while (fgets(line, sizeof(line), fp)) {
        if (!is_local_line(line)) fputs(line, stdout);
        fflush(stdout);
    }
    fclose(fp);
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
