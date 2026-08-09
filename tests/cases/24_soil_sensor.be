# Characterization: SoilSensor raw-side behaviour: init fields, Update/EMA,
# IsDry/IsWet thresholds, N/C status. Conversion/calibration (%, mV, Hu)
# methods are excluded (web-only / inactive).
import json

section("soil_init_fields")

var ss = wp1.SoilSensors[0]
assert_eq(ss.RawDry, 800, "RawDry default 800")
assert_eq(ss.RawWet, 760, "RawWet default 760 (init persist default)")
assert_eq(ss.EMAN, 600, "EMAN default 600")
assert_eq(ss.ScaleMinRAW, 842, "scale min raw 842")
assert_eq(ss.ScaleMaxRAW, 1105, "scale max raw 1105")
assert_eq(ss.Name, "Soil%sHymidity", "name template")

# scale is inverted: 842 raw -> 100%, 1105 raw -> 0%
var s10 = ss.Raw2Hymidity(ss.ScaleMinRAW)
var s250 = ss.Raw2Hymidity(ss.ScaleMaxRAW)
assert_true(real(s10) > 99. && real(s10) < 101., "scale max raw maps near 100%")
assert_true(real(s250) > -1. && real(s250) < 1., "scale min raw maps near 0%")

section("soil_update_ema_first_sample")

# first Update seeds RawEma with current Raw
SIM['sensors']['ANALOG']['A1'] = 920
ss.RawEma = nil
ss.Update(json.load(tasmota.read_sensors()))
assert_eq(real(ss.RawEma), 920, "first EMA sample equals raw")
assert_eq(ss.Raw, 920, "Raw updated from sensors")

section("soil_update_ema_moves")

# next sample drifts EMA towards new raw (N=600 -> tiny step, always in bounds)
SIM['sensors']['ANALOG']['A1'] = 930
ss.Update(json.load(tasmota.read_sensors()))
assert_true(real(ss.RawEma) > 920. && real(ss.RawEma) < 930., "EMA steps toward raw")
assert_true(real(ss.RawEma) <= 930., "EMA never overshoots new raw")

section("soil_update_ema_stable_on_constant")

# repeated constant samples converge very close to the value (N=600 slow)
for i: 0..5000
    ss.Update(json.load(tasmota.read_sensors()))
end
assert_true(real(ss.RawEma) > 929.9 && real(ss.RawEma) < 930.1, "EMA stable near constant sample")

section("soil_update_nc_status")

# raw below 2 marks sensor N/C and must not update RawEma
var before_nc = real(ss.RawEma)
SIM['sensors']['ANALOG']['A1'] = 0
ss.RawEma = before_nc
ss.Update(json.load(tasmota.read_sensors()))
assert_eq(ss.Status, "N/C", "raw<2 marks N/C")
assert_eq(real(ss.RawEma), before_nc, "EMA frozen while N/C")

section("soil_is_dry_wet_thresholds")

# IsDry: Raw >= RawDry ; dry equality armed
ss.Raw = ss.RawDry
assert_true(ss.IsDry(), "IsDry true at RawDry boundary")
ss.Raw = ss.RawDry - 1
assert_true(!ss.IsDry(), "IsDry false below RawDry")

# IsWet: Raw <= RawWet
ss.Raw = ss.RawWet
assert_true(ss.IsWet(), "IsWet true at RawWet boundary")
ss.Raw = ss.RawWet + 1
assert_true(!ss.IsWet(), "IsWet false above RawWet")

# mid range: neither dry nor wet
ss.Raw = (ss.RawWet + ss.RawDry) / 2
assert_true(!ss.IsDry() && !ss.IsWet(), "mid range neither dry nor wet")

# ---------------- finished ----------------