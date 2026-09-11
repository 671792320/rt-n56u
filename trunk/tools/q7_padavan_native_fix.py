#!/usr/bin/env python3
# Q7按Padavan原生机制接入LAN发现：服务启动/停止走rc/services.c，
# WebUI运行态目标网段走EJ接口，不把临时状态写入NVRAM。
from pathlib import Path


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
    func_end = s.find('\n}\n', pos)
    if func_end < 0:
        raise SystemExit('Q7原生接入失败：lan_discovery_devices EJ函数结构异常')
    func_end += 3
    helper = '''\nstatic int\nej_lan_discovery_targets(int eid, webs_t wp, int argc, char **argv)\n{\n\tFILE *fp;\n\tchar line[128];\n\tint first = 1;\n\n\t/* 运行态目标列表只读/tmp，不写入NVRAM。 */\n\tfp = fopen("/tmp/lan_discovery_runtime/lan_discovery_targets.state", "r");\n\tif (!fp)\n\t\treturn 0;\n\n\twhile (fgets(line, sizeof(line), fp)) {\n\t\tchar *p;\n\n\t\tline[strcspn(line, "\\r\\n")] = '\\0';\n\t\tif (line[0] == '\\0')\n\t\t\tcontinue;\n\t\tp = strchr(line, '|');\n\t\tif (!p || !p[1])\n\t\t\tcontinue;\n\t\tif (!first)\n\t\t\twebsWrite(wp, ";");\n\t\twebsWrite(wp, "%s", line);\n\t\tfirst = 0;\n\t}\n\n\tfclose(fp);\n\treturn 0;\n}\n'''
    s = s[:func_end] + helper + s[func_end:]
    reg = '{ "lan_discovery_devices", ej_lan_discovery_devices},\n'
    s = replace_once('web_ex.c', s, reg, reg + '\t{ "lan_discovery_targets", ej_lan_discovery_targets},\n', 'EJ注册表位置')
web_ex.write_text(s, encoding='utf-8')

# 5. 运行态目标数据源改为EJ；配置参数仍由NVRAM提供。
data = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Data.asp')
s = data.read_text(encoding='utf-8')
s = s.replace('<% nvram_get_x("", "lan_discovery_status_targets"); %>', '<% lan_discovery_targets(); %>')
data.write_text(s, encoding='utf-8')

# 6. Manager单实例、目标发现与运行状态分离、DHCP模式真正与SNAT模式分离。
manager = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
s = manager.read_text(encoding='utf-8')
if 'LOCK_DIR=/var/run/lan_network_manager.lock' not in s:
    s = s.replace('LOG_FILE=/tmp/lan_discovery.log\n\nmkdir -p "$RUNTIME_DIR"', 'LOG_FILE=/tmp/lan_discovery.log\nLOCK_DIR=/var/run/lan_network_manager.lock\n\nmkdir -p "$RUNTIME_DIR"\nif ! mkdir "$LOCK_DIR" 2>/dev/null; then\n    logger -t lan-autodiscover "LAN网络模式管理器已经运行"\n    exit 0\nfi\ntrap \'rmdir "$LOCK_DIR" 2>/dev/null || :\' EXIT INT TERM')
