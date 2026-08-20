#ifndef DROPBEAR_LOCALOPTIONS_H_
#define DROPBEAR_LOCALOPTIONS_H_
/*
                     > > > Read This < < <

default_options.h  documents compile-time options, and provides default values.

Local customisation should be added to localoptions.h which is
used if it exists in the build directory. Options defined there will override 
any options in this file.

Options can also be defined with -DDROPBEAR_XXX=[0,1] in Makefile CFLAGS

IMPORTANT: Some options will require "make clean" after changes */

#define DROPBEAR_DEFPORT "22"
#define DROPBEAR_DEFADDRESS ""
#define DSS_PRIV_FILENAME "/etc/storage/dropbear/dss_host_key"
#define RSA_PRIV_FILENAME "/etc/storage/dropbear/rsa_host_key"
#define ECDSA_PRIV_FILENAME "/etc/storage/dropbear/ecdsa_host_key"
#define ED25519_PRIV_FILENAME "/etc/storage/dropbear/ed25519_host_key"
#define NON_INETD_MODE 1
#define INETD_MODE 0
#define DEBUG_TRACE 0
#define DROPBEAR_X11FWD 1
#define DROPBEAR_CLI_LOCALTCPFWD 1
#define DROPBEAR_CLI_REMOTETCPFWD 1
#define DROPBEAR_SVR_LOCALTCPFWD 1
#define DROPBEAR_SVR_REMOTETCPFWD 1
#define DROPBEAR_SVR_AGENTFWD 1
#define DROPBEAR_CLI_AGENTFWD 1
#define DROPBEAR_CLI_PROXYCMD 1
#define DROPBEAR_CLI_NETCAT 0
#define DROPBEAR_USER_ALGO_LIST 1
#define DROPBEAR_AES128 1
#define DROPBEAR_3DES 1
#define DROPBEAR_AES256 1
#define DROPBEAR_TWOFISH256 0
#define DROPBEAR_TWOFISH128 0
#define DROPBEAR_CHACHA20POLY1305 1
#define DROPBEAR_ENABLE_CTR_MODE 1
#define DROPBEAR_ENABLE_CBC_MODE 0
#define DROPBEAR_ENABLE_GCM_MODE 0
#define DROPBEAR_SHA1_HMAC 1
#define DROPBEAR_SHA2_256_HMAC 1
#define DROPBEAR_SHA1_96_HMAC 0
#define DROPBEAR_RSA 1
#define DROPBEAR_DSS 1
#define DROPBEAR_ECDSA 1
#define DROPBEAR_ED25519 1
#define DROPBEAR_DEFAULT_RSA_SIZE 2048
#define DROPBEAR_DELAY_HOSTKEY 0
#define DROPBEAR_DH_GROUP14_SHA1 1
#define DROPBEAR_DH_GROUP14_SHA256 1
#define DROPBEAR_DH_GROUP16 0
#define DROPBEAR_CURVE25519 0
#define DROPBEAR_ECDH 1
#define DROPBEAR_DH_GROUP1 1
#define DROPBEAR_DH_GROUP1_CLIENTONLY 1
#define DROPBEAR_ZLIB_WINDOW_BITS 15
#define DO_HOST_LOOKUP 0
#define DO_MOTD 0
#define MOTD_FILENAME "/etc/motd"
/* Q7: password authentication is checked against Padavan NVRAM. */
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
#define DROPBEAR_SVR_PUBKEY_OPTIONS 1
#define DROPBEAR_SVR_MULTIUSER 1
#define DROPBEAR_CLI_PASSWORD_AUTH 1
#define DROPBEAR_CLI_PUBKEY_AUTH 1
#define DROPBEAR_DEFAULT_CLI_AUTHKEY ".ssh/id_dropbear"
#define DROPBEAR_USE_PASSWORD_ENV 1
#define DROPBEAR_CLI_ASKPASS_HELPER 0
#define DROPBEAR_CLI_IMMEDIATE_AUTH 0
#define DROPBEAR_USE_PRNGD 0
#define DROPBEAR_PRNGD_SOCKET "/var/run/dropbear-rng"
#define MAX_UNAUTH_PER_IP 3
#define MAX_UNAUTH_CLIENTS 10
#define MAX_AUTH_TRIES 4
#define DROPBEAR_PIDFILE "/var/run/dropbear.pid"
#define XAUTH_COMMAND "/opt/bin/xauth -q"
#define DROPBEAR_SFTPSERVER 1
#define DROPBEAR_PATH_SSH_PROGRAM "/usr/bin/ssh"
#define LOG_COMMANDS 0
#define DEFAULT_RECV_WINDOW 24576
#define RECV_MAX_PAYLOAD_LEN 32768
#define TRANS_MAX_PAYLOAD_LEN 16384
#define DEFAULT_KEEPALIVE 0
#define DEFAULT_KEEPALIVE_LIMIT 3
#define DEFAULT_IDLE_TIMEOUT 0
#define DEFAULT_PATH "/usr/bin:/bin"

/* configure detects no libcrypt in the Q7 uClibc toolchain. The password
 * backend below does not call crypt(); it compares against Padavan NVRAM. */
#ifdef HAVE_CRYPT
#undef HAVE_CRYPT
#endif
#define HAVE_CRYPT 1

#endif /* DROPBEAR_LOCALOPTIONS_H_ */
