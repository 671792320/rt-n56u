#!/bin/sh
# LAN事件监督程序。
# Q7唯一RJ45使用本程序监听物理插拔，并统一管理发现worker、实时二层监听与网络模式管理器。
# LAN拔出只暂停发现，不撤销已有目标网段、临时IP和SNAT。

PIDFILE=/tmp/lan_autodiscover_worker.pid
NETMGR_PIDFILE=/tmp/lan_network_manager.pid
TCPDUMP_PIDFILE=/tmp/lan_tcpdump_listener.pid
SUPERVISOR_LOCKDIR=/var/run/lan_discovery_supervisor.lock
WORKER_LOCKDIR=/var/run/lan_autodiscover.lock
DEVICE_DB=/tmp/lan_discovery_devices.txt
LOG_FILE=/tmp/lan_discovery.log
RUNTIME_DIR=/tmp/lan_discovery_runtime
TCPDUMP_RETRY_FILE="$RUNTIME_DIR/lan_tcpdump_retry"
mkdir -p "$RUNTIME_DIR"

if ! mkdir "$SUPERVISOR_LOCKDIR" 2>/dev/null; then
    # 已有监督器运行：直接退出，不重复刷日志。
    exit 0
fi
printf '%s\n' "$" > "$SUPERVISOR_LOCKDIR/pid"
trap 'rm -f "$SUPERVISOR_LOCKDIR/pid" 2>/dev/null; rmdir "$SUPERVISOR_LOCKDIR" 2>/dev/null' EXIT INT TERM HUP

nv() { nvram get "$1" 2>/dev/null; }
runtime_set() {
    item="$1"
    key="${item%%=*}"
    value="${item#*=}"
    tmp="$RUNTIME_DIR/.$key.tmp.$"
    printf '%s' "$value" > "$tmp" && mv -f "$tmp" "${RUNTIME_DIR}/${key}"
}
cfg() { v="$(nv "$1")"; [ -n "$v" ] && echo "$v" || echo "$2"; }
set_supervisor_status() { runtime_set lan_discovery_status_supervisor="$1"; }
beijing_now() { TZ='GMT-8' date '+%Y-%m-%d %H:%M:%S'; }
LOG_DEDUPE_DIR="$RUNTIME_DIR/.log_dedupe_supervisor"
mkdir -p "$LOG_DEDUPE_DIR"
slog() {
    msg="$*"
    now_ts="$(date +%s 2>/dev/null)"
    case "$now_ts" in ''|*[!0-9]*) now_ts=0;; esac
    last_ts="$(cat "$LOG_DEDUPE_DIR/ts" 2>/dev/null)"
    case "$last_ts" in ''|*[!0-9]*) last_ts=0;; esac
    last_msg="$(cat "$LOG_DEDUPE_DIR/msg" 2>/dev/null)"
    if [ "$last_msg" = "$msg" ] && [ "$now_ts" -ge "$last_ts" ] 2>/dev/null && [ $((now_ts - last_ts)) -lt 5 ] 2>/dev/null; then
        return 0
    fi
    printf '%s' "$now_ts" > "$LOG_DEDUPE_DIR/ts"
    printf '%s' "$msg" > "$LOG_DEDUPE_DIR/msg"
    logger -t lan-supervisor "[北京时间 $(beijing_now)] 【LAN监督】$msg"
}

# 按完整命令行兜底回收旧版/失配PID文件留下的孤儿进程。
kill_matching_processes() {
    pattern="$1"
    for pid in $(ps 2>/dev/null | awk -v p="$pattern" 'index($0,p) && $1 ~ /^[0-9]+$/ {print $1}'); do
        case "$pid" in
            ''|1|$) ;;
            *) kill "$pid" 2>/dev/null ;;
        esac
    done
}

