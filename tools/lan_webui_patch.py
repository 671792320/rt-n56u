#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / 'trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp'
STATE = ROOT / 'trunk/user/www/n56u_ribbon_fixed/state.js'
CAM = ROOT / 'trunk/user/camdiscover/camdiscover.c'
LAN = ROOT / 'trunk/user/lan_autodiscover/lan_autodiscover.sh'


def patch_state():
    s = STATE.read_text()
    marker = 'var lan_discovery_menu_index = -1;'
    if marker not in s:
        # Add a real L1 sidebar item. This is independent of the LAN submenu.
        anchor = 'var menu_code="", menu1_code="", menu2_code="", tab_code="", footer_code;'
        if anchor not in s:
            raise SystemExit('state.js menu declaration not found')
        inject = '''var menu_code="", menu1_code="", menu2_code="", tab_code="", footer_code;\n\n/* Q7 LAN discovery: dedicated first-level sidebar item. */\nvar lan_discovery_menu_index = -1;\nif (typeof menuL1_title != "undefined" && typeof menuL1_link != "undefined" && typeof menuL1_icon != "undefined") {\n    var _lan_discovery_exists = false;\n    for (var _ldi = 1; _ldi < menuL1_title.length; _ldi++) {\n        if (menuL1_link[_ldi] == "Advanced_LANDiscover_Content.asp") {\n            lan_discovery_menu_index = _ldi;\n            _lan_discovery_exists = true;\n            break;\n        }\n    }\n    if (!_lan_discovery_exists) {\n        lan_discovery_menu_index = menuL1_title.length;\n        menuL1_title.push("LAN自动发现");\n        menuL1_link.push("Advanced_LANDiscover_Content.asp");\n        menuL1_icon.push("icon-search");\n    }\n}\n'''
        s = s.replace(anchor, inject, 1)
    STATE.write_text(s)


