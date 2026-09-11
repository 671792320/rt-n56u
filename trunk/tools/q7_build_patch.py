from pathlib import Path


def replace_once(text, old, new, label, required=False):
    if old in text:
        return text.replace(old, new, 1)
    if required and new not in text:
        raise SystemExit(f'未找到需要修改的内容：{label}')
    return text


# 内核默认关闭连接跟踪事件链，保持Q7现有构建兼容性。
p = Path('trunk/linux-3.4.x/net/netfilter/Kconfig')
s = p.read_text()
s = replace_once(
    s,
    'config NF_CONNTRACK_CHAIN_EVENTS\n\tbool "Register multiple callbacks to ct events"\n\tselect NF_CONNTRACK_EVENTS',
    'config NF_CONNTRACK_CHAIN_EVENTS\n\tbool "Register multiple callbacks to ct events"\n\tdefault n\n\tselect NF_CONNTRACK_EVENTS',
    'Kconfig连接跟踪事件',
)
p.write_text(s)

# Q7现有Web登录兼容处理。
p = Path('trunk/user/httpd/httpd.c')
s = p.read_text()
s = replace_once(
    s,
    '''static int
http_login_check(const uaddr *ip_now)
{
\tif (is_uaddr_localhost(ip_now))
\t\treturn 1;

\tif (login_ip.len == 0)
\t\treturn 2;

\tif (is_uaddr_equal(&login_ip, ip_now))
\t\treturn 3;

\tif ((unsigned long)(uptime() - login_timestamp) > LOGIN_TIMEOUT) {
\t\treset_login_data();
\t\treturn 2;
\t}

\treturn 0;
}
''',
    '''static int
http_login_check(const uaddr *ip_now)
{
\tif (is_uaddr_localhost(ip_now))
\t\treturn 1;

\treturn 2;
}
''',
    'http登录兼容处理',
)
p.write_text(s)

# LAN发现：统一中文日志、设备状态事件以及MAC补充。
p = Path('trunk/user/lan_autodiscover/lan_autodiscover.sh')
s = p.read_text()
helper = r'''
module_cn() {
    [ "$1" = "1" ] && printf '启用' || printf '停用'
}

format_device_log() {
    line="$1"
    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$line" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$line" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    response_len="$(printf '%s\n' "$line" | sed -n 's/.*response_len=\([0-9][0-9]*\).*/\1/p')"
    [ -n "$ip" ] || return 0
    [ -n "$mac" ] || mac="-"
    case "$mac" in
        ''|-) mac="$(ip neigh show "$ip" 2>/dev/null | awk '$0 !~ /FAILED|INCOMPLETE/ {for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); exit}}')";;
    esac
    [ -n "$mac" ] || mac="-"
    case "$type" in
        ONVIF|onvif) protocol="ONVIF";;
        SSDP|ssdp) protocol="SSDP";;
        HIK|HIK-SADP|hik|hik-sadp) protocol="HIK";;
        DAHUA|DAHUA-DHIP|dahua|dahua-dhip) protocol="DAHUA";;
        ARP|arp) protocol="ARP";;
        *) protocol="$type";;
    esac
    if [ -n "$response_len" ]; then
        log_line "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=${response_len}字节"
    elif [ "$protocol" = "ARP" ]; then
        log_line "发现设备：IP=$ip 协议=ARP MAC=$mac 回包响应=收到ARP回复"
    else
        log_line "发现设备：IP=$ip 协议=$protocol MAC=$mac 回包响应=已收到"
    fi
}

device_state_event() {
    line="$1"
    type="$(printf '%s\n' "$line" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
    ip="$(printf '%s\n' "$line" | sed -n 's/.*IP=\([^ ]*\).*/\1/p')"
    mac="$(printf '%s\n' "$line" | sed -n 's/.*MAC=\([^ ]*\).*/\1/p')"
    [ -n "$ip" ] || return 0
    case "$type" in
        ARP|arp) /usr/bin/lan_device_state.sh arp "$ip" "$mac" 2>/dev/null || :;;
        SUBNET|subnet) :;;
        *) /usr/bin/lan_device_state.sh proto "$ip" "$type" 2>/dev/null || :;;
    esac
}
'''
if 'format_device_log() {' not in s:
    marker = 'append_device() {\n'
    if marker not in s:
        raise SystemExit('未找到append_device函数')
    s = s.replace(marker, helper + '\n' + marker, 1)

