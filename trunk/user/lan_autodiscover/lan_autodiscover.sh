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
CUSTOM_TMP="$RUNTIME_DIR/custom_parse.discovery.tmp"
ACTIVE_SCAN_PID=""

mkdir -p /tmp "$RUNTIME_DIR"
touch "$LOG_FILE"

nv() { nvram get "$1" 2>/dev/null; }
cfg() { v="$(nv "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
now() { tz="$(nvram get time_zone_x 2>/dev/null)"; [ -n "$tz" ] || tz='GMT-8'; TZ="$tz" date '+%Y-%m-%d %H:%M:%S'; }
log_level() {
    level="$(nvram get lan_discovery_log_level 2>/dev/null)"
    case "$level" in
        0|1|2|3) printf '%s' "$level";;
        *) printf '1';;
    esac
}

# LAN总开关与设备发现开关必须同时开启，避免子循环绕过主开关继续运行。
discovery_enabled() {
    [ "$(cfg lan_discovery_enable 1)" = "1" ] &&
    [ "$(cfg lan_discovery_discover_enable 1)" = "1" ]
}

runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="$RUNTIME_DIR/.discovery_$key.tmp"
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

LOG_DEDUPE_DIR="$RUNTIME_DIR/.log_dedupe_autodiscover"
LOG_CACHE_TS=0
mkdir -p "$LOG_DEDUPE_DIR"

log_line() {
    level=2
    case "$1" in
        0|1|2|3) level="$1"; shift;;
    esac
    [ "$(log_level)" -ge "$level" ] 2>/dev/null || return 0
    plain="$(sanitize_text "$*" | sed 's/\\//g')"
    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    last_ts="$(cat "$LOG_DEDUPE_DIR/ts" 2>/dev/null)"
    case "$last_ts" in ''|*[!0-9]*) last_ts=0;; esac
    last_msg="$(cat "$LOG_DEDUPE_DIR/msg" 2>/dev/null)"
    if [ "$last_msg" = "$plain" ] && [ "$now_ts" -ge "$last_ts" ] 2>/dev/null && [ $((now_ts - last_ts)) -lt 5 ] 2>/dev/null; then
        runtime_set "lan_discovery_status_last=$(now)"
        return
    fi
    printf '%s' "$now_ts" > "$LOG_DEDUPE_DIR/ts"
    printf '%s' "$plain" > "$LOG_DEDUPE_DIR/msg"
    line="$(now) $plain"
    printf '%s
' "$line" >> "$LOG_FILE"

    # 日志只在达到大小上限时裁剪，避免每条设备事件都tail整个日志文件。
    log_size="$(wc -c < "$LOG_FILE" 2>/dev/null)"
    case "$log_size" in ''|*[!0-9]*) log_size=0;; esac
    if [ "$log_size" -gt 65536 ] 2>/dev/null; then
        tail -n 200 "$LOG_FILE" > "${LOG_FILE}.discovery.tmp" 2>/dev/null &&
            mv -f "@TMPLOG@" "$LOG_FILE"
    fi

    # WebUI每5秒刷新一次，日志缓存最多每2秒更新一次，避免高频runtime_set。
    if [ "$LOG_CACHE_TS" = "0" ] || [ $((now_ts - LOG_CACHE_TS)) -ge 2 ] 2>/dev/null; then
        runtime_set "lan_discovery_log=$(tail -n 30 "$LOG_FILE" 2>/dev/null)"
        LOG_CACHE_TS="$now_ts"
    fi
    runtime_set "lan_discovery_status_last=$(now)"
    logger -t lan-autodiscover "【LAN发现】$plain"
}

is_private_ip() {
    ip="$1"
    printf '%s\n' "$ip" | awk -F. '
        NF==4 &&
        (($1+0)==10 ||
         (($1+0)==172 && ($2+0)>=16 && ($2+0)<=31) ||
         (($1+0)==192 && ($2+0)==168))
        { exit 0 }
        { exit 1 }
    '
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

start_health() {
    iface="$1"
    [ -x /usr/bin/lanhealth ] || { runtime_set "lan_discovery_status_health=检测程序不存在"; return 0; }
    if [ -f "$HEALTH_PIDFILE" ]; then
        hpid="$(cat "$HEALTH_PIDFILE" 2>/dev/null)"
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
            runtime_set "lan_discovery_status_health=运行中"
            return 0
        fi
        rm -f "$HEALTH_PIDFILE"
    fi
    runtime_set "lan_discovery_status_health=检测启动中"
    runtime_set "lan_discovery_status_broadcast=0"
    runtime_set "lan_discovery_status_loop=0"
    /usr/bin/lanhealth -i "$iface" >/tmp/lanhealth.log 2>&1 &
    printf '%s\n' "$!" > "$HEALTH_PIDFILE"
    log_line 2 "网络环路与广播风暴检测已启动"
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
        ''|-) mac="$(ip neigh show "$ip" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}')" ;;
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
        log_line 3 "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=${response_len}字节"
    elif [ "$protocol" = "ARP" ]; then
        log_line 3 "发现设备：IP=$ip 协议=ARP MAC=$mac 回包响应=收到ARP回复"
    else
        log_line 3 "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=已收到"
    fi
}

