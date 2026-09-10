from pathlib import Path


def replace_once(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"未找到需要修改的内容：{label}")
    return text.replace(old, new, 1)


# ============================================================
# 网络管理：目标网段变化时，先完整撤销旧接管和旧SNAT，再建立新状态。
# ============================================================
manager_path = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
manager = manager_path.read_text()

old_anchor = '''    current_target="$(cat "$RUNTIME_DIR/lan_discovery_status_target_network" 2>/dev/null)"
    current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"
    address_ready=0
'''
new_anchor = '''    current_target="$(cat "$RUNTIME_DIR/lan_discovery_status_target_network" 2>/dev/null)"
    current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"

    # 以实际接管状态为准判断目标是否已经切换，不能只相信WebUI状态文件。
    takeover_file="$RUNTIME_DIR/lan_takeover.state"
    takeover_network="$(sed -n 's/^network=//p' "$takeover_file" 2>/dev/null | head -n 1)"
    takeover_ip="$(sed -n 's/^ip=//p' "$takeover_file" 2>/dev/null | head -n 1)"
    if [ -n "$takeover_network" ] && [ "$takeover_network" != "$target_net" ]; then
        runtime_set lan_discovery_status_state "目标网段切换：清理旧SNAT和临时IP"
        [ -x /usr/bin/lan_snat.sh ] && /usr/bin/lan_snat.sh down >> "$LOG_FILE" 2>&1 || :
        [ -x /usr/bin/lan_takeover.sh ] && /usr/bin/lan_takeover.sh -r >> "$LOG_FILE" 2>&1 || :
        current_target=""
        current_ip=""
        runtime_set lan_discovery_status_target_network ""
        runtime_set lan_discovery_status_target_ip ""
        runtime_set lan_discovery_status_target_iface ""
        log "检测到目标网段变化：${takeover_network} -> ${target_net}，已撤销旧接管"
    elif [ -n "$takeover_network" ] && [ "$takeover_network" = "$target_net" ] && [ -n "$takeover_ip" ]; then
        current_target="$target_net/24"
        current_ip="$takeover_ip"
    fi

    address_ready=0
'''
manager = replace_once(manager, old_anchor, new_anchor, '目标网段切换清理')

# 只有apply_target真正成功后才更新last状态，失败时下一轮继续尝试。
old_last = '''            apply_target "$target"
            last_mode="$mode"
            last_target="$target"
'''
new_last = '''            if apply_target "$target"; then
                last_mode="$mode"
                last_target="$target"
            else
                log "目标网段应用失败，本轮不更新缓存状态，下一轮继续重试"
            fi
'''
manager = replace_once(manager, old_last, new_last, '失败后保留重试状态')

# 无DHCP模式每轮均检查SNAT；check脚本负责发现状态不一致时先清理旧规则。
old_check = '''        elif [ "$mode" = "NO_DHCP" ]; then
            # 运行过程中其他Padavan组件可能刷新iptables；这里只补规则，
            # 不调用takeover、不更换临时IP，也不删除现有SNAT规则。
            check_snat "$target" "$localnet" || log "SNAT周期检查发现规则缺失或补回失败"
        fi
'''
new_check = '''        elif [ "$mode" = "NO_DHCP" ]; then
            # 周期检查同时负责发现旧目标网段/旧源地址并触发SNAT切换。
            check_snat "$target" "$localnet" || log "SNAT周期检查发现规则缺失或切换失败"
        fi
'''
manager = replace_once(manager, old_check, new_check, 'SNAT周期状态检查')
manager_path.write_text(manager)


# ============================================================
# SNAT：check/up均以STATE_FILE作为唯一当前状态；参数变化先清理旧规则。
# ============================================================
snat_path = Path('trunk/user/lan_autodiscover/lan_snat.sh')
snat = snat_path.read_text()

old_transition = '''if [ "$1" = "up" ]; then
    # 只有目标网段、临时源地址或本地网段真正变化时才清理旧规则。
    # 相同参数重复up直接保持现有conntrack和iptables规则不动。
    same_state=0
    if [ -r "$STATE_FILE" ]; then
        old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"
        old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"
        old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
        [ "$old_target_net" = "$TARGET_NET" ] && [ "$old_target_ip" = "$TARGET_IP" ] && [ "$old_lan_net" = "$LAN_NET" ] && same_state=1
    fi

    if [ "$same_state" != "1" ]; then
        cleanup
    fi
fi
'''
new_transition = '''# 无论是up还是周期check，只要发现当前SNAT状态与目标参数不一致，
# 就先撤销旧规则，再建立新规则；避免旧目标规则和新目标规则并存。
same_state=0
if [ -r "$STATE_FILE" ]; then
    old_target_net="$(sed -n 's/^target_net=//p' "$STATE_FILE" | head -n 1)"
    old_target_ip="$(sed -n 's/^target_ip=//p' "$STATE_FILE" | head -n 1)"
    old_lan_net="$(sed -n 's/^lan_net=//p' "$STATE_FILE" | head -n 1)"
    [ "$old_target_net" = "$TARGET_NET" ] && [ "$old_target_ip" = "$TARGET_IP" ] && [ "$old_lan_net" = "$LAN_NET" ] && same_state=1
fi

if [ "$same_state" != "1" ]; then
    cleanup
fi
'''
snat = replace_once(snat, old_transition, new_transition, 'SNAT状态切换')

old_write = '''if [ "$1" = "up" ]; then
    {
        printf 'lan_net=%s\\n' "$LAN_NET"
        printf 'target_net=%s\\n' "$TARGET_NET"
        printf 'target_ip=%s\\n' "$TARGET_IP"
        printf 'iface=br0\\n'
    } > "$STATE_FILE"
    log "SNAT已启用：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
else
    log "SNAT规则检查并补齐：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
fi
'''
new_write = '''{
    printf 'lan_net=%s\\n' "$LAN_NET"
    printf 'target_net=%s\\n' "$TARGET_NET"
    printf 'target_ip=%s\\n' "$TARGET_IP"
    printf 'iface=br0\\n'
} > "$STATE_FILE"
if [ "$1" = "up" ]; then
    log "SNAT已启用：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
else
    log "SNAT状态检查并同步：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
fi
'''
snat = replace_once(snat, old_write, new_write, 'SNAT状态文件同步')
snat_path.write_text(snat)
