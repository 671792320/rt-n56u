#!/bin/sh
# Portable LAN link-event watcher for Padavan.
# Configuration is stored in NVRAM by Advanced_LANDiscover_Content.asp.

log() {
    logger -t lan-autodiscover "$*"
}

nv() {
    nvram get "$1" 2>/dev/null
}

cfg() {
    v="$(nv "$1")"
    if [ -n "$v" ]; then echo "$v"; else echo "$2"; fi
}

run_discovery() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    discover_timeout="$(cfg lan_discovery_timeout 10)"
    onvif="$(cfg lan_discovery_onvif 1)"
    ssdp="$(cfg lan_discovery_ssdp 1)"
    hik="$(cfg lan_discovery_hik 1)"
    dahua="$(cfg lan_discovery_dahua 1)"
    raw="$(cfg lan_discovery_raw 1)"
    onvif_port="$(cfg lan_discovery_onvif_port 3702)"
    ssdp_port="$(cfg lan_discovery_ssdp_port 1900)"
    hik_port="$(cfg lan_discovery_hik_port 37020)"
    dahua_port="$(cfg lan_discovery_dahua_port 37810)"

    log "LAN link event on $iface"
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            log "DHCP server detected: $(sed -n '1p' /tmp/dhcpdetect_lan.log 2>/dev/null)"
        else
            log "no DHCP server reply"
        fi
    fi

    if [ "$discover_enable" = "1" ] && [ -x /usr/bin/camdiscover ]; then
        log "starting device discovery on $iface"
        /usr/bin/camdiscover -i "$iface" -t "$discover_timeout" \
            -o "$onvif_port" -s "$ssdp_port" -k "$hik_port" -d "$dahua_port" \
            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" \
            >/tmp/camdiscover_lan.log 2>&1
        log "device discovery finished"
        logger -t camdiscover < /tmp/camdiscover_lan.log
    fi
}

last_state=-1
while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"

    if [ "$enable" != "1" ]; then
        last_state=0
        sleep 2
        continue
    fi

    if [ ! -e "/sys/class/net/$iface" ]; then
        if [ "$last_state" != "-2" ]; then log "interface $iface not found"; last_state=-2; fi
        sleep 2
        continue
    fi

    if [ -r "/sys/class/net/$iface/carrier" ]; then
        state="$(sed -n '1p' "/sys/class/net/$iface/carrier" 2>/dev/null)"
    else
        state="$(sed -n '1p' "/sys/class/net/$iface/operstate" 2>/dev/null)"
        [ "$state" = "up" ] && state=1 || state=0
    fi

    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then
            sleep 1
            run_discovery "$iface" &
        else
            log "LAN link down on $iface"
        fi
    fi
    sleep 1
done
