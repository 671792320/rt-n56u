#!/bin/sh
# Q7 LAN网络管理器。
# 手机始终使用Q7自己的LAN网段；发现到的目标网段统一通过临时IP+SNAT访问。
#
# 生命周期严格分为两层：
# 1. 实时发现：tcpdump、ARP、ONVIF/SSDP/海康/大华等一旦出现新IP，立即登记目标网段并接管SNAT。
# 2. 周期维护：完整扫描结束后才更新目标网段miss_count；达到阈值才清理SNAT和临时IP。
# LAN拔出只停止发现worker，不清理已有目标网段、临时IP和SNAT。

IFACE=eth2.1
BR_IF=br0
LOCKDIR=/var/run/lan_network_manager.lock

# 网络管理器必须严格保持单实例。
# 除锁目录外，同时记录PID并校验实际命令行，避免旧PID文件或异常退出造成重复实例。
manager_pid_valid() {
    pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 1;;
    esac
    [ "$pid" != "$$" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmdline" in
        *"/usr/bin/lan_network_manager.sh"*) return 0;;
    esac
    return 1
}

acquire_manager_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCKDIR/pid"
        return 0
    fi

    old_pid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    if manager_pid_valid "$old_pid"; then
        logger -t lan-autodiscover "LAN网络模式管理器已经运行：PID=$old_pid"
        return 1
    fi

    # 锁目录残留但PID已经失效，只清理失效锁后重新获取。
    rm -f "$LOCKDIR/pid" 2>/dev/null
    rmdir "$LOCKDIR" 2>/dev/null || return 1

    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCKDIR/pid"
        return 0
    fi
    return 1
}

acquire_manager_lock || exit 0
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
TARGETS_FILE="$RUNTIME_DIR/lan_discovery_targets.state"
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
CYCLE_CURSOR_FILE="$RUNTIME_DIR/lan_discovery_cycle.cursor"
CURRENT_ACTIVE_FILE="$RUNTIME_DIR/lan_discovery_cycle_active.state"
cleanup() {
    old_pid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    if [ "$old_pid" = "$$" ]; then
        rm -f "$LOCKDIR/pid" 2>/dev/null
        rmdir "$LOCKDIR" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM HUP

ARP_CURSOR_FILE="$RUNTIME_DIR/realtime_arp.cursor"
PROTO_CURSOR_FILE="$RUNTIME_DIR/realtime_proto.cursor"
TCPDUMP_CURSOR_FILE="$RUNTIME_DIR/realtime_tcpdump.cursor"

MISS_LIMIT="$(nvram get lan_discovery_miss_limit 2>/dev/null)"
case "$MISS_LIMIT" in ''|*[!0-9]*) MISS_LIMIT=3;; esac
[ "$MISS_LIMIT" -ge 1 ] 2>/dev/null || MISS_LIMIT=1
[ "$MISS_LIMIT" -le 20 ] 2>/dev/null || MISS_LIMIT=20

mkdir -p "$RUNTIME_DIR"

runtime_set() {
    key="$1"
    value="$2"
    tmp="$RUNTIME_DIR/.$key.tmp.$"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"
}

beijing_now() {
    tz="$(nvram get time_zone_x 2>/dev/null)"
    [ -n "$tz" ] || tz='GMT-8'
    TZ="$tz" date '+%Y-%m-%d %H:%M:%S'
}
LOG_DEDUPE_DIR="$RUNTIME_DIR/.log_dedupe_network_manager"
mkdir -p "$LOG_DEDUPE_DIR"

log() {
    plain="$*"
    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    last_ts="$(cat "$LOG_DEDUPE_DIR/ts" 2>/dev/null)"
    case "$last_ts" in ''|*[!0-9]*) last_ts=0;; esac
    last_msg="$(cat "$LOG_DEDUPE_DIR/msg" 2>/dev/null)"
    if [ "$last_msg" = "$plain" ] && [ "$now_ts" -ge "$last_ts" ] 2>/dev/null && [ $((now_ts - last_ts)) -lt 5 ] 2>/dev/null; then
        return 0
    fi
    printf '%s' "$now_ts" > "$LOG_DEDUPE_DIR/ts"
    printf '%s' "$plain" > "$LOG_DEDUPE_DIR/msg"
    msg="$(beijing_now) 【网络管理】$plain"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t lan-autodiscover "【LAN网络】$plain"
    runtime_set lan_discovery_status_last "$(beijing_now)"
}

