# Characterization: PersistStore.has() tells "written to the device" apart
# from "only carries a registered default" - the distinction _migrate_units
# needs and could previously only get from raw persist.find().
section("persist: has()")
var st = store.PersistStore()
st.register('SomeKey', {'default': 'dflt', 'policy': 'immediate'})
assert_eq(st.has('SomeKey'), false, "registered but never persisted -> has() false")
st.set('SomeKey', 'written')
st.flush(true)
assert_eq(st.has('SomeKey'), true, "after flush the key exists on the device")
assert_eq(st.has('NeverRegistered'), false, "unknown key -> has() false")