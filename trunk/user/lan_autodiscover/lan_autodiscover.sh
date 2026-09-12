#!/bin/sh
# LAN监听、DHCP检测、主动ARP、设备发现和二层网络健康监视后端程序。
# 标准探测配置统一从lan_discovery_custom读取，旧NVRAM仅作为兼容回退。

LOCKDIR=/var/run/lan_autodiscover.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    logger -t lan-autodiscover "LAN监听程序已经运行"
    exit 0
fi

DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
RUNTIME_DIR=/tmp/lan_discovery_runtime
HEALTH_PIDFILE="$RUNTIME_DIR/lanhealth.pid"
DHCP_LOG=/tmp/dhcpdetect_lan.log
ARP_LOG=/tmp/arpscan_lan.log
CAM_LOG=/tmp/camdiscover_lan.log
CUSTOM_CONF=/tmp/camdiscover_custom.conf
CUSTOM_TMP="$RUNTIME_DIR/custom_parse.tmp"

mkdir -p /tmp "$RUNTIME_DIR"
touch "$DEVICE_DB" "$LOG_FILE"

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
now() { date '+%H:%M:%S'; }

runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="${RUNTIME_DIR}/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${RUNTIME_DIR}/${key}"
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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

log_line() {
    line="$(sanitize_text "$(now) $*" | sed 's/\\//g')"
    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null)"
    if [ "$last" = "$line" ]; then
        runtime_set "lan_discovery_status_last=$(now)"
        return
    fi
    printf '%s\n' "$line" >> "$LOG_FILE"
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    runtime_set "lan_discovery_log=$(tail -n 30 "$LOG_FILE" 2>/dev/null)"
    runtime_set "lan_discovery_status_last=$(now)"
    logger -t lan-autodiscover "$(sanitize_text "$*")"
}

iface_ipv4() {
    iface="$1"
    ip4="$(ip -4 addr show dev "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    [ -n "$ip4" ] || ip4="$(ip -4 addr show dev br0 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
    [ -n "$ip4" ] || ip4="$(nv lan_ipaddr)"
    printf '%s' "${ip4:--}"
}

iface_mac() {
    iface="$1"
    mac="$(sanitize_mac "$(cat "/sys/class/net/$iface/address" 2>/dev/null)")"
    [ "$mac" != "-" ] || mac="$(sanitize_mac "$(cat /sys/class/net/br0/address 2>/dev/null)")"
    [ "$mac" != "-" ] || mac="$(sanitize_mac "$(nv lan_hwaddr)")"
    printf '%s' "${mac:--}"
}

mtk_esw_lan4_state() {
    [ -x /sbin/mtk_esw ] || return 2
    state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
    case "$state" in
        1) printf '1'; return 0;;
        0) printf '0'; return 0;;
    esac
    return 2
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

set_link_status() {
    iface="$1"
    link="$2"
    runtime_set "lan_discovery_status_if=$iface"
    runtime_set "lan_discovery_status_role=LAN"
    runtime_set "lan_discovery_status_ip=$(iface_ipv4 "$iface")"
    runtime_set "lan_discovery_status_mac=$(iface_mac "$iface")"
    runtime_set "lan_discovery_status_link=$link"
}

start_health() {
    iface="$1"
    [ -x /usr/bin/lanhealth ] || { runtime_set "lan_discovery_status_health=检测程序不存在"; return 0; }
    if [ -f "$HEALTH_PIDFILE" ]; then
        hpid="$(cat "$HEALTH_PIDFILE" 2>/dev/null)"
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then return 0; fi
        rm -f "$HEALTH_PIDFILE"
    fi
    runtime_set "lan_discovery_status_health=检测启动中"
    runtime_set "lan_discovery_status_broadcast=0"
    runtime_set "lan_discovery_status_loop=0"
    /usr/bin/lanhealth -i "$iface" >/tmp/lanhealth.log 2>&1 &
    printf '%s\n' "$!" > "$HEALTH_PIDFILE"
    log_line "网络环路与广播风暴检测已启动"
}

