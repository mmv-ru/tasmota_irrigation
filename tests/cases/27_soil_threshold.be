# Characterization: Dry/Wet thresholds live on Plant (per-channel), editable
# via SoilDry/SoilWet commands and web args m_soildry/m_soilwet. Validation:
# gap > 20.
import json

section("soil_threshold_cmds_registered")

assert_true(SIM['cmnds'].find('SoilDry') != nil, "SoilDry cmd registered at boot")
assert_true(SIM['cmnds'].find('SoilWet') != nil, "SoilWet cmd registered at boot")

section("cmd_soildry_sets_raw_and_persists")

var pl = wp1.plants[0]
var saves0 = persist.saves
SIM['cmnds']['SoilDry']('SoilDry', 0, '820', '')
assert_eq(pl.TargetDry, 820, "SoilDry cmd sets TargetDry")
assert_eq(persist.find('P1TargetDry'), 820, "SoilDry writes TargetDry to persist map")
assert_eq(persist.saves, saves0, "SoilDry write debounced (no immediate save)")
wp1.Store.flush()
assert_eq(persist.saves, saves0 + 1, "flush saves SoilDry once")

section("cmd_soilwet_sets_raw_and_persists")

SIM['cmnds']['SoilWet']('SoilWet', 0, '760', '')
assert_eq(pl.TargetWet, 760, "SoilWet cmd sets TargetWet")
assert_eq(persist.find('P1TargetWet'), 760, "SoilWet writes TargetWet to persist map")
assert_eq(persist.saves, saves0 + 1, "SoilWet write debounced (no immediate save)")

section("cmd_rejects_close_values")

# gap 820-780 = 20 is not > 20 -> rejected, nothing changes
persist.saves = 0
SIM['cmnds']['SoilDry']('SoilDry', 0, '780', '')
assert_eq(pl.TargetDry, 820, "SoilDry keeps value when gap==20")
assert_eq(persist.find('P1TargetDry'), 820, "SoilDry not persisted on reject")
assert_eq(persist.saves, 0, "no save on rejected SoilDry")

# gap 820-790 = 30 -> ok
SIM['cmnds']['SoilWet']('SoilWet', 0, '790', '')
assert_eq(pl.TargetWet, 790, "SoilWet accepted when gap>20")

# rejected SoilWet: back to 790 accepted, 810 gap=10 rejected
SIM['cmnds']['SoilWet']('SoilWet', 0, '810', '')
assert_eq(pl.TargetWet, 790, "SoilWet keeps value when gap<20")
assert_eq(persist.find('P1TargetWet'), 790, "SoilWet not persisted on reject")

section("cmd_soildry_bad_payload_no_crash")

var before = pl.TargetDry
SIM['cmnds']['SoilDry']('SoilDry', 0, 'not-a-number', '')
assert_eq(pl.TargetDry, before, "SoilDry garbage payload leaves TargetDry untouched")

section("cmd_empty_payload_reports_value_not_reset")

# Tasmota convention: command without argument must report current value,
# never reset to 0 (int("") == 0).
var wet_before = pl.TargetWet
var dry_before = pl.TargetDry
SIM['cmnds']['SoilWet']('SoilWet', 0, '', '')
assert_eq(pl.TargetWet, wet_before, "SoilWet empty payload keeps TargetWet")
SIM['cmnds']['SoilDry']('SoilDry', 0, '', '')
assert_eq(pl.TargetDry, dry_before, "SoilDry empty payload keeps TargetDry")
SIM['cmnds']['SoilWet']('SoilWet', 0, 'not-a-number', '')
assert_eq(pl.TargetWet, wet_before, "SoilWet garbage payload keeps TargetWet")
assert_eq(persist.find('P1TargetWet'), wet_before, "SoilWet garbage payload not persisted")

section("setter_guards_zero")

# direct setter calls must not accept 0 / empty / garbage
persist.saves = 0
assert_true(!pl.SetWet(''), "SetWet empty string rejected")
assert_true(!pl.SetWet(0), "SetWet 0 rejected")
assert_true(!pl.SetDry(0), "SetDry 0 rejected")
assert_eq(pl.TargetWet, wet_before, "SetWet guard keeps TargetWet")
assert_eq(pl.TargetDry, dry_before, "SetDry guard keeps TargetDry")
assert_eq(persist.saves, 0, "no save on guarded setter calls")

section("web_arg_sets_threshold")

webserver.has_arg = def (name) return name == 'm_soildry' end
webserver.arg = def (name, dflt) return '850' end
wp1.web_sensor()
assert_eq(pl.TargetDry, 850, "web m_soildry sets TargetDry")
assert_eq(persist.find('P1TargetDry'), 850, "web m_soildry persists TargetDry")

# header pills reflect the edited plant threshold (markup-agnostic)
var joined = ""
for w: SIM['websend'] joined = joined .. w end
assert_true(string.find(joined, "сухо") >= 0 && string.find(joined, "850") >= 0, "header pills reflect plant threshold after edit")

section("web_arg_per_channel_suffix")

# channel 2 edits its own thresholds via the suffixed arg; channel 1 untouched
webserver.has_arg = def (name) return name == 'm_soildry_2' end
webserver.arg = def (name, dflt) return '860' end
wp1.web_sensor()
assert_eq(wp1.plants[1].TargetDry, 860, "web m_soildry_2 sets channel 2 TargetDry")
assert_eq(wp1.plants[0].TargetDry, 850, "channel 1 TargetDry untouched by suffixed arg")

section("web_form_emits_no_bare_inputs")

# the Soil Dry/Wet and Dry threshold/Soak dose forms moved into the per-channel
# detail popup; the main page must no longer emit the bare input ids
SIM['webhtml'] = list()
wp1.web_add_main_button()
var joined2 = ""
for h: SIM['webhtml'] joined2 = joined2 .. h end
assert_true(string.find(joined2, "id='soil_dry'") < 0, "no bare Soil Dry form on main page")
assert_true(string.find(joined2, "id='soil_wet'") < 0, "no bare Soil Wet form on main page")
assert_true(string.find(joined2, "id='dry_thr'") < 0, "no bare Dry threshold form on main page")
assert_true(string.find(joined2, "id='soak_dose'") < 0, "no bare Soak start dose form on main page")

section("deinit_removes_cmds")

wp1.deinit()
assert_true(SIM['cmnds'].find('SoilDry') == nil, "SoilDry cmd removed on deinit")
assert_true(SIM['cmnds'].find('SoilWet') == nil, "SoilWet cmd removed on deinit")

# ---------------- finished ----------------