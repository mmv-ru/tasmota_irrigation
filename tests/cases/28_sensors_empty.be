# Characterization: empty/incomplete sensor data must not crash every_second
import json

section("every_second_skips_empty_sensors")

var raw_before = wp1.SoilSensors[0].Raw
assert_true(raw_before != nil, "baseline soil raw captured")

SIM['sensors'] = {}
wp1.every_second()

assert_eq(wp1.SoilSensors[0].Raw, raw_before, "soil raw unchanged when sensors empty")

section("every_second_recovers_when_sensors_back")

SIM['sensors'] = {'ANALOG': {'A1': 901, 'A2': 900}, 'COUNTER': {'C1': 0, 'C2': 0}}
wp1.every_second()
assert_eq(wp1.SoilSensors[0].Raw, 901, "soil raw updates once sensors available again")

section("update_skips_missing_sensor_key")

SIM['sensors'] = {'COUNTER': {'C1': 5, 'C2': 0}}
wp1.every_second()
assert_eq(wp1.SoilSensors[0].Raw, 901, "soil raw preserved when ANALOG key missing")