# Q7 LAN发现配置迁移：5版固定采用“LAN拔出保留临时网段/SNAT”，并加入主动补漏周期。
# 旧版的清理开关不再参与运行时行为，避免拔插事件误删正在使用的访问规则。
LAN_DISCOVERY_CONFIG_VERSION=5
migrate_lan_discovery_config() {
    current="$(nv lan_discovery_config_version)"
    if [ "$current" != "$LAN_DISCOVERY_CONFIG_VERSION" ]; then
        [ -n "$(nv lan_discovery_enable)" ] || nvram set lan_discovery_enable=1
        [ -n "$(nv lan_discovery_ifname)" ] || nvram set lan_discovery_ifname=eth2.1
        [ -n "$(nv lan_discovery_dhcp_enable)" ] || nvram set lan_discovery_dhcp_enable=1
        [ -n "$(nv lan_discovery_dhcp_timeout)" ] || nvram set lan_discovery_dhcp_timeout=3
        [ -n "$(nv lan_discovery_discover_enable)" ] || nvram set lan_discovery_discover_enable=1
        [ -n "$(nv lan_discovery_cycle)" ] || nvram set lan_discovery_cycle=10
        [ -n "$(nv lan_discovery_probe_timeout)" ] || nvram set lan_discovery_probe_timeout=5
        [ -n "$(nv lan_discovery_miss_limit)" ] || nvram set lan_discovery_miss_limit=3
        [ -n "$(nv lan_discovery_sweep_cycle)" ] || nvram set lan_discovery_sweep_cycle=120
        nvram set lan_discovery_clear_on_unplug=0
        [ -n "$(nv lan_discovery_raw)" ] || nvram set lan_discovery_raw=1
        [ -n "$(nv lan_discovery_onvif)" ] || nvram set lan_discovery_onvif=1
        [ -n "$(nv lan_discovery_onvif_port)" ] || nvram set lan_discovery_onvif_port=3702
        [ -n "$(nv lan_discovery_ssdp)" ] || nvram set lan_discovery_ssdp=1
        [ -n "$(nv lan_discovery_ssdp_port)" ] || nvram set lan_discovery_ssdp_port=1900
        [ -n "$(nv lan_discovery_hik)" ] || nvram set lan_discovery_hik=1
        [ -n "$(nv lan_discovery_hik_port)" ] || nvram set lan_discovery_hik_port=37020
        [ -n "$(nv lan_discovery_dahua)" ] || nvram set lan_discovery_dahua=1
        [ -n "$(nv lan_discovery_dahua_port)" ] || nvram set lan_discovery_dahua_port=37810
        [ -n "$(nv lan_discovery_custom)" ] || nvram set lan_discovery_custom="# Q7标准探测配置\nonvif|3702|1\nssdp|1900|1\nhik|37020|1\ndahua|37810|1\narp|-|1"
        nvram set lan_discovery_config_version="$LAN_DISCOVERY_CONFIG_VERSION"
        nvram commit
        slog "发现配置迁移完成：版本=$LAN_DISCOVERY_CONFIG_VERSION，LAN拔出保留临时网段/SNAT"
    fi
}

migrate_lan_discovery_config

mtk_esw_lan4_state() {
    [ -x /sbin/mtk_esw ] || return 2
    state="$(/sbin/mtk_esw 10 4 2>/dev/null | sed -n 's/^LAN4 link state: \([01]\)$/\1/p')"
    case "$state" in
        1) return 0;;
        0) return 1;;
    esac
    return 2
}

is_link_up() {
    iface="$1"
    if [ "$iface" = "eth2.1" ]; then
        mtk_esw_lan4_state
        rc=$?
        [ "$rc" = "0" ] && return 0
        [ "$rc" = "1" ] && return 1
    fi
    [ -e "/sys/class/net/$iface" ] || return 1
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = "1" ] && return 0
    else
        [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "up" ] && return 0
    fi
    return 1
}

worker_running() {
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) rm -f "$PIDFILE"; return 1;;
    esac
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$PIDFILE"
    return 1
}

network_manager_pid_valid() {
    pid="$1"
    case "$pid" in
        ''|*[!0-9]*|1) return 1;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmdline" in
        *"/usr/bin/lan_network_manager.sh"*) return 0;;
    esac
    return 1
}

network_manager_pids() {
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        network_manager_pid_valid "$pid" && printf '%s\n' "$pid"
    done
}

network_manager_running() {
    [ -r "$NETMGR_PIDFILE" ] || return 1
    pid="$(cat "$NETMGR_PIDFILE" 2>/dev/null)"
    if network_manager_pid_valid "$pid"; then
        return 0
    fi
    rm -f "$NETMGR_PIDFILE"
    return 1
}

normalize_network_manager_instances() {
    keep=""
    if [ -r "$NETMGR_PIDFILE" ]; then
        pid="$(cat "$NETMGR_PIDFILE" 2>/dev/null)"
        network_manager_pid_valid "$pid" && keep="$pid"
    fi

    for pid in $(network_manager_pids); do
        case "$pid" in
            ''|1|$$) continue;;
        esac
        if [ -z "$keep" ]; then
            keep="$pid"
            continue
        fi
        if [ "$pid" != "$keep" ]; then
            kill "$pid" 2>/dev/null
        fi
    done

    if [ -n "$keep" ]; then
        printf '%s\n' "$keep" > "$NETMGR_PIDFILE"
        return 0
    fi
    rm -f "$NETMGR_PIDFILE"
    return 1
}
tcpdump_running() {
    [ -r "$TCPDUMP_PIDFILE" ] || return 1
    pid="$(cat "$TCPDUMP_PIDFILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) rm -f "$TCPDUMP_PIDFILE"; return 1;;
    esac
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$TCPDUMP_PIDFILE"
    return 1
}

