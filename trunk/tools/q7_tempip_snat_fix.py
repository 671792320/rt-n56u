from pathlib import Path
import re


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"未找到需要修改的内容：{label}")
    return text.replace(old, new, 1)


# ============================================================
# LAN网络管理：把临时目标IP同步到运行时NVRAM，供WebUI直接显示。
# 不执行nvram commit，因此仍然是临时状态；拔线时立即清空。
# ============================================================
p = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
s = p.read_text()
s = replace_once(
    s,
    '''    runtime_set lan_discovery_status_target_network ""
    runtime_set lan_discovery_status_target_ip ""
    runtime_set lan_discovery_status_target_iface ""
''',
    '''    runtime_set lan_discovery_status_target_network ""
    runtime_set lan_discovery_status_target_ip ""
    runtime_set lan_discovery_status_target_iface ""
    nvram set lan_discovery_status_target_network="" 2>/dev/null || :
    nvram set lan_discovery_status_target_ip="" 2>/dev/null || :
    nvram set lan_discovery_status_target_iface="" 2>/dev/null || :
''',
    '清理临时IP状态',
)
s = replace_once(
    s,
    '''    {
        printf 'mode=%s\\n' "$mode"
        printf 'local_net=%s\\n' "$localnet"
        printf 'target_net=%s\\n' "$target_net"
        printf 'target_ip=%s\\n' "$current_ip"
    } > "$STATE_FILE"
''',
    '''    {
        printf 'mode=%s\\n' "$mode"
        printf 'local_net=%s\\n' "$localnet"
        printf 'target_net=%s\\n' "$target_net"
        printf 'target_ip=%s\\n' "$current_ip"
    } > "$STATE_FILE"
    # 仅运行时写入NVRAM，WebUI可读取；不执行commit，重启自动消失。
    nvram set lan_discovery_status_target_network="$target_net/24" 2>/dev/null || :
    nvram set lan_discovery_status_target_ip="$current_ip" 2>/dev/null || :
    nvram set lan_discovery_status_target_iface="$BR_IF" 2>/dev/null || :
''',
    '同步临时IP到WebUI',
)

# ============================================================
# SNAT：改为“只补规则，不先删除规则”，并提供check动作。
# ============================================================
p = Path('trunk/user/lan_autodiscover/lan_snat.sh')
s = s.read_text()

# 将原cleanup保留给down/remove专用；up不再先删除规则。
old_case = '''case "$1" in
    down|remove|-r|--remove)
        if [ -z "$IPTABLES" ]; then
            rm -f "$STATE_FILE"
            exit 0
        fi
        cleanup
        exit 0
        ;;
    up)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up 目标网段 目标临时IP 本地LAN网段；$0 down"
        exit 2
        ;;
esac
'''
new_case = '''case "$1" in
    down|remove|-r|--remove)
        if [ -z "$IPTABLES" ]; then
            rm -f "$STATE_FILE"
            exit 0
        fi
        cleanup
        exit 0
        ;;
    check)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    up)
        TARGET_NET="$2"
        TARGET_IP="$3"
        LAN_NET="$4"
        ;;
    *)
        log "用法：$0 up|check 目标网段 目标临时IP 本地LAN网段；$0 down"
        exit 2
        ;;
esac
'''
s = replace_once(s, old_case, new_case, 'SNAT动作')

old_cleanup_up = '''cleanup

# 允许本机承担路由器职责；即使Padavan其他模块已开启，重复设置也是幂等的。
[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :

rule_add filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
rule_add filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
rule_add nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"
'''
new_cleanup_up = '''# 允许本机承担路由器职责；即使Padavan其他模块已开启，重复设置也是幂等的。
[ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :

# 不再删除后重建：规则存在就保持原样，规则缺失才自动补回。
rule_add filter FORWARD -i br0 -o br0 -s "$LAN_NET/24" -d "$TARGET_NET/24" -j ACCEPT
rule_add filter FORWARD -i br0 -o br0 -s "$TARGET_NET/24" -d "$LAN_NET/24" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
rule_add nat POSTROUTING -s "$LAN_NET/24" -d "$TARGET_NET/24" -o br0 -j SNAT --to-source "$TARGET_IP"

# check只负责确认并补齐规则，不改动状态文件中的源地址。
if [ "$1" = "check" ]; then
    log "SNAT规则检查完成：$LAN_NET/24 -> $TARGET_NET/24，源地址=$TARGET_IP"
    exit 0
fi
'''
s = replace_once(s, old_cleanup_up, new_cleanup_up, 'SNAT稳定补规则')
p.write_text(s)

