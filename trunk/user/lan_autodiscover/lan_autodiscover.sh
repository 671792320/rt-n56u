#!/bin/sh
# LAN discovery event watcher with WebUI status/log/device feed.

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }
trim_lines() { printf '%s\n' "$1" | tail -n 40; }
log_line() {
    line="$(now) $*"
    old="$(nv lan_discovery_log)"
    nvram set lan_discovery_log="$(trim_lines "${old}${old:+\n}${line}")"
    nvram set lan_discovery_status_last="$(now)"
    logger -t lan-autodiscover "$*"
}
set_link_status() {
    iface="$1"
    link="$2"
    ip="$(ip -4 addr show dev "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
    role="LAN"
    case "$iface" in wan*|ppp*|wwan*) role="WAN";; esac
    nvram set lan_discovery_status_if="$iface"
    nvram set lan_discovery_status_role="$role"
    nvram set lan_discovery_status_ip="${ip:--}"
    nvram set lan_discovery_status_mac="${mac:--}"
    nvram set lan_discovery_status_link="$link"
}
add_device() {
    line="$1"
    old="$(nv lan_discovery_devices)"
    if printf '%s\n' "$line" | grep -q '^DEVICE '; then
        nvram set lan_discovery_devices="$(printf '%s\n' "${old}${old:+\n}${line}" | tail -n 40)"
        count="$(printf '%s\n' "$(nv lan_discovery_devices)" | grep -c '^DEVICE ' 2>/dev/null)"
        nvram set lan_discovery_status_count="${count:-0}"
    fi
}
run_discovery() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    discover_timeout="$(cfg lan_discovery_timeout 10)"
    onvif="$(cfg lan_discovery_onvif 1)"; ssdp="$(cfg lan_discovery_ssdp 1)"
    hik="$(cfg lan_discovery_hik 1)"; dahua="$(cfg lan_discovery_dahua 1)"; raw="$(cfg lan_discovery_raw 1)"
    onvif_port="$(cfg lan_discovery_onvif_port 3702)"; ssdp_port="$(cfg lan_discovery_ssdp_port 1900)"
    hik_port="$(cfg lan_discovery_hik_port 37020)"; dahua_port="$(cfg lan_discovery_dahua_port 37810)"

    nvram set lan_discovery_status_state="DHCP检测"
    log_line "LAN Link UP $iface"
    : > /tmp/dhcpdetect_lan.log
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            dhcp="$(sed -n '1p' /tmp/dhcpdetect_lan.log 2>/dev/null)"
            nvram set lan_discovery_status_dhcp="$dhcp"
            log_line "$dhcp"
        else
            nvram set lan_discovery_status_dhcp="无 DHCP 回复"
            log_line "DHCP no reply"
        fi
    else
        nvram set lan_discovery_status_dhcp="未启用"
    fi

    if [ "$discover_enable" = "1" ] && [ -x /usr/bin/camdiscover ]; then
        nvram set lan_discovery_status_state="设备发现"
        nvram set lan_discovery_devices=""
        nvram set lan_discovery_status_count="0"
        log_line "开始设备发现 $iface"
        : > /tmp/camdiscover_lan.log
        /usr/bin/camdiscover -i "$iface" -t "$discover_timeout" \
            -o "$onvif_port" -s "$ssdp_port" -k "$hik_port" -d "$dahua_port" \
            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" \
            > /tmp/camdiscover_lan.log 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            if [ -f /tmp/camdiscover_lan.log ]; then
                sed -n '1,120p' /tmp/camdiscover_lan.log | tail -n 20 > /tmp/camdiscover_lan_tail
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    case "$line" in
                        DEVICE\ *) add_device "$line";;
                    esac
                    case "$line" in
                        DEVICE\ *|*probe*|*RX*|*FAILED*) log_line "$line";;
                    esac
                done < /tmp/camdiscover_lan_tail
            fi
            sleep 1
        done
        wait "$pid"
        log_line "设备发现完成"
        nvram set lan_discovery_status_state="空闲"
    else
        nvram set lan_discovery_status_state="设备发现未启用"
    fi
}

last_state=-1
while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$enable" != "1" ]; then
        nvram set lan_discovery_status_state="已禁用"
        last_state=0
        sleep 2
        continue
    fi
    if [ ! -e "/sys/class/net/$iface" ]; then
        set_link_status "$iface" "不存在"
        if [ "$last_state" != "-2" ]; then log_line "接口 $iface 不存在"; last_state=-2; fi
        sleep 2
        continue
    fi
    if [ -r "/sys/class/net/$iface/carrier" ]; then state="$(sed -n '1p' "/sys/class/net/$iface/carrier" 2>/dev/null)"; else state="$(sed -n '1p' "/sys/class/net/$iface/operstate" 2>/dev/null)"; [ "$state" = "up" ] && state=1 || state=0; fi
    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then set_link_status "$iface" "UP"; sleep 1; run_discovery "$iface" & else set_link_status "$iface" "DOWN"; nvram set lan_discovery_status_state="空闲"; log_line "LAN Link DOWN $iface"; fi
    fi
    sleep 1
done
