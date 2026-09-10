#!/bin/sh
# Q7单口LAN无DHCP模式的定向SNAT。
# 手机仍使用Q7 LAN网段地址，访问目标LAN时把源地址转换成目标LAN临时地址。
#
# 关键点：Padavan防火墙可能在运行过程中重建iptables规则，而且普通LAN的
# MASQUERADE/SNAT规则可能先于本规则匹配。因此本程序必须把自己的规则插到
# 链首，而不是简单追加到链尾；同时支持check动作，供网络管理器周期补齐。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/lan_snat.state"
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

rule_exists() {
    table="$1"; chain="$2"; shift 2
    "$IPTABLES" -t "$table" -C "$chain" "$@" 2>/dev/null
}

# 规则必须放在链首，避免被Padavan后续的通用规则提前匹配。
# -C确认存在时不移动，保持连接跟踪稳定；缺失时才-I 1补回。
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

cleanup() {
    [ -r "$STATE_FILE" ] || return 0
    old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"
    old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"
    old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
    if [ -n "$old_target_net" ] && [ -n "$old_target_ip" ] && [ -n "$old_lan_net" ] && [ -n "$IPTABLES" ]; then
        rule_del_all nat POSTROUTING -s "$old_lan_net/24" -d "$old_target_net/24" -o br0 -j SNAT --to-source "$old_target_ip"
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_lan_net/24" -d "$old_target_net/24" -j ACCEPT
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_target_net/24" -d "$old_lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "撤销SNAT：$old_lan_net/24 -> $old_target_net/24，源地址=$old_target_ip"
    fi
    rm -f "$STATE_FILE"
}

apply_rules() {
    TARGET_NET="$1"
    TARGET_IP="$2"
    LAN_NET="$3"

    # 允许Q7在单口LAN上承担三层转发职责。
    [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :

    # 必须使用-I 1：不能让Padavan已有的FORWARD DROP或通用规则抢先匹配。
    rule_add_first filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
    rule_add_first filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # SNAT同样必须位于POSTROUTING链首，防止被通用MASQUERADE提前选中。
    rule_add_first nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"
}

check_args() {
    case "$1:$2:$3" in
        *.*.*.*:*.*.*.*:*.*.*.*) return 0 ;;
        *) log "SNAT参数无效：target=$1 target_ip=$2 lan=$3"; return 1 ;;
    esac
}

mkdir -p "$RUNTIME_DIR"

case "$1" in
    down|remove|-r|--remove)
        if [ -z "$IPTABLES" ]; then
            rm -f "$STATE_FILE"
            exit 0
        fi
        cleanup
        exit 0
        ;;
    check|up)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up|check 目标网段 目标临时IP 本地LAN网段；$0 down"
        exit 2
        ;;
esac

check_args "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || exit 1
[ -n "$IPTABLES" ] || { log "iptables不存在，无法启用SNAT"; exit 1; }

if [ "$1" = "up" ]; then
    # 只有目标网段、源地址或本地网段真正变化时才清理旧规则。
    # 相同参数重复up直接保持现有conntrack和iptables规则不动。
    same_state=0
    if [ -r "$STATE_FILE" ]; then
        old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"
        old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"
        old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
        [ "$old_target_net" = "$TARGET_NET" ] && [ "$old_target_ip" = "$TARGET_IP" ] && [ "$old_lan_net" = "$LAN_NET" ] && same_state=1
    fi

    if [ "$same_state" != "1" ]; then
        cleanup
    fi
fi

apply_rules "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || {
    log "SNAT规则写入失败：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
    exit 1
}

if [ "$1" = "up" ]; then
    {
        printf 'lan_net=%s\n' "$LAN_NET"
        printf 'target_net=%s\n' "$TARGET_NET"
        printf 'target_ip=%s\n' "$TARGET_IP"
        printf 'iface=br0\n'
    } > "$STATE_FILE"
    log "SNAT已启用：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
else
    log "SNAT规则检查并补齐：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
fi
exit 0
