# Characterization: global "Out of Water" detection. FlowRateLimit (ml/min,
# global Store key, 0 = off) applies to every channel: any ACTIVE channel
# (pump on) whose live Rate*60 stays below the limit for 5 s flips the global
# OutOfWater flag; recovery / pump-off clears it. /svc exposes ?flowlimit=N.
import json
import introspect

section("init_defaults_from_registry")

assert_eq(wp1.FlowRateLimit, 0, "FlowRateLimit default 0 (disabled)")
assert_eq(wp1.Store.get('FlowRateLimit'), '0', "FlowRateLimit registered with 0 default")
assert_eq(wp1.OutOfWater, false, "OutOfWater starts false")
assert_eq(wp1.UnwaterSeconds, 0, "low-flow counter starts 0")

section("disabled_limit_never_trips")

# limit 0 -> even a crawl flow (RawRate 1 tick/s ~ 8.7 ml/min) never trips
wp1.FlowSensors[0].RawRate = 1.0
SIM_POWER[0] = true
for i: 0..9
    wp1.every_second()
end
assert_eq(wp1.OutOfWater, false, "limit 0: flag stays false despite low flow")
assert_eq(wp1.UnwaterSeconds, 0, "limit 0: counter not armed")
SIM_POWER[0] = false

section("store_override_reads_on_init")

# persisted limit works across a reboot
introspect.set(persist, 'FlowRateLimit', '60')
wp1.deinit()
wp1 = Watering()
assert_eq(wp1.FlowRateLimit, 60, "FlowRateLimit read from Store after reboot")
assert_eq(wp1.Store.get('FlowRateLimit'), '60', "Store value kept after reboot")
assert_eq(wp1.OutOfWater, false, "fresh boot: OutOfWater false")
assert_eq(wp1.UnwaterSeconds, 0, "fresh boot: counter 0")

section("grace_period_before_flag")

# 60 ml/min limit = 1 ml/s. RawRate 6 ticks/s * 0.1449 = 0.8694 ml/s = 52 ml/min -> low.
# The grace window is 5 consecutive seconds at sub-limit flow.
wp1.FlowSensors[0].RawRate = 6.0
SIM_POWER[0] = true
for i: 0..3
    wp1.every_second()
end
assert_eq(wp1.UnwaterSeconds, 4, "4 s below limit: counter at 4")
assert_eq(wp1.OutOfWater, false, "4 s below limit: not yet flagged")
wp1.every_second()
assert_eq(wp1.OutOfWater, true, "5 s below limit: OutOfWater set")
assert_eq(wp1.UnwaterSeconds, 5, "counter keeps counting while dry")

section("recovery_clears_flag")

# back above the limit (RawRate 10 -> 1.449 ml/s -> 87 ml/min)
wp1.FlowSensors[0].RawRate = 10.0
wp1.every_second()
assert_eq(wp1.OutOfWater, false, "flow restored: flag cleared")
assert_eq(wp1.UnwaterSeconds, 0, "flow restored: counter reset")

section("pump_off_clears_flag")

# dry again but pump off -> no low-flow, flag stays clear
wp1.FlowSensors[0].RawRate = 6.0
SIM_POWER[0] = false
for i: 0..5
    wp1.every_second()
end
assert_eq(wp1.OutOfWater, false, "pump off: sub-limit flow is not counted")
assert_eq(wp1.UnwaterSeconds, 0, "pump off: counter stays 0")

section("any_channel_triggers_and_idle_ignored")

# channel 2's pump on + shared C1 meter low trips the global flag (channel 1 off)
wp1.FlowSensors[0].RawRate = 6.0
SIM_POWER[1] = true
for i: 0..4
    wp1.every_second()
end
assert_eq(wp1.OutOfWater, true, "channel 2 active with low shared flow trips global flag")
SIM_POWER[1] = false

# all pumps off, meter crawls -> still no flag
wp1.FlowSensors[0].RawRate = 0.5
for i: 0..5
    wp1.every_second()
end
assert_eq(wp1.OutOfWater, false, "no active channel: low shared flow does not trip (pump off)")

section("banner_on_main_page")

# banner appears on the main page while the flag is set
wp1.FlowSensors[0].RawRate = 6.0
SIM_POWER[2] = true
for i: 0..4
    wp1.every_second()
end
assert_eq(wp1.OutOfWater, true, "sanity: flag set for banner test")
SIM['websend'] = list()
webserver.has_arg = def (name) return false end
wp1.web_sensor()
var joined = ""
for m: SIM['websend'] joined = joined .. m end
assert_true(string.find(joined, "Нет воды") >= 0, "main page shows 'Нет воды' banner")
SIM_POWER[2] = false

section("telemetry_contains_outofwater")

SIM['append'] = list()
wp1.json_append()
var tele = ""
for a: SIM['append'] tele = tele .. a end
assert_true(string.find(tele, '"OutOfWater":true') >= 0, "telemetry exports OutOfWater:true")
# flag cleared -> false
assert_true(string.find(tele, "true") >= 0, "sanity: telemetry contains true")
wp1.FlowSensors[0].RawRate = 99.0
SIM_POWER[0] = true
wp1.every_second()
SIM['append'] = list()
wp1.json_append()
tele = ""
for a: SIM['append'] tele = tele .. a end
assert_true(string.find(tele, '"OutOfWater":false') >= 0, "telemetry exports OutOfWater:false when restored")
SIM_POWER[0] = false

section("svc_page_argument_sets_limit")

# ?flowlimit=N updates live value + Store (debounced), markup shows the field
SIM['webhtml'] = list()
webserver.has_arg = def (name) return name == 'flowlimit' end
webserver.arg = def (name, dflt) return name == 'flowlimit' ? '120' : dflt end
wp1.page_service()
assert_eq(wp1.FlowRateLimit, 120, "svc ?flowlimit=120 updates live FlowRateLimit")
assert_eq(wp1.Store.get('FlowRateLimit'), '120', "svc ?flowlimit=120 persists to Store")
SIM['webhtml'] = list()
webserver.has_arg = def (name) return false end
wp1.page_service()
var page = ""
for h: SIM['webhtml'] page = page .. h end
assert_true(string.find(page, "flowlimit") >= 0, "/svc renders flowlimit input")
assert_true(string.find(page, "ml/min") >= 0, "/svc shows units ml/min")
assert_true(string.find(page, "<form action='svc' style='display: block;' method='get'><input name='flowlimit'") >= 0, "/svc flowlimit is inside a real GET form (button submits)")

section("svc_page_garbage_rejected")

# non-numeric / negative values leave the limit untouched (debounced)
webserver.has_arg = def (name) return name == 'flowlimit' end
webserver.arg = def (name, dflt) return 'abc' end
wp1.page_service()
assert_eq(wp1.FlowRateLimit, 120, "garbage flowlimit rejected (live untouched)")
assert_eq(wp1.Store.get('FlowRateLimit'), '120', "garbage flowlimit rejected (Store untouched)")
webserver.arg = def (name, dflt) return '-5' end
wp1.page_service()
assert_eq(wp1.FlowRateLimit, 120, "negative flowlimit rejected (live untouched)")
assert_eq(wp1.Store.get('FlowRateLimit'), '120', "negative flowlimit rejected (Store untouched)")
# 0 allowed: disables detection
webserver.arg = def (name, dflt) return '0' end
wp1.page_service()
assert_eq(wp1.FlowRateLimit, 0, "flowlimit=0 accepted (disables detection)")
assert_eq(wp1.Store.get('FlowRateLimit'), '0', "flowlimit=0 persisted")

# ---------------- finished ----------------