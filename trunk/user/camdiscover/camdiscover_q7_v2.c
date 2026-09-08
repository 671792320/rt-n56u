/* Q7 LAN discovery v2.
 * ARP/subnet database is the discovery base; multicast/broadcast protocols
 * enrich those devices. Designed for a single-port LAN uplink with a
 * temporary target-LAN source IPv4 on br0.
 */
#include <arpa/inet.h>
#include <getopt.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define ONVIF_ADDR "239.255.255.250"
#define SSDP_ADDR "239.255.255.250"
#define HIK_ADDR "239.255.255.250"
#define DAHUA_ADDR "239.255.255.251"
#define ONVIF_PORT 3702
#define SSDP_PORT 1900
#define HIK_PORT 37020
#define DAHUA_PORT 37810
#define DVRIP_PORT 5050
#define BUF_SIZE 8192
#define MAX_SUBNETS 32
#define MAX_CUSTOM 64
#define MAX_SEEN 1024

struct probe_socket { int fd; int port; const char *name; };
struct custom_probe { int fd; int port; char name[64]; char addr[64]; char payload[2048]; };
struct ctx {
    const char *iface;
    int ifindex;
    struct in_addr source;
    int has_source;
    struct probe_socket onvif, ssdp, hik, dahua, dvrip;
    struct custom_probe custom[MAX_CUSTOM];
    int custom_count;
    char subnets[MAX_SUBNETS][32];
    int subnet_count;
};

static char seen[MAX_SEEN][128];
static int seen_count;

static int seen_add(const char *key)
{
    int i;
    for (i = 0; i < seen_count; ++i) if (!strcmp(seen[i], key)) return 0;
    if (seen_count < MAX_SEEN) {
        strncpy(seen[seen_count], key, sizeof(seen[seen_count]) - 1);
        seen[seen_count][sizeof(seen[seen_count]) - 1] = 0;
        ++seen_count;
    }
    return 1;
}

static void device(const char *kind, const char *ip, const char *info)
{
    char key[128];
    if (!ip || !*ip) return;
    snprintf(key, sizeof(key), "%s:%s", kind ? kind : "IP", ip);
    if (!seen_add(key)) return;
    printf("DEVICE type=%s IP=%s MAC=-", kind ? kind : "IP", ip);
    if (info && *info) printf(" INFO=%s", info);
    printf("\n"); fflush(stdout);
}

static int iface_index(const char *name)
{
    FILE *f; char cmd[128], line[64]; int idx = 0;
    snprintf(cmd, sizeof(cmd), "/sys/class/net/%s/ifindex", name);
    f = fopen(cmd, "r"); if (!f) return 0;
    if (fgets(line, sizeof(line), f)) idx = atoi(line);
    fclose(f); return idx;
}

static int load_source(struct in_addr *out)
{
    FILE *f; char b[64];
    f = fopen("/tmp/lan_discovery_runtime/lan_discovery_status_target_ip", "r");
    if (!f) return 0;
    if (!fgets(b, sizeof(b), f)) { fclose(f); return 0; }
    fclose(f);
    b[strcspn(b, " \r\n\t")] = 0;
    return inet_aton(b, out) ? 1 : 0;
}

static void load_subnets(struct ctx *c, const char *path)
{
    FILE *f; char line[256], ip[64]; int ok;
    const char *p = path;
    if (!p || !*p) p = "/tmp/lan_discovery_devices.txt";
    f = fopen(p, "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f) && c->subnet_count < MAX_SUBNETS) {
        char *s = strstr(line, "DEVICE type=SUBNET IP=");
        if (!s) continue;
        s += strlen("DEVICE type=SUBNET IP=");
        if (sscanf(s, "%63[^ ]", ip) != 1) continue;
        ok = 1;
        if (sscanf(ip, "%*d.%*d.%*d.%*d") != 0) ok = 1;
        if (!ok) continue;
        snprintf(c->subnets[c->subnet_count], sizeof(c->subnets[0]), "%s", ip);
        ++c->subnet_count;
    }
    fclose(f);
}

static int bind_source(int fd, struct in_addr *src, int has_src)
{
    struct sockaddr_in a;
    if (!has_src) return 0;
    memset(&a, 0, sizeof(a)); a.sin_family = AF_INET; a.sin_addr = *src;
    return bind(fd, (struct sockaddr *)&a, sizeof(a));
}

