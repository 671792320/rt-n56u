#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, old, new):
    p = ROOT / path
    s = p.read_text()
    if old not in s:
        raise SystemExit(f'pattern not found: {path}: {old[:80]!r}')
    p.write_text(s.replace(old, new, 1))


def patch_camdiscover():
    path = ROOT / 'trunk/user/camdiscover/camdiscover.c'
    s = path.read_text()
    if 'static char self_mac[32];' not in s:
        s = s.replace('static int seen_count;\n', '''static int seen_count;\nstatic char self_mac[32];\nstatic char self_ips[16][INET_ADDRSTRLEN];\nstatic int self_ip_count;\n''', 1)
        s = s.replace('static void print_ipv4_device(const char *kind, const char *ip, const char *mac)\n{\n', '''static int is_self_ip(const char *ip)\n{\n    int i;\n    if (!ip || !*ip) return 0;\n    for (i = 0; i < self_ip_count; i++)\n        if (!strcmp(self_ips[i], ip)) return 1;\n    return 0;\n}\n\nstatic void load_self_addresses(void)\n{\n    int fd;\n    char buf[4096];\n    struct ifconf ifc;\n    struct ifreq *ifr;\n    int i, n;\n\n    self_ip_count = 0;\n    self_mac[0] = 0;\n    fd = socket(AF_INET, SOCK_DGRAM, 0);\n    if (fd < 0) return;\n    memset(&ifc, 0, sizeof(ifc));\n    ifc.ifc_len = sizeof(buf);\n    ifc.ifc_buf = buf;\n    if (ioctl(fd, SIOCGIFCONF, &ifc) == 0) {\n        n = ifc.ifc_len / (int)sizeof(struct ifreq);\n        ifr = ifc.ifc_req;\n        for (i = 0; i < n && self_ip_count < 16; i++) {\n            struct sockaddr_in *sa = (struct sockaddr_in *)&ifr[i].ifr_addr;\n            if (sa->sin_family == AF_INET &&\n                inet_ntop(AF_INET, &sa->sin_addr, self_ips[self_ip_count], INET_ADDRSTRLEN))\n                self_ip_count++;\n        }\n    }\n    close(fd);\n}\n\nstatic void load_self_mac(const char *ifname)\n{\n    int fd;\n    struct ifreq ifr;\n    unsigned char *m;\n    if (!ifname) return;\n    fd = socket(AF_INET, SOCK_DGRAM, 0);\n    if (fd < 0) return;\n    memset(&ifr, 0, sizeof(ifr));\n    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);\n    if (ioctl(fd, SIOCGIFHWADDR, &ifr) == 0) {\n        m = (unsigned char *)ifr.ifr_hwaddr.sa_data;\n        snprintf(self_mac, sizeof(self_mac), "%02x:%02x:%02x:%02x:%02x:%02x",\n                 m[0], m[1], m[2], m[3], m[4], m[5]);\n    }\n    close(fd);\n}\n\nstatic void print_ipv4_device(const char *kind, const char *ip, const char *mac)\n{\n''', 1)
        s = s.replace('    char key[80];\n    snprintf(key, sizeof(key), "%s:%s:%s", kind, ip ? ip : "", mac ? mac : "");\n', '    char key[80];\n    if (is_self_ip(ip)) return;\n    snprintf(key, sizeof(key), "%s:%s:%s", kind, ip ? ip : "", mac ? mac : "");\n', 1)
        s = s.replace('static void print_text_device(const char *kind, const char *ip, const char *text)\n{\n    char key[80];\n', 'static void print_text_device(const char *kind, const char *ip, const char *text)\n{\n    char key[80];\n    if (is_self_ip(ip)) return;\n', 1)
        s = s.replace('    mac_to_text(buf + 6, mac, sizeof(mac));\n\n    if (proto == ETH_P_ARP', '    mac_to_text(buf + 6, mac, sizeof(mac));\n    if (self_mac[0] && !strcasecmp(mac, self_mac)) return;\n\n    if (proto == ETH_P_ARP', 1)

    s = s.replace('static int send_onvif_probe(int fd)\n', 'static int send_onvif_probe(int fd, int port)\n', 1)
    s = s.replace('return send_multicast(fd, ONVIF_ADDR, ONVIF_PORT, p, (size_t)n);', 'return send_multicast(fd, ONVIF_ADDR, port, p, (size_t)n);', 1)
    s = s.replace('static int send_ssdp_probe(int fd)\n', 'static int send_ssdp_probe(int fd, int port)\n', 1)
    s = s.replace('return send_multicast(fd, SSDP_ADDR, SSDP_PORT, p, strlen(p));', 'return send_multicast(fd, SSDP_ADDR, port, p, strlen(p));', 1)
    s = s.replace('static int send_hik_probe(int fd)\n', 'static int send_hik_probe(int fd, int port)\n', 1)
    s = s.replace('return send_multicast(fd, HIK_ADDR, HIK_PORT, p, strlen(p));', 'return send_multicast(fd, HIK_ADDR, port, p, strlen(p));', 1)
    s = s.replace('static int send_dahua_probe(int fd)\n', 'static int send_dahua_probe(int fd, int port)\n', 1)
    s = s.replace('return send_multicast(fd, DAHUA_ADDR, DAHUA_PORT, (const char *)frame, 32 + blen);', 'return send_multicast(fd, DAHUA_ADDR, port, (const char *)frame, 32 + blen);', 1)

    old = '''static void usage(const char *p)\n{\n    printf("Usage: %s [-i interface] [-t seconds]\\n", p);\n    printf("  -i interface   interface to discover on (recommended: eth2.1)\\n");\n    printf("  -t seconds     discovery window, 1..60 (default 10)\\n");\n    printf("\\nActive: ONVIF, SSDP/UPnP, Hikvision SADP, Dahua DHIP\\n");\n    printf("Passive: ARP and IPv4 device observation\\n");\n}\n'''
    new = '''static void usage(const char *p)\n{\n    printf("Usage: %s [-i interface] [-t seconds] [-o onvif] [-s ssdp] [-k hik] [-d dahua] [-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1]\\n", p);\n    printf("  -i interface   discovery interface (default br0)\\n");\n    printf("  -t seconds     discovery window, 1..60 (default 10)\\n");\n    printf("  -o/-s/-k/-d    protocol destination ports\\n");\n    printf("  -O/-S/-H/-D    enable ONVIF/SSDP/HIK-SADP/DAHUA-DHIP\\n");\n    printf("  -A              enable ARP/IPv4 passive discovery\\n");\n}\n'''
    if old in s:
        s = s.replace(old, new, 1)
    else:
        raise SystemExit('camdiscover usage block not found')

    main_old = '''    const char *ifname = NULL;\n    int timeout = 10;\n    int opt;\n'''
    main_new = '''    const char *ifname = NULL;\n    int timeout = 10;\n    int onvif_port = ONVIF_PORT, ssdp_port = SSDP_PORT;\n    int hik_port = HIK_PORT, dahua_port = DAHUA_PORT;\n    int enable_onvif = 1, enable_ssdp = 1, enable_hik = 1;\n    int enable_dahua = 1, enable_raw = 1;\n    int opt;\n'''
    if main_old not in s:
        raise SystemExit('camdiscover main declaration not found')
    s = s.replace(main_old, main_new, 1)

    getopt_old = '    while ((opt = getopt(argc, argv, "i:t:h")) != -1) {\n'
    getopt_new = '    while ((opt = getopt(argc, argv, "i:t:o:s:k:d:O:S:H:D:A:h")) != -1) {\n'
    if getopt_old not in s:
        raise SystemExit('camdiscover getopt not found')
    s = s.replace(getopt_old, getopt_new, 1)

    parse_old = '''        if (opt == 'i') {\n            ifname = optarg;\n        } else if (opt == 't') {\n            timeout = atoi(optarg);\n            if (timeout < 1) timeout = 1;\n            if (timeout > 60) timeout = 60;\n        } else {\n'''
    parse_new = '''        if (opt == 'i') {\n            ifname = optarg;\n        } else if (opt == 't') {\n            timeout = atoi(optarg);\n            if (timeout < 1) timeout = 1;\n            if (timeout > 60) timeout = 60;\n        } else if (opt == 'o') onvif_port = atoi(optarg);\n        else if (opt == 's') ssdp_port = atoi(optarg);\n        else if (opt == 'k') hik_port = atoi(optarg);\n        else if (opt == 'd') dahua_port = atoi(optarg);\n        else if (opt == 'O') enable_onvif = atoi(optarg) ? 1 : 0;\n        else if (opt == 'S') enable_ssdp = atoi(optarg) ? 1 : 0;\n        else if (opt == 'H') enable_hik = atoi(optarg) ? 1 : 0;\n        else if (opt == 'D') enable_dahua = atoi(optarg) ? 1 : 0;\n        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;\n        else {\n'''
    if parse_old not in s:
        raise SystemExit('camdiscover option parser block not found')
    s = s.replace(parse_old, parse_new, 1)

    s = s.replace('''    c.ifname = ifname;\n    c.ifindex = get_ifindex(ifname);\n''', '''    c.ifname = ifname;\n    c.ifindex = get_ifindex(ifname);\n    load_self_addresses();\n    load_self_mac(ifname);\n''', 1)
    s = s.replace('''    printf("[camdiscover] interface=%s ifindex=%u timeout=%d\\n",\n           c.ifname, c.ifindex, timeout);\n''', '''    printf("[camdiscover] interface=%s ifindex=%u timeout=%d ports=%d/%d/%d/%d protocols=%d%d%d%d raw=%d\\n",\n           c.ifname, c.ifindex, timeout, onvif_port, ssdp_port, hik_port, dahua_port,\n           enable_onvif, enable_ssdp, enable_hik, enable_dahua, enable_raw);\n''', 1)

    s = s.replace('''    c.fd_onvif = make_udp_receiver(ONVIF_ADDR, ONVIF_PORT, c.ifindex);\n    c.fd_ssdp = make_udp_receiver(SSDP_ADDR, SSDP_PORT, c.ifindex);\n    c.fd_hik = make_udp_receiver(HIK_ADDR, HIK_PORT, c.ifindex);\n    c.fd_dahua = make_udp_receiver(DAHUA_ADDR, DAHUA_PORT, c.ifindex);\n\n    c.fd_raw = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));\n''', '''    if (enable_onvif) c.fd_onvif = make_udp_receiver(ONVIF_ADDR, onvif_port, c.ifindex);\n    if (enable_ssdp) c.fd_ssdp = make_udp_receiver(SSDP_ADDR, ssdp_port, c.ifindex);\n    if (enable_hik) c.fd_hik = make_udp_receiver(HIK_ADDR, hik_port, c.ifindex);\n    if (enable_dahua) c.fd_dahua = make_udp_receiver(DAHUA_ADDR, dahua_port, c.ifindex);\n\n    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;\n''', 1)
    s = s.replace('rc = send_onvif_probe(c.fd_onvif);', 'rc = send_onvif_probe(c.fd_onvif, onvif_port);', 1)
    s = s.replace('rc = send_ssdp_probe(c.fd_ssdp);', 'rc = send_ssdp_probe(c.fd_ssdp, ssdp_port);', 1)
    s = s.replace('rc = send_hik_probe(c.fd_hik);', 'rc = send_hik_probe(c.fd_hik, hik_port);', 1)
    s = s.replace('rc = send_dahua_probe(c.fd_dahua);', 'rc = send_dahua_probe(c.fd_dahua, dahua_port);', 1)
    path.write_text(s)


