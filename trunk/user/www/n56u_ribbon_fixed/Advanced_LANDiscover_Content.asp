<!DOCTYPE html>
<html>
<head>
<title><#Web_Title#> - 局域网自动发现</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.ico">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/engage.itoggle.css">
<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/bootstrap/js/bootstrap.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/bootstrap/js/engage.itoggle.min.js"></script>
<script>
var $j=jQuery.noConflict();
var refresh_timer=null;
var custom_loaded=false;
var initial_status={
    iface:'<% nvram_get_x("", "lan_discovery_status_if"); %>',
    role:'<% nvram_get_x("", "lan_discovery_status_role"); %>',
    ip:'<% nvram_get_x("", "lan_discovery_status_ip"); %>',
    mac:'<% nvram_get_x("", "lan_discovery_status_mac"); %>',
    link:'<% nvram_get_x("", "lan_discovery_status_link"); %>',
    dhcp:'<% nvram_get_x("", "lan_discovery_status_dhcp"); %>',
    state:'<% nvram_get_x("", "lan_discovery_status_state"); %>',
    count:'<% nvram_get_x("", "lan_discovery_status_count"); %>',
    last:'<% nvram_get_x("", "lan_discovery_status_last"); %>'
};
var cfg={
    ifname:'<% nvram_get_x("", "lan_discovery_ifname"); %>',
    ip:'<% nvram_get_x("", "lan_ipaddr"); %>',
    mac:'<% nvram_get_x("", "lan_hwaddr"); %>'
};
<% login_state_hook(); %>

$j(document).ready(function(){
    init_itoggle('lan_discovery_enable');
    init_itoggle('lan_discovery_dhcp_enable');
    init_itoggle('lan_discovery_discover_enable');
    init_itoggle('lan_discovery_onvif');
    init_itoggle('lan_discovery_ssdp');
    init_itoggle('lan_discovery_hik');
    init_itoggle('lan_discovery_dahua');
    init_itoggle('lan_discovery_raw');
});

