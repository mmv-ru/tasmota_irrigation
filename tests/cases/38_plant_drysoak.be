# Characterization: the dry-soil soak works per channel (channel 2 here) with
# per-channel parameters and no Prev*/estimate persistence.
import json

section("dry_preset_on_second_channel")

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
# isolate channel 2: wet channel 1 so the round-robin sweep skips it
SIM['sensors']['ANALOG']['A1'] = 740
SIM['sensors']['ANALOG']['A2'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilSensors[1].Update(json.load(tasmota.read_sensors()))
assert_true(P2.SoilSensor.RawEma > P2.DryThreshold, "channel 2 soil EMA dry")

persist.saves = 0
SIM['cmds'] = list()
wp1.auto_flood()
assert_eq(P2.AutofloodInProcess, true, "channel 2 session started")
assert_eq(P2.Preset.Type, 'dry', "dry preset on channel 2")
assert_eq(P2.DrySoakDose, 100, "channel 2 soak start dose")
assert_true(cmds_include("Power2 1"), "Power2 commanded")
assert_eq(persist.saves, 0, "dry session does not persist prev-stats")
assert_true(!persist.has('P2PrevFloodedVol'), "no Prev stats for channel 2 dry session")

section("channel2_dry_cadence")

SIM['millis'] = 0
SIM['sensors']['COUNTER']['C1'] = 100
wp1.rule_power({'State': 0}, 'POWER2')
assert_eq(P2.LastFloodVol, 100, "channel 2 volume accumulated")
assert_eq(P2.DryDailyTicks.size(), 1, "daily tick recorded per channel")
var st = SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P2", nil)
assert_true(st != nil, "channel 2 soil check timer armed")
assert_eq(st['delay'], 7200*1000, "channel 2 soak interval (2h)")

section("per_channel_dry_params")

# dry-soak params are per channel: editing channel 1 leaves channel 2 alone
wp1.Store.set('P1SoakStartDose', 200)
assert_eq(wp1.Store.get('P1SoakStartDose'), 200, "P1 soak dose updated")
assert_eq(wp1.Store.get('P2SoakStartDose'), '100', "P2 soak dose independent")
wp1.Store.set('P2DryThreshold', 900)
assert_eq(wp1.Store.get('P1DryThreshold'), '820', "P1 DryThreshold independent")

# ---------------- finished ----------------
