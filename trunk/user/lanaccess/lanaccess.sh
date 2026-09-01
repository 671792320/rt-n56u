#!/bin/sh
# LAN access manager for the no-DHCP target-network mode.
# DHCP is a transparent mode; NAT is used only after DHCP is absent.

PIDFILE=/tmp/lanaccess.pid
STATEFILE=/tmp/lanaccess.state
LOCKDIR=/var/run/lanaccess.lock

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }
log() { logger -t lanaccess "$(now) $*"; }

dhcp_found() {
    dhcp="$(nv lan_discovery_status_dhcp)"
    case "$dhcp" in
        网关\ *|DHCP服务器\ *|已发现DHCP\ (*)|已发现DHCP\ *) return 0 ;;
    esac
    [ "$dhcp" = "已发现DHCP（无网关信息）" ] && return 0
    return 1
}

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
    if [ "$source" != "DIRECT" ]; then
        iptables -t nat -D POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$source" 2>/dev/null
        iptables -D FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null
        iptables -D FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        ip route del "$target/32" dev "$IFACE" 2>/dev/null
        ip addr del "$source/32" dev "$IFACE" 2>/dev/null
    fi
}

cleanup_all() {
    if [ -r "$STATEFILE" ]; then
        while IFS='|' read -r target source; do
            [ -n "$target" ] || continue
            cleanup_target "$target" "$source"
        done < "$STATEFILE"
    fi
    : > "$STATEFILE"

    # Remove legacy self-NAT rules left by pre-SNAT experiments.
    while iptables -t nat -D POSTROUTING -s "$PHONE_NET" -d "$PHONE_NET" -o br0 -j SNAT --to-source "$PHONE_IP" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "$PHONE_NET" -o br0 -j SNAT --to-source "$PHONE_IP" 2>/dev/null; do :; done

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
    while [ "$n" -le 64 ]; do
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

install_source_route() {
    source="$1"; target="$2"
    ip addr add "$source/32" dev "$IFACE" 2>/dev/null || return 1
    ip route replace "$target/32" dev "$IFACE" src "$source" 2>/dev/null || {
        ip addr del "$source/32" dev "$IFACE" 2>/dev/null
        return 1
    }
    if arping -I "$IFACE" -c 2 -w 2 "$target" >/dev/null 2>&1; then
        return 0
    fi
    if ping -I "$source" -c 1 -W 1 "$target" >/dev/null 2>&1; then
        return 0
    fi
    ip route del "$target/32" dev "$IFACE" 2>/dev/null
    ip addr del "$source/32" dev "$IFACE" 2>/dev/null
    return 1
}

rule_present() {
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-s $PHONE_NET -d $1/32 -o $IFACE -j SNAT --to-source $2" >/dev/null 2>&1
}

install_target() {
    target="$1"
    valid_ipv4 "$target" || return 1
    dhcp_found && return 2
    if awk -F'|' -v t="$target" '$1==t {found=1} END{exit found?0:1}' "$STATEFILE" 2>/dev/null; then return 0; fi

    if same_phone_subnet "$target"; then
        printf '%s|DIRECT\n' "$target" >> "$STATEFILE"
        log "目标 $target 与手机侧同 /24，直接访问"
        return 0
    fi

    for candidate in $(candidate_ips "$target"); do
        dhcp_found && return 2
        [ "$candidate" = "$target" ] && continue
        [ "$candidate" = "$PHONE_IP" ] && continue
        source_used "$candidate" && continue
        if arping -I "$IFACE" -c 1 -w 1 "$candidate" >/dev/null 2>&1; then continue; fi
        if install_source_route "$candidate" "$target"; then
            dhcp_found && {
                cleanup_target "$target" "$candidate"
                return 2
            }

            if ! iptables -A FORWARD -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j ACCEPT 2>/dev/null; then
                log "目标 $target 建立失败：FORWARD 出站规则添加失败"
                cleanup_target "$target" "$candidate"
                return 1
            fi

            if ! iptables -A FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
                iptables -A FORWARD -s "$target/32" -d "$PHONE_NET" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            fi

            if ! iptables -t nat -A POSTROUTING -s "$PHONE_NET" -d "$target/32" -o "$IFACE" -j SNAT --to-source "$candidate" 2>/dev/null; then
                log "目标 $target 建立失败：SNAT规则添加失败"
                cleanup_target "$target" "$candidate"
                return 1
            fi

            if ! rule_present "$target" "$candidate"; then
                log "目标 $target 建立失败：SNAT规则未生效"
                cleanup_target "$target" "$candidate"
                return 1
            fi

            printf '%s|%s\n' "$target" "$candidate" >> "$STATEFILE"
            log "目标 $target 已建立访问通道，源地址 $candidate，ROUTE=ON SNAT=ON"
            return 0
        fi
    done
    log "目标 $target 无法建立访问通道：目标无ARP/IP响应或空闲源地址不可用"
    return 1
}

sync_targets() {
    dhcp_found && { cleanup_all; nvram set lan_access_status="上级DHCP已存在"; return 0; }
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
                cleanup_target "$target" "$source"
                log "目标 $target 已从发现列表移除，访问通道已清理"
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
    if dhcp_found; then
        nvram set lan_access_status="上级DHCP已存在"
    elif [ "${count:-0}" = "0" ]; then
        nvram set lan_access_status="等待目标设备"
    else
        nvram set lan_access_status="已建立 ${count} 个目标通道"
    fi
}

cleanup_all
nvram set lan_access_status="等待目标设备"
last_link="-"
last_devices=""
last_dhcp=""
while :; do
    IFACE="$(cfg lan_discovery_ifname eth2.1)"
    link="$(nv lan_discovery_status_link)"
    devices="$(nv lan_discovery_devices)"
    dhcp="$(nv lan_discovery_status_dhcp)"

    # LAN Link state always has priority. Do not let DHCP/NAT state swallow
    # the physical plug/unplug transition.
    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" != "UP" ]; then
            cleanup_all
            nvram set lan_access_status="LAN已断开"
            log "LAN Link DOWN，已清理目标通道"
            last_devices=""
            last_dhcp=""
            sleep 2
            continue
        fi
        log "LAN Link UP，开始重新检测目标网络"
        last_devices=""
        last_dhcp=""
    fi

    if [ "$link" != "UP" ]; then
        sleep 2
        continue
    fi

    # DHCP is evaluated only after the physical link transition has been
    # handled, so plug/unplug detection remains reliable in both modes.
    if [ "$dhcp" != "$last_dhcp" ]; then
        last_dhcp="$dhcp"
        if dhcp_found; then
            cleanup_all
            nvram set lan_access_status="上级DHCP已存在"
            log "检测到上级DHCP，进入透明桥接模式，停止NAT访问模式"
        else
            nvram set lan_access_status="等待目标设备"
            log "上级DHCP不存在，进入无DHCP访问模式"
            last_devices=""
        fi
    fi

    if dhcp_found; then
        sleep 2
        continue
    fi

    if [ "$devices" != "$last_devices" ]; then
        last_devices="$devices"
        sync_targets
    fi
    sleep 2
done
