#!/bin/sh
# LAN发现设备状态跟踪：以ARP发现轮次为准维护正常/冲突/离线状态。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/device_state.db"
ARP_SEEN_FILE="$RUNTIME_DIR/arp_seen.txt"
EVENT_FILE="$RUNTIME_DIR/device_protocol_events.txt"
DEVICE_DB=/tmp/lan_discovery_devices.txt

mkdir -p "$RUNTIME_DIR"
touch "$STATE_FILE" "$ARP_SEEN_FILE" "$EVENT_FILE"

norm_mac() {
    m="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/\\//g;s/[[:space:]]//g')"
    case "$m" in
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) printf '%s' "$m";;
        *) printf '%s' '-';;
    esac
}

case "$1" in
begin)
    : > "$ARP_SEEN_FILE"
    : > "$EVENT_FILE"
    ;;

arp)
    ip="$2"; mac="$(norm_mac "$3")"
    case "$ip" in *.*.*.*) ;; *) exit 0;; esac
    printf '%s|%s\n' "$ip" "$mac" >> "$ARP_SEEN_FILE"
    ;;

proto)
    ip="$2"; type="$3"
    case "$ip" in *.*.*.*) ;; *) exit 0;; esac
    [ -n "$type" ] || type=PROTO
    printf '%s|%s\n' "$ip" "$type" >> "$EVENT_FILE"
    ;;

finish)
    tmp="${STATE_FILE}.tmp"
    : > "$tmp"
    seen_ips="${ARP_SEEN_FILE}.ips"
    sort -t'|' -k1,1 -u "$ARP_SEEN_FILE" 2>/dev/null | cut -d'|' -f1 > "$seen_ips"

    # 当前轮：根据每个IP实际收到的ARP MAC数量判断冲突。
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        macs="$(grep "^$ip|" "$ARP_SEEN_FILE" 2>/dev/null | cut -d'|' -f2 | grep -v '^-$' | sort -u)
        count="$(printf '%s\n' "$macs" | grep -c ':' 2>/dev/null)"
        case "$count" in ''|*[!0-9]*) count=0;; esac
        mac="$(printf '%s\n' "$macs" | head -n 1)"
        [ -n "$mac" ] || mac="-"
        if [ "$count" -gt 1 ]; then status="IP冲突"; else status="正常"; fi
        printf '%s|%s|%s|0\n' "$ip" "$mac" "$status" >> "$tmp"
    done < "$seen_ips"

    # 历史设备：本轮无ARP响应则miss+1；连续3轮才离线。
    while IFS='|' read -r ip mac status miss; do
        [ -n "$ip" ] || continue
        grep -qx "$ip" "$seen_ips" 2>/dev/null && continue
        case "$miss" in ''|*[!0-9]*) miss=0;; esac
        miss=$((miss + 1))
        new_status="正常"
        [ "$status" = "IP冲突" ] && new_status="IP冲突"
        [ "$miss" -ge 3 ] && new_status="暂时离线"
        printf '%s|%s|%s|%s\n' "$ip" "${mac:--}" "$new_status" "$miss" >> "$tmp"
    done < "$STATE_FILE"

    sort -t'|' -k1,1 -u "$tmp" > "${tmp}.sort" 2>/dev/null && mv -f "${tmp}.sort" "$tmp"
    mv -f "$tmp" "$STATE_FILE"
    rm -f "$seen_ips"

    # 将状态投影回设备数据库。每个IP一条主记录，避免ARP记录被协议记录覆盖。
    out="${DEVICE_DB}.status.tmp"
    : > "$out"
    while IFS='|' read -r ip mac status miss; do
        [ -n "$ip" ] || continue
        protocols=""
        info=""
        while IFS= read -r row; do
            type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
            [ -n "$type" ] || continue
            case "$type" in
                SUBNET|IP_CONFLICT|PROTO_FAIL|ARP) ;;
                *) case " $protocols " in *" $type "*) ;; *) protocols="$protocols${protocols:+ / }$type";; esac ;;
            esac
            [ -z "$info" ] && info="$(printf '%s\n' "$row" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
        done <<EOF
$(grep " IP=$ip " "$DEVICE_DB" 2>/dev/null)
EOF
        [ -n "$protocols" ] || protocols="ARP"
        case "$status" in
            IP冲突) info="同IP多MAC";;
            暂时离线) info="连续3轮未响应";;
        esac
        printf 'DEVICE type=ARP IP=%s MAC=%s INFO=%s STATUS=%s PROTO=%s MISS=%s\n' "$ip" "${mac:--}" "${info:--}" "$status" "$protocols" "$miss" >> "$out"
    done < "$STATE_FILE"

    mv -f "$out" "$DEVICE_DB"
    ;;
esac
