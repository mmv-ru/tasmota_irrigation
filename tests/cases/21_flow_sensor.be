# Characterization: FlowSensor counter read, rate measurement, reset, conversion
import json

section("flow_scale_and_conversion")

var fs = wp1.FlowSensors[0]
assert_eq(fs.Scale, 0.1449, "default scale 0.1449 ml/count")
assert_eq(fs.Raw2Flow(1000), 144.9, "Raw2Flow: 1000 counts -> 144.9 ml")
fs.setScale(0.2)
assert_eq(fs.Scale, 0.2, "setScale applied")
assert_eq(fs.Raw2Flow(10), 2.0, "Raw2Flow with custom scale")

section("flow_rate_measurement")

# counter advances between updates while RateMeasuring -> RawRate = pulses/s
fs.setScale(0.1449)
fs.RateMeasuring = true
SIM['millis'] = 1000
fs.Update(json.load(tasmota.read_sensors()))
assert_eq(fs.LastMillis, 1000, "first sample stamps millis")

SIM['sensors']['COUNTER']['C1'] = 120
SIM['millis'] = 1500
fs.Update(json.load(tasmota.read_sensors()))
assert_eq(fs.RawRate, 240, "raw rate = (120-0)/0.5s = 240 pulses/s")
assert_true(fs.Rate != nil, "Rate member exposes flow")
assert_eq(fs.Rate, 240*0.1449, "Rate = RawRate * scale")

section("flow_rate_off")

# RateMeasuring off -> no rate sampling, LastMillis reset
fs.RateMeasuring = false
SIM['sensors']['COUNTER']['C1'] = 300
SIM['millis'] = 2000
fs.Update(json.load(tasmota.read_sensors()))
assert_eq(fs.RawRate, 240, "rate frozen while not measuring")
assert_eq(fs.LastMillis, nil, "last millis cleared when not measuring")
assert_eq(fs.Rate, 240*0.1449, "Rate still reported from frozen rate")

section("flow_reset")

fs.Reset()
assert_eq(fs.Raw, 0, "Raw zeroed after Reset")
assert_true(cmds_include("Counter1 0"), "Reset issues Counter1 0 command")

section("flow_member_unknown")

assert_eq(type(fs.member("Nope")), "module", "unknown member is undefined")
assert_eq(fs.RateMeasuring, false, "RateMeasuring exposed as member")

section("flow_rate_nil_and_setmember")

# Rate with no samples yet -> nil (diagnostics placeholder: "no flow while pump ON")
new_fs = FlowSensor('C1')
assert_eq(new_fs.member("Rate"), nil, "Rate member nil when never measured")
assert_eq(new_fs.member("RateMeasuring"), nil, "RateMeasuring initial state nil")
new_fs.RateMeasuring = true
assert_eq(new_fs.member("RateMeasuring"), true, "setmember enables rate measuring")
var stamped = new_fs.LastMillis
SIM['millis'] = 3000
new_fs.RateMeasuring = true
assert_eq(new_fs.LastMillis, stamped, "no redundant Update on no state change")
new_fs.RateMeasuring = false
assert_eq(new_fs.member("RateMeasuring"), false, "setmember disables rate measuring")

section("flow_scale_store_default_and_override")

# the built-in scale is applied by init_sensors unless a persisted FlowScale
# value exists (calibrated from the /svc page)
var stored = wp1.FlowSensors[0].Scale
assert_eq(stored, 0.1449, "fresh init uses the built-in default scale")

# persist an override, re-init the driver (BrRestart) -> scale restored
wp1.Store.set('FlowScale', '0.25')
wp1.deinit()
wp1 = Watering()
assert_eq(wp1.FlowSensors[0].Scale, 0.25, "stored FlowScale applied on init")

# corrupt persisted value falls back to the built-in scale
persist.FlowScale = 'abc'
wp1.deinit()
wp1 = Watering()
assert_eq(wp1.FlowSensors[0].Scale, 0.1449, "corrupt stored scale falls back to built-in")

# ---------------- finished ----------------
