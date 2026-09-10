#!/bin/sh
# Q7单口LAN多目标网段SNAT。
# 手机始终使用Q7自己的192.168.2.x地址；每个目标/24网段单独维护一条SNAT和FORWARD规则。
# 有DHCP与无DHCP目标网段可以同时存在，互不删除、互不覆盖。

RUNTIME_DIR=/tmp/lan_discovery_runtime
LOCK_DIR="$RUNTIME_DIR/.lan_snat.lock"
LOGTAG=lan-autodiscover

find_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        command -v iptables
        return 0
    fi
    for p in /bin/iptables /sbin/iptables /usr/sbin/iptables; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

IPTABLES="$(find_iptables 2>/dev/null)"

log() {
    logger -t "$LOGTAG" "[snat] $*"
    printf '%s\n' "[snat] $*"
}

acquire_lock() {
    n=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -ge 10 ] && {
            log "SNAT操作等待锁超时，跳过本轮，避免并发修改iptables"
            return 1
        }
        sleep 1
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT INT TERM
    return 0
}

rule_exists() {
    table="$1"; chain="$2"; shift 2
    "$IPTABLES" -t "$table" -C "$chain" "$@" 2>/dev/null
}

rule_add_first() {
    table="$1"; chain="$2"; shift 2
    rule_exists "$table" "$chain" "$@" || "$IPTABLES" -t "$table" -I "$chain" 1 "$@"
}

rule_del_all() {
    table="$1"; chain="$2"; shift 2
    while rule_exists "$table" "$chain" "$@"; do
        "$IPTABLES" -t "$table" -D "$chain" "$@" 2>/dev/null || break
    done
}

state_key() {
    printf '%s\n' "$1" | tr '.' '_'
}

state_file_for() {
    printf '%s/lan_snat_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"
}

normalize_network() {
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'
}

cleanup_one() {
    target="$1"
    state_file="$(state_file_for "$target")"
    [ -r "$state_file" ] || return 0
    old_target_net="$(sed -n 's/^target_net=//p' "$state_file" | head -n 1)"
    old_target_ip="$(sed -n 's/^target_ip=//p' "$state_file" | head -n 1)"
    old_lan_net="$(sed -n 's/^lan_net=//p' "$state_file" | head -n 1)"
    if [ -n "$old_target_net" ] && [ -n "$old_target_ip" ] && [ -n "$old_lan_net" ] && [ -n "$IPTABLES" ]; then
        rule_del_all nat POSTROUTING -s "$old_lan_net/24" -d "$old_target_net/24" -o br0 -j SNAT --to-source "$old_target_ip"
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_lan_net/24" -d "$old_target_net/24" -j ACCEPT
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_target_net/24" -d "$old_lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "撤销SNAT：$old_lan_net/24 -> $old_target_net/24，源地址=$old_target_ip"
    fi
    rm -f "$state_file"
}

cleanup_all() {
    for state_file in "$RUNTIME_DIR"/lan_snat_*.state; do
        [ -r "$state_file" ] || continue
        target="$(sed -n 's/^target_net=//p' "$state_file" | head -n 1)"
        [ -n "$target" ] && cleanup_one "$target"
    done
}

apply_rules() {
    TARGET_NET="$1"
    TARGET_IP="$2"
    LAN_NET="$3"
    [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :

    rule_add_first filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
    rule_add_first filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    rule_add_first nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"
}

check_args() {
    case "$1:$2:$3" in
        *.*.*.*:*.*.*.*:*.*.*.*) ;;
        *) log "SNAT参数无效：target=$1 target_ip=$2 lan=$3"; return 1;;
    esac
    [ "$1" != "$3" ] || { log "SNAT参数无效：目标网段与本地网段不能相同：$1"; return 1; }
    target_prefix="$(printf '%s\n' "$1" | awk -F. '{if(NF==4)print $1"."$2"."$3}')"
    ip_prefix="$(printf '%s\n' "$2" | awk -F. '{if(NF==4)print $1"."$2"."$3}')"
    [ -n "$target_prefix" ] && [ "$target_prefix" = "$ip_prefix" ] || {
        log "SNAT参数无效：临时源地址不属于目标网段：target=$1 target_ip=$2"
        return 1
    }
    return 0
}

mkdir -p "$RUNTIME_DIR"

ACTION="$1"
case "$ACTION" in
    down|remove|-r|--remove)
        [ -n "$IPTABLES" ] || exit 0
        acquire_lock || exit 0
        if [ -n "$2" ]; then
            TARGET_NET="$(normalize_network "$2")"
            [ -n "$TARGET_NET" ] && cleanup_one "$TARGET_NET"
        else
            cleanup_all
        fi
        exit 0
        ;;
    check|up)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up|check 目标网段 目标临时IP 本地LAN网段；$0 down [目标网段]"
        exit 2
        ;;
esac

check_args "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || exit 1
[ -n "$IPTABLES" ] || { log "iptables不存在，无法启用SNAT"; exit 1; }

acquire_lock || exit 0
STATE_FILE="$(state_file_for "$TARGET_NET")"
same_state=0
if [ -r "$STATE_FILE" ]; then
    old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"
    old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"
    old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
    [ "$old_target_net" = "$TARGET_NET" ] && [ "$old_target_ip" = "$TARGET_IP" ] && [ "$old_lan_net" = "$LAN_NET" ] && same_state=1
fi

# up/check都执行状态一致性检查；只清理“同一个目标网段”的旧状态，不影响其他网段。
if [ "$same_state" != "1" ]; then
    cleanup_one "$TARGET_NET"
fi

apply_rules "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || {
    log "SNAT规则写入失败：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
    exit 1
}

{
    printf 'lan_net=%s\n' "$LAN_NET"
    printf 'target_net=%s\n' "$TARGET_NET"
    printf 'target_ip=%s\n' "$TARGET_IP"
    printf 'iface=br0\n'
} > "$STATE_FILE"

if [ "$ACTION" = "up" ]; then
    log "SNAT已启用：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
else
    log "SNAT状态检查并同步：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
fi
exit 0
