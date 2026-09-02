/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <syslog.h>
#include <signal.h>
#include <string.h>
#include <fcntl.h>
#include <sys/klog.h>
#include <sys/types.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <dirent.h>

#include <rstats.h>
#if defined (USE_STORAGE)
#include <disk_initial.h>
#endif

#include "rc.h"
#include "gpio_pins.h"
#include "switch.h"
#include <ralink_priv.h>

extern struct nvram_pair router_defaults[];

/* static values */
static int nvram_modem_type = 0;
static int nvram_modem_rule = 0;
static int nvram_nf_nat_type = 0;
static int nvram_ipv6_type = 0;

static int
nvram_restore_defaults(void)
{
	struct nvram_pair *np;
	int restore_defaults;
	char tmp[32] = {0};
	unsigned char buffer[2] = {0};
	char lan_mac[] = "FFFF";

	int i_offset = get_wired_mac_e2p_offset(0) + 4;
	if (flash_mtd_read(MTD_PART_NAME_FACTORY, i_offset, buffer, 2) == 0) {
		sprintf(lan_mac, "%02X%02X", buffer[0] & 0xff, buffer[1] & 0xff);
	}

	/* Restore defaults if told to or OS has changed */
	restore_defaults = !nvram_match("restore_defaults", "0");

	/* check asus-wrt NVRAM content (sorry, but many params is incompatible) */
	if (!restore_defaults) {
		if (nvram_get("buildno") && nvram_get("buildinfo") && nvram_get("extendno"))
			restore_defaults = 1;
	}

	if (restore_defaults)
		nvram_clear();

	/* Restore defaults */
	for (np = router_defaults; np->name; np++) {
		if (restore_defaults || !nvram_get(np->name)) {
			if (strstr(np->name,"wl_ssid") || strstr(np->name,"rt_ssid") || !strcmp(np->name,"wl_guest_ssid") || !strcmp(np->name,"rt_guest_ssid")){
				sprintf(tmp, np->value, lan_mac);
				nvram_set(np->name, tmp);
			} else {
				nvram_set(np->name, np->value);
			}
		}
	}

#ifdef Q7_FIRMWARE_VERSION
	/* Q7使用独立版本宏，避免依赖Padavan内部版本号拼接规则。 */
	nvram_set("firmver_sub", Q7_FIRMWARE_VERSION);
#endif

	klogctl(8, NULL, nvram_get_int("console_loglevel"));

	/* load static values */
	nvram_modem_type = nvram_get_int("modem_type");
	nvram_modem_rule = nvram_get_int("modem_rule");
	nvram_nf_nat_type = nvram_get_int("nf_nat_type");
	nvram_ipv6_type = get_ipv6_type();

	return restore_defaults;
}
