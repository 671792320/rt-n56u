#include <unistd.h>
#include <sys/types.h>
#include <stdlib.h>

/*
 * Q7 LAN发现监督器按Padavan正常启动流程启动：
 * init_router()在系统基础服务、LAN和日志等组件就绪后调用start_lan_discovery()。
 * 不使用constructor，避免在rc进程装载阶段抢跑网络初始化。
 */
void
start_lan_discovery(void)
{
	pid_t pid;

	if (getpid() != 1)
		return;

	pid = fork();
	if (pid < 0)
		return;

	if (pid == 0) {
		setsid();
		execl("/usr/bin/lan_discovery_supervisor.sh",
		      "lan_discovery_supervisor.sh", (char *)NULL);
		_exit(127);
	}
}

void
stop_lan_discovery(void)
{
	system("killall lan_discovery_supervisor.sh 2>/dev/null");
	system("killall lan_network_manager.sh 2>/dev/null");
	system("killall lan_autodiscover.sh 2>/dev/null");
	system("killall lan_tcpdump_listener.sh 2>/dev/null");
	system("killall lanlisten 2>/dev/null");
}
