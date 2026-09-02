#!/bin/sh
# LAN监听、DHCP检测和设备发现后端程序。
LOCKDIR=/var/run/lan_autodiscover.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    logger -t lan-autodiscover "LAN监听程序已经运行"
    exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM HUP

# LAN设备结果和完整日志保存到持久化存储，供页面及后续转发功能使用。
DEVICE_DB=/etc/storage/lan_discovery_devices.db
LOG_FILE=/etc/storage/lan_discovery.log
mkdir -p /etc/storage
touch "$DEVICE_DB" "$LOG_FILE"

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }
sanitize_text() { printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177' | sed 's/\\\([0-9A-Fa-f]\)/\1/g'; }
sanitize_mac() {
    m="$(sanitize_text "$1")"
    m="$(printf '%s' "$m" | sed 's/\\//g' | tr '[:lower:]' '[:upper:]')"
    case "$m" in
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) printf '%s' "$m";;
        *) printf '%s' "-";;
    esac
}
iface_ipv4() {
    iface="$1"
    ip4="$(ip -4 addr show dev "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    if [ -z "$ip4" ] && [ "$iface" != "br0" ] && [ -e /sys/class/net/br0 ]; then
        ip4="$(ip -4 addr show dev br0 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    fi
    if [ -z "$ip4" ]; then ip4="$(nv lan_ipaddr)"; fi
    printf '%s' "${ip4:--}"
}
iface_mac() {
    iface="$1"
    mac="$(sanitize_mac "$(cat "/sys/class/net/$iface/address" 2>/dev/null)")"
    if [ "$mac" = "-" ] && [ "$iface" != "br0" ] && [ -e /sys/class/net/br0 ]; then mac="$(sanitize_mac "$(cat /sys/class/net/br0/address 2>/dev/null)")"; fi
    if [ "$mac" = "-" ]; then mac="$(sanitize_mac "$(nv lan_hwaddr)")"; fi
    printf '%s' "${mac:--}"
}
ensure_defaults() {
    [ -n "$(nv lan_discovery_enable)" ] || nvram set lan_discovery_enable=1
    [ -n "$(nv lan_discovery_ifname)" ] || nvram set lan_discovery_ifname=eth2.1
    [ -n "$(nv lan_discovery_dhcp_enable)" ] || nvram set lan_discovery_dhcp_enable=1
    [ -n "$(nv lan_discovery_dhcp_timeout)" ] || nvram set lan_discovery_dhcp_timeout=3
    [ -n "$(nv lan_discovery_discover_enable)" ] || nvram set lan_discovery_discover_enable=1
    [ -n "$(nv lan_discovery_cycle)" ] || nvram set lan_discovery_cycle=10
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
clean_device_line() {
    raw="$(sanitize_text "$1" | sed 's/\\//g')"
    type="$(printf '%s\n' "$raw" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$raw" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$raw" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    mac="$(sanitize_mac "$mac")"
    case "$ip" in
        *.*.*.*) ;;
        *) return 1;;
    esac
    [ -n "$type" ] || type="IP"
    printf 'DEVICE type=%s IP=%s MAC=%s' "$type" "$ip" "$mac"
}
log_line() {
    line="$(sanitize_text "$(now) $*" | sed 's/\\//g')"
    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null)"
    if [ "$last" = "$line" ]; then
        nvram set lan_discovery_status_last "$(now)"
        return
    fi
    printf '%s\n' "$line" >> "$LOG_FILE"
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    # NVRAM只保留最近30行，避免长时间运行导致状态字段过大。
    recent="$(tail -n 30 "$LOG_FILE" 2>/dev/null)"
    nvram set lan_discovery_log "$recent"
    nvram set lan_discovery_status_last "$(now)"
    logger -t lan-autodiscover "$(sanitize_text "$*")"
}
# Q7唯一RJ45对应MTK交换机LAN4，使用mtk-esw原生PHY状态检测物理插拔。
mtk_esw_lan4_state() {
    [ -x /sbin/mtk_esw ] || return 2
    state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
    case "$state" in
        1) printf '%s' "1"; return 0;;
        0) printf '%s' "0"; return 0;;
    esac
    return 2
}
lan_phy_link_state() {
    state="$(mtk_esw_lan4_state 2>/dev/null)"
    case "$state" in
        1) printf '%s' "UP"; return 0;;
        0) printf '%s' "DOWN"; return 0;;
    esac
    return 1
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
        case "$iface" in wan*|ppp*|wwan*|eth*.2) role="WAN";; ra*|apcli*|wds*) role="WiFi";; br*|eth*.1) role="LAN";; esac
        ip4="$(iface_ipv4 "$iface")"
        mac="$(iface_mac "$iface")"
        if [ "$iface" = "eth2.1" ]; then
            link="$(lan_phy_link_state 2>/dev/null)"
            [ -n "$link" ] || link="-"
        elif [ -r "$p/carrier" ]; then
            link="$(cat "$p/carrier" 2>/dev/null)"
            [ "$link" = "1" ] && link="UP" || link="DOWN"
        else
            link="$(cat "$p/operstate" 2>/dev/null)"
            [ "$link" = "up" ] && link="UP"
            [ "$link" = "down" ] && link="DOWN"
        fi
        line="${iface}|${role}|${ip4}|${mac}|${link:--}"
        if [ -n "$out" ]; then out="$(printf '%s\n%s' "$out" "$line")"; else out="$line"; fi
    done
    nvram set lan_discovery_interfaces "$out"
}
set_link_status() {
    iface="$1"; link="$2"; ip4="$(iface_ipv4 "$iface")"; mac="$(iface_mac "$iface")"; role="LAN"
    if printf '%s\n' "$(nv wan_ifnames) $(nv wan_ifname) $(nv wan_ifname_x)" | tr ' ' '\n' | grep -qx "$iface"; then role="WAN"; fi
    case "$iface" in wan*|ppp*|wwan*|eth*.2) role="WAN";; ra*|apcli*|wds*) role="WiFi";; br*) role="LAN";; eth*.1) role="LAN";; esac
    nvram set lan_discovery_status_if="$iface"
    nvram set lan_discovery_status_role="$role"
    nvram set lan_discovery_status_ip="$ip4"
    nvram set lan_discovery_status_mac="$mac"
    nvram set lan_discovery_status_link="$link"
}
is_link_up() {
    iface="$1"
    if [ "$iface" = "eth2.1" ]; then
        state="$(mtk_esw_lan4_state 2>/dev/null)"
        case "$state" in
            1) return 0;;
            0) return 1;;
        esac
    fi
    [ -e "/sys/class/net/$iface" ] || return 1
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = "1" ] && return 0
    else
        [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "up" ] && return 0
    fi
    return 1
}
sort_device_db() {
    [ -f "$DEVICE_DB" ] || return
    tmp="${DEVICE_DB}.tmp"
    : > "$tmp"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        ip="$(printf '%s\n' "$row" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
        key="$(printf '%s\n' "$ip" | awk -F. 'NF==4 {printf "%03d%03d%03d%03d",$1,$2,$3,$4}')"
        [ -n "$key" ] || key=999999999999
        printf '%s|%s\n' "$key" "$row"
    done < "$DEVICE_DB" | sort -n | cut -d'|' -f2- > "$tmp"
    mv -f "$tmp" "$DEVICE_DB"
}
sync_device_cache() {
    sort_device_db
    # 页面缓存只取前100条；完整数据库仍保存在持久化文件中。
    nvram set lan_discovery_devices "$(head -n 100 "$DEVICE_DB" 2>/dev/null)"
    count="$(wc -l < "$DEVICE_DB" 2>/dev/null | tr -d ' ')"
    nvram set lan_discovery_status_count "${count:-0}"
}
reset_device_db() {
    : > "$DEVICE_DB"
    nvram set lan_discovery_devices ""
    nvram set lan_discovery_status_count "0"
}
append_device() {
    clean="$(clean_device_line "$1")" || return
    ip="$(printf '%s\n' "$clean" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return
    tmp="${DEVICE_DB}.tmp"
    : > "$tmp"
    awk -v ip="$ip" 'index($0," IP=" ip " ")==0 && index($0," IP=" ip)==0 {print}' "$DEVICE_DB" 2>/dev/null >> "$tmp"
    printf '%s\n' "$clean" >> "$tmp"
    mv -f "$tmp" "$DEVICE_DB"
    sync_device_cache
    printf '%s' "$clean"
}
run_discovery() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    discover_cycle="$(cfg lan_discovery_cycle 10)"
    onvif="$(cfg lan_discovery_onvif 1)"
    ssdp="$(cfg lan_discovery_ssdp 1)"
    hik="$(cfg lan_discovery_hik 1)"
    dahua="$(cfg lan_discovery_dahua 1)"
    raw="$(cfg lan_discovery_raw 1)"
    onvif_port="$(cfg lan_discovery_onvif_port 3702)"
    ssdp_port="$(cfg lan_discovery_ssdp_port 1900)"
    hik_port="$(cfg lan_discovery_hik_port 37020)"
    dahua_port="$(cfg lan_discovery_dahua_port 37810)"
    custom="$(nv lan_discovery_custom)"

    nvram set lan_discovery_status_state="DHCP检测"
    log_line "LAN口已插入 $iface"
    : > /tmp/dhcpdetect_lan.log
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            line="$(grep -m1 '^\[dhcpdetect\] DHCP server found' /tmp/dhcpdetect_lan.log 2>/dev/null)"
            gateway="$(printf '%s\n' "$line" | sed -n 's/.* gateway=\([^ ]*\).*/\1/p')"
            server="$(printf '%s\n' "$line" | sed -n 's/.* server=\([^ ]*\).*/\1/p')"
            if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
                nvram set lan_discovery_status_dhcp="网关 $gateway"
                log_line "上级DHCP：网关 $gateway"
            elif [ -n "$server" ] && [ "$server" != "-" ]; then
                nvram set lan_discovery_status_dhcp="DHCP服务器 $server（未提供网关）"
                log_line "上级DHCP：服务器 $server，未提供网关"
            else
                nvram set lan_discovery_status_dhcp="已发现DHCP（无网关信息）"
                log_line "上级DHCP已发现，但报文未提供网关"
            fi
        else
            nvram set lan_discovery_status_dhcp="未发现DHCP"
            log_line "未发现DHCP"
        fi
    else
        nvram set lan_discovery_status_dhcp="未启用"
    fi

    if [ "$discover_enable" != "1" ] || [ ! -x /usr/bin/camdiscover ]; then
        nvram set lan_discovery_status_state="设备发现未启用"
        return
    fi

    # 发现周期不再清空设备数据库，保证页面和后续转发使用稳定结果。
    sync_device_cache
    nvram set lan_discovery_status_state="持续设备发现"
    log_line "开始持续设备发现 $iface，探测周期 ${discover_cycle}s"
    while is_link_up "$iface"; do
        if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
            nvram set lan_discovery_status_state="设备发现未启用"
            log_line "设备发现已关闭，停止设备发现进程"
            break
        fi
        : > /tmp/camdiscover_lan.log
        : > /tmp/camdiscover_custom.conf
        printf '%s\n' "$custom" | while IFS= read -r row; do
            [ -n "$row" ] || continue
            printf '%s\n' "$row" >> /tmp/camdiscover_custom.conf
        done
        args="-i $iface -t $discover_cycle -o $onvif_port -s $ssdp_port -k $hik_port -d $dahua_port -O $onvif -S $ssdp -H $hik -D $dahua -A $raw"
        [ -s /tmp/camdiscover_custom.conf ] && args="$args -C /tmp/camdiscover_custom.conf"
        /usr/bin/camdiscover $args > /tmp/camdiscover_lan.log 2>&1 &
        pid=$!
        last_tail=""
        stop_discovery=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
                stop_discovery=1
                kill "$pid" 2>/dev/null
                log_line "设备发现开关已关闭，终止当前探测进程"
                break
            fi
            if [ -f /tmp/camdiscover_lan.log ]; then
                current="$(tail -n 25 /tmp/camdiscover_lan.log 2>/dev/null)"
                if [ "$current" != "$last_tail" ]; then
                    printf '%s\n' "$current" | while IFS= read -r line; do
                        [ -n "$line" ] || continue
                        case "$line" in
                            DEVICE\ *)
                                clean="$(append_device "$line")"
                                [ -n "$clean" ] && log_line "$clean"
                                ;;
                            *probe\ sent*|*probe\ FAILED*) log_line "$line";;
                            *listen\ *FAILED*) log_line "$line";;
                        esac
                    done
                    last_tail="$current"
                fi
            fi
            sleep 1
        done
        wait "$pid" 2>/dev/null
        if [ "$stop_discovery" = "1" ] || [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
            nvram set lan_discovery_status_state="设备发现未启用"
            break
        fi
        if ! is_link_up "$iface"; then break; fi
        log_line "本轮主动探测完成，继续监听，下一轮 ${discover_cycle}s"
        sleep 1
    done
    if [ "$(cfg lan_discovery_discover_enable 1)" = "1" ]; then
        nvram set lan_discovery_status_state="等待接口"
    else
        nvram set lan_discovery_status_state="设备发现未启用"
    fi
}

