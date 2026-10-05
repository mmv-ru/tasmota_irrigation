import strict

var cfg = module('cfg')

# Maximum number of irrigation channels (2..4). Each channel owns one pump
# relay (Power1..PowerN) and one soil sensor (A1..AN); all channels share the
# flow counter C1, so fills are strictly serialised (one at a time).
var MAX_CHANNELS = 4

# Deferred phase-2 init delay (ms). On early boot the firmware's own sensor
# drivers are still coming up and read_sensors() can throw through the
# FUNC_JSON_APPEND dispatch during the first ~1.7 s of uptime (WiFi connects
# ~3.7 s). Watering init() arms a one-shot timer with this delay instead of
# calling init_sensors() synchronously, so the first read happens ~4.3 s in —
# outside the crash window (pattern: xsns_34_hx711 "Fix power on init").
var BOOT_INIT_DELAY_MS = 4000

# Berry's module() does not auto-collect file-level names: every exported
# member has to be assigned explicitly or `cfg.<name>` raises
# 'module cfg has no member'. (Probe 2026-10-05, gotcha #13.)
cfg.MAX_CHANNELS = MAX_CHANNELS
cfg.BOOT_INIT_DELAY_MS = BOOT_INIT_DELAY_MS

return cfg