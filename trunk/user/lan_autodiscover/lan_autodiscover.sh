#!/bin/sh
# LAN监听、DHCP检测、主动ARP、设备发现和二层网络健康监视后端程序。
LOCKDIR=/var/run/lan_autodiscover.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    logger -t lan-autodiscover "LAN监听程序已经运行"
    exit 0
fi
trap 'stop_health; rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM HUP

# LAN设备结果和完整日志保存到临时目录，供页面及后续转发功能使用。
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
RUNTIME_DIR=/tmp/lan_discovery_runtime
HEALTH_PIDFILE=/tmp/lan_discovery_runtime/lanhealth.pid
mkdir -p /tmp "$RUNTIME_DIR"
touch "$DEVICE_DB" "$LOG_FILE"

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
now() { date '+%H:%M:%S'; }

# 运行时状态只保存在/tmp，不把状态写入持久NVRAM。
runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="${RUNTIME_DIR}/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${RUNTIME_DIR}/${key}"
}

sanitize_text() {
    printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177' | sed 's/\\\([0-9A-Fa-f]\)/\1/g'
}
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
    if [ "$mac" = "-" ] && [ "$iface" != "br0" ] && [ -e /sys/class/net/br0 ]; then mac="$(sanitize_mac "$(cat "/sys/class/net/br0/address" 2>/dev/null)")"; fi
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
}

# 从统一“自定义接口”中读取标准探测配置。
# 标准格式：名称|端口|启用；说明行以#开头，普通自定义UDP不参与标准配置。
read_custom_builtin() {
    custom="$1"
    onvif_enable=0; onvif_port=3702
    ssdp_enable=0; ssdp_port=1900
    hik_enable=0; hik_port=37020
    dahua_enable=0; dahua_port=37810
    arp_enable=0

    printf '%s\n' "$custom" | while IFS= read -r row; do
        [ -n "$row" ] || continue
        case "$row" in \#*) continue;; esac
        oldifs="$IFS"; IFS='|'; set -- $row; IFS="$oldifs"
        name="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
        port="${2:-0}"; enable="${3:-0}"
        [ "$enable" = "1" ] || enable=0
        case "$name" in
            onvif) onvif_enable=1; onvif_port="$port";;
            ssdp) ssdp_enable=1; ssdp_port="$port";;
            hik|hik-sadp) hik_enable=1; hik_port="$port";;
            dahua|dahua-dhip) dahua_enable=1; dahua_port="$port";;
            arp) arp_enable=1;;
        esac
        printf '%s\n' "__CUSTOM_CFG__ $name $port $enable"
    done
}

