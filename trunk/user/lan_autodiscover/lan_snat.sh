#!/bin/sh
# Q7单口LAN无DHCP模式的定向SNAT。
# 手机仍使用Q7 LAN网段地址，访问目标LAN时把源地址转换成目标LAN临时地址。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/lan_snat.state"
LOGTAG=lan-autodiscover

# Padavan/Q7 实际环境中 iptables 位于 /bin/iptables；不同固件也可能位于
# /sbin 或 /usr/sbin。禁止把路径写死，否则功能正常的iptables会被误判为不存在。
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

rule_add() {
    table="$1"; chain="$2"; shift 2
    rule_exists "$table" "$chain" "$@" || "$IPTABLES" -t "$table" -A "$chain" "$@"
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
    if [ -n "$old_target_net" ] && [ -n "$old_target_ip" ] && [ -n "$old_lan_net" ]; then
        rule_del_all nat POSTROUTING -s "$old_lan_net/24" -d "$old_target_net/24" -o br0 -j SNAT --to-source "$old_target_ip"
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_lan_net/24" -d "$old_target_net/24" -j ACCEPT
        rule_del_all filter FORWARD -i br0 -o br0 -s "$old_target_net/24" -d "$old_lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "撤销SNAT：$old_lan_net/24 -> $old_target_net/24，源地址=$old_target_ip"
    fi
    rm -f "$STATE_FILE"
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
    up)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up 目标网段 目标临时IP 本地LAN网段；$0 down"
        exit 2
        ;;
esac

case "$TARGET_NET:$TARGET_IP:$LAN_NET" in
    *.*.*.*:*.*.*.*:*.*.*.*) ;;
    *) log "SNAT参数无效：target=$TARGET_NET target_ip=$TARGET_IP lan=$LAN_NET"; exit 1;;
esac

[ -n "$IPTABLES" ] || { log "iptables不存在，无法启用SNAT"; exit 1; }

cleanup

# 允许本机承担路由器职责；即使Padavan其他模块已开启，重复设置也是幂等的。
[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :

rule_add filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
rule_add filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
rule_add nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"

{
    printf 'lan_net=%s\n' "$LAN_NET"
    printf 'target_net=%s\n' "$TARGET_NET"
    printf 'target_ip=%s\n' "$TARGET_IP"
    printf 'iface=br0\n'
} > "$STATE_FILE"

log "SNAT已启用：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
exit 0
