#!/usr/bin/env python3
from pathlib import Path

DATA = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Data.asp')
PAGE = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')


def replace_required(text, old, new, label):
    if old not in text:
        raise SystemExit('Q7 WebUI最终修复失败：找不到' + label)
    return text.replace(old, new, 1)


def ensure_once(text, old, new):
    if new in text:
        return text
    if old not in text:
        raise SystemExit('Q7 WebUI最终修复失败：找不到最终校正锚点')
    return text.replace(old, new, 1)


def main():
    if not DATA.exists() or not PAGE.exists():
        raise SystemExit('Q7 WebUI最终修复失败：LAN发现页面文件不存在')

    data = DATA.read_text(encoding='utf-8')
    data = data.replace(
        '<% nvram_get_x("", "lan_discovery_status_targets"); %>',
        '<% lan_discovery_targets(); %>',
    )
    for item in [
        '---IFACES---', '---LOG---', '---DEVICES---',
        '---TARGETS---', '---CUSTOM---', '<% lan_discovery_targets(); %>'
    ]:
        if item not in data:
            raise SystemExit('Q7 WebUI最终修复失败：Data接口缺少 ' + item)
    DATA.write_text(data, encoding='utf-8')

    page = PAGE.read_text(encoding='utf-8')

    start = page.find('function parse_data(data){')
    end = page.find('function health_text(v){', start)
    if start < 0 or end < 0:
        raise SystemExit('Q7 WebUI最终修复失败：找不到parse_data边界')
    parse_fn = '''function parse_data(data){data=html_decode(data);var first=(data.split('\\n')[0]||'').split('|');return {iface:value_or(first[1],value_or(initial_status.iface,'eth2.1')),role:value_or(first[2],value_or(initial_status.role,'LAN')),ip:value_or(first[3],value_or(initial_status.ip,'-')),mac:mac_norm(value_or(first[4],value_or(initial_status.mac,'-'))),link:value_or(first[5],value_or(initial_status.link,'-')),dhcp:value_or(first[6],value_or(initial_status.dhcp,'未检测')),state:value_or(first[7],value_or(initial_status.state,'空闲')),count:value_or(first[8],value_or(initial_status.count,'0')),last:value_or(first[9],value_or(initial_status.last,'-')),health:value_or(first[10],value_or(initial_status.health,'未监视')),broadcast:value_or(first[11],value_or(initial_status.broadcast,'0')),loop:value_or(first[12],value_or(initial_status.loop,'0')),interfaces:section(data,'---IFACES---','---LOG---'),log:section(data,'---LOG---','---DEVICES---'),devices:section(data,'---DEVICES---','---TARGETS---'),targets:section(data,'---TARGETS---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')};}\n'''
    page = page[:start] + parse_fn + page[end:]

    old_record = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0};}"
    new_record = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0,ping:'检测中',backend_status:''};}"
    page = ensure_once(page, old_record, new_record)

    old_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);if(type==='ARP')currentArp[ip]=1;}}"
    new_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);var pf=(z.match(/PROTO=(.*?) PING=/)||[])[1]||'';var pg=(z.match(/PING=([^ ]+)/)||[])[1]||'';var bs=(z.match(/STATUS=([^ ]+)/)||[])[1]||'';if(r){if(pf){pf.split(/ \/ /).forEach(function(t){add_protocol(r,t);});}if(pg)r.ping=pg;if(bs)r.backend_status=bs;}if(type==='ARP')currentArp[ip]=1;}}"
    page = ensure_once(page, old_merge, new_merge)

    old_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '正常';}"
    new_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.backend_status==='在线'||row.backend_status==='暂时离线'||row.backend_status==='IP冲突')return row.backend_status;if(row.ping==='通')return '在线';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '在线';}"
    if old_status in page:
        page = page.replace(old_status, new_status, 1)

    if 'function render_target_states(s)' not in page:
        target_function = "function render_target_states(s){var box=document.getElementById('target_states');if(!box)return;var raw=String(s||'').replace(/\\r/g,'');var arr=raw.split(';');var rows=[];for(var i=0;i<arr.length;i++){var line=String(arr[i]||'').replace(/^\\s+|\\s+$/g,'');if(!line)continue;var p=line.split('|');if(p.length<2)continue;var net=String(p[0]||'').trim();var ip=String(p[1]||'').trim();if(!/^((\\d{1,3}\\.){3}\\d{1,3})\\/24$/.test(net)||!/^((\\d{1,3}\\.){3}\\d{1,3})$/.test(ip))continue;rows.push({net:net,ip:ip});}rows.sort(function(a,b){return ip_key(a.net.split('/')[0])-ip_key(b.net.split('/')[0]);});if(!rows.length){box.innerHTML='<div class=\"muted\">当前没有生效的目标网段</div>';return;}var html='<table class=\"table table-bordered table-condensed target-state-table\"><thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead><tbody>';for(var j=0;j<rows.length;j++){html+='<tr><td>'+rows[j].net+'</td><td><strong>'+rows[j].ip+'</strong></td><td>已启用（SNAT）</td></tr>';}html+='</tbody></table>';box.innerHTML=html;}\n"
        page = replace_required(page, 'function render_custom_hint()', target_function + 'function render_custom_hint()', '目标状态函数位置')

    if "render_target_states(o.targets)" not in page:
        page = replace_required(page, 'render_devices(o.devices);render_log(o.log);', 'render_devices(o.devices);render_target_states(o.targets);render_log(o.log);', '目标状态刷新调用')

    if 'id="target_states"' not in page:
        target_html = '<h4 style="margin-top:12px">目标网段与临时IP（SNAT地址）</h4><div class="alert alert-info">下面显示实际生效的目标网段、对应临时IP及SNAT状态。</div><div id="target_states"><div class="muted">等待目标网段状态...</div></div>\n'
        page = replace_required(page, '<h4>IP占用情况 ', target_html + '<h4>IP占用情况 ', '目标状态区域')

    old_vals = "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];"
    final_vals = "var vals=[st,protocol,r.ip,displayMac,r.ping||'不可用',r.info||'-'];"
    existing_vals = "var vals=[st,protocol,r.ip,displayMac,r.ping||'不可用',clean_device_info(r.info||'-')];"
    if final_vals not in page:
        if existing_vals in page:
            page = page.replace(existing_vals, final_vals, 1)
        elif old_vals in page:
            page = page.replace(old_vals, final_vals, 1)
        else:
            raise SystemExit('Q7 WebUI最终修复失败：找不到设备表数据列')

    old_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>'
    final_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>'
    if final_header not in page:
        page = replace_required(page, old_header, final_header, 'Ping表头')
    page = page.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)

    PAGE.write_text(page, encoding='utf-8')

    checks = [
        ('targets:section(data', '目标网段解析'),
        ('render_target_states(o.targets)', '目标状态刷新'),
        ('function render_target_states(s)', '目标状态函数'),
        ('id="target_states"', '目标状态区域'),
        ("ping:'检测中',backend_status:''", '设备Ping状态字段'),
        (final_vals, '设备Ping数据列'),
        (final_header, 'Ping表头'),
    ]
    for item, label in checks:
        if item not in page:
            raise SystemExit('Q7 WebUI最终修复校验失败：缺少' + label)

    print('Q7 LAN发现页面最终校正完成：目标网段、Ping列、设备状态均已强制校验。')


if __name__ == '__main__':
    main()
