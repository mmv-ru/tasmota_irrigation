# Characterization: per-channel persist keys (P{Num}_*) are isolated and
# restored per channel after a reboot (deinit + fresh Watering driver).
import json

section("per_channel_keys_are_independent")

var P1 = wp1.plants[0]
var P2 = wp1.plants[1]
assert_eq(wp1.Store.get('P1TargetDry'), '800', "P1 TargetDry default")
assert_eq(wp1.Store.get('P2TargetDry'), '800', "P2 TargetDry default (own key)")
assert_eq(wp1.Store.get('P2DryThreshold'), '820', "P2 DryThreshold default")

# set a channel-1-only threshold: channel 2 must be untouched
SIM['cmds'] = list()
P1.SoilSensor.SetDry(860)
assert_eq(wp1.Store.get('P1TargetDry'), 860, "P1 TargetDry updated")
assert_eq(wp1.Store.get('P2TargetDry'), '800', "P2 TargetDry still default")

section("reboot_restores_each_channel")

wp1.Store.flush(true)
wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
P2 = wp1.plants[1]
assert_eq(P1.SoilSensor.RawDry, 860, "P1 restored its own threshold")
assert_eq(P2.SoilSensor.RawDry, 800, "P2 keeps its own threshold")

section("per_channel_dry_threshold_restores")

wp1.Store.set('P1DryThreshold', 900)
assert_eq(wp1.Store.get('P2DryThreshold'), '820', "P2 DryThreshold untouched")
wp1.Store.flush(true)
wp1.deinit()
wp1 = Watering()
P1 = wp1.plants[0]
P2 = wp1.plants[1]
assert_eq(P1.DryThreshold, 900, "P1 DryThreshold restored")
assert_eq(P2.DryThreshold, 820, "P2 DryThreshold independent")

# ---------------- finished ----------------
