# Characterization: every_second() soil-max tracking (Temp model).
# Running minimum is tracked in SoilMaxHymidityTemp; SoilMaxHymidity becomes
# non-nil only on confirmation (+5 rise). A value restored from persist after
# reboot is a valid "confirmed" value and is never overwritten by a higher one.
import json

var P1 = wp1.plants[0]

section("every_second_tracks_soil_max")

# dry soil: RawEma stable -> running minimum captured into Temp, not confirmed
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
P1.SoilMaxHymidity = nil
P1.SoilMaxHymidityTemp = nil
P1.PauseSoilMaxStat = false
wp1.every_second()

var t1 = P1.SoilMaxHymidityTemp
assert_true(t1 != nil, "running min captured during non-paused second")
assert_eq(t1, wp1.SoilSensors[0].RawEma, "temp equals current RawEma when fresh")
assert_true(P1.SoilMaxHymidity == nil, "max stays nil until +5 rise confirms")
assert_true(P1.SoilMaxHymidityTimeTemp != nil, "temp timestamp stored")

section("confirms_after_rise")

# soil dries out (RawEma rises above temp+5) -> max humidity confirmed
var t1_v = P1.SoilMaxHymidityTemp
wp1.SoilSensors[0].RawEma = t1_v + 10
wp1.every_second()
assert_eq(P1.SoilMaxHymidity, t1_v, "max promoted to confirmed value after +5")
assert_eq(P1.SoilMaxHymidityTime, P1.SoilMaxHymidityTimeTemp, "confirmation timestamp promoted")
assert_true(P1.SoilMaxHymidityTime != nil, "confirmation timestamp stored")

section("every_second_paused")

# while PauseSoilMaxStat, neither max nor temp must be updated
var before_pause = P1.SoilMaxHymidity
var before_temp = P1.SoilMaxHymidityTemp
P1.PauseSoilMaxStat = true
SIM['sensors']['ANALOG']['A1'] = 800
# raw to increase (drier), EMA stays
wp1.every_second()
assert_eq(P1.SoilMaxHymidity, before_pause, "max untouched while paused")
assert_eq(P1.SoilMaxHymidityTemp, before_temp, "temp untouched while paused")

section("reboot_restore_guard")

# after a reboot the last confirmed value is restored from persist (non-nil).
# A higher post-boot RawEma must NOT re-confirm a value above the restored max,
# and telemetry keeps emitting the restored value right away (no InfluxDB gap).
P1.SoilMaxHymidity = 805
P1.SoilMaxHymidityTime = SIM['rtc_local']
P1.SoilMaxHymidityTemp = nil
P1.SoilMaxHymidityTimeTemp = nil
P1.PauseSoilMaxStat = false
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
wp1.every_second()
assert_eq(P1.SoilMaxHymidity, 805, "restored max preserved when RawEma stays above it")
assert_eq(P1.SoilMaxHymidityTemp, P1.SoilSensor.RawEma, "temp tracks the current EMA minimum")

SIM['append'] = list()
wp1.json_append()
var obj = json.load(string.split(SIM['append'][0], '"Watering":')[1])
assert_eq(obj['LastSoilMaxHymidity'], 805, "telemetry emits restored max right after reboot")

section("reboot_lower_min_confirms")

# a genuinely lower minimum than the restored value IS re-confirmed
P1.SoilMaxHymidity = 805
P1.SoilMaxHymidityTemp = nil
P1.PauseSoilMaxStat = false
P1.SoilSensor.RawEma = 800   # drier than the restored 805 (below it)
wp1.every_second()
var lower = P1.SoilMaxHymidityTemp
assert_true(lower != nil && lower < 805, "temp captures a minimum below the restored max")
assert_eq(lower, P1.SoilSensor.RawEma, "temp equals current EMA minimum")
P1.SoilSensor.RawEma = lower + 10
wp1.every_second()
assert_eq(P1.SoilMaxHymidity, lower, "lower minimum confirmed after +5 rise")

# ---------------- finished ----------------