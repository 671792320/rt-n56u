#!/usr/bin/env python3
# Q7混合DHCP/SNAT与临时IP唯一性最终修复。
# 该补丁放在所有LAN/SNAT补丁之后执行，避免后续补丁把混合模式覆盖回全局DHCP逻辑。
from pathlib import Path
import re


def replace_block(text, start_marker, end_marker, new_block, label):
    start = text.find(start_marker)
    if start < 0:
        if new_block.strip() in text:
            return text
        raise SystemExit(f"Q7混合模式修复失败：找不到{label}起点")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"Q7混合模式修复失败：找不到{label}结束边界")
    return text[:start] + new_block + text[end:]


# 1. Manager：目标网段按网段独立处理。
# DHCP网段：直接桥接，不创建临时IP/SNAT。
# 非DHCP网段：创建临时IP并SNAT；如果同时存在DHCP，则SNAT源网段使用DHCP实际下发的网段。
manager_path = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
s = manager_path.read_text(encoding='utf-8')

new_apply = '''apply_target() {
    target_net="$1"
    mode="$2"
    source_net="$3"
    [ -n "$target_net" ] || return 1
    [ "$target_net" != "0.0.0.0" ] || { log "忽略无效目标网段：0.0.0.0/24"; return 1; }
    localip="$(local_ip)"
    localnet="$(network_from_ip "$localip")"
    [ -n "$localnet" ] || return 1
    [ "$target_net" != "$localnet" ] || return 0
    [ -n "$source_net" ] || source_net="$localnet"
    [ "$target_net" != "$source_net" ] || return 0
    runtime_set lan_discovery_status_state "目标网段管理：$mode"
    if ! /usr/bin/lan_takeover.sh "$IFACE" "$target_net" >> "$LOG_FILE" 2>&1; then
        log "目标网段接管失败：$target_net/24"
        return 1
    fi
    current_ip="$(state_ip_for "$target_net")"
    [ -n "$current_ip" ] || { log "无法取得目标网段临时地址：$target_net/24"; return 1; }
    if ! /usr/bin/lan_snat.sh up "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1; then
        log "SNAT启用失败：$source_net/24 → $target_net/24"
        return 1
    fi
    update_runtime_targets
    {
        printf 'last_mode=%s\\n' "$mode"
        printf 'local_net=%s\\n' "$localnet"
        printf 'source_net=%s\\n' "$source_net"
        printf 'last_target_net=%s\\n' "$target_net"
        printf 'last_target_ip=%s\\n' "$current_ip"
    } > "$STATE_FILE"
    log "目标网段=$target_net/24，模式=$mode，SNAT源=$source_net/24，临时地址=$current_ip"
    return 0
}
'''
s = replace_block(s, 'apply_target() {', 'remove_stale_targets() {', new_apply, 'apply_target')

new_check = '''check_snat() {
    target_net="$1"
    takeover_file="$RUNTIME_DIR/lan_takeover_$(printf '%s' "$target_net" | tr '.' '_').state"
    snat_file="$RUNTIME_DIR/lan_snat_$(printf '%s' "$target_net" | tr '.' '_').state"
    current_ip="$(sed -n 's/^ip=//p' "$takeover_file" 2>/dev/null | head -n 1)"
    source_net="$(sed -n 's/^lan_net=//p' "$snat_file" 2>/dev/null | head -n 1)"
    [ -n "$target_net" ] && [ "$target_net" != "0.0.0.0" ] && [ -n "$current_ip" ] && [ -n "$source_net" ] || return 1
    [ -x /usr/bin/lan_snat.sh ] || return 1
    /usr/bin/lan_snat.sh check "$target_net" "$current_ip" "$source_net" >> "$LOG_FILE" 2>&1
}
'''
s = replace_block(s, 'check_snat() {', 'process_targets() {', new_check, 'SNAT周期检查')

