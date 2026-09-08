function init_itoggle(id,func)
{
    var obj_f = $j('#'+id+'_fake');
    var obj_0 = $j('#'+id+'_0');
    var obj_1 = $j('#'+id+'_1');

    $j('#'+id+'_on_of').iToggle({
        easing: 'linear',
        speed: 70,
        onClickOn: function(){
            obj_f.attr("checked","checked").attr("value",1);
            obj_1.attr("checked","checked");
            obj_0.removeAttr("checked");
            if (typeof(func) === 'function')
                func();
        },
        onClickOff: function(){
            obj_f.removeAttr("checked").attr("value",0);
            obj_0.attr("checked","checked");
            obj_1.removeAttr("checked");
            if (typeof(func) === 'function')
                func();
        }
    });
    $j("#"+id+"_on_of label.itoggle").css("background-position", $j("input#"+id+"_fake:checked").length > 0 ? '0% -27px' : '100% -27px');
}

/* LAN发现页面的自定义开关使用与Padavan原生页面完全相同的iToggle机制。
 * 仅在对应DOM存在时初始化，不影响其它页面。 */
$j(function(){
    if ($j('#lan_discovery_enable_on_of').length) init_itoggle('lan_discovery_enable');
    if ($j('#lan_discovery_dhcp_enable_on_of').length) init_itoggle('lan_discovery_dhcp_enable');
    if ($j('#lan_discovery_discover_enable_on_of').length) init_itoggle('lan_discovery_discover_enable');
});

/* 标准监控协议的目标地址是协议固定值，由这里显式展示，避免只看到端口却不知道探测发向哪里。
 * 真正的发送目标仍由camdiscover实现；自定义五列格式仍可指定任意目标地址。 */
$j(function(){
    var ta=$j('#lan_discovery_custom');
    if (!ta.length || $j('#lan_discovery_protocol_targets').length) return;
    var rows=[
        ['ONVIF / WS-Discovery','239.255.255.250','3702','组播 + 目标网段探测'],
        ['SSDP','239.255.255.250','1900','组播'],
        ['海康 SADP','239.255.255.250','37020','组播 + 目标网段广播'],
        ['大华 DHDiscover','239.255.255.251','37810','组播 + 目标网段广播'],
        ['ARP','二层广播','—','主动ARP扫描，不使用IP地址']
    ];
    var box=$j('<div id="lan_discovery_protocol_targets" class="protocol-target-box"></div>');
    box.append('<h4>标准监控协议</h4>');
    box.append('<div class="alert alert-info">标准协议的探测目标地址由协议实现固定；目标网段确定后，HIK/DAHUA会同时进行目标网段广播。自定义协议可在下面配置任意目标地址。</div>');
    var table=$j('<table class="table table-bordered table-condensed"><thead><tr><th>协议</th><th>目标地址</th><th>端口</th><th>探测方式</th></tr></thead><tbody></tbody></table>');
    for(var i=0;i<rows.length;i++){
        var tr=$j('<tr></tr>');
        for(var c=0;c<rows[i].length;c++) tr.append($j('<td></td>').text(rows[i][c]));
        table.find('tbody').append(tr);
    }
    box.append(table);
    ta.closest('.custom-box').before(box);
});
