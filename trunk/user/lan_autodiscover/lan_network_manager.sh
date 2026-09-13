#!/bin/sh
# Q7 LAN网络管理器。
# 手机始终使用Q7自己的LAN网段；所有发现到的目标网段统一通过临时IP+SNAT访问。
#
# 目标网段采用“扫描轮次”状态管理：
# 1. 只有监听到完整的一轮“本轮主动探测完成”后，才更新目标网段状态。
# 2. 当前轮发现的网段：miss_count=0，并保持原临时IP/SNAT。
# 3. 当前轮没有发现的旧网段：miss_count+1。
# 4. 连续3个完整扫描轮次没有发现，才删除临时IP和SNAT。
# 5. 扫描周期可自由设置10/20/30/60秒等，不需要重新计算固定超时时间。
# 6. 扫描尚未完成、网线变化或进程异常，不增加miss_count，避免误删。

IFACE=eth2.1
BR_IF=br0
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
TARGETS_FILE="$RUNTIME_DIR/lan_discovery_targets.state"
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
CYCLE_CURSOR_FILE="$RUNTIME_DIR/lan_discovery_cycle.cursor"
CURRENT_ACTIVE_FILE="$RUNTIME_DIR/lan_discovery_cycle_active.state"
miss_limit_current() {
    miss_limit="$(nvram get lan_discovery_miss_limit 2>/dev/null)"
    case "$miss_limit" in ''|*[!0-9]*) miss_limit=3;; esac
    [ "$miss_limit" -ge 1 ] 2>/dev/null || miss_limit=1
    [ "$miss_limit" -le 20 ] 2>/dev/null || miss_limit=20
    printf '%s' "$miss_limit"
}

mkdir -p "$RUNTIME_DIR"

time_now() { date '+%H:%M:%S'; }

log() {
    msg="$(time_now) 【网络管理】$*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t lan-autodiscover "$msg"
    runtime_set lan_discovery_status_last="$(time_now)"
}

runtime_set() {
    key="$1"
    value="$2"
    tmp="$RUNTIME_DIR/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"
}

link_up() {
    if [ -x /sbin/mtk_esw ]; then
        state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
        [ "$state" = "1" ] && return 0
        [ "$state" = "0" ] && return 1
    fi
    return 0
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
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0\n",$1,$2,$3}'
}

state_key() {
    printf '%s' "$1" | tr '.' '_'
}

target_state_file() {
    printf '%s/lan_target_state_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"
}

takeover_state_file() {
    printf '%s/lan_takeover_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"
}

snat_state_file() {
    printf '%s/lan_snat_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"
}

state_get() {
    file="$1"
    key="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

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
    takeover_file="$(takeover_state_file "$target_net")"
    snat_file="$(snat_state_file "$target_net")"

    old_target_ip="$(state_get "$takeover_file" ip)"
    old_lan_net="$(state_get "$snat_file" lan_net)"
    old_snat_target="$(state_get "$snat_file" target_net)"

    [ -n "$old_snat_target" ] || old_snat_target="$target_net"

    if [ -x /usr/bin/lan_snat.sh ]; then
        /usr/bin/lan_snat.sh down "$target_net" >> "$LOG_FILE" 2>&1 || :
    fi
    if [ -x /usr/bin/lan_takeover.sh ]; then
        /usr/bin/lan_takeover.sh -r "$target_net" >> "$LOG_FILE" 2>&1 || :
    fi

    rm -f "$(target_state_file "$target_net")"
    :
}

cleanup_network() {
    for f in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$f" ] || continue
        net="$(state_get "$f" network)"
        [ -n "$net" ] || continue
        cleanup_one "$net"
    done
    rm -f "$STATE_FILE" "$TARGETS_FILE" "$CURRENT_ACTIVE_FILE" "$CYCLE_CURSOR_FILE"
    rm -f "$RUNTIME_DIR"/lan_target_state_*.state
    update_runtime_targets
    runtime_set lan_discovery_status_state "等待接口"
}

