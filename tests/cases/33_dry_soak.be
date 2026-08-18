# Characterization: dry-soil soak preset (FloodPreset Type='dry').
# Picked when RawEma > DryThreshold: fixed start dose, SoakInterval cadence,
# 24h trend adaptation (escalate/hold), DailyCap pause, StopRaw stop. Does NOT
# write Prev*/estimate stats (WriteStats=false).
import json

section("dry_preset_pick_and_session_start")
var P1 = wp1.plants[0]

# soil clearly dry by EMA above the default DryThreshold 820
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
persist.saves = 0
wp1.auto_flood()

assert_true(P1.Preset != nil && P1.Preset.Type == 'dry', "dry preset picked when RawEma > DryThreshold")
assert_eq(P1.DrySoakDose, 100, "dry soak start dose = SoakStartDose default")
assert_eq(P1.AutofloodInProcess, true, "session started")
assert_eq(P1.PlannedFlood, 100, "planned dose comes from the dry preset")
assert_true(cmds_include("Power1 1"), "pump commanded ON")
assert_eq(persist.saves, 0, "dry session does not persist prev-stats (WriteStats=false)")
assert_true(!persist.has('P1PrevFloodedVol'), "PrevFloodedVol not written by dry session")
assert_true(P1.Preset.AdaptMode == 'trend', "dry preset uses trend adaptation")

# The flood completed (relay released) before the soil checks below run.
tasmota.set_power(0, false)

section("dry_record_flood_uses_soak_interval")

# completed flood under the dry preset -> SoakInterval cadence + daily tracking
SIM['millis'] = 0
P1._record_flood(100)
assert_eq(P1.LastFloodVol, 100, "volume accumulated")
assert_true(P1.DryDailyTicks.size() == 1, "daily tick recorded")
assert_eq(P1.DryDailyTicks[0]['ticks'], 100, "recorded dose")
var st = SIM['timers']['ID_SOILTRANSITION_AFTERFLOOD_P1']
assert_eq(st['delay'], 7200*1000, "SoakInterval (2h) between dry soaks")

section("trend_window_not_full_repeats_same_dose")

# first soil check shortly after the flood: trend window (24h) not full yet,
# same dose repeated without escalation
P1.DryEmaHistory = list()
P1.DrySoakDose = 100
wp1.SoilSensors[0].RawEma = 900
SIM['millis'] = 1000
SIM['cmds'] = list()
P1.timer_soil_transition_after_flooded()
assert_true(cmds_include("Power1 1"), "repeat flood commanded")
assert_eq(P1.DrySoakDose, 100, "no escalation before the trend window fills")
assert_eq(P1.DryEmaHistory.size(), 1, "current EMA recorded into history")

section("trend_no_response_escalates_after_window")

# 24h later the soil still did not respond (RawEma unchanged) -> dose x1.2
P1.DryEmaHistory = list()
P1.DryEmaHistory.push({'ms': 0, 'ema': 900})
P1.DryDailyTicks = list()
P1.DrySoakDose = 100
wp1.SoilSensors[0].RawEma = 900
SIM['millis'] = 24*60*60*1000
SIM['cmds'] = list()
tasmota.set_power(0, false)
P1.timer_soil_transition_after_flooded()
assert_true(cmds_include("Power1 1"), "repeat flood commanded after window")
assert_eq(P1.DrySoakDose, 120, "no response over the window -> dose x1.2")

section("trend_dose_capped_at_maxdose")

# escalation must not exceed SoakMaxDose (2000)
P1.DryEmaHistory = list()
P1.DryEmaHistory.push({'ms': 0, 'ema': 900})
P1.DryDailyTicks = list()
P1.DrySoakDose = 1900
wp1.SoilSensors[0].RawEma = 900
SIM['millis'] = 24*60*60*1000
SIM['cmds'] = list()
tasmota.set_power(0, false)
P1.timer_soil_transition_after_flooded()
assert_eq(P1.DrySoakDose, 2000, "dry dose capped at SoakMaxDose")

section("trend_hold_when_humidity_rising")

