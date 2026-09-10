# Characterization: ml/ticks boundary helpers and the one-time UnitsV2 migration
# of iteration-1 persisted C1-tick values to the canonical ml unit.
import introspect
import json

section("ticks_conversion_helper")

# ticks(ml) = round(ml / scale). Fractional scale: 100 ml @0.4 ml/tick = 250 ticks.
var P1 = wp1.plants[0]
wp1.FlowSensors[0].Scale = 0.4
assert_eq(P1.ticks(100), 250, "100 ml @0.4 ml/tick = 250 ticks")
assert_eq(P1.ticks(15), 38, "15 ml @0.4 -> 37.5 -> 38 (round half up)")
assert_eq(P1.ticks(0), 0, "zero volume stays zero")

# missing scale -> volume passed through as-is (no calibration configured)
wp1.FlowSensors[0].Scale = nil
assert_eq(P1.ticks(100), 100, "nil scale falls back to identity")

# zero/negative scale also falls back (guard, no crash)
wp1.FlowSensors[0].Scale = 0
assert_eq(P1.ticks(100), 100, "zero scale falls back to identity")
wp1.FlowSensors[0].Scale = 0.4

section("migration_converts_tick_era_persisted_values")

# The boot already marked this device migrated (UnitsV2=1). Simulate an
# iteration-1 device: drop the marker, write tick-era values + a stored
# calibration directly to persist, then re-create the driver.
introspect.set(persist, 'UnitsV2', nil)
introspect.set(persist, 'FlowScale', '0.4')
introspect.set(persist, 'P1SoakStartDose', '100')
introspect.set(persist, 'P1SoakDailyCap', '1500')
introspect.set(persist, 'P1SoakMaxDose', '2000')
introspect.set(persist, 'P1LastFloodVol', '2000')
introspect.set(persist, 'P1PrevFloodedVol', '300')
introspect.set(persist, 'P2SoakStartDose', '50')

wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
var P2 = wp1.plants[1]

assert_eq(wp1.Store.get('UnitsV2'), '1', "migration marker set after upgrade")
assert_eq(P1.ticks(100), 250, "reloaded scale 0.4 drives the boundary conversion")
assert_eq(wp1.Store.get('P1SoakStartDose'), 40, "StartDose converted 100 ticks x 0.4 = 40 ml")
assert_eq(wp1.Store.get('P1SoakDailyCap'), 600, "DailyCap converted 1500 -> 600 ml")
assert_eq(wp1.Store.get('P1SoakMaxDose'), 800, "MaxDose converted 2000 -> 800 ml")
assert_eq(P1.LastFloodVol, 800, "LastFloodVol loaded as 2000 -> 800 ml")
assert_eq(wp1.Store.get('P1PrevFloodedVol'), 120, "PrevFloodedVol converted 300 -> 120 ml")
assert_eq(wp1.Store.get('P2SoakStartDose'), 20, "second channel converted 50 -> 20 ml")
assert_eq(wp1.Store.get('P3SoakStartDose'), '15', "unpersisted channel keeps its ml default")

section("migration_is_idempotent")

# a second re-init must not re-convert (already-ml values are no longer ticks)
wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
assert_eq(wp1.Store.get('P1SoakStartDose'), 40, "no double conversion on re-init")
assert_eq(P1.LastFloodVol, 800, "LastFloodVol not multiplied twice")

section("fresh_device_keeps_ml_defaults")

# brand-new device: nothing persisted -> defaults already ml, marker best-effort
introspect.set(persist, 'UnitsV2', nil)
for k: ['P1SoakStartDose', 'P1SoakDailyCap', 'P1SoakMaxDose', 'P1LastFloodVol', 'P1PrevFloodedVol', 'P2SoakStartDose', 'FlowScale']
    introspect.set(persist, k, nil)
end
wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
assert_eq(wp1.Store.get('P1SoakStartDose'), '15', "fresh device keeps the ml default")
assert_eq(wp1.Store.get('P1PrevFloodedVol'), nil, "fresh device has no prev stats")
assert_eq(P1.ticks(100), 690, "no stored calibration -> default 0.1449 ml/tick (100 ml = 690 ticks)")

# ---------------- finished ----------------