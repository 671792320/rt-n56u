#!/bin/sh
# Q7 LAN网络管理器。
# 手机始终使用Q7自己的LAN网段；所有发现到的目标网段统一通过临时IP+SNAT访问。
# 不再检测目标网段是否存在DHCP，也不再根据DHCP改变Q7自身DHCP或访问模式。
#
# 关键修复：目标网段状态采用增量缓存，不因一次ARP扫描空窗就立即删除临时IP/SNAT。
# 目标网段连续超过30秒没有再次被发现才清理；正常10秒一轮扫描时相当于允许约3轮丢失。

IFACE=eth2.1
BR_IF=br0
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
TARGETS_FILE="$RUNTIME_DIR/lan_discovery_targets.state"
LOG_FILE=/tmp/lan_discovery.log
STALE_GRACE=35

mkdir -p "$RUNTIME_DIR"

log() {
    msg="$(date '+%H:%M:%S') 【网络管理】$*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t lan-autodiscover "$msg"
    runtime_set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

runtime_set() { key="$1"; value="$2"; tmp="$RUNTIME_DIR/.${key}.tmp"; printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"; }
link_up() { [ -x /sbin/mtk_esw ] || return 0; state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"; [ "$state" = "1" ]; }
local_ip() { ip_from_nvram="$(nvram get lan_ipaddr 2>/dev/null)"; case "$ip_from_nvram" in *.*.*.*) printf '%s\n' "$ip_from_nvram"; return 0;; esac; ip -4 addr show dev "$BR_IF" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' | head -n 1; }
network_from_ip() { printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0\n",$1,$2,$3}'; }
target_from_db() { local_net="$1"; awk -v local_net="$local_net" '/^DEVICE type=SUBNET / {ip=""; for(i=1;i<=NF;i++) if($i ~ /^IP=/) {ip=substr($i,4); break} if(ip != "" && ip != "0.0.0.0" && ip != local_net) print ip}' "$DEVICE_DB" 2>/dev/null | while IFS= read -r ipaddr; do network_from_ip "$ipaddr"; done | sort -u; }
clear_target_status() { runtime_set lan_discovery_status_target_network ""; runtime_set lan_discovery_status_target_ip ""; runtime_set lan_discovery_status_target_iface ""; nvram set lan_discovery_status_targets "" 2>/dev/null || :; }
cleanup_network() { [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :; [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r >/dev/null 2>&1 || :; rm -f "$STATE_FILE" "$TARGETS_FILE" "$RUNTIME_DIR"/lan_target_state_*.state; clear_target_status; }
update_runtime_targets() { tmp="$RUNTIME_DIR/.lan_discovery_targets.tmp"; : > "$tmp"; for f in "$RUNTIME_DIR"/lan_takeover_*.state; do [ -r "$f" ] || continue; net="$(sed -n 's/^network=//p' "$f" | head -n 1)"; ipaddr="$(sed -n 's/^ip=//p' "$f" | head -n 1)"; [ -n "$net" ] && [ "$net" != "0.0.0.0" ] && [ -n "$ipaddr" ] && printf '%s|%s\n' "$net/24" "$ipaddr" >> "$tmp"; done; sort -u "$tmp" > "$TARGETS_FILE"; rm -f "$tmp"; targets_text="$(awk 'BEGIN{ORS=""} {if(NR>1) printf ";"; printf "%s",$0}' "$TARGETS_FILE" 2>/dev/null)"; nvram set lan_discovery_status_targets "$targets_text" 2>/dev/null || :; first="$(head -n 1 "$TARGETS_FILE" 2>/dev/null)"; if [ -n "$first" ]; then first_net="${first%%|*}"; first_ip="${first#*|}"; runtime_set lan_discovery_status_target_network "$first_net"; runtime_set lan_discovery_status_target_ip "$first_ip"; runtime_set lan_discovery_status_target_iface "$BR_IF"; else clear_target_status; fi; }

# 每个目标网段独立保存最近发现时间。文件是运行时缓存，不写入NVRAM。
target_state_file() { printf '%s/lan_target_state_%s.state\n' "$RUNTIME_DIR" "$(printf '%s' "$1" | tr '.' '_')"; }
mark_target_seen() {
    target_net="$1"
    state_file="$(target_state_file "$target_net")"
    now_epoch="$(date +%s 2>/dev/null)"
    case "$now_epoch" in ''|*[!0-9]*) now_epoch=0;; esac
    old_ip="$(sed -n 's/^target_ip=//p' "$state_file" 2>/dev/null | head -n 1)"
    {
        printf 'target_net=%s\n' "$target_net"
        printf 'target_ip=%s\n' "$old_ip"
        printf 'last_seen=%s\n' "$now_epoch"
    } > "${state_file}.tmp" && mv -f "${state_file}.tmp" "$state_file"
}

target_is_active() { active_file="$1"; target_net="$2"; [ -r "$active_file" ] && grep -qx "$target_net" "$active_file" 2>/dev/null; }
state_ip_for() { target_net="$1"; takeover_file="$RUNTIME_DIR/lan_takeover_$(printf '%s' "$target_net" | tr '.' '_').state"; sed -n 's/^ip=//p' "$takeover_file" 2>/dev/null | head -n 1; }

apply_target() {
    target_net="$1"
    mode="$2"
    source_net="$3"
    [ -n "$target_net" ] || return 1
    [ "$target_net" != "0.0.0.0" ] || { log "忽略无效目标网段：0.0.0.0/24"; return 1; }
    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || return 1
    [ "$target_net" != "$localnet" ] || return 0
    [ -n "$source_net" ] || source_net="$localnet"
    [ "$target_net" != "$source_net" ] || return 0
    runtime_set lan_discovery_status_state "目标网段管理：$mode"
    if ! /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1; then
        log "目标网段接管失败：$target_net/24"
        return 1
    fi
    current_ip="$(state_ip_for "$target_net")"
    [ -n "$current_ip" ] || { log "无法取得目标网段临时地址：$target_net/24"; return 1; }
    if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
        log "SNAT启用失败：$source_net/24 → $target_net/24"
        return 1
    fi
    # 发现成功后只更新缓存，不重新创建临时IP；lan_takeover/lan_snat自身保持幂等。
    mark_target_seen "$target_net"
    state_file="$(target_state_file "$target_net")"
    tmp_state="${state_file}.tmp"
    {
        printf 'target_net=%s\n' "$target_net"
        printf 'target_ip=%s\n' "$current_ip"
        printf 'last_seen=%s\n' "$(date +%s 2>/dev/null)"
    } > "$tmp_state" && mv -f "$tmp_state" "$state_file"
    update_runtime_targets
    {
        printf 'last_mode=%s\n' "$mode"
        printf 'local_net=%s\n' "$localnet"
        printf 'source_net=%s\n' "$source_net"
        printf 'last_target_net=%s\n' "$target_net"
        printf 'last_target_ip=%s\n' "$current_ip"
    } > "$STATE_FILE"
    log "目标网段=$target_net/24，统一SNAT，源网段=$source_net/24，临时地址=$current_ip"
    return 0
}

# 旧版本这里会在一次扫描空窗期立即删除目标网段。
# 现在只根据最近一次成功发现时间判断，避免ARP扫描过程中SNAT反复删除/重建。
remove_stale_targets() {
    now_epoch="$(date +%s 2>/dev/null)"
    case "$now_epoch" in ''|*[!0-9]*) return 0;; esac
    for f in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$f" ] || continue
        net="$(sed -n 's/^network=//p' "$f" | head -n 1)"
        [ -n "$net" ] || continue
        state_file="$(target_state_file "$net")"
        last_seen="$(sed -n 's/^last_seen=//p' "$state_file" 2>/dev/null | head -n 1)"
        case "$last_seen" in ''|*[!0-9]*)
            # 兼容旧版本运行时状态：已有接管状态但没有缓存时间时，先建立保护窗口，不立即删除。
            printf 'target_net=%s\nlast_seen=%s\n' "$net" "$now_epoch" > "${state_file}.tmp" && mv -f "${state_file}.tmp" "$state_file"
            log "目标网段建立状态缓存，暂不清理：$net/24"
            continue
            ;;
        esac
        age=$((now_epoch - last_seen))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -ge "$STALE_GRACE" ]; then
            log "目标网段连续${age}秒未重新发现，确认清理：$net/24"
            [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down "$net" >> "$LOG_FILE" 2>&1 || :
            [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r "$net" >> "$LOG_FILE" 2>&1 || :
            rm -f "$state_file"
        else
            log "目标网段暂未在本轮发现，保留SNAT：$net/24，距超时${age}/${STALE_GRACE}秒"
        fi
    done
    update_runtime_targets
}

check_snat() {
    target_net="$1"
    takeover_file="$RUNTIME_DIR/lan_takeover_$(printf '%s' "$target_net" | tr '.' '_').state"
    snat_file="$RUNTIME_DIR/lan_snat_$(printf '%s' "$target_net" | tr '.' '_').state"
    current_ip="$(sed -n 's/^ip=//p' "$takeover_file" 2>/dev/null | head -n 1)"
    source_net="$(sed -n 's/^lan_net=//p' "$snat_file" 2>/dev/null | head -n 1)"
    [ -n "$target_net" ] && [ "$target_net" != "0.0.0.0" ] && [ -n "$current_ip" ] && [ -n "$source_net" ] || return 1
    [ -x /usr/bin/lan_snat.sh ] || return 1
    /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1
}

process_targets() {
    localnet="$1"
    candidates="$RUNTIME_DIR/.lan_target_candidates.tmp"
    active="$RUNTIME_DIR/.lan_target_active.tmp"
    : > "$candidates"

    # 统一模式：只根据设备发现结果得到目标网段。
    # 无论目标网段有没有DHCP，均不改变Q7 DHCP，均使用临时IP+SNAT访问。
    target_from_db "$localnet" >> "$candidates"
    grep -vE "^$localnet$|^0\.0\.0\.0$" "$candidates" 2>/dev/null | sort -u > "$candidates.sorted"
    mv -f "$candidates.sorted" "$candidates"

    runtime_set lan_discovery_status_state "统一SNAT模式：Q7 DHCP保持现有配置"

    : > "$active"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ "$target" != "0.0.0.0" ] || continue
        printf '%s\n' "$target" >> "$active"
        # 所有目标网段统一：Q7源网段 → 目标网段临时IP。
        apply_target "$target" "统一SNAT访问" "$localnet" || log "本轮未成功处理目标，下一轮继续：$target/24"
    done < "$candidates"

    remove_stale_targets
    update_runtime_targets
    while IFS='|' read -r target_with_mask target_ip; do
        [ -n "$target_with_mask" ] || continue
        target_net="${target_with_mask%/24}"
        [ "$target_net" != "0.0.0.0" ] || continue
        check_snat "$target_net" || log "SNAT周期检查失败：$target_net/24"
    done < "$TARGETS_FILE"
    rm -f "$candidates" "$active" "$candidates.sorted"
}

while :; do
    if ! link_up; then
        if [ -f "$STATE_FILE" ] || ls "$RUNTIME_DIR"/lan_takeover_*.state >/dev/null 2>&1; then log "LAN网线已拔出，正在撤销全部临时地址和SNAT"; cleanup_network; fi
        sleep 1; continue
    fi
    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }
    process_targets "$localnet"
    sleep 2
done
