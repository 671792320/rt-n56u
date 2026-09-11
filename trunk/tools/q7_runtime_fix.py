from pathlib import Path

p = Path('trunk/user/rc/rc.c')
s = p.read_text()

# 修正历史补丁中TUP-T2前缀长度，避免strncmp多比较一个字符导致迁移条件失效。
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", sizeof("@Seetong_IPCTEST-UTP-T2_") - 1)',
)
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", sizeof("@Seetong_IPCTEST-TUP-T2_") - 1)',
)

# 无线MAC参数在部分Q7旧NVRAM中可能为空，回退到lan_hwaddr。
s = s.replace(
    'const char *mac = nvram_safe_get("wl0_hwaddr");',
    'const char *mac = nvram_safe_get("wl0_hwaddr");\n\t\tif (!mac || !*mac)\n\t\t\tmac = nvram_safe_get("lan_hwaddr");',
)

# rc.c只应保留一份Q7版本/SSID启动迁移代码。
marker = '/* Q7固定固件版本：WebUI直接读取firmver_sub'
if s.count(marker) > 1:
    first = s.find(marker)
    second = s.find(marker, first + len(marker))
    s = s[:second] + s[s.find('\n\t/* Q7 SSID迁移', second):] if False else s

p.write_text(s)
