#!/bin/sh
# Q7 LAN DHCP主动探测。
# 使用系统自带udhcpc发送一次DHCP请求。
# 回调脚本只记录服务器、租约地址、子网掩码和网关，不执行任何网卡配置，
# 因此不会改变Q7当前LAN地址、路由或DNS。

iface="$1"
timeout="$2"
result_file="$3"

[ -n "$iface" ] || iface=br0
[ -n "$timeout" ] || timeout=3
[ -n "$result_file" ] || result_file=/tmp/lan_discovery_runtime/dhcp_probe.result

RUNTIME_DIR="$(dirname "$result_file")"
mkdir -p "$RUNTIME_DIR"

callback="$RUNTIME_DIR/.dhcp_probe_callback.sh"
tmp="$RUNTIME_DIR/.dhcp_probe.result.tmp"

cat > "$callback" <<'EOF'
#!/bin/sh
result_file="$DHCP_RESULT_FILE"
case "$1" in
    bound|renew)
        {
            printf 'result=FOUND\n'
            printf 'ip=%s\n' "$ip"
            printf 'subnet=%s\n' "$subnet"
            printf 'router=%s\n' "$router"
            printf 'serverid=%s\n' "$serverid"
        } > "${result_file}.tmp" &&
            mv -f "${result_file}.tmp" "$result_file"
        ;;
esac
exit 0
EOF
chmod +x "$callback"

rm -f "$result_file" "$tmp"
DHCP_RESULT_FILE="$result_file" \
    udhcpc -i "$iface" -n -q -t 1 -T "$timeout" -s "$callback" \
    >/tmp/lan_dhcp_probe.log 2>&1

rc=$?
rm -f "$callback" "$tmp"

if [ "$rc" = "0" ] && [ -s "$result_file" ]; then
    exit 0
fi

rm -f "$result_file"
exit 1