device_state_event() {
    line="$1"
    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$line" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return 0

    # 最终设备数据库只允许lan_device_state.sh写入；worker只负责转交事件。
    case "$type" in
        SUBNET|subnet)
            subnet="$(printf '%s\n' "$line" | sed -n 's/.* IP=\([0-9.]*\).*/\1/p')"
            /usr/bin/lan_device_state.sh subnet "$subnet" >/dev/null 2>&1 || :
            ;;
        ARP|arp)
            mac="$(printf '%s\n' "$line" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
            /usr/bin/lan_device_state.sh arp "$ip" "$mac" >/dev/null 2>&1 || :
            /usr/bin/lan_device_state.sh record "$line" >/dev/null 2>&1 || :
            ;;
        *)
            /usr/bin/lan_device_state.sh proto "$ip" "$type" >/dev/null 2>&1 || :
            /usr/bin/lan_device_state.sh record "$line" >/dev/null 2>&1 || :
            ;;
    esac
}

register_subnet_from_ip() {
    ip="$1"
    is_private_ip "$ip" || return 0
    subnet="$(printf '%s\n' "$ip" | awk -F. 'NF==4 {printf "%d.%d.%d.0",$1,$2,$3}')"
    [ -n "$subnet" ] || return
    /usr/bin/lan_device_state.sh subnet "$subnet" >/dev/null 2>&1 || :
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
    localnet="$2"
    [ "$raw" = "1" ] || return 0
    [ -x /usr/bin/arpscan ] || { log_line 1 "主动ARP扫描程序不存在"; return 0; }

    # 主动ARP只扫描目标网段：
    # 1. 当前开机周期已经锁定的目标网段；
    # 2. DHCP/设备发现登记的目标网段。
    # Q7自身LAN网段(localnet)绝不能进入主动扫描，避免每轮重复扫描255个本机地址。
    subnet_file="$RUNTIME_DIR/.arpscan_subnets.tmp"
    : > "$subnet_file"

    for takeover_file in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$takeover_file" ] || continue
        target_net="$(sed -n 's/^network=//p' "$takeover_file" 2>/dev/null | head -n 1)"
        [ -n "$target_net" ] || continue
        [ "$target_net" != "$localnet" ] || continue
        [ "$target_net" != "0.0.0.0" ] || continue
        printf '%s|24\n' "$target_net" >> "$subnet_file"
    done

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        network="$(printf '%s\n' "$row" | sed -n 's/.* IP=\([0-9.]*\) INFO=\([0-9][0-9]*\).*/\1\/\2/p')"
        [ -n "$network" ] || continue
        network_net="${network%%/*}"
        [ "$network_net" != "$localnet" ] || continue
        printf '%s\n' "$network" >> "$subnet_file"
    done <<EOF
$(grep '^DEVICE type=SUBNET ' "$DEVICE_DB" 2>/dev/null)
EOF

    sort -u "$subnet_file" -o "$subnet_file" 2>/dev/null

    args="-i $iface -t 2"
    subnet_count=0
    while IFS= read -r network; do
        [ -n "$network" ] || continue
        args="$args -s $network"
        subnet_count=$((subnet_count + 1))
    done < "$subnet_file"
    rm -f "$subnet_file"

    if [ "$subnet_count" -eq 0 ]; then
        log_line 2 "本轮主动ARP跳过：暂无目标网段"
        return 0
    fi

    runtime_set "lan_discovery_status_state=主动ARP扫描"
    log_line 3 "开始主动ARP扫描，目标网段 ${subnet_count} 个（已排除Q7本机网段 ${localnet}/24）"
    : > "$ARP_LOG"
    /usr/bin/arpscan $args > "$ARP_LOG" 2>&1 &
    pid=$!

    # ARP扫描运行期间持续消费结果文件，并把设备事件统一交给lan_device_state.sh。
    while kill -0 "$pid" 2>/dev/null; do
        if ! discovery_enabled; then
            kill "$pid" 2>/dev/null
            break
        fi

        if [ -s "$ARP_LOG" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    DEVICE\ *)
                        device_state_event "$line"
                        format_device_log "$line"
                        ;;
                    *probe\ sent*|*probe\ FAILED*|*scan\ FAILED*)
                        log_line 3 "【ARP扫描】$line"
                        ;;
                esac
            done < "$ARP_LOG"
            : > "$ARP_LOG"
        fi
        sleep 1
    done

    wait "$pid" 2>/dev/null

    # 处理arpscan退出前最后一次尚未消费的输出。
    if [ -s "$ARP_LOG" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                DEVICE\ *)
                    device_state_event "$line"
                    format_device_log "$line"
                    ;;
                *probe\ sent*|*probe\ FAILED*|*scan\ FAILED*)
                    log_line 3 "【ARP扫描】$line"
                    ;;
            esac
        done < "$ARP_LOG"
    fi
    : > "$ARP_LOG"
}