stop_health() {
    if [ -f "$HEALTH_PIDFILE" ]; then
        hpid="$(cat "$HEALTH_PIDFILE" 2>/dev/null)"
        [ -n "$hpid" ] && kill "$hpid" 2>/dev/null
        rm -f "$HEALTH_PIDFILE"
    fi
    runtime_set "lan_discovery_status_health=未监视"
    runtime_set "lan_discovery_status_broadcast=0"
    runtime_set "lan_discovery_status_loop=0"
}

clean_device_line() {
    raw="$(sanitize_text "$1" | sed 's/\\//g')"
    type="$(printf '%s\n' "$raw" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$raw" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$raw" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    mac="$(sanitize_mac "$mac")"
    case "$ip" in *.*.*.*) ;; *) return 1;; esac
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
    runtime_set "lan_discovery_status_count=${count:-0}"
}

clear_subnet_records() {
    [ -f "$DEVICE_DB" ] || return
    tmp="${DEVICE_DB}.tmp"
    grep -v 'DEVICE type=SUBNET ' "$DEVICE_DB" > "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$DEVICE_DB"
    sync_device_cache
}


module_cn() {
    [ "$1" = "1" ] && printf '启用' || printf '停用'
}

format_device_log() {
    line="$1"
    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$line" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$line" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    response_len="$(printf '%s\n' "$line" | sed -n 's/.*response_len=\([0-9][0-9]*\).*/\1/p')"
    [ -n "$ip" ] || return 0
    [ -n "$mac" ] || mac="-"
    case "$mac" in
        ''|-) mac="$(ip neigh show "$ip" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}')";;
    esac
    [ -n "$mac" ] || mac="-"
    case "$type" in
        ONVIF|onvif) protocol="ONVIF";;
        SSDP|ssdp) protocol="SSDP";;
        HIK|HIK-SADP|hik|hik-sadp) protocol="HIK";;
        DAHUA|DAHUA-DHIP|dahua|dahua-dhip) protocol="DAHUA";;
        ARP|arp) protocol="ARP";;
        *) protocol="$type";;
    esac
    if [ -n "$response_len" ]; then
        log_line "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=${response_len}字节"
    elif [ "$protocol" = "ARP" ]; then
        log_line "发现设备：IP=$ip 协议=ARP MAC=$mac 回包响应=收到ARP回复"
    else
        log_line "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=已收到"
    fi
}

device_state_event() {
    line="$1"
    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$line" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$line" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return 0
    case "$type" in
        ARP|arp) /usr/bin/lan_device_state.sh arp "$ip" "$mac" 2>/dev/null || :;;
        SUBNET|subnet) :;;
        *) /usr/bin/lan_device_state.sh proto "$ip" "$type" 2>/dev/null || :;;
    esac
}

append_device() {
    clean="$(clean_device_line "$1")" || return
    ip="$(printf '%s\n' "$clean" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
    new_mac="$(printf '%s\n' "$clean" | sed -n 's/.* MAC=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return
    old_mac="$(awk -v ip="$ip" '$0 ~ /DEVICE / && $0 !~ /type=SUBNET / && $0 !~ /type=IP_CONFLICT / && $0 ~ " IP=" ip " " {for(i=1;i<=NF;i++) if($i ~ /^MAC=/) {print substr($i,5); exit}}' "$DEVICE_DB" 2>/dev/null)"
    tmp="${DEVICE_DB}.tmp"
    awk -v ip="$ip" '{if ($0 ~ /type=IP_CONFLICT /) next; if (index($0," IP=" ip " ") != 0) next; print}' "$DEVICE_DB" 2>/dev/null > "$tmp"
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
    subnet="$(printf '%s\n' "$ip" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}')"
    [ -n "$subnet" ] || return
    grep -q "DEVICE type=SUBNET IP=${subnet} INFO=24" "$DEVICE_DB" 2>/dev/null || append_device "DEVICE type=SUBNET IP=${subnet} INFO=24"
}

