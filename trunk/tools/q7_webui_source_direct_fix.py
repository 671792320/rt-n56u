#!/usr/bin/env python3
from pathlib import Path

PAGE = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
DATA = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Data.asp')


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit('Q7 WebUI源码修复失败：找不到' + label)
    return text.replace(old, new, 1)


def main():
    page = PAGE.read_text(encoding='utf-8')
    data = DATA.read_text(encoding='utf-8')

    # Data接口直接输出目标网段，页面不再依赖旧NVRAM缓存。
    data = data.replace('<% nvram_get_x("", "lan_discovery_status_targets"); %>', '<% lan_discovery_targets(); %>')
    DATA.write_text(data, encoding='utf-8')

    # parse_data必须把TARGETS独立出来。
    old_parse = "interfaces:section(data,'---IFACES---','---LOG---'),log:section(data,'---LOG---','---DEVICES---'),devices:section(data,'---DEVICES---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')"
    new_parse = "interfaces:section(data,'---IFACES---','---LOG---'),log:section(data,'---LOG---','---DEVICES---'),devices:section(data,'---DEVICES---','---TARGETS---'),targets:section(data,'---TARGETS---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')"
    page = must_replace(page, old_parse, new_parse, '目标网段解析')

    # 设备记录增加后端Ping/状态字段。
    old_record = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0};}"
    new_record = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0,ping:'不可用',backend_status:''};}"
    page = must_replace(page, old_record, new_record, '设备记录字段')

    # 解析DEVICE行中的PROTO/PING/STATUS。
    old_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);if(type==='ARP')currentArp[ip]=1;}}"
    new_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);var pf=(z.match(/PROTO=(.*?) PING=/)||[])[1]||'';var pg=(z.match(/PING=([^ ]+)/)||[])[1]||'';var bs=(z.match(/STATUS=([^ ]+)/)||[])[1]||'';if(r){if(pf){pf.split(/ \/ /).forEach(function(t){add_protocol(r,t);});}if(pg)r.ping=pg;if(bs)r.backend_status=bs;}if(type==='ARP')currentArp[ip]=1;}}"
    page = must_replace(page, old_merge, new_merge, '设备Ping状态解析')

    # 后端Ping优先决定在线状态。
    old_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '正常';}"
    new_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.backend_status==='在线'||row.backend_status==='暂时离线'||row.backend_status==='IP冲突')return row.backend_status;if(row.ping==='通')return '在线';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '在线';}"
    page = must_replace(page, old_status, new_status, '在线状态计算')

    # 信息栏清洗：Ping/STATUS/PING/MISS不再混进设备描述。
    if 'function clean_device_info(v)' not in page:
        page = must_replace(page, 'function mac_norm(v){', "function clean_device_info(v){var s=String(v==null?'':v);s=s.replace(/^Ping：[[:space:]]*[^；]*；[[:space:]]*/,'');s=s.replace(/[[:space:]]*STATUS=[^ ]+/g,'');s=s.replace(/[[:space:]]*PING=[^ ]+/g,'');s=s.replace(/[[:space:]]*MISS=[0-9]+/g,'');s=s.replace(/[[:space:]]*Ping：[[:space:]]*[^；]+；/g,'');s=s.replace(/^设备可达$/,'');s=s.replace(/^[；;、，,[:space:]]+|[；;、，,[:space:]]+$/g,'');return s||'-';}\nfunction mac_norm(v){", '设备信息清洗函数')

    old_info = "var info=(z.match(/INFO=(.*)$/)||[])[1]||'-';"
    new_info = "var info=clean_device_info((z.match(/INFO=(.*)$/)||[])[1]||'-');"
    page = must_replace(page, old_info, new_info, '设备信息清洗调用')

    # 设备表直接落地为6列。
    old_vals = "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];"
    new_vals = "var vals=[st,protocol,r.ip,displayMac,r.ping||'不可用',clean_device_info(r.info||'-')];"
    page = must_replace(page, old_vals, new_vals, '设备表数据列')

    old_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>'
    new_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>'
    page = must_replace(page, old_header, new_header, '设备表表头')
    page = page.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)

    # 目标网段状态函数。
    if 'function render_target_states(s)' not in page:
        fn = "function render_target_states(s){var box=document.getElementById('target_states');if(!box)return;var raw=String(s||'').replace(/\\r/g,'');var arr=raw.split(';');var rows=[];for(var i=0;i<arr.length;i++){var line=String(arr[i]||'').replace(/^\\s+|\\s+$/g,'');if(!line)continue;var p=line.split('|');if(p.length<2)continue;var net=String(p[0]||'').trim();var ip=String(p[1]||'').trim();if(!/^((\\d{1,3}\\.){3}\\d{1,3})\\/24$/.test(net)||!/^((\\d{1,3}\\.){3}\\d{1,3})$/.test(ip))continue;rows.push({net:net,ip:ip});}rows.sort(function(a,b){return ip_key(a.net.split('/')[0])-ip_key(b.net.split('/')[0]);});if(!rows.length){box.innerHTML='<div class=\"muted\">当前没有生效的目标网段</div>';return;}var html='<table class=\"table table-bordered table-condensed\"><thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead><tbody>';for(var j=0;j<rows.length;j++){html+='<tr><td>'+rows[j].net+'</td><td><strong>'+rows[j].ip+'</strong></td><td>已启用（SNAT）</td></tr>';}html+='</tbody></table>';box.innerHTML=html;}\n"
        page = must_replace(page, 'function render_custom_hint()', fn + 'function render_custom_hint()', '目标网段状态函数位置')

    if 'render_target_states(o.targets)' not in page:
        page = must_replace(page, 'render_devices(o.devices);render_log(o.log);', 'render_devices(o.devices);render_target_states(o.targets);render_log(o.log);', '目标状态刷新')

    if 'id="target_states"' not in page:
        target_html = '<h4 style="margin-top:12px">目标网段与临时IP（SNAT地址）</h4><div class="alert alert-info">下面显示实际生效的目标网段、对应临时IP及SNAT状态。</div><div id="target_states"><div class="muted">等待目标网段状态...</div></div>\n'
        page = must_replace(page, '<h4>IP占用情况 ', target_html + '<h4>IP占用情况 ', '目标网段状态区域')

    PAGE.write_text(page, encoding='utf-8')

    # 这里检查的是实际源码，不是补丁脚本。
    required = [
        '<% lan_discovery_targets(); %>',
        "devices:section(data,'---DEVICES---','---TARGETS---')",
        "targets:section(data,'---TARGETS---','---CUSTOM---')",
        "function render_target_states(s)",
        'render_target_states(o.targets)',
        'id="target_states"',
        '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>',
        "var vals=[st,protocol,r.ip,displayMac,r.ping||'不可用',clean_device_info(r.info||'-')];",
    ]
    for item in required:
        if item not in page:
            raise SystemExit('Q7 WebUI源码修复校验失败：缺少 ' + item)
    print('Q7 WebUI已直接写入实际源码：6列设备表、Ping、目标网段/SNAT状态全部完成。')


if __name__ == '__main__':
    main()
