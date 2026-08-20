SRC_NAME=dropbear-202X.XX

ifeq ($(CONFIG_FIRMWARE_INCLUDE_SFTP),y)
COPT=-DSFTPSERVER_PATH=\"/usr/libexec/sftp-server\"
else
COPT=-DSFTPSERVER_PATH=\"/opt/libexec/sftp-server\"
endif
ifneq ($(CONFIG_FIRMWARE_INCLUDE_DROPBEAR_FAST_CODE),y)
COPT+=-DDROPBEAR_SMALL_CODE
endif
CFLAGS+=$(COPT) -ffunction-sections -fdata-sections
LDFLAGS += -Wl,--gc-sections

# Dropbear is configured after the in-tree target libraries have been built.
# Use Padavan's staged zlib explicitly.  --with-zlib is handled by Dropbear's
# configure.ac and avoids relying on configure's generic library search.
DROPBEAR_STAGE=$(ROOTDIR)/stage
DROPBEAR_ZLIB=$(DROPBEAR_STAGE)

all: config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME) PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" MULTI=1

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		make configure && touch config_done; \
	fi )

configure:
	( cd $(SRC_NAME) ; \
	autoreconf -v; \
	CPPFLAGS="-I$(DROPBEAR_STAGE)/include" \
	LDFLAGS="-L$(DROPBEAR_STAGE)/lib -Wl,-rpath-link,$(DROPBEAR_STAGE)/lib" \
	./configure \
		--prefix=/usr \
		--disable-lastlog \
		--disable-utmp \
		--disable-utmpx \
		--disable-wtmp \
		--disable-wtmpx \
		--disable-loginfunc \
		--disable-pututline \
		--disable-pututxline \
		--disable-wtmpx \
		--enable-zlib \
		--with-zlib=$(DROPBEAR_ZLIB) \
		--enable-bundled-libtom \
		--host=$(HOST_TARGET) \
		--build=$(HOST_BUILD) ; \
	)

clean:
	if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME) distclean ; \
	fi ; \
	rm -f dropbearmulti
	rm -f config_done

romfs:
	cp $(SRC_NAME)/dropbearmulti .
	$(STRIP) dropbearmulti
	$(ROMFSINST) /usr/bin/dropbearmulti
	$(ROMFSINST) -p +x /usr/bin/sshd.sh
	$(ROMFSINST) -s dropbearmulti /usr/bin/ssh
	$(ROMFSINST) -s dropbearmulti /usr/bin/scp
	$(ROMFSINST) -s dropbearmulti /usr/bin/dropbearkey
	$(ROMFSINST) -s dropbearmulti /usr/bin/dropbearconvert
	$(ROMFSINST) -s /usr/bin/dropbearmulti /usr/sbin/dropbear
