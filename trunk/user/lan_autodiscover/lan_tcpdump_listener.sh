#!/bin/sh
# Q7 LAN二层实时监听：tcpdump持续监听ARP回复和IPv4活动，只记录“新IP/新MAC/新发现”事件。
# 实时监听只负责发现，不直接维护SNAT；网络管理器读取统一事件文件后立即接管目标网段。
# 不监听ARP请求，避免把Q7自己的主动ARP扫描请求误判为设备；同时过滤Q7当前所有本机IPv4地址。

RUNTIME_DIR=/tmp/lan_discovery_runtime
IFACE="${1:-eth2.1}"
EVENT_FILE="$RUNTIME_DIR/tcpdump_discovery_events.txt"
SEEN_FILE="$RUNTIME_DIR/tcpdump_seen.txt"
LOGTAG=lan-autodiscover
COOLDOWN=10

mkdir -p "$RUNTIME_DIR"
touch "$EVENT_FILE" "$SEEN_FILE"

log() {
    msg="$(date '+%H:%M:%S') 【二层监听】$*"
    printf '%s\n' "$msg" >> /tmp/lan_discovery.log
    logger -t "$LOGTAG" "$msg"
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
        *" is-at "*)
            ip="$(printf '%s\n' "$line" | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) is-at .*/\1/p' | head -n 1)"
            ;;
        *)
            return 0
            ;;
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

log "启动实时二层监听：接口=$IFACE"

TCPDUMP="$(command -v tcpdump 2>/dev/null)"
[ -n "$TCPDUMP" ] || TCPDUMP="/usr/sbin/tcpdump"
[ -x "$TCPDUMP" ] || { log "系统没有tcpdump，实时监听未启动"; exit 1; }

# tcpdump持续监听；只捕获ARP回复和IPv4，避免把Q7自己的ARP请求作为设备发现。
"$TCPDUMP" -l -n -e -i "$IFACE" 'arp[6:2] = 2 or ip' 2>/dev/null |
while IFS= read -r line; do
    case "$line" in
        *ARP*) parse_arp "$line";;
        *" IP "*|*" IPv4 "*) parse_ip "$line";;
    esac
done

exit 0
