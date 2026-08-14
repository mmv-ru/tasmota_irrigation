# Characterization: auto_flood() scheduling entry point
import json

section("auto_flood_dry_starts")

# fresh session: sensor must see dry soil for a start, not yet in process
# DryThreshold forced high: this test characterises the normal (estimate)
# preset, not the dry-soak path (covered by 33_dry_soak).
wp1.plants[0].DryThreshold = 9999
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
assert_true(wp1.SoilSensors[0].IsDry(), "sensor dry")

wp1.auto_flood()

assert_eq(wp1.plants[0].AutofloodInProcess, true, "flood session started")
assert_true(wp1.plants[0].PlannedFlood != nil, "planned flood volume set")
assert_eq(wp1.plants[0].LastFloodVol, 0, "session volume reset to 0")
assert_true(cmds_include("Power1 1"), "pump commanded ON")
assert_eq(wp1.plants[0].SoilHPreFlood, real(wp1.SoilSensors[0].RawEma), "pre-flood soil level captured")

assert_true(wp1.plants[0].PrevFloodedVol != nil, "previous session volume preserved")

section("auto_flood_ignored_when_in_process_or_wet")

# already running -> must not double-start. Other channels would be fair game
# for the round-robin sweep, so wet them out to isolate the in-process channel.
SIM['sensors']['ANALOG']['A2'] = 740
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
var cmds_len = SIM['cmds'].size()
wp1.auto_flood()
assert_eq(SIM['cmds'].size(), cmds_len, "no double start while in process")

# force end of session, then wet soil -> no start
wp1.plants[0].AutofloodInProcess = false
SIM['sensors']['ANALOG']['A1'] = 740
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.auto_flood()
assert_true(cmds_include("Power1 1"), "no start while wet")

section("auto_flood_saves_prev_once")

# dry soil again so a new session can start and persist prev-stats
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
persist.saves = 0
wp1.auto_flood()
assert_eq(persist.saves, 1, "single persist.save for prev-stats batch")
var have = persist.has('P1PrevFloodedVol')
assert_true(have, "PrevFloodedVol written to persist")
assert_true(persist.has('P1SoilHPreFlood'), "SoilHPreFlood written to persist")
assert_true(persist.has('P1LastFloodVol'), "LastFloodVol written to persist")

section("auto_flood_estimate")

# with a completed session state, estimateflood produced a planned volume
assert_true(wp1.plants[0].PlannedFlood > 0, "planned flood volume is positive")

# ---------------- finished ----------------