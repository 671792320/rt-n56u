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