static int receiver(const char *group, int port, struct in_addr *src, int has_src)
{
    int fd, reuse = 1;
    struct sockaddr_in b;
    struct ip_mreqn m;
    fd = socket(AF_INET, SOCK_DGRAM, 0); if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    memset(&b, 0, sizeof(b)); b.sin_family = AF_INET; b.sin_port = htons(port);
    b.sin_addr.s_addr = has_src ? src->s_addr : htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&b, sizeof(b)) < 0) { close(fd); return -1; }
    memset(&m, 0, sizeof(m)); inet_aton(group, &m.imr_multiaddr); if (has_src) m.imr_address = *src;
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, sizeof(m)) < 0) { close(fd); return -1; }
    return fd;
}

static int sender_socket(struct in_addr *src, int has_src)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int one = 1;
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    if (bind_source(fd, src, has_src) < 0) { close(fd); return -1; }
    return fd;
}

static int sendto_ip(int fd, const char *ip, int port, const void *data, size_t len)
{
    struct sockaddr_in d; ssize_t n;
    memset(&d, 0, sizeof(d)); d.sin_family = AF_INET; d.sin_port = htons(port);
    if (!inet_aton(ip, &d.sin_addr)) return -1;
    n = sendto(fd, data, len, 0, (struct sockaddr *)&d, sizeof(d));
    return n == (ssize_t)len ? 0 : -1;
}

static void subnet_broadcast(const char *net, char *out, size_t n)
{
    unsigned int a,b,c;
    if (sscanf(net, "%u.%u.%u", &a,&b,&c) == 3) snprintf(out,n,"%u.%u.%u.255",a,b,c);
    else out[0] = 0;
}

static int send_onvif(int fd)
{
    static const char p[] = "<?xml version=\"1.0\"?><e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><e:Header><w:MessageID>uuid:q7-camdiscover</w:MessageID><w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>";
    return sendto_ip(fd, ONVIF_ADDR, ONVIF_PORT, p, strlen(p));
}

static int send_ssdp(int fd)
{
    static const char p[] = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\nUSER-AGENT: Padavan-Q7-camdiscover/2.0\r\n\r\n";
    return sendto_ip(fd, SSDP_ADDR, SSDP_PORT, p, strlen(p));
}

static const char *hik_probe = "<?xml version=\"1.0\" encoding=\"utf-8\"?><Probe><Uuid>13A888A9-F1B1-4020-AE9F-05607682D23B</Uuid><Types>inquiry</Types></Probe>";

static int send_hik(int fd, const char *broadcast, int port)
{
    return sendto_ip(fd, broadcast, port, hik_probe, strlen(hik_probe));
}

static size_t dahua_dhip(unsigned char *out, size_t max)
{
    static const char body[] = "{\"method\":\"DHDiscover.search\",\"params\":{\"mac\":\"\",\"uni\":1}}";
    size_t n = strlen(body);
    if (max < 32 + n) return 0;
    memset(out, 0, 32 + n);
    out[0]=0x20; out[1]=0x00; out[2]=0x00; out[3]=0x00;
    out[4]='D'; out[5]='H'; out[6]='I'; out[7]='P';
    out[16]=(unsigned char)((n>>24)&255); out[17]=(unsigned char)((n>>16)&255); out[18]=(unsigned char)((n>>8)&255); out[19]=(unsigned char)(n&255);
    out[24]=(unsigned char)((n>>24)&255); out[25]=(unsigned char)((n>>16)&255); out[26]=(unsigned char)((n>>8)&255); out[27]=(unsigned char)(n&255);
    memcpy(out+32, body, n);
    return 32+n;
}

static size_t dahua_dvrip(unsigned char *out, size_t max)
{
    if (max < 48) return 0;
    memset(out,0,48);
    out[0]=0xa3; out[1]=0x01; out[2]=0x00; out[3]=0x01;
    out[28]=0x02; out[29]=0x00; out[30]=0x00; out[31]=0x00;
    return 48;
}

static void rx_probe(int fd, const char *kind)
{
    unsigned char b[BUF_SIZE]; struct sockaddr_in s; socklen_t sl=sizeof(s); ssize_t n; char ip[64]; char info[256];
    n = recvfrom(fd,b,sizeof(b)-1,0,(struct sockaddr*)&s,&sl); if(n<=0) return;
    if(!inet_ntop(AF_INET,&s.sin_addr,ip,sizeof(ip))) return;
    if (!strcmp(kind,"SSDP")) snprintf(info,sizeof(info),"SSDP response len=%ld",(long)n);
    else if (!strcmp(kind,"ONVIF")) snprintf(info,sizeof(info),"ONVIF response len=%ld",(long)n);
    else if (!strcmp(kind,"DVRIP")) snprintf(info,sizeof(info),"DVRIP response len=%ld",(long)n);
    else snprintf(info,sizeof(info),"%s response len=%ld",kind,(long)n);
    device(kind,ip,info);
    printf("[camdiscover] %s RX %s:%d bytes=%ld\n",kind,ip,ntohs(s.sin_port),(long)n); fflush(stdout);
}

