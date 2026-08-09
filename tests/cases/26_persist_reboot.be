# Characterization: persist layer survives a full Berry VM restart.
# Real Tasmota: `BrRestart` reloads the script -> old wp1.deinit()+new Watering().
# init() reads TargetDry/TargetWet and session fields back from persist.
import json

section("calibration_survives_reboot")

persist.saves = 0
wp1.SoilSensors[0].Dry = 60
wp1.SoilSensors[0].Wet = 55
var saved_dry = persist.find("TargetDry")
var saved_wet = persist.find("TargetWet")
assert_true(saved_dry != nil, "TargetDry written before reboot")
assert_true(saved_wet != nil, "TargetWet written before reboot")

# ---- emulate BrRestart: reload script (old driver deinit, new instance) ----
var saves_before_deinit = persist.saves
wp1.deinit()
assert_true(persist.saves > saves_before_deinit, "deinit flushed persist (save)")
wp1 = Watering()
assert_eq(wp1.SoilSensors[0].RawDry, int(saved_dry), "RawDry restored from persistence")
assert_eq(wp1.SoilSensors[0].RawWet, int(saved_wet), "RawWet restored from persistence")

section("prev_session_stats_survive_reboot")

# dry enough to pass the auto_flood guard (RawDry comes from persisted 60%)
SIM['sensors']['ANALOG']['A1'] = 1100
wp1.PauseSoilMaxStat = true
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
assert_true(wp1.SoilSensors[0].IsDry(), "precondition: soil reads dry")

# snapshot current session stats into persist, as auto_flood does on start
wp1.SoilHPreFlood = 812
wp1.SoilHPostFlood = 820
wp1.LastFloodVol = 420
wp1.SoilMaxHymidity = 805
wp1.auto_flood()
assert_true(persist.has('PrevSoilHPreFlood'), "PrevSoilHPreFlood written during auto_flood")
assert_eq(wp1.PlannedFlood, 300, "estimate fallback default when data missing")

wp1.deinit()
wp1 = Watering()
assert_eq(wp1.PrevSoilHPreFlood, 812, "PrevSoilHPreFlood restored after reboot")
assert_eq(wp1.PrevSoilHPostFlood, 820, "PrevSoilHPostFlood restored after reboot")
assert_eq(wp1.PrevSoilMaxHymidity, 805, "PrevSoilMaxHymidity restored after reboot")
assert_true(persist.has('PrevFloodedVol'), "PrevFloodedVol persisted by auto_flood")

section("lastfloodvol_default_when_never_written")

# LastFloodVol is read from persist with "0" default; written only when flooded
assert_eq(wp1.LastFloodVol, 0, "LastFloodVol default 0 on fresh persistence")

# ---------------- finished ----------------