s = s.replace(
    'clean="$(append_device "$line")"\n                    [ -n "$clean" ] && log_line "发现设备：$clean"',
    'device_state_event "$line"\n                    clean="$(append_device "$line")"\n                    [ -n "$clean" ] && format_device_log "$line"',
)
s = s.replace(
    'clean="$(append_device "$line")"\n                        [ -n "$clean" ] && log_line "发现设备：$clean"',
    'device_state_event "$line"\n                        clean="$(append_device "$line")"\n                        [ -n "$clean" ] && format_device_log "$line"',
)
old_log = '    log_line "[camdiscover] probes enabled: ONVIF=$onvif SSDP=$ssdp HIK=$hik DAHUA=$dahua ARP=$raw"'
new_log = '    log_line "发现程序启用模块：ONVIF=$(module_cn "$onvif") SSDP=$(module_cn "$ssdp") HIK=$(module_cn "$hik") DAHUA=$(module_cn "$dahua") ARP=$(module_cn "$raw")"'
s = replace_once(s, old_log, new_log, '中文模块日志')
old_cycle = '''        [ "$raw" = "1" ] && run_arpscan "$iface"
        run_camdiscover "$iface" "$discover_cycle"'''
new_cycle = '''        if [ "$raw" = "1" ]; then
            /usr/bin/lan_device_state.sh begin
            run_arpscan "$iface"
        fi
        run_camdiscover "$iface" "$discover_cycle"
        if [ "$raw" = "1" ]; then
            /usr/bin/lan_device_state.sh finish
        fi'''
if old_cycle in s:
    s = s.replace(old_cycle, new_cycle, 1)

# 将底层扫描程序的英文分类前缀统一转换为中文，避免日志中出现混杂标签。
s = s.replace(
    'log_line "$line"\n                        ;;&nbsp;',
    'log_line "【设备扫描】$line"\n                        ;;&nbsp;'
) if False else s
s = s.replace(
    '\\[arpscan\\]*)\n                        log_line "$line"',
    '\\[arpscan\\]*)\n                        arp_line="$(printf \'%s\\n\' "$line" | sed \'s/^\\[arpscan\\][[:space:]]*//\')"\n                        log_line "【ARP扫描】$arp_line"'
)
s = s.replace(
    '\\[arpscan\\]*) log_line "$line";;',
    '\\[arpscan\\]*) arp_line="$(printf \'%s\\n\' "$line" | sed \'s/^\\[arpscan\\][[:space:]]*//\')"; log_line "【ARP扫描】$arp_line";;'
)
s = s.replace(
    '*probe\\ sent*|*probe\\ FAILED*|*probes\\ enabled:*|*listen\\ *FAILED*) log_line "$line";;',
    '*probe\\ sent*|*probe\\ FAILED*|*probes\\ enabled:*|*listen\\ *FAILED*) log_line "【设备探测】$line";;'
)
p.write_text(s)

# WebUI：增加Ping列、读取后端状态，并保持现有页面逻辑。
p = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
s = p.read_text()
s = replace_once(s, "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0};}", "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0,ping:'检测中',backend_status:''};}", 'WebUI设备记录')
s = replace_once(s, "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);if(type==='ARP')currentArp[ip]=1;}}", "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);var pf=(z.match(/PROTO=(.*?) PING=/)||[])[1]||'';var pg=(z.match(/PING=([^ ]+)/)||[])[1]||'';var bs=(z.match(/STATUS=([^ ]+)/)||[])[1]||'';if(r){if(pf){pf.split(/ \/ /).forEach(function(t){add_protocol(r,t);});}if(pg)r.ping=pg;if(bs)r.backend_status=bs;}if(type==='ARP')currentArp[ip]=1;}}", 'WebUI设备解析')
s = replace_once(s, "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '正常';}", "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.backend_status==='在线'||row.backend_status==='暂时离线'||row.backend_status==='IP冲突')return row.backend_status;if(row.ping==='通')return '在线';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '在线';}", 'WebUI在线状态')
s = replace_once(s, "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];", "var vals=[st,protocol,r.ip,displayMac,r.ping||'检测中',r.info||'-'];", 'WebUI设备列')
s = replace_once(s, '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>', '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>', 'WebUI表头')
s = s.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)
p.write_text(s)

