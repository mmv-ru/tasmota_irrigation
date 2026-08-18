# Characterization: auto_flood sweep + derived due(). The sweep starts exactly
# one due channel; the post-flood soil check drives repeats via
# request_repeat(); a wet channel closes its session.
import json

section("sweep_starts_one_due_channel")

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
P1.DryThreshold = 9999
P2.DryThreshold = 9999
SIM['sensors']['ANALOG']['A1'] = 900
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
assert_true(P1.due(), "channel 1 due")
assert_true(P2.due(), "channel 2 due")
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P1.AutofloodInProcess, true, "exactly one channel started")
assert_eq(P2.AutofloodInProcess, false, "second channel left pending")
assert_true(cmds_include("Power1 1"), "Power1 commanded")

section("soil_check_repeats_while_dry")

# fill finishes; relay released; soil still dry -> repeat fill requested
SIM['sensors']['COUNTER']['C1'] = 250
tasmota.set_power(0, false)
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(P1.AutofloodInProcess, true, "session open awaiting soil check")
SIM['cmds'] = list()
P1.timer_soil_transition_after_flooded()
assert_true(cmds_include("Power1 1"), "repeat fill commanded")
assert_eq(P1.AutofloodInProcess, true, "session continues")

section("wet_channel_closes_session")

SIM['sensors']['ANALOG']['A1'] = 740
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
P1.timer_soil_transition_after_flooded()
assert_true(!cmds_include("Power1 1"), "no repeat while wet")
assert_eq(P1.AutofloodInProcess, false, "session closed")
assert_eq(P1.Preset, nil, "preset released")
tasmota.set_power(0, false)

section("sweep_picks_next_due_channel")

# channel 1 wet & closed; channel 2 still dry -> next sweep starts channel 2
SIM['sensors']['ANALOG']['A1'] = 740
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P2.AutofloodInProcess, true, "round-robin advances to channel 2")
assert_true(cmds_include("Power2 1"), "Power2 commanded")

# ---------------- finished ----------------
