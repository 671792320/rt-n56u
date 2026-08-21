#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Add a dedicated WebUI Level-2 menu entry and matching L3 page.
state = ROOT / 'trunk/user/www/n56u_ribbon_fixed/state.js'
s = state.read_text()
if 'tabtitle[14] = new Array("", "LAN自动发现")' not in s:
    marker = 'if (found_app_mentohust()){\n\tmentohust_array = new Array("","mentohust.asp","mentohust_log.asp");\n\ttablink[13] = (mentohust_array);\n}\n'
    if marker not in s:
        raise SystemExit('state.js mentohust tablink block not found')
    s = s.replace(marker, marker + 'tabtitle[14] = new Array("", "LAN自动发现");\ntablink[14] = new Array("", "Advanced_LANDiscover_Content.asp");\n', 1)

if 'menuL2_title.push("LAN自动发现");' not in s:
    marker = 'if (found_app_mentohust()){\n\tmenuL2_title.push("mentohust");\n} else menuL2_title.push("");\n'
    if marker not in s:
        raise SystemExit('state.js mentohust menu title block not found')
    s = s.replace(marker, marker + '\nmenuL2_title.push("LAN自动发现");\n', 1)

if 'menuL2_link.push("Advanced_LANDiscover_Content.asp");' not in s:
    marker = 'if (found_app_mentohust()){\n\tmenuL2_link.push(mentohust_array[1]);\n} else menuL2_link.push("");\n'
    if marker not in s:
        raise SystemExit('state.js mentohust menu link block not found')
    s = s.replace(marker, marker + '\nmenuL2_link.push("Advanced_LANDiscover_Content.asp");\n', 1)
state.write_text(s)

# Register the LAN discovery NVRAM variables under a dedicated sid_list group.
vp = ROOT / 'trunk/user/httpd/variables.c'
s = vp.read_text()
if 'struct variable variables_LANDiscovery[]' not in s:
    lines = []
    base = [
        'lan_discovery_enable', 'lan_discovery_ifname', 'lan_discovery_dhcp_enable',
        'lan_discovery_dhcp_timeout', 'lan_discovery_discover_enable', 'lan_discovery_timeout',
        'lan_discovery_onvif', 'lan_discovery_onvif_port', 'lan_discovery_ssdp',
        'lan_discovery_ssdp_port', 'lan_discovery_hik', 'lan_discovery_hik_port',
        'lan_discovery_dahua', 'lan_discovery_dahua_port', 'lan_discovery_raw',
        'lan_discovery_udp_count'
    ]
    lines.append('\tstruct variable variables_LANDiscovery[] = {')
    for name in base:
        lines.append(f'\t\t\t{{"{name}", "", NULL, FALSE}},')
    for i in range(64):
        for suffix in ('enable', 'name', 'addr', 'port', 'payload', 'timeout'):
            lines.append(f'\t\t\t{{"lan_discovery_udp_{i}_{suffix}", "", NULL, FALSE}},')
    lines.append('\t\t\t{0,0,0,0}')
    lines.append('\t\t};\n')
    block = '\n'.join(lines)
    marker = '\tstruct svcLink svcLinks[] = {\n'
    if marker not in s:
        raise SystemExit('variables.c svcLinks marker not found')
    s = s.replace(marker, block + marker, 1)

if '{"LANDiscovery",\t\tvariables_LANDiscovery}' not in s:
    marker = '\tstruct svcLink svcLinks[] = {\n'
    if marker not in s:
        raise SystemExit('variables.c svcLinks marker not found for registration')
    s = s.replace(marker, marker + '\t\t{"LANDiscovery",\t\tvariables_LANDiscovery},\n', 1)
vp.write_text(s)
