#!/usr/bin/env python3
# Q7 WebUI多目标网段显示补丁。
# 后端将全部“目标网段/24|临时IP”写入lan_discovery_status_targets，
# 本脚本把该状态接到现有LAN发现页面，确保多个目标网段同时显示。

from pathlib import Path

PAGE = Path("trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"Q7 WebUI补丁失败：找不到{label}锚点")
    return text.replace(old, new, 1)


def main() -> None:
    if not PAGE.exists():
        raise SystemExit(f"Q7 WebUI补丁失败：文件不存在：{PAGE}")

    text = PAGE.read_text(encoding="utf-8")

    # 幂等执行：重复运行时不再次插入相同代码。
    if "function render_target_states(s)" not in text:
        text = replace_once(
            text,
            "devices:section(data,'---DEVICES---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')};}",
            "devices:section(data,'---DEVICES---','---TARGETS---'),targets:section(data,'---TARGETS---','---CUSTOM---'),custom:section(data,'---CUSTOM---','')};}",
            "parse_data目标状态分段",
        )

        target_function = """function render_target_states(s){var box=document.getElementById('target_states');if(!box)return;var raw=String(s||'').replace(/\\r/g,'');var arr=raw.split(';');var rows=[];for(var i=0;i<arr.length;i++){var line=String(arr[i]||'').replace(/^\\s+|\\s+$/g,'');if(!line)continue;var p=line.split('|');if(p.length<2)continue;var net=String(p[0]||'').trim();var ip=String(p[1]||'').trim();if(!/^((\\d{1,3}\\.){3}\\d{1,3})\\/24$/.test(net)||!/^((\\d{1,3}\\.){3}\\d{1,3})$/.test(ip))continue;rows.push({net:net,ip:ip});}rows.sort(function(a,b){return ip_key(a.net.split('/')[0])-ip_key(b.net.split('/')[0]);});if(!rows.length){box.innerHTML='<div class=\"muted\">当前没有生效的目标网段</div>';return;}var html='<table class=\"table table-bordered table-condensed target-state-table\"><thead><tr><th>目标网段</th><th>临时IP（SNAT地址）</th><th>状态</th></tr></thead><tbody>';for(var j=0;j<rows.length;j++){html+='<tr><td>'+rows[j].net+'</td><td><strong>'+rows[j].ip+'</strong></td><td>已启用（SNAT）</td></tr>';}html+='</tbody></table>';box.innerHTML=html;}\n"""
        text = replace_once(text, "function render_custom_hint()", target_function + "function render_custom_hint()", "render_target_states函数位置")

        text = replace_once(
            text,
            "render_devices(o.devices);render_log(o.log);",
            "render_devices(o.devices);render_target_states(o.targets);render_log(o.log);",
            "refresh_data目标状态刷新",
        )

        target_html = """<h4 style=\"margin-top:12px\">目标网段与临时IP（SNAT地址）</h4><div class=\"alert alert-info\">下面每一行对应一个实际发现并接管的目标/24网段。临时IP就是该网段对应的SNAT源地址；多个目标网段会同时保留、同时显示。</div><div id=\"target_states\"><div class=\"muted\">等待目标网段状态...</div></div>\n"""
        text = replace_once(text, '<h4>IP占用情况 ', target_html + '<h4>IP占用情况 ', "目标网段状态区域")

        text = replace_once(
            text,
            ".hidden-builtin{display:none!important}",
            ".target-state-table td{white-space:nowrap}.hidden-builtin{display:none!important}",
            "目标状态表CSS",
        )

    PAGE.write_text(text, encoding="utf-8")

    checks = [
        "---TARGETS---",
        "function render_target_states(s)",
        "render_target_states(o.targets)",
        "临时IP（SNAT地址）",
        "id=\"target_states\"",
    ]
    missing = [item for item in checks if item not in text]
    if missing:
        raise SystemExit("Q7 WebUI补丁校验失败：" + ", ".join(missing))

    print("Q7 WebUI已支持多目标网段临时IP/SNAT逐行显示。")


if __name__ == "__main__":
    main()
