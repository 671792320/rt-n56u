#!/bin/sh
# LAN discovery event watcher with WebUI status/log/device feed.

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }

ensure_defaults() {
    [ -n "$(nv lan_discovery_enable)" ] || nvram set lan_discovery_enable=1
    [ -n "$(nv lan_discovery_ifname)" ] || nvram set lan_discovery_ifname=eth2.1
    [ -n "$(nv lan_discovery_dhcp_enable)" ] || nvram set lan_discovery_dhcp_enable=1
    [ -n "$(nv lan_discovery_dhcp_timeout)" ] || nvram set lan_discovery_dhcp_timeout=3
    [ -n "$(nv lan_discovery_discover_enable)" ] || nvram set lan_discovery_discover_enable=1
    [ -n "$(nv lan_discovery_timeout)" ] || nvram set lan_discovery_timeout=10
    [ -n "$(nv lan_discovery_onvif)" ] || nvram set lan_discovery_onvif=1
    [ -n "$(nv lan_discovery_onvif_port)" ] || nvram set lan_discovery_onvif_port=3702
    [ -n "$(nv lan_discovery_ssdp)" ] || nvram set lan_discovery_ssdp=1
    [ -n "$(nv lan_discovery_ssdp_port)" ] || nvram set lan_discovery_ssdp_port=1900
    [ -n "$(nv lan_discovery_hik)" ] || nvram set lan_discovery_hik=1
    [ -n "$(nv lan_discovery_hik_port)" ] || nvram set lan_discovery_hik_port=37020
    [ -n "$(nv lan_discovery_dahua)" ] || nvram set lan_discovery_dahua=1
    [ -n "$(nv lan_discovery_dahua_port)" ] || nvram set lan_discovery_dahua_port=37810
    [ -n "$(nv lan_discovery_raw)" ] || nvram set lan_discovery_raw=1
    [ -n "$(nv lan_discovery_status_dhcp)" ] || nvram set lan_discovery_status_dhcp="未检测"
    [ -n "$(nv lan_discovery_status_state)" ] || nvram set lan_discovery_status_state="空闲"
    [ -n "$(nv lan_discovery_status_count)" ] || nvram set lan_discovery_status_count=0
    [ -n "$(nv lan_discovery_status_last)" ] || nvram set lan_discovery_status_last="-"
}

log_line() {
    line="$(now) $*"
    old="$(nv lan_discovery_log)"
    if [ -n "$old" ]; then
        nvram set lan_discovery_log="$(printf '%s\n%s\n' "$old" "$line" | tail -n 40)"
    else
        nvram set lan_discovery_log="$line"
    fi
    nvram set lan_discovery_status_last="$(now)"
    logger -t lan-autodiscover "$*"
}

refresh_interfaces() {
    out=""
    for p in /sys/class/net/*; do
        [ -d "$p" ] || continue
        iface="${p##*/}"
        [ "$iface" = "lo" ] && continue
        role="LAN"
        if printf '%s\n' "$(nv lan_ifnames)" | tr ' ' '\n' | grep -qx "$iface"; then role="LAN"; fi
        if printf '%s\n' "$(nv wan_ifnames) $(nv wan_ifname) $(nv wan_ifname_x)" | tr ' ' '\n' | grep -qx "$iface"; then role="WAN"; fi
        case "$iface" in wan*|ppp*|wwan*) role="WAN";; esac
        ip="$(ip -4 addr show dev "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
        mac="$(cat "$p/address" 2>/dev/null)"
        if [ -r "$p/carrier" ]; then
            link="$(cat "$p/carrier" 2>/dev/null)"
            [ "$link" = "1" ] && link="UP" || link="DOWN"
        else
            link="$(cat "$p/operstate" 2>/dev/null)"
        fi
        line="${iface}|${role}|${ip:--}|${mac:--}|${link:--}"
        if [ -n "$out" ]; then out="$(printf '%s\n%s' "$out" "$line")"; else out="$line"; fi
    done
    nvram set lan_discovery_interfaces "$out"
}

