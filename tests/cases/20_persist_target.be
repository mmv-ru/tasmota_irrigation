# Characterization: persist TargetDry/TargetWet written on Dry/Wet calibration
import json

section("setmember_dry_wet_persist_kall")

# manual calibration via virtual member: sensor.Dry = 60 (humidity %)
persist.saves = 0
wp1.SoilSensors[0].Dry = 60
assert_true(persist.has('TargetDry'), "TargetDry persisted after Dry calibration")
assert_eq(persist.saves, 1, "one save for Dry calibration")

wp1.SoilSensors[0].Wet = 55
assert_true(persist.has('TargetWet'), "TargetWet persisted after Wet calibration")
assert_eq(persist.saves, 2, "save also on Wet calibration")

section("dry_wet_reflect_persisted_scale")

# persist stores raw values; init() assigns them verbatim to RawDry/RawWet
assert_eq(wp1.SoilSensors[0].RawDry, persist.find("TargetDry"), "RawDry reflects persisted TargetDry")
assert_eq(wp1.SoilSensors[0].RawWet, persist.find("TargetWet"), "RawWet reflects persisted TargetWet")

# ---------------- finished ----------------