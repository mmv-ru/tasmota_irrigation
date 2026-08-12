# Characterization: web_sensor() must not truncate output when one section fails.
# soil0 with nil RawEma used to crash the whole method (type_error inside Raw2Hu).
import json

section("web_sensor_survives_soil1_crash")

wp1.SoilSensors[0].RawEma = nil
wp1.SoilSensors[1].RawEma = 900
wp1.SoilMaxHymidity = nil
wp1.LastFloodTime = nil
SIM['websend'] = list()
wp1.web_sensor()

var joined = ""
for m: SIM['websend'] joined = joined + m end
assert_true(string.find(joined, "Flooding in process") >= 0, "basic rows present")
assert_true(string.find(joined, "SoilA2Hymidity") >= 0, "soil2 row survived despite soil1 break")
assert_true(string.find(joined, "Water used") >= 0, "flow row survived")

section("web25_max_row_guarded")

# SoilMaxHymidity with time triggers the guarded max-humidity section (detail view)
wp1.DetailView = true
wp1.SoilMaxHymidity = 810
wp1.SoilMaxHymidityConfirmed = true
wp1.SoilMaxHymidityTime = SIM['rtc_local']
SIM['websend'] = list()
wp1.web_sensor()
var j2 = ""
for m: SIM['websend'] j2 = j2 + m end
assert_true(string.find(j2, "SoilHymidity1 max") >= 0, "max humidity row emitted")

# ---------------- finished ----------------
