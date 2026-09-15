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
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/login_state_hook.js"></script>
<script type="text/javascript" src="/bootstrap/js/bootstrap.min.js"></script>
<script>
var $j = jQuery.noConflict();
var refresh_timer = null;

<% login_state_hook(); %>

function html_decode(v){
    var s = String(v || '');
    for(var i=0;i<5;i++){
        s=s.replace(/&amp;/gi,'&').replace(/&#38;/gi,'&')
          .replace(/&#10;/gi,'\n').replace(/&#13;/gi,'\n')
          .replace(/&#8232;/gi,'\n').replace(/&#x2028;/gi,'\n')
          .replace(/&lt;/gi,'<').replace(/&gt;/gi,'>');
    }
    return s.replace(/\r/g,'');
}

function lines(v){
    return html_decode(v).split(/\n|\u2028/);
}

function value_or(v,d){
    return (v !== undefined && v !== null && String(v) !== '' && String(v) !== '-') ? String(v) : d;
}

function link_text(v){
    v=String(v || '');
    return v==='UP' ? '已插入' : (v==='DOWN' ? '未插入' : (v || '-'));
}

function health_text(v){
    v=String(v || '');
    if(v==='OK') return '正常';
    if(v==='BROADCAST_STORM') return '广播风暴';
    if(v==='LOOP_SUSPECTED') return '疑似环路';
    if(v==='LOOP_BROADCAST') return '疑似环路/广播风暴';
    return v || '未监视';
}

function section(data,a,b){
    var p=data.indexOf(a);
    if(p<0) return '';
    p += a.length;
    var q=b ? data.indexOf(b,p) : -1;
    return data.substring(p,q<0 ? data.length : q).replace(/^\n+|\n+$/g,'');
}

function clean_device_info(v){
    var s=String(v || '');
    s=s.replace(/^Ping：[[:space:]]*[^；]*；[[:space:]]*/,'');
    s=s.replace(/[[:space:]]*STATUS=[^ ]+/g,'');
    s=s.replace(/[[:space:]]*PING=[^ ]+/g,'');
    s=s.replace(/[[:space:]]*MISS=[0-9]+/g,'');
    s=s.replace(/^设备可达$/,'');
    s=s.replace(/^[；;、，,[:space:]]+|[；;、，,[:space:]]+$/g,'');
    return s || '-';
}

function displayMac(v){
    var m=String(v==null?'':v).replace(/\\/g,'').replace(/\s+/g,'').toUpperCase();
    return /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(m) ? m : '-';
}

function parse_data(data){
    data=html_decode(data);
    var first=(data.split('\n')[0] || '').split('|');
    return {
        iface:value_or(first[1],'<% nvram_get_x("", "lan_discovery_ifname"); %>'),
        role:value_or(first[2],'LAN'),
        ip:value_or(first[3],'-'),
        mac:displayMac(value_or(first[4],'<% nvram_get_x("", "lan_hwaddr"); %>')),
        link:value_or(first[5],'-'),
        dhcp:value_or(first[6],'未检测'),
        state:value_or(first[7],'空闲'),
        count:value_or(first[8],'0'),
        last:value_or(first[9],'-'),
        health:value_or(first[10],'未监视'),
        broadcast:value_or(first[11],'0'),
        loop:value_or(first[12],'0'),
        interfaces:section(data,'---IFACES---','---LOG---'),
        log:section(data,'---LOG---','---DEVICES---'),
        devices:section(data,'---DEVICES---','---TARGETS---'),
        targets:section(data,'---TARGETS---','---CUSTOM---')
    };
}

function render_status(o){
    $j('#status_iface').text(o.iface);
    $j('#status_ip').text(o.ip);
    $j('#status_mac').text(displayMac(o.mac));
    $j('#status_link').text(link_text(o.link));
    $j('#status_dhcp').text(o.dhcp);
    $j('#status_state').text(o.state);
    $j('#status_count').text(o.count);
    $j('#status_last').text(o.last);
    $j('#status_health').text(health_text(o.health));
    $j('#status_broadcast').text(o.broadcast + '/s');
    $j('#status_loop').text(o.loop + '/s');
    if(o.health==='OK' || o.health==='未监视' || o.health==='-') $j('#status_health').removeClass('health-danger');
    else $j('#status_health').addClass('health-danger');
}

function render_interfaces(s){
    var sel=document.getElementById('lan_ifname');
    if(!sel) return;
    var wanted='<% nvram_get_x("", "lan_discovery_ifname"); %>';
    var ls=lines(s),found=false;
    sel.innerHTML='';
    for(var i=0;i<ls.length;i++){
        var f=String(ls[i] || '').split('|');
        if(f.length<5 || !f[0] || f[1]!=='LAN' || /^(lo|br|ra|wds|apcli)/.test(f[0])) continue;
        var opt=document.createElement('option');
        opt.value=f[0];
        opt.text=f[0]+' | '+f[1]+' | '+(f[2]||'-')+' | '+link_text(f[4]);
        if(f[0]===wanted){ opt.selected=true; found=true; }
        sel.appendChild(opt);
    }
    if(!sel.options.length){
        var o=document.createElement('option');
        o.value=wanted || 'eth2.1';
        o.text=(wanted || 'eth2.1')+' | LAN';
        o.selected=true;
        sel.appendChild(o);
    }else if(!found){
        sel.selectedIndex=0;
    }
}

function render_devices(s){
    var b=document.getElementById('devices');
    if(!b) return;
    b.innerHTML='';
    var ls=lines(s), map={}, ips=[];
    for(var i=0;i<ls.length;i++){
        var z=String(ls[i] || '').replace(/^\s+|\s+$/g,'');
        if(z.indexOf('DEVICE ')!==0 || z.indexOf('type=SUBNET ')>=0) continue;
        var ip=(z.match(/IP=([^ ]+)/)||[])[1] || '-';
        var type=(z.match(/type=([^ ]+)/)||[])[1] || 'ARP';
        var mac=(z.match(/MAC=([^ ]+)/)||[])[1] || '-';
        var st=(z.match(/STATUS=([^ ]+)/)||[])[1] || '在线';
        var ping=(z.match(/PING=([^ ]+)/)||[])[1] || '不可用';
        var info=clean_device_info((z.match(/INFO=(.*)$/)||[])[1] || '-');
        if(!map[ip]){ map[ip]={ip:ip,mac:mac,status:st,ping:ping,proto:[],info:[]}; ips.push(ip); }
        var d=map[ip];
        if(mac!=='-' && d.mac==='-') d.mac=mac;
        if(st==='在线') d.status=st;
        if(ping==='通') d.ping=ping;
        if(type!=='ARP' && d.proto.indexOf(type)<0) d.proto.push(type);
        if(info!=='-' && d.info.indexOf(info)<0) d.info.push(info);
    }
    ips.sort(function(a,b){
        var x=a.split('.'),y=b.split('.');
        for(var i=0;i<4;i++){var n=(+x[i]||0),m=(+y[i]||0);if(n!==m)return n-m;}
        return 0;
    });
    for(var j=0;j<ips.length;j++){
        var d=map[ips[j]],tr=document.createElement('tr');
        [d.status,d.proto.length?d.proto.join(' / '):'ARP',d.ip,displayMac(d.mac),d.ping,d.info.length?d.info.join('；'):'-'].forEach(function(v){
            var td=document.createElement('td');td.textContent=v;tr.appendChild(td);
        });
        b.appendChild(tr);
    }
    if(!ips.length) b.innerHTML='<tr><td colspan="6" class="muted">暂无设备</td></tr>';
}

function render_target_states(s){
    var b=document.getElementById('targets');
    if(!b) return;
    b.innerHTML='';
    var ls=String(s || '').split(';'),n=0;
    for(var i=0;i<ls.length;i++){
        var p=ls[i].split('|');
        if(p.length<2) continue;
        var tr=document.createElement('tr');
        [p[0],p[1],'已启用（SNAT）'].forEach(function(v){var td=document.createElement('td');td.textContent=v;tr.appendChild(td);});
        b.appendChild(tr); n++;
    }
    if(!n) b.innerHTML='<tr><td colspan="3" class="muted">当前没有生效的目标网段</td></tr>';
}

function renderTargets(s){ render_target_states(s); }
function render_log(s){
    var b=document.getElementById('live_log');
    if(!b) return;
    b.textContent=s || '暂无日志';
    b.scrollTop=b.scrollHeight;
}

function refresh_data(){
    var x=new XMLHttpRequest();
    x.onreadystatechange=function(){
        if(x.readyState!==4 || x.status!==200) return;
        var o=parse_data(x.responseText);
        render_status(o);
        render_interfaces(o.interfaces);
        render_devices(o.devices);
        render_target_states(o.targets);
        render_log(o.log);
    };
    x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);
    x.send(null);
}

function clearLog(){
    if(!login_safe()) return false;
    showLoading();
    document.form.action_mode.value='Update';
    document.form.action_script.value='lan_discovery_clear_log';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='';
    document.form.submit();
    return false;
}

function clearDevices(){
    if(!login_safe()) return false;
    showLoading();
    document.form.action_mode.value='Update';
    document.form.action_script.value='lan_discovery_clear_devices';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='';
    document.form.submit();
    return false;
}

function applyRule(){
    if(!login_safe()) return false;
    var ui=document.getElementById('lan_discovery_custom_ui');
    var hidden=document.getElementById('lan_discovery_custom');
    if(ui && hidden){
        var ls=lines(ui.value),out=[];
        for(var i=0;i<ls.length;i++){
            var r=String(ls[i] || '').replace(/^\s+|\s+$/g,'');
            if(!r || r.charAt(0)==='#') continue;
            r=r.replace(/\s+#.*$/,'');
            var p=r.split(/\s+/);
            if(p.length<4) continue;
            var n=p[0].toLowerCase().replace(/_/g,'-');
            var port=p[2] || '-';
            var en=p[p.length-1]==='0'?'0':'1';
            if(n==='onvif') out.push('onvif|'+port+'|'+en);
            else if(n==='ssdp') out.push('ssdp|'+port+'|'+en);
            else if(n==='hik' || n==='hik-sadp') out.push('hik-sadp|'+port+'|'+en);
            else if(n==='dahua' || n==='dahua-dhip') out.push('dahua-dhip|'+port+'|'+en);
            else if(n==='arp') out.push('arp|-|'+en);
            else out.push(encodeURIComponent(p[0])+'|'+encodeURIComponent(p[1]||'-')+'|'+encodeURIComponent(p[2]||'-')+'|'+encodeURIComponent(p.slice(3,p.length-1).join(' '))+'|'+en);
        }
        hidden.value=out.join('\n');
    }
    showLoading();
    document.form.action_mode.value='Apply';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='';
    document.form.submit();
    return false;
}

function internal_to_ui(v){
    var ls=lines(v),out=['# 协议    地址              端口    是否启用'],seen={onvif:0,ssdp:0,hik:0,dahua:0,arp:0};
    for(var i=0;i<ls.length;i++){
        var r=String(ls[i] || '').replace(/^\s+|\s+$/g,'');
        if(!r) continue;
        if(r.charAt(0)==='#'){ if(r.indexOf('# 协议')!==0) out.push(r); continue; }
        var p=r.split('|');
        var n=(p[0] || '').toLowerCase().replace(/_/g,'-');
        if(n==='onvif'||n==='ssdp'||n==='hik-sadp'||n==='hik'||n==='dahua-dhip'||n==='dahua'||n==='arp'){
            var k=n==='hik'||n==='hik-sadp'?'hik':(n==='dahua'||n==='dahua-dhip'?'dahua':n);
            if(seen[k]) continue;
            seen[k]=1;
            var addr=k==='dahua'?'239.255.255.251':(k==='arp'?'-':'239.255.255.250');
            var port={onvif:'3702',ssdp:'1900',hik:'37020',dahua:'37810',arp:'-'}[k];
            out.push(k+' '+addr+' '+(p[1]||port)+' '+(p[2]==='0'?'0':'1'));
        }else if(p.length>=5){
            out.push(p[0]+' '+(p[1]||'-')+' '+(p[2]||'-')+' '+(p[p.length-1]==='0'?'0':'1')+'    # '+(p.slice(3,p.length-1).join('|'));
        }
    }
    if(!seen.onvif) out.push('onvif 239.255.255.250 3702 1');
    if(!seen.ssdp) out.push('ssdp 239.255.255.250 1900 1');
    if(!seen.hik) out.push('hik 239.255.255.250 37020 1');
    if(!seen.dahua) out.push('dahua 239.255.255.251 37810 1');
    if(!seen.arp) out.push('arp - - 1');
    return out.join('\n');
}

function initial(){
    show_banner(1);
    show_menu(5,3,1);
    load_body();
    show_footer();
    init_itoggle('lan_discovery_enable');
    init_itoggle('lan_discovery_dhcp_enable');
    init_itoggle('lan_discovery_discover_enable');

    var f=document.form;
    if(!f.lan_discovery_dhcp_timeout.value) f.lan_discovery_dhcp_timeout.value='3';
    if(!f.lan_discovery_cycle.value) f.lan_discovery_cycle.value='10';
    if(!f.lan_discovery_miss_limit.value) f.lan_discovery_miss_limit.value='3';

    var raw=document.getElementById('lan_discovery_custom_raw');
    var ui=document.getElementById('lan_discovery_custom_ui');
    if(raw && ui) ui.value=internal_to_ui(raw.value);

    refresh_data();
    if(refresh_timer) clearInterval(refresh_timer);
    refresh_timer=setInterval(refresh_data,1000);
}
</script>
<style type="text/css">
.status-table td{white-space:nowrap;vertical-align:middle;}
.mini{width:55px;margin:0 3px;}
.health-danger{font-weight:bold;color:#b94a48;}
.live-box{height:220px;overflow:auto;background:#111;color:#ddd;padding:8px;font:12px/1.55 monospace;white-space:pre-wrap;}
.custom-area{width:100%;min-height:210px;box-sizing:border-box;font:13px/1.55 monospace;white-space:pre;}
.note{color:#888;}
.target-table td,.target-table th{white-space:nowrap;vertical-align:middle;}
.hidden-builtin{position:absolute;left:-10000px;top:auto;width:1px;height:1px;overflow:hidden;}
</style>
</head>
<body onload="initial();" onunload="return unload_body();">
<div class="wrapper">
<div class="container-fluid" style="padding-right:0"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="action_mode" value="">
<input type="hidden" name="action_script" value="">
<textarea name="lan_discovery_custom_raw" id="lan_discovery_custom_raw" style="display:none"><% nvram_get_x("", "lan_discovery_custom"); %></textarea>
<input type="hidden" name="lan_discovery_custom" id="lan_discovery_custom" value="">

<div class="container-fluid"><div class="row-fluid">
<div class="span3">
<div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div>
</div>

<div class="span9">
<div class="box well grad_colour_dark_blue">
<h2 class="box_head round_top">LAN监听与设备发现</h2>
<div class="round_bottom">
<div id="tabMenu" class="submenuBlock"></div>
<div class="alert alert-info">LAN口插拔、DHCP、ARP、协议设备发现以及网络健康检测由后台统一运行，本页面只负责参数配置和状态显示。</div>

<table class="table table-condensed status-table">
<tr><th colspan="8">当前状态</th></tr>
<tr><td>检测接口</td><td id="status_iface">-</td><td>LAN IPv4</td><td id="status_ip">-</td><td>LAN口</td><td id="status_link">-</td><td>DHCP</td><td id="status_dhcp">-</td></tr>
<tr><td>发现状态</td><td id="status_state">-</td><td>已发现</td><td id="status_count">0</td><td>最后活动</td><td id="status_last">-</td><td>MAC</td><td id="status_mac">-</td></tr>
<tr><td>网络健康</td><td id="status_health">未监视</td><td>广播速率</td><td id="status_broadcast">0/s</td><td>MAC回流</td><td id="status_loop">0/s</td><td>说明</td><td>红色=异常</td></tr>
</table>

<table class="table table-bordered table-condensed">
<tr><th width="190">检测接口</th><td><select id="lan_ifname" name="lan_discovery_ifname" class="span9"><option value="<% nvram_get_x("", "lan_discovery_ifname"); %>" selected><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN</option></select></td></tr>
<tr><th>LAN事件检测</th><td><div class="main_itoggle"><div id="lan_discovery_enable_on_of"></div></div><div class="hidden-builtin"><input type="radio" name="lan_discovery_enable" id="lan_discovery_enable_1" value="1" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>><input type="radio" name="lan_discovery_enable" id="lan_discovery_enable_0" value="0" <% nvram_match_x("", "lan_discovery_enable", "0", "checked"); %>></div><span class="note">监视LAN插拔并驱动后端发现服务</span></td></tr>
<tr><th>DHCP检测</th><td><div class="main_itoggle"><div id="lan_discovery_dhcp_enable_on_of"></div></div><div class="hidden-builtin"><input type="radio" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_1" value="1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>><input type="radio" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_0" value="0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "checked"); %>></div><input class="mini" name="lan_discovery_dhcp_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒</td></tr>
<tr><th>设备发现</th><td><div class="main_itoggle"><div id="lan_discovery_discover_enable_on_of"></div></div><div class="hidden-builtin"><input type="radio" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_1" value="1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>><input type="radio" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_0" value="0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "checked"); %>></div><span class="note">启用后持续周期探测和实时监听</span></td></tr>
<tr><th>设备发现周期</th><td><input class="mini" name="lan_discovery_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒 <span class="note">支持10/20/30/60等自定义周期</span></td></tr>
<tr><th>目标网段丢失轮数</th><td><input class="mini" name="lan_discovery_miss_limit" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_miss_limit"); %>"> 轮 <span class="note">连续完整扫描达到此轮数后才清理目标网段</span></td></tr>
<tr><th>LAN拔出处理</th><td><b>始终保留</b> <span class="note">拔出LAN只暂停实时监听和周期发现，不清除已有目标网段、临时IP和SNAT。</span></td></tr>
</table>

<h4>自定义探测配置</h4>
<div class="alert alert-info">格式：<b>协议　地址　端口　是否启用</b>。示例：onvif 239.255.255.250 3702 1；ARP填写：arp - - 1。</div>
<textarea id="lan_discovery_custom_ui" class="custom-area" rows="11"></textarea>

<h4>目标网段与临时IP</h4>
<table class="table table-bordered table-condensed target-table">
<thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead>
<tbody id="targets"><tr><td colspan="3" class="muted">等待目标网段状态...</td></tr></tbody>
</table>

<h4>已发现设备 <button type="button" class="btn btn-mini pull-right" onclick="clearDevices();return false;">清空设备</button></h4>
<table class="table table-bordered table-condensed">
<thead><tr><th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th></tr></thead>
<tbody id="devices"><tr><td colspan="6" class="muted">暂无设备</td></tr></tbody>
</table>

<h4>实时监听日志 <button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空日志</button></h4>
<pre id="live_log" class="live-box">暂无日志</pre>

<table class="table"><tr><td style="border:0"><center><input class="btn btn-primary" style="width:219px" type="button" value="保存" onclick="applyRule();return false;"></center></td></tr></table>
</div></div>
</div></div></div>
</form>
<div id="footer"></div>
</div>
</body>
</html>