def patch_page():
    page = '''<!DOCTYPE html>\n<html>\n<head>\n<title><#Web_Title#> - LAN自动发现</title>\n<meta http-equiv="Content-Type" content="text/html; charset=utf-8">\n<meta http-equiv="Pragma" content="no-cache">\n<meta http-equiv="Expires" content="-1">\n<link rel="shortcut icon" href="images/favicon.ico">\n<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">\n<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">\n<script type="text/javascript" src="/jquery.js"></script>\n<script type="text/javascript" src="/state.js"></script>\n<script type="text/javascript" src="/general.js"></script>\n<script type="text/javascript" src="/popup.js"></script>\n<script>\nvar $j = jQuery.noConflict();\n<% login_state_hook(); %>\nfunction checkEnter(e){ e=e||window.event; return (e.keyCode||e.which||0) === 13; }\nfunction initial(){\n  var m = (typeof lan_discovery_menu_index == 'number' && lan_discovery_menu_index > 0) ? lan_discovery_menu_index : 5;\n  show_banner(1); show_menu(m,0,0); show_footer();\n  var d={lan_discovery_enable:'1',lan_discovery_ifname:'eth2.1',lan_discovery_dhcp_enable:'1',lan_discovery_dhcp_timeout:'3',lan_discovery_discover_enable:'1',lan_discovery_timeout:'10',lan_discovery_onvif:'1',lan_discovery_ssdp:'1',lan_discovery_hik:'1',lan_discovery_dahua:'1',lan_discovery_raw:'1',lan_discovery_onvif_port:'3702',lan_discovery_ssdp_port:'1900',lan_discovery_hik_port:'37020',lan_discovery_dahua_port:'37810'};\n  for(var k in d){ if(document.form[k] && document.form[k].value==='') document.form[k].value=d[k]; }\n  for(var i=1;i<=6;i++){\n    var n='lan_discovery_custom_'+i+'_name', p='lan_discovery_custom_'+i+'_port', e='lan_discovery_custom_'+i+'_enable', q='lan_discovery_custom_'+i+'_payload';\n    if(document.form[e] && document.form[e].value==='') document.form[e].value='0';\n    if(document.form[n] && document.form[n].value==='') document.form[n].value='';\n    if(document.form[p] && document.form[p].value==='') document.form[p].value='';\n    if(document.form[q] && document.form[q].value==='') document.form[q].value='';\n  }\n}\nfunction save(){\n  if (!login_safe()) return false;\n  document.form.action_mode.value=' Apply ';\n  document.form.current_page.value='Advanced_LANDiscover_Content.asp';\n  document.form.next_page.value='Advanced_LANDiscover_Content.asp';\n  document.form.submit();\n}\n</script>\n</head>\n<body onLoad="initial();">\n<div class="wrapper"><div class="container-fluid"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>\n<div id="Loading" class="popup_bg"></div><iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>\n<form method="post" name="form" action="apply.cgi" onkeypress="return !checkEnter(event)">\n<input type="hidden" name="current_page" value=""><input type="hidden" name="next_page" value=""><input type="hidden" name="next_host" value=""><input type="hidden" name="sid_list" value=""><input type="hidden" name="action_mode" value=""><input type="hidden" name="action_script" value="">\n<div class="container-fluid"><div class="row-fluid"><div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>\n<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN 自动发现</h2><div class="round_bottom">\n<div class="alert alert-info">LAN口 Link Up 后自动检测 DHCP；没有 DHCP 时执行设备发现。自身 IP/MAC 自动过滤。参数保存到 NVRAM，可用于其它 Padavan 机型移植。</div>\n<h4>基本设置</h4><table width="100%" cellpadding="4" cellspacing="0" class="table">\n<tr><td>LAN自动发现</td><td><select name="lan_discovery_enable" class="span4"><option value="1" <% nvram_match_x("", "lan_discovery_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_enable", "0", "selected"); %>>禁用</option></select></td></tr>\n<tr><td>检测接口</td><td><input name="lan_discovery_ifname" class="span4" value="<% nvram_get_x("", "lan_discovery_ifname"); %>"></td></tr>\n<tr><td>DHCP检测</td><td><select name="lan_discovery_dhcp_enable" class="span4"><option value="1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "selected"); %>>禁用</option></select>　超时 <input name="lan_discovery_dhcp_timeout" class="span2" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>"> 秒</td></tr>\n<tr><td>设备发现</td><td><select name="lan_discovery_discover_enable" class="span4"><option value="1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "selected"); %>>禁用</option></select>　超时 <input name="lan_discovery_timeout" class="span2" value="<% nvram_get_x("", "lan_discovery_timeout"); %>"> 秒</td></tr>\n</table>\n<h4>内置协议</h4><table width="100%" class="table">\n<tr><td>ONVIF</td><td><select name="lan_discovery_onvif"><option value="1" <% nvram_match_x("", "lan_discovery_onvif", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_onvif", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_onvif_port" class="span2" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"></td></tr>\n<tr><td>SSDP/UPnP</td><td><select name="lan_discovery_ssdp"><option value="1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_ssdp_port" class="span2" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"></td></tr>\n<tr><td>HIK-SADP</td><td><select name="lan_discovery_hik"><option value="1" <% nvram_match_x("", "lan_discovery_hik", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_hik", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_hik_port" class="span2" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"></td></tr>\n<tr><td>DAHUA-DHIP</td><td><select name="lan_discovery_dahua"><option value="1" <% nvram_match_x("", "lan_discovery_dahua", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dahua", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_dahua_port" class="span2" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"></td></tr>\n<tr><td>ARP/IP被动发现</td><td><select name="lan_discovery_raw"><option value="1" <% nvram_match_x("", "lan_discovery_raw", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_raw", "0", "selected"); %>>禁用</option></select></td></tr>\n</table>\n<h4>自定义 UDP 发现</h4><div class="alert alert-warning">用于没有 ONVIF/SSDP/SADP/DHIP 的设备。填写名称和 UDP 端口即可；可选填写发送内容，空白时发送空 UDP 广播。最多 6 项。</div>\n<table width="100%" class="table table-condensed"><tr><th>启用</th><th>名称</th><th>UDP端口</th><th>发送内容</th></tr>\n'''
    for i in range(1,7):
        page += f'<tr><td><select name="lan_discovery_custom_{i}_enable"><option value="1" <% nvram_match_x("", "lan_discovery_custom_{i}_enable", "1", "selected"); %>>是</option><option value="0" <% nvram_match_x("", "lan_discovery_custom_{i}_enable", "0", "selected"); %>>否</option></select></td><td><input name="lan_discovery_custom_{i}_name" class="span3" value="<% nvram_get_x("", "lan_discovery_custom_{i}_name"); %>"></td><td><input name="lan_discovery_custom_{i}_port" class="span2" value="<% nvram_get_x("", "lan_discovery_custom_{i}_port"); %>"></td><td><input name="lan_discovery_custom_{i}_payload" class="span5" value="<% nvram_get_x("", "lan_discovery_custom_{i}_payload"); %>"></td></tr>\n'
    page += '''</table><div class="row-fluid"><div class="span12"><button type="button" class="btn btn-primary" onClick="save();">保存设置</button></div></div>\n</div></div></div></div></div></div></form><div id="footer"></div></div></body></html>\n'''
    PAGE.write_text(page)


