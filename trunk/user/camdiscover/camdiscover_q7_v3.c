#include <arpa/inet.h>
#include <getopt.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define ONVIF_G "239.255.255.250"
#define SSDP_G "239.255.255.250"
#define HIK_G "239.255.255.250"
#define DAHUA_G "239.255.255.251"
#define MAX_SUBNET 32
#define BUF 8192
#define SEEN 1024

struct ctx { int onvif,ssdp,hik,dahua; int ifindex; int timeout; int onvif_en,ssdp_en,hik_en,dahua_en; int onvif_port,ssdp_port,hik_port,dahua_port; struct in_addr src; int has_src; char subnet[MAX_SUBNET][32]; int subnet_count; };
static char seen[SEEN][96]; static int seen_count;

static int seen_add(const char *k){int i;for(i=0;i<seen_count;i++)if(!strcmp(seen[i],k))return 0;if(seen_count<SEEN){strncpy(seen[seen_count],k,95);seen[seen_count][95]=0;seen_count++;}return 1;}
static const char *type_cn(const char *type){if(!strcmp(type,"ONVIF"))return "ONVIF";if(!strcmp(type,"SSDP"))return "SSDP";if(!strcmp(type,"HIK"))return "HIK";if(!strcmp(type,"DAHUA"))return "DAHUA";if(!strcmp(type,"ARP"))return "ARP";return type;}
static void print_dev(const char *type,const char *ip,long n){char k[96];snprintf(k,sizeof(k),"%s:%s",type,ip);if(!seen_add(k))return;printf("DEVICE type=%s IP=%s MAC=- INFO=回包响应=%ld字节\n",type,ip,n);printf("[camdiscover] 发现设备：IP=%s 协议=%s MAC=- 回包响应=%ld字节\n",ip,type_cn(type),n);fflush(stdout);}
static int ifindex_of(const char *name){char p[128],b[32];FILE*f;snprintf(p,sizeof(p),"/sys/class/net/%s/ifindex",name);f=fopen(p,"r");if(!f)return 0;if(!fgets(b,sizeof(b),f)){fclose(f);return 0;}fclose(f);return atoi(b);}
static int load_src(struct in_addr *a){FILE*f;char b[64];f=fopen("/tmp/lan_discovery_runtime/lan_discovery_status_target_ip","r");if(!f)return 0;if(!fgets(b,sizeof(b),f)){fclose(f);return 0;}fclose(f);b[strcspn(b," \r\n\t")]=0;return inet_aton(b,a);}
static void load_subnets(struct ctx*c){FILE*f;char line[256],ip[64];f=fopen("/tmp/lan_discovery_devices.txt","r");if(!f)return;while(fgets(line,sizeof(line),f)&&c->subnet_count<MAX_SUBNET){char*p=strstr(line,"DEVICE type=SUBNET IP=");if(!p)continue;p+=22;if(sscanf(p,"%63[^ ]",ip)!=1)continue;snprintf(c->subnet[c->subnet_count],32,"%s",ip);c->subnet_count++;}fclose(f);}
static void bc_addr(const char*net,char*out){unsigned int a,b,c;if(sscanf(net,"%u.%u.%u",&a,&b,&c)==3)snprintf(out,64,"%u.%u.%u.255",a,b,c);else*out=0;}
static int make_rx(struct in_addr*src,int has,const char*group,int port){int fd,reuse=1,one=1;struct sockaddr_in b;struct ip_mreqn m;fd=socket(AF_INET,SOCK_DGRAM,0);if(fd<0)return -1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&one,sizeof(one));memset(&b,0,sizeof(b));b.sin_family=AF_INET;b.sin_port=htons(port);b.sin_addr.s_addr=has?src->s_addr:htonl(INADDR_ANY);if(bind(fd,(struct sockaddr*)&b,sizeof(b))<0){close(fd);return -1;}memset(&m,0,sizeof(m));inet_aton(group,&m.imr_multiaddr);if(has)m.imr_address=*src; if(setsockopt(fd,IPPROTO_IP,IP_ADD_MEMBERSHIP,&m,sizeof(m))<0){close(fd);return -1;}return fd;}
static int sendto_addr(int fd,const char*ip,int port,const void*p,size_t n){struct sockaddr_in d;ssize_t w;memset(&d,0,sizeof(d));d.sin_family=AF_INET;d.sin_port=htons(port);if(!inet_aton(ip,&d.sin_addr))return -1;w=sendto(fd,p,n,0,(struct sockaddr*)&d,sizeof(d));return w==(ssize_t)n?0:-1;}
static const char onvif_probe[]="<?xml version=\"1.0\"?><e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><e:Header><w:MessageID>uuid:q7-discovery</w:MessageID><w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>";
static const char ssdp_probe[]="M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\nUSER-AGENT: Padavan-Q7-camdiscover/3.0\r\n\r\n";
static const char hik_probe[]="<?xml version=\"1.0\" encoding=\"utf-8\"?><Probe><Uuid>13A888A9-F1B1-4020-AE9F-05607682D23B</Uuid><Types>inquiry</Types></Probe>";
static size_t dahua_probe(unsigned char*b,size_t z){const char body[]={"{\"method\":\"DHDiscover.search\",\"params\":{\"mac\":\"\",\"uni\":1}}"};size_t n=strlen(body);if(z<32+n)return 0;memset(b,0,32+n);b[0]=0x20;b[4]='D';b[5]='H';b[6]='I';b[7]='P';b[16]=(n>>24)&255;b[17]=(n>>16)&255;b[18]=(n>>8)&255;b[19]=n&255;b[24]=(n>>24)&255;b[25]=(n>>16)&255;b[26]=(n>>8)&255;b[27]=n&255;memcpy(b+32,body,n);return 32+n;}
static void rx(int fd,const char*kind){unsigned char b[BUF];struct sockaddr_in s;socklen_t sl=sizeof(s);ssize_t n;char ip[64];n=recvfrom(fd,b,sizeof(b),0,(struct sockaddr*)&s,&sl);if(n<=0)return;if(!inet_ntop(AF_INET,&s.sin_addr,ip,sizeof(ip)))return;print_dev(kind,ip,(long)n);printf("[camdiscover] %s收到响应：IP=%s，回包=%ld字节\n",type_cn(kind),ip,(long)n);fflush(stdout);}

