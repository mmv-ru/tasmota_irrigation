# Characterization: pulseencode() mapping MaxPumpRun (seconds) -> PulseTime value
# Per Tasmota docs (Commands / PulseTime):
#   0                = disabled
#   1..111           = 0.1 s increments (=> up to 11.1 s)
#   112..64900       = offset by 100, 1 s increments (112 => 12 s, 460 => 6 min = 360 s)
import string

section("pulse_encode_zero_to_11s")

assert_eq(wp1.pulseencode(0), 0, "0 s -> 0 (disabled)")
assert_eq(wp1.pulseencode(5.5), 55, "5.5 s -> 55 (0.1s units)")
assert_eq(wp1.pulseencode(11.1), 111, "11.1 s -> 111 (max 0.1s units)")

section("pulse_encode_11_to_12s_rounding")

assert_eq(wp1.pulseencode(11.4), 111, "11.4 s rounds to 111")
assert_eq(wp1.pulseencode(11.6), 112, "11.6 s rounds to 112")
assert_eq(wp1.pulseencode(12), 112, "12 s -> 112 (offset 100)")

section("pulse_encode_over_12s")

assert_eq(wp1.pulseencode(13), 113, "13 s -> 113")
assert_eq(wp1.pulseencode(60), 160, "60 s -> 160")
assert_eq(wp1.pulseencode(360), 460, "360 s -> 460 (docs example: 6 min)")
assert_eq(wp1.pulseencode(64800), 64900, "64800 s -> 64900 (valid max)")

section("pulse_encode_out_of_bounds")

var raised = false
try
    wp1.pulseencode(-1)
except .. as e, m
    raised = true
end
assert_true(raised, "negative time raises")

raised = false
try
    wp1.pulseencode(70000)
except .. as e, m
    raised = true
end
assert_true(raised, "too large time raises")

section("pulse_encode_boundary_bug")

# NB: Tasmota max is 64900; code accepts time<=64900 -> emits 65000 which is
# OUT OF RANGE for the device. Documenting current (buggy) behavior.
assert_eq(wp1.pulseencode(64900), 65000, "64900 s -> 65000 (out of Tasmota range, documented)")

# ---------------- finished ----------------