# ============================================================
# LAN网络管理：每2秒自检一次SNAT；状态文件存在时也不能认为规则一定存在。
# ============================================================
p = Path('trunk/user/lan_autodiscover/lan_network_manager.sh')
s = p.read_text()
old_loop_tail = '''        if [ "$mode:$target" != "$last_mode:$last_target" ] || [ ! -f "$STATE_FILE" ]; then
            apply_target "$target"
            last_mode="$mode"
            last_target="$target"
        fi
    fi

    sleep 2
done
'''
new_loop_tail = '''        if [ "$mode:$target" != "$last_mode:$last_target" ] || [ ! -f "$STATE_FILE" ]; then
            apply_target "$target"
            last_mode="$mode"
            last_target="$target"
        elif [ "$mode" = "NO_DHCP" ]; then
            # 运行过程中如果其他Padavan组件刷新iptables，SNAT会被清掉；这里主动补回。
            current_ip="$(cat "$RUNTIME_DIR/lan_discovery_status_target_ip" 2>/dev/null)"
            [ -n "$current_ip" ] && [ -x /usr/bin/lan_snat.sh ] && \\
                /usr/bin/lan_snat.sh check "$target" "$current_ip" "$localnet" >> "$LOG_FILE" 2>&1 || :
        fi
    fi

    sleep 2
done
'''
s = replace_once(s, old_loop_tail, new_loop_tail, 'SNAT周期自检')
p.write_text(s)

# ============================================================
# WebUI：显示目标临时IP专属颜色，并计入IP占用。
# ============================================================
p = Path('trunk/user/www/n56u_ribbon_fixed/Advanced_LANDiscover_Content.asp')
s = p.read_text()

# initial_status 增加运行时临时目标地址。
old_status = "loop:'<% nvram_get_x(\"\", \"lan_discovery_status_loop\"); %>'"
new_status = old_status + ",target_ip:'<% nvram_get_x(\"\", \"lan_discovery_status_target_ip\"); %>',target_network:'<% nvram_get_x(\"\", \"lan_discovery_status_target_network\"); %>'"
s = replace_once(s, old_status, new_status, 'WebUI临时IP状态')

# 插入临时IP专属样式。
style_marker = '</head>'
style = '''<style>
.ip-cell.ip-target{background:#f0ad4e!important;color:#fff!important;border-color:#eea236!important;font-weight:bold;}
.ip-cell.ip-target:hover{background:#ec971f!important;}
</style>\n'''
s = replace_once(s, style_marker, style + style_marker, '临时IP颜色')

# 用新版矩阵渲染函数替换旧实现。
start = s.find('function render_matrix(byIp){')
end = s.find('function infer_status', start)
if start < 0 or end < 0:
    raise SystemExit('未找到render_matrix函数')
