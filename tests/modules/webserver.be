# webserver stub: module instance (dot-assignable) so tests can override
# has_arg/arg per scenario.
var ws = module('webserver_std')
ws.has_arg = def (name) return false end
ws.arg = def (name, dflt) return dflt end
ws.content_send = def (html)
    if SIM['webhtml'] == nil
        SIM['webhtml'] = list()
    end
    SIM['webhtml'].push(html)
end
ws.content_open = def (a, b) end
ws.content_start = def (title)
    if SIM['webhtml'] == nil
        SIM['webhtml'] = list()
    end
    SIM['webhtml'].push("[content_start " .. title .. "]")
end
ws.content_send_style = def ()
    if SIM['webhtml'] == nil
        SIM['webhtml'] = list()
    end
    SIM['webhtml'].push("[content_send_style]")
end
ws.content_stop = def ()
    if SIM['webhtml'] == nil
        SIM['webhtml'] = list()
    end
    SIM['webhtml'].push("[content_stop]")
end
ws.content_button = def (t)
    if SIM['webhtml'] == nil
        SIM['webhtml'] = list()
    end
    SIM['webhtml'].push("[content_button " .. t .. "]")
end
ws.check_privileged_access = def () return true end
ws.BUTTON_MAIN = "MAIN"
ws.HTTP_GET = "GET"
# `on()` mirrors the firmware slot table (xdrv_52_3 `w_webserver_on`): a slot is
# keyed by prefix+method, so a repeat call reuses it instead of adding a second
# route. Every call is still logged to SIM['on_calls'] so a test can tell
# "called twice" (harmless, no guard needed) from "registered twice" (a bug).
ws.on = def (prefix, cb, method)
    # NB: a Berry map subscript on a missing key raises key_error, so optional
    # SIM entries are read with find(key, default).
    var calls = SIM.find('on_calls', nil)
    if calls == nil
        calls = list()
        SIM['on_calls'] = calls
    end
    var slots = SIM.find('routes', nil)
    if slots == nil
        slots = list()
        SIM['routes'] = slots
    end
    calls.push(prefix .. " " .. method)
    var idx = nil
    if slots.size() > 0
        for i: 0..slots.size() - 1
            if slots[i]['prefix'] == prefix && slots[i]['method'] == method
                idx = i
            end
        end
    end
    var entry = {'prefix': prefix, 'method': method, 'cb': cb}
    if idx != nil
        slots[idx] = entry
    else
        slots.push(entry)
    end
end
return ws