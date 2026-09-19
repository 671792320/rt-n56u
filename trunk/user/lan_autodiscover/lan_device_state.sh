#!/bin/sh
# LAN发现设备状态跟踪：综合ARP、Ping和协议发现结果判断设备状态。
# 同一个IP最终只保留一条逻辑设备；WebUI通过相同IP合并ARP和各协议记录。
# MAC优先使用当前ARP或内核邻居表中的真实MAC，不允许协议记录中的MAC=-覆盖有效MAC。

RUNTIME_DIR=/tmp/lan_discovery_runtime
STATE_FILE="$RUNTIME_DIR/device_state.db"
ARP_SEEN_FILE="$RUNTIME_DIR/arp_seen.txt"
EVENT_FILE="$RUNTIME_DIR/device_protocol_events.txt"
DEVICE_DB=/tmp/lan_discovery_devices.txt
SUBNET_CACHE_FILE="$RUNTIME_DIR/subnet_records.cache"

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

DB_LOCKDIR="$RUNTIME_DIR/.lan_device_db.lock"

acquire_db_lock() {
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        if mkdir "$DB_LOCKDIR" 2>/dev/null; then
            printf '%s\n' "$" > "$DB_LOCKDIR/pid"
            return 0
        fi

        old_pid="$(cat "$DB_LOCKDIR/pid" 2>/dev/null)"
        case "$old_pid" in
            ''|*[!0-9]*) old_pid="";;
        esac

        if [ -z "$old_pid" ] || ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$DB_LOCKDIR/pid" 2>/dev/null
            rmdir "$DB_LOCKDIR" 2>/dev/null || :
            continue
        fi

        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

release_db_lock() {
    old_pid="$(cat "$DB_LOCKDIR/pid" 2>/dev/null)"
    if [ "$old_pid" = "$$" ]; then
        rm -f "$DB_LOCKDIR/pid" 2>/dev/null
        rmdir "$DB_LOCKDIR" 2>/dev/null
    fi
}

clean_device_line() {
    raw="$1"
    type="$(printf '%s\n' "$raw" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$raw" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$raw" | sed -n 's/.* MAC=\([^ ]*\).*/\1/p')"
    [ -n "$type" ] || type=IP
    [ -n "$ip" ] || return 1
    case "$ip" in
        *.*.*.*) ;;
        *) return 1;;
    esac
    mac="$(norm_mac "$mac")"
    if [ "$type" = "SUBNET" ]; then
        prefix="$(printf '%s\n' "$raw" | sed -n 's/.*INFO=\([0-9][0-9]*\).*/\1/p')"
        [ -n "$prefix" ] || prefix=24
        printf 'DEVICE type=SUBNET IP=%s INFO=%s' "$ip" "$prefix"
        return 0
    fi
    printf 'DEVICE type=%s IP=%s MAC=%s' "$type" "$ip" "$mac"
    info="$(printf '%s\n' "$raw" | sed -n 's/.*INFO=\(.*\)$/\1/p')"
    [ -n "$info" ] && printf ' INFO=%s' "$info"
}

upsert_device_record() {
    raw="$1"
    clean="$(clean_device_line "$raw")" || return 1
    ip="$(printf '%s\n' "$clean" | sed -n 's/.* IP=\([^ ]*\).*/\1/p')"
    new_mac="$(printf '%s\n' "$clean" | sed -n 's/.* MAC=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return 1

    old_mac="$(awk -v ip="$ip" '$0 ~ /DEVICE / && $0 !~ /type=SUBNET / && $0 !~ /type=IP_CONFLICT / && $0 ~ " IP=" ip " " {for(i=1;i<=NF;i++) if($i ~ /^MAC=/) {print substr($i,5); exit}}' "$DEVICE_DB" 2>/dev/null)"
    tmp="${DEVICE_DB}.state.tmp"

    # 最终设备表只允许本程序写入；同一IP更新时保留其它IP和SUBNET记录。
    awk -v ip="$ip" '{
        if ($0 ~ /type=SUBNET /) {print; next}
        if (index($0," IP=" ip " ") != 0) next
        print
    }' "$DEVICE_DB" 2>/dev/null > "$tmp"

    case "$clean" in
        *"type=SUBNET "*)
            printf '%s\n' "$clean" >> "$tmp"
            ;;
        *)
            printf '%s STATUS=在线 PING=未探测\n' "$clean" >> "$tmp"
            ;;
    esac

    if [ -n "$old_mac" ] && [ "$old_mac" != "-" ] &&
       [ -n "$new_mac" ] && [ "$new_mac" != "-" ] &&
       [ "$old_mac" != "$new_mac" ]; then
        printf 'DEVICE type=IP_CONFLICT IP=%s MAC=%s INFO=IP冲突：旧MAC=%s，新MAC=%s STATUS=在线 PING=未探测\n' \
            "$ip" "$new_mac" "$old_mac" "$new_mac" >> "$tmp"
    fi

    mv -f "$tmp" "$DEVICE_DB"
}

