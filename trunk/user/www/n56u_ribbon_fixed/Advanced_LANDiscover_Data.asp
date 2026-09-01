STATUS|<% nvram_get_x("", "lan_discovery_status_if"); %>|<% nvram_get_x("", "lan_discovery_status_role"); %>|<% nvram_get_x("", "lan_discovery_status_ip"); %>|<% nvram_get_x("", "lan_discovery_status_mac"); %>|<% nvram_get_x("", "lan_discovery_status_link"); %>|<% nvram_get_x("", "lan_discovery_status_dhcp"); %>|<% nvram_get_x("", "lan_discovery_status_state"); %>|<% nvram_get_x("", "lan_discovery_status_count"); %>|<% nvram_get_x("", "lan_discovery_status_last"); %>|<% nvram_get_x("", "lan_access_status"); %>|<% nvram_get_x("", "lan_access_count"); %>
---IFACES---
<% nvram_get_x("", "lan_discovery_interfaces"); %>
---LOG---
<% nvram_get_x("", "lan_discovery_log"); %>
---DEVICES---
<% nvram_get_x("", "lan_discovery_devices"); %>
---CUSTOM---
<% nvram_get_x("", "lan_discovery_custom"); %>
