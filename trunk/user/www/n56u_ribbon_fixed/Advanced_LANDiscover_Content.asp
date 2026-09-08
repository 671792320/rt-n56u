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
var $j = jQuery.noConflict();
var refresh_timer = null;
var device_page = 1;
var matrix_selected_net = '';
var matrix_selected_ip = '';
var initial_status = {
    iface:'<% nvram_get_x("", "lan_discovery_status_if"); %>',
    role:'<% nvram_get_x("", "lan_discovery_status_role"); %>',
    ip:'<% nvram_get_x("", "lan_discovery_status_ip"); %>',
    mac:'<% nvram_get_x("", "lan_discovery_status_mac"); %>',
    link:'<% nvram_get_x("", "lan_discovery_status_link"); %>',
    dhcp:'<% nvram_get_x("", "lan_discovery_status_dhcp"); %>',
    state:'<% nvram_get_x("", "lan_discovery_status_state"); %>',
    count:'<% nvram_get_x("", "lan_discovery_status_count"); %>',
    last:'<% nvram_get_x("", "lan_discovery_status_last"); %>',
    health:'<% nvram_get_x("", "lan_discovery_status_health"); %>',
    broadcast:'<% nvram_get_x("", "lan_discovery_status_broadcast"); %>',
    loop:'<% nvram_get_x("", "lan_discovery_status_loop"); %>'
};
<% login_state_hook(); %>

