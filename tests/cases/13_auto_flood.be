# Characterization: auto_flood() scheduling entry point
import json

section("auto_flood_dry_starts")

# fresh session: sensor must see dry soil for a start, not yet in process
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
assert_true(wp1.SoilSensors[0].IsDry(), "sensor dry")

wp1.auto_flood()

assert_eq(wp1.AutofloodInProcess, true, "flood session started")
assert_true(wp1.PlannedFlood != nil, "planned flood volume set")
assert_eq(wp1.LastFloodVol, 0, "session volume reset to 0")
assert_true(cmds_include("Power1 1"), "pump commanded ON")
assert_eq(wp1.SoilHPreFlood, real(wp1.SoilSensors[0].RawEma), "pre-flood soil level captured")

assert_true(wp1.PrevFloodedVol != nil, "previous session volume preserved")

section("auto_flood_ignored_when_in_process_or_wet")

# already running -> must not double-start
var cmds_len = SIM['cmds'].size()
wp1.auto_flood()
assert_eq(SIM['cmds'].size(), cmds_len, "no double start while in process")

# force end of session, then wet soil -> no start
wp1.AutofloodInProcess = false
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
var have = persist.has('PrevFloodedVol')
assert_true(have, "PrevFloodedVol written to persist")
assert_true(persist.has('SoilHPreFlood'), "SoilHPreFlood written to persist")
assert_true(persist.has('LastFloodVol'), "LastFloodVol written to persist")

section("auto_flood_estimate")

# with a completed session state, estimateflood produced a planned volume
assert_true(wp1.PlannedFlood > 0, "planned flood volume is positive")

# ---------------- finished ----------------