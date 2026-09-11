from pathlib import Path

# Q7临时IP/SNAT稳定性校验。
# 当前主线采用每个目标/24网段独立维护临时IP、SNAT和状态。
# 校验只验证实际功能结构，不依赖某一条中文日志或注释文本，避免后续改日志再次误报。

MANAGER = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
SNAT = Path('trunk/user/lan_autodiscover/lan_snat.sh')
TAKEOVER = Path('trunk/user/lan_autodiscover/lan_takeover.sh')
WEBUI = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')

for path in (MANAGER, SNAT, TAKEOVER, WEBUI):
    if not path.is_file():
        raise SystemExit(f'Q7校验文件不存在：{path}')

manager = MANAGER.read_text(encoding='utf-8')
snat = SNAT.read_text(encoding='utf-8')
takeover = TAKEOVER.read_text(encoding='utf-8')
webui = WEBUI.read_text(encoding='utf-8')

# 管理器必须能够从DHCP和设备库得到多个目标网段，并逐个处理。
manager_checks = (
    'target_from_dhcp()',
    'target_from_db()',
    'process_targets()',
    'lan_takeover_*.state',
    'lan_snat.sh up',
    'lan_snat.sh down "$net"',
    'TARGETS_FILE',
    'state_ip_for()',
)
for marker in manager_checks:
    if marker not in manager:
        raise SystemExit(f'Q7网络管理器缺少关键结构：{marker}')

# SNAT必须按目标网段保存状态、支持单目标清理/全部清理，并使用目标临时IP。
snat_checks = (
    'state_file_for()',
    'cleanup_one()',
    'cleanup_all()',
    'case "$ACTION" in',
    'check|up)',
    'POSTROUTING',
    '--to-source "$TARGET_IP"',
    'acquire_lock()',
    'lan_net=%s',
    'target_net=%s',
    'target_ip=%s',
)
for marker in snat_checks:
    if marker not in snat:
        raise SystemExit(f'Q7多网段SNAT缺少关键结构：{marker}')

# 临时IP接管必须按目标网段独立保存、删除，并优先复用同一网段已有地址。
takeover_checks = (
    'state_file_for()',
    'remove_one()',
    'remove_all()',
    'reuse_existing()',
    'ip addr add "$FREE_IP/24" dev "$BR_IF"',
    'network=%s',
    'ip=%s',
)
for marker in takeover_checks:
    if marker not in takeover:
        raise SystemExit(f'Q7临时IP接管缺少关键结构：{marker}')

# WebUI必须保留多网段矩阵；临时IP/SNAT显示由后续WebUI状态区域负责。
webui_checks = (
    'render_matrix(byIp)',
    'ip-tabs',
    'ip-grid',
    'parse_data(data)',
    'render_status(o)',
)
for marker in webui_checks:
    if marker not in webui:
        raise SystemExit(f'Q7 WebUI缺少关键结构：{marker}')

print('Q7临时IP/SNAT稳定性结构校验通过。')
