#!/bin/sh
# Q7 LAN网络模式管理器。
# 手机始终使用Q7自己的LAN网段；目标LAN允许同时存在多个/24网段。
# 每个目标网段独立维护临时IP、SNAT和状态，不再因为切换一个网段而删除其他网段。

IFACE=eth2.1
BR_IF=br0
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
DHCP_LOG=/tmp/dhcpdetect_lan.log
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
TARGETS_FILE="$RUNTIME_DIR/lan_discovery_targets.state"
LOG_FILE=/tmp/lan_discovery.log

mkdir -p "$RUNTIME_DIR"

log() {
    msg="$(date '+%H:%M:%S') [network] $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t lan-autodiscover "$msg"
    runtime_set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

runtime_set() {
    key="$1"
    value="$2"
    tmp="$RUNTIME_DIR/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"
}

link_up() {
    [ -x /sbin/mtk_esw ] || return 0
    state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
    [ "$state" = "1" ]
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
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'
}

dhcp_finished() {
    [ -f "$DHCP_LOG" ] || return 1
    grep -qE '^\[dhcpdetect\] DHCP server found|no DHCP server reply' "$DHCP_LOG" 2>/dev/null
}

target_from_dhcp() {
    grep '^\[dhcpdetect\] DHCP server found' "$DHCP_LOG" 2>/dev/null |
        sed -n 's/.* gateway=\([0-9.]*\).*/\1/p' |
        while IFS= read -r g; do network_from_ip "$g"; done | sort -u
}

target_from_db() {
    local_net="$1"
    awk -v local_net="$local_net" '
        /^DEVICE type=SUBNET / {
            ip=""
            for(i=1;i<=NF;i++) if($i ~ /^IP=/) {ip=substr($i,4); break}
            if(ip != "" && ip != local_net) print ip
        }
    ' "$DEVICE_DB" 2>/dev/null | sort -u
}

is_dhcp_target() {
    wanted="$1"
    target_from_dhcp | grep -qx "$wanted"
}

clear_target_status() {
    runtime_set lan_discovery_status_target_network ""
    runtime_set lan_discovery_status_target_ip ""
    runtime_set lan_discovery_status_target_iface ""
}

cleanup_network() {
    [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :
    [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r >/dev/null 2>&1 || :
    rm -f "$STATE_FILE" "$TARGETS_FILE"
    clear_target_status
}

update_runtime_targets() {
    tmp="$RUNTIME_DIR/.lan_discovery_targets.tmp"
    : > "$tmp"
    for f in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$f" ] || continue
        net="$(sed -n 's/^network=//p' "$f" | head -n 1)"
        ipaddr="$(sed -n 's/^ip=//p' "$f" | head -n 1)"
        [ -n "$net" ] && [ -n "$ipaddr" ] && printf '%s|%s\n' "$net/24" "$ipaddr" >> "$tmp"
    done
    sort -u "$tmp" > "$TARGETS_FILE"
    rm -f "$tmp"

    first="$(head -n 1 "$TARGETS_FILE" 2>/dev/null)"
    if [ -n "$first" ]; then
        first_net="${first%%|*}"
        first_ip="${first#*|}"
        runtime_set lan_discovery_status_target_network "$first_net"
        runtime_set lan_discovery_status_target_ip "$first_ip"
        runtime_set lan_discovery_status_target_iface "$BR_IF"
    else
        clear_target_status
    fi
}

target_is_active() {
    grep -q "^$1/24|" "$TARGETS_FILE" 2>/dev/null
}

state_ip_for() {
    target_net="$1"
    takeover_file="$RUNTIME_DIR/lan_takeover_$(printf '%s' "$target_net" | tr '.' '_').state"
    sed -n 's/^ip=//p' "$takeover_file" 2>/dev/null | head -n 1
}

apply_target() {
    target_net="$1"
    mode="$2"
    [ -n "$target_net" ] || return 1
    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || return 1
    [ "$target_net" != "$localnet" ] || return 0

    runtime_set lan_discovery_status_state "目标网段管理：$mode"

    if ! /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1; then
        log "目标网段接管失败：$target_net/24"
        return 1
    fi

    current_ip="$(state_ip_for "$target_net")"
    [ -n "$current_ip" ] || {
        log "无法取得目标网段临时地址：$target_net/24"
        return 1
    }

    # 无论目标是否存在DHCP，都使用目标网段独立SNAT保证回包稳定。
    if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$localnet" >> "$LOG_FILE" 2>&1; then
        log "SNAT启用失败：$localnet/24 -> $target_net/24"
        return 1
    fi

    update_runtime_targets
    {
        printf 'last_mode=%s\n' "$mode"
        printf 'local_net=%s\n' "$localnet"
        printf 'last_target_net=%s\n' "$target_net"
        printf 'last_target_ip=%s\n' "$current_ip"
    } > "$STATE_FILE"
    log "目标网段=$target_net/24，模式=$mode，临时地址=$current_ip"
    return 0
}

remove_stale_targets() {
    for f in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$f" ] || continue
        net="$(sed -n 's/^network=//p' "$f" | head -n 1)"
        [ -n "$net" ] || continue
        if ! target_is_active "$net"; then
            log "目标网段已不再发现，清理：$net/24"
            [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down "$net" >> "$LOG_FILE" 2>&1 || :
            [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r "$net" >> "$LOG_FILE" 2>&1 || :
        fi
    done
    update_runtime_targets
}

check_snat() {
    target_net="$1"
    localnet="$2"
    current_ip="$(state_ip_for "$target_net")"
    [ -n "$target_net" ] && [ -n "$localnet" ] && [ -n "$current_ip" ] || return 1
    [ -x /usr/bin/lan_snat.sh ] || return 1
    /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$localnet" >> "$LOG_FILE" 2>&1
}

process_targets() {
    localnet="$1"
    candidates="$RUNTIME_DIR/.lan_target_candidates.tmp"
    : > "$candidates"
    target_from_dhcp >> "$candidates"
    target_from_db "$localnet" >> "$candidates"
    grep -v "^$localnet$" "$candidates" 2>/dev/null | sort -u > "$candidates.sorted"
    mv -f "$candidates.sorted" "$candidates"

    : > "$TARGETS_FILE"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        mode="NO_DHCP"
        is_dhcp_target "$target" && mode="DHCP"
        apply_target "$target" "$mode" || log "本轮未成功处理目标，下一轮继续：$target/24"
    done < "$candidates"
    rm -f "$candidates"
    remove_stale_targets

    # 对所有已成功管理的目标补一次SNAT，不能只检查最后一个目标。
    while IFS='|' read -r target_with_mask target_ip; do
        [ -n "$target_with_mask" ] || continue
        target_net="${target_with_mask%/24}"
        check_snat "$target_net" "$localnet" || log "SNAT周期检查失败：$target_net/24"
    done < "$TARGETS_FILE"
}

while :; do
    if ! link_up; then
        if [ -f "$STATE_FILE" ] || ls "$RUNTIME_DIR"/lan_takeover_*.state >/dev/null 2>&1; then
            log "LAN拔出，撤销全部临时地址和SNAT"
            cleanup_network
        fi
        sleep 1
        continue
    fi

    loops=0
    while [ ! -f "$DHCP_LOG" ] || ! dhcp_finished; do
        link_up || break
        loops=$((loops + 1))
        [ "$loops" -ge 12 ] && break
        sleep 1
    done

    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || { sleep 2; continue; }

    process_targets "$localnet"
    sleep 2
done