get_standard_config() {
    custom="$(nv lan_discovery_custom)"
    # 先使用统一自定义接口；若其中没有标准配置，则兼容旧NVRAM。
    cfg_lines="$(read_custom_builtin "$custom")"
    have_standard=0
    printf '%s\n' "$cfg_lines" | grep -q '^__CUSTOM_CFG__ ' && have_standard=1
    if [ "$have_standard" = "1" ]; then
        onvif="$(printf '%s\n' "$cfg_lines" | awk '$2=="onvif" {v=$4} END{print v+0}')"
        onvif_port="$(printf '%s\n' "$cfg_lines" | awk '$2=="onvif" {v=$3} END{print v+3702}')"
        ssdp="$(printf '%s\n' "$cfg_lines" | awk '$2=="ssdp" {v=$4} END{print v+0}')"
        ssdp_port="$(printf '%s\n' "$cfg_lines" | awk '$2=="ssdp" {v=$3} END{print v+1900}')"
        hik="$(printf '%s\n' "$cfg_lines" | awk '$2=="hik" {v=$4} END{print v+0}')"
        hik_port="$(printf '%s\n' "$cfg_lines" | awk '$2=="hik" {v=$3} END{print v+37020}')"
        dahua="$(printf '%s\n' "$cfg_lines" | awk '$2=="dahua" {v=$4} END{print v+0}')"
        dahua_port="$(printf '%s\n' "$cfg_lines" | awk '$2=="dahua" {v=$3} END{print v+37810}')"
        raw="$(printf '%s\n' "$cfg_lines" | awk '$2=="arp" {v=$4} END{print v+0}')"
    else
        onvif="$(cfg lan_discovery_onvif 1)"; onvif_port="$(cfg lan_discovery_onvif_port 3702)"
        ssdp="$(cfg lan_discovery_ssdp 1)"; ssdp_port="$(cfg lan_discovery_ssdp_port 1900)"
        hik="$(cfg lan_discovery_hik 1)"; hik_port="$(cfg lan_discovery_hik_port 37020)"
        dahua="$(cfg lan_discovery_dahua 1)"; dahua_port="$(cfg lan_discovery_dahua_port 37810)"
        raw="$(cfg lan_discovery_raw 1)"
    fi

    case "$onvif" in 1) ;; *) onvif=0;; esac
    case "$ssdp" in 1) ;; *) ssdp=0;; esac
    case "$hik" in 1) ;; *) hik=0;; esac
    case "$dahua" in 1) ;; *) dahua=0;; esac
    case "$raw" in 1) ;; *) raw=0;; esac
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
    if [ "$type" = "SUBNET" ]; then
        prefix="$(printf '%s\n' "$raw" | sed -n 's/.*INFO=\([0-9][0-9]*\).*/\1/p')"
        [ -n "$prefix" ] || prefix=24
        printf 'DEVICE type=SUBNET IP=%s INFO=%s' "$ip" "$prefix"
    else
        printf 'DEVICE type=%s IP=%s MAC=%s' "$type" "$ip" "$mac"
        info="$(printf '%s\n' "$raw" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
        [ -n "$info" ] && printf ' INFO=%s' "$info"
    fi
}
log_line() {
    line="$(sanitize_text "$(now) $*" | sed 's/\\//g')"
    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null)"
    if [ "$last" = "$line" ]; then
        runtime_set lan_discovery_status_last="$(now)"
        return
    fi
    printf '%s\n' "$line" >> "$LOG_FILE"
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    recent="$(tail -n 30 "$LOG_FILE" 2>/dev/null)"
    runtime_set lan_discovery_log="$recent"
    runtime_set lan_discovery_status_last="$(now)"
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
    runtime_set lan_discovery_interfaces="$out"
}
set_link_status() {
    iface="$1"; link="$2"; ip4="$(iface_ipv4 "$iface")"; mac="$(iface_mac "$iface")"; role="LAN"
    if printf '%s\n' "$(nv wan_ifnames) $(nv wan_ifname) $(nv wan_ifname_x)" | tr ' ' '\n' | grep -qx "$iface"; then role="WAN"; fi
    case "$iface" in wan*|ppp*|wwan*|eth*.2) role="WAN";; ra*|apcli*|wds*) role="WiFi";; br*) role="LAN";; eth*.1) role="LAN";; esac
    runtime_set lan_discovery_status_if="$iface"
    runtime_set lan_discovery_status_role="$role"
    runtime_set lan_discovery_status_ip="$ip4"
    runtime_set lan_discovery_status_mac="$mac"
    runtime_set lan_discovery_status_link="$link"
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