def patch_user_makefile():
    p = ROOT / 'trunk/user/Makefile'
    s = p.read_text()
    if 'dir_y += lan_autodiscover' not in s:
        s = s.replace('dir_y += camdiscover\ndir_y += netmgr\n', 'dir_y += camdiscover\ndir_y += lan_autodiscover\ndir_y += netmgr\n', 1)
    p.write_text(s)


def patch_init():
    p = ROOT / 'trunk/user/rc/init.c'
    s = p.read_text()
    marker = '\t/* unblock SIGUSR1 */\n'
    insert = '''\t/* Start the configurable LAN discovery watcher. It is self-contained and\n\t * reads its settings from NVRAM, so no board-specific interface is baked in. */\n\tif (access("/usr/bin/lan_autodiscover.sh", X_OK) == 0)\n\t\tsystem("/usr/bin/lan_autodiscover.sh >/dev/null 2>&1 &");\n\n'''
    if 'lan_autodiscover.sh' not in s:
        if marker not in s:
            raise SystemExit('init insertion point not found')
        s = s.replace(marker, insert + marker, 1)
    p.write_text(s)


def create_module():
    d = ROOT / 'trunk/user/lan_autodiscover'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'Makefile').write_text(r'''ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk

all:

romfs:
	$(ROMFSINST) -p +x /usr/bin/lan_autodiscover.sh

clean:

''')
    (d / 'lan_autodiscover.sh').write_text(r'''#!/bin/sh
# Portable LAN link-event watcher for Padavan.
# Configuration is stored in NVRAM by Advanced_LANDiscover_Content.asp.

log() {
    logger -t lan-autodiscover "$*"
}

nv() {
    nvram get "$1" 2>/dev/null
}

cfg() {
    v="$(nv "$1")"
    if [ -n "$v" ]; then echo "$v"; else echo "$2"; fi
}

run_discovery() {
    iface="$1"
    dhcp_enable="$(cfg lan_discovery_dhcp_enable 1)"
    dhcp_timeout="$(cfg lan_discovery_dhcp_timeout 3)"
    discover_enable="$(cfg lan_discovery_discover_enable 1)"
    discover_timeout="$(cfg lan_discovery_timeout 10)"
    onvif="$(cfg lan_discovery_onvif 1)"
    ssdp="$(cfg lan_discovery_ssdp 1)"
    hik="$(cfg lan_discovery_hik 1)"
    dahua="$(cfg lan_discovery_dahua 1)"
    raw="$(cfg lan_discovery_raw 1)"
    onvif_port="$(cfg lan_discovery_onvif_port 3702)"
    ssdp_port="$(cfg lan_discovery_ssdp_port 1900)"
    hik_port="$(cfg lan_discovery_hik_port 37020)"
    dahua_port="$(cfg lan_discovery_dahua_port 37810)"

    log "LAN link event on $iface"
    if [ "$dhcp_enable" = "1" ] && [ -x /usr/bin/dhcpdetect ]; then
        /usr/bin/dhcpdetect -i "$iface" -t "$dhcp_timeout" >/tmp/dhcpdetect_lan.log 2>&1
        rc=$?
        if [ "$rc" = "0" ]; then
            log "DHCP server detected: $(cat /tmp/dhcpdetect_lan.log 2>/dev/null)"
        else
            log "no DHCP server reply"
        fi
    fi

    if [ "$discover_enable" = "1" ] && [ -x /usr/bin/camdiscover ]; then
        log "starting device discovery on $iface"
        /usr/bin/camdiscover -i "$iface" -t "$discover_timeout" \
            -o "$onvif_port" -s "$ssdp_port" -k "$hik_port" -d "$dahua_port" \
            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" \
            >/tmp/camdiscover_lan.log 2>&1
        log "device discovery finished"
        cat /tmp/camdiscover_lan.log | logger -t camdiscover
    fi
}

last_state=-1
while :; do
    enable="$(cfg lan_discovery_enable 1)"
    iface="$(cfg lan_discovery_ifname eth2.1)"

    if [ "$enable" != "1" ]; then
        last_state=0
        sleep 2
        continue
    fi

    if [ ! -e "/sys/class/net/$iface" ]; then
        if [ "$last_state" != "-2" ]; then log "interface $iface not found"; last_state=-2; fi
        sleep 2
        continue
    fi

    if [ -r "/sys/class/net/$iface/carrier" ]; then
        state="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"
    else
        state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"
        [ "$state" = "up" ] && state=1 || state=0
    fi

    if [ "$state" != "$last_state" ]; then
        last_state="$state"
        if [ "$state" = "1" ]; then
            sleep 1
            run_discovery "$iface" &
        else
            log "LAN link down on $iface"
        fi
    fi
    sleep 1
done
''')
    (d / 'README.md').write_text('LAN discovery watcher: monitors a configurable LAN interface, detects DHCP on link-up, then runs camdiscover with NVRAM-configured protocols and ports.\n')