def patch_camdiscover():
    s = CAM.read_text()
    if 'CUSTOM UDP discovery' in s:
        return
    s = s.replace('#define MAX_DEVICES     256\n', '#define MAX_DEVICES     256\n#define MAX_CUSTOM      6\n', 1)
    s = s.replace('''struct discover_ctx {\n    int fd_onvif;\n''', '''struct custom_probe {\n    int fd;\n    int port;\n    char name[64];\n};\n\nstruct discover_ctx {\n    int fd_onvif;\n''', 1)
    s = s.replace('''    int fd_raw;\n    const char *ifname;\n''', '''    int fd_raw;\n    struct custom_probe custom[MAX_CUSTOM];\n    int custom_count;\n    const char *ifname;\n''', 1)
    insert = r'''
/* CUSTOM UDP discovery: configurable broadcast probes, independent of vendor protocols. */
static int make_custom_receiver(const char *ifname, int port)
{
    int fd, yes = 1;
    struct sockaddr_in a;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
#ifdef SO_BINDTODEVICE
    if (ifname && *ifname) setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, ifname, strlen(ifname) + 1);
#endif
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
    return fd;
}

static int send_custom_probe(int fd, int port, const char *payload)
{
    struct sockaddr_in d;
    const char *p = payload ? payload : "";
    size_t n = strlen(p);
    d.sin_family = AF_INET;
    d.sin_port = htons((unsigned short)port);
    d.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    return sendto(fd, p, n, 0, (struct sockaddr *)&d, sizeof(d)) == (ssize_t)n ? 0 : -1;
}

static void handle_custom(int fd, const char *name, int port)
{
    unsigned char x[BUF_SIZE];
    struct sockaddr_in s;
    socklen_t sl = sizeof(s);
    ssize_t n;
    char ip[INET_ADDRSTRLEN], info[256];
    n = recvfrom(fd, x, sizeof(x), 0, (struct sockaddr *)&s, &sl);
    if (n <= 0) return;
    inet_ntop(AF_INET, &s.sin_addr, ip, sizeof(ip));
    snprintf(info, sizeof(info), "UDP port=%d response_len=%ld", port, (long)n);
    print_text_device(name && *name ? name : "CUSTOM-UDP", ip, info);
}

static int load_custom_file(const char *path, struct discover_ctx *c)
{
    FILE *f;
    char line[512];
    if (!path || !*path) return 0;
    f = fopen(path, "r");
    if (!f) return 0;
    while (c->custom_count < MAX_CUSTOM && fgets(line, sizeof(line), f)) {
        char *p1, *p2, *nl;
        int port;
        nl = strchr(line, '\n'); if (nl) *nl = 0;
        p1 = strchr(line, '|'); if (!p1) continue;
        *p1++ = 0;
        p2 = strchr(p1, '|'); if (!p2) continue;
        *p2++ = 0;
        port = atoi(p1);
        if (port < 1 || port > 65535 || !*line) continue;
        c->custom[c->custom_count].port = port;
        strncpy(c->custom[c->custom_count].name, line, sizeof(c->custom[c->custom_count].name)-1);
        c->custom[c->custom_count].name[sizeof(c->custom[c->custom_count].name)-1] = 0;
        c->custom[c->custom_count].fd = make_custom_receiver(c->ifname, port);
        if (c->custom[c->custom_count].fd >= 0) {
            send_custom_probe(c->custom[c->custom_count].fd, port, p2);
            c->custom_count++;
        }
    }
    fclose(f);
    return c->custom_count;
}
'''
    anchor = 'static int make_udp_receiver(const char *group, int port, unsigned int ifindex)\n'
    s = s.replace(anchor, insert + '\n' + anchor, 1)
    s = s.replace('''static void usage(const char *p)\n{\n    printf("Usage: %s [-i interface] [-t seconds] [-o onvif] [-s ssdp] [-k hik] [-d dahua] [-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1]\\n", p);\n''', '''static void usage(const char *p)\n{\n    printf("Usage: %s [-i interface] [-t seconds] [-o onvif] [-s ssdp] [-k hik] [-d dahua] [-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1] [-F custom_file]\\n", p);\n''', 1)
    s = s.replace('''    printf("  -A              enable ARP/IPv4 passive discovery\\n");\n}\n''', '''    printf("  -A              enable ARP/IPv4 passive discovery\\n");\n    printf("  -F file         custom UDP discovery file: name|port|payload\\n");\n}\n''', 1)
    s = s.replace('''    int enable_dahua = 1, enable_raw = 1;\n    int opt;\n''', '''    int enable_dahua = 1, enable_raw = 1;\n    const char *custom_file = NULL;\n    int opt;\n''', 1)
    s = s.replace('"i:t:o:s:k:d:O:S:H:D:A:h"', '"i:t:o:s:k:d:O:S:H:D:A:F:h"', 1)
    s = s.replace("        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;\n", "        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;\n        else if (opt == 'F') custom_file = optarg;\n", 1)
    s = s.replace('''    c.fd_onvif = c.fd_ssdp = c.fd_hik = c.fd_dahua = c.fd_raw = -1;\n''', '''    c.fd_onvif = c.fd_ssdp = c.fd_hik = c.fd_dahua = c.fd_raw = -1;\n    memset(c.custom, 0, sizeof(c.custom));\n    { int _ci; for (_ci=0; _ci<MAX_CUSTOM; _ci++) c.custom[_ci].fd = -1; }\n''', 1)
    s = s.replace('''    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;\n''', '''    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;\n    if (custom_file) load_custom_file(custom_file, &c);\n''', 1)
    s = s.replace('''        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &rfds); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }\n''', '''        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &rfds); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }\n        { int _ci; for (_ci=0; _ci<c.custom_count; _ci++) if (c.custom[_ci].fd >= 0) { FD_SET(c.custom[_ci].fd, &rfds); if (c.custom[_ci].fd > maxfd) maxfd = c.custom[_ci].fd; } }\n''', 1)
    s = s.replace('''        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &rfds)) handle_raw(c.fd_raw);\n''', '''        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &rfds)) handle_raw(c.fd_raw);\n        { int _ci; for (_ci=0; _ci<c.custom_count; _ci++) if (c.custom[_ci].fd >= 0 && FD_ISSET(c.custom[_ci].fd, &rfds)) handle_custom(c.custom[_ci].fd, c.custom[_ci].name, c.custom[_ci].port); }\n''', 1)
    s = s.replace('''    if (c.fd_raw >= 0) close(c.fd_raw);\n    return 0;\n''', '''    if (c.fd_raw >= 0) close(c.fd_raw);\n    { int _ci; for (_ci=0; _ci<c.custom_count; _ci++) if (c.custom[_ci].fd >= 0) close(c.custom[_ci].fd); }\n    return 0;\n''', 1)
    CAM.write_text(s)


