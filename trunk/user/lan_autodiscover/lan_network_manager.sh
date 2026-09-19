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

mkdir -p "$RUNTIME_DIR"

runtime_set() {
    key="$1"
    value="$2"
    tmp="$RUNTIME_DIR/.manager_$key.tmp"
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
    # Q7本机LAN地址由NVRAM维护，正常运行时无需每秒执行ip/grep/sed管道。
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
    tmp="${state_file}.manager.tmp"
    {
        printf 'target_net=%s\n' "$target_net"
        printf 'target_ip=%s\n' "$target_ip"
        printf 'miss_count=%s\n' "$miss_count"
        printf 'last_scan_seq=%s\n' "$scan_seq"
        printf 'last_seen=%s\n' "$(date +%s 2>/dev/null)"
    } > "$tmp" && mv -f "$tmp" "$state_file"
}

update_runtime_targets() {
    tmp="$RUNTIME_DIR/.manager_targets.tmp"
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

consume_stream_targets() {
    file="$1"
    cursor_file="$2"
    localnet="$3"
    output="$4"

    [ -r "$file" ] || return 0
    count="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
    case "$count" in ''|*[!0-9]*) count=0;; esac
    cursor="$(cat "$cursor_file" 2>/dev/null)"
    case "$cursor" in ''|*[!0-9]*) cursor=0;; esac
    [ "$count" -ge "$cursor" ] || cursor=0
    [ "$count" -gt "$cursor" ] || return 0

    # 只有出现新增事件时才通知上层进行排序和SNAT判断。
    realtime_new=1
    start=$((cursor + 1))
    sed -n "${start},${count}p" "$file" 2>/dev/null |
    awk -F'|' -v localnet="$localnet" '
        function valid_octet(v) { return v ~ /^[0-9]+$/ && v >= 0 && v <= 255 }
        {
            ip=$1
            n=split(ip,p,".")
            if(n != 4 || !valid_octet(p[1]) || !valid_octet(p[2]) ||
               !valid_octet(p[3]) || !valid_octet(p[4]))
                next
            net=p[1]"."p[2]"."p[3]".0"
            if(net != localnet && net != "0.0.0.0")
                print net
        }
    ' >> "$output"
    printf '%s\\n' "$count" > "$cursor_file"
}

process_realtime_events() {
    localnet="$1"
    targets_tmp="$RUNTIME_DIR/.manager_realtime_targets.tmp"
    : > "$targets_tmp"
    realtime_new=0

    # 三类实时事件只做“目标网段”去重，不再为每个数据包启动一次lan_device_state.sh。
    # 设备详细状态由主动ARP/协议扫描统一维护；实时监听只负责快速发现新网段。
    consume_stream_targets "$RUNTIME_DIR/arp_seen.txt" "$ARP_CURSOR_FILE" "$localnet" "$targets_tmp"
    consume_stream_targets "$RUNTIME_DIR/device_protocol_events.txt" "$PROTO_CURSOR_FILE" "$localnet" "$targets_tmp"
    consume_stream_targets "$RUNTIME_DIR/tcpdump_discovery_events.txt" "$TCPDUMP_CURSOR_FILE" "$localnet" "$targets_tmp"

    # 没有任何新增事件时，不执行sort，也不进入SNAT判断。
    if [ "$realtime_new" != "1" ] || [ ! -s "$targets_tmp" ]; then
        rm -f "$targets_tmp"
        return 0
    fi

    sort -u "$targets_tmp" -o "$targets_tmp" 2>/dev/null
    while IFS= read -r target_net; do
        [ -n "$target_net" ] || continue
        # apply_target内部有目标状态锁；同一网段只允许第一次建立SNAT。
        apply_target "$target_net" "$localnet" "realtime" || :
    done < "$targets_tmp"
    rm -f "$targets_tmp"
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

last_event_check=0

while :; do
    if ! link_up; then
        # LAN拔出只退出管理器，由supervisor重新启动；已有目标网段和SNAT保持不动。
        runtime_set lan_discovery_status_link "DOWN"
        runtime_set lan_discovery_status_state "LAN拔出：保留现有临时网段/SNAT"
        exit 0
    fi

    # 正常情况下直接读取Padavan保存的LAN地址，避免调用local_ip函数产生同名Shell子进程。
    localip="$(nvram get lan_ipaddr 2>/dev/null)"
    case "$localip" in
        *.*.*.*) ;;
        *) sleep 2; continue;;
    esac
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }

    # 实时事件只处理新增记录；无新增数据时不排序、不做SNAT判断。
    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    if [ "$last_event_check" = "0" ] || [ $((now_ts - last_event_check)) -ge 1 ] 2>/dev/null; then
        process_realtime_events "$localnet"
        last_event_check="$now_ts"
    fi

    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    if [ "$last_maintenance" = "0" ] || [ $((now_ts - last_maintenance)) -ge 60 ] 2>/dev/null; then
        # 仅检查已有SNAT规则是否仍存在，不重新选择临时IP，也不因扫描缺失删除目标。
        check_existing_targets "$localnet"
        last_maintenance="$now_ts"
    fi

    # supervisor负责1秒级插拔检测；网络管理器空闲时降低到2秒轮询，避免CPU空转。
    sleep 2
done
