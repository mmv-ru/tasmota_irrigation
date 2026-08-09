# Smoke test: harness loads, Watering initializes
section("smoke")

assert_true(wp1 != nil, "wp1 Watering object created")
assert_true(type(wp1) == "instance", "wp1 is an object")

section("smoke summary")
print("PASS=" .. PASS_COUNT .. " FAIL=" .. FAIL_COUNT)