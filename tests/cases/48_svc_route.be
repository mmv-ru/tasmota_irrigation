# /svc must not depend on Tasmota's one-shot web_add_handler event: on
# BrRestart that event fires before the driver exists (the driver is added by
# the deferred init_sensors(), ~4 s after load), so init_sensors() registers the
# route itself - the same pattern the heating-controller reference uses in its
# start(). This is the regression test for "/svc dead after BrRestart".
section("svc: deferred registration from init_sensors")

# The boot shim already ran init_sensors(); it must have registered /svc by
# itself. Before the fix SIM['on_calls'] is nil here (nothing ever called
# webserver.on), which is exactly the reported bug.
assert_eq(SIM.find('on_calls', nil) != nil ? SIM.find('on_calls', nil).size() : -1, 1,
          "init_sensors() calls webserver.on exactly once")
assert_eq(SIM.find('routes', nil) != nil ? SIM.find('routes', nil).size() : -1, 1,
          "exactly one route in the table")
if SIM.find('routes', nil) != nil && SIM.find('routes', nil).size() > 0
    assert_eq(SIM['routes'][0]['prefix'], "/svc", "the route is /svc")
    assert_eq(SIM['routes'][0]['method'], webserver.HTTP_GET, "registered for GET")
end

# A second explicit call is harmless: the firmware reuses the slot for the same
# prefix+method, which is why no idempotence guard is needed on our side (a
# guard would block the legitimate second call in the cold-boot interleaving,
# where the first one is a C-side no-op).
wp1.web_add_handler()
assert_eq(SIM['on_calls'].size(), 2, "the second call still reaches webserver.on")
assert_eq(SIM['routes'].size(), 1, "no duplicate route after the second call")

# The registered closure serves the page.
SIM['webhtml'] = list()
SIM['routes'][0]['cb']()
var svc_html = SIM['webhtml'].concat()
assert_true(SIM['webhtml'].size() > 0, "the registered callback renders /svc")
assert_true(string.find(svc_html, "Сервисный режим") >= 0,
            "the callback renders the service page header")
