# Characterization: full flood cycle with counter compensation and timers
import json

section("flood_cycle_setup")

# dry soil, start pump. Use a clean calibration (0.5 ml/tick) so the ml values
# stay integers: 30 ml default dose = 60 ticks, and 350 ticks = 175 ml stays
# below the 300 ml session cap (the cycle must not be cut short).
wp1.FlowSensors[0].Scale = 0.5
SIM['sensors']['ANALOG']['A1'] = 900
SIM['millis'] = 5000
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(wp1.plants[0].FinishRule, "COUNTER#C1>=60", "default finish rule (30 ml/0.5 = 60 ticks)")
assert_true(wp1.plants[0].WaterIsOn(), "pump on")

section("counter_reaches_limit")

# counter advances past the flood default (60 ticks) -> flooding complete
SIM['sensors']['COUNTER']['C1'] = 350
# rule_flooded fires with the counter value
wp1.plants[0].rule_flooded(350, "COUNTER#C1>=60")
assert_true(cmds_include("Power1 0"), "rule_flooded turns pump off")

section("pump_off_compensation")

# pump reports OFF after the flooded rule; counter delta = 350 - 0(start) = 350
tasmota.set_power(0, false)
wp1.rule_power({'State': 0}, 'POWER1')
assert_true(!wp1.plants[0].WaterIsOn(), "pump off")
assert_true(cmds_include("counter1 350"), "counter compensated by full delta")
assert_true(wp1.plants[0].LastFloodVol != nil && real(wp1.plants[0].LastFloodVol) == 175, "LastFloodVol accumulated (350 ticks x 0.5 ml)")
assert_true(wp1.plants[0].FinishRule == nil, "finish rule cleared")
assert_eq(wp1.plants[0].PauseSoilMaxStat, true, "PauseSoilMaxStat still set (waiting for soil transition)")

section("timers_after_flood")

assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "soil transition timer armed")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") != nil, "fast tele end timer armed")
var st = SIM['timers']['ID_SOILTRANSITION_AFTERFLOOD_P1']
assert_eq(st['delay'], 2*60*60*1000, "2h default flood interval")

# ---------------- finished ----------------