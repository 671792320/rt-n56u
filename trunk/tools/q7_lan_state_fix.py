from pathlib import Path


def replace_once(text, old, new, label, required=False):
    if old not in text:
        if required:
            raise SystemExit(f"未找到需要修复的内容：{label}")
        return text
    return text.replace(old, new, 1)


# ============================================================
# 后端：Ping兼容、INFO去除动态状态、禁止把网段地址当设备。
# ============================================================
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

# LAN发现当前按/24显示，.0和.255是网段/广播地址，不作为设备主机记录。
old_is_ip = '''is_ip() {
    case "$1" in *.*.*.*) return 0;; *) return 1;; esac
}
'''
new_is_ip = '''is_ip() {
    ip="$1"
    case "$ip" in *.*.*.*) ;; *) return 1;; esac
    last="${ip##*.}"
    case "$last" in
        ''|*[!0-9]*) return 1;;
        0|255) return 1;;
    esac
    return 0
}
'''
s = replace_once(s, old_is_ip, new_is_ip, "排除网段和广播地址")

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
            # INFO只保存设备描述；历史轮次附加的Ping/STATUS/PING/MISS一律剥离。
            detail="$(printf '%s\\n' "$detail" | sed 's/^Ping：[[:space:]]*[^；]*；[[:space:]]*//;s/[[:space:]]*STATUS=[^ ]*//g;s/[[:space:]]*PING=[^ ]*//g;s/[[:space:]]*MISS=[0-9][0-9]*//g;s/[[:space:]]*$//')"
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


# ============================================================
# WebUI：信息栏只显示中文设备描述，Ping只保留在独立Ping列。
# ============================================================
p = Path("trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp")
s = p.read_text()

# 增加统一的信息栏清洗函数，兼容已经存在于后端缓存中的旧状态字符串。
marker = "function mac_norm(v){"
helper = '''function clean_device_info(v){
    var s=String(v==null?'':v);
    s=s.replace(/^Ping：[[:space:]]*[^；]*；[[:space:]]*/,'');
    s=s.replace(/[[:space:]]*STATUS=[^ ]+/g,'');
    s=s.replace(/[[:space:]]*PING=[^ ]+/g,'');
    s=s.replace(/[[:space:]]*MISS=[0-9]+/g,'');
    s=s.replace(/[[:space:]]*Ping：[[:space:]]*[^；]+；/g,'');
    s=s.replace(/^设备可达$/,'');
    s=s.replace(/^[；;、，,[:space:]]+|[；;、，,[:space:]]+$/g,'');
    return s||'-';
}
'''
if 'function clean_device_info(v){' not in s:
    s = replace_once(s, marker, helper + marker, "WebUI信息清洗", required=True)

# 解析DEVICE记录时立即清洗INFO，避免旧缓存继续污染页面。
old_info = "var info=(z.match(/INFO=(.*)$/)||[])[1]||'-';"
new_info = "var info=clean_device_info((z.match(/INFO=(.*)$/)||[])[1]||'-');"
s = replace_once(s, old_info, new_info, "WebUI设备信息", required=True)

# 最终渲染前再清洗一次，确保历史缓存/兼容记录不会进入信息栏。
old_vals = "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];"
new_vals = "var vals=[st,protocol,r.ip,displayMac,r.ping||'不可用',clean_device_info(r.info||'-')];"
s = replace_once(s, old_vals, new_vals, "WebUI设备列", required=False)

# 表头与空表列数同步；若前一补丁已经加入Ping列则这里保持幂等。
old_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>'
new_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>'
s = replace_once(s, old_header, new_header, "WebUI表头", required=False)
s = s.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)

p.write_text(s)
