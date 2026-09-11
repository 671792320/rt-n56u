#!/bin/sh
# Q7单口LAN多目标网段SNAT。
# 手机始终使用Q7自己的192.168.2.x地址；每个目标/24网段单独维护一条SNAT和FORWARD规则。
# 有DHCP与无DHCP目标网段可以同时存在，互不删除、互不覆盖。

RUNTIME_DIR=/tmp/lan_discovery_runtime
LOCK_DIR="$RUNTIME_DIR/.lan_snat.lock"
LOGTAG=lan-autodiscover

find_iptables() {
    if command -v iptables >/dev/null 2>&1; then command -v iptables; return 0; fi
    for p in /bin/iptables /sbin/iptables /usr/sbin/iptables; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
IPTABLES="$(find_iptables 2>/dev/null)"

log() {
    printf '%s\n' "【SNAT】$*"
    logger -t "$LOGTAG" "【SNAT】$*"
}

acquire_lock() {
    n=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -ge 10 ] && { log "等待防火墙锁超时，本轮跳过"; return 1; }
        sleep 1
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT INT TERM
    return 0
}

rule_exists() { table="$1"; chain="$2"; shift 2; "$IPTABLES" -t "$table" -C "$chain" "$@" 2>/dev/null; }
rule_add_first() { table="$1"; chain="$2"; shift 2; rule_exists "$table" "$chain" "$@" || "$IPTABLES" -t "$table" -I "$chain" 1 "$@"; }
rule_del_all() { table="$1"; chain="$2"; shift 2; while rule_exists "$table" "$chain" "$@"; do "$IPTABLES" -t "$table" -D "$chain" "$@" 2>/dev/null || break; done; }

state_key() { printf '%s\n' "$1" | tr '.' '_'; }
state_file_for() { printf '%s/lan_snat_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
normalize_network() { printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'; }

cleanup_one() {
    target="$1"; state_file="$(state_file_for "$target")"; [ -r "$state_file" ] || return 0
    old_target_net="$(sed -n 's/^target_net=//p' "$state_file" | head -n 1)"; old_target_ip="$(sed -n 's/^target_ip=//p' "$state_file" | head -n 1)"; old_lan_net="$(sed -n 's/^lan_net=//p' "$state_file" | head -n 1)"
    if [ -n "$old_target_net" ] && [ "$old_target_net" != "0.0.0.0" ] && [ -n "$old_target_ip" ] && [ "$old_target_ip" != "0.0.0.0" ] && [ -n "$old_lan_net" ] && [ -n "$IPTABLES" ]; then
        rule_del_all nat POSTROUTING -s "$old_lan_net/24" -d "$old_target_net/24" -o br0 -j SNAT --to-source "$old_target_ip"
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_lan_net/24" -d "$old_target_net/24" -j ACCEPT
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_target_net/24" -d "$old_lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "已撤销规则：本地=$old_lan_net/24 → 目标=$old_target_net/24，源地址=$old_target_ip"
    fi
    rm -f "$state_file"
}

cleanup_all() {
    for state_file in "$RUNTIME_DIR"/lan_snat_*.state; do
        [ -r "$state_file" ] || continue
        target="$(sed -n 's/^target_net=//p' "$state_file" | head -n 1)"
        [ -n "$target" ] && [ "$target" != "0.0.0.0" ] && cleanup_one "$target"
    done
}

apply_rules() {
    TARGET_NET="$1"; TARGET_IP="$2"; LAN_NET="$3"
    [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :
    rule_add_first filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
    rule_add_first filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    rule_add_first nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"
}

check_args() {
    target_net="$(normalize_network "$1")"; target_ip="$2"; lan_net="$(normalize_network "$3")"
    case "$target_ip" in *.*.*.*) ;; *) log "参数错误：临时源地址=$2"; return 1;; esac
    [ -n "$target_net" ] && [ -n "$lan_net" ] || { log "参数错误：目标或本地网段格式错误"; return 1; }
    [ "$target_net" != "0.0.0.0" ] && [ "$lan_net" != "0.0.0.0" ] || { log "参数错误：禁止使用无效网段0.0.0.0/24"; return 1; }
    [ "$target_net" != "$lan_net" ] || { log "参数错误：目标网段与本地网段不能相同：$target_net"; return 1; }
    target_prefix="$(printf '%s\n' "$target_net" | awk -F. '{print $1"."$2"."$3}')"; ip_prefix="$(printf '%s\n' "$target_ip" | awk -F. '{if(NF==4)print $1"."$2"."$3}')"
    [ -n "$target_prefix" ] && [ "$target_prefix" = "$ip_prefix" ] || { log "参数错误：临时源地址不属于目标网段：目标=$target_net，源地址=$target_ip"; return 1; }
    CHECK_TARGET_NET="$target_net"; CHECK_LAN_NET="$lan_net"; return 0
}

mkdir -p "$RUNTIME_DIR"
ACTION="$1"
case "$ACTION" in
    down|remove|-r|--remove)
        [ -n "$IPTABLES" ] || exit 0; acquire_lock || exit 0
        if [ -n "$2" ]; then TARGET_NET="$(normalize_network "$2")"; [ -n "$TARGET_NET" ] && [ "$TARGET_NET" != "0.0.0.0" ] && cleanup_one "$TARGET_NET"; else cleanup_all; fi
        exit 0;;
    check|up) TARGET_NET="$2"; TARGET_IP="$3"; LAN_NET="$4";;
    *) log "用法错误：需要 up/check 目标网段 临时源地址 本地网段，或 down [目标网段]"; exit 2;;
esac

check_args "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || exit 1
TARGET_NET="$CHECK_TARGET_NET"; LAN_NET="$CHECK_LAN_NET"
[ -n "$IPTABLES" ] || { log "系统中没有防火墙程序，无法启用SNAT"; exit 1; }
acquire_lock || exit 0
STATE_FILE="$(state_file_for "$TARGET_NET")"
same_state=0
if [ -r "$STATE_FILE" ]; then
    old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"; old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"; old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
    [ "$old_target_net" = "$TARGET_NET" ] && [ "$old_target_ip" = "$TARGET_IP" ] && [ "$old_lan_net" = "$LAN_NET" ] && same_state=1
fi
[ "$same_state" = "1" ] || cleanup_one "$TARGET_NET"
apply_rules "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || { log "规则写入失败：本地=$LAN_NET/24 → 目标=$TARGET_NET/24，源地址=$TARGET_IP"; exit 1; }
{
    printf 'lan_net=%s\n' "$LAN_NET"; printf 'target_net=%s\n' "$TARGET_NET"; printf 'target_ip=%s\n' "$TARGET_IP"; printf 'iface=br0\n'
} > "$STATE_FILE"
if [ "$ACTION" = "up" ]; then log "规则已启用：本地=$LAN_NET/24 → 目标=$TARGET_NET/24，源地址=$TARGET_IP"; else log "状态检查正常：本地=$LAN_NET/24 → 目标=$TARGET_NET/24，源地址=$TARGET_IP"; fi
exit 0
