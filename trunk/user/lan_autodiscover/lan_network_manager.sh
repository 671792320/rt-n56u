#!/bin/sh
# Q7 LAN网络模式管理器。
# 只负责：读取DHCP检测结果、确定目标网段、建立临时目标LAN地址，
# 以及在无DHCP模式下启用定向SNAT。DHCP开关本身保持由现有已验证逻辑负责。

IFACE=eth2.1
BR_IF=br0
RUNTIME_DIR=/tmp/lan_discovery_runtime
DEVICE_DB=/tmp/lan_discovery_devices.txt
DHCP_LOG=/tmp/dhcpdetect_lan.log
STATE_FILE="$RUNTIME_DIR/lan_network_manager.state"
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
    ip -4 addr show dev "$BR_IF" 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' | head -n 1
}

network_from_ip() {
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'
}

dhcp_found() {
    [ -f "$DHCP_LOG" ] || return 1
    grep -q '^\[dhcpdetect\] DHCP server found' "$DHCP_LOG" 2>/dev/null
}

dhcp_finished() {
    [ -f "$DHCP_LOG" ] || return 1
    grep -qE '^\[dhcpdetect\] DHCP server found|no DHCP server reply' "$DHCP_LOG" 2>/dev/null
}

target_from_dhcp() {
    grep -m1 '^\[dhcpdetect\] DHCP server found' "$DHCP_LOG" 2>/dev/null |
        sed -n 's/.* gateway=\([0-9.]*\).*/\1/p' |
        while IFS= read -r g; do network_from_ip "$g"; done
}

target_from_db() {
    local_net="$1"
    awk -v local_net="$local_net" '
        /^DEVICE type=SUBNET / {
            ip=""
            for(i=1;i<=NF;i++) if($i ~ /^IP=/) {ip=substr($i,4); break}
            if(ip != "" && ip != local_net) {print ip; exit}
        }
    ' "$DEVICE_DB" 2>/dev/null
}

cleanup_network() {
    [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :
    [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r >/dev/null 2>&1 || :
    rm -f "$STATE_FILE"
    runtime_set lan_discovery_status_target_network ""
    runtime_set lan_discovery_status_target_ip ""
    runtime_set lan_discovery_status_target_iface ""
}

apply_target() {
    target_net="$1"
    [ -n "$target_net" ] || return 1
    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || return 1
    [ "$target_net" != "$localnet" ] || return 1

    current_target="$(cat "$RUNTIME_DIR/lan_discovery_status_target_network" 2>/dev/null)"
    current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"
    address_ready=0
    if [ "$current_target" = "$target_net/24" ] && [ -n "$current_ip" ] && ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $current_ip/24"; then
        address_ready=1
        log "目标临时地址已存在：$current_ip/24，继续应用网络模式"
    fi

    if [ "$address_ready" != "1" ]; then
        runtime_set lan_discovery_status_state "LAN目标网段接管"
        if ! /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1; then
            log "目标网段接管失败：$target_net/24"
            return 1
        fi
        current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"
        [ -n "$current_ip" ] || return 1
    fi

    mode="NO_DHCP"
    if dhcp_found; then mode="DHCP"; fi

    if [ "$mode" = "NO_DHCP" ]; then
        runtime_set lan_discovery_status_state "无DHCP：设备发现/SNAT模式"
        if [ -x /usr/bin/lan_snat.sh ]; then
            /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$localnet" >> "$LOG_FILE" 2>&1 || {
                log "SNAT启用失败：$localnet/24 -> $target_net/24"
                return 1
            }
        else
            log "SNAT程序不存在：无法启用无DHCP访问转发"
            return 1
        fi
    else
        runtime_set lan_discovery_status_state "有DHCP：目标LAN协议发现"
        [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :
    fi

    {
        printf 'mode=%s\n' "$mode"
        printf 'local_net=%s\n' "$localnet"
        printf 'target_net=%s\n' "$target_net"
        printf 'target_ip=%s\n' "$current_ip"
    } > "$STATE_FILE"
    log "网络模式=$mode，目标网段=$target_net/24，临时地址=$current_ip"
    return 0
}

# 只检查/补回SNAT，不重新接管IP，不改变临时源地址。
# 这样即使Padavan其他组件重建iptables，也能在下一轮自动恢复。
check_snat() {
    target_net="$1"
    localnet="$2"
    current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"
    [ -n "$target_net" ] && [ -n "$localnet" ] && [ -n "$current_ip" ] || return 1
    [ -x /usr/bin/lan_snat.sh ] || return 1
    /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$localnet" >> "$LOG_FILE" 2>&1
}

last_mode=""
last_target=""
while :; do
    if ! link_up; then
        if [ -f "$STATE_FILE" ]; then
            log "LAN拔出，撤销临时地址和SNAT"
            cleanup_network
        fi
        last_mode=""
        last_target=""
        sleep 1
        continue
    fi

    # 等待现有DHCP检测产生结果；不修改检测程序本身。
    loops=0
    while [ ! -f "$DHCP_LOG" ] || ! dhcp_finished; do
        link_up || break
        loops=$((loops + 1))
        [ "$loops" -ge 12 ] && break
        sleep 1
    done

    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    target="$(target_from_dhcp)"
    [ -n "$target" ] || target="$(target_from_db "$localnet")"

    if [ -n "$target" ] && [ "$target" != "$localnet" ]; then
        mode="NO_DHCP"
        dhcp_found && mode="DHCP"
        if [ "$mode:$target" != "$last_mode:$last_target" ] || [ ! -f "$STATE_FILE" ]; then
            apply_target "$target"
            last_mode="$mode"
            last_target="$target"
        elif [ "$mode" = "NO_DHCP" ]; then
            # 运行过程中其他Padavan组件可能刷新iptables；这里只补规则，
            # 不调用takeover、不更换临时IP，也不删除现有SNAT规则。
            check_snat "$target" "$localnet" || log "SNAT周期检查发现规则缺失或补回失败"
        fi
    fi

    sleep 2
done
