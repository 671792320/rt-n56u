var itoggle_plugin_loading = false;
var itoggle_plugin_callbacks = [];

function itoggle_run_callbacks()
{
    var cbs = itoggle_plugin_callbacks;
    itoggle_plugin_callbacks = [];
    for (var i = 0; i < cbs.length; ++i) {
        try { cbs[i](); } catch (e) {}
    }
}

function itoggle_load_plugin(cb)
{
    if ($j.fn && typeof $j.fn.iToggle === 'function') {
        cb();
        return;
    }

    itoggle_plugin_callbacks.push(cb);
    if (itoggle_plugin_loading)
        return;

    itoggle_plugin_loading = true;
    var s = document.createElement('script');
    s.type = 'text/javascript';
    s.src = '/bootstrap/js/engage.itoggle.min.js';
    s.onload = function() {
        itoggle_plugin_loading = false;
        itoggle_run_callbacks();
    };
    s.onerror = function() {
        itoggle_plugin_loading = false;
        itoggle_plugin_callbacks = [];
    };
    document.getElementsByTagName('head')[0].appendChild(s);
}

function init_itoggle(id,func)
{
    itoggle_load_plugin(function(){
        var obj_f = $j('#'+id+'_fake');
        var obj_0 = $j('#'+id+'_0');
        var obj_1 = $j('#'+id+'_1');
        var box = $j('#'+id+'_on_of');

        if (!box.length || !$j.fn || typeof $j.fn.iToggle !== 'function')
            return;

        box.iToggle({
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
    });
}
