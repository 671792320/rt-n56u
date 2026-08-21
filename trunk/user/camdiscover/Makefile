ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
# Legacy Padavan uClibc exposes overlapping libc/kernel networking structs.
# Suppress the kernel UAPI copies so net/if.h and netpacket/packet.h remain
# the single definitions used by camdiscover.c.
CFLAGS += -D__UAPI_DEF_IF_IFMAP=0 -D__UAPI_DEF_IF_IFREQ=0 -D__UAPI_DEF_IF_IFCONF=0 -D__UAPI_DEF_IF_NET_DEVICE_FLAGS=0 -D__UAPI_DEF_SOCKADDR_LL=0 -D__UAPI_DEF_PACKET_MREQ=0
CFLAGS += -Os -s -I. -I$(SHDIR) -I$(SHDIR)/include
# Q7 validation build: keep camdiscover standalone and dependency-free.
EXEC=camdiscover
OBJS=camdiscover.o
all: $(EXEC)
$(EXEC): $(OBJS)
	$(CC) -o $@ $(OBJS)
	$(STRIP) $@
%.o: %.c
	$(CC) -c $< $(CFLAGS)
romfs:
	$(ROMFSINST) /usr/bin/$(EXEC)
clean:
	rm -f $(EXEC) $(OBJS)
