ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
CFLAGS += -Os -s -I. -I$(SHDIR) -I$(SHDIR)/include
# Q7 validation build: keep discovery tools standalone and dependency-free.
# The legacy uClibc toolchain mixes libc and Linux UAPI packet headers.
# Force the compatibility header before camdiscover.c so kernel packet
# definitions are selected consistently, and provide struct iphdr.
CFLAGS += -include $(CURDIR)/camdiscover_compat.h -include netinet/ip.h

EXEC=camdiscover
DHCP_EXEC=dhcpdetect
ARP_EXEC=arpscan
OBJS=camdiscover.o camdiscover_debug.o
DHCP_OBJS=dhcpdetect.o
ARP_OBJS=arpscan.o

all: $(EXEC) $(DHCP_EXEC) $(ARP_EXEC)

$(EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@

$(DHCP_EXEC): $(DHCP_OBJS)
	$(CC) -o $@ $(DHCP_OBJS)
	$(STRIP) $@

$(ARP_EXEC): $(ARP_OBJS)
	$(CC) -o $@ $(ARP_OBJS)
	$(STRIP) $@

camdiscover.o: camdiscover.c
	$(CC) -Drecvfrom=camdiscover_recvfrom -c $< $(CFLAGS)

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(DHCP_EXEC)
	$(ROMFSINST) /usr/bin/$(ARP_EXEC)

clean:
	rm -f $(EXEC) $(OBJS) $(DHCP_EXEC) $(DHCP_OBJS) $(ARP_EXEC) $(ARP_OBJS)
