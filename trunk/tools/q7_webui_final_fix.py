#!/usr/bin/env python3
from pathlib import Path

DATA = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Data.asp')
PAGE = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')


def main():
    # 保持Padavan原生EJ目标数据，同时绝不破坏WebUI其它数据分段。
    s = DATA.read_text(encoding='utf-8')
    s = s.replace(
        '<% nvram_get_x("", "lan_discovery_status_targets"); %>',
        '<% lan_discovery_targets(); %>',
    )
    required_data = ['---IFACES---', '---LOG---', '---DEVICES---', '---TARGETS---', '---CUSTOM---', '<% lan_discovery_targets(); %>']
    for item in required_data:
        if item not in s:
            raise SystemExit('Q7 WebUI最终修复失败：Data接口缺少 ' + item)
    DATA.write_text(s, encoding='utf-8')

    s = PAGE.read_text(encoding='utf-8')

    # parse_data最终统一支持目标网段分段，避免前后补丁造成数据格式不一致。
    start = s.find('function parse_data(data){')
    end = s.find('function health_text(v){', start)
    if start < 0 or end < 0:
        raise SystemExit('Q7 WebUI最终修复失败：找不到parse_data边界')
    parse_fn = '''function parse_data(data){data=html_decode(data);var first=(data.split('\\n')[0]||'').split('|');return {iface:value_or(first[1],value_or(initial_status.iface,'eth2.1')),role:value_or(first[2],value_or(initial_status.role,'LAN')),ip:value_or(first[3],value_or(initial_status.ip,'-')),mac:mac_norm(value_or(first[4],value_or(initial_status.mac,'-'))),link:value_or(first[5],value_or(initial_status.link,'-')),dhcp:value_or(first[6],value_or(initial_status.dhcp,'未检测')),state:value_or(first[7],value_or(initial_status.state,'空闲')),count:value_or(first[8],value_or(initial_status.count,'0')),last:value_or(first[9],value_or(initial_status.last,'-')),health:value_or(first[10],value_or(initial_status.health,'未监视')),broadcast:value_or(first[11],value_or(initial_status.broadcast,'0')),loop:value_or(first[12],value_or(initial_status.loop,'0')),interfaces:section(data,'---IFACES---','---LOG---'),log:section(data,'---LOG---','---DEVICES---'),devices:section(data,'---DEVICES---','---TARGETS---'),targets:section(data,'---TARGETS---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')};}\n'''
    s = s[:start] + parse_fn + s[end:]

    # 设备记录必须保存Ping和后端状态，页面状态优先采用后端真实结果。
    if "ping:'检测中',backend_status:''" not in s:
        old = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0};}"
        new = "function make_device_record(type,ip,mac,info){return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false,proto_fail:false,miss:0,ping:'检测中',backend_status:''};}"
        if old not in s:
            raise SystemExit('Q7 WebUI最终修复失败：找不到设备记录函数')
        s = s.replace(old, new, 1)

    old_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);if(type==='ARP')currentArp[ip]=1;}}"
    new_merge = "else{var r=merge_device_record(byIp,rows,type,ip,mac,info);var pf=(z.match(/PROTO=(.*?) PING=/)||[])[1]||'';var pg=(z.match(/PING=([^ ]+)/)||[])[1]||'';var bs=(z.match(/STATUS=([^ ]+)/)||[])[1]||'';if(r){if(pf){pf.split(/ \/ /).forEach(function(t){add_protocol(r,t);});}if(pg)r.ping=pg;if(bs)r.backend_status=bs;}if(type==='ARP')currentArp[ip]=1;}}"
    if old_merge in s:
        s = s.replace(old_merge, new_merge, 1)

    old_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '正常';}"
    new_status = "function infer_status(row,type){if(row.conflict)return 'IP冲突';if(row.backend_status==='在线'||row.backend_status==='暂时离线'||row.backend_status==='IP冲突')return row.backend_status;if(row.ping==='通')return '在线';if(row.proto_fail)return '协议异常';if(row.miss>=3)return '暂时离线';return '在线';}"
    if old_status in s:
        s = s.replace(old_status, new_status, 1)

    # 目标网段表必须实际挂到刷新结果。
    if "render_target_states(o.targets)" not in s:
        s = s.replace('render_devices(o.devices);render_log(o.log);', 'render_devices(o.devices);render_target_states(o.targets);render_log(o.log);', 1)

    if 'function render_target_states(s)' not in s:
        target_function = "function render_target_states(s){var box=document.getElementById('target_states');if(!box)return;var raw=String(s||'').replace(/\\r/g,'');var arr=raw.split(';');var rows=[];for(var i=0;i<arr.length;i++){var line=String(arr[i]||'').replace(/^\\s+|\\s+$/g,'');if(!line)continue;var p=line.split('|');if(p.length<2)continue;var net=String(p[0]||'').trim();var ip=String(p[1]||'').trim();if(!/^((\\d{1,3}\\.){3}\\d{1,3})\\/24$/.test(net)||!/^((\\d{1,3}\\.){3}\\d{1,3})$/.test(ip))continue;rows.push({net:net,ip:ip});}rows.sort(function(a,b){return ip_key(a.net.split('/')[0])-ip_key(b.net.split('/')[0]);});if(!rows.length){box.innerHTML='<div class=\"muted\">当前没有生效的目标网段</div>';return;}var html='<table class=\"table table-bordered table-condensed target-state-table\"><thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead><tbody>';for(var j=0;j<rows.length;j++){html+='<tr><td>'+rows[j].net+'</td><td><strong>'+rows[j].ip+'</strong></td><td>已启用（SNAT）</td></tr>';}html+='</tbody></table>';box.innerHTML=html;}\n"
        marker = 'function render_custom_hint()'
        if marker not in s:
            raise SystemExit('Q7 WebUI最终修复失败：找不到WebUI函数插入位置')
        s = s.replace(marker, target_function + marker, 1)

    if 'id="target_states"' not in s:
        marker = '<h4>IP占用情况 '
        html = '<h4 style="margin-top:12px">目标网段与临时IP（SNAT地址）</h4><div class="alert alert-info">下面显示实际生效的目标网段、对应临时IP及SNAT状态。</div><div id="target_states"><div class="muted">等待目标网段状态...</div></div>\n'
        if marker not in s:
            raise SystemExit('Q7 WebUI最终修复失败：找不到目标状态区域')
        s = s.replace(marker, html + marker, 1)

    if '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>' not in s:
        s = s.replace('<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>', '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>', 1)

    PAGE.write_text(s, encoding='utf-8')

    checks = [
        'targets:section(data',
        'render_target_states(o.targets)',
        'function render_target_states(s)',
        'id="target_states"',
        'ping:\'检测中\'',
        '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>',
    ]
    for item in checks:
        if item not in s:
            raise SystemExit('Q7 WebUI最终修复校验失败：' + item)

    print('Q7 WebUI最终数据接口和目标状态显示校正完成。')


if __name__ == '__main__':
    main()
