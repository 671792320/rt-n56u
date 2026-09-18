#!/bin/sh
# Q7 LAN二层实时监听。
# 1. 持续监听ARP回复和IPv4活动，发现新IP/新MAC。
# 2. 同时统计广播帧速率。
# 3. 检测Q7自身MAC被重新收到的回流帧，用于判断疑似二层环路。
# 4. 健康状态写入NVRAM，WebUI实时显示。

RUNTIME_DIR=/tmp/lan_discovery_runtime
IFACE="${1:-eth2.1}"
LOCKDIR=/var/run/lan_tcpdump_listener.lock
STREAM_FIFO="$RUNTIME_DIR/lan_tcpdump_stream.fifo"
TCPDUMP_PIDFILE="$RUNTIME_DIR/lan_tcpdump_child.pid"
TCPDUMP_PID=""
EVENT_FILE="$RUNTIME_DIR/tcpdump_discovery_events.txt"
SEEN_FILE="$RUNTIME_DIR/tcpdump_seen.txt"
LOG_FILE=/tmp/lan_discovery.log
LOGTAG=lan-autodiscover
COOLDOWN=10
BROADCAST_THRESHOLD="$(nvram get lan_discovery_broadcast_threshold 2>/dev/null)"
LOOP_THRESHOLD="$(nvram get lan_discovery_loop_threshold 2>/dev/null)"
case "$BROADCAST_THRESHOLD" in ''|*[!0-9]*) BROADCAST_THRESHOLD=1000;; esac
case "$LOOP_THRESHOLD" in ''|*[!0-9]*) LOOP_THRESHOLD=10;; esac
[ "$BROADCAST_THRESHOLD" -ge 100 ] 2>/dev/null || BROADCAST_THRESHOLD=100
[ "$LOOP_THRESHOLD" -ge 1 ] 2>/dev/null || LOOP_THRESHOLD=1

mkdir -p "$RUNTIME_DIR"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    logger -t lan-autodiscover "LAN实时二层监听程序已经运行"
    exit 0
fi

cleanup() {
    if [ -n "$TCPDUMP_PID" ]; then
        kill "$TCPDUMP_PID" 2>/dev/null
        sleep 1
        kill -0 "$TCPDUMP_PID" 2>/dev/null && kill -9 "$TCPDUMP_PID" 2>/dev/null
    fi
    rm -f "$TCPDUMP_PIDFILE" "$STREAM_FIFO"
    rmdir "$LOCKDIR" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

touch "$EVENT_FILE" "$SEEN_FILE"

LOCAL_MAC="$(cat /sys/class/net/br0/address 2>/dev/null | tr '[:lower:]' '[:upper:]')"
LAST_HEALTH_SEC=""
BROADCAST_COUNT=0
LOOP_COUNT=0
LAST_HEALTH="未监视"

log() {
    msg="$(date '+%H:%M:%S') 【二层监听】$*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    logger -t "$LOGTAG" "$msg"
}

sync_web_log() {
    [ -r "$LOG_FILE" ] || return 0
    # 仅同步最近35行，避免NVRAM状态字段无限增长。
    nvram set lan_discovery_log="$(tail -n 35 "$LOG_FILE" 2>/dev/null)" 2>/dev/null || :
}

write_health() {
    health="$1"
    nvram set lan_discovery_status_health="$health" 2>/dev/null || :
    nvram set lan_discovery_status_broadcast="$BROADCAST_COUNT" 2>/dev/null || :
    nvram set lan_discovery_status_loop="$LOOP_COUNT" 2>/dev/null || :
    if [ "$health" != "$LAST_HEALTH" ]; then
        if [ "$health" = "OK" ]; then
            log "网络健康恢复正常：广播=${BROADCAST_COUNT}/s，MAC回流=${LOOP_COUNT}/s"
        else
            log "网络健康异常：状态=$health，广播=${BROADCAST_COUNT}/s，MAC回流=${LOOP_COUNT}/s"
        fi
        LAST_HEALTH="$health"
    fi
}

health_rollover() {
    now="$1"
    [ -n "$LAST_HEALTH_SEC" ] || { LAST_HEALTH_SEC="$now"; return 0; }
    [ "$now" = "$LAST_HEALTH_SEC" ] && return 0

    if [ "$BROADCAST_COUNT" -ge "$BROADCAST_THRESHOLD" ] 2>/dev/null && [ "$LOOP_COUNT" -ge "$LOOP_THRESHOLD" ] 2>/dev/null; then
        health="LOOP_BROADCAST"
    elif [ "$LOOP_COUNT" -ge "$LOOP_THRESHOLD" ] 2>/dev/null; then
        health="LOOP_SUSPECTED"
    elif [ "$BROADCAST_COUNT" -ge "$BROADCAST_THRESHOLD" ] 2>/dev/null; then
        health="BROADCAST_STORM"
    else
        health="OK"
    fi
    write_health "$health"

    # 每5秒同步一次页面实时日志；日志数据仍保留在/tmp文件中作为主记录。
    case "$now" in
        *0|*5) sync_web_log;;
    esac

    LAST_HEALTH_SEC="$now"
    BROADCAST_COUNT=0
    LOOP_COUNT=0
}

