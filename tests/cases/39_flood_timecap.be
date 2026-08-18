# Characterization: per-channel pump time cap (MaxPumpRun -> PulseTime{Num})
# and the shared-counter finish rule.
import json

section("per_channel_pulsetime")

# init arms a PulseTime cap on every channel's relay
assert_true(cmds_include('PulseTime1:{'), "PulseTime1 armed at init")
assert_true(cmds_include('PulseTime2:{'), "PulseTime2 armed at init")
assert_true(cmds_include('PulseTime3:{'), "PulseTime3 armed at init")
assert_true(cmds_include('PulseTime4:{'), "PulseTime4 armed at init")
assert_eq(wp1.pulseencode(60), 160, "60s cap encodes as PulseTime 160")
assert_eq(wp1.pulseencode(-5), 0, "negative cap clamped to 0")

section("per_channel_relay_and_finish_rule")

var P2 = wp1.plants[1]
P2.DryThreshold = 9999
SIM['sensors']['ANALOG']['A1'] = 740
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P2.AutofloodInProcess, true, "channel 2 session started")
assert_true(cmds_include("Power2 1"), "channel 2 pump commanded")
tasmota.set_power(1, true)
wp1.rule_power({'State': 1}, 'POWER2')
assert_true(P2.WaterIsOn(), "channel 2 relay ON")
assert_eq(P2.FinishRule, "COUNTER#C1>=200", "finish rule on the shared counter")

section("time_cap_recorded_on_release")

# relay auto-off (hardware PulseTime cap) arrives as POWER2 0
SIM['sensors']['COUNTER']['C1'] = 150
tasmota.set_power(1, false)
wp1.rule_power({'State': 0}, 'POWER2')
assert_true(!P2.WaterIsOn(), "channel 2 relay released")
assert_true(real(P2.LastFloodVol) == 150, "volume up to the cap recorded")
assert_eq(P2.Preset.Type, 'normal', "channel 2 used the normal preset")

# ---------------- finished ----------------
