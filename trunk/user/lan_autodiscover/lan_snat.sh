#!/bin/sh
# Q7单口LAN多目标网段SNAT管理。
# 每个目标网段独立使用一个空闲临时地址，并独立建立SNAT。
# SNAT建立后在本次开机周期内保持锁定，不因扫描不到、LAN拔出或发现其它网段而自动删除或切换。
# 只有系统停止服务/重启，或手动执行down时才清除SNAT。

RUNTIME_DIR=/tmp/lan_discovery_runtime
LOCK_DIR=$RUNTIME_DIR/.lan_snat.lock
LOGTAG=lan-autodiscover

find_iptables() {
    if command -v iptables >/dev/null 2>&1; then command -v iptables; return 0; fi
    for p in /bin/iptables /sbin/iptables /usr/sbin/iptables; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
IPTABLES="$(find_iptables 2>/dev/null)"

beijing_now() {
    tz="$(nvram get time_zone_x 2>/dev/null)"
    [ -n "$tz" ] || tz='GMT-8'
    TZ="$tz" date '+%Y-%m-%d %H:%M:%S'
}

LOG_DEDUPE_DIR=$RUNTIME_DIR/.log_dedupe_snat
mkdir -p "$LOG_DEDUPE_DIR"
log() {
    plain="$*"
    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    last_ts="$(cat "$LOG_DEDUPE_DIR/ts" 2>/dev/null)"
    case "$last_ts" in ''|*[!0-9]*) last_ts=0;; esac
    last_msg="$(cat "$LOG_DEDUPE_DIR/msg" 2>/dev/null)"
    if [ "$last_msg" = "$plain" ] && [ "$now_ts" -ge "$last_ts" ] 2>/dev/null && [ $((now_ts - last_ts)) -lt 5 ] 2>/dev/null; then return 0; fi
    printf '%s' "$now_ts" > "$LOG_DEDUPE_DIR/ts"
    printf '%s' "$plain" > "$LOG_DEDUPE_DIR/msg"
    logger -t "$LOGTAG" "[snat] $plain"
    printf '%s\n' "$(beijing_now) [snat] $plain"
}

acquire_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT INT TERM
    return 0
}
state_key() { printf '%s' "$1" | tr '.' '_'; }
state_file() { printf '%s/lan_snat_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
state_get() { file="$1"; key="$2"; sed -n "s/^$key=//p" "$file" 2>/dev/null | head -n 1; }

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

check_args() {
    case "$1:$2:$3" in *.*.*.*:*.*.*.*:*.*.*.*) ;; *) return 1;; esac
    [ "$1" != "$3" ] || { log "SNAT参数无效：目标网段与本地网段相同：$1"; return 1; }
    target_prefix="$(printf '%s\n' "$1" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    ip_prefix="$(printf '%s\n' "$2" | awk -F. 'NF==4 {print $1"."$2"."$3}')"
    [ "$target_prefix" = "$ip_prefix" ] || { log "SNAT参数无效：临时地址不属于目标网段：$1 -> $2"; return 1; }
    return 0
}

