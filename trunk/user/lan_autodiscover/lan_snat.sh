#!/bin/sh
# Q7单口LAN无DHCP模式的定向SNAT。
# 手机仍使用Q7 LAN网段地址，访问目标LAN时把源地址转换成目标LAN临时地址。
#
# 设计说明：
# 1. 目标LAN与Q7 LAN共用br0，因此目标流量也从br0出去；
# 2. TARGET_IP是lan_takeover.sh在目标网段中自动挑选的临时源地址，不能留空；
# 3. eth2.2上的普通MASQUERADE属于Padavan原有网络逻辑，不与本规则冲突；
# 4. 多个LAN管理器实例可能同时检查SNAT，因此本程序使用mkdir锁避免并发插入/删除规则。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/lan_snat.state"
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

# 规则必须放在链首，避免被Padavan其他规则提前匹配。
# 已存在时不移动，避免已建立连接因规则重排而受到影响；不存在时才插入。
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

    # 同一物理口的跨网段访问，需要br0到br0的转发放行。
    rule_add_first filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
    rule_add_first filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 核心规则：目标设备只看到目标LAN中的临时IP，而不是手机的Q7 LAN地址。
    # 这里不能改成MASQUERADE到eth2.2，也不能删除--to-source "$TARGET_IP"。
    rule_add_first nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"
}

check_args() {
    case "$1:$2:$3" in
        *.*.*.*:*.*.*.*:*.*.*.*) ;;
        *) log "SNAT参数无效：target=$1 target_ip=$2 lan=$3"; return 1;;
    esac
    [ "$1" != "$3" ] || { log "SNAT参数无效：目标网段与本地网段不能相同：$1"; return 1; }
    case "$2" in
        "$1"*) return 0 ;;
    esac
    target_net="$1"
    target_ip="$2"
    target_prefix="$(printf '%s\n' "$target_net" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    ip_prefix="$(printf '%s\n' "$target_ip" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    [ -n "$target_prefix" ] && [ "$target_prefix" = "$ip_prefix" ] || {
        log "SNAT参数无效：临时源地址不属于目标网段：target=$1 target_ip=$2"
        return 1
    }
    return 0
}

mkdir -p "$RUNTIME_DIR"

case "$1" in
    down|remove|-r|--remove)
        if [ -z "$IPTABLES" ]; then
            rm -f "$STATE_FILE"
            exit 0
        fi
        acquire_lock || exit 0
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

acquire_lock || exit 0

if [ "$1" = "up" ]; then
    # 只有目标网段、临时源地址或本地网段真正变化时才清理旧规则。
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
