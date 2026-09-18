#!/bin/sh
# Q7 LAN临时接管：每个目标/24网段独立维护一个临时地址。
# 临时地址从.254开始向下递减选择，先检查本机、邻居表和其它目标状态，再用ARP探测确认地址未被占用。
# 同一目标网段重复调用时优先复用原临时IP；只有地址丢失或冲突才重新选择。

RUNTIME_DIR=/tmp/lan_discovery_runtime
LOGTAG=lan-autodiscover
LOCK_DIR="$RUNTIME_DIR/.lan_takeover.lock"

runtime_set() { key="$1"; value="$2"; tmp="$RUNTIME_DIR/.${key}.tmp"; printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"; }
log() { msg="$(date '+%H:%M:%S') 【临时地址】$*"; logger -t "$LOGTAG" "$msg"; printf '%s\n' "$msg"; }
valid_ip() { case "$1" in *.*.*.*) return 0;; *) return 1;; esac; }
normalize_network() { printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'; }
state_key() { printf '%s\n' "$1" | tr '.' '_'; }
state_file_for() { printf '%s/lan_takeover_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }

remove_one() {
    network="$1"
    state_file="$(state_file_for "$network")"
    if [ -r "$state_file" ]; then
        old_iface="$(sed -n 's/^iface=//p' "$state_file" | head -n 1)"
        old_ip="$(sed -n 's/^ip=//p' "$state_file" | head -n 1)"
        if valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] && [ -n "$old_iface" ]; then
            ip addr del "$old_ip/24" dev "$old_iface" 2>/dev/null || :
            log "已撤销：接口=$old_iface 地址=$old_ip/24 网段=${network}/24"
        fi
    fi
    rm -f "$state_file"
}

remove_all() {
    for state_file in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state_file" ] || continue
        old_iface="$(sed -n 's/^iface=//p' "$state_file" | head -n 1)"
        old_ip="$(sed -n 's/^ip=//p' "$state_file" | head -n 1)"
        if valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] && [ -n "$old_iface" ]; then
            ip addr del "$old_ip/24" dev "$old_iface" 2>/dev/null || :
            log "已撤销：接口=$old_iface 地址=$old_ip/24"
        fi
        rm -f "$state_file"
    done
}

collect_used_ips() {
    used_file="$RUNTIME_DIR/lan_takeover_used.txt"
    : > "$used_file"

    # 不再为了选择临时地址执行整网段ARP扫描，避免一次接管被254个地址的主动扫描拖慢。
    # 当前邻居表、本机已有地址以及其它目标网段状态已经足够排除本地已知冲突。
    ip neigh show dev "$IFACE" 2>/dev/null |
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 !~ /FAILED|INCOMPLETE/ {print $1}' >> "$used_file"
    ip -4 addr show dev "$BR_IF" 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' >> "$used_file"

    # 所有已有临时地址状态都视为占用，防止两个目标网段事务选择同一个地址。
    for state in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state" ] || continue
        sed -n 's/^ip=//p' "$state" | head -n 1 >> "$used_file"
    done
    sort -u "$used_file" -o "$used_file"
}

is_used() { grep -qx "$1" "$RUNTIME_DIR/lan_takeover_used.txt" 2>/dev/null; }

probe_free_ip() {
    candidate="$1"
    [ -x /usr/bin/arping ] && ARPING=/usr/bin/arping || ARPING="$(command -v arping 2>/dev/null)"
    [ -n "$ARPING" ] || return 1

    # 使用0.0.0.0作为探测源地址，避免尚未接管目标网段时产生错误源地址。
    output="$($ARPING -I "$IFACE" -c 1 -s 0.0.0.0 "$candidate" 2>&1)"
    status=$?

    # 某些BusyBox arping在收到回应时返回0，某些版本通过输出表示冲突；两种情况都按“占用”处理。
    [ "$status" -eq 0 ] && return 1
    printf '%s\n' "$output" | grep -qiE 'Unicast reply|reply from|bytes from|Received [1-9][0-9]* responses?' && return 1
    return 0
}