new_render = r'''function render_matrix(byIp){
    var box=document.getElementById('ip_matrix');
    if(!box)return;
    var nets={},targetIp=String(initial_status.target_ip||''),targetNet=String(initial_status.target_network||'');
    for(var k in byIp){
        if(k==='-'||!(/^(\d+\.){3}\d+$/.test(k)))continue;
        var p=k.split('.');
        nets[p[0]+'.'+p[1]+'.'+p[2]+'.0']=1;
    }
    var initialNet=initial_status.ip&&/^(\d+\.){3}\d+$/.test(initial_status.ip)?initial_status.ip.split('.').slice(0,3).join('.')+'.0':'';
    if(initialNet)nets[initialNet]=1;
    if(targetNet&&targetNet.indexOf('/24')>0)nets[targetNet.replace('/24','')]=1;
    var names=[];for(var n in nets)names.push(n);
    names.sort(function(a,b){return ip_key(a)-ip_key(b);});
    if(!names.length){box.innerHTML='<div class="muted">等待发现局域网网段...</div>';return;}
    if(!matrix_selected_net||!nets[matrix_selected_net])matrix_selected_net=(targetNet?targetNet.replace('/24',''):(initialNet&&nets[initialNet]?initialNet:names[0]));
    var prefix=matrix_selected_net.substring(0,matrix_selected_net.lastIndexOf('.')+1);
    if(matrix_selected_ip&&matrix_selected_ip.indexOf(prefix)!==0)matrix_selected_ip='';
    box.innerHTML='';
    var tabs=document.createElement('div');tabs.className='ip-tabs';
    for(var i=0;i<names.length;i++)(function(net){var b=document.createElement('button');b.type='button';b.className='btn btn-small '+(matrix_selected_net===net?'active':'');b.textContent=net+'/24';b.onclick=function(){matrix_selected_net=net;matrix_selected_ip='';render_matrix(byIp);};tabs.appendChild(b);})(names[i]);
    box.appendChild(tabs);
    var used=0,free=0,conflict=0,targetCount=0;
    for(i=1;i<255;i++){
        var ip=ip_from_net(matrix_selected_net,i),cr=byIp[ip],isTarget=(ip===targetIp&&targetNet.replace('/24','')===matrix_selected_net);
        if(cr&&cr.conflict)conflict++;
        else if(cr||isTarget)used++;
        else free++;
        if(isTarget)targetCount++;
    }
    var title=document.createElement('div');title.className='ip-matrix-title';title.innerHTML='<strong>'+matrix_selected_net+'/24</strong>　已使用 <b>'+used+'</b>　未发现 <b>'+free+'</b>　冲突 <b class="conflict-text">'+conflict+'</b>　临时IP <b>'+targetCount+'</b>';box.appendChild(title);
    var legend=document.createElement('div');legend.className='ip-legend';legend.innerHTML='<span><i class="ip-cell ip-used"></i>已使用</span><span><i class="ip-cell ip-free"></i>未发现</span><span><i class="ip-cell ip-self"></i>本机</span><span><i class="ip-cell ip-target"></i>目标LAN临时IP</span><span><i class="ip-cell ip-conflict"></i>IP冲突</span>';box.appendChild(legend);
    var grid=document.createElement('div');grid.className='ip-grid';
    for(i=1;i<255;i++){
        ip=ip_from_net(matrix_selected_net,i);var r=byIp[ip],isTarget=(ip===targetIp&&targetNet.replace('/24','')===matrix_selected_net),cell=document.createElement('button');cell.type='button';
        cell.className='ip-cell '+(isTarget?'ip-target':(r?(r.conflict?'ip-conflict':(ip===initial_status.ip?'ip-self':'ip-used')):'ip-free'));
        if(ip===matrix_selected_ip)cell.className+=' ip-selected';cell.textContent=i;
        if(isTarget)cell.title=ip+'\n类型：目标LAN临时IP\n用途：无DHCP模式SNAT源地址';
        else if(r)cell.title=ip+'\n状态：'+(r.conflict?'IP冲突':'已使用')+'\n协议：'+(r.protocols.length?r.protocols.join(' / '):'-')+'\nMAC：'+(r.conflict&&r.macs?r.macs.join(' / '):r.mac)+'\n'+(r.info||'-');
        else cell.title=ip+'\n当前未发现响应';
        cell.onclick=(function(ip,row,target){return function(){matrix_selected_ip=ip;var d=document.getElementById('ip_detail');if(d)d.textContent=target?(ip+' ｜ 目标LAN临时IP ｜ 无DHCP模式SNAT源地址'):(row?(ip+' ｜ '+(row.conflict?'IP冲突':'已使用')+' ｜ '+(row.protocols.length?row.protocols.join(' / '):'-')+' ｜ MAC '+(row.conflict&&row.macs?row.macs.join(' / '):row.mac)+(row.info&&row.info!=='-'?' ｜ '+row.info:'')):(ip+' ｜ 当前未发现响应（不代表绝对不存在设备）'));var cs=document.querySelectorAll('#ip_matrix .ip-grid .ip-cell');for(var q=0;q<cs.length;q++)cs[q].className=cs[q].className.replace(/\s*ip-selected/g,'');this.className+=' ip-selected';};})(ip,r,isTarget);grid.appendChild(cell);
    }
    box.appendChild(grid);var detail=document.createElement('div');detail.id='ip_detail';detail.className='ip-detail '+(matrix_selected_ip?'':'muted');var sr=matrix_selected_ip?byIp[matrix_selected_ip]:null;
    if(matrix_selected_ip&&matrix_selected_ip===targetIp&&targetNet.replace('/24','')===matrix_selected_net)detail.textContent=targetIp+' ｜ 目标LAN临时IP ｜ 无DHCP模式SNAT源地址';
    else if(sr)detail.textContent=matrix_selected_ip+' ｜ '+(sr.conflict?'IP冲突':'已使用')+' ｜ '+(sr.protocols.length?sr.protocols.join(' / '):'-')+' ｜ MAC '+(sr.conflict&&sr.macs?sr.macs.join(' / '):sr.mac)+(sr.info&&sr.info!=='-'?' ｜ '+sr.info:'');
    else if(matrix_selected_ip)detail.textContent=matrix_selected_ip+' ｜ 当前未发现响应（不代表绝对不存在设备）';else detail.textContent='点击IP方块查看详细信息';box.appendChild(detail);
}
'''
s = s[:start] + new_render + s[end:]
p.write_text(s)

print('Q7临时IP、SNAT稳定性和IP矩阵修复已生成')
