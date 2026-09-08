#!/bin/sh
# LAN事件监督程序。
# Q7唯一RJ45使用本程序监听物理插拔，并统一管理发现worker与网络模式manager。
# 已验证的DHCP开关逻辑由worker保持，本程序不直接修改DHCP服务。

PIDFILE=/tmp/lan_autodiscover_worker.pid
NETMGR_PIDFILE=/tmp/lan_network_manager.pid
SUPERVISOR_LOCKDIR=/var/run/lan_discovery_supervisor.lock
WORKER_LOCKDIR=/var/run/lan_autodiscover.lock
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
RUNTIME_DIR=/tmp/lan_discovery_runtime
mkdir -p "$RUNTIME_DIR"

if ! mkdir "$SUPERVISOR_LOCKDIR" 2>/dev/null; then
    echo "$(date '+%H:%M:%S') LAN监督程序已经运行" | logger -t lan-supervisor
    exit 0
fi
trap 'rmdir "$SUPERVISOR_LOCKDIR" 2>/dev/null' EXIT INT TERM HUP

nv() { nvram get "$1" 2>/dev/null; }
runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="${RUNTIME_DIR}/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${RUNTIME_DIR}/${key}"
}
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }

set_supervisor_status() { runtime_set lan_discovery_status_supervisor="$1"; }

mtk_esw_lan4_state() {
    [ -x /sbin/mtk_esw ] || return 2
    state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
    case "$state" in
        1) return 0;;
        0) return 1;;
    esac
    return 2
}

is_link_up() {
    iface="$1"
    if [ "$iface" = "eth2.1" ]; then
        mtk_esw_lan4_state
        rc=$?
        [ "$rc" = "0" ] && return 0
        [ "$rc" = "1" ] && return 1
    fi
    [ -e "/sys/class/net/$iface" ] || return 1
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = "1" ] && return 0
    else
        [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "up" ] && return 0
    fi
    return 1
}

worker_running() {
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) rm -f "$PIDFILE"; return 1;;
    esac
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$PIDFILE"
    return 1
}

network_manager_running() {
    [ -r "$NETMGR_PIDFILE" ] || return 1
    pid="$(cat "$NETMGR_PIDFILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) rm -f "$NETMGR_PIDFILE"; return 1;;
    esac
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$NETMGR_PIDFILE"
    return 1
}

start_network_manager() {
    iface="$1"
    if network_manager_running; then
        runtime_set lan_discovery_status_network_manager="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lan_network_manager.sh ]; then
        runtime_set lan_discovery_status_network_manager="程序不存在"
        echo "$(date '+%H:%M:%S') LAN网络模式管理器不存在" | logger -t lan-supervisor
        return 1
    fi
    echo "$(date '+%H:%M:%S') LAN网络模式管理器启动：$iface" | logger -t lan-supervisor
    /usr/bin/lan_network_manager.sh > /tmp/lan_network_manager.log 2>&1 &
    echo "$!" > "$NETMGR_PIDFILE"
    runtime_set lan_discovery_status_network_manager="运行中"
    return 0
}

