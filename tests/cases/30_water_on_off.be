# Characterization: rule_power dispatches to water_on()/water_off()
import json

section("dispatcher_routes_to_water_on")

# dry soil -> water_on starts the pump session
SIM['sensors']['ANALOG']['A1'] = 900
SIM['millis'] = 1000
SIM['cmds'] = list()
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_true(wp1.plants[0].WaterIsOn(), "relay on via dispatcher")
assert_eq(wp1.plants[0].FinishRule, "COUNTER#C1>=200", "finish rule set")
assert_true(cmds_include("TelePeriod 10"), "fast telemetry during pump")

section("water_on_aborts_when_wet")

# wet soil -> water_on stops pump immediately, no new rule from this start
SIM['sensors']['ANALOG']['A1'] = 740
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.plants[0].FinishRule = nil
tasmota.set_power(0, true)
SIM['cmds'] = list()
wp1.plants[0].water_on()
assert_true(cmds_include("Power1 0"), "pump turned off on wet soil")
assert_eq(wp1.plants[0].FinishRule, nil, "no finish rule armed on wet abort")

section("water_on_dry_starts_session")

SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
tasmota.set_power(0, true)
wp1.plants[0].water_on()
assert_true(wp1.plants[0].WaterIsOn(), "pump on")
assert_eq(wp1.plants[0].FinishRule, "COUNTER#C1>=200", "finish rule set")
assert_true(wp1.plants[0].Counter1BeforeStart == 0, "start counter captured")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") == nil, "no pending fast-tele timer")

section("water_off_records_flood")

# counter advanced -> water_off compensates and records the flood
SIM['sensors']['COUNTER']['C1'] = 250
SIM['millis'] = 1000 + 60000
SIM['cmds'] = list()
tasmota.set_power(0, false)
wp1.plants[0].water_off()
assert_true(!wp1.plants[0].WaterIsOn(), "pump off")
assert_true(cmds_include("counter1 250"), "counter preset via water_off")
assert_true(real(wp1.plants[0].LastFloodVol) == 250, "flood volume accumulated")
assert_eq(wp1.plants[0].LastFlowRate, 250.0, "avg flow from volume/pump-run (250ml/min)")
assert_true(wp1.plants[0].FinishRule == nil, "finish rule cleared")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "soil transition timer armed")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") != nil, "fast tele end timer armed")

section("water_off_no_water")

# no counter movement -> session closed without soil check
SIM['sensors']['COUNTER']['C1'] = 0
wp1.plants[0].LastFloodVol = 0
wp1.plants[0].PauseSoilMaxStat = true
wp1.plants[0].AutofloodInProcess = true
SIM['timers'] = map()
SIM['cmds'] = list()
wp1.plants[0].water_off()
assert_eq(wp1.plants[0].PauseSoilMaxStat, false, "pause lifted on empty session")
assert_eq(wp1.plants[0].AutofloodInProcess, false, "session closed without water")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") == nil, "no soil check timer for empty session")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") != nil, "fast tele end timer still armed")

section("dispatcher_unknown_state")

wp1.rule_power({'State': 5}, 'POWER1')
assert_true(true, "unknown state logs warning without crash")

# ---------------- finished ----------------