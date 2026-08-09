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

section("power_off_implies_crash")

# CHARACTERIZATION (known deviation): after a wet-stop, Counter1BeforeStart was
# never assigned (nil). A subsequent OFF event therefore crashes with
# "type_error: unsupported operand type(s) for -: 'int' and 'nil'"
# This reproduces watering.be:429 (Counter1 - self.Counter1BeforeStart).
var crashed = false
try
    wp1.rule_power({'State': 0}, 'POWER1')
except .. as e, m
    crashed = true
    print("  caught: " .. str(e) .. ": " .. str(m))
end
assert_true(crashed, "OFF after wet-stop raises an exception (documented bug)")

# ---------------- finished ----------------