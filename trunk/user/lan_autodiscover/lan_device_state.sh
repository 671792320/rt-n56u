#!/bin/sh
# LAN发现设备状态跟踪：以ARP发现轮次为准维护正常/冲突/离线状态。
# 不依赖WebUI刷新次数，状态保存在/tmp，设备记录仍由主发现程序维护。

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

# 命令：begin / arp IP MAC / proto IP TYPE / finish
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

    # 当前轮ARP结果：同IP多MAC直接进入冲突状态。
    awk -F'|' 'NF>=2 {ips[$1]=1; if($2!="-") mac[$1][$2]=1} END {for(ip in ips){n=0; m=""; for(x in mac[ip]){n++; m=m (m?" / ":"") x} status=(n>1?"IP冲突":"正常"); print ip "|" m "|" status "|0"}}' "$ARP_SEEN_FILE" |
    while IFS='|' read -r ip macs status miss; do
        [ -n "$ip" ] || continue
        old="$(grep "^$ip|" "$STATE_FILE" 2>/dev/null | head -n 1)"
        [ "$status" = "IP冲突" ] || status="正常"
        printf '%s|%s|%s|0\n' "$ip" "${macs:--}" "$status" >> "$tmp"
    done

    # 历史设备如果本轮没有ARP响应，miss++；达到3轮才进入暂时离线。
    while IFS='|' read -r ip mac status miss; do
        [ -n "$ip" ] || continue
        grep -q "^$ip|" "$ARP_SEEN_FILE" 2>/dev/null && continue
        case "$miss" in ''|*[!0-9]*) miss=0;; esac
        miss=$((miss + 1))
        [ "$status" = "IP冲突" ] && new_status="IP冲突" || new_status="正常"
        [ "$miss" -ge 3 ] && new_status="暂时离线"
        printf '%s|%s|%s|%s\n' "$ip" "${mac:--}" "$new_status" "$miss" >> "$tmp"
    done < "$STATE_FILE"

    sort -t'|' -k1,1 -u "$tmp" > "${tmp}.sort" 2>/dev/null && mv -f "${tmp}.sort" "$tmp"
    mv -f "$tmp" "$STATE_FILE"

    # 输出给WebUI：每个设备保留一条状态记录；协议信息从当前数据库合并。
    out="${DEVICE_DB}.status.tmp"
    : > "$out"
    while IFS='|' read -r ip mac status miss; do
        [ -n "$ip" ] || continue
        info=""
        protocols=""
        # 当前数据库里能够提供的协议标签。
        while IFS= read -r row; do
            type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
            [ -n "$type" ] || continue
            case "$type" in SUBNET|IP_CONFLICT|PROTO_FAIL|ARP) ;; *) protocols="$protocols${protocols:+ / }$type";; esac
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

    # 当前轮明确上报的协议探测异常才转换为协议异常，不把整个网络失败误算成设备离线。
    while IFS='|' read -r ip type; do
        [ -n "$ip" ] || continue
        grep -q "^$ip|" "$STATE_FILE" 2>/dev/null || continue
        sed -i "s/^DEVICE type=ARP IP=$ip /DEVICE type=ARP IP=$ip /" "$out" 2>/dev/null || :
        sed -i "s/ STATUS=正常 / STATUS=协议异常 /" "$out" 2>/dev/null || :
        sed -i "s/ INFO=[^ ]*/ INFO=协议探测无响应/" "$out" 2>/dev/null || :
    done < "$EVENT_FILE"

    # 保留没有ARP状态的协议记录（极少数仅协议可见设备）。
    awk '!seen[$3]++' "$out" > "${out}.uniq" 2>/dev/null || cp -f "$out" "${out}.uniq"
    mv -f "${out}.uniq" "$DEVICE_DB"
    ;;

esac
