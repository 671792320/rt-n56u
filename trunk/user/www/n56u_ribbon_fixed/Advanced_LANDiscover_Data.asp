STATUS|<% nvram_get_x("", "lan_discovery_status_if"); %>|<% nvram_get_x("", "lan_discovery_status_role"); %>|<% nvram_get_x("", "lan_discovery_status_ip"); %>|<% nvram_get_x("", "lan_discovery_status_mac"); %>|<% nvram_get_x("", "lan_discovery_status_link"); %>|<% nvram_get_x("", "lan_discovery_status_dhcp"); %>|<% nvram_get_x("", "lan_discovery_status_state"); %>|<% nvram_get_x("", "lan_discovery_status_count"); %>|<% nvram_get_x("", "lan_discovery_status_last"); %>|<% nvram_get_x("", "lan_discovery_status_health"); %>|<% nvram_get_x("", "lan_discovery_status_broadcast"); %>|<% nvram_get_x("", "lan_discovery_status_loop"); %>|<% nvram_get_x("", "lan_discovery_status_total"); %>
---IFACES---
<% nvram_get_x("", "lan_discovery_interfaces"); %>
---LOG---
<% nvram_get_x("", "lan_discovery_log"); %>
---DEVICES---
<% lan_discovery_devices(); %>
---TARGETS---
<% nvram_get_x("", "lan_discovery_status_targets"); %>
---CUSTOM---
<% nvram_get_x("", "lan_discovery_custom"); %>
