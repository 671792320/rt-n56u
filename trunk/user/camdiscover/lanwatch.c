/* Q7 LAN event watcher.
 * Polls the physical LAN carrier and reacts only to link transitions.
 * On link-up: run dhcpdetect, then camdiscover. No network configuration
 * is changed yet; this stage is discovery/diagnostics only.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IFACE "eth2"
#define DISCOVER_IFACE "eth2.1"
#define CARRIER_FILE "/sys/class/net/eth2/carrier"

static int read_carrier(void)
{
    FILE *fp;
    char b[8];
    int v;
    fp = fopen(CARRIER_FILE, "r");
    if (!fp) return -1;
    if (!fgets(b, sizeof(b), fp)) { fclose(fp); return -1; }
    fclose(fp);
    v = atoi(b);
    return v ? 1 : 0;
}

static void run_discovery(void)
{
    int dhcp;
    printf("[lanwatch] LAN link up: DHCP check on %s\n", DISCOVER_IFACE);
    fflush(stdout);
    dhcp = system("/usr/bin/dhcpdetect -i " DISCOVER_IFACE " -t 3");
    if (dhcp == 0)
        printf("[lanwatch] DHCP detected; running discovery\n");
    else
        printf("[lanwatch] no DHCP detected; running discovery\n");
    fflush(stdout);
    system("/usr/bin/camdiscover -i " DISCOVER_IFACE " -t 10");
    printf("[lanwatch] discovery cycle complete\n");
    fflush(stdout);
}

int main(void)
{
    int old = -2, now;
    printf("[lanwatch] watching %s carrier, discovery interface=%s\n", IFACE, DISCOVER_IFACE);
    fflush(stdout);

    while (1) {
        now = read_carrier();
        if (now != old) {
            old = now;
            if (now == 1) {
                run_discovery();
            } else if (now == 0) {
                printf("[lanwatch] LAN link down\n");
                fflush(stdout);
            }
        }
        sleep(1);
    }
    return 0;
}