start_network_manager() {
    iface="$1"

    # 正常运行时不再每秒扫描/proc；只有PID失效时才收敛历史残留。
    if network_manager_running; then
        runtime_set lan_discovery_status_network_manager="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lan_network_manager.sh ]; then
        runtime_set lan_discovery_status_network_manager="程序不存在"
        if [ "$(cat "$RUNTIME_DIR/lan_discovery_status_network_manager" 2>/dev/null)" != "程序不存在" ]; then
            slog "网络模式管理器不存在"
        fi
        return 1
    fi
    slog "网络模式管理器启动：接口=$iface"
    /usr/bin/lan_network_manager.sh > /tmp/lan_network_manager.log 2>&1 &
    echo "$!" > "$NETMGR_PIDFILE"
    runtime_set lan_discovery_status_network_manager="运行中"
    return 0
}

stop_network_manager() {
    was_running=0
    if network_manager_running; then
        pid="$(cat "$NETMGR_PIDFILE" 2>/dev/null)"
        was_running=1
        slog "网络模式管理器停止"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    rm -f "$NETMGR_PIDFILE"

    # 无论PID文件是否存在，都清理旧版/失配PID留下的网络管理器孤儿进程。
    # 只结束管理器本身，不调用SNAT down，不删除已经建立的临时IP。
    kill_matching_processes "/usr/bin/lan_network_manager.sh"

    # LAN拔出只暂停网络管理器，绝不调用lan_snat.sh down或lan_takeover.sh -r。
    # 已建立的目标网段、临时IP和SNAT由目标网段状态机独立保存。
    runtime_set lan_discovery_status_network_manager="已停止"
    if [ "$was_running" = "1" ]; then
        slog "LAN拔出：停止网络管理器，保留全部临时网段、临时IP和SNAT"
    fi
}

start_tcpdump() {
    iface="$1"

    # 监听程序启动失败时不要每秒重复拉起，避免失败日志刷屏并产生频繁进程创建。
    now="$(date +%s 2>/dev/null)"
    case "$now" in ''|*[!0-9]*) now=0;; esac
    retry_at="$(cat "$TCPDUMP_RETRY_FILE" 2>/dev/null)"
    case "$retry_at" in ''|*[!0-9]*) retry_at=0;; esac
    if [ "$retry_at" -gt 0 ] 2>/dev/null && [ "$now" -lt "$retry_at" ] 2>/dev/null; then
        return 1
    fi

    if tcpdump_running; then
        rm -f "$TCPDUMP_RETRY_FILE"
        runtime_set lan_discovery_status_tcpdump="运行中"
        return 0
    fi
    if [ ! -x /usr/bin/lan_tcpdump_listener.sh ]; then
        runtime_set lan_discovery_status_tcpdump="程序不存在"
        slog "实时二层监听入口程序不存在"
        return 1
    fi
    slog "实时二层监听启动：接口=$iface"
    /usr/bin/lan_tcpdump_listener.sh "$iface" > /tmp/lan_tcpdump_listener.log 2>&1 &
    pid="$!"
    echo "$pid" > "$TCPDUMP_PIDFILE"
    # 子进程可能立即因环境错误退出；给它一个短暂观察窗口，避免监督程序持续重启失败进程。
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$TCPDUMP_PIDFILE"
        printf '%s\n' $((now + 5)) > "$TCPDUMP_RETRY_FILE"
        runtime_set lan_discovery_status_tcpdump="启动失败，5秒后重试"
        return 1
    fi
    rm -f "$TCPDUMP_RETRY_FILE"
    runtime_set lan_discovery_status_tcpdump="运行中"
    return 0
}