int main(int argc,char**argv){struct ctx c;const char*ifname="br0";int opt,maxfd,rc,i;struct timeval tv;fd_set rfds;time_t end;unsigned char frame[256];memset(&c,0,sizeof(c));c.onvif=c.ssdp=c.hik=c.dahua=-1;c.timeout=8;c.onvif_en=c.ssdp_en=c.hik_en=c.dahua_en=1;c.onvif_port=3702;c.ssdp_port=1900;c.hik_port=37020;c.dahua_port=37810;while((opt=getopt(argc,argv,"i:t:o:s:k:d:OSHDAC:I:"))!=-1){switch(opt){case'i':ifname=optarg;break;case't':c.timeout=atoi(optarg);break;case'o':c.onvif_port=atoi(optarg);break;case's':c.ssdp_port=atoi(optarg);break;case'k':c.hik_port=atoi(optarg);break;case'd':c.dahua_port=atoi(optarg);break;case'O':c.onvif_en=atoi(optarg)!=0;break;case'S':c.ssdp_en=atoi(optarg)!=0;break;case'H':c.hik_en=atoi(optarg)!=0;break;case'D':c.dahua_en=atoi(optarg)!=0;break;case'I':if(inet_aton(optarg,&c.src))c.has_src=1;break;case'A':break;case'C':break;default:break;}}
if(c.timeout<1)c.timeout=1;if(c.timeout>30)c.timeout=30;c.ifindex=ifindex_of(ifname);if(!c.has_src)c.has_src=load_src(&c.src);load_subnets(&c);printf("[camdiscover] 接口=%s ifindex=%d 源地址=%s 目标网段数=%d\n",ifname,c.ifindex,c.has_src?inet_ntoa(c.src):"自动",c.subnet_count);if(c.onvif_en)c.onvif=make_rx(&c.src,c.has_src,ONVIF_G,c.onvif_port);if(c.ssdp_en)c.ssdp=make_rx(&c.src,c.has_src,SSDP_G,c.ssdp_port);if(c.hik_en)c.hik=make_rx(&c.src,c.has_src,HIK_G,c.hik_port);if(c.dahua_en)c.dahua=make_rx(&c.src,c.has_src,DAHUA_G,c.dahua_port);printf("[camdiscover] 模块：ONVIF=%s SSDP=%s HIK=%s DAHUA=%s\n",c.onvif_en?"启用":"关闭",c.ssdp_en?"启用":"关闭",c.hik_en?"启用":"关闭",c.dahua_en?"启用":"关闭");fflush(stdout);
if(c.onvif>=0)printf("[camdiscover] ONVIF探测%s\n",sendto_addr(c.onvif,ONVIF_G,c.onvif_port,onvif_probe,strlen(onvif_probe))==0?"已发送":"发送失败");if(c.ssdp>=0)printf("[camdiscover] SSDP探测%s\n",sendto_addr(c.ssdp,SSDP_G,c.ssdp_port,ssdp_probe,strlen(ssdp_probe))==0?"已发送":"发送失败");if(c.hik>=0){printf("[camdiscover] HIK探测%s\n",sendto_addr(c.hik,HIK_G,c.hik_port,hik_probe,strlen(hik_probe))==0?"已发送":"发送失败");for(i=0;i<c.subnet_count;i++){char bc[64];bc_addr(c.subnet[i],bc);if(bc[0])printf("[camdiscover] HIK广播 %s %s\n",bc,sendto_addr(c.hik,bc,c.hik_port,hik_probe,strlen(hik_probe))==0?"已发送":"发送失败");}}
if(c.dahua>=0){size_t n=dahua_probe(frame,sizeof(frame));printf("[camdiscover] 大华探测%s\n",sendto_addr(c.dahua,DAHUA_G,c.dahua_port,frame,n)==0?"已发送":"发送失败");for(i=0;i<c.subnet_count;i++){char bc[64];bc_addr(c.subnet[i],bc);if(bc[0])printf("[camdiscover] 大华广播 %s %s\n",bc,sendto_addr(c.dahua,bc,c.dahua_port,frame,n)==0?"已发送":"发送失败");}}
end=time(NULL)+c.timeout;while(time(NULL)<end){FD_ZERO(&rfds);maxfd=-1;if(c.onvif>=0){FD_SET(c.onvif,&rfds);if(c.onvif>maxfd)maxfd=c.onvif;}if(c.ssdp>=0){FD_SET(c.ssdp,&rfds);if(c.ssdp>maxfd)maxfd=c.ssdp;}if(c.hik>=0){FD_SET(c.hik,&rfds);if(c.hik>maxfd)maxfd=c.hik;}if(c.dahua>=0){FD_SET(c.dahua,&rfds);if(c.dahua>maxfd)maxfd=c.dahua;}if(maxfd<0)break;tv.tv_sec=1;tv.tv_usec=0;rc=select(maxfd+1,&rfds,0,0,&tv);if(rc<=0)continue;if(c.onvif>=0&&FD_ISSET(c.onvif,&rfds))rx(c.onvif,"ONVIF");if(c.ssdp>=0&&FD_ISSET(c.ssdp,&rfds))rx(c.ssdp,"SSDP");if(c.hik>=0&&FD_ISSET(c.hik,&rfds))rx(c.hik,"HIK");if(c.dahua>=0&&FD_ISSET(c.dahua,&rfds))rx(c.dahua,"DAHUA");}
if(c.onvif>=0)close(c.onvif);if(c.ssdp>=0)close(c.ssdp);if(c.hik>=0)close(c.hik);if(c.dahua>=0)close(c.dahua);return 0;}