set_link_status() {
    iface="$1"; link="$2"
    ip="$(ip -4 addr show dev "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null)"
    role="LAN"
    if printf '%s\n' "$(nv wan_ifnames) $(nv wan_ifname) $(nv wan_ifname_x)" | tr ' ' '\n' | grep -qx "$iface"; then role="WAN"; fi
    case "$iface" in wan*|ppp*|wwan*) role="WAN";; esac
    nvram set lan_discovery_status_if="$iface"
    nvram set lan_discovery_status_role="$role"
    nvram set lan_discovery_status_ip="${ip:--}"
    nvram set lan_discovery_status_mac="${mac:--}"
    nvram set lan_discovery_status_link="$link"
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
    custom="$(nv lan_discovery_custom)"

    nvram set lan_discovery_status_state="DHCP检测"
    log_line "LAN Link UP $iface"
    : > /tmp/dhcpdetect_lan.log
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            dhcp="$(sed -n '1p' /tmp/dhcpdetect_lan.log 2>/dev/null)"
            nvram set lan_discovery_status_dhcp="$dhcp"; log_line "$dhcp"
        else
            nvram set lan_discovery_status_dhcp="无 DHCP 回复"; log_line "DHCP no reply"
        fi
    else
        nvram set lan_discovery_status_dhcp="未启用"
    fi

    if [ "$discover_enable" = "1" ] && [ -x /usr/bin/camdiscover ]; then
        nvram set lan_discovery_status_state="设备发现"
        nvram set lan_discovery_devices=""; nvram set lan_discovery_status_count="0"
        log_line "开始设备发现 $iface"
        : > /tmp/camdiscover_lan.log
        : > /tmp/camdiscover_custom.conf
        printf '%s\n' "$custom" | while IFS= read -r row; do
            [ -n "$row" ] || continue
            printf '%s\n' "$row" >> /tmp/camdiscover_custom.conf
        done
        args="-i $iface -t $discover_timeout -o $onvif_port -s $ssdp_port -k $hik_port -d $dahua_port -O $onvif -S $ssdp -H $hik -D $dahua -A $raw"
        [ -s /tmp/camdiscover_custom.conf ] && args="$args -C /tmp/camdiscover_custom.conf"
        # shellcheck disable=SC2086
        /usr/bin/camdiscover $args > /tmp/camdiscover_lan.log 2>&1 &
        pid=$!; last_tail=""
        while kill -0 "$pid" 2>/dev/null; do
            if [ -f /tmp/camdiscover_lan.log ]; then
                current="$(tail -n 25 /tmp/camdiscover_lan.log 2>/dev/null)"
                if [ "$current" != "$last_tail" ]; then
                    printf '%s\n' "$current" | while IFS= read -r line; do
                        [ -n "$line" ] || continue
                        case "$line" in
                            DEVICE\ *)
                                old="$(nv lan_discovery_devices)"
                                if [ -n "$old" ]; then nvram set lan_discovery_devices="$(printf '%s\n%s\n' "$old" "$line" | tail -n 40)"; else nvram set lan_discovery_devices="$line"; fi
                                count="$(printf '%s\n' "$(nv lan_discovery_devices)" | grep -c '^DEVICE ' 2>/dev/null)"
                                nvram set lan_discovery_status_count="${count:-0}"; log_line "$line" ;;
                            *probe*|*RX*|*FAILED*|*listen*) log_line "$line" ;;
                        esac
                    done
                    last_tail="$current"
                fi
            fi
            sleep 1
        done
        wait "$pid"
        nvram set lan_discovery_status_state="空闲"; log_line "设备发现完成"
    else
        nvram set lan_discovery_status_state="设备发现未启用"
    fi
}

ensure_defaults
refresh_interfaces
last_iface=""; last_state="-9"; iface_refresh=0
while :; do
    iface_refresh=$((iface_refresh + 1)); if [ "$iface_refresh" -ge 5 ]; then refresh_interfaces; iface_refresh=0; fi
    enable="$(cfg lan_discovery_enable 1)"; iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$iface" != "$last_iface" ]; then last_iface="$iface"; last_state="-9"; nvram set lan_discovery_status_state="等待接口"; log_line "检测接口切换为 $iface"; set_link_status "$iface" "WAIT"; fi
    if [ "$enable" != "1" ]; then
        nvram set lan_discovery_status_state="已禁用"
        if [ -e "/sys/class/net/$iface" ]; then
            if [ -r "/sys/class/net/$iface/carrier" ]; then link="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"; [ "$link" = "1" ] && link="UP" || link="DOWN"; else link="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"; fi
            set_link_status "$iface" "${link:--}"
        fi
        sleep 2; continue
    fi
    if [ ! -e "/sys/class/net/$iface" ]; then set_link_status "$iface" "不存在"; sleep 2; continue; fi
    if [ -r "/sys/class/net/$iface/carrier" ]; then state="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"; else state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"; [ "$state" = "up" ] && state=1 || state=0; fi
    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then set_link_status "$iface" "UP"; sleep 1; run_discovery "$iface" & else set_link_status "$iface" "DOWN"; nvram set lan_discovery_status_state="等待接口"; log_line "LAN Link DOWN $iface"; fi
    fi
    sleep 1
done