new_process = '''process_targets() {
    localnet="$1"
    candidates="$RUNTIME_DIR/.lan_target_candidates.tmp"
    active="$RUNTIME_DIR/.lan_target_active.tmp"
    dhcp_nets="$RUNTIME_DIR/.lan_dhcp_nets.tmp"
    : > "$candidates"
    : > "$dhcp_nets"
    target_from_dhcp >> "$dhcp_nets"
    target_from_dhcp >> "$candidates"
    target_from_db "$localnet" >> "$candidates"
    grep -vE "^$localnet$|^0\\.0\\.0\\.0$" "$candidates" 2>/dev/null | sort -u > "$candidates.sorted"
    mv -f "$candidates.sorted" "$candidates"

    dhcp_source_net="$(head -n 1 "$dhcp_nets" 2>/dev/null)"
    if [ -n "$dhcp_source_net" ]; then
        # br0只有一个二层广播域，所以只要存在DHCP，就关闭Q7自身DHCP，避免手机拿到错误租约。
        runtime_set lan_discovery_status_state "混合模式：发现DHCP网段，关闭Q7 DHCP"
        if [ "$(nvram get dhcp_enable_x 2>/dev/null)" != "0" ]; then
            nvram set dhcp_enable_x=0
            /sbin/rc restart_dhcpd >/dev/null 2>&1 || :
        fi
    else
        if [ "$(nvram get dhcp_enable_x 2>/dev/null)" != "1" ]; then
            nvram set dhcp_enable_x=1
            /sbin/rc restart_dhcpd >/dev/null 2>&1 || :
        fi
    fi

    : > "$active"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ "$target" != "0.0.0.0" ] || continue

        if grep -qx "$target" "$dhcp_nets" 2>/dev/null; then
            # DHCP目标网段直接桥接：只清理这个网段自己的旧SNAT/临时IP，不影响其他无DHCP网段。
            log "目标网段=$target/24 检测到DHCP：使用直接桥接，不建立SNAT"
            /usr/bin/lan_snat.sh down "$target" >> "$LOG_FILE" 2>&1 || :
            /usr/bin/lan_takeover.sh -r "$target" >> "$LOG_FILE" 2>&1 || :
            continue
        fi

        # 存在DHCP时，手机实际地址来自DHCP网段，因此这里必须用DHCP网段作为SNAT源网段。
        source_net="$localnet"
        [ -n "$dhcp_source_net" ] && source_net="$dhcp_source_net"
        printf '%s\\n' "$target" >> "$active"
        mode="未检测到DHCP"
        [ -n "$dhcp_source_net" ] && mode="混合模式：无DHCP目标，SNAT经由$dhcp_source_net/24"
        apply_target "$target" "$mode" "$source_net" || log "本轮未成功处理目标，下一轮继续：$target/24"
    done < "$candidates"

    remove_stale_targets "$active"
    update_runtime_targets
    while IFS='|' read -r target_with_mask target_ip; do
        [ -n "$target_with_mask" ] || continue
        target_net="${target_with_mask%/24}"
        [ "$target_net" != "0.0.0.0" ] || continue
        check_snat "$target_net" || log "SNAT周期检查失败：$target_net/24"
    done < "$TARGETS_FILE"
    rm -f "$candidates" "$active" "$dhcp_nets"
}
'''
s = replace_block(s, 'process_targets() {', '\n\nwhile :; do', new_process, '目标处理流程')
manager_path.write_text(s, encoding='utf-8')

# 2. takeover：所有临时IP分配必须全局串行，并把所有既有状态IP加入占用表。
takeover_path = Path('trunk/user/lan_autodiscover/lan_takeover.sh')
s = takeover_path.read_text(encoding='utf-8')

if 'LOCK_DIR="$RUNTIME_DIR/.lan_takeover.lock"' not in s:
    s = s.replace('LOGTAG=lan-autodiscover\n', 'LOGTAG=lan-autodiscover\nLOCK_DIR="$RUNTIME_DIR/.lan_takeover.lock"\n')
    marker = 'IFACE="${1:-eth2.1}"; NETWORK_RAW="${2:-}"; mkdir -p "$RUNTIME_DIR"\n'
    guard = '''IFACE="${1:-eth2.1}"; NETWORK_RAW="${2:-}"; mkdir -p "$RUNTIME_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "已有临时IP分配事务正在执行，本轮跳过，防止重复占用同一地址"
    exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' EXIT INT TERM
'''
    if marker not in s:
        raise SystemExit('Q7临时IP唯一性修复失败：找不到takeover主入口')
    s = s.replace(marker, guard, 1)