link_up() {
    if [ -x /sbin/mtk_esw ]; then
        state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
        [ "$state" = "1" ] && return 0
        [ "$state" = "0" ] && return 1
    fi
    [ -r "/sys/class/net/$IFACE/carrier" ] && [ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)" = "1" ] && return 0
    [ ! -r "/sys/class/net/$IFACE/carrier" ] && [ "$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)" = "up" ] && return 0
    return 1
}

local_ip() {
    ip_from_nvram="$(nvram get lan_ipaddr 2>/dev/null)"
    case "$ip_from_nvram" in
        *.*.*.*) printf '%s\n' "$ip_from_nvram"; return 0;;
    esac
    ip -4 addr show dev "$BR_IF" 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' | head -n 1
}

network_from_ip() {
    printf '%s\n' "$1" |
        awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0\n",$1,$2,$3}'
}

state_key() { printf '%s' "$1" | tr '.' '_'; }
target_state_file() { printf '%s/lan_target_state_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
takeover_state_file() { printf '%s/lan_takeover_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
snat_state_file() { printf '%s/lan_snat_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
state_get() { file="$1"; key="$2"; sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1; }

write_target_state() {
    target_net="$1"
    target_ip="$2"
    miss_count="$3"
    scan_seq="$4"
    state_file="$(target_state_file "$target_net")"
    tmp="${state_file}.tmp"
    {
        printf 'target_net=%s\n' "$target_net"
        printf 'target_ip=%s\n' "$target_ip"
        printf 'miss_count=%s\n' "$miss_count"
        printf 'last_scan_seq=%s\n' "$scan_seq"
        printf 'last_seen=%s\n' "$(date +%s 2>/dev/null)"
    } > "$tmp" && mv -f "$tmp" "$state_file"
}

update_runtime_targets() {
    tmp="$RUNTIME_DIR/.lan_discovery_targets.tmp"
    : > "$tmp"
    for f in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$f" ] || continue
        net="$(state_get "$f" network)"
        ipaddr="$(state_get "$f" ip)"
        [ -n "$net" ] || continue
        [ "$net" != "0.0.0.0" ] || continue
        [ -n "$ipaddr" ] || continue
        printf '%s|%s\n' "$net/24" "$ipaddr" >> "$tmp"
    done
    sort -u "$tmp" > "$TARGETS_FILE"
    rm -f "$tmp"

    targets_text="$(awk 'BEGIN{ORS=""} {if(NR>1) printf ";"; printf "%s",$0}' "$TARGETS_FILE" 2>/dev/null)"
    nvram set lan_discovery_status_targets "$targets_text" 2>/dev/null || :

    first="$(head -n 1 "$TARGETS_FILE" 2>/dev/null)"
    if [ -n "$first" ]; then
        first_net="${first%%|*}"
        first_ip="${first#*|}"
        runtime_set lan_discovery_status_target_network "$first_net"
        runtime_set lan_discovery_status_target_ip "$first_ip"
        runtime_set lan_discovery_status_target_iface "$BR_IF"
    else
        runtime_set lan_discovery_status_target_network ""
        runtime_set lan_discovery_status_target_ip ""
        runtime_set lan_discovery_status_target_iface ""
        nvram set lan_discovery_status_targets "" 2>/dev/null || :
    fi
}

apply_target() {
    target_net="$1"
    source_net="$2"
    scan_seq="$3"

    [ -n "$target_net" ] || return 1
    [ "$target_net" != "$source_net" ] || return 0
    [ "$target_net" != "0.0.0.0" ] || return 1

    pending_file="$RUNTIME_DIR/lan_pending_$(state_key "$target_net").state"
    if [ -r "$pending_file" ]; then
        retry_after="$(cat "$pending_file" 2>/dev/null)"
        now_ts="$(date +%s 2>/dev/null)"
        case "$retry_after:$now_ts" in
            *[!0-9:]*|:) retry_after=0;;
        esac
        if [ "$now_ts" -lt "$retry_after" ] 2>/dev/null; then
            return 1
        fi
        rm -f "$pending_file"
    fi

    state_file="$(target_state_file "$target_net")"
    # 目标网段一旦建立SNAT就进入本次开机周期锁定状态。
    # 后续相同网段实时事件直接丢弃，不重新选临时地址、不重建SNAT。
    if [ -r "$state_file" ]; then
        runtime_set lan_discovery_status_state "实时发现：目标网段已锁定"
        return 0
    fi

    takeover_file="$(takeover_state_file "$target_net")"
    current_ip="$(state_get "$takeover_file" ip)"

    # 新目标第一次出现时才分配该网段内的空闲临时地址。
    if [ -z "$current_ip" ] || ! ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $current_ip/24"; then
        if ! /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1; then
            log "目标网段接管失败：$target_net/24"
            return 1
        fi
        current_ip="$(state_get "$takeover_file" ip)"
        [ -n "$current_ip" ] || {
            log "无法取得目标网段临时地址：$target_net/24"
            return 1
        }
    fi

    if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
        pending_file="$RUNTIME_DIR/lan_pending_$(state_key "$target_net").state"
        now_ts="$(date +%s 2>/dev/null)"
        case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
        printf '%s\n' "$((now_ts + 10))" > "$pending_file"
        log "SNAT暂未完成，10秒后重试：$source_net/24 → $target_net/24"
        return 1
    fi

    write_target_state "$target_net" "$current_ip" 0 "$scan_seq"
    rm -f "$RUNTIME_DIR/lan_pending_$(state_key "$target_net").state"
    log "目标网段首次接管：$source_net/24 → $target_net/24，临时地址=$current_ip"
    runtime_set lan_discovery_status_state "实时发现：目标网段已接管"
    update_runtime_targets
    return 0
}

process_stream_file() {
    file="$1"
    cursor_file="$2"
    localnet="$3"
    kind="$4"

    [ -r "$file" ] || return 0
    count="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
    case "$count" in ''|*[!0-9]*) count=0;; esac
    cursor="$(cat "$cursor_file" 2>/dev/null)"
    case "$cursor" in ''|*[!0-9]*) cursor=0;; esac
    [ "$count" -ge "$cursor" ] || cursor=0
    [ "$count" -gt "$cursor" ] || return 0

    start=$((cursor + 1))
    sed -n "${start},${count}p" "$file" 2>/dev/null |
    while IFS='|' read -r ip field2 field3 field4; do
        [ -n "$ip" ] || continue
        net="$(network_from_ip "$ip")"
        [ -n "$net" ] || continue
        [ "$net" != "$localnet" ] || continue
        case "$kind" in
            ARP)
                /usr/bin/lan_device_state.sh arp "$ip" "$field2" >/dev/null 2>&1 || :
                ;;
            PROTO)
                /usr/bin/lan_device_state.sh proto "$ip" "$field2" >/dev/null 2>&1 || :
                ;;
            TCPDUMP)
                # 实时监听只负责发现目标网段；避免每个IPv4数据包都再启动一个Shell状态进程。
                ;;
        esac
        takeover_file="$(takeover_state_file "$net")"
        current_ip="$(state_get "$takeover_file" ip)"
        if [ -z "$current_ip" ] || ! ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $current_ip/24"; then
            apply_target "$net" "$localnet" "realtime-$kind" || :
        else
            state_file="$(target_state_file "$net")"
            [ -r "$state_file" ] || apply_target "$net" "$localnet" "realtime-$kind" || :
        fi
    done
    printf '%s\n' "$count" > "$cursor_file"
}

