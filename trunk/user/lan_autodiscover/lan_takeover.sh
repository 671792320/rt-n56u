#!/bin/sh
# Q7 LAN临时接管：每个目标/24网段独立维护一个临时地址。
# 同一目标网段重复调用时复用原临时IP，只有首次出现或地址丢失才重新选择。

RUNTIME_DIR=/tmp/lan_discovery_runtime
LOGTAG=lan-autodiscover
runtime_set() { key="$1"; value="$2"; tmp="$RUNTIME_DIR/.${key}.tmp"; printf '%s' "$value" > "$tmp" && mv -f "$tmp" "$RUNTIME_DIR/$key"; }
log() { msg="$(date '+%H:%M:%S') 【临时地址】$*"; logger -t "$LOGTAG" "$msg"; printf '%s\n' "$msg"; }
valid_ip() { case "$1" in *.*.*.*) return 0;; *) return 1;; esac; }
normalize_network() { printf '%s\n' "$1" | awk -F. 'NF==4 && $1+0>0 && $1+0<=255 && $2+0>=0 && $2+0<=255 && $3+0>=0 && $3+0<=255 && $4+0>=0 && $4+0<=255 {printf "%d.%d.%d.0",$1,$2,$3}'; }
state_key() { printf '%s\n' "$1" | tr '.' '_'; }
state_file_for() { printf '%s/lan_takeover_%s.state\n' "$RUNTIME_DIR" "$(state_key "$1")"; }
remove_one() {
    network="$1"; state_file="$(state_file_for "$network")"
    if [ -r "$state_file" ]; then
        old_iface="$(sed -n 's/^iface=//p' "$state_file" | head -n 1)"; old_ip="$(sed -n 's/^ip=//p' "$state_file" | head -n 1)"
        if valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] && [ -n "$old_iface" ]; then ip addr del "$old_ip/24" dev "$old_iface" 2>/dev/null || :; log "已撤销：接口=$old_iface 地址=$old_ip/24 网段=${network}/24"; fi
    fi
    rm -f "$state_file"
}
remove_all() {
    for state_file in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state_file" ] || continue
        old_iface="$(sed -n 's/^iface=//p' "$state_file" | head -n 1)"; old_ip="$(sed -n 's/^ip=//p' "$state_file" | head -n 1)"
        if valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] && [ -n "$old_iface" ]; then ip addr del "$old_ip/24" dev "$old_iface" 2>/dev/null || :; log "已撤销：接口=$old_iface 地址=$old_ip/24"; fi
        rm -f "$state_file"
    done
}
collect_used_ips() {
    used_file="$RUNTIME_DIR/lan_takeover_used.txt"; : > "$used_file"
    if [ -x /usr/bin/arpscan ]; then /usr/bin/arpscan -i "$IFACE" -t 2 -s "$NETWORK/24" 2>/dev/null | sed -n 's/^DEVICE type=[^ ]* IP=\([^ ]*\).*/\1/p' >> "$used_file"; fi
    ip neigh show dev "$IFACE" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 != "FAILED" {print $1}' >> "$used_file"
    ip -4 addr show dev "$BR_IF" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([0-9.]*\)\/.*$/\1/p' >> "$used_file"
    sort -u "$used_file" -o "$used_file"
}
is_used() { grep -qx "$1" "$RUNTIME_DIR/lan_takeover_used.txt" 2>/dev/null; }
probe_free_ip() {
    candidate="$1"; [ -x /usr/bin/arping ] && ARPING=/usr/bin/arping || ARPING="$(command -v arping 2>/dev/null)"; [ -n "$ARPING" ] || return 1
    output="$($ARPING -I "$IFACE" -c 1 -s 0.0.0.0 "$candidate" 2>&1)"; status=$?; [ "$status" -eq 0 ] && return 1
    printf '%s\n' "$output" | grep -qiE 'Unicast reply|reply from|bytes from' && return 1
    return 0
}
find_free_ip() {
    octets="$(printf '%s\n' "$NETWORK" | awk -F. '{print $1,$2,$3}')"; set -- $octets; a="$1"; b="$2"; c="$3"
    for host in 250 249 248 247 246 245 244 243 242 241 240 239 238 237 236 235 234 233 232 231 230 229 228 227 226 225 224 223 222 221 220 219 218 217 216 215 214 213 212 211 210 209 208 207 206 205 204 203 202 201 200; do
        candidate="$a.$b.$c.$host"
        if ! is_used "$candidate"; then
            if [ -n "$(command -v arping 2>/dev/null)" ] || [ -x /usr/bin/arping ]; then probe_free_ip "$candidate" && { printf '%s' "$candidate"; return 0; }; else printf '%s' "$candidate"; return 0; fi
        fi
    done
    return 1
}
reuse_existing() {
    [ -r "$STATE_FILE" ] || return 1
    old_iface="$(sed -n 's/^iface=//p' "$STATE_FILE" | head -n 1)"; old_ip="$(sed -n 's/^ip=//p' "$STATE_FILE" | head -n 1)"; old_network="$(sed -n 's/^network=//p' "$STATE_FILE" | head -n 1)"
    [ "$old_iface" = "$BR_IF" ] && [ "$old_network" = "$NETWORK" ] && valid_ip "$old_ip" && [ "$old_ip" != "0.0.0.0" ] || return 1
    if ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $old_ip/24"; then
        runtime_set lan_discovery_status_target_network "$NETWORK/24"; runtime_set lan_discovery_status_target_ip "$old_ip"; runtime_set lan_discovery_status_target_iface "$BR_IF"; log "复用成功：接口=$BR_IF 地址=$old_ip/24 目标网段=${NETWORK}/24"; return 0
    fi
    return 1
}
IFACE="${1:-eth2.1}"; NETWORK_RAW="${2:-}"; mkdir -p "$RUNTIME_DIR"
if [ "$IFACE" = "-r" ] || [ "$IFACE" = "--remove" ]; then
    if [ -n "$NETWORK_RAW" ]; then NETWORK="$(normalize_network "$NETWORK_RAW")"; [ -n "$NETWORK" ] && remove_one "$NETWORK"; else remove_all; fi
    runtime_set lan_discovery_status_target_network ""; runtime_set lan_discovery_status_target_ip ""; runtime_set lan_discovery_status_target_iface ""; exit 0