# 统一从自定义接口解析标准探测，不经过管道子Shell，因此开关不会丢失。
read_standard_config() {
    custom="$1"
    onvif=0; onvif_port=3702; ssdp=0; ssdp_port=1900
    hik=0; hik_port=37020; dahua=0; dahua_port=37810; raw=0
    standard_found=0
    : > "$CUSTOM_TMP"
    printf '%s\n' "$custom" > "$CUSTOM_TMP"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        row="$(trim "$row")"
        case "$row" in \#*) continue;; esac
        name="$(trim "$(printf '%s' "$row" | cut -d'|' -f1)")"
        port="$(trim "$(printf '%s' "$row" | cut -d'|' -f2)")"
        enable="$(trim "$(printf '%s' "$row" | cut -d'|' -f3)")"
        name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
        case "$name" in
            onvif|ssdp|hik|hik-sadp|dahua|dahua-dhip|arp)
                standard_found=1
                [ "$enable" = "1" ] && enable=1 || enable=0
                case "$name" in
                    onvif) onvif="$enable"; [ -n "$port" ] && onvif_port="$port";;
                    ssdp) ssdp="$enable"; [ -n "$port" ] && ssdp_port="$port";;
                    hik|hik-sadp) hik="$enable"; [ -n "$port" ] && hik_port="$port";;
                    dahua|dahua-dhip) dahua="$enable"; [ -n "$port" ] && dahua_port="$port";;
                    arp) raw="$enable";;
                esac
                ;;
        esac
    done < "$CUSTOM_TMP"
    rm -f "$CUSTOM_TMP"

    if [ "$standard_found" != "1" ]; then
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

write_custom_config() {
    custom="$1"
    : > "$CUSTOM_CONF"
    printf '%s\n' "$custom" > "$CUSTOM_TMP"
    while IFS= read -r row; do
        row="$(trim "$row")"
        [ -n "$row" ] || continue
        case "$row" in \#*) continue;; esac
        fields="$(printf '%s' "$row" | awk -F'|' '{print NF}')"
        case "$fields" in
            5)
                enabled="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"
                [ "$enabled" = "1" ] || continue
                printf '%s\n' "$row" >> "$CUSTOM_CONF"
                ;;
        esac
    done < "$CUSTOM_TMP"
    rm -f "$CUSTOM_TMP"
}

run_arpscan() {
    iface="$1"
    [ "$raw" = "1" ] || return 0
    [ -x /usr/bin/arpscan ] || { log_line "主动ARP扫描程序不存在"; return 0; }
    args="-i $iface -t 2"
    subnet_count=0
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        network="$(printf '%s\n' "$row" | sed -n 's/.* IP=\([0-9.]*\) INFO=\([0-9][0-9]*\).*/\1\/\2/p')"
        [ -n "$network" ] || continue
        args="$args -s $network"
        subnet_count=$((subnet_count + 1))
    done <<EOF
$(grep '^DEVICE type=SUBNET ' "$DEVICE_DB" 2>/dev/null)
EOF
    runtime_set "lan_discovery_status_state=主动ARP扫描"
    log_line "开始主动ARP扫描，已知网段 ${subnet_count} 个"
    : > "$ARP_LOG"
    /usr/bin/arpscan $args > "$ARP_LOG" 2>&1 &
    pid=$!
    processed=""
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
            kill "$pid" 2>/dev/null
            break
        fi
        if [ -s "$ARP_LOG" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    DEVICE\ *)
                        type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                        [ "$type" = "SUBNET" ] && continue
                        register_subnet_from_ip "$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
                        device_state_event "$line"
                        clean="$(append_device "$line")"
                        [ -n "$clean" ] && format_device_log "$line"
                        ;;
                    \[arpscan\]*)
                        arp_line="$(printf '%s\n' "$line" | sed 's/^\[arpscan\][[:space:]]*//')"
                        log_line "【ARP扫描】$arp_line"
                        ;;
                esac
            done < "$ARP_LOG"
            : > "$ARP_LOG"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
    if [ -s "$ARP_LOG" ]; then
        while IFS= read -r line; do
            case "$line" in
                DEVICE\ *)
                    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                    [ "$type" = "SUBNET" ] && continue
                    register_subnet_from_ip "$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
                    device_state_event "$line"
                    clean="$(append_device "$line")"
                    [ -n "$clean" ] && format_device_log "$line"
                    ;;
                \[arpscan\]*) arp_line="$(printf '%s\n' "$line" | sed 's/^\[arpscan\][[:space:]]*//')"; log_line "【ARP扫描】$arp_line";;
            esac
        done < "$ARP_LOG"
    fi
    rm -f "$ARP_LOG"
}

