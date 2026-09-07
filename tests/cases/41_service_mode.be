# Characterization: service mode (enter/exit/timeout, auto-flood blocking, banner)
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
assert_true(string.find(pinit, "?enter=1") >= 0, "enable button present while off")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") == nil, "no timeout timer while off")

section("service_mode_enter")

# ?enter=1 turns the mode on and arms the fixed 2h timeout
webserver.has_arg = def (name) return name == 'enter' end
SIM['timers'] = map()
SIM['webhtml'] = list()
wp1.page_service()
assert_true(wp1.ServiceMode, "service mode enabled by ?enter=1")
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") != nil, "2h timeout timer armed")
assert_eq(SIM['timers']["ID_SERVICE_MODE_TIMEOUT"]['delay'], 2*60*60*1000, "timeout is exactly 2 hours")
var penter = ""
for m: SIM['webhtml'] penter = penter + m end
assert_true(string.find(penter, "включен") >= 0, "page reports the mode as on")
assert_true(string.find(penter, "Выйти") >= 0, "exit button offered while on")

section("service_mode_enter_rearms")

# a repeated enter re-arms the timer from scratch (fresh 2h window)
SIM['timers'] = map()
webserver.has_arg = def (name) return name == 'enter' end
wp1.page_service()
assert_true(SIM['timers'].find("ID_SERVICE_MODE_TIMEOUT") != nil, "timeout re-armed by repeated enter")
assert_eq(SIM['timers']["ID_SERVICE_MODE_TIMEOUT"]['delay'], 2*60*60*1000, "re-enter starts a fresh 2h window")

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
assert_true(string.find(pexit, "?enter=1") >= 0, "enable button back after exit")

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

# merely opening /svc without enter/exit must not toggle the mode
var was = wp1.ServiceMode
webserver.has_arg = def (name) return false end
wp1.page_service()
assert_eq(wp1.ServiceMode, was, "plain page load does not change the mode")

# ---------------- finished ----------------