#include <stdlib.h>
#include <string.h>

#include "common.h"

/*
 * Keep LAN discovery settings inside Padavan's normal GetVariables() save
 * path without modifying the large generated variables.c table.
 *
 * The wrapper appends our configuration variables to the native variable
 * table. validate_asp_apply()/validate_cgi() can therefore save them through
 * the same nvram_set() mechanism as every other WebUI parameter.
 */

static struct variable lan_discovery_extra[] = {
    {"lan_discovery_enable", "", NULL, FALSE},
    {"lan_discovery_ifname", "", NULL, FALSE},
    {"lan_discovery_dhcp_enable", "", NULL, FALSE},
    {"lan_discovery_dhcp_timeout", "", NULL, FALSE},
    {"lan_discovery_discover_enable", "", NULL, FALSE},
    {"lan_discovery_cycle", "", NULL, FALSE},
    {"lan_discovery_raw", "", NULL, FALSE},
    {"lan_discovery_onvif", "", NULL, FALSE},
    {"lan_discovery_onvif_port", "", NULL, FALSE},
    {"lan_discovery_ssdp", "", NULL, FALSE},
    {"lan_discovery_ssdp_port", "", NULL, FALSE},
    {"lan_discovery_hik", "", NULL, FALSE},
    {"lan_discovery_hik_port", "", NULL, FALSE},
    {"lan_discovery_dahua", "", NULL, FALSE},
    {"lan_discovery_dahua_port", "", NULL, FALSE},
    {"lan_discovery_custom", "", NULL, FALSE},
    {"lan_discovery_log", "", NULL, FALSE},
    {0, 0, 0, 0}
};

extern struct variable *__real_GetVariables(int sid);

#define LAN_DISCOVERY_CACHE_MAX 128
static struct variable *wrapped_cache[LAN_DISCOVERY_CACHE_MAX];

struct variable *__wrap_GetVariables(int sid)
{
    struct variable *orig;
    struct variable *out;
    size_t orig_count = 0;
    size_t extra_count = 0;
    size_t i;

    orig = __real_GetVariables(sid);
    if (!orig)
        return NULL;

    if (sid < 0 || sid >= LAN_DISCOVERY_CACHE_MAX)
        return orig;

    if (wrapped_cache[sid])
        return wrapped_cache[sid];

    while (orig[orig_count].name)
        orig_count++;
    while (lan_discovery_extra[extra_count].name)
        extra_count++;

    out = (struct variable *)calloc(orig_count + extra_count + 1,
                                    sizeof(struct variable));
    if (!out)
        return orig;

    for (i = 0; i < orig_count; i++)
        out[i] = orig[i];
    for (i = 0; i < extra_count; i++)
        out[orig_count + i] = lan_discovery_extra[i];

    wrapped_cache[sid] = out;
    return out;
}
