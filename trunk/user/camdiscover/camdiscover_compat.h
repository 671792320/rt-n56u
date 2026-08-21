#ifndef CAMDISCOVER_COMPAT_H
#define CAMDISCOVER_COMPAT_H

/*
 * Q7 uses an old uClibc toolchain whose libc networking headers conflict
 * with the Linux 3.4 UAPI packet headers. camdiscover uses the kernel
 * packet API, so select the kernel definitions consistently.
 *
 * linux/if.h embeds struct sockaddr, therefore socket.h must be included
 * first.  Do not include net/if.h or netpacket/packet.h here: their structs
 * conflict with linux/if.h and linux/if_packet.h on this toolchain.
 */
#include <sys/socket.h>

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
