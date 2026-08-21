#ifndef CAMDISCOVER_COMPAT_H
#define CAMDISCOVER_COMPAT_H

/*
 * The Q7 uClibc toolchain ships old libc networking headers alongside
 * Linux 3.4 UAPI headers.  Both sets define sockaddr_ll/ifreq/ifmap.
 * camdiscover uses the Linux packet API, so use the kernel definitions
 * and provide the libc function declaration it needs.
 */
#ifndef _NET_IF_H
#define _NET_IF_H 1
#endif
#ifndef _NETPACKET_PACKET_H
#define _NETPACKET_PACKET_H 1
#endif

#include <linux/if.h>
#include <linux/if_packet.h>

extern unsigned int if_nametoindex(const char *ifname);

#endif
