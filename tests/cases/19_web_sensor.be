# Characterization: web_sensor() -> sequence of web_send_decimal messages
# Uses the module instance stub; has_arg can be overridden per scenario.
import json

section("web_sensor_no_args")

SIM['websend'] = list()
wp1.SoilMaxHymidity = nil
wp1.LastFloodTime = nil
wp1.web_sensor()

assert_true(SIM['websend'].size() >= 4, "base rows emitted for both soil + flow sensors")
var joined = ""
for m: SIM['websend'] joined = joined .. m end
assert_true(string.find(joined, "FlowSensor Calibration mode") >= 0, "calibration row present")
assert_true(string.find(joined, "Flooding in process") >= 0, "flooding row present")
assert_true(string.find(joined, "SoilA1Hymidity") >= 0, "soil humidity label")
assert_true(string.find(joined, "SoilA2Hymidity") >= 0, "second soil humidity label")
assert_true(string.find(joined, "Water used") >= 0, "flow water used")

section("web_sensor_max_shown_when_confirmed")

# when max humidity known, an extra row with value + time appears
wp1.SoilMaxHymidity = 840
wp1.SoilMaxHymidityConfirmed = true
wp1.SoilMaxHymidityTime = SIM['rtc_local']
SIM['websend'] = []
wp1.web_sensor()
var j2 = ""
for m: SIM['websend'] j2 = j2 + m end
assert_true(string.find(j2, "SoilHymidity1 max") >= 0, "max humidity row")

# ---------------- finished ----------------