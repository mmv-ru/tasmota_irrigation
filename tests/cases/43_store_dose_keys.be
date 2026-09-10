# Characterization: session dose parameters are per-channel Store keys, not
# hardcoded Plant defaults. MaxFlood / Counter1FloodDefault get popup web args
# (m_maxflood_N / m_c1def_N); Counter1Backflow stays Store-only (no UI field).
import json
import introspect

section("init_defaults_from_registry")

var P1 = wp1.plants[0]
assert_eq(P1.MaxFlood, 300, "MaxFlood default 300 ml from registry")
assert_eq(P1.Counter1FloodDefault, 30, "Counter1FloodDefault default 30 ml")
assert_eq(P1.Counter1Backflow, 0, "Counter1Backflow default 0 ml")
assert_eq(wp1.Store.get('P1MaxFlood'), '300', "P1MaxFlood registered with ml default")
assert_eq(wp1.Store.get('P1Counter1FloodDefault'), '30', "P1Counter1FloodDefault registered")
assert_eq(wp1.Store.get('P1Counter1Backflow'), '0', "P1Counter1Backflow registered")

section("store_overrides_read_on_init")

# persisted overrides survive a reboot: re-init reads them instead of defaults
introspect.set(persist, 'P1MaxFlood', '500')
introspect.set(persist, 'P1Counter1FloodDefault', '60')
introspect.set(persist, 'P1Counter1Backflow', '10')
introspect.set(persist, 'P2MaxFlood', '900')

wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
assert_eq(P1.MaxFlood, 500, "P1 MaxFlood read from Store after reboot")
assert_eq(P1.Counter1FloodDefault, 60, "P1 flood dose default read from Store")
assert_eq(P1.Counter1Backflow, 10, "P1 backflow read from Store")
assert_eq(wp1.plants[1].MaxFlood, 900, "P2 MaxFlood independent per channel")
assert_eq(wp1.plants[1].Counter1FloodDefault, 30, "P2 keeps default when nothing persisted")

section("escalation_capped_at_store_maxflood")

# repeat-flood escalation must cap at the Store-backed MaxFlood (500), not the
# hardcoded 300
P1.DryThreshold = 9999
P1.Preset = nil
P1.AutofloodInProcess = true
P1.SoilHPreFlood = 900
SIM['sensors']['ANALOG']['A1'] = 890
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
P1.Counter1FloodDefault = 450
P1.timer_soil_transition_after_flooded()
assert_eq(P1.Counter1FloodDefault, 500, "escalation capped at Store-backed MaxFlood 500")

section("popup_markup_has_new_fields")

# expanded soil1: the settings button carries maxflood/c1def values from Store;
# backflow must NOT be exposed as a data-attribute
webserver.has_arg = def (name) return name == 'me' end
webserver.arg = def (name, dflt) return name == 'me' ? '1' : dflt end
SIM['websend'] = list()
wp1.web_sensor()
var joined = ""
for m: SIM['websend'] joined = joined .. m end
assert_true(string.find(joined, "data-maxflood='500'") >= 0, "popup carries MaxFlood value")
assert_true(string.find(joined, "data-c1def='60'") >= 0, "popup carries flood dose default value")
assert_true(string.find(joined, "data-backflow") < 0, "backflow not exposed in popup markup")

# main-page JS config declares the two new fields + labels (backflow absent)
SIM['webhtml'] = list()
wp1.web_add_main_button()
var js = ""
for h: SIM['webhtml'] js = js .. h end
assert_true(string.find(js, "Max flood (ml)") >= 0, "popup label for Max flood")
assert_true(string.find(js, "Flood dose default (ml)") >= 0, "popup label for flood dose default")
assert_true(string.find(js, "m_maxflood_") >= 0, "popup arg base for Max flood")
assert_true(string.find(js, "m_c1def_") >= 0, "popup arg base for flood dose default")
assert_true(string.find(js, "m_c1backflow_") < 0, "no backflow UI arg")

section("web_args_set_plant_and_store")

# per-channel web args persist on the Store and update the live plant field
webserver.has_arg = def (name) return name == 'm_maxflood_2' || name == 'm_c1def_2' end
webserver.arg = def (name, dflt)
    if name == 'm_maxflood_2' return '750' end
    if name == 'm_c1def_2' return '80' end
    return dflt
end
wp1.web_sensor()
assert_eq(wp1.plants[1].MaxFlood, 750, "web m_maxflood_2 updates live P2.MaxFlood")
assert_eq(wp1.plants[1].Counter1FloodDefault, 80, "web m_c1def_2 updates live flood dose default")
assert_eq(wp1.Store.get('P2MaxFlood'), 750, "web m_maxflood_2 persists P2MaxFlood")
assert_eq(wp1.Store.get('P2Counter1FloodDefault'), 80, "web m_c1def_2 persists P2Counter1FloodDefault")
assert_eq(persist.find('P2MaxFlood'), 750, "web m_maxflood_2 written to persist map")

# non-numeric / zero args rejected without touching the Store
webserver.has_arg = def (name) return name == 'm_maxflood' end
webserver.arg = def (name, dflt) return 'abc' end
wp1.web_sensor()
assert_eq(P1.MaxFlood, 500, "garbage m_maxflood rejected (plant untouched)")
assert_eq(wp1.Store.get('P1MaxFlood'), 500, "garbage m_maxflood rejected (Store untouched)")

# zero arg rejected without touching plant or Store (plant value may still be
# the escalated 500 from the cap test, Store keeps the configured default)
var c1_before = P1.Counter1FloodDefault
webserver.has_arg = def (name) return name == 'm_c1def' end
webserver.arg = def (name, dflt) return '0' end
wp1.web_sensor()
assert_eq(P1.Counter1FloodDefault, c1_before, "zero m_c1def rejected (plant untouched)")
assert_eq(wp1.Store.get('P1Counter1FloodDefault'), 60, "zero m_c1def rejected (Store untouched)")

# ---------------- finished ----------------