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
return ws