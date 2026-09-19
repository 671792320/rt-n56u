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
<script type="text/javascript" src="/bootstrap/js/engage.itoggle.min.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/itoggle.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script>
var $j=jQuery.noConflict();
var refresh_timer=null;
var custom_loaded=false;
var last_log_text='';
var selected_target='';
var target_items=[];
var device_map={};

<% login_state_hook(); %>

function html_decode(v){
    var s=String(v==null?'':v);
    for(var i=0;i<5;i++){
        s=s.replace(/&amp;/gi,'&').replace(/&#38;/gi,'&')
         .replace(/&#10;/gi,'\n').replace(/&#13;/gi,'\n')
         .replace(/&#8232;/gi,'\n').replace(/&#x2028;/gi,'\n')
         .replace(/&lt;/gi,'<').replace(/&gt;/gi,'>');
    }
    return s.replace(/\r/g,'');
}
function lines(v){return html_decode(v).split(/\n|\u2028/);}
function val(v,d){return(v!==undefined&&v!==null&&String(v)!==''&&String(v)!=='-')?String(v):d;}
function linkText(v){v=String(v||'');return v==='UP'?'已插入':(v==='DOWN'?'未插入':(v||'-'));}
function healthText(v){v=String(v||'');if(v==='OK')return'正常';if(v==='BROADCAST_STORM')return'广播风暴';if(v==='LOOP_SUSPECTED')return'疑似环路';if(v==='LOOP_BROADCAST')return'疑似环路/广播风暴';return v||'未监视';}
function macText(v){var m=String(v||'').replace(/\\/g,'').replace(/\s+/g,'').toUpperCase();return/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(m)?m:'-';}
function escHtml(v){return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;').replace(/'/g,'&#39;');}
function section(t,a,b){var p=t.indexOf(a);if(p<0)return'';p+=a.length;var q=b?t.indexOf(b,p):-1;return t.substring(p,q<0?t.length:q).replace(/^\n+|\n+$/g,'');}
function parseData(t){
    t=html_decode(t);
    var f=(t.split('\n')[0]||'').split('|');
    return{
        iface:val(f[1],'<% nvram_get_x("", "lan_discovery_ifname"); %>'),
        role:val(f[2],'LAN'),
        ip:val(f[3],'-'),
        mac:macText(val(f[4],'<% nvram_get_x("", "lan_hwaddr"); %>')),
        link:val(f[5],'-'),
        dhcp:val(f[6],'未检测'),
        state:val(f[7],'空闲'),
        count:val(f[8],'0'),
        last:val(f[9],'-'),
        health:val(f[10],'未监视'),
        broadcast:val(f[11],'0'),
        loop:val(f[12],'0'),
        ifaces:section(t,'---IFACES---','---LOG---'),
        log:section(t,'---LOG---','---DEVICES---'),
        devices:section(t,'---DEVICES---','---TARGETS---'),
        targets:section(t,'---TARGETS---','---CUSTOM---'),
        custom:section(t,'---CUSTOM---','')
    };
}
function clean_device_info(v){
    var s=String(v||'');
    s=s.replace(/^Ping:\s*[^；]*；\s*/,'')
      .replace(/\s*STATUS=[^ ]+/g,'')
      .replace(/\s*PING=[^ ]+/g,'')
      .replace(/\s*MISS=[0-9]+/g,'')
      .replace(/^设备可达$/,'')
      .replace(/^[；;、，,\s]+|[；;、，,\s]+$/g,'');
    return s||'-';
}
function ipKey(ip){
    var p=String(ip||'').split('.');
    if(p.length!==4)return 4294967295;
    var n=0;
    for(var i=0;i<4;i++){
        if(!/^\d+$/.test(p[i]))return 4294967295;
        n=n*256+(+p[i]);
    }
    return n;
}
function parseDevices(s){
    var ls=lines(s),map={};
    for(var i=0;i<ls.length;i++){
        var z=String(ls[i]||'').trim();
        if(z.indexOf('DEVICE ')!==0||z.indexOf('type=SUBNET ')>=0)continue;
        var ip=(z.match(/IP=([^ ]+)/)||[])[1]||'-';
        if(ip==='-'||!/^\d+\.\d+\.\d+\.\d+$/.test(ip))continue;
        var type=(z.match(/type=([^ ]+)/)||[])[1]||'ARP';
        var mac=(z.match(/MAC=([^ ]+)/)||[])[1]||'-';
        var st=(z.match(/STATUS=([^ ]+)/)||[])[1]||'在线';
        var ping=(z.match(/PING=([^ ]+)/)||[])[1]||'不可用';
        var info=clean_device_info((z.match(/INFO=(.*)$/)||[])[1]||'-');
        if(!map[ip])map[ip]={ip:ip,macs:[],status:'',ping:'',proto:[],info:[]};
        var d=map[ip];
        mac=macText(mac);
        if(mac!=='-'&&d.macs.indexOf(mac)<0)d.macs.push(mac);
        if(st==='在线')d.status='在线';
        if(ping==='通')d.ping='通';
        if(type!=='ARP'&&d.proto.indexOf(type)<0)d.proto.push(type);
        if(info!=='-'&&d.info.indexOf(info)<0)d.info.push(info);
    }
    return map;
}
function parseTargets(s){
    var ls=String(s||'').split(';'),out=[];
    for(var i=0;i<ls.length;i++){
        var p=ls[i].split('|');
        if(p.length<2||!p[0])continue;
        out.push({net:p[0],temp:p[1]||'-',state:p[2]||'SNAT已锁定'});
    }
    return out;
}
function targetShort(net){
    var p=String(net||'').split('/')[0].split('.');
    if(p.length!==4)return net||'-';
    return p[2]+'.'+p[3];
}
function targetBase(net){
    var p=String(net||'').split('/')[0].split('.');
    return p.length===4 ? p[0]+'.'+p[1]+'.'+p[2] : '';
}
function findTarget(net){
    for(var i=0;i<target_items.length;i++)if(target_items[i].net===net)return target_items[i];
    return null;
}
function renderTargets(){
    var b=document.getElementById('targets');
    if(!b)return;
    b.innerHTML='';
    if(!target_items.length){
        b.innerHTML='<span class="note">暂未发现目标网段</span>';
        selected_target='';
        return;
    }
    if(!findTarget(selected_target))selected_target=target_items[0].net;
    for(var i=0;i<target_items.length;i++){
        var t=target_items[i];
        var btn=document.createElement('button');
        btn.type='button';
        btn.className='btn btn-mini '+(t.net===selected_target?'btn-primary':'');
        btn.style.marginRight='5px';
        btn.style.marginBottom='4px';
        btn.innerHTML=targetShort(t.net);
        btn.title=t.net+'  临时IP：'+t.temp;
        btn.setAttribute('data-net',t.net);
        btn.onclick=function(){
            selected_target=this.getAttribute('data-net');
            renderTargets();
            renderMatrix();
            return false;
        };
        b.appendChild(btn);
    }
}
function deviceCurrent(d){
    return !!d && (d.status==='在线' || d.ping==='通');
}
function classifyIp(ip,t){
    if(t&&t.temp===ip)return'temp';
    var d=device_map[ip];
    if(!deviceCurrent(d))return'empty';
    if(d.macs.length>1)return'conflict';
    return'found';
}
function statusText(kind){
    if(kind==='found')return'已发现';
    if(kind==='temp')return'临时IP';
    if(kind==='conflict')return'IP冲突';
    return'未使用';
}
function renderSummary(){
    var nets=target_items.length;
    var found=0,conflict=0,temp=0,total=nets*255;
    for(var i=0;i<target_items.length;i++){
        if(target_items[i].temp!=='-')temp++;
        var base=targetBase(target_items[i].net);
        for(var j=1;j<=255;j++){
            var ip=base+'.'+j;
            var d=device_map[ip];
            if(deviceCurrent(d)){
                found++;
                if(d.macs.length>1)conflict++;
            }
        }
    }
    var used=found+temp;
    var unused=total-used;
    if(unused<0)unused=0;
    $j('#summary_targets').text(nets);
    $j('#summary_found').text(found);
    $j('#summary_temp').text(temp);
    $j('#summary_conflict').text(conflict);
    $j('#summary_unused').text(unused);
}
function renderMatrix(){
    var title=document.getElementById('matrix_title');
    var box=document.getElementById('ip_matrix');
    if(!title||!box)return;
    box.innerHTML='';
    var t=findTarget(selected_target);
    if(!t){
        title.innerHTML='当前网段：-';
        return;
    }
    title.innerHTML='当前网段：'+t.net+' <span class="note">临时IP：'+t.temp+'，状态：'+t.state+'</span>';
    var table=document.createElement('table');
    table.className='table table-bordered table-condensed ip-grid';
    var tbody=document.createElement('tbody');
    for(var row=0;row<16;row++){
        var tr=document.createElement('tr');
        for(var col=0;col<16;col++){
            var n=row*16+col+1;
            var td=document.createElement('td');
            if(n>255){
                td.innerHTML='&nbsp;';
                tr.appendChild(td);
                continue;
            }
            var ip=targetBase(t.net)+'.'+n;
            var kind=classifyIp(ip,t);
            if(kind==='found')td.className='success';
            else if(kind==='temp')td.className='info';
            else if(kind==='conflict')td.className='error';
            var a=document.createElement('a');
            a.href='#';
            a.innerHTML=n;
            a.style.display='block';
            a.setAttribute('data-ip',ip);
            a.onclick=function(){
                showIpDetail(this.getAttribute('data-ip'),findTarget(selected_target));
                return false;
            };
            td.appendChild(a);
            tr.appendChild(td);
        }
        tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    box.appendChild(table);
    var cur=findTarget(selected_target);
    if(cur)$j('#matrix_summary').text('已发现 '+countTargetFound(cur.net)+' 个，临时IP 1 个，冲突 '+countTargetConflict(cur.net)+' 个');
}
function countTargetFound(net){
    var base=targetBase(net),n=0;
    for(var i=1;i<=255;i++)if(deviceCurrent(device_map[base+'.'+i]))n++;
    return n;
}
function countTargetConflict(net){
    var base=targetBase(net),n=0;
    for(var i=1;i<=255;i++){
        var d=device_map[base+'.'+i];
        if(d&&d.macs.length>1)n++;
    }
    return n;
}
function showIpDetail(ip,t){
    var d=device_map[ip],body=document.getElementById('ip_detail_body');
    if(!body)return;
    var kind=classifyIp(ip,t);
    var html='';
    html+='<table class="table table-bordered table-condensed detail-table">';
    html+='<tr><th width="160">IP地址</th><td>'+escHtml(ip)+'</td></tr>';
    html+='<tr><th>状态</th><td>'+statusText(kind)+'</td></tr>';
    if(kind==='temp'){
        html+='<tr><th>所有者</th><td>Q7</td></tr>';
        html+='<tr><th>用途</th><td>SNAT源地址</td></tr>';
        html+='<tr><th>SNAT状态</th><td>'+((t&&t.state)?t.state:'SNAT已锁定')+'</td></tr>';
        html+='<tr><th>所属网段</th><td>'+(t?t.net:'-')+'</td></tr>';
    }else if(d){
        html+='<tr><th>MAC地址</th><td>'+((d.macs.length)?escHtml(d.macs.join('<br>')).replace(/&lt;br&gt;/g,'<br>'):'-')+'</td></tr>';
        html+='<tr><th>发现协议</th><td>'+escHtml((d.proto.length)?d.proto.join(' / '):'ARP')+'</td></tr>';
        html+='<tr><th>Ping状态</th><td>'+((d.ping==='通')?'可达':'不可用')+'</td></tr>';
        if(d.info.length)html+='<tr><th>设备信息</th><td>'+escHtml(d.info.join('<br>')).replace(/&lt;br&gt;/g,'<br>')+'</td></tr>';
        if(kind==='conflict')html+='<tr><th>冲突说明</th><td>检测到多个不同MAC占用同一IP地址</td></tr>';
    }else{
        html+='<tr><th>ARP响应</th><td>无</td></tr>';
        html+='<tr><th>说明</th><td>当前扫描周期未发现该地址</td></tr>';
    }
    html+='<tr><th>目标网段</th><td>'+escHtml(t?t.net:'-')+'</td></tr>';
    html+='</table>';
    body.innerHTML=html;
}
function renderStatus(o){
    $j('#status_iface').text(o.iface);
    $j('#status_role').text(o.role);
    $j('#status_ip').text(o.ip);
    $j('#status_mac').text(o.mac);
    $j('#status_link').text(linkText(o.link));
    $j('#status_dhcp').text(o.dhcp);
    $j('#status_state').text(o.state);
    $j('#status_last').text(o.last);
    $j('#status_health').text(healthText(o.health));
    $j('#status_broadcast').text(o.broadcast+'/s');
    $j('#status_loop').text(o.loop+'/s');
    if(o.health==='OK'||o.health==='未监视'||o.health==='-')$j('#status_health').removeClass('health-danger');
    else $j('#status_health').addClass('health-danger');
}
function renderIfaces(s){
    var sel=document.getElementById('lan_ifname');
    if(!sel)return;
    var wanted='<% nvram_get_x("", "lan_discovery_ifname"); %>';
    var ls=lines(s),found=false;
    sel.innerHTML='';
    for(var i=0;i<ls.length;i++){
        var f=String(ls[i]||'').trim().split('|');
        if(f.length<5||!f[0]||f[1]!=='LAN'||/^(lo|br|ra|wds|apcli)/.test(f[0]))continue;
        var o=document.createElement('option');
        o.value=f[0];
        o.text=f[0]+' | '+f[1]+' | '+(f[2]||'-')+' | '+linkText(f[4]);
        if(f[0]===wanted){o.selected=true;found=true;}
        sel.appendChild(o);
    }
    if(!sel.options.length){
        var o=document.createElement('option');
        o.value=wanted||'eth2.1';
        o.text=(wanted||'eth2.1')+' | LAN';
        o.selected=true;
        sel.appendChild(o);
    }else if(!found)sel.selectedIndex=0;
}
function refresh(){
    var x=new XMLHttpRequest();
    x.onreadystatechange=function(){
        if(x.readyState!==4||x.status!==200)return;
        var o=parseData(x.responseText);
        renderStatus(o);
        renderIfaces(o.ifaces);
        target_items=parseTargets(o.targets);
        device_map=parseDevices(o.devices);
        renderTargets();
        renderSummary();
        renderMatrix();
        if(!custom_loaded){
            var ui=document.getElementById('lan_discovery_custom_ui');
            if(ui){ui.value=internalToUi(o.custom||'');custom_loaded=true;}
        }
        var lg=document.getElementById('live_log');
        var new_log=o.log||'暂无日志';
        if(lg&&new_log!==last_log_text){
            var oldTop=lg.scrollTop;
            lg.textContent=new_log;
            lg.scrollTop=oldTop;
            last_log_text=new_log;
        }
    };
    x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);
    x.send(null);
}
function uiToInternal(t){
    var ls=lines(t),out=[];
    for(var i=0;i<ls.length;i++){
        var r=String(ls[i]||'').replace(/^\s+|\s+$/g,'');
        if(!r||r.charAt(0)==='#')continue;
        r=r.replace(/\s+#.*$/,'');
        var p=r.split(/\s+/);
        if(p.length<4)continue;
        var n=p[0].toLowerCase().replace(/_/g,'-'),port=p[2]||'-',en=p[p.length-1]==='0'?'0':'1';
        if(n==='onvif')out.push('onvif|'+port+'|'+en);
        else if(n==='ssdp')out.push('ssdp|'+port+'|'+en);
        else if(n==='hik'||n==='hik-sadp')out.push('hik-sadp|'+port+'|'+en);
        else if(n==='dahua'||n==='dahua-dhip')out.push('dahua-dhip|'+port+'|'+en);
        else if(n==='arp')out.push('arp|-|'+en);
        else out.push(encodeURIComponent(p[0])+'|'+encodeURIComponent(p[1]||'-')+'|'+encodeURIComponent(p[2]||'-')+'|'+encodeURIComponent(p.slice(3,p.length-1).join(' '))+'|'+en);
    }
    return out.join('\n');
}
function internalToUi(t){
    var ls=lines(t),out=['# 协议    地址              端口    是否启用'],seen={onvif:0,ssdp:0,hik:0,dahua:0,arp:0};
    for(var i=0;i<ls.length;i++){
        var r=String(ls[i]||'').replace(/^\s+|\s+$/g,'');
        if(!r)continue;
        if(r.charAt(0)==='#'){if(r.indexOf('# 协议')!==0)out.push(r);continue;}
        var p=r.split('|'),n=(p[0]||'').toLowerCase().replace(/_/g,'-'),k=n==='hik-sadp'?'hik':(n==='dahua-dhip'?'dahua':n);
        if(k==='onvif'||k==='ssdp'||k==='hik'||k==='dahua'||k==='arp'){
            if(seen[k])continue;
            seen[k]=1;
            var addr=k==='dahua'?'239.255.255.251':(k==='arp'?'-':'239.255.255.250');
            var port={onvif:'3702',ssdp:'1900',hik:'37020',dahua:'37810',arp:'-'}[k];
            out.push(k+' '+addr+' '+(p[1]||port)+' '+(p[2]==='0'?'0':'1'));
        }else if(p.length>=5){
            out.push((p[0]||'custom')+' '+(p[1]||'-')+' '+(p[2]||'-')+' '+(p[4]==='0'?'0':'1')+'    # '+(p[3]||''));
        }
    }
    if(!seen.onvif)out.push('onvif 239.255.255.250 3702 1');
    if(!seen.ssdp)out.push('ssdp 239.255.255.250 1900 1');
    if(!seen.hik)out.push('hik 239.255.255.250 37020 1');
    if(!seen.dahua)out.push('dahua 239.255.255.251 37810 1');
    if(!seen.arp)out.push('arp - - 1');
    return out.join('\n');
}
function applyRule(){
    if(!login_safe())return false;
    var ui=document.getElementById('lan_discovery_custom_ui'),hidden=document.getElementById('lan_discovery_custom');
    if(ui&&hidden)hidden.value=uiToInternal(ui.value);
    showLoading();
    document.form.action_mode.value=' Update ';
    document.form.action_script.value='lan_discovery_restart';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='Advanced_LANDiscover_Content.asp';
    document.form.submit();
    return false;
}
function clearLog(){
    if(!login_safe())return false;
    showLoading();
    document.form.action_mode.value=' Update ';
    document.form.action_script.value='lan_discovery_clear_log';
    document.form.current_page.value='Advanced_LANDiscover_Content.asp';
    document.form.next_page.value='Advanced_LANDiscover_Content.asp';
    document.form.submit();
    return false;
}
function initial(){
    show_banner(1);
    show_menu(5,3,1);
    show_footer();
    init_itoggle('lan_discovery_enable');
    init_itoggle('lan_discovery_dhcp_enable');
    init_itoggle('lan_discovery_discover_enable');
    var f=document.form;
    if(!f.lan_discovery_dhcp_timeout.value)f.lan_discovery_dhcp_timeout.value='3';
    if(!f.lan_discovery_cycle.value)f.lan_discovery_cycle.value='10';
    if(!f.lan_discovery_sweep_cycle.value)f.lan_discovery_sweep_cycle.value='120';
    if(!f.lan_discovery_probe_timeout.value)f.lan_discovery_probe_timeout.value='5';
    refresh();
    if(refresh_timer)clearInterval(refresh_timer);
    refresh_timer=setInterval(refresh,5000);
}
</script>
<style type="text/css">
.status-table td{white-space:nowrap;vertical-align:middle}
.mini{width:55px;margin:0 3px}
.health-danger{font-weight:bold;color:#b94a48}
.live-box{height:170px;overflow:auto;padding:8px;background:#111;color:#ddd;font:12px/1.55 monospace;white-space:pre-wrap}
.custom-area{width:100%;min-height:180px;box-sizing:border-box;font:13px/1.55 monospace;white-space:pre}
.note{color:#888}
.hidden-builtin{position:absolute;left:-10000px;top:auto;width:1px;height:1px;overflow:hidden}
.target-tabs{padding:2px 0 5px}
.ip-grid{table-layout:fixed;margin-bottom:8px}
.ip-grid td{text-align:center;vertical-align:middle;padding:2px 0!important;height:23px}
.ip-grid td a{text-decoration:none}
.ip-grid td.error a,.ip-grid td.info a,.ip-grid td.success a{font-weight:bold}
.detail-table{margin-bottom:10px}
.detail-table th{white-space:nowrap}
.section-head{margin:8px 0}
.summary-table td{white-space:nowrap;text-align:center}
</style>
</head>
<body onload="initial();" onunload="return unload_body();">
<div class="wrapper">
<div class="container-fluid" style="padding-right:0"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div><iframe name="hidden_frame" id="hidden_frame" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="next_host" value="">
<input type="hidden" name="sid_list" value="LANHostConfig;">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="action_mode" value="">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="lan_discovery_custom" id="lan_discovery_custom" value="">

<div class="container-fluid"><div class="row-fluid">
<div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>

<div class="span9"><div class="box well grad_colour_dark_blue">
<h2 class="box_head round_top">LAN监听与设备发现</h2>
<div class="round_bottom"><div id="tabMenu" class="submenuBlock"></div>

<div class="alert alert-info">本页面使用 Padavan 原生表格和按钮样式。后台负责实时监听、周期发现和 SNAT；页面仅显示状态并保存参数。</div>

<table class="table table-condensed status-table">
<tr><th colspan="8">当前状态</th></tr>
<tr>
<td>检测接口</td><td id="status_iface">-</td>
<td>LAN IPv4</td><td id="status_ip">-</td>
<td>LAN口</td><td id="status_link">-</td>
<td>DHCP</td><td id="status_dhcp">-</td>
</tr>
<tr>
<td>发现状态</td><td id="status_state">-</td>
<td>最后活动</td><td id="status_last">-</td>
<td>网络健康</td><td id="status_health">-</td>
<td>MAC</td><td id="status_mac">-</td>
</tr>
<tr>
<td>广播速率</td><td id="status_broadcast">0/s</td>
<td>MAC回流</td><td id="status_loop">0/s</td>
<td colspan="4">红色文字表示健康状态异常</td>
</tr>
</table>

<h4 class="section-head">发现统计</h4>
<table class="table table-bordered table-condensed summary-table">
<tr>
<td><b>目标网段</b><br><span id="summary_targets">0</span></td>
<td><b>已发现</b><br><span id="summary_found">0</span></td>
<td><b>临时IP</b><br><span id="summary_temp">0</span></td>
<td><b>未使用</b><br><span id="summary_unused">0</span></td>
<td><b>IP冲突</b><br><span id="summary_conflict">0</span></td>
</tr>
</table>

<h4 class="section-head">目标网段</h4>
<div id="targets" class="target-tabs"><span class="note">暂未发现目标网段</span></div>

<h4 class="section-head" id="matrix_title">当前网段：-</h4>
<div class="note" style="margin-bottom:4px">
<span class="label label-success">已发现</span>
<span class="label label-info">临时IP</span>
<span class="label label-important">IP冲突</span>
<span class="label">未使用</span>
<span id="matrix_summary" style="margin-left:8px"></span>
</div>
<div id="ip_matrix"><div class="note">等待目标网段状态...</div></div>

<h4 class="section-head">IP详细信息</h4>
<div id="ip_detail_body"><div class="alert alert-info">点击上面的 IP 地址查看详细信息。</div></div>

<h4 class="section-head">发现参数</h4>
<table class="table table-bordered table-condensed">
<tr>
<th width="190">检测接口</th>
<td>
<select name="lan_discovery_ifname" id="lan_ifname" class="span5">
<option value="<% nvram_get_x("", "lan_discovery_ifname"); %>"><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN</option>
</select>
</td>
</tr>
<tr>
<th>LAN发现服务</th>
<td>
<div class="main_itoggle">
<div id="lan_discovery_enable_on_of">
<input type="checkbox" id="lan_discovery_enable_fake" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>>
</div>
</div>
<div class="hidden-builtin">
<input type="radio" id="lan_discovery_enable_1" name="lan_discovery_enable" value="1" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>>
<input type="radio" id="lan_discovery_enable_0" name="lan_discovery_enable" value="0" <% nvram_match_x("", "lan_discovery_enable", "0", "checked"); %>>
</div>
<span class="note">控制LAN发现后台服务是否运行</span>
</td>
</tr>
<tr>
<th>DHCP检测</th>
<td>
<div class="main_itoggle">
<div id="lan_discovery_dhcp_enable_on_of">
<input type="checkbox" id="lan_discovery_dhcp_enable_fake" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>>
</div>
</div>
<div class="hidden-builtin">
<input type="radio" id="lan_discovery_dhcp_enable_1" name="lan_discovery_dhcp_enable" value="1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>>
<input type="radio" id="lan_discovery_dhcp_enable_0" name="lan_discovery_dhcp_enable" value="0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "checked"); %>>
</div>
<input class="mini" name="lan_discovery_dhcp_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒
</td>
</tr>
<tr>
<th>主动设备发现</th>
<td>
<div class="main_itoggle">
<div id="lan_discovery_discover_enable_on_of">
<input type="checkbox" id="lan_discovery_discover_enable_fake" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>>
</div>
</div>
<div class="hidden-builtin">
<input type="radio" id="lan_discovery_discover_enable_1" name="lan_discovery_discover_enable" value="1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>>
<input type="radio" id="lan_discovery_discover_enable_0" name="lan_discovery_discover_enable" value="0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "checked"); %>>
</div>
<span class="note">实时二层监听持续运行；关闭后仅停止主动补漏</span>
</td>
</tr>
<tr>
<th>主动探测单次窗口</th>
<td><input class="mini" name="lan_discovery_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒</td>
</tr>
<tr>
<th>主动补漏周期</th>
<td><input class="mini" name="lan_discovery_sweep_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_sweep_cycle"); %>"> 秒
<span class="note">ARP、ONVIF、SSDP、海康、大华等主动探测周期</span>
</td>
</tr>
<tr>
<th>协议探测超时</th>
<td><input class="mini" name="lan_discovery_probe_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_probe_timeout"); %>"> 秒</td>
</tr>
<tr>
<th>LAN拔出处理</th>
<td><b>保留目标网段、临时IP和SNAT</b> <span class="note">LAN重新插入后继续使用本次开机周期的锁定状态。</span></td>
</tr>
</table>

<h4 class="section-head">自定义探测配置</h4>
<div class="alert alert-info">格式：协议 地址 端口 是否启用。ARP填写：arp - - 1。普通情况下保持默认配置即可。</div>
<textarea id="lan_discovery_custom_ui" class="custom-area" rows="8"></textarea>

<h4 class="section-head">实时监听日志
<button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空日志</button>
</h4>
<pre id="live_log" class="live-box">暂无日志</pre>

<table class="table">
<tr><td style="border:0">
<center>
<input class="btn btn-primary" style="width:219px" type="button" value="应用" onclick="applyRule();return false;">
</center>
</td></tr>
</table>

</div></div></div></div></form>
<div id="footer"></div>
</div>
</body>
</html>
