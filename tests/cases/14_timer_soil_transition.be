# Characterization: timer_soil_transition_after_flooded()
# After flood interval elapsed, soil is checked: if too dry -> repeat flood,
# if wet enough -> end session.
import json

section("soil_still_dry_repeats_flood")

# simulate completed flood session, then soil still dry at check time
# DryThreshold forced high: characterises the normal/escalate preset, not the
# dry-soak trend path (covered by 33_dry_soak).
wp1.plants[0].DryThreshold = 9999
wp1.plants[0].Preset = nil
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
var before_default = real(wp1.plants[0].Counter1FloodDefault)
wp1.plants[0].AutofloodInProcess = true

# ensure pre-flood level captured (>= to trigger repeat branch)
wp1.plants[0].SoilHPreFlood = 900
SIM['sensors']['ANALOG']['A1'] = 890
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))

wp1.plants[0].timer_soil_transition_after_flooded()

assert_true(cmds_include("Power1 1"), "repeat flood commanded ON")
assert_true(wp1.plants[0].Counter1FloodDefault > before_default, "flood default escalated (x1.2)")
assert_eq(wp1.plants[0].AutofloodInProcess, true, "session still active")

section("timer_soil_wet_ends_session")

# soil reached wet level -> session should finish
wp1.plants[0].AutofloodInProcess = true
SIM['sensors']['ANALOG']['A1'] = 740
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
var flood_vol = 350
wp1.plants[0].LastFloodVol = flood_vol

wp1.plants[0].timer_soil_transition_after_flooded()

assert_eq(wp1.plants[0].AutofloodInProcess, false, "session ended when wet")
assert_eq(wp1.plants[0].PrevFloodedVol, flood_vol, "previous flood vol archived")
assert_eq(wp1.plants[0].SoilMaxHymidity, nil, "soil max humidity cleared")
assert_eq(wp1.plants[0].PauseSoilMaxStat, false, "pause lifted after session")

section("timer_soil_repeat_default_capped_at_maxflood")

# repeated flood escalation must not exceed MaxFlood
wp1.plants[0].MaxFlood = 1000
wp1.plants[0].Counter1FloodDefault = 900
wp1.plants[0].AutofloodInProcess = true
wp1.plants[0].SoilHPreFlood = 900
SIM['sensors']['ANALOG']['A1'] = 890
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))

wp1.plants[0].timer_soil_transition_after_flooded()

assert_true(cmds_include("Power1 1"), "repeat flood still commanded")
assert_eq(wp1.plants[0].Counter1FloodDefault, 1000, "flood default capped at MaxFlood")

# ---------------- finished ----------------