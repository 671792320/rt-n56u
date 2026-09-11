#!/usr/bin/env python3
# Q7 LAN发现页原生Padavan WebUI兼容修复。
# 只补齐Padavan原有页面初始化方式，不改变Q7后台数据模型。

from pathlib import Path

PAGE = Path("trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"Q7 LAN发现页修复失败：找不到{label}")
    return text.replace(old, new, 1)


def main() -> None:
    if not PAGE.exists():
        raise SystemExit(f"Q7 LAN发现页修复失败：文件不存在：{PAGE}")

    text = PAGE.read_text(encoding="utf-8")

    # Padavan官方页面：itoggle必须在document.ready中显式初始化。
    if "init_itoggle('lan_discovery_enable'" not in text:
        init_block = """\n$j(document).ready(function() {\n\tinit_itoggle('lan_discovery_enable');\n\tinit_itoggle('lan_discovery_dhcp_enable');\n\tinit_itoggle('lan_discovery_discover_enable');\n});\n"""
        text = replace_once(text, "var $j=jQuery.noConflict();", "var $j=jQuery.noConflict();" + init_block, "Padavan itoggle初始化位置")

    # Padavan官方页面的initial()会先执行load_body()，完成公共页面状态初始化。
    if "function initial(){" in text and "function initial(){show_banner(1);show_menu(5,3,1);show_footer();load_body();" not in text:
        old = "function initial(){show_banner(1);show_menu(5,3,1);show_footer();"
        if old in text:
            text = text.replace(old, old + "load_body();", 1)
        else:
            marker = "show_footer();"
            idx = text.find("function initial(){")
            pos = text.find(marker, idx)
            if pos < 0:
                raise SystemExit("Q7 LAN发现页修复失败：找不到initial()/show_footer()")
            end = pos + len(marker)
            text = text[:end] + "\n\tload_body();" + text[end:]

    # 目标数据必须与设备数据分段解析，保持Data.asp的EJ分区结构。
    old_parse = "devices:section(data,'---DEVICES---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')"
    new_parse = "devices:section(data,'---DEVICES---','---TARGETS---'),targets:section(data,'---TARGETS---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')"
    if "targets:section(data,'---TARGETS---','---CUSTOM---')" not in text and old_parse in text:
        text = text.replace(old_parse, new_parse, 1)

    # 设备表保持6列：状态、协议、IP、MAC、Ping、信息。
    old_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>信息</th>'
    new_header = '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>'
    if new_header not in text and old_header in text:
        text = text.replace(old_header, new_header, 1)
    text = text.replace('colspan="5" class="muted">暂无设备', 'colspan="6" class="muted">暂无设备', 1)

    # 兼容旧的5列数据数组；若上游修复已加入Ping列则保持原状。
    old_vals = "var vals=[st,protocol,r.ip,displayMac,r.info||'-'];"
    new_vals = "var vals=[st,protocol,r.ip,displayMac,r.ping||'检测中',r.info||'-'];"
    if old_vals in text and new_vals not in text:
        text = text.replace(old_vals, new_vals, 1)

    # 确保运行态目标状态在每次刷新时渲染。
    if "function render_target_states(s)" in text and "render_target_states(o.targets)" not in text:
        text = replace_once(text, "render_devices(o.devices);render_log(o.log);", "render_devices(o.devices);render_target_states(o.targets);render_log(o.log);", "目标状态刷新调用")

    # 统一官方Padavan页面的fake checkbox结构，保留隐藏radio作为真正提交字段。
    for name in ("lan_discovery_enable", "lan_discovery_dhcp_enable", "lan_discovery_discover_enable"):
        old = f'<input type="checkbox" id="{name}_fake" <% nvram_match_x("", "{name}", "1", "value=1 checked"); %>>'
        new = f'<input type="checkbox" id="{name}_fake" <% nvram_match_x("", "{name}", "1", "value=1 checked"); %><% nvram_match_x("", "{name}", "0", "value=0"); %>>'
        if old in text:
            text = text.replace(old, new, 1)

    PAGE.write_text(text, encoding="utf-8")

    required = [
        "init_itoggle('lan_discovery_enable');",
        "init_itoggle('lan_discovery_dhcp_enable');",
        "init_itoggle('lan_discovery_discover_enable');",
        "load_body();",
        "Advanced_LANDiscover_Data.asp",
        "refresh_data();",
        "devices:section(data,'---DEVICES---','---TARGETS---')",
        "targets:section(data,'---TARGETS---','---CUSTOM---')",
        '<th>状态</th><th>协议</th><th>IP</th><th>MAC</th><th>Ping</th><th>信息</th>',
    ]
    missing = [item for item in required if item not in text]
    if missing:
        raise SystemExit("Q7 LAN发现页原生修复校验失败：" + ", ".join(missing))

    print("Q7 LAN发现页已按Padavan原生WebUI初始化方式修复。")


if __name__ == "__main__":
    main()
