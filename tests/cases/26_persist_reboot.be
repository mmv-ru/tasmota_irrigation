# Characterization: persist layer survives a full Berry VM restart.
# Real Tasmota: `BrRestart` reloads the script -> old wp1.deinit()+new Watering().
# init() reads TargetDry/TargetWet and session fields back from persist.
import json

section("calibration_survives_reboot")

persist.saves = 0
assert_true(wp1.plants[0].SetDry(970), "SetDry accepted (gap 970-760>20)")
assert_true(wp1.plants[0].SetWet(930), "SetWet accepted (gap 970-930>20)")
var saved_dry = persist.find("P1TargetDry")
var saved_wet = persist.find("P1TargetWet")
assert_true(saved_dry != nil, "TargetDry written before reboot")
assert_true(saved_wet != nil, "TargetWet written before reboot")

# ---- emulate BrRestart: reload script (old driver deinit, new instance) ----
var saves_before_deinit = persist.saves
wp1.deinit()
assert_true(persist.saves > saves_before_deinit, "deinit flushed persist (save)")
wp1 = Watering()
assert_eq(wp1.plants[0].TargetDry, int(saved_dry), "TargetDry restored from persistence")
assert_eq(wp1.plants[0].TargetWet, int(saved_wet), "TargetWet restored from persistence")

section("prev_session_stats_survive_reboot")

# dry enough to pass the auto_flood guard (TargetDry comes from persisted 970).
# TargetWet=930 sits above the freshly-seeded EMA (~900.66) so start_flood's
# dry-guard skips and no dose is planned yet, as in the pre-refactor contract.
SIM['sensors']['ANALOG']['A1'] = 1100
wp1.plants[0].DryThreshold = 9999
wp1.plants[0].PauseSoilMaxStat = true
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
assert_true(wp1.plants[0].IsDry(), "precondition: soil reads dry")

# snapshot current session stats into persist, as auto_flood does on start
wp1.plants[0].SoilHPreFlood = 812
wp1.plants[0].LastFloodVol = 420
wp1.plants[0].SoilMaxHymidity = 805
wp1.auto_flood()
assert_true(persist.has('P1PrevSoilHPreFlood'), "PrevSoilHPreFlood written during auto_flood")
assert_true(persist.has('P1SoilHPreFlood'), "SoilHPreFlood written during auto_flood")
assert_true(persist.has('P1LastFloodVol'), "LastFloodVol written during auto_flood")
# start_flood() dry-guard: right after reboot the EMA is still below TargetWet
# (seeded from the boot sample ~900, rising toward the sample), so the pump
# start is skipped and no dose is planned yet. Persisted stats are unaffected.
assert_eq(wp1.plants[0].PlannedFlood, nil, "no plan while EMA below wet threshold")

wp1.deinit()
wp1 = Watering()
assert_eq(wp1.plants[0].PrevSoilHPreFlood, 812, "PrevSoilHPreFlood restored after reboot")
assert_eq(wp1.plants[0].PrevSoilMaxHymidity, 805, "PrevSoilMaxHymidity restored after reboot")
assert_true(persist.has('P1PrevFloodedVol'), "PrevFloodedVol persisted by auto_flood")

section("estimate_works_after_reboot")

# After reboot the last session's SoilHPreFlood/LastFloodVol/SoilMaxHymidity are
# restored from persist, so estimateflood() must produce a real number, not nil.
assert_eq(wp1.plants[0].SoilHPreFlood, 812, "SoilHPreFlood restored after reboot")
assert_eq(wp1.plants[0].LastFloodVol, 420, "LastFloodVol restored after reboot")
# dry enough to build a CurDRaw > 0
SIM['sensors']['ANALOG']['A1'] = 1100
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
var est = wp1.plants[0].estimateflood()
assert_true(est != nil, "estimateflood returns a value after reboot (last session data present)")
assert_true(est >= 0, "estimateflood non-negative")

section("lastfloodvol_restored_when_written")

# LastFloodVol is persisted at session start (with SoilHPreFlood etc.) and
# restored on boot, so the flood estimate has real last-session data.
assert_eq(wp1.plants[0].LastFloodVol, 420, "LastFloodVol restored from persistence")

section("lastflood_time_rate_survive_reboot")

# _record_flood() persists the last-fill date + avg flow rate
# (P{Num}LastFloodTime / P{Num}LastFlowRate); Plant.init() must restore them so
# the web group "Последний полив" survives a reboot. Values written the same
# way _record_flood() does (Store.set, debounced policy).
var p1 = wp1.plants[0]
p1.LastFloodTime = SIM['rtc_local']
p1.LastFlowRate = 500.0
wp1.Store.set('P1LastFloodTime', SIM['rtc_local'])
wp1.Store.set('P1LastFlowRate', 500.0)
wp1.Store.flush(true)
wp1.deinit()
wp1 = Watering()
var p1b = wp1.plants[0]
assert_eq(p1b.LastFloodTime, SIM['rtc_local'], "LastFloodTime restored after reboot")
assert_eq(p1b.LastFlowRate, 500.0, "LastFlowRate restored after reboot")

# ---------------- finished ----------------