# RawEma fell over the window (humidity rising) -> hold, no watering, timer re-armed
P1.DryEmaHistory = list()
P1.DryEmaHistory.push({'ms': 0, 'ema': 900})
P1.DryDailyTicks = list()
P1.DrySoakDose = 100
wp1.SoilSensors[0].RawEma = 850
SIM['millis'] = 24*60*60*1000
SIM['cmds'] = list()
tasmota.set_power(0, false)
P1.timer_soil_transition_after_flooded()
assert_true(!cmds_include("Power1 1"), "no watering while humidity rises")
assert_eq(P1.DrySoakDose, 100, "dose untouched on hold")
var st_h = SIM['timers']['ID_SOILTRANSITION_AFTERFLOOD_P1']
assert_eq(st_h['delay'], 7200*1000, "soil check re-armed after SoakInterval")

section("trend_dailycap_pauses")

# more than SoakDailyCap (1500 ticks) already flooded in the last 24h -> pause
P1.DryEmaHistory = list()
P1.DryEmaHistory.push({'ms': 0, 'ema': 900})
P1.DryDailyTicks = list()
P1.DryDailyTicks.push({'ms': 0, 'ticks': 1500})
P1.DrySoakDose = 100
wp1.SoilSensors[0].RawEma = 900
SIM['millis'] = 24*60*60*1000
SIM['cmds'] = list()
P1.timer_soil_transition_after_flooded()
assert_true(!cmds_include("Power1 1"), "no watering when daily cap reached")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") != nil, "check re-armed after cap pause")

section("trend_stop_below_dry_threshold")

# RawEma dropped below StopRaw (DryThreshold 820) -> soak finished, session closed
P1.DryEmaHistory = list()
P1.DryEmaHistory.push({'ms': 0, 'ema': 900})
P1.DryDailyTicks = list()
P1.AutofloodInProcess = true
wp1.SoilSensors[0].RawEma = 800
SIM['millis'] = 24*60*60*1000
SIM['cmds'] = list()
P1.timer_soil_transition_after_flooded()
assert_eq(P1.AutofloodInProcess, false, "session closed on stop")
assert_eq(P1.Preset, nil, "preset released after dry session")
assert_eq(P1.DrySoakDose, nil, "dry dose reset")
assert_true(!cmds_include("Power1 1"), "no pump command on stop")
assert_true(!persist.has('P1PrevFloodedVol'), "Prev* stats still not polluted")

section("every_second_skips_max_tracking_in_dry")

# WriteStats=false: SoilMaxHymidity must not be captured during a dry session
P1.Preset = FloodPreset('dry', wp1.Store, P1.Prefix)
wp1.SoilSensors[0].RawEma = 900
P1.PauseSoilMaxStat = false
P1.SoilMaxHymidity = nil
wp1.every_second()
assert_eq(P1.SoilMaxHymidity, nil, "no SoilMaxHymidity tracking while dry preset active")
P1.Preset = nil

section("drysoak_cmd_status_and_start")

SIM['lastresp'] = nil
tasmota.resp_cmnd_str = def (m) SIM['lastresp'] = m end
SIM['cmnds']['DrySoak']('DrySoak', 0, '', '')
assert_true(SIM['lastresp'] != nil, "DrySoak reports status")
assert_true(string.find(SIM['lastresp'], 'preset=') >= 0, "status contains preset")

# manual start: forces the dry preset and floods with the start dose
wp1.SoilSensors[0].RawEma = 900
P1.Preset = nil
tasmota.set_power(0, false)
SIM['cmds'] = list()
SIM['cmnds']['DrySoak']('DrySoak', 0, 'start', '')
assert_true(P1.Preset != nil && P1.Preset.Type == 'dry', "start forces dry preset")
assert_true(cmds_include("Power1 1"), "start floods")
assert_eq(P1.PlannedFlood, 100, "manual dry soak uses start dose")
P1._drysoak_end()

section("dry_threshold_restored_after_reboot")

assert_eq(P1.DryThreshold, 820, "DryThreshold default from store")
wp1.Store.set('P1DryThreshold', 900)
wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
assert_eq(P1.DryThreshold, 900, "DryThreshold restored from persistence")

# ---------------- finished ----------------