start_health() {
    iface="$1"
    [ -x /usr/bin/lanhealth ] || { runtime_set lan_discovery_status_health="检测程序不存在"; return 0; }
    if [ -f "$HEALTH_PIDFILE" ]; then
        hpid="$(cat "$HEALTH_PIDFILE" 2>/dev/null)"
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then return 0; fi
        rm -f "$HEALTH_PIDFILE"
    fi
    runtime_set lan_discovery_status_health="检测启动中"
    runtime_set lan_discovery_status_broadcast="0"
    runtime_set lan_discovery_status_loop="0"
    /usr/bin/lanhealth -i "$iface" > /tmp/lanhealth.log 2>&1 &
    hpid=$!
    printf '%s\n' "$hpid" > "$HEALTH_PIDFILE"
    log_line "网络环路与广播风暴检测已启动"
}
stop_health() {
    if [ -f "$HEALTH_PIDFILE" ]; then
        hpid="$(cat "$HEALTH_PIDFILE" 2>/dev/null)"
        [ -n "$hpid" ] && kill "$hpid" 2>/dev/null
        rm -f "$HEALTH_PIDFILE"
    fi
    runtime_set lan_discovery_status_health="未监视"
    runtime_set lan_discovery_status_broadcast="0"
    runtime_set lan_discovery_status_loop="0"
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
    count="$(grep -v 'type=SUBNET ' "$DEVICE_DB" 2>/dev/null | grep -v 'type=IP_CONFLICT ' | wc -l | tr -d ' ')"
    runtime_set lan_discovery_status_count="${count:-0}"
}
clear_subnet_records() {
    [ -f "$DEVICE_DB" ] || return
    tmp="${DEVICE_DB}.tmp"
    grep -v 'DEVICE type=SUBNET ' "$DEVICE_DB" > "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$DEVICE_DB"
    sync_device_cache
}
append_device() {
    clean="$(clean_device_line "$1")" || return
    ip="$(printf '%s\n' "$clean" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
    new_mac="$(printf '%s\n' "$clean" | sed -n 's/.* MAC=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return

    old_mac="$(awk -v ip="$ip" '$0 ~ /DEVICE / && $0 !~ /type=SUBNET / && $0 !~ /type=IP_CONFLICT / && $0 ~ " IP=" ip " " {for(i=1;i<=NF;i++) if($i ~ /^MAC=/) {print substr($i,5); exit}}' "$DEVICE_DB" 2>/dev/null)"
    tmp="${DEVICE_DB}.tmp"
    awk -v ip="$ip" 'BEGIN{} {if ($0 ~ /type=IP_CONFLICT /) next; if (index($0," IP=" ip " ") != 0) next; print}' "$DEVICE_DB" 2>/dev/null > "$tmp"
    printf '%s\n' "$clean" >> "$tmp"
    if [ -n "$old_mac" ] && [ "$old_mac" != "-" ] && [ -n "$new_mac" ] && [ "$new_mac" != "-" ] && [ "$old_mac" != "$new_mac" ]; then
        printf 'DEVICE type=IP_CONFLICT IP=%s MAC=%s INFO=IP冲突：旧MAC=%s，新MAC=%s\n' "$ip" "$new_mac" "$old_mac" "$new_mac" >> "$tmp"
    fi
    mv -f "$tmp" "$DEVICE_DB"
    sync_device_cache
    printf '%s' "$clean"
}
register_subnet_from_ip() {
    ip="$1"
    case "$ip" in *.*.*.*) ;; *) return;; esac
    subnet="$(printf '%s\n' "$ip" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0<=255 && $3+0<=255 && $4+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}')"
    [ -n "$subnet" ] || return
    if ! grep -q "DEVICE type=SUBNET IP=${subnet} INFO=24" "$DEVICE_DB" 2>/dev/null; then append_device "DEVICE type=SUBNET IP=${subnet} INFO=24"; fi
}
register_subnet_from_device_line() {
    line="$1"; type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"; [ "$type" = "SUBNET" ] && return
    ip="$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"; [ -n "$ip" ] && register_subnet_from_ip "$ip"
}

run_arpscan() {
    iface="$1"
    get_standard_config
    [ "$raw" = "1" ] || return 0
    [ -x /usr/bin/arpscan ] || { log_line "主动ARP扫描程序不存在"; return 0; }
    args="-i $iface -t 2"; subnet_count=0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        network="$(printf '%s\n' "$row" | sed -n 's/.* IP=\([0-9.]*\) INFO=\([0-9][0-9]*\).*/\1\/\2/p')"
        [ -n "$network" ] || continue
        args="$args -s $network"; subnet_count=$((subnet_count + 1))
    done <<EOF
$(grep '^DEVICE type=SUBNET ' "$DEVICE_DB" 2>/dev/null)
EOF
    runtime_set lan_discovery_status_state="主动ARP扫描"
    log_line "开始主动ARP扫描，已知网段 ${subnet_count} 个"
    : > /tmp/arpscan_lan.log
    /usr/bin/arpscan $args > /tmp/arpscan_lan.log 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then kill "$pid" 2>/dev/null; return 0; fi
        if [ -f /tmp/arpscan_lan.log ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    DEVICE\ *)
                        type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                        if [ "$type" != "SUBNET" ]; then
                            register_subnet_from_device_line "$line"
                            clean="$(append_device "$line")"
                            [ -n "$clean" ] && log_line "发现设备：$clean"
                        fi;;
                    \[arpscan\]*) log_line "$line";;
                esac
            done < /tmp/arpscan_lan.log
            : > /tmp/arpscan_lan.log
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
}