def patch_lan_script():
    s = LAN.read_text()
    marker = '    custom_file="/tmp/lan_discovery_custom.$$"\n'
    if marker not in s:
        needle = '    log "starting device discovery on $iface"\n'
        inject = '''    custom_file="/tmp/lan_discovery_custom.$$"\n    : > "$custom_file"\n    i=1\n    while [ "$i" -le 6 ]; do\n        ce="$(cfg lan_discovery_custom_${i}_enable 0)"\n        cn="$(cfg lan_discovery_custom_${i}_name "")"\n        cp="$(cfg lan_discovery_custom_${i}_port "")"\n        cx="$(cfg lan_discovery_custom_${i}_payload "")"\n        if [ "$ce" = "1" ] && [ -n "$cn" ] && [ -n "$cp" ]; then\n            printf '%s|%s|%s\\n' "$cn" "$cp" "$cx" >> "$custom_file"\n        fi\n        i=$((i + 1))\n    done\n\n'''
        if needle not in s:
            raise SystemExit('lan_autodiscover discovery block not found')
        s = s.replace(needle, inject + needle, 1)
        old = '''            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" \\\n            >/tmp/camdiscover_lan.log 2>&1\n        log "device discovery finished"\n'''
        new = '''            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" -F "$custom_file" \\\n            >/tmp/camdiscover_lan.log 2>&1\n        rm -f "$custom_file"\n        log "device discovery finished"\n'''
        if old not in s:
            raise SystemExit('lan_autodiscover camdiscover invocation not found')
        s = s.replace(old, new, 1)
    LAN.write_text(s)


def main():
    patch_state()
    patch_page()
    patch_camdiscover()
    patch_lan_script()

if __name__ == '__main__':
    main()
