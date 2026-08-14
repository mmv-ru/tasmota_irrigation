# Characterization: PersistStore centralised persist layer.
# Load defaults, set() policies (debounced/immediate/threshold), flush/save_batch,
# dump + Store cmd + web table, deinit flush. Saves counted via persist.saves.
import json

section("store_load_defaults")
var P1 = wp1.plants[0]

var st = wp1.Store
assert_true(st != nil, "Watering exposes a PersistStore")
assert_eq(st.get('P1TargetDry'), '800', "P1TargetDry default from registry")
assert_eq(st.get('P1TargetWet'), '760', "P1TargetWet default from registry")
assert_eq(st.get('P1LastFloodVol'), '0', "P1LastFloodVol default from registry")
assert_eq(st.get('P1SoilHPreFlood'), nil, "session key defaults to nil")
assert_eq(st.get('P1PrevSoilHPreFlood'), nil, "prev session key defaults to nil")
assert_true(st.Shadow.find('P1TargetDry') == '800', "Shadow seeded from default")
assert_true(!st.Dirty, "store clean after load")

section("set_debounced_writes_map_no_save")

persist.saves = 0
st.set('P1TargetDry', 900)
assert_true(persist.has('P1TargetDry'), "set() writes the persist map in-memory")
assert_eq(persist.find('P1TargetDry'), 900, "persist map holds the new value")
assert_eq(persist.saves, 0, "no save yet: debounced")
assert_true(st.Dirty, "store marked dirty")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") != nil, "debounce timer armed")
assert_eq(st.Shadow.find('P1TargetDry'), '800', "Shadow still last flushed value")

st.set('P1TargetWet', 760)
assert_eq(persist.find('P1TargetWet'), 760, "second set writes map too")
assert_eq(persist.saves, 0, "still debounced")

st.flush()
assert_eq(persist.saves, 1, "flush saves once")
assert_true(!st.Dirty, "clean after flush")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") == nil, "timer cleared after flush")
assert_eq(st.Shadow.find('P1TargetDry'), 900, "Shadow updated to flushed value")
assert_eq(st.Shadow.find('P1TargetWet'), 760, "Shadow updated for second key")

section("flush_clean_noop")

var saves_before = persist.saves
st.flush()
assert_eq(persist.saves, saves_before, "flush on clean store does not save")

section("set_immediate")

var sti = PersistStore()
sti.register('TestImm', {'default': 0, 'policy': 'immediate'})
persist.saves = 0
sti.set('TestImm', 55)
assert_eq(persist.saves, 1, "immediate policy saves at once")
assert_true(!sti.Dirty, "immediate policy leaves store clean")
assert_eq(sti.Shadow.find('TestImm'), 55, "immediate policy syncs Shadow")

section("set_threshold_relative")

var stt = PersistStore()
stt.register('TestThr', {'default': 0, 'policy': 'threshold', 'thr': 0.5})
persist.saves = 0
# first write from 0: relative change against base=value (no stored base) -> save
stt.set('TestThr', 100)
assert_eq(persist.saves, 1, "threshold policy saves on first write")
assert_eq(stt.Shadow.find('TestThr'), 100, "shadow synced by threshold flush")

# small change: |200-100|/100 = 1.0 >= 0.5 -> save; pick 150 (0.5 -> exactly hits)
persist.saves = 0
stt.set('TestThr', 150)
assert_eq(persist.saves, 1, "threshold policy saves when change >= thr")
assert_eq(stt.Shadow.find('TestThr'), 150, "shadow synced after threshold save")

# small change: |160-150|/150 = 0.066 < 0.5 -> debounce only
persist.saves = 0
stt.set('TestThr', 160)
assert_eq(persist.saves, 0, "small change within threshold is debounced")
assert_true(stt.Dirty, "store dirty after small threshold change")

section("threshold_div_zero_guard")

var stz = PersistStore()
stz.register('TestZero', {'default': 0, 'policy': 'threshold', 'thr': 0.5})
persist.saves = 0
# both shadow and value are 0 -> no crash, no save
stz.set('TestZero', 0)
assert_eq(persist.saves, 0, "div-by-zero guarded (no crash, no save)")
assert_true(stz.Dirty, "zero-value set still marks dirty")
# first non-zero write from 0 base: base=value -> 1.0 >= 0.5 -> save
stz.set('TestZero', 10)
assert_eq(persist.saves, 1, "first non-zero write saves")

