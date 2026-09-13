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

/* LAN发现页面的三个开关统一使用Padavan原生iToggle。 */
$j(function(){
    if ($j('#lan_discovery_enable_on_of').length) init_itoggle('lan_discovery_enable');
    if ($j('#lan_discovery_dhcp_enable_on_of').length) init_itoggle('lan_discovery_dhcp_enable');
    if ($j('#lan_discovery_discover_enable_on_of').length) init_itoggle('lan_discovery_discover_enable');
});

/*
 * LAN发现协议统一放进“发现协议参数”文本区，避免再占用独立表格空间。
 * 标准协议使用五列格式：名称|目标地址|端口|说明/探测内容|启用。
 * 页面保存时会把标准协议转换回后端现有三列接口，避免破坏已验证的后端逻辑。
 */
$j(function(){
    var ta=$j('#lan_discovery_custom');
    var box=ta.closest('.custom-box');
    if (!ta.length || !box.length) return;

    box.find('h4').first().text('发现协议参数');
    box.find('.custom-format').first().html('标准协议和自定义私有协议统一在此配置。格式：<b>名称|目标地址|端口|探测内容或说明|启用</b>；标准协议的探测报文由程序自动生成。');

    var defaults=[
        '# 名称|目标地址|端口|探测内容或说明|启用',
        'onvif|239.255.255.250|3702|自动生成 ONVIF WS-Discovery|1',
        'ssdp|239.255.255.250|1900|自动生成 SSDP M-SEARCH|1',
        'hik-sadp|239.255.255.250|37020|自动生成海康 SADP 探测|1',
        'dahua-dhip|239.255.255.251|37810|自动生成大华 DHDiscover 探测|1',
        'arp|0.0.0.0|0|自动主动 ARP 扫描|1',
        '# 自定义私有协议示例',
        '# my-device|192.168.1.255|5000|DISCOVER|1'
    ].join('\n');

    function standard_defaults_need_reformat(v){
        var hasStandard=false;
        var ls=String(v||'').split(/\r?\n/);
        for(var i=0;i<ls.length;i++){
            var p=ls[i].split('|');
            if(p.length>=3){
                var n=(p[0]||'').toLowerCase().replace(/_/g,'-');
                if(n==='onvif'||n==='ssdp'||n==='hik'||n==='hik-sadp'||n==='dahua'||n==='dahua-dhip'||n==='arp'){
                    hasStandard=true;
                    if(p.length>=5) return false;
                }
            }
        }
        return hasStandard;
    }

    var current=ta.val();
    if(!String(current||'').trim() || standard_defaults_need_reformat(current))
        ta.val(defaults);

    function parse(v){
        var d={onvif:{addr:'239.255.255.250',port:'3702',enable:'1'},ssdp:{addr:'239.255.255.250',port:'1900',enable:'1'},hik:{addr:'239.255.255.250',port:'37020',enable:'1'},dahua:{addr:'239.255.255.251',port:'37810',enable:'1'},arp:{addr:'0.0.0.0',port:'0',enable:'1'}};
        var ls=String(v||'').split(/\r?\n/);
        for(var i=0;i<ls.length;i++){
            var x=String(ls[i]||'');
            if(!x || x.charAt(0)==='#') continue;
            var p=x.split('|');
            if(p.length<3) continue;
            var n=(p[0]||'').toLowerCase().replace(/_/g,'-');
            var key=(n==='hik'||n==='hik-sadp')?'hik':((n==='dahua'||n==='dahua-dhip')?'dahua':n);
            if(!d[key]) continue;
            if(p.length>=5){
                d[key]={addr:p[1]||d[key].addr,port:p[2]||d[key].port,enable:p[4]==='1'?'1':'0'};
            }else{
                d[key]={addr:d[key].addr,port:p[1]||d[key].port,enable:p[2]==='1'?'1':'0'};
            }
        }
        return d;
    }

    window.sync_builtin_from_custom=function(){
        var d=parse(ta.val());
        function set_radio(name,val){var el=document.getElementById(name+'_'+val);if(el)el.checked=true;}
        set_radio('lan_discovery_onvif',d.onvif.enable);
        set_radio('lan_discovery_ssdp',d.ssdp.enable);
        set_radio('lan_discovery_hik',d.hik.enable);
        set_radio('lan_discovery_dahua',d.dahua.enable);
        set_radio('lan_discovery_raw',d.arp.enable);
        var ids=[['lan_discovery_onvif_port',d.onvif.port],['lan_discovery_ssdp_port',d.ssdp.port],['lan_discovery_hik_port',d.hik.port],['lan_discovery_dahua_port',d.dahua.port]];
        for(var j=0;j<ids.length;j++){var e=document.getElementById(ids[j][0]);if(e)e.value=ids[j][1];}
    };

    window.normalize_custom_lines=function(){
        var ls=String(ta.val()||'').split(/\r?\n/),out=[];
        for(var i=0;i<ls.length;i++){
            var x=ls[i];
            if(!x){continue;}
            if(x.charAt(0)==='#'){out.push(x);continue;}
            var p=x.split('|');
            var n=(p[0]||'').toLowerCase().replace(/_/g,'-');
            if(p.length>=5 && (n==='onvif'||n==='ssdp'||n==='hik'||n==='hik-sadp'||n==='dahua'||n==='dahua-dhip'||n==='arp')){
                out.push(n+'|'+(p[2]||'0')+'|'+(p[4]==='1'?'1':'0'));
            }else if(p.length>=5){
                out.push(p.join('|'));
            }else if(p.length>=3 && (n==='onvif'||n==='ssdp'||n==='hik'||n==='hik-sadp'||n==='dahua'||n==='dahua-dhip'||n==='arp')){
                out.push(n+'|'+(p[1]||'0')+'|'+(p[2]==='1'?'1':'0'));
            }else{
                out.push(x);
            }
        }
        ta.val(out.join('\n'));
    };

    /* 保存前将显示用五列标准协议转为后端现有的三列标准接口。 */
    var oldApply=window.applyRule;
    window.applyRule=function(){
        normalize_custom_lines();
        if(typeof oldApply==='function') return oldApply();
        return false;
    };

    sync_builtin_from_custom();
    render_custom_hint();
});
