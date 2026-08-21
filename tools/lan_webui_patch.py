#!/usr/bin/env python3
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
PAGE=ROOT/'trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp'
STATE=ROOT/'trunk/user/www/n56u_ribbon_fixed/state.js'
CAM=ROOT/'trunk/user/camdiscover/camdiscover.c'
LAN=ROOT/'trunk/user/lan_autodiscover/lan_autodiscover.sh'
VARS=ROOT/'trunk/user/httpd/variables.c'
MAX_CUSTOM=64

def patch_state():
    s=STATE.read_text()
    if 'lan_discovery_menu_index = -1;' not in s:
        anchor='var menu_code="", menu1_code="", menu2_code="", tab_code="", footer_code;'
        if anchor not in s: raise SystemExit('state.js menu declaration not found')
        inject='''var menu_code="", menu1_code="", menu2_code="", tab_code="", footer_code;\n\n/* Q7 LAN discovery: dedicated first-level sidebar item. */\nvar lan_discovery_menu_index = -1;\n'''
        s=s.replace(anchor,inject,1)
    # The arrays are declared later, so registration must run after menuL1 arrays exist.
    if 'Advanced_LANDiscover_Content.asp' not in s:
        anchor='menuL1_icon = new Array("", "icon-home", "icon-hdd", "icon-retweet", "icon-globe", "icon-tasks", "icon-random", "icon-wrench");'
        if anchor not in s: raise SystemExit('state.js menuL1 icon array not found')
        inject='''menuL1_icon = new Array("", "icon-home", "icon-hdd", "icon-retweet", "icon-globe", "icon-tasks", "icon-random", "icon-wrench");\nif (menuL1_link.indexOf("Advanced_LANDiscover_Content.asp") < 0) {\n    lan_discovery_menu_index = menuL1_title.length;\n    menuL1_title.push("LAN自动发现");\n    menuL1_link.push("Advanced_LANDiscover_Content.asp");\n    menuL1_icon.push("icon-search");\n} else {\n    lan_discovery_menu_index = menuL1_link.indexOf("Advanced_LANDiscover_Content.asp");\n}\n'''
        s=s.replace(anchor,inject,1)
    STATE.write_text(s)

def patch_vars():
    s=VARS.read_text()
    if 'struct variable variables_LANDiscovery[]' in s: return
    names=['lan_discovery_enable','lan_discovery_ifname','lan_discovery_dhcp_enable','lan_discovery_dhcp_timeout','lan_discovery_discover_enable','lan_discovery_timeout','lan_discovery_onvif','lan_discovery_onvif_port','lan_discovery_ssdp','lan_discovery_ssdp_port','lan_discovery_hik','lan_discovery_hik_port','lan_discovery_dahua','lan_discovery_dahua_port','lan_discovery_raw','lan_discovery_custom_count']
    out=['\tstruct variable variables_LANDiscovery[] = {']
    for n in names: out.append(f'\t\t\t{{"{n}", "", NULL, FALSE}},')
    for i in range(1,MAX_CUSTOM+1):
        for k in ('enable','name','port','payload'):
            out.append(f'\t\t\t{{"lan_discovery_custom_{i}_{k}", "", NULL, FALSE}},')
    out.append('\t\t\t{0,0,0,0}\n\t\t};\n')
    block='\n'.join(out)
    marker='\tstruct svcLink svcLinks[] = {\n'
    if marker not in s: raise SystemExit('variables.c svcLinks marker not found')
    s=s.replace(marker,block+marker+'\t\t{"LANDiscovery",\t\tvariables_LANDiscovery},\n',1)
    VARS.write_text(s)

