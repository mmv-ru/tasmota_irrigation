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
return ws