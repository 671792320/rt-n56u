#!/bin/sh
# Persistent LAN event supervisor.
# Controls the discovery worker and the no-DHCP LAN access worker.

PIDFILE=/tmp/lan_autodiscover_worker.pid
ACCESS_PIDFILE=/tmp/lanaccess.pid
LOCKDIR=/var/run/lan_autodiscover.lock

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }

set_supervisor_status() {
    nvram set lan_discovery_status_supervisor="$1"
    nvram set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

is_link_up() {
    iface="$1"
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

access_running() {
    [ -r "$ACCESS_PIDFILE" ] || return 1
    pid="$(cat "$ACCESS_PIDFILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) rm -f "$ACCESS_PIDFILE"; return 1;;
    esac
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$ACCESS_PIDFILE"
    return 1
}

start_access() {
    if access_running; then
        nvram set lan_access_status="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lanaccess.sh ]; then
        nvram set lan_access_status="程序不存在"
        return 1
    fi
    /usr/bin/lanaccess.sh >/tmp/lanaccess.log 2>&1 &
    nvram set lan_access_status="启动中"
    return 0
}

stop_access() {
    if access_running; then
        pid="$(cat "$ACCESS_PIDFILE" 2>/dev/null)"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    rm -f "$ACCESS_PIDFILE"
    rm -rf /var/run/lanaccess.lock 2>/dev/null
    if [ -x /usr/bin/lanaccess.sh ]; then
        /usr/bin/lanaccess.sh cleanup >/dev/null 2>&1
    fi
    nvram set lan_access_status="已停止"
    nvram set lan_access_count=0
}

start_worker() {
    iface="$1"
    if worker_running; then
        nvram set lan_discovery_status_worker="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lan_autodiscover.sh ]; then
        nvram set lan_discovery_status_worker="程序不存在"
        return 1
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    echo "$(date '+%H:%M:%S') LAN discovery worker start: $iface" | logger -t lan-supervisor
    /usr/bin/lan_autodiscover.sh >/tmp/lan_autodiscover_worker.log 2>&1 &
    echo "$!" > "$PIDFILE"
    nvram set lan_discovery_status_worker="运行中"
    nvram set lan_discovery_status_last="$(date '+%H:%M:%S')"
    return 0
}

stop_worker() {
    if worker_running; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        echo "$(date '+%H:%M:%S') LAN discovery worker stop" | logger -t lan-supervisor
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    rm -f "$PIDFILE"
    rm -rf "$LOCKDIR" 2>/dev/null
    nvram set lan_discovery_status_worker="已停止"
    killall camdiscover 2>/dev/null
    killall dhcpdetect 2>/dev/null
    stop_access
}

last_enable="-1"
last_discover="-1"
last_iface=""
last_link="-1"

set_supervisor_status "运行中"
nvram set lan_discovery_status_worker="已停止"
nvram set lan_access_status="已停止"
nvram set lan_access_count=0

while :; do
    enable="$(cfg lan_discovery_enable 0)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"

    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_link="-1"
        nvram set lan_discovery_status_if="$iface"
        echo "$(date '+%H:%M:%S') LAN supervisor interface=$iface" | logger -t lan-supervisor
    fi

    if [ "$enable" != "$last_enable" ]; then
        last_enable="$enable"
        last_discover="-1"
        if [ "$enable" = "1" ]; then
            nvram set lan_discovery_status_enable="已启用"
            echo "$(date '+%H:%M:%S') LAN discovery enabled" | logger -t lan-supervisor
        else
            nvram set lan_discovery_status_enable="已禁用"
            nvram set lan_discovery_status_state="LAN自动发现未启用"
            echo "$(date '+%H:%M:%S') LAN discovery disabled; LAN event supervisor remains active" | logger -t lan-supervisor
            stop_worker
        fi
        last_link="-1"
    fi

    if [ -e "/sys/class/net/$iface" ]; then
        if is_link_up "$iface"; then link=1; else link=0; fi
    else
        link=0
    fi

    if [ "$enable" = "1" ] && [ "$discover_enable" != "$last_discover" ]; then
        last_discover="$discover_enable"
        if [ "$discover_enable" = "1" ] && [ "$link" = "1" ]; then
            nvram set lan_discovery_status_state="等待接口"
            echo "$(date '+%H:%M:%S') Device discovery enabled" | logger -t lan-supervisor
            start_worker "$iface"
            start_access
        else
            nvram set lan_discovery_status_state="设备发现未启用"
            echo "$(date '+%H:%M:%S') Device discovery disabled" | logger -t lan-supervisor
            stop_worker
        fi
    fi

    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" = "1" ]; then
            nvram set lan_discovery_status_link="UP"
            echo "$(date '+%H:%M:%S') LAN Link UP $iface" | logger -t lan-supervisor
            if [ "$enable" = "1" ] && [ "$discover_enable" = "1" ]; then
                start_worker "$iface"
                start_access
            else
                stop_worker
            fi
        else
            nvram set lan_discovery_status_link="DOWN"
            echo "$(date '+%H:%M:%S') LAN Link DOWN $iface" | logger -t lan-supervisor
            stop_worker
            nvram set lan_discovery_status_state="等待接口"
        fi
    elif [ "$enable" = "1" ] && [ "$discover_enable" = "1" ] && [ "$link" = "1" ]; then
        start_worker "$iface"
        start_access
    fi

    nvram set lan_discovery_status_supervisor="运行中"
    nvram set lan_discovery_status_last="$(date '+%H:%M:%S')"
    sleep 1
done
