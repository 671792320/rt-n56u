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

    sync(obj_f.prop('checked'));

    /* LAN discovery page uses the normal Padavan start_apply workflow. */
    if(id.indexOf('lan_discovery_')===0){
        var form=document.forms['form'];
        if(form){
            form.action='/start_apply.htm';
            form.target='hidden_frame';
            if(form.current_page)form.current_page.value='/Advanced_LANDiscover_Content.asp';
            if(form.next_page)form.next_page.value='/Advanced_LANDiscover_Content.asp';
        }
    }
}
