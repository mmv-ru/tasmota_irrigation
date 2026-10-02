# Characterization: SoilSensor raw-side behaviour: init fields, Update/EMA,
# N/C status, conversion/calibration (%, mV, Hu). Dry/Wet thresholds and the
# IsDry/IsWet guards live on Plant (per-channel policy) and are covered here.
import json

section("soil_init_fields")

var ss = wp1.SoilSensors[0]
var pl = wp1.plants[0]
# Dry/Wet thresholds are Plant policy (per-channel, restored from Store);
# the sensor only measures. Store defaults land on the Plant.
assert_eq(pl.TargetDry, 800, "TargetDry default 800 (store default on Plant)")
assert_eq(pl.TargetWet, 760, "TargetWet default 760 (store default on Plant)")
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

section("plant_is_dry_wet_thresholds")

# Plant owns the Dry/Wet thresholds: IsDry when Raw >= TargetDry.
var pl = wp1.plants[0]
pl.SoilSensor.Raw = pl.TargetDry
assert_true(pl.IsDry(), "IsDry true at TargetDry boundary")
pl.SoilSensor.Raw = pl.TargetDry - 1
assert_true(!pl.IsDry(), "IsDry false below TargetDry")

# IsWet: Raw <= TargetWet
pl.SoilSensor.Raw = pl.TargetWet
assert_true(pl.IsWet(), "IsWet true at TargetWet boundary")
pl.SoilSensor.Raw = pl.TargetWet + 1
assert_true(!pl.IsWet(), "IsWet false above TargetWet")

# mid range: neither dry nor wet
pl.SoilSensor.Raw = (pl.TargetWet + pl.TargetDry) / 2
assert_true(!pl.IsDry() && !pl.IsWet(), "mid range neither dry nor wet")

# ---------------- finished ----------------