fi
case "$IFACE" in eth2.1|br0) ;; *) log "参数错误：不支持的LAN接口=$IFACE"; exit 1;; esac
NETWORK="$(normalize_network "$NETWORK_RAW")"
if [ -z "$NETWORK" ] || [ "$NETWORK" = "0.0.0.0" ]; then log "参数错误：无效目标网段=$NETWORK_RAW"; exit 1; fi
BR_IF=br0; [ -e "/sys/class/net/$BR_IF" ] || BR_IF="$IFACE"; STATE_FILE="$(state_file_for "$NETWORK")"
if reuse_existing; then exit 0; fi
remove_one "$NETWORK"; collect_used_ips; FREE_IP="$(find_free_ip)"
if [ -z "$FREE_IP" ] || [ "$FREE_IP" = "0.0.0.0" ]; then log "未找到可用临时地址：目标网段=${NETWORK}/24"; exit 1; fi
if ip addr add "$FREE_IP/24" dev "$BR_IF" 2>/dev/null; then
    { printf 'iface=%s\n' "$BR_IF"; printf 'ip=%s\n' "$FREE_IP"; printf 'network=%s\n' "$NETWORK"; printf 'created=%s\n' "$(date +%s)"; } > "$STATE_FILE"
    runtime_set lan_discovery_status_target_network "$NETWORK/24"; runtime_set lan_discovery_status_target_ip "$FREE_IP"; runtime_set lan_discovery_status_target_iface "$BR_IF"; log "接管成功：接口=$BR_IF 地址=$FREE_IP/24 目标网段=${NETWORK}/24"; exit 0
fi
log "添加失败：接口=$BR_IF 地址=$FREE_IP/24"; exit 1
