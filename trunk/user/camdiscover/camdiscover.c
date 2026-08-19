/* Lightweight ONVIF WS-Discovery helper for Padavan. */
#include <arpa/inet.h>
#include <getopt.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define ONVIF_ADDR "239.255.255.250"
#define ONVIF_PORT 3702
#define BUF_SIZE 4096
static void extract(const char *x,const char *tag,char *o,size_t n){char a[64],b[64];const char*p,*q;size_t l;if(!x||!o||!n)return;snprintf(a,sizeof(a),"<%s>",tag);snprintf(b,sizeof(b),"</%s>",tag);p=strstr(x,a);if(!p)return;p+=strlen(a);q=strstr(p,b);if(!q)return;l=(size_t)(q-p);if(l>=n)l=n-1;memcpy(o,p,l);o[l]=0;}
int main(int argc,char **argv){const char*ifname=NULL;int timeout=3,opt,fd,reuse=1,ttl=1;struct sockaddr_in b,d,s;struct ip_mreqn m;unsigned int idx=0;while((opt=getopt(argc,argv,"i:t:h"))!=-1){if(opt=='i')ifname=optarg;else if(opt=='t'){timeout=atoi(optarg);if(timeout<1)timeout=1;if(timeout>30)timeout=30;}else{printf("Usage: %s [-i interface] [-t seconds]\n",argv[0]);return opt=='h'?0:1;}}fd=socket(AF_INET,SOCK_DGRAM,0);if(fd<0)return 1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));memset(&b,0,sizeof(b));b.sin_family=AF_INET;b.sin_port=htons(ONVIF_PORT);b.sin_addr.s_addr=htonl(INADDR_ANY);if(bind(fd,(struct sockaddr*)&b,sizeof(b))<0){close(fd);return 1;}if(ifname){idx=if_nametoindex(ifname);if(!idx){close(fd);return 1;}}memset(&m,0,sizeof(m));inet_aton(ONVIF_ADDR,&m.imr_multiaddr);m.imr_ifindex=(int)idx;if(setsockopt(fd,IPPROTO_IP,IP_ADD_MEMBERSHIP,&m,sizeof(m))<0){close(fd);return 1;}setsockopt(fd,IPPROTO_IP,IP_MULTICAST_TTL,&ttl,sizeof(ttl));memset(&d,0,sizeof(d));d.sin_family=AF_INET;d.sin_port=htons(ONVIF_PORT);inet_aton(ONVIF_ADDR,&d.sin_addr);char p[2048];snprintf(p,sizeof(p),"<?xml version=\"1.0\"?><e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><e:Header><w:MessageID>uuid:camdiscover-%lu</w:MessageID><w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>",(unsigned long)time(NULL));sendto(fd,p,strlen(p),0,(struct sockaddr*)&d,sizeof(d));time_t end=time(NULL)+timeout;for(;;){fd_set r;struct timeval tv;FD_ZERO(&r);FD_SET(fd,&r);tv.tv_sec=(long)(end-time(NULL));tv.tv_usec=0;if(tv.tv_sec<=0||select(fd+1,&r,NULL,NULL,&tv)<=0)break;socklen_t sl=sizeof(s);char x[BUF_SIZE];ssize_t n=recvfrom(fd,x,sizeof(x)-1,0,(struct sockaddr*)&s,&sl);if(n>0){char a[512]="",t[512]="";x[n]=0;extract(x,"d:XAddrs",a,sizeof(a));extract(x,"d:Types",t,sizeof(t));printf("ONVIF IP=%s",inet_ntoa(s.sin_addr));if(a[0])printf(" XAddrs=%s",a);if(t[0])printf(" Types=%s",t);printf("\n");fflush(stdout);}}close(fd);return 0;}
