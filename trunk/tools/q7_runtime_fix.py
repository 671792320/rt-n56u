from pathlib import Path

p = Path('trunk/user/rc/rc.c')
s = p.read_text()

# Q7实际2.4G无线参数使用rt_ssid/rt0_hwaddr。
# 旧补丁误用了wl_ssid/wl0_hwaddr（5G参数），导致刷机后2.4G SSID迁移不生效。
s = s.replace(
    'const char *ssid = nvram_safe_get("wl_ssid");',
    'const char *ssid = nvram_safe_get("rt_ssid");',
)
s = s.replace(
    'const char *mac = nvram_safe_get("wl0_hwaddr");',
    'const char *mac = nvram_safe_get("rt0_hwaddr");',
)

# 无线MAC参数为空时回退到LAN MAC，只用于兼容旧Q7 NVRAM。
s = s.replace(
    'const char *mac = nvram_safe_get("rt0_hwaddr");\n\t\tchar suffix[5] = {0};',
    'const char *mac = nvram_safe_get("rt0_hwaddr");\n\t\tif (!mac || !*mac)\n\t\t\tmac = nvram_safe_get("lan_hwaddr");\n\t\tchar suffix[5] = {0};',
)

# 修正历史补丁中TUP-T2前缀长度，避免strncmp多比较一个字符导致迁移条件失效。
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", sizeof("@Seetong_IPCTEST-UTP-T2_") - 1)',
)
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", sizeof("@Seetong_IPCTEST-TUP-T2_") - 1)',
)

# rc.c只应保留一份Q7版本/SSID启动迁移代码。
marker = '/* Q7固定固件版本：WebUI直接读取firmver_sub'
if s.count(marker) > 1:
    raise SystemExit('Q7运行时修复失败：rc.c中存在重复的Q7版本/SSID迁移代码')

# 编译前强制校验最终迁移参数，避免补丁看似成功但实际修改错误参数。
if 'const char *ssid = nvram_safe_get("rt_ssid");' not in s:
    raise SystemExit('Q7运行时修复失败：未找到rt_ssid迁移参数')
if 'const char *mac = nvram_safe_get("rt0_hwaddr");' not in s:
    raise SystemExit('Q7运行时修复失败：未找到rt0_hwaddr迁移参数')

p.write_text(s)