static void url_decode(char *dst,size_t dstn,const char *src)
{
    size_t i=0; unsigned int x;
    while(*src && i+1<dstn){
        if(src[0]=='%' && src[1] && src[2] && sscanf(src+1,"%2x",&x)==1){ dst[i++]=(char)x; src+=3; }
        else if(*src=='+'){ dst[i++]=' '; ++src; }
        else dst[i++]=*src++;
    }
    dst[i]=0;
}

static void load_custom(struct ctx *c, const char *path)
{
    FILE *f; char line[4096], *a,*b,*d,*e; int i;
    if(!path) return; f=fopen(path,"r"); if(!f) return;
    while(fgets(line,sizeof(line),f) && c->custom_count<MAX_CUSTOM){
        line[strcspn(line,"\r\n")]=0; a=strchr(line,'|'); if(!a) continue; *a++=0;
        b=strchr(a,'|'); if(!b) continue; *b++=0; d=strchr(b,'|'); if(!d) continue; *d++=0;
        e=strchr(d,'|'); if(!e) continue; *e++=0; if(strcmp(e,"1")) continue;
        i=c->custom_count; c->custom[i].fd=-1; url_decode(c->custom[i].name,sizeof(c->custom[i].name),line);
        url_decode(c->custom[i].addr,sizeof(c->custom[i].addr),a); c->custom[i].port=atoi(b); url_decode(c->custom[i].payload,sizeof(c->custom[i].payload),d);
        c->custom[i].fd=socket(AF_INET,SOCK_DGRAM,0); if(c->custom[i].fd<0) continue;
        c->custom_count++;
    }
    fclose(f);
}

static void send_custom(struct ctx *c)
{
    int i,fd,rc;
    for(i=0;i<c->custom_count;i++){
        fd=sender_socket(&c->source,c->has_source); if(fd<0) continue;
        rc=sendto_ip(fd,c->custom[i].addr,c->custom[i].port,c->custom[i].payload,strlen(c->custom[i].payload));
        printf("[camdiscover] custom %s probe %s\n",c->custom[i].name,rc==0?"sent":"FAILED"); fflush(stdout); close(fd);
    }
}

static int maxfd_add(fd_set *s,int fd,int *m)
{ if(fd<0) return 0; FD_SET(fd,s); if(fd>*m)*m=fd; return 1; }