stop_tcpdump() {
    if tcpdump_running; then
        pid="$(cat "$TCPDUMP_PIDFILE" 2>/dev/null)"
        slog "实时二层监听停止"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    # 双保险：同时清理监听脚本登记的真实tcpdump子进程，避免旧版孤儿进程继续占CPU。
    if [ -r "$RUNTIME_DIR/lan_tcpdump_child.pid" ]; then
        child_pid="$(cat "$RUNTIME_DIR/lan_tcpdump_child.pid" 2>/dev/null)"
        case "$child_pid" in
            ''|*[!0-9]*) ;;
            *)
                kill "$child_pid" 2>/dev/null
                sleep 1
                kill -0 "$child_pid" 2>/dev/null && kill -9 "$child_pid" 2>/dev/null
                ;;
        esac
        rm -f "$RUNTIME_DIR/lan_tcpdump_child.pid"
    fi
    rm -f "$TCPDUMP_PIDFILE"
    # 兼容已经存在的旧版孤儿监听脚本和tcpdump。
    kill_matching_processes "/usr/bin/lan_tcpdump_listener.sh"
    kill_matching_processes "/usr/bin/lanlisten"
    runtime_set lan_discovery_status_tcpdump="已停止"
}

sync_runtime_status() {
    iface="$1"
    if [ -e "/sys/class/net/$iface" ]; then
        ip4="$(ip -4 addr show dev br0 2>/dev/null | sed -n 's/^[[:space:]]*inet[[:space:]]\+\([^ ]*\).*/\1/p' | head -n 1)"
        [ -n "$ip4" ] || ip4="$(nv lan_ipaddr)"
        mac="$(cat /sys/class/net/br0/address 2>/dev/null)"
        [ -n "$mac" ] || mac="$(cat /sys/class/net/$iface/address 2>/dev/null)"
        [ -n "$ip4" ] || ip4="-"
        [ -n "$mac" ] || mac="-"
        runtime_set lan_discovery_status_ip="$ip4"
        runtime_set lan_discovery_status_mac="$(printf '%s' "$mac" | tr '[:lower:]' '[:upper:]')"
    fi
    if is_link_up "$iface"; then
        runtime_set lan_discovery_status_link="UP"
    else
        runtime_set lan_discovery_status_link="DOWN"
        return
    fi
    [ -f "$DEVICE_DB" ] || : > "$DEVICE_DB"
    count="$(grep -v 'type=SUBNET ' "$DEVICE_DB" 2>/dev/null | grep -v 'type=IP_CONFLICT ' | wc -l | tr -d ' ')"
    case "$count" in ''|*[!0-9]*) count=0;; esac
    runtime_set lan_discovery_status_count="$count"
    if [ "$(cfg lan_discovery_discover_enable 1)" != "1" ]; then
        runtime_set lan_discovery_status_state="设备发现未启用"
    elif tcpdump_running; then
        runtime_set lan_discovery_status_state="实时监听+周期主动发现"
    elif ps 2>/dev/null | grep -q '[c]amdiscover'; then
        runtime_set lan_discovery_status_state="持续设备发现"
    elif ps 2>/dev/null | grep -q '[d]hcpdetect'; then
        runtime_set lan_discovery_status_state="DHCP检测"
    fi
    if [ -f /tmp/dhcpdetect_lan.log ]; then
        line="$(grep -m1 '^\[dhcpdetect\] DHCP server found' /tmp/dhcpdetect_lan.log 2>/dev/null)"
        gateway="$(printf '%s\n' "$line" | sed -n 's/.* gateway=\([^ ]*\).*/\1/p')"
        server="$(printf '%s\n' "$line" | sed -n 's/.* server=\([^ ]*\).*/\1/p')"
        if [ -n "$gateway" ] && [ "$gateway" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="网关 $gateway"
        elif [ -n "$server" ] && [ "$server" != "-" ]; then
            runtime_set lan_discovery_status_dhcp="DHCP服务器 $server（未提供网关）"
        elif grep -q '\[dhcpdetect\].*no DHCP server reply' /tmp/dhcpdetect_lan.log 2>/dev/null; then
            runtime_set lan_discovery_status_dhcp="未发现DHCP"
        fi
    fi
    last="$(tail -n 1 "$LOG_FILE" 2>/dev/null | sed -n 's/^\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\) .*/\1/p')"
    [ -n "$last" ] && runtime_set lan_discovery_status_last="$last" || runtime_set lan_discovery_status_last="$(date '+%H:%M:%S')"
}

