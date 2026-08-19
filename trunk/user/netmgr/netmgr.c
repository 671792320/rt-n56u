#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define DEFAULT_IFACE "br0"
#define DEFAULT_INTERVAL 1
#define STATE_FILE "/var/run/netmgr.state"
#define LOG_FILE "/var/log/netmgr.log"
static volatile sig_atomic_t running=1;
static void stop_handler(int s){(void)s;running=0;}
static int carrier(const char *ifname){char p[128],b[8];int fd,n;snprintf(p,sizeof(p),"/sys/class/net/%s/carrier",ifname);fd=open(p,O_RDONLY);if(fd<0)return -1;n=read(fd,b,sizeof(b)-1);close(fd);if(n<=0)return -1;b[n]=0;return b[0]=='1'?1:0;}
static void report(const char *ifname,int link){const char *phase=link==1?"LINK_UP":link==0?"LINK_DOWN":"LINK_UNKNOWN";time_t now=time(NULL);FILE*f=fopen(STATE_FILE,"w");if(f){fprintf(f,"interface=%s\nlink=%d\nphase=%s\ntime=%ld\n",ifname,link,phase,(long)now);fclose(f);}f=fopen(LOG_FILE,"a");if(f){fprintf(f,"%ld interface=%s link=%d phase=%s\n",(long)now,ifname,link,phase);fclose(f);}printf("[netmgr] interface=%s link=%s phase=%s\n",ifname,link==1?"UP":link==0?"DOWN":"UNKNOWN",phase);fflush(stdout);}
int main(int argc,char**argv){const char*ifname=DEFAULT_IFACE;int interval=1,old=-2,now,opt;while((opt=getopt(argc,argv,"i:t:h"))!=-1){if(opt=='i')ifname=optarg;else if(opt=='t'){interval=atoi(optarg);if(interval<1)interval=1;if(interval>60)interval=60;}else{printf("Usage: %s [-i interface] [-t seconds]\n",argv[0]);return opt=='h'?0:1;}}signal(SIGTERM,stop_handler);signal(SIGINT,stop_handler);mkdir("/var/run",0755);mkdir("/var/log",0755);while(running){now=carrier(ifname);if(now!=old){report(ifname,now);old=now;}sleep(interval);}return 0;}