stop_network_manager() {
    if network_manager_running; then
        pid="$(cat "$NETMGR_PIDFILE" 2>/dev/null)"
        echo "$(date '+%H:%M:%S') LAN网络模式管理器停止" | logger -t lan-supervisor
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    rm -f "$NETMGR_PIDFILE"
    [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :
    [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r >/dev/null 2>&1 || :
    runtime_set lan_discovery_status_network_manager="已停止"
    runtime_set lan_discovery_status_target_network=""
    runtime_set lan_discovery_status_target_ip=""
    runtime_set lan_discovery_status_target_iface=""
}

sync_runtime_status() {
    iface="$1"
    if [ -e "/sys/class/net/$iface" ]; then
        ip4="$(ip -4 addr show dev br0 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
        [ -n "$ip4" ] || ip4="$(nv lan_ipaddr)"
        mac="$(cat /sys/class/net/br0/address 2>/dev/null)"
        [ -n "$mac" ] || mac="$(cat /sys/class/net/$iface/address 2>/dev/null)"
        [ -n "$ip4" ] || ip4="-"
        [ -n "$mac" ] || mac="-"
        runtime_set lan_discovery_status_ip="$ip4"
        runtime_set lan_discovery_status_mac="$(printf '%s' "$mac" | tr '[:lower:]' '[:upper:]')"
    fi
    if is_link_up "$iface"; then
        runtime_set lan_discovery_status_link="UP"
    else
        runtime_set lan_discovery_status_link="DOWN"
        return
    fi
    [ -f "$DEVICE_DB" ] || : > "$DEVICE_DB"
    count="$(grep -v 'type=SUBNET ' "$DEVICE_DB" 2>/dev/null | grep -v 'type=IP_CONFLICT ' | wc -l | tr -d ' ')"
    case "$count" in ''|*[!0-9]*) count=0;; esac
    runtime_set lan_discovery_status_count="$count"
    if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
        runtime_set lan_discovery_status_state="设备发现未启用"
    elif ps 2>/dev/null | grep -q '[c]amdiscover'; then
        runtime_set lan_discovery_status_state="持续设备发现"
    elif ps 2>/dev/null | grep -q '[d]hcpdetect'; then
        runtime_set lan_discovery_status_state="DHCP检测"
    fi
    if [ -f /tmp/dhcpdetect_lan.log ]; then
        line="$(grep -m1 '^\[dhcpdetect\] DHCP server found' /tmp/dhcpdetect_lan.log 2>/dev/null)"
        gateway="$(printf '%s\n' "$line" | sed -n 's/.* gateway=\([^ ]*\).*/\1/p')"
        server="$(printf '%s\n' "$line" | sed -n 's/.* server=\([^ ]*\).*/\1/p')"
        if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="网关 $gateway"
        elif [ -n "$server" ] && [ "$server" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="DHCP服务器 $server（未提供网关）"
        elif grep -q '\[dhcpdetect\].*no DHCP server reply' /tmp/dhcpdetect_lan.log 2>/dev/null; then
            runtime_set lan_discovery_status_dhcp="未发现DHCP"
        fi
    fi
    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null | sed -n 's/^\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\) .*/\1/p')"
    [ -n "$last" ] && runtime_set lan_discovery_status_last="$last" || runtime_set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

start_worker() {
    iface="$1"
    if worker_running; then
        runtime_set lan_discovery_status_worker="运行中"
        return 0
    fi
    if [ -d "$WORKER_LOCKDIR" ]; then
        stale=""
        [ -r "$WORKER_LOCKDIR/pid" ] && stale="$(cat "$WORKER_LOCKDIR/pid" 2>/dev/null)"
        case "$stale" in
            ''|*[!0-9]*) rmdir "$WORKER_LOCKDIR" 2>/dev/null;;
            *)
                if ! kill -0 "$stale" 2>/dev/null; then rmdir "$WORKER_LOCKDIR" 2>/dev/null; fi
                ;;
        esac
        [ -d "$WORKER_LOCKDIR" ] && {
            runtime_set lan_discovery_status_worker="已有工作进程"
            return 0
        }
    fi
    if [ ! -x /usr/bin/lan_autodiscover.sh ]; then
        runtime_set lan_discovery_status_worker="程序不存在"
        return 1
    fi
    echo "$(date '+%H:%M:%S') LAN监听启动发现工作进程：$iface" | logger -t lan-supervisor
    /usr/bin/lan_autodiscover.sh > /tmp/lan_autodiscover_worker.log 2>&1 &
    echo "$!" > "$PIDFILE"
    runtime_set lan_discovery_status_worker="运行中"
    return 0
}

stop_worker() {
    if worker_running; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        echo "$(date '+%H:%M:%S') LAN监听停止发现工作进程" | logger -t lan-supervisor
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    rm -f "$PIDFILE"
    rmdir "$WORKER_LOCKDIR" 2>/dev/null
    runtime_set lan_discovery_status_worker="已停止"
    killall camdiscover 2>/dev/null
    killall dhcpdetect 2>/dev/null
    killall lanhealth 2>/dev/null
    rm -f /tmp/lan_discovery_runtime/lanhealth.pid
    runtime_set lan_discovery_status_health="未监视"
    runtime_set lan_discovery_status_broadcast="0"
    runtime_set lan_discovery_status_loop="0"
}

last_enable="-1"
last_iface=""
last_link="-1"
set_supervisor_status "运行中"
runtime_set lan_discovery_status_worker="已停止"
runtime_set lan_discovery_status_network_manager="已停止"
runtime_set lan_discovery_status_health="未监视"

while :; do
    enable="$(cfg lan_discovery_enable 0)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_link="-1"
        runtime_set lan_discovery_status_if="$iface"
        echo "$(date '+%H:%M:%S') LAN监听接口：$iface" | logger -t lan-supervisor
    fi
    if [ "$enable" != "$last_enable" ]; then
        last_enable="$enable"
        last_link="-1"
        if [ "$enable" = "1" ]; then
            runtime_set lan_discovery_status_enable="已启用"
            echo "$(date '+%H:%M:%S') LAN监听已启用" | logger -t lan-supervisor
        else
            runtime_set lan_discovery_status_enable="已禁用"
            echo "$(date '+%H:%M:%S') LAN监听已禁用，仅停止插拔事件监听，不关闭LAN接口" | logger -t lan-supervisor
            stop_worker
            stop_network_manager
        fi
    fi
    if [ "$enable" != "1" ]; then sleep 1; continue; fi

    if [ -e "/sys/class/net/$iface" ]; then
        if is_link_up "$iface"; then link=1; else link=0; fi
    else
        link=0
    fi

    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" = "1" ]; then
            runtime_set lan_discovery_status_link="UP"
            runtime_set lan_discovery_status_state="DHCP检测"
            echo "$(date '+%H:%M:%S') LAN口已插入：$iface" | logger -t lan-supervisor
            # 先启动网络模式管理器；它等待DHCP检测结果，再建立目标临时IP/SNAT。
            start_network_manager "$iface"
            start_worker "$iface"
        else
            runtime_set lan_discovery_status_link="DOWN"
            runtime_set lan_discovery_status_state="等待接口"
            runtime_set lan_discovery_status_dhcp="未检测"
            echo "$(date '+%H:%M:%S') LAN口已拔出：$iface" | logger -t lan-supervisor
            stop_worker
            stop_network_manager
        fi
    fi

    if [ "$link" = "1" ]; then
        start_network_manager "$iface"
        start_worker "$iface"
    fi
    sync_runtime_status "$iface"
    set_supervisor_status "运行中"
    sleep 1
done
