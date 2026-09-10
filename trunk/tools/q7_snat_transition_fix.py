from pathlib import Path

# 多目标网段版本已经直接进入LAN管理器和SNAT脚本。
# 这里保留原工作流步骤，但不再重复做单网段文本替换，避免旧补丁与新结构互相覆盖。
manager = Path('trunk/user/lan_autodiscover/lan_network_manager.sh').read_text()
snat = Path('trunk/user/lan_autodiscover/lan_snat.sh').read_text()
takeover = Path('trunk/user/lan_autodiscover/lan_takeover.sh').read_text()

required_manager = [
    'lan_takeover_*.state',
    'target_from_dhcp',
    'target_from_db',
    'process_targets',
    '目标网段管理：$mode',
]
required_snat = [
    'state_file_for()',
    'cleanup_all()',
    'cleanup_one()',
    'SNAT状态检查并同步',
]
required_takeover = [
    'state_file_for()',
    'remove_one()',
    'remove_all()',
    '复用已有临时LAN地址',
]

for marker in required_manager:
    if marker not in manager:
        raise SystemExit(f'Q7多网段管理器缺少关键内容：{marker}')
for marker in required_snat:
    if marker not in snat:
        raise SystemExit(f'Q7多网段SNAT缺少关键内容：{marker}')
for marker in required_takeover:
    if marker not in takeover:
        raise SystemExit(f'Q7多网段临时IP接管缺少关键内容：{marker}')

print('Q7多目标网段事务结构校验通过：每个目标网段独立维护临时IP和SNAT。')
