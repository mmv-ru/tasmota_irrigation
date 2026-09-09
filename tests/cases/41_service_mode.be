# Characterization: service mode (enter/exit/timeout, auto-flood blocking, banner,
# channel control and flow calibration on the /svc page)
import json

section("service_mode_initial_off")

# fresh driver: mode is off, page offers the enable button (no timer armed)
assert_true(!wp1.ServiceMode, "service mode starts off")
webserver.has_arg = def (name) return false end
SIM['webhtml'] = list()
wp1.page_service()
var pinit = ""
for m: SIM['webhtml'] pinit = pinit + m end
assert_true(string.find(pinit, "выключен") >= 0, "page reports the mode as off")
assert_true(string.find(pinit, "name='start' value='1'") >= 0, "enable button present while off")
assert_true(string.find(pinit, "action='?") < 0, "no command args in form actions (GET submit discards them)")
assert_true(string.find(pinit, "<form action='svc'") >= 0, "off-page form posts back to /svc")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "no timeout timer while off")

section("service_mode_enter")

# ?start=1 turns the mode on and arms the fixed 2h timeout
webserver.has_arg = def (name) return name == 'start' end
SIM['timers'] = map()
SIM['webhtml'] = list()
wp1.page_service()
assert_true(wp1.ServiceMode, "service mode enabled by ?start=1")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") != nil, "2h timeout timer armed")
assert_eq(SIM['timers']["ID_SERVICE_MODE_TIMEOUT"]['delay'], 2*60*60*1000, "timeout is exactly 2 hours")
var penter = ""
for m: SIM['webhtml'] penter = penter + m end
assert_true(string.find(penter, "включен") >= 0, "page reports the mode as on")
assert_true(string.find(penter, "Выйти") >= 0, "exit button offered while on")
assert_true(string.find(penter, "action='?") < 0, "no command args in form actions while on")
assert_true(string.find(penter, "<form action='svc'") >= 0, "on-page forms post back to /svc")
assert_true(string.find(penter, "name='pump' value='1'") >= 0 && string.find(penter, "name='on' value='1'") >= 0, "channel ON posts pump/on as hidden inputs")
assert_true(string.find(penter, "name='pump' value='2'") >= 0 && string.find(penter, "name='off' value='1'") >= 0, "channel OFF posts pump/off as hidden inputs")
assert_true(string.find(penter, "name='cal' value='1'") >= 0 && string.find(penter, "name='set' value='1'") >= 0, "calibration commands carry over as hidden inputs")
assert_true(string.find(penter, "name='exit' value='1'") >= 0, "exit posts as hidden input")

section("service_mode_enter_rearms")

# a repeated start re-arms the timer from scratch (fresh 2h window)
SIM['timers'] = map()
webserver.has_arg = def (name) return name == 'start' end
wp1.page_service()
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") != nil, "timeout armed again by a repeated start")
assert_eq(SIM['timers']["ID_SERVICE_MODE_TIMEOUT"]['delay'], 2*60*60*1000, "fresh start re-arms a fresh 2h window")

section("service_mode_blocks_auto_flood")

# with the mode on, none of the flood entry points may start a pump
SIM['cmds'] = list()
wp1.auto_flood()
assert_true(!cmds_include("Power1 1"), "sweep does not start any pump in service mode")
wp1.request_manual(wp1.plants[0])
assert_true(!cmds_include("Power1 1"), "manual start blocked in service mode")
wp1.request_repeat(wp1.plants[0])
assert_true(!cmds_include("Power1 1"), "repeat start blocked in service mode")

section("service_mode_banner_on_main")

# the main page shows a status banner while the mode is active
webserver.has_arg = def (name) return false end
SIM['websend'] = list()
wp1.web_sensor()
var jb = ""
for m: SIM['websend'] jb = jb + m end
assert_true(string.find(jb, "Сервисный режим") >= 0, "banner on the main page while mode on")
assert_true(string.find(jb, "включен") >= 0, "banner reads on")

section("service_mode_exit")

# ?exit=1 turns the mode off and removes the timeout timer
SIM['timers'] = map()
SIM['webhtml'] = list()
webserver.has_arg = def (name) return name == 'exit' end
wp1.page_service()
assert_true(!wp1.ServiceMode, "service mode disabled by ?exit=1")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "timeout timer removed on exit")
var pexit = ""
for m: SIM['webhtml'] pexit = pexit + m end
assert_true(string.find(pexit, "выключен") >= 0, "page reports the mode as off after exit")
assert_true(string.find(pexit, "name='start' value='1'") >= 0, "enable button back after exit")
assert_true(string.find(pexit, "action='?") < 0, "no command args in form actions after exit")

section("service_mode_banner_off_when_idle")

# mode off -> no banner on the main page
SIM['websend'] = list()
wp1.web_sensor()
var jo = ""
for m: SIM['websend'] jo = jo + m end
assert_true(string.find(jo, "Сервисный режим") < 0, "no banner while the mode is off")

section("service_mode_timeout_auto_exit")

# the 2h timeout callback exits the mode and cleans the timer itself
wp1.ServiceMode = true
SIM['timers'] = map()
wp1.service_timeout()
assert_true(!wp1.ServiceMode, "timeout turns the mode off")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "timeout removed the timer")

section("service_mode_page_plain_load_keeps_state")

# merely opening /svc without start/exit must not toggle the mode
var was = wp1.ServiceMode
webserver.has_arg = def (name) return false end
wp1.page_service()
assert_eq(wp1.ServiceMode, was, "plain page load does not change the mode")

# ------------- stage 3: service pump runs + calibration -------------

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
var F0 = wp1.FlowSensors[0]
var St = wp1.Store

section("service_run_ticks_and_result")

# a service pump start captures the shared counter and the run duration; the
# stop reports the raw tick delta in ServiceResult without compensating the
# counter, without a finish rule and without session bookkeeping
wp1.ServiceMode = true
tasmota.set_power(0, false)
tasmota.set_power(1, false)
SIM['sensors']['COUNTER']['C1'] = 500
F0.Update(json.load(tasmota.read_sensors()))
SIM['millis'] = 1000
SIM['cmds'] = list()
SIM['timers'] = map()
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(P1.WaterIsOn(), true, "service pump relay on")
assert_eq(P1.ServiceRun, true, "plant flagged as a service run")
assert_eq(wp1.ServiceResult, nil, "no result before the stop")
assert_eq(P1.Counter1BeforeStart, 500, "shared counter snapshotted at start")
assert_true(cmds_include("TelePeriod 10"), "fast telemetry during the service run")
assert_eq(P1.FinishRule, nil, "no counter finish rule for service runs")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") == nil, "no fast-tele reset timer while running")

# a repeated start while already running is ignored (counter not re-snapped)
var csnap = P1.Counter1BeforeStart
P1.water_on()
assert_eq(P1.ServiceRun, true, "service run survives a repeated start")
assert_eq(P1.Counter1BeforeStart, csnap, "counter snapshot not re-taken")

# stop reports the run
SIM['sensors']['COUNTER']['C1'] = 750
SIM['millis'] = 1000 + 60000
SIM['cmds'] = list()
SIM['timers'] = map()
tasmota.set_power(0, false)
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(P1.WaterIsOn(), false, "service pump relay off")
assert_eq(P1.ServiceRun, false, "service run closed")
var sr1 = wp1.ServiceResult
assert_true(sr1 != nil, "service stop reported a result")
assert_eq(sr1['num'], 1, "result names the channel")
assert_eq(sr1['ticks'], 250, "result carries the raw tick delta")
assert_eq(sr1['millis'], 60000, "result carries the run duration")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") != nil, "fast-tele end timer armed after stop")
assert_eq(F0.RateMeasuring, false, "rate measurement stopped")
assert_true(!cmds_include("counter1"), "shared counter untouched by the service stop")

section("service_calibrate_volume")

# ?cal=1&vol=ml: scale = measured volume / last-run ticks (1000 ml / 250 = 4.0),
# persisted globally via the /svc page
webserver.has_arg = def (name) return name == 'cal' || name == 'vol' end
webserver.arg = def (name, dflt) if name == 'vol' return '1000' end return dflt end
SIM['webhtml'] = list()
wp1.page_service()
assert_eq(F0.Scale, 4.0, "scale derived from volume/ticks (1000/250)")
assert_eq(real(St.get('FlowScale')), 4.0, "calibrated scale persisted")
var lc = wp1.LastCalibration
assert_true(lc != nil, "calibration snapshot recorded")
assert_eq(lc['num'], 1, "snapshot names the calibrated channel")
assert_eq(lc['vol'], 1000, "snapshot keeps the measured volume")
assert_eq(lc['ticks'], 250, "snapshot keeps the run ticks")
assert_eq(lc['millis'], 60000, "snapshot keeps the run duration")
var pcal = ""
for m: SIM['webhtml'] pcal = pcal + m end
assert_true(string.find(pcal, "Калибровка датчика потока") >= 0, "calibration fieldset on the page")
assert_true(string.find(pcal, "4.0000") >= 0, "page shows the current scale")

section("service_calibrate_bad_inputs")

var cs = F0.Scale
webserver.has_arg = def (name) return name == 'cal' end
webserver.arg = def (name, dflt) return dflt end
wp1.page_service()
assert_eq(F0.Scale, cs, "cal without a volume ignored")
webserver.has_arg = def (name) return name == 'cal' || name == 'vol' end
webserver.arg = def (name, dflt) if name == 'vol' return 'abc' end return dflt end
wp1.page_service()
assert_eq(F0.Scale, cs, "non-numeric volume ignored")
webserver.arg = def (name, dflt) if name == 'vol' return '0' end return dflt end
wp1.page_service()
assert_eq(F0.Scale, cs, "zero volume ignored")

section("service_set_scale_manual")

# ?set=1&scale=coef applies and persists a manual ml-per-tick coefficient
webserver.has_arg = def (name) return name == 'set' || name == 'scale' end
webserver.arg = def (name, dflt) if name == 'scale' return '0.5' end return dflt end
wp1.page_service()
assert_eq(F0.Scale, 0.5, "manual coefficient applied")
assert_eq(real(St.get('FlowScale')), 0.5, "manual coefficient persisted")
var ms = F0.Scale
webserver.arg = def (name, dflt) if name == 'scale' return 'abc' end return dflt end
wp1.page_service()
assert_eq(F0.Scale, ms, "non-numeric coefficient ignored")
webserver.arg = def (name, dflt) if name == 'scale' return '0' end return dflt end
wp1.page_service()
assert_eq(F0.Scale, ms, "zero/negative coefficient ignored")

section("service_busy_shared_counter")

# another channel mid-(service)run: the page must reject a second pump start
# (its water would leak into the other run's tick delta)
tasmota.set_power(1, false)
SIM['sensors']['COUNTER']['C1'] = 600
F0.Update(json.load(tasmota.read_sensors()))
SIM['timers'] = map()
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(P1.ServiceRun, true, "P1 service run active")
SIM['cmds'] = list()
webserver.has_arg = def (name) return name == 'pump' || name == 'on' end
webserver.arg = def (name, dflt) if name == 'pump' return '2' end return dflt end
wp1.page_service()
assert_true(!cmds_include("Power2 1"), "page rejected the second pump start (shared C1 busy)")
assert_eq(P2.WaterIsOn(), false, "channel 2 relay untouched")
SIM['sensors']['COUNTER']['C1'] = 800
SIM['timers'] = map()
tasmota.set_power(0, false)
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(P1.ServiceRun, false, "P1 service run stopped")

section("service_page_pump_commands")

# the page issues the relay command; the POWER#State rule then dispatches into
# the service branches (dispatched manually below to mirror the real flow)
webserver.has_arg = def (name) return name == 'pump' || name == 'on' end
webserver.arg = def (name, dflt) if name == 'pump' return '1' end return dflt end
SIM['cmds'] = list()
wp1.page_service()
assert_true(cmds_include("Power1 1"), "page ON issues the relay command")
assert_eq(P1.WaterIsOn(), true, "relay on after page ON")

SIM['cmds'] = list()
wp1.page_service()
assert_true(!cmds_include("Power1 1"), "repeated page ON while already on is a no-op")

webserver.has_arg = def (name) return name == 'pump' || name == 'off' end
SIM['cmds'] = list()
wp1.page_service()
assert_true(cmds_include("Power1 0"), "page OFF issues the relay command")
assert_eq(P1.WaterIsOn(), false, "relay off after page OFF")

webserver.has_arg = def (name) return name == 'pump' || name == 'on' end
webserver.arg = def (name, dflt) if name == 'pump' return '9' end return dflt end
SIM['cmds'] = list()
wp1.page_service()
assert_true(!cmds_include("Power1 1") && !cmds_include("Power5 1"), "out-of-range channel ignored")
webserver.arg = def (name, dflt) if name == 'pump' return 'abc' end return dflt end
wp1.page_service()
assert_true(!cmds_include("Power1 1"), "garbage channel arg ignored")

section("service_exit_stops_running_pump")

# exiting the mode stops a mid-run service pump via the relay; the rule then
# closes the run and fills the result
tasmota.set_power(0, false)
tasmota.set_power(1, false)
SIM['sensors']['COUNTER']['C1'] = 300
F0.Update(json.load(tasmota.read_sensors()))
SIM['timers'] = map()
SIM['cmds'] = list()
tasmota.set_power(0, true)
wp1.rule_power({'State': 1}, 'POWER1')
assert_eq(P1.ServiceRun, true, "service run active before exit")

SIM['cmds'] = list()
wp1.service_exit()
assert_eq(wp1.ServiceMode, false, "mode off after exit")
assert_true(cmds_include("Power1 0"), "exit stops the running service pump")
assert_eq(P1.WaterIsOn(), false, "relay turned off by exit")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "timeout timer cleared on exit")

SIM['sensors']['COUNTER']['C1'] = 400
wp1.rule_power({'State': 0}, 'POWER1')
assert_eq(P1.ServiceRun, false, "service run closed after the rule")
var sr8 = wp1.ServiceResult
assert_true(sr8 != nil, "exit stop reported a result")
assert_eq(sr8['ticks'], 100, "exit stop tick delta (400-300)")

# ---------------- finished ----------------

# ---------------- OFF state: scale + last calibration visible, set without mode ----------------

# the current C1 scale and last-calibration stats stay on /svc after the mode
# is turned off (LastCalibration survived the exit in the section above)
var Fx = wp1.FlowSensors[0]
var Sx = wp1.Store

section("service_off_state_last_calibration_row")

assert_true(!wp1.ServiceMode, "mode off after the exit section")
var pafter = ""
SIM['webhtml'] = list()
webserver.has_arg = def (name) return false end
wp1.page_service()
for m: SIM['webhtml'] pafter = pafter + m end
assert_true(string.find(pafter, "Scale (мл/тик)") >= 0, "current scale shown while off")
assert_true(string.find(pafter, "Последняя калибровка: канал 1, 1000 мл / 250 тиков (4.0000 мл/тик), 60.0 с, 250.0 тиков/мин (1000.0 мл/мин)") >= 0, "last-calibration stats row shown while off")
assert_true(string.find(pafter, "0.5000") >= 0, "current (manual-set) scale rendered while off")
assert_true(string.find(pafter, "name='set' value='1'") >= 0, "direct scale-entry form present while off")
assert_true(string.find(pafter, "name='cal' value='1'") < 0, "volume calibration form not offered while off")

section("service_off_state_scale_and_set_form")

# no calibration yet: no stats row, but scale + direct-entry form still shown
wp1.LastCalibration = nil
wp1.ServiceMode = false
SIM['webhtml'] = list()
wp1.page_service()
var p0 = ""
for m: SIM['webhtml'] p0 = p0 + m end
assert_true(string.find(p0, "Scale (мл/тик)") >= 0, "current scale shown while off (no calibration yet)")
assert_true(string.find(p0, "Последняя калибровка") < 0, "no last-calibration row before the first calibration")
assert_true(string.find(p0, "name='set' value='1'") >= 0, "direct scale-entry form present while off")
assert_true(string.find(p0, "action='?") < 0, "no command args in form actions while off")

# ?set=1&scale=... applies and persists regardless of the mode; no timer, no toggle
SIM['timers'] = map()
webserver.has_arg = def (name) return name == 'set' || name == 'scale' end
webserver.arg = def (name, dflt) if name == 'scale' return '0.7' end return dflt end
Fx.setScale(0.1449)
wp1.page_service()
assert_eq(Fx.Scale, 0.7, "manual coefficient applied while off")
assert_eq(real(Sx.get('FlowScale')), 0.7, "manual coefficient persisted while off")
assert_true(!wp1.ServiceMode, "mode still off after scale set")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "no timeout timer armed by scale set while off")

webserver.arg = def (name, dflt) if name == 'scale' return 'abc' end return dflt end
wp1.page_service()
assert_eq(Fx.Scale, 0.7, "non-numeric coefficient ignored while off")
webserver.arg = def (name, dflt) if name == 'scale' return '0' end return dflt end
wp1.page_service()
assert_eq(Fx.Scale, 0.7, "zero coefficient ignored while off")

section("service_off_state_channels_fieldset")

# the global channel count is a Store variable this page can change: the fieldset
# shows the current number and a form that posts ?channels=N (no mode required).
# NB: the pinned stock Berry fails on chained map indexes (a['x']['y'] -> key_error),
# so read the meta map through a local variable first.
var mch = Sx.Meta['Channels']
assert_eq(mch['default'], "2", "registered default Channels is 2 (runner default)")
assert_eq(Sx.get('Channels'), "4", "persist fixture keeps the suite on 4 channels")
wp1._channels_pending = nil
SIM['webhtml'] = list()
webserver.has_arg = def (name) return false end
wp1.page_service()
var pch = ""
for m: SIM['webhtml'] pch = pch + m end
assert_true(string.find(pch, "<legend>Каналы</legend>") >= 0, "channels fieldset present while off")
assert_true(string.find(pch, "Каналов: <b>4</b>") >= 0, "current channel count shown")
assert_true(string.find(pch, "name='channels'") >= 0, "channels input form present")
assert_true(string.find(pch, "name='restart'") < 0, "no restart form before a change is applied")

section("service_page_channels_invalid")

# out-of-range and non-numeric values are rejected: Store untouched, no restart.
SIM['cmds'] = list()
webserver.has_arg = def (name) return name == 'channels' end
webserver.arg = def (name, dflt) if name == 'channels' return '99' end return dflt end
wp1.page_service()
assert_eq(Sx.get('Channels'), "4", "out-of-range count not persisted")
assert_true(wp1._channels_pending == nil, "no pending change recorded")
webserver.arg = def (name, dflt) if name == 'channels' return 'abc' end return dflt end
wp1.page_service()
assert_eq(Sx.get('Channels'), "4", "non-numeric count not persisted")
assert_true(SIM['timers'].find("ID_SVC_RESTART") == nil, "no restart timer armed by a rejected change")

section("service_page_channels_set_off")

# ?channels=2 persists immediately (store) but does not rebuild until restart;
# the Store parameters of the disabled channels are kept as-is.
SIM['timers'] = map()
webserver.has_arg = def (name) return name == 'channels' end
webserver.arg = def (name, dflt) if name == 'channels' return '2' end return dflt end
SIM['webhtml'] = list()
wp1.page_service()
assert_eq(Sx.get('Channels'), "2", "channels value persisted")
assert_eq(wp1.NumChannels, 4, "NumChannels unchanged until restart")
assert_eq(wp1._channels_pending, 2, "pending change flag stored")
assert_true(SIM['timers'].find("ID_SVC_RESTART") == nil, "no auto-restart on apply")
var pch2 = ""
for m: SIM['webhtml'] pch2 = pch2 + m end
assert_true(string.find(pch2, "Требуется перезагрузка") >= 0, "restart hint rendered after the change")
assert_true(string.find(pch2, "name='restart' value='1'") >= 0, "restart button offered after the change")
assert_eq(Sx.get('P3TargetDry'), "800", "channel 3 params kept after shrinking to 2")
assert_eq(Sx.get('P4TargetWet'), "760", "channel 4 params kept after shrinking to 2")
assert_eq(Sx.get('P3SoakDailyCap'), "1500", "soak param of a disabled channel kept")
assert_true(Sx.Meta.find('P4PrevFloodedVol') != nil, "P4 keys still registered after shrinking")

section("service_page_channels_restart")

# the restart button defers Restart 1 by 1s so the browser gets the response first
SIM['cmds'] = list()
webserver.has_arg = def (name) return name == 'restart' end
SIM['timers'] = map()
wp1.page_service()
assert_true(SIM['timers'].find("ID_SVC_RESTART") != nil, "restart timer armed")
assert_eq(SIM['timers']["ID_SVC_RESTART"]['delay'], 1000, "restart deferred by 1s")
SIM['timers']["ID_SVC_RESTART"]['cb']()
assert_true(cmds_include("Restart 1"), "deferred timer fires Restart 1")

section("service_page_channels_set_on")

# the fieldset is also rendered while the mode is on, and the change is accepted there
webserver.has_arg = def (name) return name == 'start' end
SIM['webhtml'] = list()
wp1.page_service()
assert_true(wp1.ServiceMode, "mode on for the channels-on test")
var pon = ""
for m: SIM['webhtml'] pon = pon + m end
assert_true(string.find(pon, "<legend>Каналы</legend>") >= 0, "channels fieldset rendered while on")
webserver.has_arg = def (name) return name == 'channels' end
webserver.arg = def (name, dflt) if name == 'channels' return '3' end return dflt end
wp1.page_service()
assert_eq(Sx.get('Channels'), "3", "channels value changed while mode on")

# restore: keep the fixture on 4 channels, clear pending state and the mode
wp1.ServiceMode = false
wp1._channels_pending = nil
Sx.set('Channels', '4')
Sx.flush(true)
SIM['timers'] = map()