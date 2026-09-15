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
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
TARGETS_FILE="$RUNTIME_DIR/lan_discovery_targets.state"
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
CYCLE_CURSOR_FILE="$RUNTIME_DIR/lan_discovery_cycle.cursor"
CURRENT_ACTIVE_FILE="$RUNTIME_DIR/lan_discovery_cycle_active.state"
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
    tmp="$RUNTIME_DIR/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"
}

time_now() { date '+%H:%M:%S'; }

log() {
    msg="$(time_now) 【网络管理】$*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t lan-autodiscover "$msg"
    runtime_set lan_discovery_status_last "$(time_now)"
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

cleanup_one() {
    target_net="$1"
    if [ -x /usr/bin/lan_snat.sh ]; then
        /usr/bin/lan_snat.sh down "$target_net" >> "$LOG_FILE" 2>&1 || :
    fi
    if [ -x /usr/bin/lan_takeover.sh ]; then
        /usr/bin/lan_takeover.sh -r "$target_net" >> "$LOG_FILE" 2>&1 || :
    fi
    rm -f "$(target_state_file "$target_net")"
}

apply_target() {
    target_net="$1"
    source_net="$2"
    scan_seq="$3"

    [ -n "$target_net" ] || return 1
    [ "$target_net" != "$source_net" ] || return 0
    [ "$target_net" != "0.0.0.0" ] || return 1

    takeover_file="$(takeover_state_file "$target_net")"
    current_ip="$(state_get "$takeover_file" ip)"

    # 临时地址不存在、状态文件丢失或者地址已经从br0消失时，立即重新接管。
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

    # SNAT使用幂等check；规则存在就保持，缺失才自动补回。
    if ! /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
        if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
            log "SNAT启用失败：$source_net/24 → $target_net/24"
            return 1
        fi
    fi

    write_target_state "$target_net" "$current_ip" 0 "$scan_seq"
    runtime_set lan_discovery_status_state "实时发现：目标网段已接管"
    log "目标网段保持：$source_net/24 → $target_net/24，临时地址=$current_ip"
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
                /usr/bin/lan_device_state.sh arp "$ip" "$field2" >/dev/null 2>&1 || :
                ;;
        esac
        apply_target "$net" "$localnet" "realtime-$kind-$(date +%s 2>/dev/null)" || :
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

    grep -v "^$local_net$" "$tmp" 2>/dev/null |
        grep -v '^0\.0\.0\.0$' 2>/dev/null |
        sort -u > "$CURRENT_ACTIVE_FILE"
    rm -f "$tmp"
}

latest_completed_cycle() {
    grep '本轮主动探测完成，继续监听，下一轮周期 ' "$LOG_FILE" 2>/dev/null | tail -n 1
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
    cycle_started="$(date +%s 2>/dev/null)"
    case "$cycle_started" in ''|*[!0-9]*) cycle_started=0;; esac

    collect_cycle_targets "$localnet"
    scan_seq="$(date +%s 2>/dev/null)-$(wc -l < "$CURRENT_ACTIVE_FILE" 2>/dev/null | tr -d ' ')"
    runtime_set lan_discovery_status_state "处理完整扫描轮次：目标网段状态增量更新"

    # 本轮真实发现的网段立即清零miss并保持现有临时IP/SNAT。
    while IFS= read -r target_net; do
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        apply_target "$target_net" "$localnet" "$scan_seq" || log "本轮目标处理失败，下轮继续尝试：$target_net/24"
    done < "$CURRENT_ACTIVE_FILE"

    # 只有完整扫描轮次才允许增加目标网段miss；管理器的实时轮询不会误删SNAT。
    # 即使完整ARP/协议扫描未发现，只要本轮开始后tcpdump有实际活动，目标网段仍然保持。
    for state_file in "$RUNTIME_DIR"/lan_target_state_*.state; do
        [ -r "$state_file" ] || continue
        target_net="$(state_get "$state_file" target_net)"
        [ -n "$target_net" ] || continue
        if grep -qx "$target_net" "$CURRENT_ACTIVE_FILE" 2>/dev/null; then
            continue
        fi

        last_seen="$(state_get "$state_file" last_seen)"
        case "$last_seen" in
            ''|*[!0-9]*) last_seen=0;;
        esac
        if [ "$last_seen" -ge "$cycle_started" ] 2>/dev/null; then
            current_ip="$(state_get "$state_file" target_ip)"
            write_target_state "$target_net" "$current_ip" 0 "$scan_seq"
            log "目标网段本轮主动扫描未发现，但实时监听仍有活动，保持：$target_net/24"
            continue
        fi

        miss_count="$(state_get "$state_file" miss_count)"
        case "$miss_count" in ''|*[!0-9]*) miss_count=0;; esac
        miss_count=$((miss_count + 1))
        current_ip="$(state_get "$state_file" target_ip)"

        if [ "$miss_count" -ge "$MISS_LIMIT" ]; then
            log "目标网段连续${miss_count}轮完整扫描未发现且无实时活动，确认清理：$target_net/24${current_ip:+，临时地址=$current_ip}"
            cleanup_one "$target_net"
        else
            old_seq="$(state_get "$state_file" last_scan_seq)"
            write_target_state "$target_net" "$current_ip" "$miss_count" "$old_seq"
            log "目标网段本轮未发现，保留：$target_net/24，连续丢失=${miss_count}/${MISS_LIMIT}轮"
        fi
    done

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

        # LAN重新插入、设备重启或规则被其它系统修改后，只补缺失部分，不删除已有目标。
        if ! ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $current_ip/24"; then
            /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1 || continue
            current_ip="$(state_get "$takeover_file" ip)"
        fi
        [ -n "$current_ip" ] || continue
        /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1 || :
    done
    update_runtime_targets
}

process_targets() {
    localnet="$1"
    process_realtime_events "$localnet"
    latest_marker="$(latest_completed_cycle)"
    if [ -n "$latest_marker" ] && ! cycle_seen_before "$latest_marker"; then
        process_completed_cycle "$localnet" "$latest_marker"
    fi
    check_existing_targets "$localnet"
}

while :; do
    if ! link_up; then
        # LAN拔出只表示“发现暂停”；不撤销任何临时IP、目标状态和SNAT规则。
        runtime_set lan_discovery_status_link "DOWN"
        runtime_set lan_discovery_status_state "LAN拔出：保留现有临时网段/SNAT"
        sleep 1
        continue
    fi

    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }

    process_targets "$localnet"
    sleep 1
done
