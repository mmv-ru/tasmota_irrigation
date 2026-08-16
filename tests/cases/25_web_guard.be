# Characterization: web_sensor() must not truncate output when one section fails.
# soil0 with nil RawEma used to crash the whole method (type_error inside Raw2Hu).
import json

section("web_sensor_survives_soil1_crash")

wp1.SoilSensors[0].RawEma = nil
wp1.SoilSensors[1].RawEma = 900
wp1.plants[0].SoilMaxHymidity = nil
wp1.plants[0].LastFloodTime = nil
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? 'c' : dflt end
SIM['websend'] = list()
wp1.web_sensor()

var joined = ""
for m: SIM['websend'] joined = joined + m end
assert_true(string.find(joined, "class='st wait'") >= 0, "basic rows present (status icon in header)")
assert_true(string.find(joined, "Канал 2") >= 0, "soil2 row survived despite soil1 break")
assert_true(string.find(joined, "Water used") >= 0, "flow row survived")

section("web25_max_row_guarded")

# SoilMaxHymidity with time triggers the guarded max-humidity section
# (soil1 section expanded)
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '1' : dflt end
wp1.plants[0].SoilMaxHymidity = 810
wp1.plants[0].SoilMaxHymidityTime = SIM['rtc_local']
SIM['websend'] = list()
wp1.web_sensor()
var j2 = ""
for m: SIM['websend'] j2 = j2 + m end
assert_true(string.find(j2, "SoilHymidity1 max") >= 0, "max humidity row emitted")

# ---------------- finished ----------------