function has_value(v){ return v !== undefined && v !== null && String(v) !== '' && String(v) !== '-'; }
function value_or(v,d){ return has_value(v) ? String(v) : d; }
function esc(v){ return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;'); }
function norm(v){ return String(v||'').replace(/\r/g,''); }
function section(data,a,b){
    var p=data.indexOf(a); if(p<0) return '';
    p+=a.length; var q=b ? data.indexOf(b,p) : -1;
    return data.substring(p,q<0?data.length:q).replace(/^\n+|\n+$/g,'');
}
function parse_data(data){
    data=norm(data);
    var first=(data.split('\n')[0]||'').split('|');
    return {
        iface:value_or(first[1],value_or(initial_status.iface,value_or(cfg.ifname,'eth2.1'))),
        role:value_or(first[2],value_or(initial_status.role,'LAN')),
        ip:value_or(first[3],value_or(initial_status.ip,value_or(cfg.ip,'-'))),
        mac:value_or(first[4],value_or(initial_status.mac,value_or(cfg.mac,'-'))),
        link:value_or(first[5],value_or(initial_status.link,'-')),
        dhcp:value_or(first[6],value_or(initial_status.dhcp,'未检测')),
        state:value_or(first[7],value_or(initial_status.state,'空闲')),
        count:value_or(first[8],value_or(initial_status.count,'0')),
        last:value_or(first[9],value_or(initial_status.last,'-')),
        interfaces:section(data,'---IFACES---','---LOG---'),
        log:section(data,'---LOG---','---DEVICES---'),
        devices:section(data,'---DEVICES---','---CUSTOM---'),
        custom:section(data,'---CUSTOM---','')
    };
}
function render_status(o){
    $j('#status_iface').text(o.iface);
    $j('#status_role').text(o.role);
    $j('#status_ip').text(o.ip);
    $j('#status_mac').text(o.mac);
    $j('#status_link').text(o.link);
    $j('#status_dhcp').text(o.dhcp);
    $j('#status_state').text(o.state);
    $j('#status_count').text(o.count);
    $j('#status_last').text(o.last);
}
function render_interfaces(s){
    var sel=document.getElementById('lan_ifname');
    var wanted=value_or(cfg.ifname,'eth2.1');
    var lines=norm(s).split('\n');
    var found=false;
    if(!s) return;
    sel.innerHTML='';
    for(var i=0;i<lines.length;i++){
        var f=lines[i].split('|');
        if(f.length<5 || !f[0]) continue;
        if(f[1] !== 'LAN' || /^(lo|br|ra|wds|apcli)/.test(f[0])) continue;
        var opt=document.createElement('option');
        opt.value=f[0]; opt.text=f[0]+' | '+f[1]+' | '+(f[2]||'-')+' | '+(f[4]||'-');
        if(f[0]===wanted){ opt.selected=true; found=true; }
        sel.appendChild(opt);
    }
    if(!sel.options.length){
        var opt2=document.createElement('option');
        opt2.value=wanted; opt2.text=wanted+' | LAN | '+value_or(cfg.ip,'-')+' | UP'; opt2.selected=true; sel.appendChild(opt2);
    }else if(!found){ sel.selectedIndex=0; }
}
function render_devices(s){
    var body=document.getElementById('devices');
    var lines=norm(s).split('\n');
    body.innerHTML='';
    for(var i=0;i<lines.length;i++){
        var z=lines[i];
        if(z.indexOf('DEVICE ')!==0) continue;
        var type=(z.match(/type=([^ ]+)/)||[])[1]||'-';
        var ip=(z.match(/IP=([^ ]+)/)||[])[1]||'-';
        var mac=(z.match(/MAC=([^ ]+)/)||[])[1]||'-';
        var info=(z.match(/INFO=(.*)$/)||[])[1]||'-';
        var tr=document.createElement('tr');
        tr.innerHTML='<td>-</td><td>'+esc(type)+'</td><td>'+esc(ip)+'</td><td>'+esc(mac)+'</td><td>'+esc(info)+'</td>';
        body.appendChild(tr);
    }
    if(!body.children.length) body.innerHTML='<tr><td colspan="5" class="muted">暂无设备</td></tr>';
}
function add_custom_row(name,addr,port,payload,en){
    var id='lan_custom_'+(new Date().getTime())+'_'+Math.floor(Math.random()*100000);
    var row=document.createElement('div'); row.className='custom_row';
    var on=String(en)==='1';
    row.innerHTML='<table class="table table-condensed" style="margin:5px 0">'+
      '<tr><td width="18%"><input class="span12 c_name" value="'+esc(name||'')+'"></td>'+ 
      '<td width="23%"><input class="span12 c_addr" value="'+esc(addr||'')+'"></td>'+ 
      '<td width="12%"><input class="span12 c_port" value="'+esc(port||'')+'"></td>'+ 
      '<td width="27%"><input class="span12 c_payload" value="'+esc(payload||'')+'"></td>'+ 
      '<td width="12%"><div class="main_itoggle"><div id="'+id+'_on_of"><input type="checkbox" id="'+id+'_fake" '+(on?'checked':'')+'></div></div>'+ 
      '<div style="position:absolute;margin-left:-10000px"><input type="radio" id="'+id+'_1" name="'+id+'" value="1" '+(on?'checked':'')+'><input type="radio" id="'+id+'_0" name="'+id+'" value="0" '+(!on?'checked':'')+'></div>'+ 
      '<input type="hidden" class="c_enable" value="'+(on?'1':'0')+'"></td>'+ 
      '<td width="8%"><button type="button" class="btn btn-danger btn-mini" onclick="remove_custom(this);return false;">删除</button></td></tr></table>';
    document.getElementById('custom_list').appendChild(row);
    init_itoggle(id,function(){ row.querySelector('.c_enable').value=document.getElementById(id+'_fake').checked?'1':'0'; });
}
function remove_custom(btn){
    var row=btn; while(row && !/(^| )custom_row( |$)/.test(row.className||'')) row=row.parentNode;
    if(row && row.parentNode) row.parentNode.removeChild(row);
}
function render_custom(s){
    if(custom_loaded || !s) return;
    custom_loaded=true;
    var lines=norm(s).split('\n');
    for(var i=0;i<lines.length;i++){
        if(!lines[i]) continue;
        var f=lines[i].split('|'); if(f.length<5) continue;
        var n=f[0],a=f[1],p=f[2],y=f[3];
        try{ n=decodeURIComponent(n); a=decodeURIComponent(a); p=decodeURIComponent(p); y=decodeURIComponent(y); }catch(e){}
        add_custom_row(n,a,p,y,f[4]);
    }
}
function add_custom(){ add_custom_row('','','','',1); }
function serialize_custom(){
    var rows=document.getElementById('custom_list').getElementsByTagName('div');
    var out=[];
    for(var i=0;i<rows.length;i++){
        if(!/(^| )custom_row( |$)/.test(rows[i].className||'')) continue;
        out.push(encodeURIComponent(rows[i].querySelector('.c_name').value)+'|'+
                 encodeURIComponent(rows[i].querySelector('.c_addr').value)+'|'+
                 encodeURIComponent(rows[i].querySelector('.c_port').value)+'|'+
                 encodeURIComponent(rows[i].querySelector('.c_payload').value)+'|'+
                 rows[i].querySelector('.c_enable').value);
    }
    document.form.lan_discovery_custom.value=out.join('\n');
}
function refresh_data(){
    var x=new XMLHttpRequest();
    x.onreadystatechange=function(){
        if(x.readyState!==4 || x.status!==200) return;
        var o=parse_data(x.responseText);
        render_status(o);
        render_interfaces(o.interfaces);
        render_devices(o.devices);
        render_custom(o.custom);
        var lg=document.getElementById('live_log'); lg.textContent=o.log||'暂无日志'; lg.scrollTop=lg.scrollHeight;
    };
    x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);
    x.send(null);
}
function applyRule(){
    if(!login_safe()) return false;
    serialize_custom();
    showLoading();
    document.form.action_mode.value=' Apply ';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='';
    document.form.submit();
    return false;
}
function clearLog(){
    if(!login_safe()) return false;
    document.form.lan_discovery_log.value='';
    applyRule();
}
function initial(){
    show_banner(1); show_menu(8,0,0); show_footer();
    render_status({iface:value_or(initial_status.iface,value_or(cfg.ifname,'eth2.1')),role:value_or(initial_status.role,'LAN'),ip:value_or(initial_status.ip,value_or(cfg.ip,'-')),mac:value_or(initial_status.mac,value_or(cfg.mac,'-')),link:value_or(initial_status.link,'-'),dhcp:value_or(initial_status.dhcp,'未检测'),state:value_or(initial_status.state,'空闲'),count:value_or(initial_status.count,'0'),last:value_or(initial_status.last,'-')});
    if(!document.form.lan_discovery_dhcp_timeout.value) document.form.lan_discovery_dhcp_timeout.value='3';
    if(!document.form.lan_discovery_cycle.value) document.form.lan_discovery_cycle.value='10';
    if(!document.form.lan_discovery_onvif_port.value) document.form.lan_discovery_onvif_port.value='3702';
    if(!document.form.lan_discovery_ssdp_port.value) document.form.lan_discovery_ssdp_port.value='1900';
    if(!document.form.lan_discovery_hik_port.value) document.form.lan_discovery_hik_port.value='37020';
    if(!document.form.lan_discovery_dahua_port.value) document.form.lan_discovery_dahua_port.value='37810';
    refresh_data();
    if(refresh_timer) clearInterval(refresh_timer);
    refresh_timer=setInterval(refresh_data,1000);
}
</script>
<style>
.status-table td{white-space:nowrap}
.help-tip{cursor:help;color:#888}
.mini{width:48px;margin:0 4px}
.live-box{height:170px;overflow:auto;background:#111;color:#ddd;padding:8px;font:12px monospace}
.custom_row{margin:5px 0}
.table th,.table td{vertical-align:middle}
</style>
</head>
<body onload="initial();" onunload="return unload_body();">
<div class="wrapper">
<div class="container-fluid"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="sid_list" value="LANHostConfig;">
<input type="hidden" name="action_mode" value="">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="lan_discovery_log" id="lan_discovery_log" value="<% nvram_get_x("", "lan_discovery_log"); %>">
<input type="hidden" name="lan_discovery_custom" id="lan_discovery_custom" value="<% nvram_get_x("", "lan_discovery_custom"); %>">
<div class="container-fluid"><div class="row-fluid">
<div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">局域网自动发现</h2><div class="round_bottom"><div id="tabMenu" class="submenuBlock"></div><div class="alert alert-info" style="margin:10px">LAN状态、DHCP检测和设备发现由后端程序提供；页面只负责配置和显示。</div>
<table class="table table-condensed"><tr><th colspan="4">当前状态</th></tr><tr><td>检测接口</td><td id="status_iface">-</td><td>IPv4</td><td id="status_ip">-</td></tr><tr><td>MAC</td><td id="status_mac">-</td><td>Link</td><td id="status_link">-</td></tr><tr><td>DHCP</td><td id="status_dhcp">-</td><td>发现状态</td><td id="status_state">-</td></tr><tr><td>已发现</td><td id="status_count">0</td><td>最后活动</td><td id="status_last">-</td></tr></table>
<table class="table table-bordered table-condensed">
<tr><th width="180">检测接口 <span class="help-tip" title="后端发现所使用的 LAN 接口；单网口 Q7 当前为 eth2.1。">ⓘ</span></th><td><select name="lan_discovery_ifname" id="lan_ifname" class="span9"><option value="<% nvram_get_x("", "lan_discovery_ifname"); %>" selected><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN | <% nvram_get_x("", "lan_ipaddr"); %> | UP</option></select></td></tr>
<tr><th>LAN事件检测 <span class="help-tip" title="对应后端 lan_discovery_enable。后续将拆分为独立的 LAN 热插拔监听开关。">ⓘ</span></th><td><div class="main_itoggle"><div id="lan_discovery_enable_on_of"><input type="checkbox" id="lan_discovery_enable_fake" <% nvram_match_x("", "lan_discovery_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_enable" id="lan_discovery_enable_1" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_enable" id="lan_discovery_enable_0" <% nvram_match_x("", "lan_discovery_enable", "0", "checked"); %>></div></td></tr>
<tr><th>DHCP检测 <span class="help-tip" title="Link UP 后执行 dhcpdetect。">ⓘ</span></th><td><div class="main_itoggle"><div id="lan_discovery_dhcp_enable_on_of"><input type="checkbox" id="lan_discovery_dhcp_enable_fake" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "checked"); %>></div> 等待 <input class="mini" name="lan_discovery_dhcp_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒</td></tr>
<tr><th>设备发现 <span class="help-tip" title="持续运行 camdiscover；周期仅控制主动探测间隔。">ⓘ</span></th><td><div class="main_itoggle"><div id="lan_discovery_discover_enable_on_of"><input type="checkbox" id="lan_discovery_discover_enable_fake" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "checked"); %>></div> 周期 <input class="mini" name="lan_discovery_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒</td></tr>
<tr><th>ARP/IP</th><td><div class="main_itoggle"><div id="lan_discovery_raw_on_of"><input type="checkbox" id="lan_discovery_raw_fake" <% nvram_match_x("", "lan_discovery_raw", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_raw" id="lan_discovery_raw_1" <% nvram_match_x("", "lan_discovery_raw", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_raw" id="lan_discovery_raw_0" <% nvram_match_x("", "lan_discovery_raw", "0", "checked"); %>></div></td></tr>
<tr><th>ONVIF</th><td><div class="main_itoggle"><div id="lan_discovery_onvif_on_of"><input type="checkbox" id="lan_discovery_onvif_fake" <% nvram_match_x("", "lan_discovery_onvif", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_onvif" id="lan_discovery_onvif_1" <% nvram_match_x("", "lan_discovery_onvif", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_onvif" id="lan_discovery_onvif_0" <% nvram_match_x("", "lan_discovery_onvif", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_onvif_port" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"></td></tr>
<tr><th>SSDP</th><td><div class="main_itoggle"><div id="lan_discovery_ssdp_on_of"><input type="checkbox" id="lan_discovery_ssdp_fake" <% nvram_match_x("", "lan_discovery_ssdp", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_ssdp" id="lan_discovery_ssdp_1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_ssdp" id="lan_discovery_ssdp_0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_ssdp_port" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"></td></tr>
<tr><th>HIK-SADP</th><td><div class="main_itoggle"><div id="lan_discovery_hik_on_of"><input type="checkbox" id="lan_discovery_hik_fake" <% nvram_match_x("", "lan_discovery_hik", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_hik" id="lan_discovery_hik_1" <% nvram_match_x("", "lan_discovery_hik", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_hik" id="lan_discovery_hik_0" <% nvram_match_x("", "lan_discovery_hik", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_hik_port" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"></td></tr>
<tr><th>DAHUA-DHIP</th><td><div class="main_itoggle"><div id="lan_discovery_dahua_on_of"><input type="checkbox" id="lan_discovery_dahua_fake" <% nvram_match_x("", "lan_discovery_dahua", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_dahua" id="lan_discovery_dahua_1" <% nvram_match_x("", "lan_discovery_dahua", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dahua" id="lan_discovery_dahua_0" <% nvram_match_x("", "lan_discovery_dahua", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_dahua_port" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"></td></tr>
</table>
<h4>已发现设备</h4><table class="table table-bordered table-condensed"><thead><tr><th>时间</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th></tr></thead><tbody id="devices"><tr><td colspan="5" class="muted">暂无设备</td></tr></tbody></table>
<h4>实时发现日志 <button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空</button></h4><pre id="live_log" class="live-box">暂无日志</pre>
<h4>自定义 UDP 发现协议 <button type="button" class="btn btn-success btn-mini pull-right" onclick="add_custom();return false;">＋ 添加</button></h4>
<div class="muted">可无限添加；开关使用系统原生样式。</div><div id="custom_list"></div>
<table class="table"><tr><td style="border:0"><center><input type="button" class="btn btn-primary" style="width:219px" value="保存" onclick="applyRule();return false;"></center></td></tr></table>
</div></div></div>
</div></div></div>
</form><div id="footer"></div></div>
</body>
</html>