# Characterization: every_second() sensor tracking and dry-peak confirmation
import json

section("every_second_tracks_soil_max")

# dry soil: RawEma stable -> SoilMaxHymidity should be captured
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.SoilMaxHymidity = nil
wp1.PauseSoilMaxStat = false
wp1.every_second()

var max1 = wp1.SoilMaxHymidity
assert_true(max1 != nil, "SoilMaxHymidity captured during non-paused second")
assert_eq(max1, wp1.SoilSensors[0].RawEma, "max equals current RawEma when fresh")

section("confirms_after_rise")

# soil dries out (RawEma rises above max+5) -> max humidity confirmed
var max1_v = wp1.SoilMaxHymidity
wp1.SoilSensors[0].RawEma = max1_v + 10
wp1.SoilMaxHymidityConfirmed = false
wp1.every_second()
assert_eq(wp1.SoilMaxHymidityConfirmed, true, "SoilMaxHymidity confirmed after +5")
assert_eq(wp1.SoilMaxHymidity, max1_v, "max value preserved on confirmation")
assert_true(wp1.SoilMaxHymidityTime != nil, "confirmation timestamp stored")

section("every_second_paused")

# while PauseSoilMaxStat, max must not be updated
var before_pause = wp1.SoilMaxHymidity
wp1.PauseSoilMaxStat = true
SIM['sensors']['ANALOG']['A1'] = 800
# raw to increase (drier), EMA stays
wp1.every_second()
assert_eq(wp1.SoilMaxHymidity, before_pause, "max untouched while paused")

# ---------------- finished ----------------