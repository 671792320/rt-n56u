obj-y += netmgr.o
CFLAGS += -Wall -O2
netmgr: netmgr.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
clean:
	rm -f *.o netmgr
romfs:
	$(ROMFSINST) /bin/netmgr