run_dhcp_detect() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    : > "$DHCP_LOG"
    runtime_set "lan_discovery_status_state=DHCP检测"
    runtime_set "lan_discovery_status_dhcp=检测中"
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
            log_line 1 "上级DHCP：网关 $gateway"
            register_subnet_from_ip "$gateway"
        elif [ -n "$server" ] && [ "$server" != "-" ]; then
            runtime_set "lan_discovery_status_dhcp=DHCP服务器 $server（未提供网关）"
            log_line 1 "上级DHCP：服务器 $server，未提供网关"
        else
            runtime_set "lan_discovery_status_dhcp=已发现DHCP（无网关信息）"
            log_line 1 "上级DHCP已发现，但报文未提供网关"
        fi
    else
        runtime_set "lan_discovery_status_dhcp=未发现DHCP"
        log_line 2 "未发现DHCP"
    fi
}

run_camdiscover() {
    iface="$1"
    discover_cycle="$2"
    custom="$(nv lan_discovery_custom)"
    get_standard_config_dummy=0
    read_standard_config "$custom"
    probe_timeout="$(cfg lan_discovery_probe_timeout 5)"
    case "$probe_timeout" in ''|*[!0-9]*) probe_timeout=5;; esac
    [ "$probe_timeout" -ge 1 ] 2>/dev/null || probe_timeout=1
    [ "$probe_timeout" -le 30 ] 2>/dev/null || probe_timeout=30
    [ "$discover_cycle" -lt "$probe_timeout" ] 2>/dev/null && probe_timeout="$discover_cycle"
    [ "$probe_timeout" -ge 1 ] 2>/dev/null || probe_timeout=1
    write_custom_config "$custom"

    log_line 3 "本轮设备发现周期 ${discover_cycle}s，响应等待 ${probe_timeout}s"
    log_line 3 "发现程序启用模块：ONVIF=$(module_cn "$onvif") SSDP=$(module_cn "$ssdp") HIK=$(module_cn "$hik") DAHUA=$(module_cn "$dahua") ARP=$(module_cn "$raw")"
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
    ACTIVE_SCAN_PID="$pid"
    while kill -0 "$pid" 2>/dev/null; do
        if ! discovery_enabled; then
            kill "$pid" 2>/dev/null
            [ "$ACTIVE_SCAN_PID" = "$pid" ] && ACTIVE_SCAN_PID=""
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
                        ;;
                    *probe\ sent*|*probe\ FAILED*|*probes\ enabled:*|*listen\ *FAILED*) log_line 3 "【设备探测】$line";;
                esac
            done < "$CAM_LOG"
            : > "$CAM_LOG"
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null
    [ "$ACTIVE_SCAN_PID" = "$pid" ] && ACTIVE_SCAN_PID=""
    rm -f "$CAM_LOG"
}

