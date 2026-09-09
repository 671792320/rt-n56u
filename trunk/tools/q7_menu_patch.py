from pathlib import Path

p = Path("trunk/user/www/n56u_ribbon_fixed/state.js")
s = p.read_text()

# 在现有应用菜单之后增加独立的LAN发现菜单项。
if 'menuL2_title.push("LAN发现");' not in s:
    marker = "\n\nmenuL2_link  = new Array("
    if marker not in s:
        raise SystemExit("未找到LAN发现菜单标题插入位置")
    s = s.replace(
        marker,
        '\n\nmenuL2_title.push("LAN发现");' + marker,
        1,
    )

# 为刚加入的菜单项增加对应页面入口，保持标题与链接索引一致。
if 'menuL2_link.push("Advanced_LANDiscover_Content.asp");' not in s:
    marker = "\n\n//Level 1 Menu in Gateway, Router mode"
    if marker not in s:
        raise SystemExit("未找到LAN发现菜单链接插入位置")
    s = s.replace(
        marker,
        '\n\nmenuL2_link.push("Advanced_LANDiscover_Content.asp");' + marker,
        1,
    )

p.write_text(s)