section("save_batch_one_save")

persist.saves = 0
var p0 = wp1.plants[0]
p0.SoilHPreFlood = 812
p0.SoilMaxHymidity = 805
p0.LastFloodVol = 420
wp1.Store.save_batch_entries(p0._stats_batch())
assert_eq(persist.saves, 1, "save_batch_entries persists once")
assert_true(persist.has('P1SoilHPreFlood'), "batch wrote SoilHPreFlood")
assert_eq(persist.find('P1SoilHPreFlood'), 812, "batch value read from source")
assert_eq(wp1.Store.Shadow.find('P1SoilHPreFlood'), 812, "batch syncs Shadow")
assert_true(!wp1.Store.Dirty, "batch leaves store clean")

section("store_dump")

var d = wp1.Store.dump()
assert_true(d.find('P1TargetDry') != nil, "dump contains P1TargetDry")
assert_true(d.size() >= 18, "dump has per-channel keys registered")
# Prev keys default to nil: check presence via the dumped JSON string
assert_true(string.find(json.dump(d), '"P1PrevSoilHPreFlood"') >= 0, "dump contains Prev keys")

section("store_cmd_dumps_json")

SIM['lastresp'] = nil
tasmota.resp_cmnd_str = def (m) SIM['lastresp'] = m end
SIM['cmnds']['Store']('Store', 0, '', '')
assert_true(SIM['lastresp'] != nil, "Store cmd responded")
var parsed = json.load(SIM['lastresp'])
assert_true(parsed != nil, "Store cmd emits valid JSON")
assert_true(parsed.find('P1TargetDry') != nil, "Store JSON contains P1TargetDry")
assert_true(string.find(SIM['lastresp'], '"P1PrevFloodedVol"') >= 0, "Store JSON contains Prev keys")

section("web_sensor_store_table")

# Detail view only: Store.* rows live under the SoilA1Hymidity accordion,
# in explicit current-then-previous order. Duplicate keys (TargetDry/TargetWet)
# and nil-less keys must NOT appear; SoilMaxHymidity/SoilMaxHymidityTime ARE
# listed (confirmed values that survive a reboot).
wp1.DetailView = true
SIM['websend'] = list()
P1.SoilMaxHymidity = nil
P1.LastFloodTime = nil
wp1.web_sensor()
var joined = ""
for m: SIM['websend'] joined = joined .. m end
assert_true(string.find(joined, "Store.P1PrevSoilHPreFlood") >= 0, "web table has Prev keys")
assert_true(string.find(joined, "Store.P1TargetDry") < 0, "Store.P1TargetDry omitted")
assert_true(string.find(joined, "Store.P1TargetWet") < 0, "Store.P1TargetWet omitted")
assert_true(string.find(joined, "Store.P1SoilMaxHymidity") >= 0, "Store.P1SoilMaxHymidity listed")
assert_true(string.find(joined, "Store.P1SoilMaxHymidityTime") >= 0, "Store.P1SoilMaxHymidityTime listed")
# explicit order: current session first (LastFloodVol), then previous session
assert_true(string.find(joined, "Store.P1LastFloodVol") < string.find(joined, "Store.P1PrevFloodedVol"), "current-session keys before Prev*")
assert_true(string.find(joined, "Store.P1PrevFloodedVol") < string.find(joined, "Store.P1PrevSoilHPostFlood"), "Prev* keys grouped together")

section("store_table_hidden_in_compact")

# compact (DetailView off) must not emit Store.* or max rows at all
wp1.DetailView = false
SIM['websend'] = list()
wp1.web_sensor()
var cjoined = ""
for m: SIM['websend'] cjoined = cjoined .. m end
assert_true(string.find(cjoined, "Store.") < 0, "compact view has no Store.* rows")
assert_true(string.find(cjoined, "SoilHymidity1 max") < 0, "compact view has no max row")

section("deinit_flushes_store")

var saves_before_deinit = persist.saves
wp1.Store.set('P1TargetDry', 901)
assert_true(wp1.Store.Dirty, "dirty before deinit")
wp1.deinit()
assert_true(persist.saves > saves_before_deinit, "deinit flushes pending writes")
assert_true(SIM['timers'].find("ID_PERSIST_SAVE") == nil, "deinit clears save timer")
assert_true(SIM['cmnds'].find('Store') == nil, "Store cmd removed on deinit")

# ---------------- finished ----------------