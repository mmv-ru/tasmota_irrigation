# Characterization: end-of-session handlers: rule_flooded, _autoflood_end,
# timer_endfasttele_after_flooded, button_pressed, rule_button1
import json

section("rule_flooded_turns_pump_off")

# counter hit the finish rule -> pump off
SIM['cmds'] = list()
wp1.plants[0].rule_flooded(350, "COUNTER#C1>=300")
assert_true(cmds_include("Power1 0"), "rule_flooded commands Power1 0")

section("autoflood_end_resets_state")

wp1.plants[0].AutofloodInProcess = true
wp1.plants[0].Counter1ResetPostpone = true
wp1.plants[0].SoilMaxHymidity = 810
wp1.plants[0].SoilMaxHymidityTime = 1700000000
wp1.plants[0].LastFloodVol = 350

wp1.plants[0]._autoflood_end()

assert_eq(wp1.plants[0].AutofloodInProcess, false, "flag cleared")
assert_eq(wp1.plants[0].Counter1ResetPostpone, false, "reset postpone consumed")
assert_eq(wp1.plants[0].SoilMaxHymidity, nil, "max humidity cleared")
assert_eq(wp1.plants[0].PrevFloodedVol, 350, "last flood archived")
assert_true(cmds_include("Counter1 0"), "pending counter reset flushed")
assert_eq(wp1.plants[0].PauseSoilMaxStat, false, "pause lifted")

section("autoflood_end_no_reset_when_not_postponed")

# no reset postpone -> no Counter1 command issued
wp1.plants[0].AutofloodInProcess = true
wp1.plants[0].Counter1ResetPostpone = false
SIM['cmds'] = list()
wp1.plants[0]._autoflood_end()
assert_eq(SIM['cmds'].size(), 0, "no counter reset when not postponed")

section("timer_endfasttele_restores_period")

SIM['cmds'] = list()
wp1.timer_endfasttele_after_flooded()
assert_true(cmds_include("TelePeriod 300"), "fast tele period restored to Tasmota default 300")

section("button_pressed_is_noop")

wp1.button_pressed('', 0, '', nil)
assert_true(true, "button_pressed noop runs")

section("rule_button1_starts_flood")

# rule_button1 triggers start_flood(): dry soil -> relay ON
# DryThreshold forced high so the button picks the normal preset (the dry-soak
# pick is covered by 33_dry_soak).
wp1.plants[0].DryThreshold = 9999
wp1.plants[0].Preset = nil
SIM['cmds'] = list()
wp1.SoilSensors[0].RawWet = 750
wp1.SoilSensors[0].RawEma = 850
wp1.rule_button1({'Action': 'SINGLE'}, 'BUTTON1')
assert_true(cmds_include("Power1 1"), "single press starts flood when dry")

section("rule_button1_skips_when_wet")

# wet soil by EMA -> start_flood refuses, no relay command
SIM['cmds'] = list()
wp1.SoilSensors[0].RawEma = 700
wp1.rule_button1({'Action': 'DOUBLE'}, 'BUTTON1')
assert_true(!cmds_include("Power1 1"), "double press does not start flood when wet")

# ---------------- finished ----------------
