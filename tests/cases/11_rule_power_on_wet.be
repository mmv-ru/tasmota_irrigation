# Characterization: rule_power State=1 but soil already wet -> stop pump immediately
import json

section("power_on_then_wet_stop")

# A1 wet (750 <= RawWet 750)
SIM['sensors']['ANALOG']['A1'] = 740
SIM['millis'] = 1000
import json
var snap = json.load(tasmota.read_sensors())
wp1.SoilSensors[0].Update(snap)
assert_true(wp1.SoilSensors[0].IsWet(), "sensor sees wet soil")

wp1.rule_power({'State': 1}, 'POWER1')

assert_eq(wp1.Power1, 1, "Power1 flag still set on wet stop")
assert_true(wp1.FinishRule == nil, "no flood rule armed when wet")
assert_true(cmds_include("Power1 0"), "pump turned off immediately")
assert_true(wp1.PauseSoilMaxStat == false, "PauseSoilMaxStat not set on wet stop")

section("power_off_after_wet_stop")

# Counter1BeforeStart is now initialized in init(), so OFF without a
# preceding ON no longer crashes: delta = Counter1 - counter@init = 0.
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(wp1.Power1, 0, "Power1 flag cleared")
assert_true(wp1.FinishRule == nil, "no finish rule to remove")

# ---------------- finished ----------------