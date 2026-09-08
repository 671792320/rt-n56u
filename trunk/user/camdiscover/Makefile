ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
CFLAGS += -Os -s -I. -I$(SHDIR) -I$(SHDIR)/include
# Q7 validation build：兼容旧版uClibc与Linux UAPI报文头。
# 主动ARP和网络健康工具只依赖Linux内核提供的AF_PACKET接口。
CFLAGS += -include $(CURDIR)/camdiscover_compat.h -include netinet/ip.h

EXEC=camdiscover
DHCP_EXEC=dhcpdetect
ARP_EXEC=arpscan
HEALTH_EXEC=lanhealth
OBJS=camdiscover.o camdiscover_debug.o
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

camdiscover.o: camdiscover.c
	$(CC) -Drecvfrom=camdiscover_recvfrom -c $< $(CFLAGS)

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(DHCP_EXEC)
	$(ROMFSINST) /usr/bin/$(ARP_EXEC)
	$(ROMFSINST) /usr/bin/$(HEALTH_EXEC)

clean:
	rm -f $(EXEC) $(OBJS) $(DHCP_EXEC) $(DHCP_OBJS) $(ARP_EXEC) $(ARP_OBJS) $(HEALTH_EXEC) $(HEALTH_OBJS)
