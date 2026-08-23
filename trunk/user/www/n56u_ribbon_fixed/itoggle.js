function init_itoggle(id,func)
{
    var obj_f = $j('#'+id+'_fake');
    var obj_0 = $j('#'+id+'_0');
    var obj_1 = $j('#'+id+'_1');
    var box = $j('#'+id+'_on_of');

    if(!box.length || !obj_f.length)
        return;

    /* Padavan's native pages put the on/off widget inside .main_itoggle.
     * LAN discovery rows are generated separately, so make the same parent
     * structure available before invoking the stock iToggle plugin. */
    if(!box.parent().hasClass('main_itoggle'))
        box.wrap('<div class="main_itoggle"></div>');
    box = $j('#'+id+'_on_of');

    function sync(on){
        if(on){
            obj_f.prop('checked',true).attr('value',1);
            if(obj_1.length)obj_1.prop('checked',true);
            if(obj_0.length)obj_0.prop('checked',false);
        }else{
            obj_f.prop('checked',false).attr('value',0);
            if(obj_0.length)obj_0.prop('checked',true);
            if(obj_1.length)obj_1.prop('checked',false);
        }
        box.find('input#'+id+'_fake').css('display','none');
        box.find('label.itoggle').css('background-position',on?'0% -27px':'100% -27px');
        if(typeof(func)==='function')func(on);
    }

    if(typeof box.iToggle === 'function'){
        box.iToggle({
            easing:'linear',
            speed:70,
            onClickOn:function(){sync(true);},
            onClickOff:function(){sync(false);}
        });
    }

    /* Older/custom pages may not have the plugin-generated label yet. */
    if(!box.find('label.itoggle').length){
        box.append('<label class="itoggle" for="'+id+'_fake"></label>');
        box.find('input#'+id+'_fake').css('display','none');
        box.find('label.itoggle').css('cursor','pointer');
        box.find('label.itoggle').off('click.lanfix').on('click.lanfix',function(e){
            e.preventDefault();
            sync(!obj_f.prop('checked'));
        });
    }

    sync(obj_f.prop('checked'));
}

/* Keep interface selector rendering compatible with HTML-encoded line breaks. */
$j(function(){
    function fixInterfaces(){
        var s=document.getElementById('lan_ifname');
        if(!s)return;
        for(var i=0;i<s.options.length;i++){
            var text=s.options[i].text||'';
            if(text.indexOf('&#10;')<0 && text.indexOf('\\n')<0)continue;
            text=text.replace(/&#10;/g,'\n').replace(/&#13;/g,'\r').replace(/\\n/g,'\n');
            var parts=text.split('\n');
            s.options[i].text=parts[0];
            for(var j=1;j<parts.length;j++){
                if(!parts[j])continue;
                var m=parts[j].split('|');
                var o=document.createElement('option');
                o.value=m[0]||'';
                o.text=parts[j];
                s.appendChild(o);
            }
        }
    }
    if(typeof MutationObserver!=='undefined'){
        var s=document.getElementById('lan_ifname');
        if(s)new MutationObserver(function(){fixInterfaces();}).observe(s,{childList:true,subtree:true});
    }
    setTimeout(fixInterfaces,300);
    setTimeout(fixInterfaces,1000);
});
