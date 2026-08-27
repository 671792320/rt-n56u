#!/bin/sh
# Persistent LAN event supervisor.
# This process is always running. It never disables the LAN interface or
# its link/IP handling. lan_discovery_enable only controls whether the
# discovery worker is started.

PIDFILE=/tmp/lan_autodiscover_worker.pid

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }

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

start_worker() {
    iface="$1"
    worker_running && return 0
    [ -x /usr/bin/lan_autodiscover.sh ] || return 1
    echo "$(date '+%H:%M:%S') LAN discovery worker start: $iface" | logger -t lan-supervisor
    /usr/bin/lan_autodiscover.sh >/tmp/lan_autodiscover_worker.log 2>&1 &
    echo "$!" > "$PIDFILE"
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
    # The worker can have spawned the short-lived protocol helpers. Stop only
    # our known discovery helpers; the supervisor itself remains alive.
    killall camdiscover 2>/dev/null
    killall dhcpdetect 2>/dev/null
}

last_enable="-1"
last_iface=""
last_link="-1"

while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"

    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_link="-1"
        echo "$(date '+%H:%M:%S') LAN supervisor interface=$iface" | logger -t lan-supervisor
    fi

    if [ "$enable" != "$last_enable" ]; then
        last_enable="$enable"
        if [ "$enable" = "1" ]; then
            echo "$(date '+%H:%M:%S') LAN discovery enabled" | logger -t lan-supervisor
        else
            echo "$(date '+%H:%M:%S') LAN discovery disabled; LAN event supervisor remains active" | logger -t lan-supervisor
            stop_worker
        fi
        # Force a fresh link evaluation whenever the program enable state changes.
        last_link="-1"
    fi

    if [ -e "/sys/class/net/$iface" ]; then
        if is_link_up "$iface"; then link=1; else link=0; fi
    else
        link=0
    fi

    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" = "1" ]; then
            echo "$(date '+%H:%M:%S') LAN Link UP $iface" | logger -t lan-supervisor
            [ "$enable" = "1" ] && start_worker "$iface"
        else
            echo "$(date '+%H:%M:%S') LAN Link DOWN $iface" | logger -t lan-supervisor
            stop_worker
        fi
    elif [ "$enable" = "1" ] && [ "$link" = "1" ]; then
        # Recover automatically if the worker exits unexpectedly.
        start_worker "$iface"
    fi

    sleep 1
done
