# Characterization: the shared flow counter C1 strictly serialises fills.
# A repeat/manual start for channel N is deferred (60s retry timer) while
# another channel's relay is ON, then proceeds once the relay is free.
import json

section("repeat_deferred_while_other_channel_pumping")

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
P1.DryThreshold = 9999
P2.DryThreshold = 9999
SIM['sensors']['ANALOG']['A1'] = 900
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
wp1.auto_flood()
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(P1.PowerN, 1, "channel 1 pumping")

# channel 2 is mid-session and its post-flood soil check wants a repeat fill
P2.AutofloodInProcess = true
P2.SoilSensor.Raw = 900
P2.SoilSensor.RawEma = 900
SIM['timers'] = map()
SIM['cmds'] = list()
P2.timer_soil_transition_after_flooded()
assert_true(!cmds_include("Power2 1"), "repeat deferred, no pump command")
var retry = SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P2", nil)
assert_true(retry != nil, "retry timer armed")
assert_eq(retry['delay'], 60*1000, "retry scheduled in 60s")
assert_eq(P2.AutofloodInProcess, true, "channel 2 session kept open")

section("repeat_fires_after_relay_freed")

# channel 1 finishes; the deferred repeat is free to start
SIM['sensors']['COUNTER']['C1'] = 250
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(wp1._flooding_plant(), nil, "no relay ON")

SIM['cmds'] = list()
P2.timer_soil_transition_after_flooded()
assert_true(cmds_include("Power2 1"), "deferred repeat proceeds")
assert_eq(P2.AutofloodInProcess, true, "channel 2 session continues")

section("manual_flood_deferred_during_pump")

# channel 1 pumping again; a manual start for channel 2 must be deferred
P2.AutofloodInProcess = false
P2.PowerN = 0
P2.Preset = nil
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(P1.PowerN, 1, "channel 1 pumping")
SIM['cmds'] = list()
P2.SoilSensor.RawEma = 900
wp1.request_manual(P2)
assert_true(!cmds_include("Power2 1"), "manual start blocked while channel 1 pumping")
assert_eq(P2.AutofloodInProcess, false, "no session started")

# relay freed -> manual start goes through
SIM['sensors']['COUNTER']['C1'] = 250
wp1.rule_power({'State': 0}, 'POWER1')
SIM['cmds'] = list()
wp1.request_manual(P2)
assert_true(cmds_include("Power2 1"), "manual start proceeds when relay free")
assert_true(P2.PlannedFlood > 0, "manual flood planned with a positive dose")

# ---------------- finished ----------------
