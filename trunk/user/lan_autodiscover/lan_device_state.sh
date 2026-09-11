#!/bin/sh
# LAN发现设备状态跟踪：综合ARP、Ping和协议发现结果判断设备状态。
# 同一个IP最终只保留一条逻辑设备；WebUI通过相同IP合并ARP和各协议记录。
# MAC优先使用当前ARP或内核邻居表中的真实MAC，不允许协议记录中的MAC=-覆盖有效MAC。

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

# 从内核邻居表补充MAC，适用于ARP扫描回包刚到过、但本轮状态记录没有保存MAC的情况。
get_neigh_mac() {
    ip="$1"
    mac="$(ip neigh show "$ip" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}')"
    norm_mac "$mac"
}

# Ping仅作为独立探测结果显示，不作为唯一在线依据。
ping_device() {
    ip="$1"
    ping_bin=""

    for candidate in /bin/ping /sbin/ping /usr/bin/ping /usr/sbin/ping; do
        if [ -x "$candidate" ]; then
            ping_bin="$candidate"
            break
        fi
    done

    if [ -z "$ping_bin" ] && command -v ping >/dev/null 2>&1; then
        ping_bin="$(command -v ping)"
    fi

    if [ -n "$ping_bin" ]; then
        if "$ping_bin" -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            printf '通'
            return 0
        fi
        printf '不通'
        return 1
    fi

    if command -v busybox >/dev/null 2>&1; then
        if busybox ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            printf '通'
            return 0
        fi
        # BusyBox存在但没有ping applet时，继续标记为不可用。
        if busybox ping --help >/dev/null 2>&1; then
            printf '不通'
            return 1
        fi
    fi

    printf '不可用'
    return 2
}

is_ip() {
    ip="$1"
    case "$ip" in *.*.*.*) ;; *) return 1;; esac
    last="${ip##*.}"
    case "$last" in
        ''|*[!0-9]*) return 1;;
        0|255) return 1;;
    esac
    return 0
}

add_protocol() {
    list="$1"
    item="$2"
    [ -n "$item" ] || return 0
    case " $list " in
        *" $item "*) printf '%s' "$list";;
        *) printf '%s' "${list}${list:+ / }$item";;
    esac
}

case "$1" in
begin)
    # 开始新一轮检测，清空本轮ARP和协议事件。
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

    # 候选设备来自本轮ARP、本轮协议事件、历史状态以及设备数据库。
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
        fi
        [ -n "$mac" ] || mac="-"

        # 本轮协议事件由调用方通过proto动作写入；多个协议只算一个在线依据。
        if grep -q "^$ip|" "$EVENT_FILE" 2>/dev/null; then
            current_proto=1
        fi

        old="$(grep "^$ip|" "$STATE_FILE" 2>/dev/null | head -n 1)"
        old_mac="$(printf '%s' "$old" | cut -d'|' -f2)"
        old_status="$(printf '%s' "$old" | cut -d'|' -f3)"
        old_miss="$(printf '%s' "$old" | cut -d'|' -f4)"
        [ "$mac" != "-" ] || mac="${old_mac:--}"
        [ "$mac" != "-" ] || mac="$(get_neigh_mac "$ip")"
        [ -n "$mac" ] || mac="-"
        case "$old_miss" in ''|*[!0-9]*) old_miss=0;; esac

        ping_status="$(ping_device "$ip")"

        # 当前轮只要ARP、协议响应或Ping任一项成功，就认为设备在线。
        if [ "$current_arp" = "1" ] || [ "$current_proto" = "1" ] || [ "$ping_status" = "通" ]; then
            status="在线"
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

    # 重新生成设备数据库：同一个IP只建立一个ARP主记录，并额外保留协议记录供WebUI按IP合并。
    # 在线时输出ARP主记录，这样WebUI可以利用当前轮在线证据；协议记录随后按IP自动合并到同一行。
    out="${DEVICE_DB}.status.tmp"
    : > "$out"
    while IFS='|' read -r ip mac status miss ping_status; do
        [ -n "$ip" ] || continue
        [ -n "$ping_status" ] || ping_status="不可用"

        protocols=""
        info=""
        old_mac="-"

        # 从原数据库提取协议、信息和有效MAC。
        while IFS= read -r row; do
            type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
            row_mac="$(printf '%s\n' "$row" | sed -n 's/.* MAC=\([^ ]*\).*/\1/p')"
            row_mac="$(norm_mac "$row_mac")"
            [ "$old_mac" != "-" ] || [ "$row_mac" = "-" ] || old_mac="$row_mac"

            case "$type" in
                SUBNET|IP_CONFLICT|PROTO_FAIL|ARP|"") ;;
                *) protocols="$(add_protocol "$protocols" "$type")";;
            esac

            detail="$(printf '%s\n' "$row" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
            # INFO只保存设备描述；历史轮次附加的Ping/STATUS/PING/MISS一律剥离。
            detail="$(printf '%s\n' "$detail" | sed 's/^Ping：[[:space:]]*[^；]*；[[:space:]]*//;s/[[:space:]]*STATUS=[^ ]*//g;s/[[:space:]]*PING=[^ ]*//g;s/[[:space:]]*MISS=[0-9][0-9]*//g;s/[[:space:]]*$//')"
            case "$detail" in
                ''|-|设备可达) ;;
                *)
                    case "$info" in
                        '') info="$detail";;
                    esac
                    ;;
            esac
        done <<EOF