def patch_camdiscover():
    s=CAM.read_text()
    s=s.replace('#define MAX_CUSTOM      6','#define MAX_CUSTOM      64')
    if 'CUSTOM UDP discovery' not in s:
        insert=r'''/* CUSTOM UDP discovery: configurable broadcast probes. */
static int make_custom_receiver(const char *ifname, int port)
{
    int fd, yes=1; struct sockaddr_in a;
    fd=socket(AF_INET,SOCK_DGRAM,0); if(fd<0)return -1;
    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&yes,sizeof(yes));
#ifdef SO_BINDTODEVICE
    if(ifname&&*ifname) setsockopt(fd,SOL_SOCKET,SO_BINDTODEVICE,ifname,strlen(ifname)+1);
#endif
    memset(&a,0,sizeof(a)); a.sin_family=AF_INET; a.sin_port=htons((unsigned short)port); a.sin_addr.s_addr=htonl(INADDR_ANY);
    if(bind(fd,(struct sockaddr*)&a,sizeof(a))<0){close(fd);return -1;} return fd;
}
static int send_custom_probe(int fd,int port,const char *payload)
{
    struct sockaddr_in d; size_t n=payload?strlen(payload):0;
    memset(&d,0,sizeof(d)); d.sin_family=AF_INET; d.sin_port=htons((unsigned short)port); d.sin_addr.s_addr=htonl(INADDR_BROADCAST);
    return sendto(fd,payload?payload:"",n,0,(struct sockaddr*)&d,sizeof(d))==(ssize_t)n?0:-1;
}
static void handle_custom(int fd,const char *name,int port)
{
    unsigned char x[BUF_SIZE]; struct sockaddr_in sa; socklen_t sl=sizeof(sa); ssize_t n; char ip[INET_ADDRSTRLEN],info[256];
    n=recvfrom(fd,x,sizeof(x),0,(struct sockaddr*)&sa,&sl); if(n<=0)return;
    inet_ntop(AF_INET,&sa.sin_addr,ip,sizeof(ip));
    snprintf(info,sizeof(info),"UDP port=%d response_len=%ld",port,(long)n);
    print_text_device(name&&*name?name:"CUSTOM-UDP",ip,info);
}
static int load_custom_file(const char *path,struct discover_ctx *c)
{
    FILE *f; char line[1024];
    if(!path||!*path)return 0; f=fopen(path,"r"); if(!f)return 0;
    while(c->custom_count<MAX_CUSTOM&&fgets(line,sizeof(line),f)){
        char *p1,*p2,*nl; int port;
        nl=strchr(line,'\n'); if(nl)*nl=0; p1=strchr(line,'|'); if(!p1)continue; *p1++=0; p2=strchr(p1,'|'); if(!p2)continue; *p2++=0;
        port=atoi(p1); if(port<1||port>65535||!*line)continue;
        c->custom[c->custom_count].port=port;
        strncpy(c->custom[c->custom_count].name,line,sizeof(c->custom[c->custom_count].name)-1);
        c->custom[c->custom_count].name[sizeof(c->custom[c->custom_count].name)-1]=0;
        c->custom[c->custom_count].fd=make_custom_receiver(c->ifname,port);
        if(c->custom[c->custom_count].fd>=0){send_custom_probe(c->custom[c->custom_count].fd,port,p2);c->custom_count++;}
    }
    fclose(f); return c->custom_count;
}
'''
        anchor='static int make_udp_receiver(const char *group, int port, unsigned int ifindex)\n'
        if anchor not in s: raise SystemExit('camdiscover UDP receiver anchor not found')
        s=s.replace(anchor,insert+'\n'+anchor,1)
        s=s.replace('''struct discover_ctx {\n    int fd_onvif;\n''','''struct custom_probe { int fd; int port; char name[64]; };\n\nstruct discover_ctx {\n    int fd_onvif;\n''',1)
        s=s.replace('''    int fd_raw;\n    const char *ifname;\n''','''    int fd_raw;\n    struct custom_probe custom[MAX_CUSTOM];\n    int custom_count;\n    const char *ifname;\n''',1)
    if '[-F custom_file]' not in s:
        s=s.replace('[-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1]', '[-O 0|1] [-S 0|1] [-H 0|1] [-D 0|1] [-A 0|1] [-F custom_file]',1)
        s=s.replace('''    printf("  -A              enable ARP/IPv4 passive discovery\\n");\n}''','''    printf("  -A              enable ARP/IPv4 passive discovery\\n");\n    printf("  -F file         custom UDP discovery file: name|port|payload\\n");\n}''',1)
    s=s.replace('''    int enable_dahua = 1, enable_raw = 1;\n    int opt;''','''    int enable_dahua = 1, enable_raw = 1;\n    const char *custom_file = NULL;\n    int opt;''',1)
    s=s.replace('"i:t:o:s:k:d:O:S:H:D:A:h"','"i:t:o:s:k:d:O:S:H:D:A:F:h"',1)
    s=s.replace("        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;","        else if (opt == 'A') enable_raw = atoi(optarg) ? 1 : 0;\n        else if (opt == 'F') custom_file = optarg;",1)
    if 'load_custom_file(custom_file, &c)' not in s:
        s=s.replace('''    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;''','''    c.fd_raw = enable_raw ? socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL)) : -1;\n    memset(c.custom, 0, sizeof(c.custom));\n    { int _i; for(_i=0;_i<MAX_CUSTOM;_i++) c.custom[_i].fd=-1; }\n    if (custom_file) load_custom_file(custom_file, &c);''',1)
    if 'FD_SET(c.custom[_ci].fd' not in s:
        s=s.replace('''        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &rfds); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }''','''        if (c.fd_raw >= 0) { FD_SET(c.fd_raw, &rfds); if (c.fd_raw > maxfd) maxfd = c.fd_raw; }\n        { int _ci; for(_ci=0;_ci<c.custom_count;_ci++) if(c.custom[_ci].fd>=0){FD_SET(c.custom[_ci].fd,&rfds);if(c.custom[_ci].fd>maxfd)maxfd=c.custom[_ci].fd;} }''',1)
        s=s.replace('''        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &rfds)) handle_raw(c.fd_raw);''','''        if (c.fd_raw >= 0 && FD_ISSET(c.fd_raw, &rfds)) handle_raw(c.fd_raw);\n        { int _ci; for(_ci=0;_ci<c.custom_count;_ci++) if(c.custom[_ci].fd>=0&&FD_ISSET(c.custom[_ci].fd,&rfds)) handle_custom(c.custom[_ci].fd,c.custom[_ci].name,c.custom[_ci].port); }''',1)
        s=s.replace('''    if (c.fd_raw >= 0) close(c.fd_raw);\n    return 0;''','''    if (c.fd_raw >= 0) close(c.fd_raw);\n    { int _ci; for(_ci=0;_ci<c.custom_count;_ci++) if(c.custom[_ci].fd>=0) close(c.custom[_ci].fd); }\n    return 0;''',1)
    CAM.write_text(s)

