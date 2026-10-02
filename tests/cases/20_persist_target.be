# Characterization: TargetDry/TargetWet persisted via PersistStore on
# Plant.SetDry/SetWet. Writes are debounced: values land in the persist map
# immediately, the save() to Flash is deferred until the 15s timer or an
# explicit flush.
import json

section("plant_setdry_wet_persist")

# thresholds set via the Plant API (raw values); Store key per channel
var p = wp1.plants[0]
persist.saves = 0
assert_true(p.SetDry(900), "SetDry accepted (gap 900-760>20)")
assert_true(persist.has('P1TargetDry'), "TargetDry written to persist map after SetDry")
assert_eq(persist.saves, 0, "no immediate save: write is debounced")
assert_true(wp1.Store.Dirty, "store marked dirty after SetDry")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") != nil, "debounce save timer armed")

assert_true(p.SetWet(750), "SetWet accepted (gap 900-750>20)")
assert_true(persist.has('P1TargetWet'), "TargetWet written to persist map after SetWet")
assert_eq(persist.saves, 0, "Wet calibration still deferred (no save yet)")

wp1.Store.flush()
assert_eq(persist.saves, 1, "flush saves both calibrations in one persist.save")
assert_true(!wp1.Store.Dirty, "store clean after flush")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") == nil, "save timer cleared after flush")

section("dry_wet_reflect_persisted_scale")

# persist stores raw values; init() assigns them verbatim to Plant.TargetDry/TargetWet
assert_eq(p.TargetDry, persist.find("P1TargetDry"), "TargetDry reflects persisted value")
assert_eq(p.TargetWet, persist.find("P1TargetWet"), "TargetWet reflects persisted value")

# ---------------- finished ----------------