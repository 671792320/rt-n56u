#!/bin/sh
# LAN access manager for unknown/no-DHCP target networks.
# Watches lan_discovery_devices and creates per-target /32 routes and SNAT
# using a temporary, unused source IP on the target network.

PIDFILE=/tmp/lanaccess.pid
STATEFILE=/tmp/lanaccess.state
LOCKDIR=/var/run/lanaccess.lock

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }
log() { printf '%s lanaccess: %s\n' "$(now)" "$*" | logger -t lanaccess; }

if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null; rm -f "$PIDFILE"' EXIT INT TERM HUP
echo $$ > "$PIDFILE"

IFACE="$(cfg lan_discovery_ifname eth2.1)"
PHONE_NET="$(cfg lan_ipaddr 192.168.123.1 | sed 's/[0-9][0-9]*$/0/')/24"

cleanup_target() {
    target="$1"; source="$2"
    [ -n "$target" ] || return 0
    iptables -t nat -D POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$source" 2>/dev/null
    iptables -D FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip route del "$target/32" dev "$IFACE" 2>/dev/null
    [ -n "$source" ] && ip addr del "$source/32" dev "$IFACE" 2>/dev/null
}

cleanup_all() {
    if [ -r "$STATEFILE" ]; then
        while IFS='|' read -r target source; do
            [ -n "$target" ] || continue
            cleanup_target "$target" "$source"
        done < "$STATEFILE"
    fi
    : > "$STATEFILE"
    nvram set lan_access_status="已清理"
    nvram set lan_access_count=0
}

ip_last_octet() {
    printf '%s\n' "$1" | awk -F. '{print $1" "$2" "$3" "$4}'
}
valid_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1<=255 && $2<=255 && $3<=255 && $4<=255 {ok=1} END{exit ok?0:1}'
}

candidate_ips() {
    ip="$1"
    set -- $(ip_last_octet "$ip")
    a="$1"; b="$2"; c="$3"; d="$4"
    n=1
    while [ "$n" -le 32 ]; do
        x=$((d + n)); y=$((d - n))
        if [ "$x" -le 254 ]; then printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$x"; fi
        if [ "$y" -ge 1 ]; then printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$y"; fi
        n=$((n + 1))
    done
    printf '%s.%s.%s.254\n' "$a" "$b" "$c"
    printf '%s.%s.%s.253\n' "$a" "$b" "$c"
}

is_known_target() {
    candidate="$1"
    printf '%s\n' "$(nv lan_discovery_devices)" | grep -E "(^| )IP=$candidate( |$)" >/dev/null 2>&1
}

source_works() {
    source="$1"; target="$2"
    ip addr add "$source/32" dev "$IFACE" 2>/dev/null || return 1
    ip route add "$target/32" dev "$IFACE" src "$source" 2>/dev/null || {
        ip addr del "$source/32" dev "$IFACE" 2>/dev/null
        return 1
    }
    if ping -I "$source" -c 1 -W 1 "$target" >/dev/null 2>&1; then return 0; fi
    ip route del "$target/32" dev "$IFACE" 2>/dev/null
    ip addr del "$source/32" dev "$IFACE" 2>/dev/null
    return 1
}

install_target() {
    target="$1"
    valid_ipv4 "$target" || return 1
    is_known_target "$target" && :
    if grep -F -x "$target|" "$STATEFILE" >/dev/null 2>&1; then return 0; fi

    source=""
    for candidate in $(candidate_ips "$target"); do
        [ "$candidate" = "$target" ] && continue
        [ "$candidate" = "$(nv lan_ipaddr)" ] && continue
        if arping -I "$IFACE" -c 1 -w 1 "$candidate" >/dev/null 2>&1; then continue; fi
        if source_works "$candidate" "$target"; then source="$candidate"; break; fi
    done
    [ -n "$source" ] || return 1

    iptables -A FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -A FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -t nat -A POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$source" 2>/dev/null
    printf '%s|%s\n' "$target" "$source" >> "$STATEFILE"
    log "目标 $target 已建立访问通道，源地址 $source"
    return 0
}

sync_targets() {
    tmp="/tmp/lanaccess.targets.$$"
    : > "$tmp"
    printf '%s\n' "$(nv lan_discovery_devices)" | while IFS= read -r line; do
        case "$line" in
            DEVICE\ *)
                ip="$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
                [ -n "$ip" ] && printf '%s\n' "$ip" >> "$tmp"
                ;;
        esac
    done
    if [ -s "$tmp" ]; then sort -u "$tmp" | while IFS= read -r target; do
        [ -n "$target" ] || continue
        install_target "$target"
    done; fi
    rm -f "$tmp"
    count="$(awk -F'|' 'NF==2 && $1!="" {n++} END{print n+0}' "$STATEFILE" 2>/dev/null)"
    nvram set lan_access_count="${count:-0}"
    [ "${count:-0}" = "0" ] && nvram set lan_access_status="等待目标设备" || nvram set lan_access_status="已建立 ${count} 个目标通道"
}

cleanup_all
nvram set lan_access_status="等待无DHCP目标网络"
last_link="-"
last_dhcp=""
last_devices=""

while :; do
    IFACE="$(cfg lan_discovery_ifname eth2.1)"
    dhcp="$(nv lan_discovery_status_dhcp)"
    link="$(nv lan_discovery_status_link)"
    devices="$(nv lan_discovery_devices)"

    if [ "$link" != "UP" ]; then
        if [ "$last_link" = "UP" ]; then cleanup_all; log "LAN Link DOWN，已清理目标通道"; fi
        last_link="$link"
        sleep 2
        continue
    fi
    last_link="$link"

    case "$dhcp" in
        网关\ *|DHCP服务器\ *|已发现DHCP*)
            if [ -s "$STATEFILE" ]; then cleanup_all; log "检测到上级DHCP，停止无DHCP目标访问模式"; fi
            nvram set lan_access_status="上级DHCP已存在"
            sleep 2
            continue
            ;;
    esac

    if [ "$devices" != "$last_devices" ]; then
        last_devices="$devices"
        sync_targets
    fi
    sleep 2
done
