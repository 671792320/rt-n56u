<!DOCTYPE html>
<html>
<head>
<title><#Web_Title#> - LAN监听与设备发现</title>
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
<script type="text/javascript" src="/bootstrap/js/engage.itoggle.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script>
var $j=jQuery.noConflict();
var refresh_timer=null;
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
<% login_state_hook(); %>
function value_or(v,d){return(v!==undefined&&v!==null&&String(v)!==''&&String(v)!=='-')?String(v):d;}
function link_text(v){v=String(v||'');return v==='UP'?'已插入':(v==='DOWN'?'未插入':v||'-');}
function norm(v){var s=String(v||'').replace(/\r/g,'');for(var i=0;i<3;i++){s=s.replace(/&amp;#38;/gi,'&#38;').replace(/&amp;#10;/gi,'&#10;').replace(/&amp;#13;/gi,'&#13;').replace(/&amp;#8232;/gi,'&#8232;').replace(/&amp;#x2028;/gi,'&#x2028;');}return s.replace(/(?:&amp;|&#38;)#13;/gi,'').replace(/(?:&amp;|&#38;)#10;/gi,'\n').replace(/(?:&amp;|&#38;)#8232;/gi,'\u2028').replace(/(?:&amp;|&#38;)#x2028;/gi,'\u2028').replace(/&#13;/g,'').replace(/&#10;/g,'\n').replace(/&#8232;/g,'\u2028').replace(/&#x2028;/gi,'\u2028');}
function lines(v){return norm(v).split(/\n|\u2028/).map(function(x){return String(x).replace(/^\s+|\s+$/g,'');}).filter(function(x){return x!=='';});}
function esc(v){return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;');}
function mac_norm(v){var m=String(v==null?'':v).replace(/&(?:#10|#13|#8232);/gi,'').replace(/\\/g,'').replace(/\s+/g,'').toUpperCase();return /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(m)?m:'-';}
function section(data,a,b){var p=data.indexOf(a);if(p<0)return '';p+=a.length;var q=b?data.indexOf(b,p):-1;return data.substring(p,q<0?data.length:q).replace(/^\n+|\n+$/g,'');}
function parse_data(data){
 data=norm(data);
 var first=(data.split('\n')[0]||'').split('|');
 return {iface:value_or(first[1],value_or(initial_status.iface,'eth2.1')),role:value_or(first[2],value_or(initial_status.role,'LAN')),ip:value_or(first[3],value_or(initial_status.ip,'-')),mac:mac_norm(value_or(first[4],value_or(initial_status.mac,'-'))),link:value_or(first[5],value_or(initial_status.link,'-')),dhcp:value_or(first[6],value_or(initial_status.dhcp,'未检测')),state:value_or(first[7],value_or(initial_status.state,'空闲')),count:value_or(first[8],value_or(initial_status.count,'0')),last:value_or(first[9],value_or(initial_status.last,'-')),interfaces:section(data,'---IFACES---','---LOG---'),log:section(data,'---LOG---','---DEVICES---'),devices:section(data,'---DEVICES---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')};
}
function render_status(o){$j('#status_iface').text(o.iface);$j('#status_role').text(o.role);$j('#status_ip').text(o.ip);$j('#status_mac').text(mac_norm(o.mac));$j('#status_link').text(link_text(o.link));$j('#status_dhcp').text(o.dhcp);$j('#status_state').text(o.state);$j('#status_count').text(o.count);$j('#status_last').text(o.last);}
function render_interfaces(s){
 var sel=document.getElementById('lan_ifname');if(!sel)return;var wanted='<% nvram_get_x("", "lan_discovery_ifname"); %>';var ls=lines(s);var found=false;sel.innerHTML='';
 for(var i=0;i<ls.length;i++){var f=ls[i].split('|');if(f.length<5||!f[0]||f[1]!=='LAN'||/^(lo|br|ra|wds|apcli)/.test(f[0]))continue;var opt=document.createElement('option');opt.value=f[0];opt.text=f[0]+' | '+f[1]+' | '+(f[2]||'-')+' | '+link_text(f[4]);if(f[0]===wanted){opt.selected=true;found=true;}sel.appendChild(opt);}
 if(!sel.options.length){var o=document.createElement('option');o.value=wanted||'eth2.1';o.text=(wanted||'eth2.1')+' | LAN';o.selected=true;sel.appendChild(o);}else if(!found)sel.selectedIndex=0;
}
function render_devices(s){
 var body=document.getElementById('devices');if(!body)return;body.innerHTML='';var ls=lines(s),byIp={};
 for(var i=0;i<ls.length;i++){
  var z=ls[i];if(z.indexOf('DEVICE ')!==0)continue;
  var type=(z.match(/type=([^ ]+)/)||[])[1]||'-';
  var ip=(z.match(/IP=([^ ]+)/)||[])[1]||'-';
  var mac=mac_norm((z.match(/MAC=([^ ]+)/)||[])[1]||'-');
  var info=(z.match(/INFO=(.*)$/)||[])[1]||'-';
  var key=ip;
  if(byIp[key]){
   var row=byIp[key];
   if(type!=='-' && row.type.indexOf(type)<0)row.type=row.type==='-'?type:row.type+'/'+type;
   if(row.mac==='-' && mac!=='-')row.mac=mac;
   if((row.info==='-'||!row.info) && info!=='-')row.info=info;
   row.cells[1].textContent=row.type;row.cells[3].textContent=row.mac;row.cells[4].textContent=row.info;
   continue;
  }
  var tr=document.createElement('tr');
  var cells=[];for(var c=0;c<5;c++){cells[c]=document.createElement('td');tr.appendChild(cells[c]);}
  cells[0].textContent='-';cells[1].textContent=type;cells[2].textContent=ip;cells[3].textContent=mac;cells[4].textContent=info;
  body.appendChild(tr);byIp[key]={type:type,mac:mac,info:info,cells:cells};
 }
 if(!body.children.length)body.innerHTML='<tr><td colspan="5" class="muted">暂无设备</td></tr>';
}
function render_log(s){
 var lg=document.getElementById('live_log');if(!lg)return;var ls=lines(s),out=[];
 for(var i=0;i<ls.length;i++){var t=String(ls[i]).replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g,'');if(/^\d{2}:\d{2}:\d{2} /.test(t))out.push(t);}
 lg.textContent=out.join('\n')||'暂无日志';lg.scrollTop=lg.scrollHeight;
}
function refresh_data(){
 var x=new XMLHttpRequest();x.onreadystatechange=function(){if(x.readyState!==4||x.status!==200)return;var o=parse_data(x.responseText);render_status(o);render_interfaces(o.interfaces);render_devices(o.devices);render_log(o.log);};
 x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);x.send(null);
}
function applyRule(){
 if(!login_safe())return false;
 showLoading();
 document.form.action_mode.value=' Apply ';
 document.form.current_page.value='Advanced_LANDiscover_Content.asp';
 document.form.next_page.value='';
 document.form.submit();
 return false;
}
function clearLog(){if(!login_safe())return false;document.form.lan_discovery_log.value='';applyRule();}
function initial(){
 show_banner(1);show_menu(5,3,1);show_footer();
 render_status({iface:value_or(initial_status.iface,'eth2.1'),role:value_or(initial_status.role,'LAN'),ip:value_or(initial_status.ip,'-'),mac:mac_norm(value_or(initial_status.mac,'-')),link:value_or(initial_status.link,'-'),dhcp:value_or(initial_status.dhcp,'未检测'),state:value_or(initial_status.state,'空闲'),count:value_or(initial_status.count,'0'),last:value_or(initial_status.last,'-')});
 refresh_data();if(refresh_timer)clearInterval(refresh_timer);refresh_timer=setInterval(refresh_data,1000);
}
$j(document).ready(function(){
 init_itoggle('lan_discovery_enable');init_itoggle('lan_discovery_dhcp_enable');init_itoggle('lan_discovery_discover_enable');init_itoggle('lan_discovery_onvif');init_itoggle('lan_discovery_ssdp');init_itoggle('lan_discovery_hik');init_itoggle('lan_discovery_dahua');init_itoggle('lan_discovery_raw');
});
</script>
<style>
.status-table td{white-space:nowrap}.mini{width:48px;margin:0 4px}.live-box{height:170px;overflow-y:auto;overflow-x:hidden;background:#111;color:#ddd;padding:8px;font:12px monospace;white-space:pre-wrap;word-break:break-all}.table th,.table td{vertical-align:middle}
</style>
</head>
<body onLoad="initial();" onunload="return unload_body();">
<div class="wrapper">
<div class="container-fluid" style="padding-right:0px"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="next_host" value="">
<input type="hidden" name="sid_list" value="LANHostConfig;">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="action_mode" value="">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="lan_discovery_log" id="lan_discovery_log" value="">
<input type="hidden" name="lan_discovery_custom" id="lan_discovery_custom" value="">
<div class="container-fluid"><div class="row-fluid">
<div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN监听与设备发现</h2><div class="round_bottom"><div id="tabMenu" class="submenuBlock"></div><div class="alert alert-info" style="margin:10px">LAN口插拔、上级DHCP和设备发现由后端程序实时监听；页面负责配置和显示。</div>
<table class="table table-condensed"><tr><th colspan="4">当前状态</th></tr><tr><td>检测接口</td><td id="status_iface">-</td><td>LAN IPv4</td><td id="status_ip">-</td></tr><tr><td>LAN MAC</td><td id="status_mac">-</td><td>LAN口状态</td><td id="status_link">-</td></tr><tr><td>上级DHCP</td><td id="status_dhcp">-</td><td>发现状态</td><td id="status_state">-</td></tr><tr><td>已发现</td><td id="status_count">0</td><td>最后活动</td><td id="status_last">-</td></tr></table>
<table class="table table-bordered table-condensed">
<tr><th width="180">检测接口</th><td><select name="lan_discovery_ifname" id="lan_ifname" class="span9"><option value="<% nvram_get_x("", "lan_discovery_ifname"); %>" selected><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN</option></select></td></tr>
<tr><th>LAN监听</th><td><div class="main_itoggle"><div id="lan_discovery_enable_on_of"><input type="checkbox" id="lan_discovery_enable_fake" <% nvram_match_x("", "lan_discovery_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_enable" id="lan_discovery_enable_1" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_enable" id="lan_discovery_enable_0" <% nvram_match_x("", "lan_discovery_enable", "0", "checked"); %>></div></td></tr>
<tr><th>DHCP检测</th><td><div class="main_itoggle"><div id="lan_discovery_dhcp_enable_on_of"><input type="checkbox" id="lan_discovery_dhcp_enable_fake" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "checked"); %>></div> 等待 <input class="mini" name="lan_discovery_dhcp_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒</td></tr>
<tr><th>设备发现</th><td><div class="main_itoggle"><div id="lan_discovery_discover_enable_on_of"><input type="checkbox" id="lan_discovery_discover_enable_fake" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "checked"); %>></div> 周期 <input class="mini" name="lan_discovery_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒</td></tr>
<tr><th>ARP/IP</th><td><div class="main_itoggle"><div id="lan_discovery_raw_on_of"><input type="checkbox" id="lan_discovery_raw_fake" <% nvram_match_x("", "lan_discovery_raw", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_raw" id="lan_discovery_raw_1" <% nvram_match_x("", "lan_discovery_raw", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_raw" id="lan_discovery_raw_0" <% nvram_match_x("", "lan_discovery_raw", "0", "checked"); %>></div></td></tr>
<tr><th>ONVIF</th><td><div class="main_itoggle"><div id="lan_discovery_onvif_on_of"><input type="checkbox" id="lan_discovery_onvif_fake" <% nvram_match_x("", "lan_discovery_onvif", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_onvif" id="lan_discovery_onvif_1" <% nvram_match_x("", "lan_discovery_onvif", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_onvif" id="lan_discovery_onvif_0" <% nvram_match_x("", "lan_discovery_onvif", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_onvif_port" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"></td></tr>
<tr><th>SSDP</th><td><div class="main_itoggle"><div id="lan_discovery_ssdp_on_of"><input type="checkbox" id="lan_discovery_ssdp_fake" <% nvram_match_x("", "lan_discovery_ssdp", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_ssdp" id="lan_discovery_ssdp_1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_ssdp" id="lan_discovery_ssdp_0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_ssdp_port" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"></td></tr>
<tr><th>HIK-SADP</th><td><div class="main_itoggle"><div id="lan_discovery_hik_on_of"><input type="checkbox" id="lan_discovery_hik_fake" <% nvram_match_x("", "lan_discovery_hik", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_hik" id="lan_discovery_hik_1" <% nvram_match_x("", "lan_discovery_hik", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_hik" id="lan_discovery_hik_0" <% nvram_match_x("", "lan_discovery_hik", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_hik_port" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"></td></tr>
<tr><th>DAHUA-DHIP</th><td><div class="main_itoggle"><div id="lan_discovery_dahua_on_of"><input type="checkbox" id="lan_discovery_dahua_fake" <% nvram_match_x("", "lan_discovery_dahua", "1", "value=1 checked"); %>></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" value="1" name="lan_discovery_dahua" id="lan_discovery_dahua_1" <% nvram_match_x("", "lan_discovery_dahua", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dahua" id="lan_discovery_dahua_0" <% nvram_match_x("", "lan_discovery_dahua", "0", "checked"); %>></div> 端口 <input class="mini" name="lan_discovery_dahua_port" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"></td></tr>
</table>
<h4>已发现设备</h4><table class="table table-bordered table-condensed"><thead><tr><th>时间</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th></tr></thead><tbody id="devices"><tr><td colspan="5" class="muted">暂无设备</td></tr></tbody></table>
<h4>实时监听日志 <button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空日志</button></h4><pre id="live_log" class="live-box">暂无日志</pre>
<table class="table"><tr><td style="border:0"><center><input class="btn btn-primary" style="width:219px" type="button" value="保存" onclick="applyRule();return false;"></center></td></tr></table>
</div></div></div></div></div></div>
</form><div id="footer"></div></div>
</body>
</html>