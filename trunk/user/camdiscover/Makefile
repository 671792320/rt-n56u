ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
CFLAGS += -Os -s -I. -I$(SHDIR) -I$(SHDIR)/include
CFLAGS += -include $(CURDIR)/camdiscover_compat.h -include netinet/ip.h

EXEC=camdiscover
DHCP_EXEC=dhcpdetect
ARP_EXEC=arpscan
HEALTH_EXEC=lanhealth
OBJS=camdiscover_q7_v3.o
DHCP_OBJS=dhcpdetect.o
ARP_OBJS=arpscan.o
HEALTH_OBJS=lanhealth.o

all: $(EXEC) $(DHCP_EXEC) $(ARP_EXEC) $(HEALTH_EXEC)

$(EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@

$(DHCP_EXEC): $(DHCP_OBJS)
	$(CC) -o $@ $(DHCP_OBJS)
	$(STRIP) $@

$(ARP_EXEC): $(ARP_OBJS)
	$(CC) -o $@ $(ARP_OBJS)
	$(STRIP) $@

$(HEALTH_EXEC): $(HEALTH_OBJS)
	$(CC) -o $@ $(HEALTH_OBJS)
	$(STRIP) $@

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(DHCP_EXEC)
	$(ROMFSINST) /usr/bin/$(ARP_EXEC)
	$(ROMFSINST) /usr/bin/$(HEALTH_EXEC)

clean:
	rm -f $(EXEC) $(OBJS) $(DHCP_EXEC) $(DHCP_OBJS) $(ARP_EXEC) $(ARP_OBJS) $(HEALTH_EXEC) $(HEALTH_OBJS) camdiscover_q7_final.o camdiscover_q7_v2.o