def patch_lan_script():
    s=LAN.read_text()
    s=s.replace('while [ "$i" -le 6 ]; do','while [ "$i" -le 64 ]; do')
    s=s.replace('lan_discovery_custom_${i}_payload','lan_discovery_custom_${i}_payload')
    if 'custom_file=' not in s:
        needle='        log "starting device discovery on $iface"\n'
        inject='''        custom_file="/tmp/lan_discovery_custom.$$"\n        : > "$custom_file"\n        i=1\n        while [ "$i" -le 64 ]; do\n            ce="$(cfg lan_discovery_custom_${i}_enable 0)"\n            cn="$(cfg lan_discovery_custom_${i}_name "")"\n            cp="$(cfg lan_discovery_custom_${i}_port "")"\n            cx="$(cfg lan_discovery_custom_${i}_payload "")"\n            if [ "$ce" = "1" ] && [ -n "$cn" ] && [ -n "$cp" ]; then\n                printf '%s|%s|%s\\n' "$cn" "$cp" "$cx" >> "$custom_file"\n            fi\n            i=$((i + 1))\n        done\n'''
        if needle not in s: raise SystemExit('lan script discovery marker not found')
        s=s.replace(needle,inject+needle,1)
        old='''            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" \\\n            >/tmp/camdiscover_lan.log 2>&1'''
        new='''            -O "$onvif" -S "$ssdp" -H "$hik" -D "$dahua" -A "$raw" -F "$custom_file" \\\n            >/tmp/camdiscover_lan.log 2>&1'''
        if old not in s: raise SystemExit('lan script camdiscover command not found')
        s=s.replace(old,new,1)
        s=s.replace('''        log "device discovery finished"''','''        rm -f "$custom_file"\n        log "device discovery finished"''',1)
    LAN.write_text(s)

def patch_page():
    rows=[]
    for i in range(1,MAX_CUSTOM+1):
        rows.append(f'''<tr id="lan_custom_row_{i}"><td><select name="lan_discovery_custom_{i}_enable"><option value="1" <% nvram_match_x("", "lan_discovery_custom_{i}_enable", "1", "selected"); %>>是</option><option value="0" <% nvram_match_x("", "lan_discovery_custom_{i}_enable", "0", "selected"); %>>否</option></select></td><td><input name="lan_discovery_custom_{i}_name" class="span3" value="<% nvram_get_x("", "lan_discovery_custom_{i}_name"); %>"></td><td><input name="lan_discovery_custom_{i}_port" class="span2" value="<% nvram_get_x("", "lan_discovery_custom_{i}_port"); %>"></td><td><input name="lan_discovery_custom_{i}_payload" class="span5" value="<% nvram_get_x("", "lan_discovery_custom_{i}_payload"); %>"></td><td><button type="button" class="btn btn-mini" onclick="lanCustomRemoveRow({i});">−</button></td></tr>''')
    page=f'''<!DOCTYPE html><html><head><title><#Web_Title#> - LAN自动发现</title><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><meta http-equiv="Pragma" content="no-cache"><meta http-equiv="Expires" content="-1"><link rel="shortcut icon" href="images/favicon.ico"><link rel="stylesheet" type="text/css" href="/bootstrap/css/bootstrap.min.css"><link rel="stylesheet" type="text/css" href="/bootstrap/css/main.css"><script src="/jquery.js"></script><script src="/state.js"></script><script src="/general.js"></script><script src="/popup.js"></script><script>\nfunction initial(){{show_banner(1);var m=(typeof lan_discovery_menu_index=='number'&&lan_discovery_menu_index>0)?lan_discovery_menu_index:5;show_menu(m,0,0);show_footer();lanCustomInit();}}\nfunction save(){{if(typeof login_safe==='function'&&!login_safe())return false;document.form.action_mode.value=' Apply ';document.form.current_page.value='Advanced_LANDiscover_Content.asp';document.form.next_page.value='Advanced_LANDiscover_Content.asp';document.form.submit();}}\nvar lanCustomCount=1;function lanCustomInit(){{var n=1;for(var i=1;i<={MAX_CUSTOM};i++){{var a=document.form['lan_discovery_custom_'+i+'_name'],b=document.form['lan_discovery_custom_'+i+'_port'],e=document.form['lan_discovery_custom_'+i+'_enable'];if((a&&a.value)||(b&&b.value)||(e&&e.value=='1'))n=i;}}lanCustomCount=n;lanCustomSync();}}\nfunction lanCustomSync(){{for(var i=1;i<={MAX_CUSTOM};i++){{var r=document.getElementById('lan_custom_row_'+i);if(r)r.style.display=(i<=lanCustomCount)?'':'none';}}document.getElementById('lan_custom_count').innerHTML=lanCustomCount+'/{MAX_CUSTOM}';}}\nfunction lanCustomAdd(){{if(lanCustomCount<{MAX_CUSTOM}){{lanCustomCount++;lanCustomSync();}}}}\nfunction lanCustomRemoveRow(i){{if(i>lanCustomCount)return;if(i<lanCustomCount){{for(var j=i;j<lanCustomCount;j++){{['enable','name','port','payload'].forEach(function(k){{var a=document.form['lan_discovery_custom_'+j+'_'+k],b=document.form['lan_discovery_custom_'+(j+1)+'_'+k];if(a&&b)a.value=b.value;}});}}}}var a=document.form['lan_discovery_custom_'+lanCustomCount+'_enable'];if(a)a.value='0';['name','port','payload'].forEach(function(k){{var b=document.form['lan_discovery_custom_'+lanCustomCount+'_'+k];if(b)b.value='';}});if(lanCustomCount>1)lanCustomCount--;lanCustomSync();}}\nfunction lanCustomRemove(){{lanCustomRemoveRow(lanCustomCount);}}\n</script></head><body onload="initial();"><div class="wrapper"><div class="container-fluid"><div class="row-fluid"><div class="span3"><center><div id="logo"></div></center></div><div class="span9"><div id="TopBanner"></div></div></div></div><div id="Loading" class="popup_bg"></div><iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe><form method="post" name="form" action="start_apply.htm" target="hidden_frame"><input type="hidden" name="current_page" value="Advanced_LANDiscover_Content.asp"><input type="hidden" name="next_page" value="Advanced_LANDiscover_Content.asp"><input type="hidden" name="sid_list" value="LANDiscovery;"><input type="hidden" name="action_mode" value=""><div class="container-fluid"><div class="row-fluid"><div class="span3"><div class="well sidebar-nav side_nav" style="padding:0"><ul id="mainMenu" class="clearfix"></ul><ul class="clearfix"><li><div id="subMenu" class="accordion"></div></li></ul></div></div><div class="span9"><div class="box well grad_colour_dark_blue"><h2 class="box_head round_top">LAN 自动发现</h2><div class="round_bottom"><div class="alert alert-info">LAN口 Link Up 后先检测 DHCP，再执行设备发现。自身 IP/MAC 自动过滤。自定义 UDP 支持动态增加。</div><table width="100%" class="table"><tr><td>LAN自动发现</td><td><select name="lan_discovery_enable"><option value="1" <% nvram_match_x("", "lan_discovery_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_enable", "0", "selected"); %>>禁用</option></select></td></tr><tr><td>检测接口</td><td><input name="lan_discovery_ifname" value="<% nvram_get_x("", "lan_discovery_ifname"); %>"></td></tr><tr><td>DHCP检测</td><td><select name="lan_discovery_dhcp_enable"><option value="1" <% nvram_match_x("", "lan_discovery_dhcp_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dhcp_enable", "0", "selected"); %>>禁用</option></select> 超时 <input name="lan_discovery_dhcp_timeout" value="<% nvram_get_x("", "lan_discovery_dhcp_timeout"); %>" size="3"> 秒</td></tr><tr><td>设备发现</td><td><select name="lan_discovery_discover_enable"><option value="1" <% nvram_match_x("", "lan_discovery_discover_enable", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_discover_enable", "0", "selected"); %>>禁用</option></select> 超时 <input name="lan_discovery_timeout" value="<% nvram_get_x("", "lan_discovery_timeout"); %>" size="3"> 秒</td></tr></table><h4>内置协议</h4><table width="100%" class="table"><tr><td>ONVIF</td><td><select name="lan_discovery_onvif"><option value="1" <% nvram_match_x("", "lan_discovery_onvif", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_onvif", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_onvif_port" value="<% nvram_get_x("", "lan_discovery_onvif_port"); %>"></td></tr><tr><td>SSDP</td><td><select name="lan_discovery_ssdp"><option value="1" <% nvram_match_x("", "lan_discovery_ssdp", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_ssdp", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_ssdp_port" value="<% nvram_get_x("", "lan_discovery_ssdp_port"); %>"></td></tr><tr><td>HIK-SADP</td><td><select name="lan_discovery_hik"><option value="1" <% nvram_match_x("", "lan_discovery_hik", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_hik", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_hik_port" value="<% nvram_get_x("", "lan_discovery_hik_port"); %>"></td></tr><tr><td>DAHUA-DHIP</td><td><select name="lan_discovery_dahua"><option value="1" <% nvram_match_x("", "lan_discovery_dahua", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_dahua", "0", "selected"); %>>禁用</option></select> 端口 <input name="lan_discovery_dahua_port" value="<% nvram_get_x("", "lan_discovery_dahua_port"); %>"></td></tr><tr><td>ARP/IP</td><td><select name="lan_discovery_raw"><option value="1" <% nvram_match_x("", "lan_discovery_raw", "1", "selected"); %>>启用</option><option value="0" <% nvram_match_x("", "lan_discovery_raw", "0", "selected"); %>>禁用</option></select></td></tr></table><h4>自定义 UDP</h4><div class="alert alert-warning">默认只显示一条。使用 + 新增、− 删除。内部最多保留 {MAX_CUSTOM} 条，页面没有 6 条限制。名称、端口、发送内容均可自定义。</div><div><button type="button" class="btn btn-success" onclick="lanCustomAdd();">＋ 新增</button> <button type="button" class="btn" onclick="lanCustomRemove();">− 删除</button> <span id="lan_custom_count">1/{MAX_CUSTOM}</span></div><table width="100%" class="table table-condensed"><tr><th>启用</th><th>名称</th><th>UDP端口</th><th>发送内容</th><th></th></tr>{''.join(rows)}</table><button type="button" class="btn btn-primary" onclick="save();">保存设置</button></div></div></div></div></div></div></form><div id="footer"></div></div></body></html>'''
    PAGE.write_text(page)

def main():
    patch_state();patch_vars();patch_camdiscover();patch_lan_script();patch_page()
if __name__=='__main__': main()
