#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdlib.h>

/*
 * Start LAN discovery once during the real system init (PID 1).
 * A delayed child gives rc enough time to restore NVRAM and bring up
 * the network before the discovery worker reads its configuration.
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
			execl("/usr/bin/lan_autodiscover.sh", "lan_autodiscover.sh", (char *)NULL);
			_exit(127);
		}
		_exit(child < 0 ? 126 : 0);
	}
}