ensure_defaults
refresh_interfaces
last_iface=""
last_state="-9"
iface_refresh=0
while :; do
    iface_refresh=$((iface_refresh + 1))
    if [ "$iface_refresh" -ge 5 ]; then refresh_interfaces; iface_refresh=0; fi
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_state="-9"
        nvram set lan_discovery_status_state="等待接口"
        log_line "检测接口切换为 $iface"
        if [ -e "/sys/class/net/$iface" ]; then set_link_status "$iface" "WAIT"; else set_link_status "$iface" "不存在"; fi
    fi
    if [ "$enable" != "1" ]; then
        nvram set lan_discovery_status_state="已禁用"
        if [ -e "/sys/class/net/$iface" ]; then
            if is_link_up "$iface"; then set_link_status "$iface" "UP"; else set_link_status "$iface" "DOWN"; fi
        fi
        sleep 2
        continue
    fi
    if [ ! -e "/sys/class/net/$iface" ]; then set_link_status "$iface" "不存在"; sleep 2; continue; fi
    if is_link_up "$iface"; then state=1; else state=0; fi
    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then
            set_link_status "$iface" "UP"
            # 只有物理链路从断开变为插入时清空旧网络的设备记录。
            reset_device_db
            run_discovery "$iface"
        else
            set_link_status "$iface" "DOWN"
            nvram set lan_discovery_status_state="等待接口"
            log_line "LAN口已拔出 $iface"
        fi
    fi
    sleep 1
done