start_worker() {
    iface="$1"
    if worker_running; then
        runtime_set lan_discovery_status_worker="运行中"
        return 0
    fi
    if [ -d "$WORKER_LOCKDIR" ]; then
        stale=""
        [ -r "$WORKER_LOCKDIR/pid" ] && stale="$(cat "$WORKER_LOCKDIR/pid" 2>/dev/null)"
        case "$stale" in
            ''|*[!0-9]*) rmdir "$WORKER_LOCKDIR" 2>/dev/null;;
            *)
                if ! kill -0 "$stale" 2>/dev/null; then rmdir "$WORKER_LOCKDIR" 2>/dev/null; fi
                ;;
        esac
        [ -d "$WORKER_LOCKDIR" ] && {
            runtime_set lan_discovery_status_worker="已有工作进程"
            return 0
        }
    fi
    if [ ! -x /usr/bin/lan_autodiscover.sh ]; then
        runtime_set lan_discovery_status_worker="程序不存在"
        return 1
    fi
    slog "发现工作进程启动：接口=$iface"
    /usr/bin/lan_autodiscover.sh > /tmp/lan_autodiscover_worker.log 2>&1 &
    echo "$!" > "$PIDFILE"
    runtime_set lan_discovery_status_worker="运行中"
    return 0
}

stop_worker() {
    was_running=0
    if worker_running; then
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        was_running=1
        slog "发现工作进程停止"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
    fi
    # 无论PID文件是否存在，都清理已知的Q7 LAN发现脚本实例。
    if [ "$was_running" = "1" ] || [ -d "$WORKER_LOCKDIR" ]; then
        kill_matching_processes "/usr/bin/lan_autodiscover.sh"
        killall camdiscover 2>/dev/null
        killall arpscan 2>/dev/null
        killall dhcpdetect 2>/dev/null
        killall lanhealth 2>/dev/null
    fi
    rm -f "$PIDFILE"
    rmdir "$WORKER_LOCKDIR" 2>/dev/null
    runtime_set lan_discovery_status_worker="已停止"
    rm -f /tmp/lan_discovery_runtime/lanhealth.pid
    runtime_set lan_discovery_status_health="未监视"
    runtime_set lan_discovery_status_broadcast="0"
    runtime_set lan_discovery_status_loop="0"
}

last_enable="-1"
last_iface=""
last_link="-1"
last_status_sync=0
set_supervisor_status "运行中"
runtime_set lan_discovery_status_worker="已停止"
runtime_set lan_discovery_status_network_manager="已停止"
runtime_set lan_discovery_status_tcpdump="已停止"
runtime_set lan_discovery_status_health="未监视"

while :; do
    enable="$(cfg lan_discovery_enable 0)"
    iface="$(cfg lan_discovery_ifname eth2.1)"
    if [ "$iface" != "$last_iface" ]; then
        last_iface="$iface"
        last_link="-1"
        runtime_set lan_discovery_status_if="$iface"
        slog "监听接口：$iface"
    fi
    if [ "$enable" != "$last_enable" ]; then
        last_enable="$enable"
        last_link="-1"
        if [ "$enable" = "1" ]; then
            runtime_set lan_discovery_status_enable="已启用"
            slog "LAN监听已启用"
        fi
    fi

    if [ "$enable" != "1" ]; then
        runtime_set lan_discovery_status_enable="已禁用"
        runtime_set lan_discovery_status_state="LAN监听已禁用"
        # 禁用状态下每轮都执行兜底清理，防止旧版PID失配或孤儿进程残留。
        stop_worker
        stop_tcpdump
        stop_network_manager
        sleep 1
        continue
    fi

    if [ -e "/sys/class/net/$iface" ]; then
        if is_link_up "$iface"; then link=1; else link=0; fi
    else
        link=0
    fi

    if [ "$link" != "$last_link" ]; then
        last_link="$link"
        if [ "$link" = "1" ]; then
            runtime_set lan_discovery_status_link="UP"
            runtime_set lan_discovery_status_state="DHCP检测"
            slog "LAN口已插入：接口=$iface"
            # 网络管理器、实时二层监听和周期主动发现同时工作。
            start_network_manager "$iface"
            start_tcpdump "$iface"
            start_worker "$iface"
        else
            runtime_set lan_discovery_status_link="DOWN"
            runtime_set lan_discovery_status_state="LAN拔出：保留现有临时网段/SNAT"
            runtime_set lan_discovery_status_dhcp="未检测"
            slog "LAN口已拔出：暂停发现，保留现有临时网段/SNAT"
            stop_worker
            stop_tcpdump
            stop_network_manager
        fi
    fi

    if [ "$link" = "1" ]; then
        start_network_manager "$iface"
        start_tcpdump "$iface"
        start_worker "$iface"
    fi
    now_status="$(date +%s 2>/dev/null)"
    case "$now_status" in ''|*[!0-9]*) now_status=0;; esac
    if [ "$last_status_sync" = "0" ] || [ $((now_status - last_status_sync)) -ge 10 ] 2>/dev/null; then
        sync_runtime_status "$iface"
        last_status_sync="$now_status"
    fi
    set_supervisor_status "运行中"
    sleep 1
done