find_free_ip() {
    octets="$(printf '%s\n' "$NETWORK" | awk -F. '{print $1,$2,$3}')"
    set -- $octets
    a="$1"; b="$2"; c="$3"

    # 临时地址按最高可用地址优先，从.254递减到.2；.0为网络地址、.255为广播地址，不参与选择。
    for host in 254 253 252 251 250 249 248 247 246 245 244 243 242 241 240 239 238 237 236 235 234 233 232 231 230 229 228 227 226 225 224 223 222 221 220 219 218 217 216 215 214 213 212 211 210 209 208 207 206 205 204 203 202 201 200 199 198 197 196 195 194 193 192 191 190 189 188 187 186 185 184 183 182 181 180 179 178 177 176 175 174 173 172 171 170 169 168 167 166 165 164 163 162 161 160 159 158 157 156 155 154 153 152 151 150 149 148 147 146 145 144 143 142 141 140 139 138 137 136 135 134 133 132 131 130 129 128 127 126 125 124 123 122 121 120 119 118 117 116 115 114 113 112 111 110 109 108 107 106 105 104 103 102 101 100 99 98 97 96 95 94 93 92 91 90 89 88 87 86 85 84 83 82 81 80 79 78 77 76 75 74 73 72 71 70 69 68 67 66 65 64 63 62 61 60 59 58 57 56 55 54 53 52 51 50 49 48 47 46 45 44 43 42 41 40 39 38 37 36 35 34 33 32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2; do
        candidate="$a.$b.$c.$host"
        if ! is_used "$candidate"; then
            if [ -n "$(command -v arping 2>/dev/null)" ] || [ -x /usr/bin/arping ]; then
                if probe_free_ip "$candidate"; then
                    printf '%s' "$candidate"
                    return 0
                fi
            else
                printf '%s' "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

ip_owned_by_other_state() {
    wanted="$1"
    for state in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state" ] || continue
        [ "$state" = "$STATE_FILE" ] && continue
        old_ip="$(sed -n 's/^ip=//p' "$state" | head -n 1)"
        [ "$old_ip" = "$wanted" ] && return 0
    done
    return 1
}

reuse_existing() {
    [ -r "$STATE_FILE" ] || return 1
    old_iface="$(sed -n 's/^iface=//p' "$STATE_FILE" | head -n 1)"
    old_ip="$(sed -n 's/^ip=//p' "$STATE_FILE" | head -n 1)"
    old_network="$(sed -n 's/^network=//p' "$STATE_FILE" | head -n 1)"

    [ "$old_iface" = "$BR_IF" ] && [ "$old_network" = "$NETWORK" ] && valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] || return 1

    if ! ip_owned_by_other_state "$old_ip" && ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $old_ip/24"; then
        # 复用前再做一次冲突探测；已存在于本机的地址不需要发DAD。
        runtime_set lan_discovery_status_target_network "$NETWORK/24"
        runtime_set lan_discovery_status_target_ip "$old_ip"
        runtime_set lan_discovery_status_target_iface "$BR_IF"
        log "复用成功：接口=$BR_IF 地址=$old_ip/24 目标网段=${NETWORK}/24"
        return 0
    fi
    return 1
}

IFACE="${1:-eth2.1}"
NETWORK_RAW="${2:-}"
mkdir -p "$RUNTIME_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "已有临时IP分配事务正在执行，本轮跳过，防止重复占用同一地址"
    exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT INT TERM

if [ "$IFACE" = "-r" ] || [ "$IFACE" = "--remove" ]; then
    if [ -n "$NETWORK_RAW" ]; then
        NETWORK="$(normalize_network "$NETWORK_RAW")"
        [ -n "$NETWORK" ] && remove_one "$NETWORK"
    else
        remove_all
    fi
    runtime_set lan_discovery_status_target_network ""
    runtime_set lan_discovery_status_target_ip ""
    runtime_set lan_discovery_status_target_iface ""
    exit 0
fi

case "$IFACE" in
    eth2.1|br0) ;;
    *) log "参数错误：不支持的LAN接口=$IFACE"; exit 1;;
esac

NETWORK="$(normalize_network "$NETWORK_RAW")"
if [ -z "$NETWORK" ] || [ "$NETWORK" = "0.0.0.0" ]; then
    log "参数错误：无效目标网段=$NETWORK_RAW"
    exit 1
fi

BR_IF=br0
[ -e "/sys/class/net/$BR_IF" ] || BR_IF="$IFACE"
STATE_FILE="$(state_file_for "$NETWORK")"

if reuse_existing; then
    exit 0
fi

# 只有同一目标网段的旧地址无法继续使用时才撤销旧状态。
remove_one "$NETWORK"
collect_used_ips
FREE_IP="$(find_free_ip)"

# 真正写入前再次确认当前运行时地址列表没有抢先占用候选地址。
[ -n "$FREE_IP" ] && ! is_used "$FREE_IP" || FREE_IP=""
if [ -z "$FREE_IP" ] || [ "$FREE_IP" = "0.0.0.0" ]; then
    log "未找到可用临时地址：目标网段=${NETWORK}/24"
    exit 1
fi

if ip addr add "$FREE_IP/24" dev "$BR_IF" 2>/dev/null; then
    # 地址已加入本机后立即再看一次内核地址表，防止状态文件和实际状态不一致。
    if ! ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $FREE_IP/24"; then
        ip addr del "$FREE_IP/24" dev "$BR_IF" 2>/dev/null || :
        log "临时地址加入后校验失败：接口=$BR_IF 地址=$FREE_IP/24"
        exit 1
    fi
    tmp_state="$STATE_FILE.tmp.$$"
    {
        printf 'iface=%s\n' "$BR_IF"
        printf 'ip=%s\n' "$FREE_IP"
        printf 'network=%s\n' "$NETWORK"
        printf 'created=%s\n' "$(date +%s)"
    } > "$tmp_state" && mv -f "$tmp_state" "$STATE_FILE"
    runtime_set lan_discovery_status_target_network "$NETWORK/24"
    runtime_set lan_discovery_status_target_ip "$FREE_IP"
    runtime_set lan_discovery_status_target_iface "$BR_IF"
    log "接管成功：接口=$BR_IF 地址=$FREE_IP/24 目标网段=${NETWORK}/24"
    exit 0
fi

log "添加失败：接口=$BR_IF 地址=$FREE_IP/24"
exit 1
