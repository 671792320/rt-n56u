#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdlib.h>

/*
 * Start persistent LAN discovery and network-mode managers once during real
 * system init.  The managers themselves remain alive and react to LAN events.
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
