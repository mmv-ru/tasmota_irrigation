# Characterization: web_add_buttons and deinit cleanup
import json

section("web_buttons_emit_html")

SIM['webhtml'] = list()
wp1.web_add_main_button()
wp1.web_add_config_button()

var joined = ""
for m: SIM['webhtml'] joined = joined .. m end
assert_true(string.find(joined, "Flow Sensor Calibration") >= 0, "calibration button")
assert_true(string.find(joined, "Reset water counter") < 0, "reset counter button moved off the main page into Common detail")
assert_true(string.find(joined, "Toggle Conf") >= 0, "toggle conf button")

section("deinit_cleans_rules_and_drivers")

# boot registers POWER1/BUTTON1 rules, auto_flood cron+cmd, driver
assert_true(SIM['rules'].find("POWER1") != nil, "POWER1 rule registered at boot")
assert_true(SIM['cmnds'].find("autoflood") != nil, "autoflood cmd registered at boot")

SIM['cmds'] = list()
wp1.plants[0].FinishRule = "COUNTER#C1>=999"
wp1.deinit()

assert_true(SIM['rules'].find("POWER1") == nil, "POWER1 rule removed")
assert_true(SIM['rules'].find("BUTTON1") == nil, "BUTTON1 rule removed")
assert_true(SIM['crons'].find("auto_flood") == nil, "auto_flood cron removed")
assert_true(SIM['cmnds'].find("autoflood") == nil, "autoflood cmd removed")
assert_true(SIM['timers'].find("ID_SOILTRANSITION_AFTERFLOOD_P1") == nil, "soil transition timer removed")
assert_true(SIM['timers'].find("ID_ENDFASTTELE") == nil, "end fast tele timer removed")
assert_true(SIM['rules'].find("COUNTER#C1>=999") == nil, "finish rule removed")
assert_eq(wp1.plants[0].FinishRule, nil, "finish rule ref cleared")
assert_true(cmds_include("Power1 0"), "pump forced off on deinit")
assert_true(SIM['drivers'].find(wp1) == nil, "driver deregistered")

section("deinit_persists")

# by the cleanup, persist.save() had been triggered at least once
assert_true(persist.saves > 0, "persist.save invoked by deinit")

# ---------------- finished ----------------