run_discovery() {
    iface="$1"
    log_line 1 "LAN口已插入 $iface"
    start_health "$iface"
    run_dhcp_detect "$iface"

    if ! discovery_enabled; then
        runtime_set "lan_discovery_status_state=设备发现未启用"
        return 0
    fi

    # 目标网段属于本次开机周期的持久状态。
    /usr/bin/lan_device_state.sh sync >/dev/null 2>&1 || :

    # Q7自身LAN网段不属于目标网段，不再写入DEVICE_DB，也不参与主动ARP扫描。

    # tcpdump负责实时发现全部活动IP/MAC；ARP与camdiscover仅作为低频主动补漏。
    # 主动扫描周期独立于单次响应窗口；平时只低频检查配置和链路，避免每秒重复轮询。
    sweep_cycle="$(cfg lan_discovery_sweep_cycle 120)"
    case "$sweep_cycle" in ''|*[!0-9]*) sweep_cycle=120;; esac
    [ "$sweep_cycle" -ge 30 ] 2>/dev/null || sweep_cycle=30
    [ "$sweep_cycle" -le 3600 ] 2>/dev/null || sweep_cycle=3600
    last_sweep=0

    while is_link_up "$iface"; do
        discovery_enabled || {
            runtime_set "lan_discovery_status_state=设备发现未启用"
            log_line 1 "LAN监听或设备发现已关闭"
            break
        }

        # 允许WebUI修改主动补漏周期，但不再每秒重复执行完整扫描。
        configured_sweep="$(cfg lan_discovery_sweep_cycle "$sweep_cycle")"
        case "$configured_sweep" in ''|*[!0-9]*) configured_sweep="$sweep_cycle";; esac
        [ "$configured_sweep" -ge 30 ] 2>/dev/null && [ "$configured_sweep" -le 3600 ] 2>/dev/null &&
            sweep_cycle="$configured_sweep"

        now_sec="$(date +%s 2>/dev/null)"
        case "$now_sec" in ''|*[!0-9]*) now_sec=0;; esac
        sweep_due=0
        [ "$last_sweep" = "0" ] && sweep_due=1
        if [ "$last_sweep" != "0" ] && [ $((now_sec - last_sweep)) -ge "$sweep_cycle" ] 2>/dev/null; then
            sweep_due=1
        fi

        if [ "$sweep_due" = "1" ]; then
            custom="$(nv lan_discovery_custom)"
            read_standard_config "$custom"
            cycle_start="$now_sec"

            # 首轮启动时上面已经完成DHCP检测；后续周期重新检测，
            # 这样交换机/上级网络稍后恢复DHCP时也能自动发现。
            if [ "$last_sweep" != "0" ]; then
                run_dhcp_detect "$iface"
            fi

            log_line 3 "低频主动补漏开始：ARP + 协议探测，周期=${sweep_cycle}s"
            if [ "$raw" = "1" ]; then
                /usr/bin/lan_device_state.sh begin
                localip="$(iface_ipv4 "$iface" | cut -d/ -f1)"
                localnet="$(printf '%s\n' "$localip" | awk -F. 'NF==4 {printf "%d.%d.%d.0",$1,$2,$3}')"
                run_arpscan "$iface" "$localnet"
            fi
            discover_cycle="$(cfg lan_discovery_cycle 10)"
            case "$discover_cycle" in ''|*[!0-9]*) discover_cycle=10;; esac
            [ "$discover_cycle" -ge 1 ] 2>/dev/null || discover_cycle=1
            [ "$discover_cycle" -le 3600 ] 2>/dev/null || discover_cycle=3600
            run_camdiscover "$iface" "$discover_cycle"
            if [ "$raw" = "1" ]; then
                /usr/bin/lan_device_state.sh finish
            fi

            /usr/bin/lan_device_state.sh sync >/dev/null 2>&1 || :
            # 这里才表示一轮真正的低频主动补漏已经完成。
            runtime_set "lan_discovery_sweep_complete=$cycle_start"
            last_sweep="$cycle_start"
            log_line 3 "低频主动补漏完成：下一轮约${sweep_cycle}s后开始"
        fi

        if ! is_link_up "$iface"; then
            break
        fi

        # supervisor负责1秒级插拔检测；worker空闲时只需每2秒检查一次状态。
        sleep 2
    done
    runtime_set "lan_discovery_status_state=等待接口"
}

cleanup() {
    if [ -n "$ACTIVE_SCAN_PID" ]; then
        kill "$ACTIVE_SCAN_PID" 2>/dev/null
        sleep 1
        kill -0 "$ACTIVE_SCAN_PID" 2>/dev/null && kill -9 "$ACTIVE_SCAN_PID" 2>/dev/null
        ACTIVE_SCAN_PID=""
    fi
    stop_health
    rm -f "$CUSTOM_TMP" "$CUSTOM_CONF" "$DHCP_LOG" "$ARP_LOG" "$CAM_LOG" "$RUNTIME_DIR/.arpscan_subnets.tmp"
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
[ -n "$(nv lan_discovery_probe_timeout)" ] || nvram set lan_discovery_probe_timeout=5
[ -n "$(nv lan_discovery_miss_limit)" ] || nvram set lan_discovery_miss_limit=3
[ -n "$(nv lan_discovery_sweep_cycle)" ] || nvram set lan_discovery_sweep_cycle=120
[ -n "$(nv lan_discovery_log_level)" ] || nvram set lan_discovery_log_level=1

iface="$(cfg lan_discovery_ifname eth2.1)"
last_iface=""
last_state="-1"

while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"

    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        log_line 1 "检测接口切换为 $iface"
    fi

    [ "$enable" = "1" ] || {
        runtime_set "lan_discovery_status_state=LAN监听已禁用"
        sleep 1
        continue
    }

    if is_link_up "$iface"; then link="UP"; state=1; else link="DOWN"; state=0; fi
    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then
            # 发现循环直接运行在worker进程中，禁止再派生脱离监督的后台run_discovery。
            run_discovery "$iface"
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