sort_device_db() {
    [ -f "$DEVICE_DB" ] || return
    tmp="${DEVICE_DB}.sort.tmp"
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
    case "$count" in ''|*[!0-9]*) count=0;; esac
    printf '%s' "$count"
}

append_subnet() {
    subnet="$1"
    case "$subnet" in
        *.*.*.0) ;;
        *) return 1;;
    esac
    grep -q "DEVICE type=SUBNET IP=${subnet} INFO=24" "$DEVICE_DB" 2>/dev/null && return 0
    printf 'DEVICE type=SUBNET IP=%s INFO=24\n' "$subnet" >> "$DEVICE_DB"
}

case "$1" in
record)
    line="$2"
    acquire_db_lock || exit 0
    upsert_device_record "$line"
    release_db_lock
    ;;

record_batch)
    batch_file="$2"
    [ -r "$batch_file" ] || exit 0
    acquire_db_lock || exit 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        upsert_device_record "$line" || :
    done < "$batch_file"
    sort_device_db
    release_db_lock
    ;;

subnet)
    subnet="$2"
    [ -n "$subnet" ] || exit 0
    acquire_db_lock || exit 0
    append_subnet "$subnet"
    sort_device_db
    release_db_lock
    ;;

realtime)
    ip="$2"
    mac="$3"
    source="$4"
    is_ip "$ip" || exit 0
    [ -n "$source" ] || source=TCP/IP
    acquire_db_lock || exit 0
    upsert_device_record "DEVICE type=$source IP=$ip MAC=$mac INFO=实时二层监听"
    release_db_lock
    ;;

sync)
    acquire_db_lock || exit 0
    count="$(sync_device_cache)"
    printf '%s' "$count" > "$RUNTIME_DIR/lan_discovery_status_count.tmp" &&
        mv -f "$RUNTIME_DIR/lan_discovery_status_count.tmp" "$RUNTIME_DIR/lan_discovery_status_count"
    release_db_lock
    ;;

begin)\n    # 开始新一轮检测，清空本轮ARP和协议事件。
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
    acquire_db_lock || exit 0
    tmp="${STATE_FILE}.state.tmp"
    candidate_ips="${RUNTIME_DIR}/candidate_ips.state.tmp"
    : > "$candidate_ips"

    # 目标网段记录不能随着设备状态重建而丢失。
    # run_arpscan下一轮正是依靠这些SUBNET记录继续扫描已发现的目标网段。
    grep '^DEVICE type=SUBNET ' "$DEVICE_DB" 2>/dev/null > "$SUBNET_CACHE_FILE" || :

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
        case "$old_miss" in ''|*[!0-9]*) old_miss=0;; esac

        # 只有本轮确实收到ARP或协议事件的IP才执行一次Ping。
        # 历史离线地址不再每轮全部Ping，避免设备和目标网段越多CPU越高。
        if [ "$current_arp" = "1" ] || [ "$current_proto" = "1" ]; then
            [ "$mac" != "-" ] || mac="$(get_neigh_mac "$ip")"
            ping_status="$(ping_device "$ip")"
        else
            ping_status="未探测"
        fi
        [ -n "$mac" ] || mac="-"

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

    # 关键修复：设备状态重建完成后恢复本轮之前已经发现的目标网段记录。
    # 否则下一轮arpscan只能看到本机网段，192.168.1.x/192.168.3.x等目标网段会从扫描列表消失。
    if [ -s "$SUBNET_CACHE_FILE" ]; then
        cat "$SUBNET_CACHE_FILE" >> "$out"
    fi
    rm -f "$SUBNET_CACHE_FILE"

    # 同一个目标网段只保留一条记录，避免重复追加。
    if [ -s "$out" ]; then
        awk '!seen[$0]++' "$out" > "${out}.uniq" 2>/dev/null && mv -f "${out}.uniq" "$out"
    fi

    mv -f "$out" "$DEVICE_DB"
    sync_device_cache >/dev/null 2>&1
    release_db_lock
    ;;
esac
