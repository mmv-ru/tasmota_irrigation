# Characterization: json_append() telemetry payload
# Driving state explicitly to verify every field of the Watering JSON:
#   - SoilRaw/EMA/humidity come from the (emulated) sensors
#   - session state (flood vol, pre-flood level) reflect internal vars
#   - ternary LastSoilMaxHymidity: nil while unconfirmed, value once confirmed
import json

section("json_append_basic")

# set up known sensor + session state
SIM['sensors']['ANALOG']['A1'] = 850
SIM['sensors']['ANALOG']['A2'] = 820
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
wp1.LastFloodVol = 350
wp1.PumpRunMillis = 42000
wp1.PrevFloodedVol = 250
wp1.SoilHPreFlood = 900
wp1.SoilMaxHymidityConfirmed = false   # not yet confirmed -> nil in payload

SIM['append'] = list()
wp1.json_append()

assert_true(SIM['append'].size() == 1, "exactly one append emitted")
var tele = SIM['append'][0]

# payload is the ", \"Watering\": {...}" fragment -> locate { after "Watering":
# payload is ", \"Watering\": {...}" fragment; extract JSON after the marker
var parts = string.split(tele, '"Watering":')
var body = parts[1]
print("tele body:", body)

section("json_append_fields")

# parse the wtele object and verify each field
var obj = json.load(body)
assert_eq(obj['Soil1Raw'], 850, "Soil1Raw from A1")
assert_eq(obj['Soil2RawEma'], int(wp1.SoilSensors[1].RawEma), "Soil2RawEma from A2")
assert_eq(obj['LastFloodSessionVol'], 350, "LastFloodSessionVol from var")
assert_eq(obj['LastSoilMaxHymidity'], nil, "max nil while unconfirmed")
assert_eq(obj['PrevFloodedVol'], 250, "PrevFloodedVol archived")
assert_eq(obj['PumpRunMillis'], 42000, "PumpRunMillis")
assert_eq(obj['SoilHPreFlood'], 900, "SoilHPreFlood")

section("json_append_max_confirmed")

# after confirmation the ternary flips to the stored max value
wp1.SoilMaxHymidity = 840
wp1.SoilMaxHymidityConfirmed = true
SIM['append'] = list()
wp1.json_append()
var obj2 = json.load(string.split(SIM['append'][0], '"Watering":')[1])
assert_eq(obj2['LastSoilMaxHymidity'], 840, "max present once confirmed")

# ---------------- finished ----------------