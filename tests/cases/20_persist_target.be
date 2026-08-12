# Characterization: TargetDry/TargetWet persisted via PersistStore on Dry/Wet
# calibration. Writes are debounced: values land in the persist map immediately,
# the save() to Flash is deferred until the 15s timer or an explicit flush.
import json

section("setmember_dry_wet_persist_kall")

# manual calibration via virtual member: sensor.Dry = 60 (humidity %)
persist.saves = 0
wp1.SoilSensors[0].Dry = 60
assert_true(persist.has('TargetDry'), "TargetDry written to persist map after Dry calibration")
assert_eq(persist.saves, 0, "no immediate save: write is debounced")
assert_true(wp1.Store.Dirty, "store marked dirty after Dry calibration")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") != nil, "debounce save timer armed")

wp1.SoilSensors[0].Wet = 55
assert_true(persist.has('TargetWet'), "TargetWet written to persist map after Wet calibration")
assert_eq(persist.saves, 0, "Wet calibration still deferred (no save yet)")

wp1.Store.flush()
assert_eq(persist.saves, 1, "flush saves both calibrations in one persist.save")
assert_true(!wp1.Store.Dirty, "store clean after flush")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") == nil, "save timer cleared after flush")

section("dry_wet_reflect_persisted_scale")

# persist stores raw values; init() assigns them verbatim to RawDry/RawWet
assert_eq(wp1.SoilSensors[0].RawDry, persist.find("TargetDry"), "RawDry reflects persisted TargetDry")
assert_eq(wp1.SoilSensors[0].RawWet, persist.find("TargetWet"), "RawWet reflects persisted TargetWet")

# ---------------- finished ----------------