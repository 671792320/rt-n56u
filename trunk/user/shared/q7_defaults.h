/*
 * Q7专用共享默认参数头文件。
 * 使用独立文件名，避免与构建过程中可能出现的 defaults.h 同名文件冲突。
 */
#ifndef _q7_defaults_h_
#define _q7_defaults_h_

#include <ralink_board.h>

#define SYS_SHELL		"/bin/sh"
#define SYS_EXEC_PATH		"/usr/sbin:/usr/bin:/sbin:/bin"
#define SYS_EXEC_PATH_OPT	"/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
#define SYS_HOME_PATH_ROOT	"/home/admin"

#define SYS_USER_ROOT		"admin"
#define SYS_GROUP_ROOT		"root"
#define SYS_USER_NOBODY		"nobody"
#define SYS_GROUP_NOGROUP	"nogroup"

#define DEF_LAN_ADDR		"192.168.2.1"
#define DEF_LAN_DHCP_BEG	"192.168.2.100"
#define DEF_LAN_DHCP_END	"192.168.2.244"
#define DEF_LAN_MASK		"255.255.255.0"

#define DEF_WLAN_2G_CC		"CN"
#define DEF_WLAN_5G_CC		"US"

#if defined(BOARD_ZTE_Q7)
/* Q7使用设备LAN MAC最后四位生成默认无线名称。 */
#define DEF_WLAN_2G_SSID	"@Seetong-IPCtest-utp2_%s"
#define DEF_WLAN_2G_PSK		"88888888"
#else
#define DEF_WLAN_2G_SSID	BOARD_PID "_%s"
#define DEF_WLAN_2G_PSK		"1234567890"
#endif

#define DEF_WLAN_5G_SSID	BOARD_PID "_5G_%s"
#define DEF_WLAN_2G_GSSID	BOARD_PID "_GUEST_%s"
#define DEF_WLAN_5G_GSSID	BOARD_PID "_GUEST_5G_%s"
#define DEF_WLAN_5G_PSK		"1234567890"

#define DEF_ROOT_PASSWORD	"admin"
#define DEF_SMB_WORKGROUP	"WORKGROUP"
#define DEF_TIMEZONE		"CST-8"
#define DEF_NTP_SERVER0		"ntp1.aliyun.com"
#define DEF_NTP_SERVER1		"2001:470:0:50::2"
#ifdef SUPPORT_OPENSSL_EC
#define DEF_HTTPS_CIPH_LIST	"ECDH+CHACHA20:ECDH+AESGCM:DH+AESGCM:DH+AES256:DH+AES:DH+3DES:RSA+AES:RSA+3DES:!ADH:!MD5:!DSS"
#else
#define DEF_HTTPS_CIPH_LIST	"DH+AESGCM:DH+AES256:DH+AES:DH+3DES:RSA+AES:RSA+3DES:!ADH:!MD5:!DSS"
#endif
#define DEF_OVPNS_CIPH_LIST	"CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM"
#define DEF_OVPNC_CIPH_LIST	"CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM"

#endif
