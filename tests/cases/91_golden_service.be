# Golden snapshot: full page_service() output in the modes that
# 41_service_mode.be already exercises. Byte-compared by tests/golden.py
# against tests/golden/service.out.
section("golden: service")

# Berry has no join(); concatenate the captured page chunks by hand.
def gold_cat(l)
    var s = ""
    for m: l
        s = s .. m
    end
    return s
end

# One state = one page_service() call. Calling it twice would not be the same
# state twice (some modes flip on the first call), so `snap` never pre-calls.
def snap(title)
    SIM['webhtml'] = list()
    wp1.page_service()
    print("### " .. title)
    print(gold_cat(SIM['webhtml']))
end

# --- mode off: no request args at all ---
webserver.has_arg = def (name)
    return false
end
webserver.arg = def (name, dflt)
    return dflt
end
snap("service: off")

# --- enable form (?start present but not submitted) ---
webserver.has_arg = def (name)
    return name == 'start'
end
webserver.arg = def (name, dflt)
    return dflt
end
snap("service: enable form")

# --- entered: ?start=1 flips the mode on this very call ---
webserver.has_arg = def (name)
    return name == 'start'
end
webserver.arg = def (name, dflt)
    if name == 'start'
        return '1'
    end
    return dflt
end
snap("service: entered")

# --- calibration view ---
webserver.has_arg = def (name)
    return name == 'cal' || name == 'vol'
end
webserver.arg = def (name, dflt)
    if name == 'vol'
        return '1000'
    end
    return dflt
end
snap("service: calibration")

# --- pump control form ---
webserver.has_arg = def (name)
    return name == 'pump' || name == 'on'
end
webserver.arg = def (name, dflt)
    if name == 'pump'
        return '2'
    end
    return dflt
end
snap("service: pump form")