# 从本轮ARP和协议事件中提取“本轮真实发现到”的目标网段。
# 这些文件在下一轮开始时才会重新清空，所以网络管理器只在完整扫描结束后读取。
collect_cycle_targets() {
    local_net="$1"
    tmp="$RUNTIME_DIR/.lan_cycle_targets.tmp"
    : > "$tmp"

    if [ -r "$RUNTIME_DIR/arp_seen.txt" ]; then
        cut -d'|' -f1 "$RUNTIME_DIR/arp_seen.txt" 2>/dev/null |
            while IFS= read -r ip; do
                network_from_ip "$ip"
            done >> "$tmp"
    fi

    if [ -r "$RUNTIME_DIR/device_protocol_events.txt" ]; then
        cut -d'|' -f1 "$RUNTIME_DIR/device_protocol_events.txt" 2>/dev/null |
            while IFS= read -r ip; do
                network_from_ip "$ip"
            done >> "$tmp"
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

save_cycle_cursor() {
    printf '%s\n' "$1" > "$CYCLE_CURSOR_FILE"
}

apply_target() {
    target_net="$1"
    source_net="$2"
    state_file="$(target_state_file "$target_net")"
    takeover_file="$(takeover_state_file "$target_net")"
    snat_file="$(snat_state_file "$target_net")"

    [ -n "$target_net" ] || return 1
    [ "$target_net" != "$source_net" ] || return 0
    [ "$target_net" != "0.0.0.0" ] || return 1

    current_ip="$(state_get "$takeover_file" ip)"

    # 首次发现、临时地址丢失或状态文件不完整时才重新接管。
    if [ -z "$current_ip" ]; then
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

    # SNAT本身使用幂等check；只有规则缺失时才实际补回。
    if [ -x /usr/bin/lan_snat.sh ]; then
        if ! /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
            if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
                log "SNAT启用失败：$source_net/24 → $target_net/24"
                return 1
            fi
        fi
    else
        log "SNAT程序不存在：$target_net/24"
        return 1
    fi

    scan_seq="$3"
    write_target_state "$target_net" "$current_ip" 0 "$scan_seq"
    runtime_set lan_discovery_status_state "统一SNAT模式：Q7 DHCP保持现有配置"
    log "目标网段状态保持：$source_net/24 → $target_net/24，临时地址=$current_ip，本轮发现"
    return 0
}

# 只在“新的完整扫描轮次”到来时更新miss_count。
# 管理器自身2秒轮询不会改变miss_count，因此扫描周期改成10/20/30/60秒均不影响逻辑。
process_completed_cycle() {
    localnet="$1"
    marker="$2"
    miss_limit="$(miss_limit_current)"

    collect_cycle_targets "$localnet"
    scan_seq="$(date +%s 2>/dev/null)-$(wc -l < "$CURRENT_ACTIVE_FILE" 2>/dev/null | tr -d ' ')"

    runtime_set lan_discovery_status_state "处理完整扫描轮次：目标网段状态增量更新"
    log "检测到新的完整扫描轮次，开始增量更新目标网段状态"

    # 1. 本轮发现的目标：miss_count清零，保持原IP和SNAT。
    while IFS= read -r target_net; do
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        apply_target "$target_net" "$localnet" "$scan_seq" || log "本轮目标处理失败，下轮继续尝试：$target_net/24"
    done < "$CURRENT_ACTIVE_FILE"

    # 2. 旧目标本轮没有出现：miss_count只加1；连续3轮才删除。
    for state_file in "$RUNTIME_DIR"/lan_target_state_*.state; do
        [ -r "$state_file" ] || continue
        target_net="$(state_get "$state_file" target_net)"
        [ -n "$target_net" ] || continue

        if grep -qx "$target_net" "$CURRENT_ACTIVE_FILE" 2>/dev/null; then
            continue
        fi

        miss_count="$(state_get "$state_file" miss_count)"
        case "$miss_count" in ''|*[!0-9]*) miss_count=0;; esac
        miss_count=$((miss_count + 1))

        current_ip="$(state_get "$state_file" target_ip)"
        if [ "$miss_count" -ge "$miss_limit" ]; then
            log "目标网段连续${miss_count}轮完整扫描未发现，确认清理：$target_net/24${current_ip:+，临时地址=$current_ip}"
            cleanup_one "$target_net"
        else
            old_seq="$(state_get "$state_file" last_scan_seq)"
            write_target_state "$target_net" "$current_ip" "$miss_count" "$old_seq"
            log "目标网段本轮未发现，保留：$target_net/24，连续丢失=${miss_count}/${miss_limit}轮"
        fi
    done

    save_cycle_cursor "$marker"
    update_runtime_targets
    rm -f "$CURRENT_ACTIVE_FILE"
    log "本轮目标网段状态更新完成：连续${miss_limit}个完整扫描轮次未发现才清理"
}

check_existing_targets() {
    localnet="$1"
    for takeover_file in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$takeover_file" ] || continue
        target_net="$(state_get "$takeover_file" network)"
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        current_ip="$(state_get "$takeover_file" ip)"
        snat_file="$(snat_state_file "$target_net")"
        source_net="$(state_get "$snat_file" lan_net)"
        [ -n "$current_ip" ] || continue
        [ -n "$source_net" ] || source_net="$localnet"
        [ -x /usr/bin/lan_snat.sh ] || continue
        /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >/dev/null 2>&1 || :
    done
}

process_targets() {
    localnet="$1"

    latest_marker="$(latest_completed_cycle)"
    if [ -n "$latest_marker" ] && ! cycle_seen_before "$latest_marker"; then
        process_completed_cycle "$localnet" "$latest_marker"
    fi

    check_existing_targets "$localnet"
    update_runtime_targets
}

while :; do
    if ! link_up; then
        if ls "$RUNTIME_DIR"/lan_takeover_*.state >/dev/null 2>&1; then
            log "LAN网线已拔出，立即撤销全部临时地址和SNAT"
            cleanup_network
        fi
        sleep 1
        continue
    fi

    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }

    process_targets "$localnet"
    sleep 2
done
