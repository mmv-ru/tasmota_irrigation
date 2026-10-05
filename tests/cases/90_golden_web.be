# Golden snapshot: full web_sensor() output in the channel states that
# 19_web_sensor.be already exercises. Byte-compared by tests/golden.py
# against tests/golden/web.out.
section("golden: web")

# Berry has no join(); concatenate the captured message list by hand.
def gold_cat(l)
    var s = ""
    for m: l
        s = s .. m
    end
    return s
end

# --- state: no me= (collapsed) ---
webserver.has_arg = def (name) return false end
webserver.arg = def (name, dflt) return dflt end
SIM['websend'] = list()
wp1.web_sensor()
print("### web_sensor: no me")
print(gold_cat(SIM['websend']))

# --- state: me=1 (soil channel 1 expanded) ---
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '1' : dflt end
SIM['websend'] = list()
wp1.web_sensor()
print("### web_sensor: me=1")
print(gold_cat(SIM['websend']))

# --- state: me=c (flow/common detail) ---
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? 'c' : dflt end
SIM['websend'] = list()
wp1.web_sensor()
print("### web_sensor: me=c")
print(gold_cat(SIM['websend']))

# --- state: me=4 (last channel expanded) ---
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '4' : dflt end
SIM['websend'] = list()
wp1.web_sensor()
print("### web_sensor: me=4")
print(gold_cat(SIM['websend']))

# --- state: me=2 ---
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '2' : dflt end
SIM['websend'] = list()
wp1.web_sensor()
print("### web_sensor: me=2")
print(gold_cat(SIM['websend']))

# --- main button + telemetry ---
# web_add_main_button() writes through webserver.content_send (not
# web_send_decimal), so it lands in SIM['webhtml'].
SIM['webhtml'] = list()
wp1.web_add_main_button()
print("### web_add_main_button")
print(gold_cat(SIM['webhtml']))

SIM['append'] = list()
wp1.json_append()
print("### json_append")
print(gold_cat(SIM['append']))