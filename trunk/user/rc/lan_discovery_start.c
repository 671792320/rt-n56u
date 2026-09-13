#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "nvram_linux.h"

/*
 * 启动LAN发现和网络管理服务，并同步本次构建生成的固件版本号。
 * 版本号来源于编译时生成的/etc/q7_firmware_version，不写死具体版本。
 */
static void sync_q7_firmware_version(void)
{
	FILE *fp;
	char version[64];

	fp = fopen("/etc/q7_firmware_version", "r");
	if (!fp)
		return;

	if (!fgets(version, sizeof(version), fp)) {
		fclose(fp);
		return;
	}
	fclose(fp);

	version[strcspn(version, "\r\n")] = '\0';
	if (!version[0])
		return;

	if (strcmp(nvram_safe_get("firmver_sub"), version) != 0) {
		nvram_set("firmver_sub", version);
		nvram_commit();
	}
}

/*
 * Start persistent LAN discovery and network-mode managers once during real
 * system init.  The managers themselves remain alive and react to LAN events.
 */
static void __attribute__((constructor)) lan_discovery_constructor(void)
{
	pid_t pid;

	if (getpid() != 1)
		return;

	/* 直接按本次固件构建版本同步firmver_sub，避免旧NVRAM残留旧版本号。 */
	sync_q7_firmware_version();

	pid = fork();
	if (pid < 0)
		return;

	if (pid == 0) {
		pid_t child;
		setsid();
		sleep(8);
		child = fork();
		if (child == 0) {
			execl("/usr/bin/lan_discovery_supervisor.sh", "lan_discovery_supervisor.sh", (char *)NULL);
			_exit(127);
		}
		_exit(child < 0 ? 126 : 0);
	}

	pid = fork();
	if (pid == 0) {
		pid_t child;
		setsid();
		sleep(10);
		child = fork();
		if (child == 0) {
			execl("/usr/bin/lan_network_manager.sh", "lan_network_manager.sh", (char *)NULL);
			_exit(127);
		}
		_exit(child < 0 ? 126 : 0);
	}
}
