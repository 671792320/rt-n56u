#!/bin/sh
#
# Optware/Entware policy guard.
#
# The firmware's native /usr/bin/opt-mount.sh honors optw_enable, but older
# Hiboy opt-script installations (Sh01_mountopt.sh / _mountopt) can manage
# /opt independently.  Keep the WebUI optw_enable switch authoritative.
#
# optw_enable:
#   0 / empty / invalid : Optware disabled
#   1                   : legacy Optware enabled
#   2                   : Entware enabled
#

nvram_opt_enabled()
{
    value="$(nvram get optw_enable 2>/dev/null)"
    case "$value" in
        1|2) return 0 ;;
        *)   return 1 ;;
    esac
}

stop_legacy_opt_script()
{
    # Do not kill arbitrary shell processes. Only terminate the known legacy
    # Optware mount/update helpers that can recreate /opt while disabled.
    for pid in $(ps 2>/dev/null | grep -E 'Sh01_mountopt\.sh|sh01_mountopt\.sh|/tmp/script/_mountopt|re_upan_storage\.sh' | grep -v grep | awk '{print $1}'); do
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null
    done
}

unmount_opt()
{
    if mountpoint -q /opt 2>/dev/null; then
        # Drop a possible swap file first so a lazy unmount does not leave an
        # active file backed by the disabled Optware tree.
        if [ -x /sbin/swapoff ] && [ -f /opt/.swap ]; then
            swapoff /opt/.swap 2>/dev/null
        fi
        umount /opt 2>/dev/null || umount -l /opt 2>/dev/null
        logger -t "opt-guard" "Optware disabled (optw_enable=0), /opt unmounted"
    fi
}

# No Optware feature requested: nothing to monitor.
nvram_opt_enabled && exit 0

# The old opt-script stack can be started by /etc/storage/start_script.sh or
# its own recovery scripts after firmware initialization, so keep this guard
# alive only while the WebUI switch remains disabled.
while :; do
    if nvram_opt_enabled; then
        exit 0
    fi

    stop_legacy_opt_script
    unmount_opt

    # Avoid a busy loop while still catching legacy scripts that retry mounts.
    sleep 2
done
