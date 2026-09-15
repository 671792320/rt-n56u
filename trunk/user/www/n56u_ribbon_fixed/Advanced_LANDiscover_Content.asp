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
<script type="text/javascript" src="/login_state_hook.js"></script>
<script>
var $j=jQuery.noConflict();
var refresh_timer=null;
var initial_custom='<% nvram_get_x("", "lan_discovery_custom"); %>';
var initial_status={
 iface:'<% nvram_get_x("", "lan_discovery_status_if"); %>',
 ip:'<% nvram_get_x("", "lan_discovery_status_ip"); %>',
 mac:'<% nvram_get_x("", "lan_discovery_status_mac"); %>',
 link:'<% nvram_get_x("", "lan_discovery_status_link"); %>',
 dhcp:'<% nvram_get_x("", "lan_discovery_status_dhcp"); %>',
 state:'<% nvram_get_x("", "lan_discovery_status_state"); %>',
 count:'<% nvram_get_x("", "lan_discovery_status_count"); %>',
 last:'<% nvram_get_x("", "lan_discovery_status_last"); %>'
};
<% login_state_hook(); %>
function esc(v){return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function lines(v){return String(v||'').replace(/\r/g,'').replace(/&#10;/g,'\n').split(/\n/);}
function valueOr(v,d){return v!==undefined&&v!==null&&String(v)!==''?String(v):d;}
function setToggle(name,value){var f=document.getElementById(name+'_fake'),r1=document.getElementById(name+'_1'),r0=document.getElementById(name+'_0');if(!f||!r1||!r0)return;var on=String(value)==='1';f.checked=on;r1.checked=on;r0.checked=!on;try{init_itoggle(name);}catch(e){}}
function standardAddress(name){name=String(name||'').toLowerCase();if(name==='dahua'||name==='dahua-dhip')return'239.255.255.251';if(name==='arp')return'-';return'239.255.255.250';}
function internalToUi(text){
    var out=['# 协议    地址              端口    是否启用'];
    var ls=lines(text),seen={onvif:0,ssdp:0,hik:0,dahua:0,arp:0};
    for(var i=0;i<ls.length;i++){
        var row=String(ls[i]||'').trim();if(!row)continue;
        if(row.charAt(0)==='#'){if(row.indexOf('# 协议')!==0)out.push(row);continue;}
        var p=row.split('|');
        var n=(p[0]||'').toLowerCase().replace(/_/g,'-');
        if(n==='onvif'||n==='ssdp'||n==='hik'||n==='hik-sadp'||n==='dahua'||n==='dahua-dhip'||n==='arp'){
            var key=(n==='hik'||n==='hik-sadp')?'hik':(n==='dahua'||n==='dahua-dhip'?'dahua':n);
            var port=p[1]||({'onvif':'3702','ssdp':'1900','hik':'37020','dahua':'37810','arp':'-'}[key]);
            var en=p[2]==='1'?'1':'0';
            if(seen[key])continue;
            seen[key]=1;
            out.push((key==='hik'?'hik':key)+' '+standardAddress(key)+' '+port+' '+en);
        }else if(p.length>=5){
            out.push((p[0]||'custom')+' '+(p[1]||'-')+' '+(p[2]||'-')+' '+(p[4]==='1'?'1':'0')+'    # '+(p[3]||''));
        }
    }
    if(!seen.onvif)out.push('onvif 239.255.255.250 3702 1');
    if(!seen.ssdp)out.push('ssdp 239.255.255.250 1900 1');
    if(!seen.hik)out.push('hik 239.255.255.250 37020 1');
    if(!seen.dahua)out.push('dahua 239.255.255.251 37810 1');
    if(!seen.arp)out.push('arp - - 1');
    return out.join('\n');
}
function uiToInternal(text){
    var out=[],ls=lines(text);
    for(var i=0;i<ls.length;i++){
        var row=String(ls[i]||'').trim();if(!row||row.charAt(0)==='#')continue;
        var clean=row.replace(/\s+#.*$/,'').trim();
        var p=clean.split(/\s+/);
        if(p.length<4)continue;
        var n=(p[0]||'').toLowerCase().replace(/_/g,'-'),addr=p[1]||'-',port=p[2]||'-',en=p[p.length-1]==='1'?'1':'0';
        if(n==='onvif')out.push('onvif|'+(port||'3702')+'|'+en);
        else if(n==='ssdp')out.push('ssdp|'+(port||'1900')+'|'+en);
        else if(n==='hik'||n==='hik-sadp')out.push('hik-sadp|'+(port||'37020')+'|'+en);
        else if(n==='dahua'||n==='dahua-dhip')out.push('dahua-dhip|'+(port||'37810')+'|'+en);
        else if(n==='arp')out.push('arp|-|'+en);
        else{
            var payload='';
            if(p.length>4)payload=p.slice(3,p.length-1).join(' ');
            out.push(encodeURIComponent(p[0])+'|'+encodeURIComponent(addr)+'|'+encodeURIComponent(port)+'|'+encodeURIComponent(payload)+'|'+en);
        }
    }
    return out.join('\n');
}
function syncLegacyFromUi(){
    var txt=document.getElementById('lan_discovery_custom_ui').value,ls=lines(txt),d={onvif:['3702','1'],ssdp:['1900','1'],hik:['37020','1'],dahua:['37810','1'],arp:['-','1']};
    for(var i=0;i<ls.length;i++){var row=String(ls[i]||'').replace(/\s+#.*$/,'').trim();if(!row||row.charAt(0)==='#')continue;var p=row.split(/\s+/);if(p.length<4)continue;var n=p[0].toLowerCase().replace(/_/g,'-');if(n==='onvif')d.onvif=[p[2]||'3702',p[p.length-1]==='1'?'1':'0'];else if(n==='ssdp')d.ssdp=[p[2]||'1900',p[p.length-1]==='1'?'1':'0'];else if(n==='hik'||n==='hik-sadp')d.hik=[p[2]||'37020',p[p.length-1]==='1'?'1':'0'];else if(n==='dahua'||n==='dahua-dhip')d.dahua=[p[2]||'37810',p[p.length-1]==='1'?'1':'0'];else if(n==='arp')d.arp=['-',p[p.length-1]==='1'?'1':'0'];}
    document.getElementById('lan_discovery_onvif_port').value=d.onvif[0];document.getElementById('lan_discovery_ssdp_port').value=d.ssdp[0];document.getElementById('lan_discovery_hik_port').value=d.hik[0];document.getElementById('lan_discovery_dahua_port').value=d.dahua[0];
    ['onvif','ssdp','hik','dahua','raw'].forEach(function(k){var n=k==='raw'?'arp':k;var val=d[n][1];var a=document.getElementById('lan_discovery_'+k+'_1'),b=document.getElementById('lan_discovery_'+k+'_0');if(a&&b){a.checked=val==='1';b.checked=val!=='1';}});
}
function parseData(data){var s=String(data||'').replace(/\r/g,'');var first=(s.split('\n')[0]||'').split('|');return{iface:valueOr(first[1],initial_status.iface||'eth2.1'),ip:valueOr(first[3],initial_status.ip||'-'),mac:valueOr(first[4],initial_status.mac||'-'),link:valueOr(first[5],initial_status.link||'-'),dhcp:valueOr(first[6],initial_status.dhcp||'未检测'),state:valueOr(first[7],initial_status.state||'空闲'),count:valueOr(first[8],initial_status.count||'0'),last:valueOr(first[9],initial_status.last||'-'),log:section(s,'---LOG---','---DEVICES---'),devices:section(s,'---DEVICES---','---TARGETS---'),targets:section(s,'---TARGETS---','---CUSTOM---')};}
function section(s,a,b){var p=s.indexOf(a);if(p<0)return'';p+=a.length;var q=b?s.indexOf(b,p):-1;return s.substring(p,q<0?s.length:q).replace(/^\n+|\n+$/g,'');}
function renderStatus(o){$j('#status_iface').text(o.iface);$j('#status_ip').text(o.ip);$j('#status_mac').text(o.mac);$j('#status_link').text(o.link==='UP'?'已插入':(o.link==='DOWN'?'未插入':o.link));$j('#status_dhcp').text(o.dhcp);$j('#status_state').text(o.state);$j('#status_count').text(o.count);$j('#status_last').text(o.last);}
function renderDevices(s){var body=document.getElementById('devices');body.innerHTML='';var ls=lines(s),n=0;for(var i=0;i<ls.length;i++){var z=String(ls[i]||'');if(z.indexOf('DEVICE ')!==0)continue;if(z.indexOf('type=SUBNET ')>=0)continue;var type=(z.match(/type=([^ ]+)/)||[])[1]||'-',ip=(z.match(/IP=([^ ]+)/)||[])[1]||'-',mac=(z.match(/MAC=([^ ]+)/)||[])[1]||'-',info=(z.match(/INFO=(.*)$/)||[])[1]||'-';var tr=document.createElement('tr');[type,ip,mac,info].forEach(function(v){var td=document.createElement('td');td.textContent=v;tr.appendChild(td);});body.appendChild(tr);n++;}if(!n)body.innerHTML='<tr><td colspan="4" class="muted">暂无设备</td></tr>';}
function renderTargets(s){var box=document.getElementById('targets');box.innerHTML='';var ls=String(s||'').split(';'),n=0;for(var i=0;i<ls.length;i++){var p=ls[i].split('|');if(p.length<2)continue;var tr=document.createElement('tr');[p[0],p[1],'已启用（SNAT）'].forEach(function(v){var td=document.createElement('td');td.textContent=v;tr.appendChild(td);});box.appendChild(tr);n++;}if(!n)box.innerHTML='<tr><td colspan="3" class="muted">当前没有生效的目标网段</td></tr>';}
function refresh(){var x=new XMLHttpRequest();x.onreadystatechange=function(){if(x.readyState!==4||x.status!==200)return;var o=parseData(x.responseText);renderStatus(o);document.getElementById('live_log').textContent=o.log||'暂无日志';document.getElementById('live_log').scrollTop=document.getElementById('live_log').scrollHeight;renderDevices(o.devices);renderTargets(o.targets);};x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);x.send(null);}
function applyRule(){if(!login_safe())return false;var internal=uiToInternal(document.getElementById('lan_discovery_custom_ui').value);document.getElementById('lan_discovery_custom').value=internal;syncLegacyFromUi();showLoading();document.form.action_mode.value='Apply';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function clearLog(){if(!login_safe())return false;showLoading();document.form.action_mode.value='Update';document.form.action_script.value='lan_discovery_clear_log';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function clearDevices(){if(!login_safe())return false;showLoading();document.form.action_mode.value='Update';document.form.action_script.value='lan_discovery_clear_devices';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function initial(){show_banner(1);show_menu(5,3,1);show_footer();setToggle('lan_discovery_enable','<% nvram_get_x("", "lan_discovery_enable"); %>'||'1');setToggle('lan_discovery_dhcp_enable','<% nvram_get_x("", "lan_discovery_dhcp_enable"); %>'||'1');setToggle('lan_discovery_discover_enable','<% nvram_get_x("", "lan_discovery_discover_enable"); %>'||'1');setToggle('lan_discovery_clear_on_unplug','<% nvram_get_x("", "lan_discovery_clear_on_unplug"); %>'||'1');document.getElementById('lan_discovery_custom_ui').value=internalToUi(initial_custom);syncLegacyFromUi();refresh();if(refresh_timer)clearInterval(refresh_timer);refresh_timer=setInterval(refresh,1000);}
</script>
<style>.status-table td{white-space:nowrap}.mini{width:55px;margin:0 3px}.live-box{height:220px;overflow:auto;background:#111;color:#ddd;padding:8px;font:12px monospace;white-space:pre-wrap}.custom-area{width:100%;min-height:210px;box-sizing:border-box;font:13px monospace;line-height:1.55;white-space:pre}.note{color:#888}.target-table td,.target-table th{white-space:nowrap}</style>
</head>
<body onLoad="initial();" onunload="return unload_body();">
<div class="wrapper"><div class="container-fluid" style="padding-right:0"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div><iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp"><input type="hidden" name="next_page" value=""><input type="hidden" name="next_host" value=""><input type="hidden" name="sid_list" value="LANHostConfig;"><input type="hidden" name="group_id" value=""><input type="hidden" name="action_mode" value=""><input type="hidden" name="action_script" value="">
<input type="hidden" name="lan_discovery_enable" id="lan_discovery_enable_1" value="1"><input type="hidden" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_1" value="1"><input type="hidden" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_1" value="1"><input type="hidden" name="lan_discovery_clear_on_unplug" id="lan_discovery_clear_on_unplug_1" value="1"><input type="hidden" name="lan_discovery_raw" id="lan_discovery_raw_1" value="1"><input type="hidden" name="lan_discovery_onvif" id="lan_discovery_onvif_1" value="1"><input type="hidden" name="lan_discovery_ssdp" id="lan_discovery_ssdp_1" value="1"><input type="hidden" name="lan_discovery_hik" id="lan_discovery_hik_1" value="1"><input type="hidden" name="lan_discovery_dahua" id="lan_discovery_dahua_1" value="1"><input type="hidden" name="lan_discovery_custom" id="lan_discovery_custom" value="">
<div class="container-fluid"><div class="row-fluid"><div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN监听与设备发现</h2><div class="round_bottom"><div id="tabMenu" class="submenuBlock"></div><div class="alert alert-info" style="margin:10px">LAN口插拔、上级DHCP、ARP及协议设备发现均由后台实时运行。</div>
<table class="table table-condensed status-table"><tr><th colspan="8">当前状态</th></tr><tr><td>检测接口</td><td id="status_iface">-</td><td>LAN IPv4</td><td id="status_ip">-</td><td>LAN口</td><td id="status_link">-</td><td>DHCP</td><td id="status_dhcp">-</td></tr><tr><td>发现状态</td><td id="status_state">-</td><td>已发现</td><td id="status_count">0</td><td>最后活动</td><td id="status_last">-</td><td>MAC</td><td id="status_mac">-</td></tr></table>
<table class="table table-bordered table-condensed">
<tr><th width="190">检测接口</th><td><select name="lan_discovery_ifname" id="lan_ifname" class="span9"><option value="<% nvram_get_x("", "lan_discovery_ifname"); %>"><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN</option></select></td></tr>
<tr><th>LAN监听</th><td><div class="main_itoggle"><div id="lan_discovery_enable_on_of"><input type="checkbox" id="lan_discovery_enable_fake"></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" name="lan_discovery_enable_radio" id="lan_discovery_enable_0" value="0"></div></td></tr>
<tr><th>DHCP检测</th><td><div class="main_itoggle"><div id="lan_discovery_dhcp_enable_on_of"><input type="checkbox" id="lan_discovery_dhcp_enable_fake"></div></div><div style="position:absolute;margin-left:-10000px"><input type="radio" name="lan_discovery_dhcp_enable_radio" id="lan_discovery_dhcp_enable_0" value="0"></div><input type="text" class="mini" name="lan_discovery_dhcp_timeout" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒</td></tr>
<tr><th>设备发现</th><td><div class="main_itoggle"><div id="lan_discovery_discover_enable_on_of"><input type="checkbox" id="lan_discovery_discover_enable_fake"></div></div></td></tr>
<tr><th>设备发现周期</th><td><input class="mini" name="lan_discovery_cycle" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒 <span class="note">支持10/20/30/60等自定义周期</span></td></tr>
<tr><th>协议响应等待时间</th><td><input class="mini" name="lan_discovery_probe_timeout" value="<% nvram_get_x("", "lan_discovery_probe_timeout"); %>"> 秒 <span class="note">ONVIF/SSDP/海康/大华每轮发送后最长等待时间，1～30秒</span></td></tr>
<tr><th>目标网段丢失轮数</th><td><input class="mini" name="lan_discovery_miss_limit" value="<% nvram_get_x("", "lan_discovery_miss_limit"); %>"> 轮 <span class="note">连续完整扫描未发现达到此轮数才清理目标网段</span></td></tr>
<tr><th>LAN拔出时清除临时网段</th><td><div class="main_itoggle"><div id="lan_discovery_clear_on_unplug_on_of"><input type="checkbox" id="lan_discovery_clear_on_unplug_fake"></div></div><span class="note">开启：LAN拔出后立即清除临时IP和SNAT；关闭：保留已有临时网段，重新插入后继续使用</span></td></tr>
</table>
<div class="custom-box"><h4>自定义探测配置</h4><div class="alert alert-info">格式恢复为旧版四列：<b>协议　地址　端口　是否启用</b>。标准协议示例使用组播/广播地址；ARP没有地址和端口时填 <b>-</b>。后台保存时会自动转换为兼容格式。</div><textarea id="lan_discovery_custom_ui" class="custom-area" rows="12"></textarea></div>
<input type="hidden" name="lan_discovery_onvif_port" id="lan_discovery_onvif_port" value="3702"><input type="hidden" name="lan_discovery_ssdp_port" id="lan_discovery_ssdp_port" value="1900"><input type="hidden" name="lan_discovery_hik_port" id="lan_discovery_hik_port" value="37020"><input type="hidden" name="lan_discovery_dahua_port" id="lan_discovery_dahua_port" value="37810">
<h4>目标网段与临时IP</h4><table class="table table-bordered table-condensed target-table"><thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead><tbody id="targets"><tr><td colspan="3" class="muted">等待目标网段状态...</td></tr></tbody></table>
<h4>已发现设备 <button type="button" class="btn btn-mini pull-right" onclick="clearDevices();return false;">清空设备</button></h4><table class="table table-bordered table-condensed"><thead><tr><th>协议</th><th>IP</th><th>MAC</th><th>信息</th></tr></thead><tbody id="devices"><tr><td colspan="4" class="muted">暂无设备</td></tr></tbody></table>
<h4>实时监听日志 <button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空日志</button></h4><pre id="live_log" class="live-box">暂无日志</pre>
<table class="table"><tr><td style="border:0"><center><input class="btn btn-primary" style="width:219px" type="button" value="保存" onclick="applyRule();return false;"></center></td></tr></table>
</div></div></div></div></div></div></form><div id="footer"></div></div>
</body>
</html>