run_discovery() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"; dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"; discover_enable="$(cfg lan_discovery_discover_enable 1)"
    runtime_set lan_discovery_status_state="DHCP检测"; log_line "LAN口已插入 $iface"; start_health "$iface"
    : > /tmp/dhcpdetect_lan.log
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1; rc=$?
        if [ "$rc" = "0" ]; then
            line="$(grep -m1 '^\[dhcpdetect\] DHCP server found' /tmp/dhcpdetect_lan.log 2>/dev/null)"
            gateway="$(printf '%s\n' "$line" | sed -n 's/.* gateway=\([^ ]*\).*/\1/p')"; server="$(printf '%s\n' "$line" | sed -n 's/.* server=\([^ ]*\).*/\1/p')"
            if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then runtime_set lan_discovery_status_dhcp="网关 $gateway"; log_line "上级DHCP：网关 $gateway"; elif [ -n "$server" ] && [ "$server" != "-" ]; then runtime_set lan_discovery_status_dhcp="DHCP服务器 $server（未提供网关）"; log_line "上级DHCP：服务器 $server，未提供网关"; else runtime_set lan_discovery_status_dhcp="已发现DHCP（无网关信息）"; log_line "上级DHCP已发现，但报文未提供网关"; fi
        else runtime_set lan_discovery_status_dhcp="未发现DHCP"; log_line "未发现DHCP"; fi
    else runtime_set lan_discovery_status_dhcp="未启用"; fi

    if [ "$discover_enable" != "1" ] || [ ! -x /usr/bin/camdiscover ]; then runtime_set lan_discovery_status_state="设备发现未启用"; return; fi
    clear_subnet_records; register_subnet_from_ip "$(iface_ipv4 "$iface" | cut -d/ -f1)"; sync_device_cache; runtime_set lan_discovery_status_state="持续设备发现"

    while is_link_up "$iface"; do
        if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then runtime_set lan_discovery_status_state="设备发现未启用"; log_line "设备发现已关闭，停止设备发现进程"; break; fi
        discover_cycle="$(cfg lan_discovery_cycle 10)"; case "$discover_cycle" in ''|*[!0-9]*) discover_cycle=10;; esac
        [ "$discover_cycle" -ge 1 ] 2>/dev/null || discover_cycle=1; [ "$discover_cycle" -le 3600 ] 2>/dev/null || discover_cycle=3600
        get_standard_config
        custom="$(nv lan_discovery_custom)"; probe_timeout=5; [ "$discover_cycle" -lt "$probe_timeout" ] 2>/dev/null && probe_timeout="$discover_cycle"; [ "$probe_timeout" -ge 1 ] 2>/dev/null || probe_timeout=1
        round_start="$(date +%s)"

        if [ "$raw" = "1" ]; then run_arpscan "$iface"; fi
        log_line "本轮设备发现周期 ${discover_cycle}s，响应等待 ${probe_timeout}s"
        : > /tmp/camdiscover_lan.log; : > /tmp/camdiscover_custom.conf
        printf '%s\n' "$custom" | while IFS= read -r row; do case "$row" in ''|\#*) continue;; esac; p1="$(printf '%s' "$row" | awk -F'|' '{print NF}')"; [ "$p1" -ge 5 ] && printf '%s\n' "$row" >> /tmp/camdiscover_custom.conf; done
        args="-i $iface -t $probe_timeout -o $onvif_port -s $ssdp_port -k $hik_port -d $dahua_port"
        [ "$onvif" = "1" ] && args="$args -O"; [ "$ssdp" = "1" ] && args="$args -S"; [ "$hik" = "1" ] && args="$args -H"; [ "$dahua" = "1" ] && args="$args -D"; [ "$raw" = "1" ] && args="$args -A"; [ -s /tmp/camdiscover_custom.conf ] && args="$args -C /tmp/camdiscover_custom.conf"
        /usr/bin/camdiscover $args > /tmp/camdiscover_lan.log 2>&1 & pid=$!
        last_tail=""; stop_discovery=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then stop_discovery=1; kill "$pid" 2>/dev/null; log_line "设备发现开关已关闭，终止当前探测进程"; break; fi
            if [ -f /tmp/camdiscover_lan.log ]; then
                current="$(tail -n 25 /tmp/camdiscover_lan.log 2>/dev/null)"
                if [ "$current" != "$last_tail" ]; then
                    printf '%s\n' "$current" | while IFS= read -r line; do
                        [ -n "$line" ] || continue
                        case "$line" in
                            DEVICE\ *) type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"; if [ "$type" != "SUBNET" ]; then register_subnet_from_device_line "$line"; clean="$(append_device "$line")"; [ -n "$clean" ] && log_line "发现设备：$clean"; fi;;
                            *probe\ sent*|*probe\ FAILED*) log_line "$line";; *listen\ *FAILED*) log_line "$line";; *probes\ enabled:*) log_line "$line";;
                        esac
                    done
                    last_tail="$current"
                fi
            fi
            sleep 1
        done
        wait "$pid" 2>/dev/null
        if [ "$stop_discovery" = "1" ] || [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then runtime_set lan_discovery_status_state="设备发现未启用"; break; fi
        if ! is_link_up "$iface"; then break; fi
        elapsed=$(( $(date +%s) - round_start )); wait_seconds=$((discover_cycle - elapsed)); [ "$wait_seconds" -lt 0 ] 2>/dev/null && wait_seconds=0
        log_line "本轮主动探测完成，继续监听，下一轮周期 ${discover_cycle}s"
        while [ "$wait_seconds" -gt 0 ]; do
            if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then runtime_set lan_discovery_status_state="设备发现未启用"; break; fi
            if ! is_link_up "$iface"; then break; fi
            sleep 1; wait_seconds=$((wait_seconds - 1))
        done
    done
    if [ "$(cfg lan_discovery_discover_enable 1)" = "1" ]; then runtime_set lan_discovery_status_state="等待接口"; else runtime_set lan_discovery_status_state="设备发现未启用"; fi
}