def create_web():
    p = ROOT / 'trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp'
    p.write_text(r'''<!DOCTYPE html>
<html>
<head>
<title><#Web_Title#> - LAN自动发现</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.ico">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css">
<link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css">
<script type="text/javascript" src="/jquery.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script>
var $j = jQuery.noConflict();
<% login_state_hook(); %>
function initial(){ show_banner(1); show_menu(5,7,6); show_footer(); }
function save(){
  if (!login_safe()) return false;
  document.form.action_mode.value=' Apply ';
  document.form.current_page.value='Advanced_LANDiscover_Content.asp';
  document.form.next_page.value='Advanced_LANDiscover_Content.asp';
  document.form.submit();
}
</script>
</head>
<body onLoad="initial();">
<div class="wrapper">
<div class="container-fluid"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" action="apply.cgi" onkeypress="return !checkEnter(event)">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="next_host" value="">
<input type="hidden" name="sid_list" value="">
<input type="hidden" name="action_mode" value="">
<input type="hidden" name="action_script" value="">
<div class="container-fluid"><div class="row-fluid"><div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div>
<div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN 自动发现配置</h2><div class="round_bottom"><div class="row-fluid"><div class="alert alert-info">LAN口产生 Link Up 事件后，先检测 DHCP，再执行设备发现。默认启用。</div>
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
</table>
<div class="row-fluid"><div class="span12"><button type="button" class="btn btn-primary" onClick="save();">保存设置</button></div></div>
</div></div></div></div></div></div>
</form><div id="footer"></div></div>
</body></html>
''')


def main():
    patch_camdiscover()
    patch_user_makefile()
    patch_init()
    create_module()
    create_web()
    print('LAN discovery configuration patch applied')

if __name__ == '__main__':
    main()
