#!/usr/bin/env python3
# Q7按Padavan原生机制接入LAN发现：服务启动/停止走rc/services.c，
# WebUI运行态目标网段走EJ接口，不把临时状态写入NVRAM。
from pathlib import Path
import re


def replace_once(path, text, old, new, label):
    if old not in text:
        if new in text:
            return text
        raise SystemExit(f"Q7原生接入失败：{path} 找不到{label}")
    return text.replace(old, new, 1)


# 1. LAN发现服务使用Padavan标准services.c启动/停止链。
services = Path('trunk/user/rc/services.c')
s = services.read_text(encoding='utf-8')
if 'start_lan_discovery(void)' not in s:
    marker = 'void\nstart_telnetd(void)\n'
    helper = '''static int\nis_lan_discovery_run(void)\n{\n\treturn pids("lan_discovery_supervisor");\n}\n\nvoid\nstart_lan_discovery(void)\n{\n\tif (nvram_invmatch("lan_discovery_enable", "1"))\n\t\treturn;\n\n\tif (!is_lan_discovery_run())\n\t\teval("/usr/bin/lan_discovery_supervisor.sh");\n}\n\nvoid\nstop_lan_discovery(void)\n{\n\tchar* svcs[] = { "lan_discovery_supervisor", NULL };\n\tkill_services(svcs, 3, 1);\n\tkill_pidfile_s("/tmp/lan_network_manager.pid", SIGTERM);\n\tkill_pidfile_s("/tmp/lan_autodiscover_worker.pid", SIGTERM);\n\tif (check_if_file_exist("/usr/bin/lan_snat.sh"))\n\t\teval("/usr/bin/lan_snat.sh", "down");\n\tif (check_if_file_exist("/usr/bin/lan_takeover.sh"))\n\t\teval("/usr/bin/lan_takeover.sh", "-r");\n\tunlink("/tmp/lan_network_manager.pid");\n\tunlink("/tmp/lan_autodiscover_worker.pid");\n}\n\n'''
    s = replace_once('services.c', s, marker, helper + marker, 'LAN服务启动函数位置')
    s = replace_once('services.c', s, '\tstart_networkmap(1);\n', '\tstart_networkmap(1);\n\tstart_lan_discovery();\n', 'start_services_once调用点')
    s = replace_once('services.c', s, '\tstop_networkmap();\n', '\tstop_networkmap();\n\tstop_lan_discovery();\n', 'stop_services调用点')
services.write_text(s, encoding='utf-8')

# 2. rc.h声明服务函数。
rc_h = Path('trunk/user/rc/rc.h')
s = rc_h.read_text(encoding='utf-8')
if 'void start_lan_discovery(void);' not in s:
    marker = 'int start_services_once(int is_ap_mode);\n'
    s = replace_once('rc.h', s, marker, marker + 'void start_lan_discovery(void);\nvoid stop_lan_discovery(void);\n', 'services声明位置')
rc_h.write_text(s, encoding='utf-8')

# 3. 不再把constructor启动器编进rc；由services.c统一负责服务生命周期。
rc_mk = Path('trunk/user/rc/Makefile')
s = rc_mk.read_text(encoding='utf-8')
s = s.replace(' lan_discovery_start.o', '')
rc_mk.write_text(s, encoding='utf-8')

# 4. WebUI运行态目标列表通过Padavan EJ直接读取/tmp状态文件。
web_ex = Path('trunk/user/httpd/web_ex.c')
s = web_ex.read_text(encoding='utf-8')
if 'ej_lan_discovery_targets' not in s:
    marker = 'static int\nej_lan_discovery_devices'
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit('Q7原生接入失败：找不到lan_discovery_devices EJ函数')

    # 不依赖官方源码中的相邻注释，只按下一个ej_netdev函数签名定位。
    match = re.search(r'\nstatic int\s+ej_netdev\s*\(', s[pos:])
    if not match:
        raise SystemExit('Q7原生接入失败：找不到ej_netdev函数边界')
    func_end = pos + match.start()

    helper = '''\nstatic int\nej_lan_discovery_targets(int eid, webs_t wp, int argc, char **argv)\n{\n\tFILE *fp;\n\tchar line[128];\n\tint first = 1;\n\n\t/* 运行态目标列表只读/tmp，不写入NVRAM。 */\n\tfp = fopen("/tmp/lan_discovery_runtime/lan_discovery_targets.state", "r");\n\tif (!fp)\n\t\treturn 0;\n\n\twhile (fgets(line, sizeof(line), fp)) {\n\t\tchar *p;\n\n\t\tline[strcspn(line, "\\r\\n")] = '\\0';\n\t\tif (line[0] == '\\0')\n\t\t\tcontinue;\n\t\tp = strchr(line, '|');\n\t\tif (!p || !p[1])\n\t\t\tcontinue;\n\t\tif (!first)\n\t\t\twebsWrite(wp, ";");\n\t\twebsWrite(wp, "%s", line);\n\t\tfirst = 0;\n\t}\n\n\tfclose(fp);\n\treturn 0;\n}\n\n'''
    s = s[:func_end] + helper + s[func_end:]
    reg = '{ "lan_discovery_devices", ej_lan_discovery_devices},\n'
    s = replace_once('web_ex.c', s, reg, reg + '\t{ "lan_discovery_targets", ej_lan_discovery_targets},\n', 'EJ注册表位置')
web_ex.write_text(s, encoding='utf-8')

# 5. 运行态目标数据源改为EJ；配置参数仍由NVRAM提供。
data = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Data.asp')
s = data.read_text(encoding='utf-8')
s = s.replace('<% nvram_get_x("", "lan_discovery_status_targets"); %>', '<% lan_discovery_targets(); %>')
data.write_text(s, encoding='utf-8')

print('Q7已按Padavan原生服务/EJ机制完成LAN发现接入修复。')
