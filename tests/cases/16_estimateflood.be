# Characterization: estimateflood() linear dose estimation
# Uses: LastFloodVol, SoilHPreFlood, SoilMaxHymidity(prev session), RawEma, RawWet
import json

section("estimate_normal")

# prev session: HPre=900, minRaw(max humidity)=820 -> LastFloodDRaw=80
# current soil RawEma=850, RawWet=800 -> CurDRaw=50
# Estimated = 350 * 50/80 = 218.75 -> int 218
wp1.LastFloodVol = 350
wp1.SoilHPreFlood = 900
wp1.SoilMaxHymidity = 820
wp1.SoilSensors[0].RawWet = 800
wp1.SoilSensors[0].RawEma = 850
var est = wp1.estimateflood()
assert_eq(est, 218, "linear estimate rounded down")

section("estimate_nil_for_small_dose")

# Estimated < 100 -> returns nil (estimate unusable, fall back to default),
# not 0 (would falsely mean "no flooding needed")
wp1.LastFloodVol = 50
wp1.SoilMaxHymidity = 850
wp1.SoilSensors[0].RawEma = 840  # CurDRaw=40, LastFloodDRaw=50 -> 50*40/50=40 < 100
assert_eq(wp1.estimateflood(), nil, "small needed dose -> nil")

section("estimate_nil_on_exception")

# missing SoilMaxHymidity (nil) -> division by nil -> exception -> nil
wp1.SoilMaxHymidity = nil
var res = wp1.estimateflood()
assert_eq(res, nil, "nil result when pre-data missing")

# ---------------- finished ----------------