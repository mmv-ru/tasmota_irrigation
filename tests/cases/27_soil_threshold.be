# Characterization: RawDry/RawWet thresholds editable via SoilDry/SoilWet
# commands and web args m_soildry/m_soilwet. Validation: gap > 20.
import json

section("soil_threshold_cmds_registered")

assert_true(SIM['cmnds'].find('SoilDry') != nil, "SoilDry cmd registered at boot")
assert_true(SIM['cmnds'].find('SoilWet') != nil, "SoilWet cmd registered at boot")

section("cmd_soildry_sets_raw_and_persists")

var ss = wp1.SoilSensors[0]
var saves0 = persist.saves
SIM['cmnds']['SoilDry']('SoilDry', 0, '820', '')
assert_eq(ss.RawDry, 820, "SoilDry cmd sets RawDry")
assert_eq(persist.find('TargetDry'), 820, "SoilDry persists RawDry")
assert_eq(persist.saves, saves0 + 1, "SoilDry saves once")

section("cmd_soilwet_sets_raw_and_persists")

SIM['cmnds']['SoilWet']('SoilWet', 0, '760', '')
assert_eq(ss.RawWet, 760, "SoilWet cmd sets RawWet")
assert_eq(persist.find('TargetWet'), 760, "SoilWet persists RawWet")

section("cmd_rejects_close_values")

# gap 820-780 = 20 is not > 20 -> rejected, nothing changes
persist.saves = 0
SIM['cmnds']['SoilDry']('SoilDry', 0, '780', '')
assert_eq(ss.RawDry, 820, "SoilDry keeps value when gap==20")
assert_eq(persist.find('TargetDry'), 820, "SoilDry not persisted on reject")
assert_eq(persist.saves, 0, "no save on rejected SoilDry")

# gap 820-790 = 30 -> ok
SIM['cmnds']['SoilWet']('SoilWet', 0, '790', '')
assert_eq(ss.RawWet, 790, "SoilWet accepted when gap>20")

# rejected SoilWet: back to 790 accepted, 810 gap=10 rejected
SIM['cmnds']['SoilWet']('SoilWet', 0, '810', '')
assert_eq(ss.RawWet, 790, "SoilWet keeps value when gap<20")
assert_eq(persist.find('TargetWet'), 790, "SoilWet not persisted on reject")

section("cmd_soildry_bad_payload_no_crash")

var before = ss.RawDry
SIM['cmnds']['SoilDry']('SoilDry', 0, 'not-a-number', '')
assert_eq(ss.RawDry, before, "SoilDry garbage payload leaves RawDry untouched")

section("web_arg_sets_threshold")

webserver.has_arg = def (name) return name == 'm_soildry' end
webserver.arg = def (name, dflt) return '850' end
wp1.web_sensor()
assert_eq(ss.RawDry, 850, "web m_soildry sets RawDry")
assert_eq(persist.find('TargetDry'), 850, "web m_soildry persists RawDry")

section("web_form_emits_inputs")

SIM['webhtml'] = list()
wp1.web_add_main_button()
var joined = ""
for h: SIM['webhtml'] joined = joined .. h end
assert_true(string.find(joined, "m_soildry") >= 0, "form has m_soildry input")
assert_true(string.find(joined, "m_soilwet") >= 0, "form has m_soilwet input")

section("deinit_removes_cmds")

wp1.deinit()
assert_true(SIM['cmnds'].find('SoilDry') == nil, "SoilDry cmd removed on deinit")
assert_true(SIM['cmnds'].find('SoilWet') == nil, "SoilWet cmd removed on deinit")

# ---------------- finished ----------------