$(grep " IP=$ip " "$DEVICE_DB" 2>/dev/null)
EOF

        [ "$mac" != "-" ] || mac="$old_mac"
        [ "$mac" != "-" ] || mac="$(get_neigh_mac "$ip")"
        [ -n "$mac" ] || mac="-"
        [ -n "$protocols" ] || protocols="ARP"

        # 输出中文状态信息；Ping作为独立状态字段保留在记录中。
        case "$status" in
            在线)
                if [ -n "$info" ] && [ "$info" != "-" ]; then
                    info="Ping：${ping_status}；${info}"
                else
                    info="Ping：${ping_status}；设备可达"
                fi
                ;;
            IP冲突) info="Ping：${ping_status}；同IP多MAC";;
            暂时离线) info="Ping：${ping_status}；连续${miss}轮无ARP、协议和Ping响应";;
            *) info="Ping：${ping_status}；${info:--}";;
        esac

        # 在线设备输出ARP主记录，协议发现结果另外输出；WebUI会按IP合并成一行。
        if [ "$status" = "在线" ]; then
            printf 'DEVICE type=ARP IP=%s MAC=%s INFO=%s STATUS=%s PING=%s MISS=%s\n' \
                "$ip" "${mac:--}" "$info" "$status" "$ping_status" "$miss" >> "$out"

            # 仅显示已有协议，不把ARP重复添加到协议列表。
            old_records="$(grep " IP=$ip " "$DEVICE_DB" 2>/dev/null)"
            printf '%s\n' "$old_records" | while IFS= read -r row; do
                type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                case "$type" in
                    SUBNET|IP_CONFLICT|PROTO_FAIL|ARP|'') ;;
                    *)
                        row_info="$(printf '%s\n' "$row" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
                        [ -n "$row_info" ] || row_info="设备协议响应"
                        printf 'DEVICE type=%s IP=%s MAC=%s INFO=%s PING=%s STATUS=在线\n' \
                            "$type" "$ip" "${mac:--}" "$row_info" "$ping_status" >> "$out"
                        ;;
                esac
            done
        else
            # 离线设备不输出虚假的ARP在线记录，避免WebUI把它当成当前在线。
            old_records="$(grep " IP=$ip " "$DEVICE_DB" 2>/dev/null)"
            printf '%s\n' "$old_records" | while IFS= read -r row; do
                type="$(printf '%s\n' "$row" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
                case "$type" in
                    SUBNET|IP_CONFLICT|PROTO_FAIL|ARP|'') ;;
                    *)
                        row_info="$(printf '%s\n' "$row" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
                        [ -n "$row_info" ] || row_info="历史协议记录"
                        printf 'DEVICE type=%s IP=%s MAC=%s INFO=%s PING=%s STATUS=%s MISS=%s\n' \
                            "$type" "$ip" "${mac:--}" "$row_info" "$ping_status" "$status" "$miss" >> "$out"
                        ;;
                esac
            done
            # 如果没有任何历史协议记录，保留一条ARP状态记录用于显示离线IP和MAC。
            if ! grep -q " IP=$ip " "$out" 2>/dev/null; then
                printf 'DEVICE type=ARP IP=%s MAC=%s INFO=%s STATUS=%s PING=%s MISS=%s\n' \
                    "$ip" "${mac:--}" "$info" "$status" "$ping_status" "$miss" >> "$out"
            fi
        fi
    done < "$STATE_FILE"

    mv -f "$out" "$DEVICE_DB"
    ;;
esac
