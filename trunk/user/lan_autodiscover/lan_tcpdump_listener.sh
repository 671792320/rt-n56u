#!/bin/sh
# Q7 LAN实时二层监听入口。
# 低CPU模式：使用原生C程序lanlisten直接监听AF_PACKET。
# 不再创建FIFO，也不再由Shell逐包调用sed/awk/ip/logger。

RUNTIME_DIR=/tmp/lan_discovery_runtime
IFACE="${1:-eth2.1}"
EVENT_FILE="$RUNTIME_DIR/tcpdump_discovery_events.txt"
LISTENER=/usr/bin/lanlisten

mkdir -p "$RUNTIME_DIR"

if [ ! -x "$LISTENER" ]; then
    logger -t lan-autodiscover "【二层监听】监听程序不存在：$LISTENER"
    exit 1
fi

if [ ! -e "/sys/class/net/$IFACE" ]; then
    logger -t lan-autodiscover "【二层监听】监听接口不存在：$IFACE"
    exit 1
fi

touch "$EVENT_FILE" 2>/dev/null || {
    logger -t lan-autodiscover "【二层监听】无法创建事件文件：$EVENT_FILE"
    exit 1
}

exec "$LISTENER" -i "$IFACE" -e "$EVENT_FILE"
