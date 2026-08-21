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
dhcpdetect=dhcpdetect
OBJS=camdiscover.o
DHCP_OBJS=dhcpdetect.o

all: $(EXEC) $(dhcpdetect)

$(EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@

$(dhcpdetect): $(DHCP_OBJS)
	$(CC) -o $@ $(DHCP_OBJS)
	$(STRIP) $@

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(dhcpdetect)

clean:
	rm -f $(EXEC) $(OBJS) $(dhcpdetect) $(DHCP_OBJS)