old_collect = '''collect_used_ips() {
    used_file="$RUNTIME_DIR/lan_takeover_used.txt"; : > "$used_file"
    if [ -x /usr/bin/arpscan ]; then /usr/bin/arpscan -i "$IFACE" -t 2 -s "$NETWORK/24" 2>/dev/null | sed -n 's/^DEVICE type=[^ ]* IP=\\([^ ]*\\).*/\\1/p' >> "$used_file"; fi
    ip neigh show dev "$IFACE" 2>/dev/null | awk '$1 ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$/ && $2 != "FAILED" {print $1}' >> "$used_file"
    ip -4 addr show dev "$BR_IF" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\\+\\([0-9.]*\\)\\/.*$/\\1/p' >> "$used_file"
    sort -u "$used_file" -o "$used_file"
}
'''
new_collect = '''collect_used_ips() {
    used_file="$RUNTIME_DIR/lan_takeover_used.txt"; : > "$used_file"
    if [ -x /usr/bin/arpscan ]; then /usr/bin/arpscan -i "$IFACE" -t 2 -s "$NETWORK/24" 2>/dev/null | sed -n 's/^DEVICE type=[^ ]* IP=\\([^ ]*\\).*/\\1/p' >> "$used_file"; fi
    ip neigh show dev "$IFACE" 2>/dev/null | awk '$1 ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$/ && $2 != "FAILED" {print $1}' >> "$used_file"
    ip -4 addr show dev "$BR_IF" 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\\+\\([0-9.]*\\)\\/.*$/\\1/p' >> "$used_file"
    # 所有已有临时地址状态都视为占用，防止两个状态文件重复选择同一个完整IP。
    for state in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state" ] || continue
        sed -n 's/^ip=//p' "$state" | head -n 1 >> "$used_file"
    done
    sort -u "$used_file" -o "$used_file"
}
'''
if old_collect not in s:
    raise SystemExit('Q7临时IP唯一性修复失败：找不到collect_used_ips')
s = s.replace(old_collect, new_collect, 1)

reuse_marker = 'reuse_existing() {\n'
if 'ip_owned_by_other_state()' not in s:
    inject = '''ip_owned_by_other_state() {
    wanted="$1"
    for state in "$RUNTIME_DIR"/lan_takeover_*.state; do
        [ -r "$state" ] || continue
        [ "$state" = "$STATE_FILE" ] && continue
        old_ip="$(sed -n 's/^ip=//p' "$state" | head -n 1)"
        [ "$old_ip" = "$wanted" ] && return 0
    done
    return 1
}

'''
    s = s.replace(reuse_marker, inject + reuse_marker, 1)

s = s.replace('if ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $old_ip/24"; then\n', 'if ! ip_owned_by_other_state "$old_ip" && ip -4 addr show dev "$BR_IF" 2>/dev/null | grep -q " $old_ip/24"; then\n', 1)

old_alloc = 'remove_one "$NETWORK"; collect_used_ips; FREE_IP="$(find_free_ip)"\n'
new_alloc = '''remove_one "$NETWORK"
collect_used_ips
FREE_IP="$(find_free_ip)"
# 再次读取当前地址与全部状态，确保在真正添加前没有重复占用。
[ -n "$FREE_IP" ] && ! is_used "$FREE_IP" || FREE_IP=""
'''
if old_alloc not in s:
    raise SystemExit('Q7临时IP唯一性修复失败：找不到临时IP分配位置')
s = s.replace(old_alloc, new_alloc, 1)

old_write = '''    { printf 'iface=%s\\n' "$BR_IF"; printf 'ip=%s\\n' "$FREE_IP"; printf 'network=%s\\n' "$NETWORK"; printf 'created=%s\\n' "$(date +%s)"; } > "$STATE_FILE"
'''
new_write = '''    tmp_state="$STATE_FILE.tmp.$$"
    { printf 'iface=%s\\n' "$BR_IF"; printf 'ip=%s\\n' "$FREE_IP"; printf 'network=%s\\n' "$NETWORK"; printf 'created=%s\\n' "$(date +%s)"; } > "$tmp_state" && mv -f "$tmp_state" "$STATE_FILE"
'''
if old_write not in s:
    raise SystemExit('Q7临时IP唯一性修复失败：找不到状态写入位置')
s = s.replace(old_write, new_write, 1)
takeover_path.write_text(s, encoding='utf-8')

print('Q7混合DHCP/SNAT与临时IP唯一性修复已应用。')