s = s.replace('clear_target_status() { runtime_set lan_discovery_status_target_network ""; runtime_set lan_discovery_status_target_ip ""; runtime_set lan_discovery_status_target_iface ""; nvram set lan_discovery_status_targets "" 2>/dev/null || :; }', 'clear_target_status() { runtime_set lan_discovery_status_target_network ""; runtime_set lan_discovery_status_target_ip ""; runtime_set lan_discovery_status_target_iface ""; }')
s = s.replace('targets_text="$(awk \'BEGIN{ORS=""} {if(NR>1) printf ";"; printf "%s",$0}\' "$TARGETS_FILE" 2>/dev/null)"; nvram set lan_discovery_status_targets "$targets_text" 2>/dev/null || :; ', '')
old = 'remove_stale_targets() { for f in "$RUNTIME_DIR"/lan_takeover_*.state; do [ -r "$f" ] || continue; net="$(sed -n \'s/^network=//p\' "$f" | head -n 1)"; [ -n "$net" ] || continue; if ! target_is_active "$net"; then log "目标网段已不再发现，正在清理：$net/24"; [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down "$net" >> "$LOG_FILE" 2>&1 || :; [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r "$net" >> "$LOG_FILE" 2>&1 || :; fi; done; update_runtime_targets; }'
new = 'remove_stale_targets() { active_file="$1"; for f in "$RUNTIME_DIR"/lan_takeover_*.state; do [ -r "$f" ] || continue; net="$(sed -n \'s/^network=//p\' "$f" | head -n 1)"; [ -n "$net" ] || continue; if ! grep -qx "$net" "$active_file" 2>/dev/null; then log "目标网段已不再发现，正在清理：$net/24"; [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down "$net" >> "$LOG_FILE" 2>&1 || :; [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r "$net" >> "$LOG_FILE" 2>&1 || :; fi; done; }'
s = replace_once('lan_network_manager.sh', s, old, new, '过期目标清理逻辑')
old_proc = 'process_targets() { localnet="$1"; candidates="$RUNTIME_DIR/.lan_target_candidates.tmp"; : > "$candidates"; target_from_dhcp >> "$candidates"; target_from_db "$localnet" >> "$candidates"; grep -vE "^$localnet$|^0\\.0\\.0\\.0$" "$candidates" 2>/dev/null | sort -u > "$candidates.sorted"; mv -f "$candidates.sorted" "$candidates"; : > "$TARGETS_FILE"; while IFS= read -r target; do [ -n "$target" ] || continue; [ "$target" != "0.0.0.0" ] || continue; mode="未检测到DHCP"; is_dhcp_target "$target" && mode="检测到DHCP"; apply_target "$target" "$mode" || log "本轮未成功处理目标，下一轮继续：$target/24"; done < "$candidates"; rm -f "$candidates"; remove_stale_targets; while IFS=\'|\' read -r target_with_mask target_ip; do [ -n "$target_with_mask" ] || continue; target_net="${target_with_mask%/24}"; [ "$target_net" != "0.0.0.0" ] || continue; check_snat "$target_net" "$localnet" || log "SNAT周期检查失败：$target_net/24"; done < "$TARGETS_FILE"; }'
new_proc = '''process_targets() {\n    localnet="$1"\n    candidates="$RUNTIME_DIR/.lan_target_candidates.tmp"\n    active="$RUNTIME_DIR/.lan_target_active.tmp"\n    : > "$candidates"\n    target_from_dhcp >> "$candidates"\n    target_from_db "$localnet" >> "$candidates"\n    grep -vE "^$localnet$|^0\\.0\\.0\\.0$" "$candidates" 2>/dev/null | sort -u > "$candidates.sorted"\n    mv -f "$candidates.sorted" "$candidates"\n\n    if target_from_dhcp | grep -q .; then\n        runtime_set lan_discovery_status_state "检测到DHCP：桥接模式"\n        if [ "$(nvram get dhcp_enable_x 2>/dev/null)" != "0" ]; then\n            nvram set dhcp_enable_x=0\n            /sbin/rc restart_dhcpd >/dev/null 2>&1 || :\n        fi\n        /usr/bin/lan_snat.sh down >/dev/null 2>&1 || :\n        /usr/bin/lan_takeover.sh -r >/dev/null 2>&1 || :\n        : > "$TARGETS_FILE"\n        rm -f "$candidates" "$active"\n        return 0\n    fi\n\n    if [ "$(nvram get dhcp_enable_x 2>/dev/null)" != "1" ]; then\n        nvram set dhcp_enable_x=1\n        /sbin/rc restart_dhcpd >/dev/null 2>&1 || :\n    fi\n\n    : > "$active"\n    while IFS= read -r target; do\n        [ -n "$target" ] || continue\n        printf '%s\\n' "$target" >> "$active"\n        apply_target "$target" "未检测到DHCP" || log "本轮未成功处理目标，下一轮继续：$target/24"\n    done < "$candidates"\n\n    remove_stale_targets "$active"\n    update_runtime_targets\n    while IFS='|' read -r target_with_mask target_ip; do\n        [ -n "$target_with_mask" ] || continue\n        target_net="${target_with_mask%/24}"\n        [ "$target_net" != "0.0.0.0" ] || continue\n        check_snat "$target_net" "$localnet" || log "SNAT周期检查失败：$target_net/24"\n    done < "$TARGETS_FILE"\n    rm -f "$candidates" "$active"\n}'''
s = replace_once('lan_network_manager.sh', s, old_proc, new_proc, '目标处理流程')
manager.write_text(s, encoding='utf-8')

# 7. 纠正WebUI旧补丁中的POSIX正则写法：JavaScript使用\\s。
page = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
if page.exists():
    s = page.read_text(encoding='utf-8')
    s = s.replace('[[:space:]]', '\\s')
    page.write_text(s, encoding='utf-8')

print('Q7已按Padavan原生服务/EJ机制完成LAN发现接入修复。')
