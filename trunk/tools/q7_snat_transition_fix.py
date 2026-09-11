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
    'check|up)',
    'rule_add_first nat POSTROUTING',
    'acquire_lock()',
]
required_takeover = [
    'state_file_for()',
    'remove_one()',
    'remove_all()',
    '复用成功：接口=$BR_IF',
]

# 校验实际代码结构，不依赖旧版中文日志文本。
# 日志格式可以继续调整，但多网段事务、并发锁和幂等SNAT结构必须保留。
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
