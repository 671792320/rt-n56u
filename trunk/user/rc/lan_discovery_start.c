#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdlib.h>

/*
 * Start the persistent LAN discovery supervisor once during real system init.
 * The supervisor itself remains alive regardless of the WebUI enable switch.
 * lan_discovery_enable only controls whether the discovery worker is started,
 * so disabling discovery never disables LAN link/IP event monitoring.
 */
static void __attribute__((constructor)) lan_discovery_constructor(void)
{
	pid_t pid;

	if (getpid() != 1)
		return;

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
}