process_realtime_events() {
    localnet="$1"
    # ARP、私有协议和tcpdump均实时进入同一个目标接管流程；管理器自身不改变miss_count。
    process_stream_file "$RUNTIME_DIR/arp_seen.txt" "$ARP_CURSOR_FILE" "$localnet" ARP
    process_stream_file "$RUNTIME_DIR/device_protocol_events.txt" "$PROTO_CURSOR_FILE" "$localnet" PROTO
    process_stream_file "$RUNTIME_DIR/tcpdump_discovery_events.txt" "$TCPDUMP_CURSOR_FILE" "$localnet" TCPDUMP
}

collect_cycle_targets() {
    local_net="$1"
    cycle_started="$2"
    tmp="$RUNTIME_DIR/.lan_cycle_targets.tmp"
    : > "$tmp"

    if [ -r "$RUNTIME_DIR/arp_seen.txt" ]; then
        cut -d'|' -f1 "$RUNTIME_DIR/arp_seen.txt" 2>/dev/null |
            while IFS= read -r ip; do network_from_ip "$ip"; done >> "$tmp"
    fi

    if [ -r "$RUNTIME_DIR/device_protocol_events.txt" ]; then
        cut -d'|' -f1 "$RUNTIME_DIR/device_protocol_events.txt" 2>/dev/null |
            while IFS= read -r ip; do network_from_ip "$ip"; done >> "$tmp"
    fi

    # 实时二层监听同样属于本轮真实活动，不能因为主动ARP/协议扫描没命中
    # 就把仍在通信的目标网段清掉，否则下一条实时事件又会重新触发“首次接管”。
    if [ -r "$RUNTIME_DIR/tcpdump_discovery_events.txt" ]; then
        awk -F'|' -v start="$cycle_started" '$4 >= start {print $1}'             "$RUNTIME_DIR/tcpdump_discovery_events.txt" 2>/dev/null |
            while IFS= read -r ip; do network_from_ip "$ip"; done >> "$tmp"
    fi

    grep -v "^$local_net$" "$tmp" 2>/dev/null |
        grep -v '^0\.0\.0\.0$' 2>/dev/null |
        sort -u > "$CURRENT_ACTIVE_FILE"
    rm -f "$tmp"
}

