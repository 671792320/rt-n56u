#!/bin/sh
# 固件升级前停止LAN发现运行时任务。
# 仅停止发现相关进程，不修改LAN发现NVRAM配置，不主动撤销已有SNAT规则。
LOCKDIR=/var/run/lan_discovery_supervisor.lock
SUPERVISOR_PIDFILE="$LOCKDIR/pid"
WORKER_PIDFILE=/tmp/lan_autodiscover_worker.pid
TCPDUMP_PIDFILE=/tmp/lan_tcpdump_listener.pid
NETMGR_PIDFILE=/tmp/lan_network_manager.pid

valid_pid() {
    pid="$1"
    case "$pid" in
        ''|*[!0-9]*|1) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

stop_pid() {
    pid="$1"
    valid_pid "$pid" || return 0
    kill "$pid" 2>/dev/null
    i=0
    while [ "$i" -lt 5 ]; do
        valid_pid "$pid" || return 0
        sleep 1
        i=$((i + 1))
    done
    valid_pid "$pid" && kill -9 "$pid" 2>/dev/null
}

# 先停止监督器。监督器收到TERM后退出并释放自己的锁目录。
if [ -r "$SUPERVISOR_PIDFILE" ]; then
    supervisor_pid="$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null)"
    if valid_pid "$supervisor_pid" && [ -r "/proc/$supervisor_pid/cmdline" ]; then
        cmdline="$(tr '\000' ' ' < "/proc/$supervisor_pid/cmdline" 2>/dev/null)"
        case "$cmdline" in
            *"/usr/bin/lan_discovery_supervisor.sh"*) stop_pid "$supervisor_pid" ;;
        esac
    fi
fi

# 无论监督器是否正常退出，都清理发现相关子进程。
for pidfile in "$WORKER_PIDFILE" "$TCPDUMP_PIDFILE" "$NETMGR_PIDFILE"; do
    if [ -r "$pidfile" ]; then
        pid="$(cat "$pidfile" 2>/dev/null)"
        stop_pid "$pid"
        rm -f "$pidfile"
    fi
done

for pattern in \
    "/usr/bin/lan_autodiscover.sh" \
    "/usr/bin/lan_tcpdump_listener.sh" \
    "/usr/bin/lan_network_manager.sh" \
    "/usr/bin/lanlisten"; do
    for pid in $(ps 2>/dev/null | awk -v p="$pattern" 'index($0,p) && $1 ~ /^[0-9]+$/ {print $1}'); do
        [ "$pid" = "$$" ] && continue
        stop_pid "$pid"
    done
done

killall camdiscover 2>/dev/null
killall arpscan 2>/dev/null
killall dhcpdetect 2>/dev/null
killall lanhealth 2>/dev/null

rm -f /tmp/lan_autodiscover_worker.pid /tmp/lan_tcpdump_listener.pid /tmp/lan_network_manager.pid
logger -t lan-supervisor "【LAN监督】检测到固件升级，已停止LAN发现运行任务，保留配置和现有SNAT规则"
exit 0