apply_rules() {
    target_net="$1"; target_ip="$2"; lan_net="$3"
    [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :
    rule_add_first filter FORWARD -i br0 -o br0 -s "$lan_net/24" -d "$target_net/24" -j ACCEPT
    rule_add_first filter FORWARD -i br0 -o br0 -s "$target_net/24" -d "$lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    rule_add_first nat POSTROUTING -s "$lan_net/24" -d "$target_net/24" -o br0 -j SNAT --to-source "$target_ip"
}

remove_one() {
    target_net="$1"
    state="$(state_file "$target_net")"
    [ -r "$state" ] || return 0
    target_ip="$(state_get "$state" target_ip)"
    lan_net="$(state_get "$state" lan_net)"
    if [ -n "$IPTABLES" ] && [ -n "$target_ip" ] && [ -n "$lan_net" ]; then
        rule_del_all nat POSTROUTING -s "$lan_net/24" -d "$target_net/24" -o br0 -j SNAT --to-source "$target_ip"
        rule_del_all filter FORWARD -i br0 -o br0 -s "$lan_net/24" -d "$target_net/24" -j ACCEPT
        rule_del_all filter FORWARD -i br0 -o br0 -s "$target_net/24" -d "$lan_net/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "手动删除SNAT：$lan_net/24 -> $target_net/24，临时地址=$target_ip"
    fi
    rm -f "$state"
}
remove_all() {
    for state in "$RUNTIME_DIR"/lan_snat_*.state; do
        [ -r "$state" ] || continue
        target_net="$(state_get "$state" target_net)"
        [ -n "$target_net" ] && remove_one "$target_net"
    done
}

mkdir -p "$RUNTIME_DIR"
case "$1" in
    down|remove|-r|--remove)
        [ -n "$IPTABLES" ] || exit 0
        acquire_lock || exit 1
        if [ -n "$2" ]; then
            target_net="$(printf '%s\n' "$2" | sed 's|/24$||')"
            remove_one "$target_net"
        else
            remove_all
        fi
        exit 0
        ;;
    up|check)
        TARGET_NET="$2"; TARGET_IP="$3"; LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up|check 目标网段 临时地址 本地LAN网段；$0 down [目标网段]"
        exit 2
        ;;
esac

check_args "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || exit 1
[ -n "$IPTABLES" ] || { log "iptables不存在，无法维护SNAT"; exit 1; }
acquire_lock || exit 1

STATE_FILE="$(state_file "$TARGET_NET")"

if [ "$1" = "up" ]; then
    # 同一目标网段已经锁定时，直接忽略；绝不换临时地址、删除旧规则或切换到其它网段。
    if [ -r "$STATE_FILE" ]; then
        old_ip="$(state_get "$STATE_FILE" target_ip)"
        old_lan="$(state_get "$STATE_FILE" lan_net)"
        [ -n "$old_ip" ] && [ -n "$old_lan" ] || exit 1
        apply_rules "$TARGET_NET" "$old_ip" "$old_lan" || exit 1
        exit 0
    fi

    apply_rules "$TARGET_NET" "$TARGET_IP" "$LAN_NET" || {
        log "SNAT规则写入失败：$LAN_NET/24 -> $TARGET_NET/24，临时地址=$TARGET_IP"
        exit 1
    }

    tmp="$STATE_FILE.tmp.$$"
    {
        printf 'lan_net=%s\n' "$LAN_NET"
        printf 'target_net=%s\n' "$TARGET_NET"
        printf 'target_ip=%s\n' "$TARGET_IP"
        printf 'iface=br0\n'
        printf 'locked=1\n'
        printf 'created=%s\n' "$(date +%s 2>/dev/null)"
    } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
    log "SNAT已锁定：$LAN_NET/24 -> $TARGET_NET/24，临时地址=$TARGET_IP"
    exit 0
fi

# check只修复当前锁定项缺失的iptables规则，不改变网段和临时地址。
state_ip="$(state_get "$STATE_FILE" target_ip)"
state_lan="$(state_get "$STATE_FILE" lan_net)"
[ -n "$state_ip" ] || state_ip="$TARGET_IP"
[ -n "$state_lan" ] || state_lan="$LAN_NET"
missing=0
rule_exists filter FORWARD -i br0 -o br0 -s "$state_lan/24" -d "$TARGET_NET/24" -j ACCEPT || missing=1
rule_exists filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$state_lan/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || missing=1
rule_exists nat POSTROUTING -s "$state_lan/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$state_ip" || missing=1
if [ "$missing" = "1" ]; then
    apply_rules "$TARGET_NET" "$state_ip" "$state_lan" || exit 1
    log "SNAT规则已补齐：$state_lan/24 -> $TARGET_NET/24，临时地址=$state_ip"
fi
exit 0
