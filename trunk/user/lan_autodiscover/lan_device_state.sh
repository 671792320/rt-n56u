#!/bin/sh
# LAN发现设备状态跟踪：以当前轮ARP、协议响应和Ping结果综合判断在线状态。
# 同一个IP始终只保留一条设备记录，协议、Ping和状态统一写入这一条记录。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/device_state.db"
ARP_SEEN_FILE="$RUNTIME_DIR/arp_seen.txt"
EVENT_FILE="$RUNTIME_DIR/device_protocol_events.txt"
DEVICE_DB=/tmp/lan_discovery_devices.txt

mkdir -p "$RUNTIME_DIR"
touch "$STATE_FILE" "$ARP_SEEN_FILE" "$EVENT_FILE" "$DEVICE_DB"

norm_mac() {
    m="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/\\//g;s/[[:space:]]//g')"
    case "$m" in
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) printf '%s' "$m";;
        *) printf '%s' '-';;
    esac
}

ping_device() {
    ip="$1"
    command -v ping >/dev/null 2>&1 || return 2
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1
}

is_ip() {
    case "$1" in *.*.*.*) return 0;; *) return 1;; esac
}

case "$1" in
begin)
    # 开始新一轮检测，清空本轮ARP和协议响应记录。
    : > "$ARP_SEEN_FILE"
    : > "$EVENT_FILE"
    ;;

arp)
    ip="$2"
    mac="$(norm_mac "$3")"
    is_ip "$ip" || exit 0
    printf '%s|%s\n' "$ip" "$mac" >> "$ARP_SEEN_FILE"
    ;;

proto)
    ip="$2"
    type="$3"
    is_ip "$ip" || exit 0
    [ -n "$type" ] || type=PROTO
    printf '%s|%s\n' "$ip" "$type" >> "$EVENT_FILE"
    ;;

finish)
    tmp="${STATE_FILE}.tmp"
    candidate_ips="${RUNTIME_DIR}/candidate_ips.tmp"
    : > "$candidate_ips"

    # 候选IP来自：本轮ARP、本轮协议响应、历史设备以及当前设备数据库。
    cat "$ARP_SEEN_FILE" 2>/dev/null | cut -d'|' -f1 >> "$candidate_ips"
    cat "$EVENT_FILE" 2>/dev/null | cut -d'|' -f1 >> "$candidate_ips"
    cut -d'|' -f1 "$STATE_FILE" 2>/dev/null >> "$candidate_ips"
    sed -n 's/.* IP=\([^ ]*\).*/\1/p' "$DEVICE_DB" 2>/dev/null >> "$candidate_ips"
    sort -u "$candidate_ips" > "${candidate_ips}.sort" 2>/dev/null && mv -f "${candidate_ips}.sort" "$candidate_ips"

    : > "$tmp"
    while IFS= read -r ip; do
        is_ip "$ip" || continue

        current_arp=0
        current_proto=0
        mac="-"

        if grep -q "^$ip|" "$ARP_SEEN_FILE" 2>/dev/null; then
            current_arp=1
            mac="$(grep "^$ip|" "$ARP_SEEN_FILE" 2>/dev/null | cut -d'|' -f2 | grep -v '^-$' | sort -u | head -n 1)"
            [ -n "$mac" ] || mac="-"
        fi

        if grep -q "^$ip|" "$EVENT_FILE" 2>/dev/null; then
            current_proto=1
        fi

        old="$(grep "^$ip|" "$STATE_FILE" 2>/dev/null | head -n 1)"
        old_mac="$(printf '%s' "$old" | cut -d'|' -f2)"
        old_status="$(printf '%s' "$old" | cut -d'|' -f3)"
        old_miss="$(printf '%s' "$old" | cut -d'|' -f4)"
        old_ping="$(printf '%s' "$old" | cut -d'|' -f5)"
        [ -n "$mac" ] && [ "$mac" != "-" ] || mac="${old_mac:--}"
        case "$old_miss" in ''|*[!0-9]*) old_miss=0;; esac

        ping_status="不通"
        if ping_device "$ip"; then
            ping_status="通"
        elif ! command -v ping >/dev/null 2>&1; then
            ping_status="不可用"
        fi

        # 当前轮只要ARP、协议响应或Ping任一项成功，就视为在线。
        if [ "$current_arp" = "1" ] || [ "$current_proto" = "1" ] || [ "$ping_status" = "通" ]; then
            status="正常"
            miss=0
        else
            miss=$((old_miss + 1))
            status="正常"
            [ "$old_status" = "IP冲突" ] && status="IP冲突"
            [ "$miss" -ge 3 ] && status="暂时离线"
        fi

        printf '%s|%s|%s|%s|%s\n' "$ip" "${mac:--}" "$status" "$miss" "$ping_status" >> "$tmp"
    done < "$candidate_ips"

    sort -t'|' -k1,1 -u "$tmp" > "${tmp}.sort" 2>/dev/null && mv -f "${tmp}.sort" "$tmp"
    mv -f "$tmp" "$STATE_FILE"
    rm -f "$candidate_ips"

    # 重新生成设备数据库：每个IP只保留一条记录，并合并本轮协议与Ping结果。
    out="${DEVICE_DB}.status.tmp"
    : > "$out"
    while IFS='|' read -r ip mac status miss ping_status; do
        [ -n "$ip" ] || continue
        [ -n "$ping_status" ] || ping_status="不可用"

        protocols=""
        info=""

        # 优先读取本轮协议响应；如果本轮没有协议响应，再保留数据库里的协议记录用于展示。
        while IFS= read -r row; do
            type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
            case "$type" in
                SUBNET|IP_CONFLICT|PROTO_FAIL|ARP|"") ;;
                *)
                    case " $protocols " in
                        *" $type "*) ;;
                        *) protocols="$protocols${protocols:+ / }$type";;
                    esac
                    ;;
            esac
            if [ -z "$info" ]; then
                info="$(printf '%s\n' "$row" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
            fi
        done <<EOF
$(grep " IP=$ip " "$DEVICE_DB" 2>/dev/null)
EOF

        current_protocols=""
        while IFS='|' read -r event_ip event_type; do
            [ "$event_ip" = "$ip" ] || continue
            case " $current_protocols " in
                *" $event_type "*) ;;
                *) current_protocols="$current_protocols${current_protocols:+ / }$event_type";;
            esac
        done < "$EVENT_FILE"
        [ -n "$current_protocols" ] && protocols="$current_protocols"
        [ -n "$protocols" ] || protocols="ARP"

        case "$status" in
            IP冲突) info="同IP多MAC";;
            暂时离线) info="连续3轮无ARP、协议和Ping响应";;
        esac

        printf 'DEVICE type=ARP IP=%s MAC=%s INFO=%s STATUS=%s PROTO=%s PING=%s MISS=%s\n' \
            "$ip" "${mac:--}" "${info:--}" "$status" "$protocols" "$ping_status" "$miss" >> "$out"
    done < "$STATE_FILE"

    mv -f "$out" "$DEVICE_DB"
    ;;
esac
