ifndef ROOTDIR
ROOTDIR=../..
endif
USERDIR=$(ROOTDIR)/user
SHDIR=$(ROOTDIR)/user/shared
INSTALLDIR=$(ROOTDIR)/romfs
include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk
CFLAGS += -Os -s -I. -I$(SHDIR) -I$(SHDIR)/include
# Q7 validation build: keep camdiscover standalone and dependency-free.
# The legacy uClibc toolchain mixes libc and Linux UAPI packet headers.
# Force the compatibility header before camdiscover.c so the kernel packet
# definitions are selected consistently, and explicitly provide struct iphdr.
CFLAGS += -include $(CURDIR)/camdiscover_compat.h -include netinet/ip.h
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