latest_completed_cycle() {
    [ -r "$RUNTIME_DIR/lan_discovery_sweep_complete" ] || return 1
    marker="$(cat "$RUNTIME_DIR/lan_discovery_sweep_complete" 2>/dev/null)"
    case "$marker" in
        ''|*[!0-9]*) return 1;;
    esac
    printf '%s\n' "$marker"
}

cycle_seen_before() {
    marker="$1"
    [ -r "$CYCLE_CURSOR_FILE" ] || return 1
    old="$(cat "$CYCLE_CURSOR_FILE" 2>/dev/null)"
    [ "$old" = "$marker" ]
}

save_cycle_cursor() { printf '%s\n' "$1" > "$CYCLE_CURSOR_FILE"; }

process_completed_cycle() {
    localnet="$1"
    marker="$2"
    # marker就是本轮真正主动补漏开始的时间，而不是10秒探测窗口结束时间。
    cycle_started="$marker"

    collect_cycle_targets "$localnet" "$cycle_started"
    scan_seq="$(date +%s 2>/dev/null)-$(wc -l < "$CURRENT_ACTIVE_FILE" 2>/dev/null | tr -d ' ')"
    runtime_set lan_discovery_status_state "处理完整扫描轮次：目标网段状态增量更新"

    # 本轮真实发现的网段立即清零miss并保持现有临时IP/SNAT。
    while IFS= read -r target_net; do
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        apply_target "$target_net" "$localnet" "$scan_seq" || log "本轮目标处理失败，下轮继续尝试：$target_net/24"
    done < "$CURRENT_ACTIVE_FILE"

    # SNAT采用本次开机周期锁定策略。
    # 完整扫描只负责发现新的目标网段；已经锁定的目标永不因miss_count自动删除。
    # 因此这里不再执行目标网段清理、临时地址撤销或SNAT切换。

    save_cycle_cursor "$marker"
    update_runtime_targets
    rm -f "$CURRENT_ACTIVE_FILE"
    log "本轮目标网段状态更新完成：连续${MISS_LIMIT}个完整扫描轮次未发现且无实时活动才清理"
}

check_existing_targets() {
    localnet="$1"
    for takeover_file in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$takeover_file" ] || continue
        target_net="$(state_get "$takeover_file" network)"
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        current_ip="$(state_get "$takeover_file" ip)"
        source_net="$localnet"
        [ -n "$current_ip" ] || continue

        # 目标网段已经锁定后，不因临时地址异常自动重新分配。
        # 只有重启或用户手动清除SNAT后才重新建立完整接管状态。
        if ! ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $current_ip/24"; then
            log "已锁定目标的临时地址不存在，保持锁定不自动重建：$target_net/24"
            continue
        fi
        /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1 || :
    done
    update_runtime_targets
}

last_maintenance=0

while :; do
    if ! link_up; then
        # LAN拔出后直接退出网络管理器，由supervisor按需重新启动。
        # 这里只停止网络管理进程，绝不撤销已有临时IP、目标状态和SNAT规则。
        runtime_set lan_discovery_status_link "DOWN"
        runtime_set lan_discovery_status_state "LAN拔出：保留现有临时网段/SNAT"
        exit 0
    fi

    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }

    process_realtime_events "$localnet"

    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    if [ "$last_maintenance" = "0" ] || [ $((now_ts - last_maintenance)) -ge 30 ] 2>/dev/null; then
        latest_marker="$(latest_completed_cycle)"
        if [ -n "$latest_marker" ] && ! cycle_seen_before "$latest_marker"; then
            process_completed_cycle "$localnet" "$latest_marker"
        fi
        check_existing_targets "$localnet"
        last_maintenance="$now_ts"
    fi

    sleep 1
done
