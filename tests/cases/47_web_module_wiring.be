# Characterization: after the module split the UI is a separate object holding
# a reference to the driver. The HTML itself is covered by the golden snapshot;
# this asserts the wiring, not the markup.
section("web: module wiring")

assert_true(wp1.ui != nil, "Watering creates its Web UI in init()")
assert_eq(wp1.ui.d.NumChannels, wp1.NumChannels, "Web holds a reference to the driver")

# delegates reach the UI without raising
SIM['websend'] = list()
wp1.web_sensor()
assert_true(SIM['websend'].size() > 0, "web_sensor delegate renders through the UI")
SIM['webhtml'] = list()
wp1.web_add_main_button()
assert_true(SIM['webhtml'].size() > 0, "web_add_main_button delegate renders through the UI")
SIM['webhtml'] = list()
wp1.page_service()
assert_true(SIM['webhtml'].size() > 0, "page_service delegate renders through the UI")

# deinit releases the UI: no stale UI may keep the old driver alive
wp1.deinit()
assert_eq(wp1.ui, nil, "deinit() clears the UI reference")
