<!DOCTYPE html>
<html>
<head>
<title><#Web_Title#> - 局域网发现</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.ico">
<link rel="icon" href="images/favicon.png">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript">
var $j = jQuery.noConflict();
<% login_state_hook(); %>

/*
 * Do not modify state.js menu tables. Padavan generates the stock menu in
 * show_menu(); this page only appends one item after that generation.
 */
function add_lan_discovery_menu(){
	var m = document.getElementById('mainMenu');
	if(!m) return;
	if(document.getElementById('option_lan_discovery')) return;
	var li = document.createElement('li');
	li.id = 'option_lan_discovery';
	li.innerHTML = '<a href="Advanced_LANDiscover_Content.asp" title="LAN自动发现"><i class="icon-search"></i>&nbsp;&nbsp;LAN自动发现</a>';
	m.appendChild(li);
}

function initial(){
	show_banner(1);
	if(typeof(show_menu) == 'function') show_menu(5,7,6);
	add_lan_discovery_menu();
	show_footer();
	var defaults={lan_discovery_ifname:'eth2.1',lan_discovery_dhcp_timeout:'3',lan_discovery_timeout:'10',lan_discovery_onvif_port:'3702',lan_discovery_ssdp_port:'1900',lan_discovery_hik_port:'37020',lan_discovery_dahua_port:'37810'};
	for(var k in defaults){
		if(document.form[k] && document.form[k].value==='') document.form[k].value=defaults[k];
	}
}
function checkEnter(e){e=e||window.event;return (e.keyCode||e.which||0)===13;}
function save(){
	if(!login_safe()) return false;
	document.form.action_mode.value=' Apply ';
	document.form.current_page.value='Advanced_LANDiscover_Content.asp';
	document.form.next_page.value='Advanced_LANDiscover_Content.asp';
	document.form.submit();
	return true;
}
</script>
</head>
<body onLoad="initial();">
<div class="wrapper">
	<div class="container-fluid" style="padding-right:0px"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
	<div id="Loading" class="popup_bg"></div>
	<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
	<form method="post" name="form" action="apply.cgi" onkeypress="return !checkEnter(event)">
		<input type="hidden" name="current_page" value=""><input type="hidden" name="next_page" value=""><input type="hidden" name="next_host" value=""><input type="hidden" name="sid_list" value=""><input type="hidden" name="group_id" value=""><input type="hidden" name="action_mode" value=""><input type="hidden" name="action_script" value="">
		<div class="container-fluid"><div class="row-fluid">
			<div class="span3"><div class="well sidebar-nav side_nav" style="padding:0px;"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
			<div class="span9"><div class="row-fluid"><div class="span12"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">局域网自动发现</h2><div class="round_bottom"><div class="row-fluid">
				<div id="tabMenu" class="submenuBlock"></div>
				<div class="alert alert-info" style="margin:10px;">LAN口产生 Link Up 事件后，先检测 DHCP，再执行设备发现。默认启用；自身设备地址会自动过滤。</div>
				<table width="100%" cellpadding="4" cellspacing="0" class="table">
					<tr><td>LAN事件检测</td><td><select name="lan_discovery_enable" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_enable", "0", "selected"); %>>禁用</option></select></td></tr>
					<tr><td>检测接口</td><td><input name="lan_discovery_ifname" class="span6" value="<% nvram_get_x("", "lan_discovery_ifname"); %>"></td></tr>
					<tr><td>DHCP检测</td><td><select name="lan_discovery_dhcp_enable" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "selected"); %>>禁用</option></select></td></tr>
					<tr><td>DHCP超时(秒)</td><td><input name="lan_discovery_dhcp_timeout" class="span3" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"></td></tr>
					<tr><td>设备发现</td><td><select name="lan_discovery_discover_enable" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "selected"); %>>禁用</option></select></td></tr>
					<tr><td>发现超时(秒)</td><td><input name="lan_discovery_timeout" class="span3" value="<% nvram_get_x("", "lan_discovery_timeout"); %>"></td></tr>
					<tr><td>ONVIF</td><td><select name="lan_discovery_onvif" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_onvif", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_onvif", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_onvif_port" class="span2" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"></td></tr>
					<tr><td>SSDP</td><td><select name="lan_discovery_ssdp" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_ssdp_port" class="span2" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"></td></tr>
					<tr><td>HIK-SADP</td><td><select name="lan_discovery_hik" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_hik", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_hik", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_hik_port" class="span2" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"></td></tr>
					<tr><td>DAHUA-DHIP</td><td><select name="lan_discovery_dahua" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_dahua", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dahua", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_dahua_port" class="span2" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"></td></tr>
					<tr><td>ARP/IP被动发现</td><td><select name="lan_discovery_raw" class="span6"><option value="1" <% nvram_match_x("", "lan_discovery_raw", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_raw", "0", "selected"); %>>禁用</option></select></td></tr>
				</table><div class="row-fluid"><div class="span12"><button type="button" class="btn btn-primary" onClick="save();">保存设置</button></div></div>
			</div></div></div></div></div>
		</div></div>
	</form><div id="footer"></div>
</div>
</body>
</html>
