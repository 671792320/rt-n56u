#!/bin/sh
# LAN事件监督程序。
# 该程序常驻运行，只负责Q7 LAN口物理插拔监听、总开关和发现工作进程启停。
# DHCP检测、设备发现、设备数量、实时日志等业务状态由工作进程维护。

PIDFILE=/tmp/lan_autodiscover_worker.pid
LOCKDIR=/var/run/lan_autodiscover.lock
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
RUNTIME_DIR=/tmp/lan_discovery_runtime
mkdir -p "$RUNTIME_DIR"

nv() { nvram get "$1" 2>/dev/null; }
# 运行时状态只保存在/tmp，不写入持久NVRAM。
runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="${RUNTIME_DIR}/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${RUNTIME_DIR}/${key}"
}
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }

set_supervisor_status() {
    runtime_set lan_discovery_status_supervisor="$1"
}

# Q7唯一RJ45对应交换机LAN4，使用mtk-esw原生PHY状态判断物理插拔。
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

# 从实际系统状态重新生成页面显示字段，避免页面看到已经失效的缓存。
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
    count="$(wc -l < "$DEVICE_DB" 2>/dev/null | tr -d ' ')"
    case "$count" in ''|*[!0-9]*) count=0;; esac
    runtime_set lan_discovery_status_count="$count"

    # 功能开关优先于进程瞬时状态，避免关闭设备发现后仍显示“持续设备发现”。
    if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
        runtime_set lan_discovery_status_state="设备发现未启用"
    elif ps 2>/dev/null | grep -q '[c]amdiscover'; then
        runtime_set lan_discovery_status_state="持续设备发现"
    elif ps 2>/dev/null | grep -q '[d]hcpdetect'; then
        runtime_set lan_discovery_status_state="DHCP检测"
    elif [ -f /tmp/camdiscover_lan.log ] && grep -q '开始持续设备发现' /tmp/lan_autodiscover_worker.log 2>/dev/null; then
        runtime_set lan_discovery_status_state="持续设备发现"
    elif worker_running && [ "$(cfg lan_discovery_discover_enable 1)" = "1" ]; then
        runtime_set lan_discovery_status_state="DHCP检测"
    elif [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
        runtime_set lan_discovery_status_state="设备发现未启用"
    fi

    # DHCP检测结果以当前检测日志为准，避免页面继续显示“未检测”。
    if [ -f /tmp/dhcpdetect_lan.log ]; then
        line="$(grep -m1 '^\\[dhcpdetect\\] DHCP server found' /tmp/dhcpdetect_lan.log 2>/dev/null)"
        gateway="$(printf '%s\\n' "$line" | sed -n 's/.* gateway=\\([^ ]*\\).*/\\1/p')"
        server="$(printf '%s\\n' "$line" | sed -n 's/.* server=\\([^ ]*\\).*/\\1/p')"
        if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="网关 $gateway"
        elif [ -n "$server" ] && [ "$server" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="DHCP服务器 $server（未提供网关）"
        elif grep -q '\\[dhcpdetect\\].*No DHCP' /tmp/dhcpdetect_lan.log 2>/dev/null; then
            runtime_set lan_discovery_status_dhcp="未发现DHCP"
        fi
    fi

    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null | sed -n 's/^\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\) .*/\\1/p')"
    [ -n "$last" ] && runtime_set lan_discovery_status_last="$last" || runtime_set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

start_worker() {
    iface="$1"
    if worker_running; then
        runtime_set lan_discovery_status_worker="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lan_autodiscover.sh ]; then
        runtime_set lan_discovery_status_worker="程序不存在"
        return 1
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    echo "$(date '+%H:%M:%S') LAN监听启动发现工作进程：$iface" | logger -t lan-supervisor
    /usr/bin/lan_autodiscover.sh >/tmp/lan_autodiscover_worker.log 2>&1 &
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
    rm -rf "$LOCKDIR" 2>/dev/null
    runtime_set lan_discovery_status_worker="已停止"
    killall camdiscover 2>/dev/null
    killall dhcpdetect 2>/dev/null
}

last_enable="-1"
last_discover="-1"
last_iface=""
last_link="-1"

set_supervisor_status "运行中"
runtime_set lan_discovery_status_worker="已停止"

while :; do
    enable="$(cfg lan_discovery_enable 0)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"

    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_link="-1"
        last_discover="-1"
        runtime_set lan_discovery_status_if="$iface"
        echo "$(date '+%H:%M:%S') LAN监听接口：$iface" | logger -t lan-supervisor
    fi

    if [ "$enable" != "$last_enable" ]; then
        last_enable="$enable"
        last_link="-1"
        last_discover="-1"
        if [ "$enable" = "1" ]; then
            runtime_set lan_discovery_status_enable="已启用"
            echo "$(date '+%H:%M:%S') LAN监听已启用" | logger -t lan-supervisor
        else
            runtime_set lan_discovery_status_enable="已禁用"
            runtime_set lan_discovery_status_state="已禁用"
            runtime_set lan_discovery_status_dhcp="未检测"
            runtime_set lan_discovery_status_count="0"
            echo "$(date '+%H:%M:%S') LAN监听已禁用" | logger -t lan-supervisor
            stop_worker
        fi
    fi

    if [ -e "/sys/class/net/$iface" ]; then
        if is_link_up "$iface"; then link=1; else link=0; fi
    else
        link=0
    fi

    if [ "$enable" != "1" ]; then
        sleep 1
        continue
    fi

    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" = "1" ]; then
            runtime_set lan_discovery_status_link="UP"
            runtime_set lan_discovery_status_state="DHCP检测"
            echo "$(date '+%H:%M:%S') LAN口已插入：$iface" | logger -t lan-supervisor
            start_worker "$iface"
        else
            runtime_set lan_discovery_status_link="DOWN"
            runtime_set lan_discovery_status_state="等待接口"
            runtime_set lan_discovery_status_dhcp="未检测"
            runtime_set lan_discovery_status_count="0"
            echo "$(date '+%H:%M:%S') LAN口已拔出：$iface" | logger -t lan-supervisor
            stop_worker
        fi
    fi

    # 设备发现开关独立于LAN插拔。无需重新插拔网线即可立即停止或恢复发现。
    if [ "$enable" = "1" ] && [ "$link" = "1" ] && [ "$discover_enable" != "$last_discover" ]; then
        last_discover="$discover_enable"
        if [ "$discover_enable" = "1" ]; then
            runtime_set lan_discovery_status_state="启动设备发现"
            echo "$(date '+%H:%M:%S') 设备发现已启用" | logger -t lan-supervisor
            stop_worker
            start_worker "$iface"
        else
            runtime_set lan_discovery_status_state="设备发现未启用"
            echo "$(date '+%H:%M:%S') 设备发现已禁用" | logger -t lan-supervisor
            stop_worker
        fi
    fi

    # 工作进程异常退出时自动恢复，但设备发现关闭时保持停止。
    if [ "$link" = "1" ] && [ "$discover_enable" = "1" ]; then
        start_worker "$iface"
    fi

    sync_runtime_status "$iface"
    set_supervisor_status "运行中"
    sleep 1
done