# Q7默认无线名称：新的TUP-T2格式，后缀由启动时根据无线MAC自动迁移为4位。
p = Path('trunk/user/shared/defaults.h')
s = p.read_text()
s = s.replace('@seetong-IPCtest-utp2_', '@Seetong_IPCTEST-TUP-T2_')
s = s.replace('@Seetong_IPCTEST-UTP-T2_', '@Seetong_IPCTEST-TUP-T2_')
s = s.replace('@Seetong-IPCTEST-UTP-T2_', '@Seetong_IPCTEST-TUP-T2_')
p.write_text(s)

# 编译链使用独立头文件名，避免defaults.h与WebUI文件名冲突。
for rel in ('trunk/user/shared/shutils.h', 'trunk/user/shared/defaults.c'):
    p = Path(rel)
    s = p.read_text()
    if '#include "defaults.h"' in s:
        s = s.replace('#include "defaults.h"', '#include "q7_defaults.h"', 1)
    p.write_text(s)

# Q7运行时迁移：解决旧固件已有NVRAM时默认SSID不会更新，以及版本号仅在构建阶段写入的问题。
p = Path('trunk/user/rc/rc.c')
s = p.read_text()
marker = '\tnvram_need_commit = nvram_restore_defaults();\n'
block = r'''
	/* Q7固定固件版本：WebUI直接读取firmver_sub，启动阶段写入并随NVRAM一起提交。 */
	if (strcmp(nvram_safe_get("firmver_sub"), "3.4.3.9-099_26-03-1") != 0) {
		nvram_set("firmver_sub", "3.4.3.9-099_26-03-1");
		nvram_need_commit = 1;
	}

	/* Q7 SSID迁移：只处理本项目历史默认SSID，不覆盖用户自行设置的SSID。 */
	{
		const char *ssid = nvram_safe_get("wl_ssid");
		const char *mac = nvram_safe_get("wl0_hwaddr");
		char suffix[5] = {0};
		char new_ssid[64];
		int legacy = 0;
		int i;

		if (!strncmp(ssid, "@seetong-IPCtest-utp2_", 22) ||
		    !strncmp(ssid, "@Seetong_IPCTEST-UTP-T2_", 24) ||
		    !strncmp(ssid, "@Seetong_IPCTEST-TUP-T2_", 24))
			legacy = 1;

		if (legacy) {
			/* 优先从无线MAC取最后4位；MAC格式为 XX:XX:XX:XX:XX:XX。 */
			if (mac && strlen(mac) >= 17) {
				suffix[0] = mac[12];
				suffix[1] = mac[13];
				suffix[2] = mac[15];
				suffix[3] = mac[16];
			}
			/* 无线MAC不可用时，再使用现有SSID末尾的4位十六进制后缀。 */
			if (strlen(suffix) != 4) {
				const char *u = strrchr(ssid, '_');
				if (u && strlen(u + 1) == 4) {
					int ok = 1;
					for (i = 0; i < 4; i++) {
						char c = u[1 + i];
						if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
							ok = 0;
							break;
						}
					}
					if (ok)
						memcpy(suffix, u + 1, 4);
				}
			}
			if (strlen(suffix) == 4) {
				for (i = 0; i < 4; i++) {
					if (suffix[i] >= 'a' && suffix[i] <= 'f')
						suffix[i] = (char)(suffix[i] - 'a' + 'A');
				}
				suffix[4] = 0;
				snprintf(new_ssid, sizeof(new_ssid), "@Seetong_IPCTEST-TUP-T2_%s", suffix);
				if (strcmp(ssid, new_ssid) != 0) {
					nvram_set("wl_ssid", new_ssid);
					nvram_need_commit = 1;
				}
			}
		}
	}
'''
if '/* Q7固定固件版本：WebUI直接读取firmver_sub' not in s:
    if marker not in s:
        raise SystemExit('未找到rc.c的NVRAM恢复位置')
    s = s.replace(marker, marker + block, 1)
p.write_text(s)
