from pathlib import Path


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"未找到需要修复的内容：{label}")
    return text.replace(old, new, 1)


p = Path("trunk/user/lan_autodiscover/lan_device_state.sh")
s = p.read_text()

# Ping兼容：优先使用PATH中的ping，再尝试常见绝对路径和BusyBox applet。
old_ping = '''ping_device() {
    ip="$1"
    if ! command -v ping >/dev/null 2>&1; then
        printf '不可用'
        return 2
    fi
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        printf '通'
        return 0
    fi
    printf '不通'
    return 1
}
'''
new_ping = '''ping_device() {
    ip="$1"
    ping_bin=""

    for candidate in /bin/ping /sbin/ping /usr/bin/ping /usr/sbin/ping; do
        if [ -x "$candidate" ]; then
            ping_bin="$candidate"
            break
        fi
    done

    if [ -z "$ping_bin" ] && command -v ping >/dev/null 2>&1; then
        ping_bin="$(command -v ping)"
    fi

    if [ -n "$ping_bin" ]; then
        if "$ping_bin" -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            printf '通'
            return 0
        fi
        printf '不通'
        return 1
    fi

    if command -v busybox >/dev/null 2>&1; then
        if busybox ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            printf '通'
            return 0
        fi
        # BusyBox存在但没有ping applet时，继续标记为不可用。
        if busybox ping --help >/dev/null 2>&1; then
            printf '不通'
            return 1
        fi
    fi

    printf '不可用'
    return 2
}
'''
s = replace_once(s, old_ping, new_ping, "Ping探测")

# 从历史DEVICE记录取INFO时，只保留真正的设备描述，绝不再次保存动态状态字段。
old_detail = '''            detail="$(printf '%s\\n' "$row" | sed -n 's/.*INFO=\\(.*\\)$/\\1/p')"
            case "$detail" in
                ''|-) ;;
                *)
                    case "$info" in
                        '') info="$detail";;
                    esac
                    ;;
            esac
'''
new_detail = '''            detail="$(printf '%s\\n' "$row" | sed -n 's/.*INFO=\\(.*\\)$/\\1/p')"
            # INFO只保存设备协议描述；历史轮次附加的Ping/STATUS/MISS一律剥离。
            detail="$(printf '%s\\n' "$detail" | sed 's/^Ping：[[:space:]]*[^；]*；[[:space:]]*//;s/[[:space:]]*STATUS=.*$//;s/[[:space:]]*PING=.*$//;s/[[:space:]]*MISS=.*$//')"
            case "$detail" in
                ''|-|设备可达) ;;
                *)
                    case "$info" in
                        '') info="$detail";;
                    esac
                    ;;
            esac
'''
s = replace_once(s, old_detail, new_detail, "INFO历史状态清理")

p.write_text(s)
