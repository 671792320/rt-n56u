function init_itoggle(id,func)
{
    var obj_f = $j('#'+id+'_fake');
    var obj_0 = $j('#'+id+'_0');
    var obj_1 = $j('#'+id+'_1');
    var box = $j('#'+id+'_on_of');

    function sync(on){
        if(on){
            obj_f.prop('checked',true).attr('value',1);
            obj_1.prop('checked',true);
            obj_0.prop('checked',false);
        }else{
            obj_f.prop('checked',false).attr('value',0);
            obj_0.prop('checked',true);
            obj_1.prop('checked',false);
        }
        box.find('input#'+id+'_fake').css('display','none');
        box.find('label.itoggle').css('background-position',on?'0% -27px':'100% -27px');
        if(typeof(func)==='function')func();
    }

    if(typeof box.iToggle === 'function'){
        box.iToggle({
            easing:'linear',
            speed:70,
            onClickOn:function(){sync(true);},
            onClickOff:function(){sync(false);}
        });
    }else{
        box.find('input#'+id+'_fake').hide();
        box.find('label.itoggle').css('cursor','pointer').off('click.lanfix').on('click.lanfix',function(e){
            e.preventDefault();
            sync(!obj_f.prop('checked'));
        });
    }

    /* New LAN discovery variables default to enabled until an explicit
     * 0/1 value has been saved. Existing values are never overwritten. */
    if(id.indexOf('lan_discovery_')===0 && !obj_0.prop('checked') && !obj_1.prop('checked') && !obj_f.prop('checked'))
        obj_f.prop('checked',true);
    sync(obj_f.prop('checked'));

    if(id.indexOf('lan_discovery_')===0){
        var form=document.forms['form'];
        if(form){
            form.action='/start_apply.htm';
            form.target='hidden_frame';
            if(form.current_page)form.current_page.value='/Advanced_LANDiscover_Content.asp';
            if(form.next_page)form.next_page.value='/Advanced_LANDiscover_Content.asp';
            $j(form).off('submit.lanfix').on('submit.lanfix',function(){try{showLoading();}catch(e){}});
        }
    }
}

/* Compatibility helpers for the LAN discovery interface list. */
$j(function(){
    var sel=document.getElementById('lan_ifname');
    function fixInterfaces(){
        var s=document.getElementById('lan_ifname');
        if(!s)return;
        for(var i=0;i<s.options.length;i++){
            var text=s.options[i].text||'';
            text=text.replace(/&#10;/g,'\n').replace(/&#13;/g,'\r');
            if(text.indexOf('\n')<0)continue;
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
    if(sel && typeof MutationObserver!=='undefined'){
        var mo=new MutationObserver(function(){fixInterfaces();});
        mo.observe(sel,{childList:true,subtree:true});
        setTimeout(fixInterfaces,300);
        setTimeout(fixInterfaces,1000);
    }
});
