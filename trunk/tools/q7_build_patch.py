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
    '''static int\nhttp_login_check(const uaddr *ip_now)\n{\n\tif (is_uaddr_localhost(ip_now))\n\t\treturn 1;\n\n\tif (login_ip.len == 0)\n\t\treturn 2;\n\n\tif (is_uaddr_equal(&login_ip, ip_now))\n\t\treturn 3;\n\n\tif ((unsigned long)(uptime() - login_timestamp) > LOGIN_TIMEOUT) {\n\t\treset_login_data();\n\t\treturn 2;\n\t}\n\n\treturn 0;\n}\n''',
    '''static int\nhttp_login_check(const uaddr *ip_now)\n{\n\tif (is_uaddr_localhost(ip_now))\n\t\treturn 1;\n\n\treturn 2;\n}\n''',
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
old_cycle = '''        [ "$raw" = "1" ] && run_arpscan "$iface"\n        run_camdiscover "$iface" "$discover_cycle"'''
new_cycle = '''        if [ "$raw" = "1" ]; then\n            /usr/bin/lan_device_state.sh begin\n            run_arpscan "$iface"\n        fi\n        run_camdiscover "$iface" "$discover_cycle"\n        if [ "$raw" = "1" ]; then\n            /usr/bin/lan_device_state.sh finish\n        fi'''
if old_cycle in s:
    s = s.replace(old_cycle, new_cycle, 1)
p.write_text(s)

# Q7 WebUI：增加Ping列、读取后端状态，并保持现有页面逻辑。
p = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
s = p.read_text()
s = replace_once(
    s,
    "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0};}",
    "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0,ping:'检测中',backend_status:''};}",
    'WebUI设备记录',
)
s = replace_once(
    s,
    "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);if(type==='ARP')currentArp[ip]=1;}}",
    "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);var pf=(z.match(/PROTO=(.*?) PING=/)||[])[1]||'';var pg=(z.match(/PING=([^ ]+)/)||[])[1]||'';var bs=(z.match(/STATUS=([^ ]+)/)||[])[1]||'';if(r){if(pf){pf.split(/ \/ /).forEach(function(t){add_protocol(r,t);});}if(pg)r.ping=pg;if(bs)r.backend_status=bs;}if(type==='ARP')currentArp[ip]=1;}}",
    'WebUI设备解析',
)
s = replace_once(
    s,
    "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '正常';}",
    "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.backend_status==='在线'||row.backend_status==='暂时离线'||row.backend_status==='IP冲突')return row.backend_status;if(row.ping==='通')return '在线';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '在线';}",
    'WebUI在线状态',
)
s = replace_once(
    s,
    "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];",
    "var vals=[st,protocol,r.ip,displayMac,r.ping||'检测中',r.info||'-'];",
    'WebUI设备列',
)
s = replace_once(
    s,
    '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>',
    '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>',
    'WebUI表头',
)
s = s.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)
p.write_text(s)

# Q7默认无线名称：保持Seetong首字母大写。
p = Path('trunk/user/shared/defaults.h')
s = s.replace('@seetong-IPCtest-utp2_', '@Seetong-IPCtest-utp2_')
p.write_text(s)

# Q7共享默认参数使用独立头文件，避免defaults.h同名冲突。
for rel in ('trunk/user/shared/shutils.h', 'trunk/user/shared/defaults.c'):
    p = Path(rel)
    s = p.read_text()
    if '#include "defaults.h"' in s:
        s = s.replace('#include "defaults.h"', '#include "q7_defaults.h"', 1)
    p.write_text(s)
