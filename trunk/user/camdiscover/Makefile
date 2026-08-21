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
RAW_EXEC=camdiscover.raw
dhcpdetect=dhcpdetect
lanwatch=lanwatch
OBJS=camdiscover.o
FILTER_OBJS=camdiscover_filter.o
DHCP_OBJS=dhcpdetect.o
LANWATCH_OBJS=lanwatch.o

all: $(EXEC) $(RAW_EXEC) $(dhcpdetect) $(lanwatch)

$(RAW_EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@

$(EXEC): $(FILTER_OBJS)
	$(CC) -o $@ $(FILTER_OBJS)
	$(STRIP) $@

$(dhcpdetect): $(DHCP_OBJS)
	$(CC) -o $@ $(DHCP_OBJS)
	$(STRIP) $@

$(lanwatch): $(LANWATCH_OBJS)
	$(CC) -o $@ $(LANWATCH_OBJS)
	$(STRIP) $@

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(RAW_EXEC)
	$(ROMFSINST) /usr/bin/$(dhcpdetect)
	$(ROMFSINST) /usr/bin/$(lanwatch)
	$(ROMFSINST) /usr/bin/lanwatch_start.sh

clean:
	rm -f $(EXEC) $(RAW_EXEC) $(OBJS) $(FILTER_OBJS) $(dhcpdetect) $(DHCP_OBJS) $(lanwatch) $(LANWATCH_OBJS)
