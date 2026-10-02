# Deferred phase-2 initialization: Watering() must NOT read sensors / create
# plants / register the driver synchronously at load (early-boot read_sensors()
# can throw through the FUNC_JSON_APPEND dispatch during the first ~1.7 s of
# boot). Phase 2 (init_sensors) is armed via ID_DELAY_INIT timer by init();
# this case checks the contract: creation leaves the object uninitialized, a
# manual init_sensors() == "timer fired" completes it, a second call is
# idempotent, and a throwing read goes down the retry path (re-arms the timer,
# keeps _initialized false) then recovers.
import json
import introspect

section("creation_defers_phase2")

var w2 = Watering()
assert_eq(introspect.get(w2, '_initialized') == false, true, "fresh Watering() starts uninitialized")
assert_eq(introspect.get(w2, 'plants') == nil, true, "no plants before phase 2")
assert_eq(introspect.get(w2, 'SoilSensors') == nil, true, "no soil sensors before phase 2")
assert_true(SIM['timers'].find("ID_DELAY_INIT") != nil, "ID_DELAY_INIT timer armed at creation")

section("phase2_runs_on_init_sensors")

# shim semantics: build.py / device timer call init_sensors() == "timer fired"
w2.init_sensors()
assert_eq(introspect.get(w2, '_initialized') == true, true, "phase 2 marks initialized")
assert_true(w2.plants != nil, "plants created by phase 2")
assert_true(w2.SoilSensors != nil, "soil sensors created by phase 2")
var first_plant = w2.plants[0]

section("phase2_is_idempotent")

var cmds_before = SIM['cmds'].size()
w2.init_sensors()
assert_eq(SIM['cmds'].size(), cmds_before, "second phase 2 adds no commands")
assert_true(w2.plants[0] == first_plant, "second phase 2 does not recreate plants")
assert_eq(introspect.get(w2, '_initialized') == true, true, "flag stays true")

section("retry_path_on_throwing_read")

var orig_read = tasmota.read_sensors
tasmota.read_sensors = def () raise "type_error" end
var w3 = Watering()
var tries_before = w3.BootInitTries
w3.init_sensors()
assert_eq(introspect.get(w3, '_initialized') == false, true, "throwing read leaves flag false")
assert_eq(w3.BootInitTries, tries_before + 1, "BootInitTries incremented on throw")
assert_eq(introspect.get(w3, 'plants') == nil, true, "no plants after failed phase 2")
assert_true(SIM['timers'].find("ID_DELAY_INIT") != nil, "retry timer re-armed")
assert_eq(SIM['timers']['ID_DELAY_INIT']['delay'], 1000, "retry delay 1000 ms")
tasmota.read_sensors = orig_read
w3.init_sensors()
assert_eq(introspect.get(w3, '_initialized') == true, true, "phase 2 completes after read recovers")
assert_true(w3.plants != nil, "plants exist after recovery")

# ---------------- finished ----------------