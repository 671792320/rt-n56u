#include <unistd.h>
#include <sys/types.h>
#include <stdlib.h>

/*
 * Start the Optware policy guard once from PID 1.
 * The guard exits immediately when optw_enable is 1/2. When the WebUI
 * setting is disabled it remains active and prevents legacy external
 * Optware scripts from recreating /opt.
 */
static void __attribute__((constructor)) optware_policy_constructor(void)
{
    pid_t pid;

    if (getpid() != 1)
        return;

    pid = fork();
    if (pid < 0)
        return;

    if (pid == 0) {
        setsid();
        sleep(8);
        execl("/usr/bin/optware_policy_guard.sh",
              "optware_policy_guard.sh", (char *)NULL);
        _exit(127);
    }
}
