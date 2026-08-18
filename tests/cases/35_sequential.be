# Characterization: multi-channel serialisation. One pump relay runs at a time
# (shared flow counter C1); the auto_flood sweep is round-robin and starts at
# most one due channel per invocation.
import json

section("sequential_one_channel_at_a_time")

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
P1.DryThreshold = 9999
P2.DryThreshold = 9999
SIM['sensors']['ANALOG']['A1'] = 900
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
assert_true(P1.due(), "channel 1 dry and due")
assert_true(P2.due(), "channel 2 dry and due")

SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P1.AutofloodInProcess, true, "channel 1 session started")
assert_true(cmds_include("Power1 1"), "Power1 commanded")
assert_true(!cmds_include("Power2 1"), "channel 2 not started")
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_true(P1.WaterIsOn(), "channel 1 relay ON")

section("sweep_skipped_while_relay_on")

# relay still ON -> the sweep must not start anything, even a due channel
var clen = SIM['cmds'].size()
wp1.auto_flood()
assert_eq(SIM['cmds'].size(), clen, "sweep skipped while channel 1 pumping")
assert_eq(P2.AutofloodInProcess, false, "channel 2 still waiting")

section("next_due_channel_wins_round_robin")

# channel 1 fill finishes (relay OFF, water recorded)
SIM['sensors']['COUNTER']['C1'] = 250
tasmota.set_power(0, false)
wp1.rule_power({'State': 0}, 'POWER1')
assert_true(!P1.WaterIsOn(), "channel 1 relay released")
assert_eq(P1.AutofloodInProcess, true, "channel 1 session still pending its soil check")

# next sweep: channel 1 is not due (session open), channel 2 takes the slot
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P2.AutofloodInProcess, true, "channel 2 started next")
assert_true(cmds_include("Power2 1"), "Power2 commanded")
tasmota.set_power(1, true)
wp1.rule_power({'State': 1}, 'POWER2')
assert_true(P2.WaterIsOn(), "channel 2 relay ON")

section("round_robin_wraps_to_first")

# channel 2 finishes; close both sessions (wet soil -> autoflood_end)
SIM['sensors']['COUNTER']['C1'] = 500
tasmota.set_power(1, false)
wp1.rule_power({'State': 0}, 'POWER2')
SIM['sensors']['ANALOG']['A1'] = 740
SIM['sensors']['ANALOG']['A2'] = 740
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
P1.timer_soil_transition_after_flooded()
P2.timer_soil_transition_after_flooded()
assert_eq(P1.AutofloodInProcess, false, "channel 1 session closed")
assert_eq(P2.AutofloodInProcess, false, "channel 2 session closed")

# both dry again: the rr pointer wrapped past channel 2, so channel 1 starts
SIM['sensors']['ANALOG']['A1'] = 900
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P1.AutofloodInProcess, true, "round-robin wraps back to channel 1")
assert_true(cmds_include("Power1 1"), "Power1 commanded again")

# ---------------- finished ----------------
