ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
include $(ROOTDIR)/versions.inc

all:

romfs:
	mkdir -p $(INSTALLDIR)/etc
	printf '%s\n' '3.4.3.9-$(FIRMWARE_BUILDS_VER)' > $(INSTALLDIR)/etc/q7_firmware_version
	$(ROMFSINST) -p +x /usr/bin/lan_autodiscover.sh
	$(ROMFSINST) -p +x /usr/bin/lan_discovery_supervisor.sh
	$(ROMFSINST) -p +x /usr/bin/lan_takeover.sh
	$(ROMFSINST) -p +x /usr/bin/lan_snat.sh
	$(ROMFSINST) -p +x /usr/bin/lan_network_manager.sh
	$(ROMFSINST) -p +x /usr/bin/lan_device_state.sh

clean:
