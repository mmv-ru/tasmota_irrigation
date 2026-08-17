# Characterization: web_sensor() -> sequence of web_send_decimal messages
# Uses the module instance stub; has_arg can be overridden per scenario.
import json

section("web_sensor_no_args")

SIM['websend'] = list()
wp1.plants[0].SoilMaxHymidity = nil
wp1.plants[0].LastFloodTime = nil
wp1.web_sensor()

assert_true(SIM['websend'].size() >= 3, "base rows emitted for both soil + flow sensors")
var joined = ""
for m: SIM['websend'] joined = joined .. m end
assert_true(string.find(joined, "Канал 1") >= 0, "soil humidity label")
assert_true(string.find(joined, "Канал 2") >= 0, "second soil humidity label")
assert_true(string.find(joined, "Water used") >= 0, "flow water used")

section("web_sensor_max_shown_when_confirmed")

# when max humidity known and soil1 section expanded (me=1 in the request),
# an extra row with value + time appears
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '1' : dflt end
wp1.plants[0].SoilMaxHymidity = 840
wp1.plants[0].SoilMaxHymidityTime = SIM['rtc_local']
SIM['websend'] = []
wp1.web_sensor()
var j2 = ""
for m: SIM['websend'] j2 = j2 + m end
assert_true(string.find(j2, "SoilHymidity1 max") >= 0, "max humidity row")
assert_true(string.find(j2, "Dry soak") >= 0, "dry soak row under soil1 detail")
assert_true(string.find(j2, "Dry threshold") >= 0, "dry threshold row under soil1 detail")
# grouped detail body: settings stack (Сухо/Влажно), group labels, no legacy pipes
assert_true(string.find(j2, "Сухо</th>") >= 0, "dry setting row (stacked)")
assert_true(string.find(j2, "Влажно</th>") >= 0, "wet setting row (stacked)")
assert_true(string.find(j2, "54.2% u") >= 0, "calibrated %u line under dry raw value")
assert_true(string.find(j2, "Размачивание") >= 0, "dry-soak group label")
assert_true(string.find(j2, "Текущий сеанс") >= 0, "current-session group label")
assert_true(string.find(j2, "Предыдущий сеанс") >= 0, "previous-session group label")
assert_true(string.find(j2, "| TargetDry") < 0, "legacy TargetDry pipe row gone")

section("web_sensor_expand_is_per_request")

# expand is per-request: the same state with me= (collapsed) must NOT emit the
# max row, even though a previous request asked for it
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '' : dflt end
SIM['websend'] = []
wp1.web_sensor()
var j3 = ""
for m: SIM['websend'] j3 = j3 + m end
assert_true(string.find(j3, "SoilHymidity1 max") < 0, "no max row when me= (collapsed)")
assert_true(string.find(j3, "Dry soak") < 0, "no dry soak row when me= (collapsed)")

section("web_sensor_flow_expand")

# Common (flow) section expands with me=c (c is the Common flag char)
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? 'c' : dflt end
wp1.FlowSensors[0].RawRate = 5
SIM['websend'] = []
wp1.web_sensor()
var j4 = ""
for m: SIM['websend'] j4 = j4 + m end
assert_true(string.find(j4, "Common") >= 0, "Common section label")
assert_true(string.find(j4, "pulse/s") >= 0, "flow detail row present when me=c")
assert_true(string.find(j4, "ml/min") >= 0, "flow rate row present when me=c")
assert_true(string.find(j4, "FlowSensor Calibration mode") >= 0, "calibration row under Common when me=c")
assert_true(string.find(j4, "Water counter") >= 0, "reset counter row under Common when me=c")
assert_true(string.find(j4, "confirm(") >= 0, "reset counter row carries a JS confirm popup")
assert_true(string.find(j4, "m_reset_water_counter_1") >= 0, "reset counter row posts the reset arg")
assert_true(string.find(j4, "Сеанс полива</th>") < 0, "session row is expanded-soil detail only (soil collapsed with me=c)")

section("web_sensor_flow_collapsed")

# without the c flag no Common detail rows appear; session/pump rows are
# per-channel expanded-soil detail only (the header carries the status icon)
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '' : dflt end
SIM['websend'] = []
wp1.web_sensor()
var j5 = ""
for m: SIM['websend'] j5 = j5 + m end
assert_true(string.find(j5, "pulse/s") < 0, "no flow detail row when me= (collapsed)")
assert_true(string.find(j5, "Water counter") < 0, "no reset counter row when me= (collapsed)")
assert_true(string.find(j5, "Сеанс полива</th>") < 0, "no session row in compact")
assert_true(string.find(j5, "Вода</th>") < 0, "no pump row in compact")
assert_eq(string.split(j5, "class='st wait'").size(), 5, "waiting status icon shown in every channel header (4 channels)")

section("web_sensor_per_channel_detail")

# every channel expands on its own flag: me=2 must show channel 2's detail
# (its own max + dry rows), not channel 1's.
wp1.plants[1].SoilMaxHymidity = 771
wp1.plants[1].SoilMaxHymidityTime = SIM['rtc_local']
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '2' : dflt end
SIM['websend'] = []
wp1.web_sensor()
var j6 = ""
for m: SIM['websend'] j6 = j6 + m end
assert_true(string.find(j6, "SoilHymidity2 max") >= 0, "channel 2 max shown when me=2")
assert_true(string.find(j6, "SoilHymidity2 max time") >= 0, "channel 2 max time shown when me=2")
assert_true(string.find(j6, "LastFloodVol") >= 0, "channel 2 session row shown when me=2")
assert_true(string.find(j6, "SoilHymidity1 max") < 0, "channel 1 max hidden when me=2")

# session is per-channel: channel 2 active -> only its row reads active, and
# the pump row reads idle (relay off). Icon switches from waiting to session.
wp1.plants[1].AutofloodInProcess = true
SIM['websend'] = []
wp1.web_sensor()
var j6b = ""
for m: SIM['websend'] j6b = j6b + m end
assert_true(string.find(j6b, "Сеанс полива</th>") >= 0, "session row under expanded channel 2")
assert_eq(string.split(j6b, "Сеанс полива</th>").size(), 2, "only the active channel shows its session row (one yes)")
assert_true(string.find(j6b, "Сеанс полива</th><td>active") >= 0, "session row reads active for active channel")
assert_true(string.find(j6b, "Вода</th><td>idle") >= 0, "pump row reads idle (relay off)")
assert_true(string.find(j6b, "class='st sess'") >= 0, "header icon switched from waiting to session")
assert_eq(string.split(j6b, "class='st wait'").size(), 4, "other channels still show the waiting icon (3 + none for active)")
wp1.plants[1].AutofloodInProcess = false

section("web_sensor_pump_run")

# pump running on channel 2 (me=2): header icon is the run state and the pump
# row reads run with the live flow rate (ml/min) while the pump is on
wp1.plants[1].PowerN = 1
wp1.FlowSensors[0].RawRate = 10
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '2' : dflt end
SIM['websend'] = []
wp1.web_sensor()
var j8 = ""
for m: SIM['websend'] j8 = j8 + m end
assert_true(string.find(j8, "class='st run'") >= 0, "header icon is the run state")
assert_true(string.find(j8, "Вода</th><td>run") >= 0, "pump row reads run when relay on")
assert_true(string.find(j8, "ml/min") >= 0, "live flow rate shown while pump runs")
wp1.plants[1].PowerN = 0
wp1.FlowSensors[0].RawRate = nil

section("web_sensor_channels_header_count")

# one accordion header per configured channel (default Channels=4)
webserver.has_arg = def (name) return false end
webserver.arg = def (name, dflt) return dflt end
SIM['websend'] = []
wp1.web_sensor()
var j7 = ""
for m: SIM['websend'] j7 = j7 + m end
assert_eq(string.split(j7, "Канал 1<span").size(), 2, "channel 1 header present")
assert_eq(string.split(j7, "Канал 4<span").size(), 2, "channel 4 header present (NumChannels=4)")
assert_true(string.find(j7, "Канал 5<span") < 0, "no header beyond NumChannels")

# ---------------- finished ----------------