run_dhcp_detect() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    : > "$DHCP_LOG"
    runtime_set "lan_discovery_status_state=DHCP检测"
    if [ "$dhcp_enable" != "1" ] || [ ! -x /usr/bin/dhcpdetect ]; then
        runtime_set "lan_discovery_status_dhcp=未启用"
        return 0
    fi
    /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" > "$DHCP_LOG" 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        line="$(grep -m1 '^\[dhcpdetect\] DHCP server found' "$DHCP_LOG" 2>/dev/null)"
        gateway="$(printf '%s\n' "$line" | sed -n 's/.* gateway=\([^ ]*\).*/\1/p')"
        server="$(printf '%s\n' "$line" | sed -n 's/.* server=\([^ ]*\).*/\1/p')"
        if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
            runtime_set "lan_discovery_status_dhcp=网关 $gateway"
            log_line "上级DHCP：网关 $gateway"
            register_subnet_from_ip "$gateway"
        elif [ -n "$server" ] && [ "$server" != "-" ]; then
            runtime_set "lan_discovery_status_dhcp=DHCP服务器 $server（未提供网关）"
            log_line "上级DHCP：服务器 $server，未提供网关"
        else
            runtime_set "lan_discovery_status_dhcp=已发现DHCP（无网关信息）"
            log_line "上级DHCP已发现，但报文未提供网关"
        fi
    else
        runtime_set "lan_discovery_status_dhcp=未发现DHCP"
        log_line "未发现DHCP"
    fi
}

run_camdiscover() {
    iface="$1"
    discover_cycle="$2"
    custom="$(nv lan_discovery_custom)"
    get_standard_config_dummy=0
    read_standard_config "$custom"
    probe_timeout=5
    [ "$discover_cycle" -lt "$probe_timeout" ] 2>/dev/null && probe_timeout="$discover_cycle"
    [ "$probe_timeout" -ge 1 ] 2>/dev/null || probe_timeout=1
    write_custom_config "$custom"

    log_line "本轮设备发现周期 ${discover_cycle}s，响应等待 ${probe_timeout}s"
    log_line "发现程序启用模块：ONVIF=$(module_cn "$onvif") SSDP=$(module_cn "$ssdp") HIK=$(module_cn "$hik") DAHUA=$(module_cn "$dahua") ARP=$(module_cn "$raw")"
    : > "$CAM_LOG"
    args="-i $iface -t $probe_timeout -o $onvif_port -s $ssdp_port -k $hik_port -d $dahua_port"
    [ "$onvif" = "1" ] && args="$args -O"
    [ "$ssdp" = "1" ] && args="$args -S"
    [ "$hik" = "1" ] && args="$args -H"
    [ "$dahua" = "1" ] && args="$args -D"
    [ "$raw" = "1" ] && args="$args -A"
    [ -s "$CUSTOM_CONF" ] && args="$args -C $CUSTOM_CONF"

    /usr/bin/camdiscover $args > "$CAM_LOG" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
            kill "$pid" 2>/dev/null
            return 0
        fi
        if [ -s "$CAM_LOG" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    DEVICE\ *)
                        type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                        [ "$type" = "SUBNET" ] && continue
                        register_subnet_from_ip "$(printf '%s\n' "$line" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
                        device_state_event "$line"
                        clean="$(append_device "$line")"
                        [ -n "$clean" ] && format_device_log "$line"
                        ;;
                    *probe\ sent*|*probe\ FAILED*|*probes\ enabled:*|*listen\ *FAILED*) log_line "【设备探测】$line";;
                esac
            done < "$CAM_LOG"
            : > "$CAM_LOG"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
    rm -f "$CAM_LOG"
}

