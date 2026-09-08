#!/bin/sh
# Q7 LAN临时接管：根据主动ARP发现的目标/24网段选择空闲地址，
# 给br0增加secondary IPv4，使后续三层/组播协议发现使用目标LAN源地址。
# 不修改NVRAM，不替换Padavan原有LAN主地址。再次调用本程序会替换上一次临时地址。

RUNTIME_DIR=/tmp/lan_discovery_runtime
TAKEOVER_FILE="$RUNTIME_DIR/lan_takeover.state"
USED_FILE="$RUNTIME_DIR/lan_takeover_used.txt"
LOGTAG=lan-autodiscover

runtime_set() {
    key="$1"
    value="$2"
    tmp="$RUNTIME_DIR/.${key}.tmp"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"
}

log() {
    logger -t "$LOGTAG" "[takeover] $*"
    printf '%s\n' "[takeover] $*"
}

valid_ip() {
    case "$1" in
        *.*.*.*) return 0;;
        *) return 1;;
    esac
}

normalize_network() {
    printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>=0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'
}

remove_existing() {
    if [ -r "$TAKEOVER_FILE" ]; then
        old_iface="$(sed -n 's/^iface=//p' "$TAKEOVER_FILE" | head -n 1)"
        old_ip="$(sed -n 's/^ip=//p' "$TAKEOVER_FILE" | head -n 1)"
        if valid_ip "$old_ip" && [ -n "$old_iface" ]; then
            ip addr del "$old_ip/24" dev "$old_iface" 2>/dev/null || :
        fi
    fi
    rm -f "$TAKEOVER_FILE" "$USED_FILE"
}

collect_used_ips() {
    : > "$USED_FILE"
    if [ -x /usr/bin/arpscan ]; then
        /usr/bin/arpscan -i "$IFACE" -t 2 -s "$NETWORK/24" 2>/dev/null |
            sed -n 's/^DEVICE type=[^ ]* IP=\([^ ]*\).*/\1/p' |
            sort -u > "$USED_FILE"
    fi
    # 本机现有IPv4也不能被选作空闲地址。
    ip -4 addr show dev "$BR_IF" 2>/dev/null |
        sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' >> "$USED_FILE"
    sort -u "$USED_FILE" -o "$USED_FILE"
}

is_used() {
    grep -qx "$1" "$USED_FILE" 2>/dev/null
}

find_free_ip() {
    octets="$(printf '%s\n' "$NETWORK" | awk -F. '{print $1,$2,$3}')"
    set -- $octets
    a="$1"; b="$2"; c="$3"
    # 网关/常见设备通常集中在低地址，高地址优先作为临时管理地址。
    for host in 250 249 248 247 246 245 244 243 242 241 240 239 238 237 236 235 234 233 232 231 230 229 228 227 226 225 224 223 222 221 220 219 218 217 216 215 214 213 212 211 210 209 208 207 206 205 204 203 202 201 200; do
        candidate="$a.$b.$c.$host"
        if ! is_used "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

IFACE="${1:-eth2.1}"
NETWORK_RAW="${2:-}"
mkdir -p "$RUNTIME_DIR"

case "$IFACE" in
    eth2.1|br0) ;;
    *) log "不支持的LAN接口：$IFACE"; exit 1;;
esac

NETWORK="$(normalize_network "$NETWORK_RAW")"
if [ -z "$NETWORK" ]; then
    log "无有效目标网段：$NETWORK_RAW"
    exit 1
fi

BR_IF=br0
[ -e "/sys/class/net/$BR_IF" ] || BR_IF="$IFACE"

remove_existing
collect_used_ips

FREE_IP="$(find_free_ip)"
if [ -z "$FREE_IP" ]; then
    log "${NETWORK}/24未找到可用空闲IP"
    exit 1
fi

if ip addr add "$FREE_IP/24" dev "$BR_IF" 2>/dev/null; then
    {
        printf 'iface=%s\n' "$BR_IF"
        printf 'ip=%s\n' "$FREE_IP"
        printf 'network=%s\n' "$NETWORK"
        printf 'created=%s\n' "$(date +%s)"
    } > "$TAKEOVER_FILE"
    runtime_set lan_discovery_status_target_network "$NETWORK/24"
    runtime_set lan_discovery_status_target_ip "$FREE_IP"
    runtime_set lan_discovery_status_target_iface "$BR_IF"
    log "LAN临时接管成功：$BR_IF $FREE_IP/24，目标网段=${NETWORK}/24"
    exit 0
fi

log "添加临时LAN地址失败：$BR_IF $FREE_IP/24"
exit 1
