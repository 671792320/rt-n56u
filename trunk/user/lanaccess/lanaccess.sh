#!/bin/sh
# LAN access manager for discovered target networks.
# Creates per-target /32 routes and SNAT using a temporary unused source IP.
# DHCP detection is informational only; NAT is still required whenever the
# phone-side LAN and target device are on different IPv4 networks.

PIDFILE=/tmp/lanaccess.pid
STATEFILE=/tmp/lanaccess.state
LOCKDIR=/var/run/lanaccess.lock

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }
log() { logger -t lanaccess "$(now) $*"; }

IFACE="$(cfg lan_discovery_ifname eth2.1)"
PHONE_IP="$(cfg lan_ipaddr 192.168.123.1)"
PHONE_NET="$(printf '%s' "$PHONE_IP" | sed 's/[0-9][0-9]*$/0/')/24"

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1>=0 && $1<=255 && $2>=0 && $2<=255 && $3>=0 && $3<=255 && $4>=0 && $4<=255 {ok=1} END{exit ok?0:1}'
}

same_phone_subnet() {
    target="$1"
    phone_prefix="$(printf '%s' "$PHONE_IP" | awk -F. '{print $1"."$2"."$3}')"
    target_prefix="$(printf '%s' "$target" | awk -F. '{print $1"."$2"."$3}')"
    [ "$phone_prefix" = "$target_prefix" ]
}

cleanup_target() {
    target="$1"; source="$2"
    [ -n "$target" ] || return 0
    iptables -t nat -D POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$source" 2>/dev/null
    iptables -D FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip route del "$target/32" dev "$IFACE" 2>/dev/null
}

cleanup_all() {
    if [ -r "$STATEFILE" ]; then
        while IFS='|' read -r target source; do
            [ -n "$target" ] || continue
            if [ "$source" != "DIRECT" ]; then
                cleanup_target "$target" "$source"
                ip addr del "$source/32" dev "$IFACE" 2>/dev/null
            fi
        done < "$STATEFILE"
    fi
    : > "$STATEFILE"
    nvram set lan_access_status="已清理"
    nvram set lan_access_count=0
}

if [ "$1" = "cleanup" ]; then
    cleanup_all
    rm -f "$PIDFILE"
    rm -rf "$LOCKDIR" 2>/dev/null
    exit 0
fi

if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null; rm -f "$PIDFILE"' EXIT INT TERM HUP
echo $$ > "$PIDFILE"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

candidate_ips() {
    ip="$1"
    set -- $(printf '%s\n' "$ip" | awk -F. '{print $1,$2,$3,$4}')
    a="$1"; b="$2"; c="$3"; d="$4"
    n=1
    while [ "$n" -le 32 ]; do
        x=$((d+n)); y=$((d-n))
        [ "$x" -le 254 ] && printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$x"
        [ "$y" -ge 1 ] && printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$y"
        n=$((n+1))
    done
    printf '%s.%s.%s.254\n' "$a" "$b" "$c"
    printf '%s.%s.%s.253\n' "$a" "$b" "$c"
}

source_used() {
    source="$1"
    awk -F'|' -v s="$source" '$2==s {found=1} END{exit found?0:1}' "$STATEFILE" 2>/dev/null
}

source_test() {
    source="$1"; target="$2"
    ip addr add "$source/32" dev "$IFACE" 2>/dev/null || return 1
    ip route replace "$target/32" dev "$IFACE" src "$source" 2>/dev/null || {
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
    if awk -F'|' -v t="$target" '$1==t {found=1} END{exit found?0:1}' "$STATEFILE" 2>/dev/null; then return 0; fi

    # A target already inside the phone-side /24 does not need SNAT.
    if same_phone_subnet "$target"; then
        printf '%s|DIRECT\n' "$target" >> "$STATEFILE"
        log "目标 $target 与手机侧同网段，直接访问，无需SNAT"
        return 0
    fi

    for candidate in $(candidate_ips "$target"); do
        [ "$candidate" = "$target" ] && continue
        [ "$candidate" = "$PHONE_IP" ] && continue
        source_used "$candidate" && continue
        if arping -I "$IFACE" -c 1 -w 1 "$candidate" >/dev/null 2>&1; then continue; fi
        if source_test "$candidate" "$target"; then
            iptables -A FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null
            iptables -A FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            iptables -t nat -A POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$candidate" 2>/dev/null
            printf '%s|%s\n' "$target" "$candidate" >> "$STATEFILE"
            log "目标 $target 已建立访问通道，源地址 $candidate，SNAT=ON"
            return 0
        fi
    done
    log "目标 $target 无法建立访问通道"
    return 1
}

sync_targets() {
    tmp="/tmp/lanaccess.targets.$$"
    current="/tmp/lanaccess.current.$$"
    : > "$tmp"
    : > "$current"
    printf '%s\n' "$(nv lan_discovery_devices)" | while IFS= read -r line; do
        case "$line" in
            DEVICE\ *)
                ip="$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
                valid_ipv4 "$ip" && printf '%s\n' "$ip" >> "$tmp"
                ;;
        esac
    done
    sort -u "$tmp" > "$current" 2>/dev/null

    if [ -r "$STATEFILE" ]; then
        while IFS='|' read -r target source; do
            [ -n "$target" ] || continue
            if ! grep -F -x "$target" "$current" >/dev/null 2>&1; then
                if [ "$source" = "DIRECT" ]; then
                    log "目标 $target 已从发现列表移除，清理直接访问状态"
                else
                    cleanup_target "$target" "$source"
                    ip addr del "$source/32" dev "$IFACE" 2>/dev/null
                    log "目标 $target 已从发现列表移除，访问通道已清理"
                fi
            fi
        done < "$STATEFILE"
        : > /tmp/lanaccess.state.new.$$
        while IFS='|' read -r target source; do
            [ -n "$target" ] || continue
            grep -F -x "$target" "$current" >/dev/null 2>&1 && printf '%s|%s\n' "$target" "$source" >> /tmp/lanaccess.state.new.$$
        done < "$STATEFILE"
        mv /tmp/lanaccess.state.new.$$ "$STATEFILE"
    fi

    if [ -s "$current" ]; then
        while IFS= read -r target; do
            [ -n "$target" ] || continue
            awk -F'|' -v t="$target" '$1==t {found=1} END{exit found?0:1}' "$STATEFILE" 2>/dev/null && continue
            install_target "$target"
        done < "$current"
    fi
    rm -f "$tmp" "$current"
    count="$(awk -F'|' 'NF==2 && $1!="" {n++} END{print n+0}' "$STATEFILE" 2>/dev/null)"
    nvram set lan_access_count="${count:-0}"
    [ "${count:-0}" = "0" ] && nvram set lan_access_status="等待目标设备" || nvram set lan_access_status="已建立 ${count} 个目标通道"
}

cleanup_all
nvram set lan_access_status="等待目标设备"
last_link="-"
last_devices=""
while :; do
    IFACE="$(cfg lan_discovery_ifname eth2.1)"
    link="$(nv lan_discovery_status_link)"
    devices="$(nv lan_discovery_devices)"

    if [ "$link" != "UP" ]; then
        if [ "$last_link" = "UP" ]; then cleanup_all; log "LAN Link DOWN，已清理目标通道"; fi
        last_link="$link"
        sleep 2
        continue
    fi
    last_link="$link"

    if [ "$devices" != "$last_devices" ]; then
        last_devices="$devices"
        sync_targets
    fi
    sleep 2
done
