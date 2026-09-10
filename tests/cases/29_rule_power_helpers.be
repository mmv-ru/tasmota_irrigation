# Characterization: rule_power OFF-branch helpers: _compensate_backflow,
# _record_flood, _end_session_no_water
import json

section("compensate_backflow_above_backflow")

# Clean 2.0 ml/tick calibration so ml <-> ticks are integers; backflow is
# expressed in ml (133 ticks = 266 ml).
wp1.FlowSensors[0].Scale = 2.0
# backflow 0 (default): full delta returned, counter preset to post-backflow value
wp1.plants[0].Counter1BeforeStartTicks = 100
SIM['cmds'] = list()
var d = wp1.plants[0]._compensate_backflow(300)
assert_eq(d, 200, "delta net of backflow (Backflow=0)")
assert_true(cmds_include("counter1 300"), "counter preset to read value when no backflow")

section("compensate_backflow_subtracts_backflow")

# 266 ml backflow = 133 ticks at the 2.0 ml/tick scale
wp1.plants[0].Counter1Backflow = 266
wp1.plants[0].Counter1BeforeStartTicks = 100
SIM['cmds'] = list()
d = wp1.plants[0]._compensate_backflow(533)
assert_eq(d, 300, "delta net of backflow 533-100-133")
assert_true(cmds_include("counter1 400"), "counter preset minus backflow")
wp1.plants[0].Counter1Backflow = 0

section("compensate_backflow_delta_below_backflow")

# pump ran but net delta <= backflow -> no water counted, counter set back to start
wp1.plants[0].Counter1Backflow = 266
wp1.plants[0].Counter1BeforeStartTicks = 100
SIM['cmds'] = list()
d = wp1.plants[0]._compensate_backflow(150)
assert_eq(d, 0, "no net water after backflow")
assert_true(cmds_include("counter1 100"), "counter preset back to start value")
wp1.plants[0].Counter1Backflow = 0

section("record_flood_accumulates_and_arms_timer")

SIM['cmds'] = list()
# raise the session cap so the flood below neither records nor cuts the timer
wp1.plants[0].MaxFlood = 2000
wp1.plants[0].LastFloodVol = 0
wp1.plants[0].PumpRunMillis = 60000
wp1.plants[0]._record_flood(250)
assert_eq(wp1.plants[0].LastFloodVol, 500, "volume accumulated (250 ticks x 2.0 ml)")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "soil transition timer armed")
var st = SIM['timers']['ID_SOILTRANSITION_AFTERFLOOD_P1']
assert_eq(st['delay'], 2*60*60*1000, "2h default flood interval")
assert_eq(wp1.plants[0].LastFloodTime, SIM['rtc_local'], "last flood time recorded")
assert_eq(wp1.plants[0].LastFlowRate, 500.0, "avg flow = dose over 1min run (500ml/min)")

section("record_flood_replaces_pending_timer")

# re-arm: a pending short timer must be replaced by the new one
wp1.plants[0].LastFloodVol = 0
wp1.plants[0]._record_flood(100)
var st3 = SIM['timers']['ID_SOILTRANSITION_AFTERFLOOD_P1']
assert_eq(st3['delay'], 2*60*60*1000, "timer re-armed to 2h interval")

section("record_flood_ends_session_over_maxflood")

# accumulated volume above MaxFlood closes the normal session instead of
# arming the 2h soil check (the removed 24h delay behaviour) - the next day's
# scheduler starts a fresh session anyway. The pending soil timer is removed.
wp1.plants[0].MaxFlood = 1000
wp1.plants[0].LastFloodVol = 0
wp1.plants[0].AutofloodInProcess = true
wp1.plants[0]._record_flood(250)
assert_eq(wp1.plants[0].LastFloodVol, 500, "volume accumulated below the cap")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "soil timer armed below the cap")
assert_eq(wp1.plants[0].AutofloodInProcess, true, "session stays active below the cap")

wp1.plants[0]._record_flood(300)
assert_eq(wp1.plants[0].LastFloodVol, 1100, "volume accumulated over the cap")
assert_eq(wp1.plants[0].AutofloodInProcess, false, "session closed by the volume cap")
assert_eq(wp1.plants[0].PrevFloodedVol, 1100, "capped volume archived as PrevFloodedVol")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") == nil, "soil timer removed on cap")

section("end_session_no_water_resets_state")

wp1.plants[0].PauseSoilMaxStat = true
wp1.plants[0].AutofloodInProcess = true
wp1.plants[0]._end_session_no_water()
assert_eq(wp1.plants[0].PauseSoilMaxStat, false, "pause lifted")
assert_eq(wp1.plants[0].AutofloodInProcess, false, "session closed without soil check timer")

section("rule_power_off_backflow_zero_session")

# full OFF-branch through rule_power: delta above backflow records a flood
SIM['sensors']['COUNTER']['C1'] = 200
wp1.plants[0].Counter1BeforeStartTicks = 0
wp1.plants[0].LastFloodVol = 0
wp1.plants[0].AutofloodInProcess = true
SIM['cmds'] = list()
wp1.rule_power({'State': 0}, 'POWER1')
assert_true(cmds_include("counter1 200"), "counter preset via OFF branch")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "soil timer armed from record_flood")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") != nil, "fast tele end timer armed")

# ---------------- finished ----------------