count_health_packet() {
    line="$1"
    now="$(date +%s 2>/dev/null)"
    case "$now" in ''|*[!0-9]*) return 0;; esac
    health_rollover "$now"

    case "$line" in
        *"> ff:ff:ff:ff:ff:ff"*|*"> FF:FF:FF:FF:FF:FF"*|*Broadcast*)
            BROADCAST_COUNT=$((BROADCAST_COUNT + 1))
            ;;
    esac

    if [ -n "$LOCAL_MAC" ]; then
        case "$line" in
            *"$LOCAL_MAC > "*|*"${LOCAL_MAC},"*) LOOP_COUNT=$((LOOP_COUNT + 1));;
        esac
    fi
}

init_health() {
    nvram set lan_discovery_status_health="未监视" 2>/dev/null || :
    nvram set lan_discovery_status_broadcast="0" 2>/dev/null || :
    nvram set lan_discovery_status_loop="0" 2>/dev/null || :
}

is_local_ip() {
    wanted="$1"
    ip -4 addr show dev br0 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' |
        grep -qx "$wanted" && return 0
    ip -4 addr show dev "$IFACE" 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' |
        grep -qx "$wanted" && return 0
    return 1
}

is_valid_unicast_ip() {
    ip="$1"
    case "$ip" in
        ''|0.0.0.0|255.255.255.255|127.*|224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|236.*|237.*|238.*|239.*) return 1;;
        *.*.*.*) ;;
        *) return 1;;
    esac
    last="${ip##*.}"
    case "$last" in ''|*[!0-9]*) return 1;; 0|255) return 1;; esac
    is_local_ip "$ip" && return 1
    return 0
}

normalize_mac() {
    m="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/\\//g')"
    case "$m" in
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) printf '%s' "$m";;
        *) printf '%s' '-';;
    esac
}

get_seen() {
    ip="$1"
    awk -F'|' -v ip="$ip" '$1==ip {print; exit}' "$SEEN_FILE" 2>/dev/null
}

should_emit() {
    ip="$1"
    mac="$2"
    now="$3"
    old="$(get_seen "$ip")"
    [ -n "$old" ] || return 0
    old_mac="$(printf '%s' "$old" | cut -d'|' -f2)"
    old_time="$(printf '%s' "$old" | cut -d'|' -f3)"
    [ "$old_mac" != "$mac" ] && return 0
    case "$old_time" in ''|*[!0-9]*) return 0;; esac
    [ $((now - old_time)) -ge "$COOLDOWN" ] 2>/dev/null && return 0
    return 1
}

save_seen() {
    ip="$1"
    mac="$2"
    now="$3"
    tmp="$SEEN_FILE.tmp"
    awk -F'|' -v ip="$ip" '$1!=ip {print}' "$SEEN_FILE" 2>/dev/null > "$tmp"
    printf '%s|%s|%s\n' "$ip" "$mac" "$now" >> "$tmp"
    tail -n 512 "$tmp" > "${tmp}.trim" 2>/dev/null && mv -f "${tmp}.trim" "$tmp"
    mv -f "$tmp" "$SEEN_FILE"
}