ensure_defaults
refresh_interfaces
last_iface=""; last_state="-9"; last_discover="-9"; iface_refresh=0
while :; do
    iface_refresh=$((iface_refresh + 1)); if [ "$iface_refresh" -ge 5 ]; then refresh_interfaces; iface_refresh=0; fi
    enable="$(cfg lan_discovery_enable 1)"; discover_enable="$(cfg lan_discovery_discover_enable 1)"; iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$iface" != "$last_iface" ]; then last_iface="$iface"; set_link_status "$iface" "$(lan_phy_link_state 2>/dev/null || echo '-')"; log_line "检测接口切换为 $iface"; fi
    if [ "$discover_enable" != "$last_discover" ]; then last_discover="$discover_enable"; [ "$discover_enable" = "1" ] && log_line "设备发现已启用" || log_line "设备发现已禁用"; fi
    if [ "$enable" != "1" ]; then runtime_set lan_discovery_status_state="LAN监听已禁用"; sleep 1; continue; fi
    if is_link_up "$iface"; then link="UP"; else link="DOWN"; fi
    set_link_status "$iface" "$link"
    if [ "$link" = "UP" ] && [ "$last_state" != "1" ]; then last_state=1; run_discovery "$iface" & worker_pid=$!; echo "$worker_pid" > /tmp/lan_autodiscover_worker.pid
    elif [ "$link" = "DOWN" ] && [ "$last_state" != "0" ]; then last_state=0; [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null; worker_pid=""; stop_health; runtime_set lan_discovery_status_state="等待接口"; fi
    sleep 1
done
