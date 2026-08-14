# Characterization: rule_power ON/Power1 1 -> start flood (dry soil)
import json

section("power_on_dry")

# A1 dry (900 >= RawDry 800)
SIM['sensors']['ANALOG']['A1'] = 900
SIM['millis'] = 1000

var before = real(wp1.FlowSensors[0].Raw)
wp1.rule_power({'State': 1}, 'POWER1')

assert_eq(wp1.plants[0].PowerN, 1, "Power1 flag set")
assert_true(wp1.plants[0].PauseSoilMaxStat == true, "PauseSoilMaxStat set while pumping")
assert_true(wp1.plants[0].FinishRule != nil, "Finishing rule armed")
assert_eq(before, real(wp1.FlowSensors[0].Raw), "FlowSensors[0] before start")
assert_true(cmds_include("TelePeriod 10"), "fast telemetry during pump")
assert_true(cmds_include("PulseTime1"), "PulseTime configured at init")
# ---------------- finished ----------------