emit_event() {
    ip="$1"
    mac="$2"
    source="$3"
    [ -n "$ip" ] || return 0
    is_valid_unicast_ip "$ip" || return 0
    now="$(date +%s 2>/dev/null)"
    case "$now" in ''|*[!0-9]*) now=0;; esac
    should_emit "$ip" "$mac" "$now" || return 0
    save_seen "$ip" "$mac" "$now"
    printf '%s|%s|%s|%s\n' "$ip" "$mac" "$source" "$now" >> "$EVENT_FILE"
    tail -n 512 "$EVENT_FILE" > "${EVENT_FILE}.trim" 2>/dev/null && mv -f "${EVENT_FILE}.trim" "$EVENT_FILE"
    log "实时发现：IP=$ip MAC=$mac 来源=$source"
}

parse_arp() {
    line="$1"
    case "$line" in
        *" is-at "*) ip="$(printf '%s\n' "$line" | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) is-at .*/\1/p' | head -n 1)";;
        *) return 0;;
    esac
    mac="$(printf '%s\n' "$line" | sed -n 's/.*is-at \([0-9A-Fa-f:][0-9A-Fa-f:]*\).*/\1/p' | head -n 1)"
    [ -n "$mac" ] || mac="-"
    mac="$(normalize_mac "$mac")"
    [ "$mac" = "-" ] && [ -n "$ip" ] && mac="$(ip neigh show "$ip" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}' | tr '[:lower:]' '[:upper:]')"
    [ -n "$mac" ] || mac="-"
    emit_event "$ip" "$mac" "ARP"
}

parse_ip() {
    line="$1"
    src="$(printf '%s\n' "$line" | sed -n 's/.* IP \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]* > .*/\1/p' | head -n 1)"
    [ -n "$src" ] || src="$(printf '%s\n' "$line" | sed -n 's/.* IPv4 \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]* > .*/\1/p' | head -n 1)"
    [ -n "$src" ] || return 0
    mac="$(printf '%s\n' "$line" | sed -n 's/^.*[[:space:]]\([0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f:]*\)[[:space:]]*>.*$/\1/p' | head -n 1)"
    [ -n "$mac" ] || mac="-"
    mac="$(normalize_mac "$mac")"
    [ "$mac" = "-" ] && mac="$(ip neigh show "$src" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}' | tr '[:lower:]' '[:upper:]')"
    [ -n "$mac" ] || mac="-"
    emit_event "$src" "$mac" "TCP/IP"
}

[ -e "/sys/class/net/$IFACE" ] || { log "监听接口不存在：$IFACE"; exit 1; }

init_health
sync_web_log
log "启动实时二层监听：接口=$IFACE，本机MAC=$LOCAL_MAC，广播阈值=${BROADCAST_THRESHOLD}/s，回流阈值=${LOOP_THRESHOLD}/s"

TCPDUMP="$(command -v tcpdump 2>/dev/null)"
[ -n "$TCPDUMP" ] || TCPDUMP="/usr/sbin/tcpdump"
[ -x "$TCPDUMP" ] || { log "系统没有tcpdump，实时监听未启动"; exit 1; }

# tcpdump独立运行并记录PID，避免监督程序停止外层shell后留下孤儿tcpdump。
rm -f "$STREAM_FIFO"
if ! mkfifo "$STREAM_FIFO" 2>/dev/null; then
    log "无法创建实时监听FIFO，监听未启动"
    exit 1
fi

"$TCPDUMP" -l -n -e -i "$IFACE" 'arp[6:2] = 2 or ip' 2>/dev/null > "$STREAM_FIFO" &
TCPDUMP_PID=$!
printf '%s\n' "$TCPDUMP_PID" > "$TCPDUMP_PIDFILE"

while IFS= read -r line; do
    count_health_packet "$line"
    case "$line" in
        *ARP*) parse_arp "$line";;
        *" IP "*|*" IPv4 "*) parse_ip "$line";;
    esac
done < "$STREAM_FIFO"

exit 0
