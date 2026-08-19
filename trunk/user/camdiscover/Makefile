obj-y += camdiscover.o

CFLAGS += -Wall -O2

camdiscover-objs := camdiscover.o

$(camdiscover-objs):
	$(CC) $(CFLAGS) -c -o $@ $<

camdiscover: $(camdiscover-objs)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f *.o camdiscover

romfs:
	$(ROMFSINST) /bin/camdiscover
