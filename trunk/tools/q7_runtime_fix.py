from pathlib import Path

p = Path('trunk/user/rc/rc.c')
s = p.read_text()

# Q7实际2.4G无线参数使用rt_ssid/rt0_hwaddr。
s = s.replace(
    'const char *ssid = nvram_safe_get("wl_ssid");',
    'const char *ssid = nvram_safe_get("rt_ssid");',
)
s = s.replace(
    'const char *mac = nvram_safe_get("wl0_hwaddr");',
    'const char *mac = nvram_safe_get("rt0_hwaddr");',
)
s = s.replace(
    'const char *mac = nvram_safe_get("rt0_hwaddr");\n\t\tchar suffix[5] = {0};',
    'const char *mac = nvram_safe_get("rt0_hwaddr");\n\t\tif (!mac || !*mac)\n\t\t\tmac = nvram_safe_get("lan_hwaddr");\n\t\tchar suffix[5] = {0};',
)

# 强制更新本项目SSID：无论旧NVRAM保存了什么名称，只要能取得MAC就统一生成目标名称。
s = s.replace('\t\tint legacy = 0;', '\t\tint legacy = 1;')
# 关键修复：Q7 2.4G实际写入rt_ssid，不能再写到5G的wl_ssid。
s = s.replace('nvram_set("wl_ssid", new_ssid);', 'nvram_set("rt_ssid", new_ssid);')

# 修正历史补丁中前缀长度。
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", sizeof("@Seetong_IPCTEST-UTP-T2_") - 1)',
)
s = s.replace(
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", 24)',
    'strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", sizeof("@Seetong_IPCTEST-TUP-T2_") - 1)',
)

# Q7版本号必须在NVRAM恢复后、commit前写入，否则旧NVRAM会继续保留旧版本。
marker = '\tnvram_need_commit = nvram_restore_defaults();\n'
version_block = '''\t/* Q7固定固件版本：WebUI直接读取firmver_sub。 */
\tif (strcmp(nvram_safe_get("firmver_sub"), "3.4.3.9-099_26-03-1") != 0) {
\t\tnvram_set("firmver_sub", "3.4.3.9-099_26-03-1");
\t\tnvram_need_commit = 1;
\t}
'''
if '/* Q7固定固件版本：WebUI直接读取firmver_sub。 */' not in s:
    if marker not in s:
        raise SystemExit('Q7版本修复失败：找不到nvram_restore_defaults后的提交位置')
    s = s.replace(marker, marker + version_block, 1)

# 编译前强制校验最终参数。
for item, msg in [
    ('nvram_set("firmver_sub", "3.4.3.9-099_26-03-1");', '未找到firmver_sub写入代码'),
    ('const char *ssid = nvram_safe_get("rt_ssid");', '未找到rt_ssid读取'),
    ('const char *mac = nvram_safe_get("rt0_hwaddr");', '未找到rt0_hwaddr读取'),
    ('nvram_set("rt_ssid", new_ssid);', '未找到rt_ssid写入'),
]:
    if item not in s:
        raise SystemExit('Q7运行时修复失败：' + msg)

p.write_text(s)