run_discovery() {
    iface="$1"
    log_line "LAN口已插入 $iface"
    start_health "$iface"
    run_dhcp_detect "$iface"

    if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
        runtime_set "lan_discovery_status_state=设备发现未启用"
        return 0
    fi

    clear_subnet_records
    register_subnet_from_ip "$(iface_ipv4 "$iface" | cut -d/ -f1)"
    run_dhcp_detect "$iface"
    sync_device_cache

    while is_link_up "$iface"; do
        [ "$(cfg lan_discovery_discover_enable 1)" = "1" ] || {
            runtime_set "lan_discovery_status_state=设备发现未启用"
            log_line "设备发现已关闭"
            break
        }
        discover_cycle="$(cfg lan_discovery_cycle 10)"
        case "$discover_cycle" in ''|*[!0-9]*) discover_cycle=10;; esac
        [ "$discover_cycle" -ge 1 ] 2>/dev/null || discover_cycle=1
        [ "$discover_cycle" -le 3600 ] 2>/dev/null || discover_cycle=3600

        custom="$(nv lan_discovery_custom)"
        read_standard_config "$custom"
        cycle_start="$(date +%s)"
        if [ "$raw" = "1" ]; then
            /usr/bin/lan_device_state.sh begin
            run_arpscan "$iface"
        fi
        run_camdiscover "$iface" "$discover_cycle"
        if [ "$raw" = "1" ]; then
            /usr/bin/lan_device_state.sh finish
        fi
        if ! is_link_up "$iface"; then break; fi

        elapsed=$(( $(date +%s) - cycle_start ))
        wait_seconds=$((discover_cycle - elapsed))
        [ "$wait_seconds" -lt 0 ] 2>/dev/null && wait_seconds=0
        log_line "本轮主动探测完成，继续监听，下一轮周期 ${discover_cycle}s"
        while [ "$wait_seconds" -gt 0 ]; do
            [ "$(cfg lan_discovery_discover_enable 1)" = "1" ] || break
            is_link_up "$iface" || break
            sleep 1
            wait_seconds=$((wait_seconds - 1))
        done
    done
    runtime_set "lan_discovery_status_state=等待接口"
}

cleanup() {
    stop_health
    rm -f "$CUSTOM_TMP" "$CUSTOM_CONF" "$DHCP_LOG" "$ARP_LOG" "$CAM_LOG"
    rmdir "$LOCKDIR" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

# 启动时保留兼容默认值，但标准探测实际运行配置来自自定义接口。
[ -n "$(nv lan_discovery_enable)" ] || nvram set lan_discovery_enable=1
[ -n "$(nv lan_discovery_ifname)" ] || nvram set lan_discovery_ifname=eth2.1
[ -n "$(nv lan_discovery_dhcp_enable)" ] || nvram set lan_discovery_dhcp_enable=1
[ -n "$(nv lan_discovery_dhcp_timeout)" ] || nvram set lan_discovery_dhcp_timeout=3
[ -n "$(nv lan_discovery_discover_enable)" ] || nvram set lan_discovery_discover_enable=1
[ -n "$(nv lan_discovery_cycle)" ] || nvram set lan_discovery_cycle=10
[ -n "$(nv lan_discovery_miss_limit)" ] || nvram set lan_discovery_miss_limit=3

iface="$(cfg lan_discovery_ifname eth2.1)"
last_iface=""
last_state="-1"

while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"

    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        runtime_set "lan_discovery_status_if=$iface"
        log_line "检测接口切换为 $iface"
    fi

    [ "$enable" = "1" ] || {
        runtime_set "lan_discovery_status_state=LAN监听已禁用"
        sleep 1
        continue
    }

    if is_link_up "$iface"; then link="UP"; state=1; else link="DOWN"; state=0; fi
    set_link_status "$iface" "$link"

    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then
            run_discovery "$iface" &
            worker_pid=$!
            printf '%s\n' "$worker_pid" > /tmp/lan_autodiscover_worker.pid
        else
            [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null
            worker_pid=""
            stop_health
            runtime_set "lan_discovery_status_state=等待接口"
            runtime_set "lan_discovery_status_dhcp=未检测"
        fi
    fi
    sleep 1
done
