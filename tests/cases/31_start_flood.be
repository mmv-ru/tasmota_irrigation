# Characterization: start_flood() shared flooding entry point.
# Used by auto_flood(), timer_soil_transition_after_flooded() and rule_button1.
# Guards on soil dryness (RawEma > RawWet), then sets PlannedFlood via
# planned_dose() (estimate on Prev* or Counter1FloodDefault) and switches the
# relay ON.
import json

section("start_flood_dry_starts")

# dry soil by EMA -> planned dose + pump ON
# DryThreshold forced high: characterises the normal (estimate) preset, not the
# dry-soak path (covered by 33_dry_soak).
wp1.plants[0].DryThreshold = 9999
wp1.plants[0].Preset = nil
wp1.SoilSensors[0].RawWet = 750
wp1.SoilSensors[0].RawEma = 850
SIM['cmds'] = list()
wp1.plants[0].PlannedFlood = nil
wp1.plants[0].start_flood()
assert_eq(wp1.plants[0].PlannedFlood, 30, "planned dose defaults to Counter1FloodDefault (ml)")
assert_true(cmds_include("Power1 1"), "pump commanded ON")

section("start_flood_uses_prev_estimate")

# valid Prev* session data -> estimate used as planned dose.
# CurDRaw = 850 - 800 = 50, LastFloodDRaw = 900 - 820 = 80,
# Estimated = 350 * 50/80 = 218.75 -> 218
wp1.plants[0].PrevFloodedVol = 350
wp1.plants[0].PrevSoilHPreFlood = 900
wp1.plants[0].PrevSoilMaxHymidity = 820
wp1.SoilSensors[0].RawWet = 800
wp1.SoilSensors[0].RawEma = 850
SIM['cmds'] = list()
wp1.plants[0].start_flood()
assert_eq(wp1.plants[0].PlannedFlood, 218, "estimate on Prev* used as planned dose")
assert_true(cmds_include("Power1 1"), "pump commanded ON")

section("start_flood_skips_when_wet")

# soil wet by EMA -> no plan change, no pump command
wp1.SoilSensors[0].RawEma = 700
SIM['cmds'] = list()
wp1.plants[0].start_flood()
assert_eq(wp1.plants[0].PlannedFlood, 218, "no replan when skipped")
assert_true(!cmds_include("Power1 1"), "no relay command when wet")

# ---------------- finished ----------------
