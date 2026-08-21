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
dhcpdetect=dhcpdetect
udpdiscover=udpdiscover
OBJS=camdiscover.o
DHCP_OBJS=dhcpdetect.o
UDP_OBJS=udpdiscover.o

all: $(EXEC) $(dhcpdetect) $(udpdiscover)

$(EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@

$(dhcpdetect): $(DHCP_OBJS)
	$(CC) -o $@ $(DHCP_OBJS)
	$(STRIP) $@

$(udpdiscover): $(UDP_OBJS)
	$(CC) -o $@ $(UDP_OBJS)
	$(STRIP) $@

%.o: %.c
	$(CC) -c $< $(CFLAGS)

romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
	$(ROMFSINST) /usr/bin/$(dhcpdetect)
	$(ROMFSINST) /usr/bin/$(udpdiscover)

clean:
	rm -f $(EXEC) $(OBJS) $(dhcpdetect) $(DHCP_OBJS) $(udpdiscover) $(UDP_OBJS)
