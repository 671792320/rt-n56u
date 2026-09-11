from pathlib import Path

# Q7临时IP/SNAT稳定性校验。
# 当前主线采用每个目标/24网段独立维护临时IP和SNAT状态。
# 不再使用旧版固定文本替换，避免多网段升级后误报“未找到内容”。

MANAGER = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
SNAT = Path('trunk/user/lan_autodiscover/lan_snat.sh')
TAKEOVER = Path('trunk/user/lan_autodiscover/lan_takeover.sh')
WEBUI = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')

manager = MANAGER.read_text()
snat = SNAT.read_text()
takeover = TAKEOVER.read_text()
webui = WEBUI.read_text()

# 多目标管理器结构检查。
for marker in ('lan_takeover_*.state', 'target_from_dhcp', 'target_from_db', 'process_targets', 'update_runtime_targets'):
    if marker not in manager:
        raise SystemExit(f'Q7多网段管理器缺少关键内容：{marker}')

# SNAT必须按目标网段保存独立状态，并支持check/up。
# 这里检查实际代码结构，不再依赖某一条中文日志文本，避免后续日志格式调整导致构建误报。
for marker in ('state_file_for()', 'cleanup_one()', 'cleanup_all()', 'check|up)', 'rule_add_first nat POSTROUTING', 'acquire_lock()'):
    if marker not in snat:
        raise SystemExit(f'Q7多网段SNAT缺少关键内容：{marker}')

# 临时IP接管必须按目标网段独立保存、删除和复用。
for marker in ('state_file_for()', 'remove_one()', 'remove_all()', 'lan_takeover_', '复用已有临时LAN地址'):
    if marker not in takeover:
        raise SystemExit(f'Q7多网段临时IP接管缺少关键内容：{marker}')

# WebUI继续使用多网段IP矩阵，不重新引入旧单目标状态替换。
for marker in ('render_matrix(byIp)', 'ip-tabs', 'ip-grid'):
    if marker not in webui:
        raise SystemExit(f'Q7 WebUI多网段显示缺少关键内容：{marker}')

print('Q7临时IP/SNAT稳定性校验通过：当前多网段实现无需旧单网段文本补丁。')