int main(int argc,char **argv)
{
    struct ctx c; const char *custom=NULL; const char *subnet_file=NULL; int timeout=8, enable_onvif=1,enable_ssdp=1,enable_hik=1,enable_dahua=1,enable_raw=1; int p_onvif=3702,p_ssdp=1900,p_hik=37020,p_dahua=37810; int opt,i,maxfd,rc; struct timeval tv; fd_set rfds; time_t end; unsigned char frame[512];
    memset(&c,0,sizeof(c)); c.onvif.fd=c.ssdp.fd=c.hik.fd=c.dahua.fd=c.dvrip.fd=-1;
    while((opt=getopt(argc,argv,"i:t:o:s:k:d:O:S:H:D:A:C:I:N:"))!=-1){
        switch(opt){case'i':c.iface=optarg;break;case't':timeout=atoi(optarg);break;case'o':p_onvif=atoi(optarg);break;case's':p_ssdp=atoi(optarg);break;case'k':p_hik=atoi(optarg);break;case'd':p_dahua=atoi(optarg);break;case'O':enable_onvif=atoi(optarg)!=0;break;case'S':enable_ssdp=atoi(optarg)!=0;break;case'H':enable_hik=atoi(optarg)!=0;break;case'D':enable_dahua=atoi(optarg)!=0;break;case'A':enable_raw=atoi(optarg)!=0;break;case'C':custom=optarg;break;case'I':{if(inet_aton(optarg,&c.source))c.has_source=1;}break;case'N':subnet_file=optarg;break;default:break;}
    }
    if(!c.iface)c.iface="br0"; if(timeout<1)timeout=1;if(timeout>60)timeout=60; c.ifindex=iface_index(c.iface); if(!c.has_source)c.has_source=load_source(&c.source); load_subnets(&c,subnet_file); load_custom(&c,custom);
    printf("[camdiscover] iface=%s ifindex=%d source=%s target_subnets=%d\n",c.iface,c.ifindex,c.has_source?inet_ntoa(c.source):"auto",c.subnet_count);

    if(enable_onvif)c.onvif.fd=receiver(ONVIF_ADDR,p_onvif,&c.source,c.has_source);
    if(enable_ssdp)c.ssdp.fd=receiver(SSDP_ADDR,p_ssdp,&c.source,c.has_source);
    if(enable_hik)c.hik.fd=receiver(HIK_ADDR,p_hik,&c.source,c.has_source);
    if(enable_dahua)c.dahua.fd=receiver(DAHUA_ADDR,p_dahua,&c.source,c.has_source);
    printf("[camdiscover] sockets ONVIF=%d SSDP=%d HIK=%d DAHUA=%d custom=%d\n",c.onvif.fd,c.ssdp.fd,c.hik.fd,c.dahua.fd,c.custom_count); fflush(stdout);

    if(c.custom_count)send_custom(&c);
    {
        int fd=sender_socket(&c.source,c.has_source);
        if(fd>=0){
            if(c.onvif.fd>=0)printf("[camdiscover] ONVIF multicast %s\n",send_onvif(fd)==0?"sent":"FAILED");
            if(c.ssdp.fd>=0)printf("[camdiscover] SSDP multicast %s\n",send_ssdp(fd)==0?"sent":"FAILED");
            if(c.hik.fd>=0){int ok=sendto_ip(fd,HIK_ADDR,p_hik,hik_probe,strlen(hik_probe)); printf("[camdiscover] HIK multicast %s\n",ok==0?"sent":"FAILED");}
            if(c.dahua.fd>=0){size_t n=dahua_dhip(frame,sizeof(frame)); int ok=sendto_ip(fd,DAHUA_ADDR,p_dahua,frame,n); printf("[camdiscover] DAHUA multicast %s\n",ok==0?"sent":"FAILED");}
            if(enable_dahua){size_t n=dahua_dvrip(frame,sizeof(frame)); int ok=0; if(n) ok=sendto_ip(fd,"255.255.255.255",DVRIP_PORT,frame,n); printf("[camdiscover] DAHUA DVRIP broadcast %s\n",ok==0?"sent":"FAILED");}
            if(enable_hik||enable_dahua){
                for(i=0;i<c.subnet_count;i++){
                    char bc[64]; subnet_broadcast(c.subnets[i],bc,sizeof(bc)); if(!bc[0])continue;
                    if(enable_hik)printf("[camdiscover] HIK broadcast %s:%d %s\n",bc,p_hik,send_hik(fd,bc,p_hik)==0?"sent":"FAILED");
                    if(enable_dahua){size_t n=dahua_dhip(frame,sizeof(frame));printf("[camdiscover] DAHUA broadcast %s:%d %s\n",bc,p_dahua,sendto_ip(fd,bc,p_dahua,frame,n)==0?"sent":"FAILED");}
                }
            }
            close(fd);
        }
    }
    printf("[camdiscover] probes enabled: ONVIF=%d SSDP=%d HIK=%d DAHUA=%d ARP=%d\n",enable_onvif,enable_ssdp,enable_hik,enable_dahua,enable_raw); fflush(stdout);
    end=time(NULL)+timeout;
    while(time(NULL)<end){
        FD_ZERO(&rfds);maxfd=-1;maxfd_add(&rfds,c.onvif.fd,&maxfd);maxfd_add(&rfds,c.ssdp.fd,&maxfd);maxfd_add(&rfds,c.hik.fd,&maxfd);maxfd_add(&rfds,c.dahua.fd,&maxfd);
        for(i=0;i<c.custom_count;i++)if(c.custom[i].fd>=0)maxfd_add(&rfds,c.custom[i].fd,&maxfd);
        if(maxfd<0)break;tv.tv_sec=1;tv.tv_usec=0;rc=select(maxfd+1,&rfds,NULL,NULL,&tv);if(rc<=0)continue;
        if(c.onvif.fd>=0&&FD_ISSET(c.onvif.fd,&rfds))rx_probe(c.onvif.fd,"ONVIF");
        if(c.ssdp.fd>=0&&FD_ISSET(c.ssdp.fd,&rfds))rx_probe(c.ssdp.fd,"SSDP");
        if(c.hik.fd>=0&&FD_ISSET(c.hik.fd,&rfds))rx_probe(c.hik.fd,"HIK");
        if(c.dahua.fd>=0&&FD_ISSET(c.dahua.fd,&rfds))rx_probe(c.dahua.fd,"DAHUA");
    }
    if(c.onvif.fd>=0)close(c.onvif.fd);if(c.ssdp.fd>=0)close(c.ssdp.fd);if(c.hik.fd>=0)close(c.hik.fd);if(c.dahua.fd>=0)close(c.dahua.fd);for(i=0;i<c.custom_count;i++)if(c.custom[i].fd>=0)close(c.custom[i].fd);
    return 0;
}
