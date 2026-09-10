from pathlib import Path


def patch_once(text, old, new, label):
    # 已经存在目标内容时直接视为成功，防止前序提交重复应用补丁。
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"未找到需要修改的内容：{label}")
    return text.replace(old, new, 1)


# ============================================================
# LAN网络管理：临时目标IP状态同步到运行时NVRAM。
# ============================================================
manager_path = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
manager_text = manager_path.read_text()

manager_text = patch_once(
    manager_text,
    '''    runtime_set lan_discovery_status_target_network ""\n    runtime_set lan_discovery_status_target_ip ""\n    runtime_set lan_discovery_status_target_iface ""\n''',
    '''    runtime_set lan_discovery_status_target_network ""\n    runtime_set lan_discovery_status_target_ip ""\n    runtime_set lan_discovery_status_target_iface ""\n    nvram set lan_discovery_status_target_network="" 2>/dev/null || :\n    nvram set lan_discovery_status_target_ip="" 2>/dev/null || :\n    nvram set lan_discovery_status_target_iface="" 2>/dev/null || :\n''',
    '清理临时IP状态',
)

manager_text = patch_once(
    manager_text,
    '''    {\n        printf 'mode=%s\\n' "$mode"\n        printf 'local_net=%s\\n' "$localnet"\n        printf 'target_net=%s\\n' "$target_net"\n        printf 'target_ip=%s\\n' "$current_ip"\n    } > "$STATE_FILE"\n''',
    '''    {\n        printf 'mode=%s\\n' "$mode"\n        printf 'local_net=%s\\n' "$localnet"\n        printf 'target_net=%s\\n' "$target_net"\n        printf 'target_ip=%s\\n' "$current_ip"\n    } > "$STATE_FILE"\n    # 仅运行时写入NVRAM，供WebUI显示；不执行commit。\n    nvram set lan_discovery_status_target_network="$target_net/24" 2>/dev/null || :\n    nvram set lan_discovery_status_target_ip="$current_ip" 2>/dev/null || :\n    nvram set lan_discovery_status_target_iface="$BR_IF" 2>/dev/null || :\n''',
    '同步临时IP到WebUI',
)
manager_path.write_text(manager_text)


# ============================================================
# SNAT：兼容已经完成check/并发锁/规则不删除重建修复的版本。
# 旧基线才修改；新基线已经具备功能时跳过。
# ============================================================
snat_path = Path('trunk/user/lan_autodiscover/lan_snat.sh')
snat_text = snat_path.read_text()

old_case = '''case "$1" in\n    down|remove|-r|--remove)\n        if [ -z "$IPTABLES" ]; then\n            rm -f "$STATE_FILE"\n            exit 0\n        fi\n        cleanup\n        exit 0\n        ;;\n    up)\n        TARGET_NET="$2"\n        TARGET_IP="$3"\n        LAN_NET="$4"\n        ;;\n    *)\n        log "用法：$0 up 目标网段 目标临时IP 本地LAN网段；$0 down"\n        exit 2\n        ;;\nesac\n'''
new_case = '''case "$1" in\n    down|remove|-r|--remove)\n        if [ -z "$IPTABLES" ]; then\n            rm -f "$STATE_FILE"\n            exit 0\n        fi\n        cleanup\n        exit 0\n        ;;\n    check)\n        TARGET_NET="$2"\n        TARGET_IP="$3"\n        LAN_NET="$4"\n        ;;\n    up)\n        TARGET_NET="$2"\n        TARGET_IP="$3"\n        LAN_NET="$4"\n        ;;\n    *)\n        log "用法：$0 up|check 目标网段 目标临时IP 本地LAN网段；$0 down"\n        exit 2\n        ;;\nesac\n'''

if old_case in snat_text:
    snat_text = snat_text.replace(old_case, new_case, 1)
else:
    # 当前提交已经包含check动作，说明该段无需再次修改。
    if not ('check|up)' in snat_text or 'check)' in snat_text):
        raise SystemExit('未找到SNAT动作且当前版本也没有check接口')

old_apply = '''cleanup\n\n# 允许本机承担路由器职责；即使Padavan其他模块已开启，重复设置也是幂等的。\n[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :\n\nrule_add filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT\nrule_add filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\nrule_add nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"\n'''
new_apply = '''# 允许本机承担路由器职责；即使Padavan其他模块已开启，重复设置也是幂等的。\n[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :\n\n# 不再删除后重建：规则存在就保持原样，规则缺失才自动补回。\nrule_add filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT\nrule_add filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\nrule_add nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"\n\nif [ "$1" = "check" ]; then\n    log "SNAT规则检查并补齐：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"\n    exit 0\nfi\n'''

if old_apply in snat_text:
    snat_text = snat_text.replace(old_apply, new_apply, 1)
else:
    # 已经具备稳定规则逻辑时不再重复处理。
    if 'rule_add_first nat POSTROUTING' not in snat_text or 'if [ "$1" = "check" ]' not in snat_text:
        # 某些版本已经将check逻辑放在apply_rules外层，此时只要存在check并发锁即可。
        if 'check' not in snat_text or 'LOCK_DIR' not in snat_text:
            raise SystemExit('未找到SNAT稳定补规则逻辑')

snat_path.write_text(snat_text)


# ============================================================
# WebUI：增加目标临时IP状态字段和颜色。
# render_matrix由当前前端版本自行处理，避免不同版本函数差异导致构建失败。
# ============================================================
web_path = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
web_text = web_path.read_text()

old_status = '''loop:'<% nvram_get_x("", "lan_discovery_status_loop"); %>'\n};'''
new_status = '''loop:'<% nvram_get_x("", "lan_discovery_status_loop"); %>',target_ip:'<% nvram_get_x("", "lan_discovery_status_target_ip"); %>',target_network:'<% nvram_get_x("", "lan_discovery_status_target_network"); %>'\n};'''

if old_status in web_text:
    web_text = web_text.replace(old_status, new_status, 1)
elif 'lan_discovery_status_target_ip' not in web_text:
    raise SystemExit('未找到WebUI状态字段位置')

style = '''<style>\n.ip-cell.ip-target{background:#f0ad4e!important;color:#fff!important;border-color:#eea236!important;font-weight:bold;}\n.ip-cell.ip-target:hover{background:#ec971f!important;}\n</style>\n'''
if style not in web_text:
    web_text = patch_once(web_text, '</head>', style + '</head>', '临时IP颜色')

web_path.write_text(web_text)