function value_or(v,d){return(v!==undefined&&v!==null&&String(v)!==''&&String(v)!=='-')?String(v):d;}
function link_text(v){v=String(v||'');return v==='UP'?'已插入':(v==='DOWN'?'未插入':(v||'-'));}
function html_decode(v){var s=String(v||'');for(var i=0;i<5;i++){s=s.replace(/&amp;/gi,'&').replace(/&#38;/gi,'&').replace(/&#10;/gi,'\n').replace(/&#13;/gi,'\n').replace(/&#8232;/gi,'\n').replace(/&#x2028;/gi,'\n');}return s.replace(/\r/g,'');}
function clean_line(v){return html_decode(v).replace(/^\s+|\s+$/g,'');}
function lines(v){return html_decode(v).split(/\n|\u2028/).map(clean_line).filter(function(x){return x!=='';});}
function section(data,a,b){var p=data.indexOf(a);if(p<0)return '';p+=a.length;var q=b?data.indexOf(b,p):-1;return data.substring(p,q<0?data.length:q);}
function mac_norm(v){var m=String(v==null?'':v).replace(/\\/g,'').replace(/\s+/g,'').toUpperCase();return /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(m)?m:'-';}
function ip_key(ip){var p=String(ip||'').split('.');if(p.length!==4)return 4294967295;for(var i=0;i<4;i++){if(!/^\d+$/.test(p[i]))return 4294967295;}return (((+p[0])*256+(+p[1]))*256+(+p[2]));}
function ip_from_net(net,host){var p=String(net||'').split('.');return p.length===4?p[0]+'.'+p[1]+'.'+p[2]+'.'+host:null;}
function parse_data(data){data=html_decode(data);var first=(data.split('\n')[0]||'').split('|');return {
    iface:value_or(first[1],value_or(initial_status.iface,'eth2.1')),
    role:value_or(first[2],value_or(initial_status.role,'LAN')),
    ip:value_or(first[3],value_or(initial_status.ip,'-')),
    mac:mac_norm(value_or(first[4],value_or(initial_status.mac,'-'))),
    link:value_or(first[5],value_or(initial_status.link,'-')),
    dhcp:value_or(first[6],value_or(initial_status.dhcp,'未检测')),
    state:value_or(first[7],value_or(initial_status.state,'空闲')),
    count:value_or(first[8],value_or(initial_status.count,'0')),
    last:value_or(first[9],value_or(initial_status.last,'-')),
    health:value_or(first[10],value_or(initial_status.health,'未监视')),
    broadcast:value_or(first[11],value_or(initial_status.broadcast,'0')),
    loop:value_or(first[12],value_or(initial_status.loop,'0')),
    interfaces:section(data,'---IFACES---','---LOG---'),
    log:section(data,'---LOG---','---DEVICES---'),
    devices:section(data,'---DEVICES---','---CUSTOM---'),
    custom:section(data,'---CUSTOM---','')
};}
function health_text(v){v=String(v||'');if(v==='OK')return '正常';if(v==='BROADCAST_STORM')return '广播风暴';if(v==='LOOP_SUSPECTED')return '疑似环路';if(v==='LOOP_BROADCAST')return '疑似环路/广播风暴';return v||'未监视';}
function render_status(o){
    $j('#status_iface').text(o.iface);$j('#status_role').text(o.role);$j('#status_ip').text(o.ip);
    $j('#status_mac').text(mac_norm(o.mac));$j('#status_link').text(link_text(o.link));$j('#status_dhcp').text(o.dhcp);
    $j('#status_state').text(o.state);$j('#status_count').text(o.count);$j('#status_last').text(o.last);
    $j('#status_health').text(health_text(o.health));$j('#status_broadcast').text(o.broadcast+'/s');$j('#status_loop').text(o.loop+'/s');
    if(o.health==='OK'||o.health==='未监视'||o.health==='-')$j('#status_health').removeClass('health-danger');else $j('#status_health').addClass('health-danger');
}
function render_interfaces(s){
    var sel=document.getElementById('lan_ifname');if(!sel)return;var wanted='<% nvram_get_x("", "lan_discovery_ifname"); %>';
    var ls=lines(s),found=false;sel.innerHTML='';
    for(var i=0;i<ls.length;i++){var f=ls[i].split('|');if(f.length<5||!f[0]||f[1]!=='LAN'||/^(lo|br|ra|wds|apcli)/.test(f[0]))continue;
        var opt=document.createElement('option');opt.value=f[0];opt.text=f[0]+' | '+f[1]+' | '+(f[2]||'-')+' | '+link_text(f[4]);
        if(f[0]===wanted){opt.selected=true;found=true;}sel.appendChild(opt);
    }
    if(!sel.options.length){var o=document.createElement('option');o.value=wanted||'eth2.1';o.text=(wanted||'eth2.1')+' | LAN';o.selected=true;sel.appendChild(o);}else if(!found)sel.selectedIndex=0;
}
function make_device_record(type,ip,mac,info){
    return {ip:ip,mac:mac||'-',info:info||'-',protocols:[],conflict:false};
}
function add_protocol(row,type){type=String(type||'-');if(type==='-'||type==='IP')return;for(var i=0;i<row.protocols.length;i++)if(row.protocols[i]===type)return;row.protocols.push(type);}
function merge_device_record(byIp,rows,type,ip,mac,info){
    if(!ip||ip==='-')return null;
    if(!byIp[ip]){byIp[ip]=make_device_record(type,ip,mac,info);add_protocol(byIp[ip],type);rows.push(byIp[ip]);return byIp[ip];}
    var row=byIp[ip];add_protocol(row,type);if(row.mac==='-'&&mac!=='-')row.mac=mac;if(info&&info!=='-'&&(row.info==='-'||row.info===''))row.info=info;return row;
}
function merge_conflict(byIp,rows,ip,mac,info){
    var row=byIp[ip];if(!row){row=make_device_record('IP_CONFLICT',ip,mac,info);row.conflict=true;row.macs=[];row.macs.push(mac);byIp[ip]=row;rows.push(row);}
    row.conflict=true;add_protocol(row,'IP_CONFLICT');if(!row.macs)row.macs=[];if(mac&&mac!=='-'&&row.macs.indexOf(mac)<0)row.macs.push(mac);
    if(info&&info!=='-')row.info=info;if(row.macs.length>=2)row.info='MAC1='+row.macs[0]+'，MAC2='+row.macs[1];row.mac=row.macs.length?row.macs[0]:'-';return row;
}
function render_matrix(byIp){
    var box=document.getElementById('ip_matrix');if(!box)return;var nets={};
    for(var k in byIp){if(k==='-'||!/^(\d+\.){3}\d+$/.test(k))continue;var p=k.split('.');nets[p[0]+'.'+p[1]+'.'+p[2]+'.0']=1;}
    var initialNet=initial_status.ip&&/^(\d+\.){3}\d+$/.test(initial_status.ip)?initial_status.ip.split('.').slice(0,3).join('.')+'.0':'';
    if(initialNet)nets[initialNet]=1;
    var names=[];for(var n in nets)names.push(n);names.sort(function(a,b){return ip_key(a)-ip_key(b);});
    if(!names.length){box.innerHTML='<div class="muted">等待发现局域网网段...</div>';return;}
    if(!matrix_selected_net||!nets[matrix_selected_net])matrix_selected_net=initialNet&&nets[initialNet]?initialNet:names[0];
    var prefix=matrix_selected_net.substring(0,matrix_selected_net.lastIndexOf('.')+1);if(matrix_selected_ip&&matrix_selected_ip.indexOf(prefix)!==0)matrix_selected_ip='';
    box.innerHTML='';var tabs=document.createElement('div');tabs.className='ip-tabs';
    for(var i=0;i<names.length;i++){(function(net){var b=document.createElement('button');b.type='button';b.className='btn btn-small '+(matrix_selected_net===net?'active':'');b.textContent=net+'/24';b.onclick=function(){matrix_selected_net=net;matrix_selected_ip='';render_matrix(byIp);};tabs.appendChild(b);})(names[i]);}box.appendChild(tabs);
    var used=0,free=0,conflict=0;for(i=1;i<255;i++){var cr=byIp[ip_from_net(matrix_selected_net,i)];if(cr&&cr.conflict)conflict++;else if(cr)used++;else free++;}
    var title=document.createElement('div');title.className='ip-matrix-title';title.innerHTML='<strong>'+matrix_selected_net+'/24</strong>　已使用 <b>'+used+'</b>　未发现 <b>'+free+'</b>　冲突 <b class="conflict-text">'+conflict+'</b>';box.appendChild(title);
    var legend=document.createElement('div');legend.className='ip-legend';legend.innerHTML='<span><i class="ip-cell ip-used"></i>已使用</span><span><i class="ip-cell ip-free"></i>未发现</span><span><i class="ip-cell ip-self"></i>本机</span><span><i class="ip-cell ip-conflict"></i>IP冲突</span>';box.appendChild(legend);
    var grid=document.createElement('div');grid.className='ip-grid';
    for(i=1;i<255;i++){var ip=ip_from_net(matrix_selected_net,i),r=byIp[ip],cell=document.createElement('button');cell.type='button';cell.className='ip-cell '+(r?(r.conflict?'ip-conflict':(ip===initial_status.ip?'ip-self':'ip-used')):'ip-free');if(ip===matrix_selected_ip)cell.className+=' ip-selected';cell.textContent=i;
        cell.title=r?(ip+'\n状态：'+(r.conflict?'IP冲突':'已使用')+'\n协议：'+(r.protocols.length?r.protocols.join(' / '):'-')+'\nMAC：'+(r.conflict&&r.macs?r.macs.join(' / '):r.mac)+'\n'+(r.info||'-')):(ip+'\n当前未发现响应');
        cell.onclick=(function(ip,row){return function(){matrix_selected_ip=ip;var d=document.getElementById('ip_detail');if(d)d.textContent=row?(ip+' ｜ '+(row.conflict?'IP冲突':'已使用')+' ｜ '+(row.protocols.length?row.protocols.join(' / '):'-')+' ｜ MAC '+(row.conflict&&row.macs?row.macs.join(' / '):row.mac)+(row.info&&row.info!=='-'?' ｜ '+row.info:'')):(ip+' ｜ 当前未发现响应（不代表绝对不存在设备）');var cs=document.querySelectorAll('#ip_matrix .ip-grid .ip-cell');for(var q=0;q<cs.length;q++)cs[q].className=cs[q].className.replace(/\s*ip-selected/g,'');this.className+=' ip-selected';};})(ip,r);grid.appendChild(cell);
    }
    box.appendChild(grid);var detail=document.createElement('div');detail.id='ip_detail';detail.className='ip-detail '+(matrix_selected_ip?'':'muted');var sr=matrix_selected_ip?byIp[matrix_selected_ip]:null;if(sr)detail.textContent=matrix_selected_ip+' ｜ '+(sr.conflict?'IP冲突':'已使用')+' ｜ '+(sr.protocols.length?sr.protocols.join(' / '):'-')+' ｜ MAC '+(sr.conflict&&sr.macs?sr.macs.join(' / '):sr.mac)+(sr.info&&sr.info!=='-'?' ｜ '+sr.info:'');else if(matrix_selected_ip)detail.textContent=matrix_selected_ip+' ｜ 当前未发现响应（不代表绝对不存在设备）';else detail.textContent='点击IP方块查看详细信息';box.appendChild(detail);
}
function render_devices(s){
    var body=document.getElementById('devices');if(!body)return;var ls=lines(s),byIp={},rows=[];
    for(var i=0;i<ls.length;i++){
        var z=ls[i];if(z.indexOf('DEVICE ')!==0)continue;
        var type=(z.match(/type=([^ ]+)/)||[])[1]||'-';var ip=(z.match(/IP=([^ ]+)/)||[])[1]||'-';if(type==='SUBNET')continue;
        var mac=mac_norm((z.match(/MAC=([^ ]+)/)||[])[1]||'-');var info=(z.match(/INFO=(.*)$/)||[])[1]||'-';
        if(type==='IP_CONFLICT')merge_conflict(byIp,rows,ip,mac,info);else merge_device_record(byIp,rows,type,ip,mac,info);
    }
    rows.sort(function(a,b){var d=ip_key(a.ip)-ip_key(b.ip);return d!==0?d:String(a.ip).localeCompare(String(b.ip));});render_matrix(byIp);
    var pages=Math.max(1,Math.ceil(rows.length/5));if(device_page>pages)device_page=pages;body.innerHTML='';var start=(device_page-1)*5,end=Math.min(start+5,rows.length);
    for(var j=start;j<end;j++){var r=rows[j],tr=document.createElement('tr'),protocol=r.conflict?'IP冲突':(r.protocols.length?r.protocols.join(' / '):'-'),displayMac=r.conflict&&r.macs?r.macs.join(' / '):r.mac,vals=[String(j+1),protocol,r.ip,displayMac,r.info||'-'];for(var c=0;c<vals.length;c++){var td=document.createElement('td');td.textContent=vals[c];tr.appendChild(td);}if(r.conflict)tr.className='ip-conflict-row';body.appendChild(tr);}
    if(!body.children.length)body.innerHTML='<tr><td colspan="5" class="muted">暂无设备</td></tr>';
    var pager=document.getElementById('device_pager');if(!pager)return;pager.innerHTML='';if(!rows.length)return;var tip=document.createElement('span');tip.className='muted';tip.textContent='第 '+device_page+' / '+pages+' 页，共 '+rows.length+' 条';pager.appendChild(tip);
    var prev=document.createElement('button');prev.type='button';prev.className='btn btn-small';prev.style.marginLeft='8px';prev.disabled=device_page<=1;prev.textContent='上一页';prev.onclick=function(){if(device_page>1){device_page--;refresh_data();}};pager.appendChild(prev);
    var next=document.createElement('button');next.type='button';next.className='btn btn-small';next.style.marginLeft='4px';next.disabled=device_page>=pages;next.textContent='下一页';next.onclick=function(){if(device_page<pages){device_page++;refresh_data();}};pager.appendChild(next);
}
function render_log(s){var lg=document.getElementById('live_log');if(!lg)return;var ls=lines(s),out=[];for(var i=0;i<ls.length;i++){var t=String(ls[i]).replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g,'').replace(/\\/g,'');if(/^\d{2}:\d{2}:\d{2} /.test(t))out.push(t);}lg.textContent=out.join('\n')||'暂无日志';lg.scrollTop=lg.scrollHeight;}
function render_custom_hint(){var box=document.getElementById('custom_hint'),ta=document.getElementById('lan_discovery_custom');if(!box||!ta)return;var count=0;lines(ta.value).forEach(function(x){if(x.charAt(0)!=='#')count++;});box.textContent=count?'当前配置 '+count+' 项，保存后立即生效':'使用下面的默认示例即可启用标准探测';}
function sync_builtin_from_custom(){
    var ta=document.getElementById('lan_discovery_custom');if(!ta)return;
    var d={onvif:{port:'3702',enable:'0'},ssdp:{port:'1900',enable:'0'},hik:{port:'37020',enable:'0'},dahua:{port:'37810',enable:'0'},arp:{port:'0',enable:'0'}};
    var ls=lines(ta.value);
    for(var i=0;i<ls.length;i++){if(ls[i].charAt(0)==='#')continue;var p=ls[i].split('|');if(p.length<3)continue;var name=p[0].toLowerCase().replace(/_/g,'-');var en=p[2]==='1'?'1':'0';if(name==='onvif')d.onvif={port:p[1]||'3702',enable:en};else if(name==='ssdp')d.ssdp={port:p[1]||'1900',enable:en};else if(name==='hik'||name==='hik-sadp')d.hik={port:p[1]||'37020',enable:en};else if(name==='dahua'||name==='dahua-dhip')d.dahua={port:p[1]||'37810',enable:en};else if(name==='arp')d.arp={port:p[1]||'0',enable:en};}
    function set_radio(name,val){var el=document.getElementById(name+'_'+val);if(el)el.checked=true;}
    set_radio('lan_discovery_onvif',d.onvif.enable);set_radio('lan_discovery_ssdp',d.ssdp.enable);set_radio('lan_discovery_hik',d.hik.enable);set_radio('lan_discovery_dahua',d.dahua.enable);set_radio('lan_discovery_raw',d.arp.enable);
    document.getElementById('lan_discovery_onvif_port').value=d.onvif.port;document.getElementById('lan_discovery_ssdp_port').value=d.ssdp.port;document.getElementById('lan_discovery_hik_port').value=d.hik.port;document.getElementById('lan_discovery_dahua_port').value=d.dahua.port;
}
function normalize_custom_lines(){
    var ta=document.getElementById('lan_discovery_custom');if(!ta)return;
    var ls=lines(ta.value),out=[],have={onvif:0,ssdp:0,hik:0,dahua:0,arp:0};
    for(var i=0;i<ls.length;i++){
        var x=ls[i];if(x.charAt(0)==='#'){out.push(x);continue;}var p=x.split('|');var name=(p[0]||'').toLowerCase().replace(/_/g,'-');
        if(name==='onvif'||name==='ssdp'||name==='hik'||name==='hik-sadp'||name==='dahua'||name==='dahua-dhip'||name==='arp'){
            if(p.length<3)continue;var key=name==='hik'||name==='hik-sadp'?'hik':(name==='dahua'||name==='dahua-dhip'?'dahua':name);if(have[key]++)continue;
            out.push((key==='hik'?'hik-sadp':key==='dahua'?'dahua-dhip':key)+'|'+(p[1]||'0')+'|'+(p[2]==='1'?'1':'0'));continue;
        }
        if(p.length>=5)out.push(p[0]+'|'+p[1]+'|'+p[2]+'|'+p.slice(3,p.length-1).join('|')+'|'+(p[p.length-1]==='1'?'1':'0'));
    }
    if(!have.onvif)out.push('onvif|3702|1');if(!have.ssdp)out.push('ssdp|1900|1');if(!have.hik)out.push('hik-sadp|37020|1');if(!have.dahua)out.push('dahua-dhip|37810|1');if(!have.arp)out.push('arp|0|1');
    ta.value=out.join('\n');sync_builtin_from_custom();render_custom_hint();
}
function refresh_data(){var x=new XMLHttpRequest();x.onreadystatechange=function(){if(x.readyState!==4||x.status!==200)return;var o=parse_data(x.responseText);render_status(o);render_interfaces(o.interfaces);render_devices(o.devices);render_log(o.log);};x.open('GET','Advanced_LANDiscover_Data.asp?_='+new Date().getTime(),true);x.send(null);}
function applyRule(){if(!login_safe())return false;normalize_custom_lines();showLoading();document.form.action_mode.value='Apply';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function clearLog(){if(!login_safe())return false;showLoading();document.form.action_mode.value='Update';document.form.action_script.value='lan_discovery_clear_log';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function clearDevices(){if(!login_safe())return false;showLoading();document.form.action_mode.value='Update';document.form.action_script.value='lan_discovery_clear_devices';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='';document.form.submit();return false;}
function initial(){
    show_banner(1);show_menu(5,3,1);show_footer();
    var ta=document.getElementById('lan_discovery_custom');
    if(ta&&!lines(ta.value).length){ta.value='# 监控协议|端口|是否启用\nonvif|3702|1\nssdp|1900|1\nhik-sadp|37020|1\ndahua-dhip|37810|1\n# ARP|占位符|是否启用\narp|0|1\n# 名称|目标地址|端口|探测内容|启用\n# 示例探测|239.255.255.250|9999|hello world|1';}
    sync_builtin_from_custom();render_custom_hint();refresh_data();if(refresh_timer)clearInterval(refresh_timer);refresh_timer=setInterval(refresh_data,1000);
}
</script>
<style>
.status-table td{white-space:nowrap}.mini{width:48px;margin:0 4px}.live-box{height:220px;overflow-y:auto;overflow-x:hidden;background:#111;color:#ddd;padding:8px;font:12px monospace;white-space:pre-wrap;word-break:break-all}.table th,.table td{vertical-align:middle}.custom-box{margin:10px 0}.custom-area{font-family:monospace;min-height:190px;width:100%;box-sizing:border-box;white-space:pre;line-height:1.55}.custom-format{margin:0 0 8px}.ip-tabs{margin:8px 0}.ip-tabs .btn{margin:0 4px 4px 0}.ip-matrix-title{margin:6px 0}.ip-legend{margin:6px 0 8px}.ip-legend span{margin-right:12px}.ip-cell{display:inline-block;width:22px;height:22px;line-height:20px;padding:0;text-align:center;font-size:10px;border:1px solid #aaa;border-radius:3px;box-sizing:border-box}.ip-grid{display:grid;grid-template-columns:repeat(16,minmax(18px,1fr));gap:3px;padding:8px;border:1px solid #ddd;background:#f7f7f7;width:100%;box-sizing:border-box}.ip-grid .ip-cell{display:block;width:100%;cursor:pointer}.ip-used{background:#7cc576;color:#1b4d1b;border-color:#4b9446}.ip-free{background:#eeeeee;color:#888;border-color:#cccccc}.ip-self{background:#5bc0de;color:#064f66;border-color:#269abc}.ip-conflict{background:#d9534f;color:#fff;border-color:#b52b27}.ip-selected{box-shadow:0 0 0 2px #333 inset}.ip-detail{margin-top:8px;padding:6px;background:#f5f5f5;border:1px solid #ddd;min-height:18px;word-break:break-all}.ip-legend .ip-cell{vertical-align:middle;margin-right:4px}.conflict-text,.health-danger{color:#c9302c}.ip-conflict-row td{background:#f2dede!important;color:#a94442}.hidden-builtin{display:none!important}
</style>
</head>
<body onLoad="initial();" onunload="return unload_body();">
<div class="wrapper"><div class="container-fluid" style="padding-right:0px"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div><iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp"><input type="hidden" name="next_page" value=""><input type="hidden" name="next_host" value=""><input type="hidden" name="sid_list" value="LANHostConfig;"><input type="hidden" name="group_id" value=""><input type="hidden" name="action_mode" value=""><input type="hidden" name="action_script" value="">
<div class="container-fluid"><div class="row-fluid"><div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN监听与设备发现</h2><div class="round_bottom"><div id="tabMenu" class="submenuBlock"></div><div class="alert alert-info" style="margin:10px">LAN口插拔、上级DHCP、设备发现及网络健康检测由后端实时运行；本页面负责参数配置和状态显示。</div>
<table class="table table-condensed status-table"><tr><th colspan="6">当前状态</th></tr><tr><td>检测接口</td><td id="status_iface">-</td><td>LAN IPv4</td><td id="status_ip">-</td><td>LAN口状态</td><td id="status_link">-</td></tr><tr><td>LAN MAC</td><td id="status_mac">-</td><td>上级DHCP</td><td id="status_dhcp">-</td><td>发现状态</td><td id="status_state">-</td></tr><tr><td>已发现</td><td id="status_count">0</td><td>最后活动</td><td id="status_last">-</td><td>网络健康</td><td id="status_health">-</td></tr><tr><td>广播速率</td><td id="status_broadcast">0/s</td><td>MAC回流</td><td id="status_loop">0/s</td><td>说明</td><td>红色=异常</td></tr></table>
<table class="table table-bordered table-condensed">
<tr><th width="180">检测接口</th><td><select name="lan_discovery_ifname" id="lan_ifname" class="span9"><option value="<% nvram_get_x("", "lan_discovery_ifname"); %>" selected><% nvram_get_x("", "lan_discovery_ifname"); %> | LAN</option></select></td></tr>
<tr><th>LAN监听</th><td><div class="main_itoggle"><div id="lan_discovery_enable_on_of"><input type="checkbox" id="lan_discovery_enable_fake" <% nvram_match_x("", "lan_discovery_enable", "1", "value=1 checked"); %>></div></div><div class="hidden-builtin"><input type="radio" value="1" name="lan_discovery_enable" id="lan_discovery_enable_1" <% nvram_match_x("", "lan_discovery_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_enable" id="lan_discovery_enable_0" <% nvram_match_x("", "lan_discovery_enable", "0", "checked"); %>></div></td></tr>
<tr><th>DHCP检测</th><td><div class="main_itoggle"><div id="lan_discovery_dhcp_enable_on_of"><input type="checkbox" id="lan_discovery_dhcp_enable_fake" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "value=1 checked"); %>></div></div><div class="hidden-builtin"><input type="radio" value="1" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dhcp_enable" id="lan_discovery_dhcp_enable_0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "checked"); %>></div></td></tr>
<tr><th>DHCP等待时间</th><td><input class="mini" name="lan_discovery_dhcp_timeout" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒　<span class="muted">插入LAN后等待上级DHCP响应的时间</span></td></tr>
<tr><th>设备发现</th><td><div class="main_itoggle"><div id="lan_discovery_discover_enable_on_of"><input type="checkbox" id="lan_discovery_discover_enable_fake" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "value=1 checked"); %>></div></div><div class="hidden-builtin"><input type="radio" value="1" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_discover_enable" id="lan_discovery_discover_enable_0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "checked"); %>></div></td></tr>
<tr><th>设备发现周期</th><td><input class="mini" name="lan_discovery_cycle" onkeypress="return is_number(this,event);" value="<% nvram_get_x("", "lan_discovery_cycle"); %>"> 秒　<span class="muted">两轮主动探测开始之间的目标周期</span></td></tr>
<tr class="hidden-builtin"><td colspan="2"><input type="radio" value="1" name="lan_discovery_raw" id="lan_discovery_raw_1" <% nvram_match_x("", "lan_discovery_raw", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_raw" id="lan_discovery_raw_0" <% nvram_match_x("", "lan_discovery_raw", "0", "checked"); %>><input name="lan_discovery_onvif_port" id="lan_discovery_onvif_port" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"><input type="radio" value="1" name="lan_discovery_onvif" id="lan_discovery_onvif_1" <% nvram_match_x("", "lan_discovery_onvif", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_onvif" id="lan_discovery_onvif_0" <% nvram_match_x("", "lan_discovery_onvif", "0", "checked"); %>><input name="lan_discovery_ssdp_port" id="lan_discovery_ssdp_port" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"><input type="radio" value="1" name="lan_discovery_ssdp" id="lan_discovery_ssdp_1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_ssdp" id="lan_discovery_ssdp_0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "checked"); %>><input name="lan_discovery_hik_port" id="lan_discovery_hik_port" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"><input type="radio" value="1" name="lan_discovery_hik" id="lan_discovery_hik_1" <% nvram_match_x("", "lan_discovery_hik", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_hik" id="lan_discovery_hik_0" <% nvram_match_x("", "lan_discovery_hik", "0", "checked"); %>><input name="lan_discovery_dahua_port" id="lan_discovery_dahua_port" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"><input type="radio" value="1" name="lan_discovery_dahua" id="lan_discovery_dahua_1" <% nvram_match_x("", "lan_discovery_dahua", "1", "checked"); %>><input type="radio" value="0" name="lan_discovery_dahua" id="lan_discovery_dahua_0" <% nvram_match_x("", "lan_discovery_dahua", "0", "checked"); %>></td></tr>
</table>
<div class="custom-box"><h4>自定义接口</h4><div class="alert alert-info custom-format">下面的文本框就是完整配置。以 <b>#</b> 开头的是说明行，不参与探测；标准探测使用三列格式，普通自定义UDP使用五列格式。</div><textarea name="lan_discovery_custom" id="lan_discovery_custom" class="custom-area" rows="12" oninput="render_custom_hint();sync_builtin_from_custom();"><% nvram_get_x("", "lan_discovery_custom"); %></textarea><div id="custom_hint" class="muted">标准探测默认启用</div></div>
<h4>IP占用情况 <button type="button" class="btn btn-mini pull-right" onclick="clearDevices();return false;">清空已发现设备</button></h4><div class="alert alert-info">绿色=已使用，灰色=当前未发现，蓝色=Padavan本机，红色=IP冲突。空白IP只表示当前没有收到ARP/设备响应，不代表绝对不存在设备。</div><div id="ip_matrix"><div class="muted">等待发现局域网网段...</div></div>
<h4 style="margin-top:12px">已发现设备</h4><table class="table table-bordered table-condensed"><thead><tr><th>序号</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th></tr></thead><tbody id="devices"><tr><td colspan="5" class="muted">暂无设备</td></tr></tbody></table><div id="device_pager" style="padding:6px 0;text-align:right"></div>
<h4>实时监听日志 <button type="button" class="btn btn-mini pull-right" onclick="clearLog();return false;">清空日志</button></h4><pre id="live_log" class="live-box">暂无日志</pre>
<table class="table"><tr><td style="border:0"><center><input class="btn btn-primary" style="width:219px" type="button" value="保存" onclick="applyRule();return false;"></center></td></tr></table>
</div></div></div></div></div></div></form><div id="footer"></div></div>
</body>
</html>
