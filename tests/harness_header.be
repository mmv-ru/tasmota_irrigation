# Test harness header for watering.be
# Combined at build time: header + watering.be + <case>.be
import introspect
import json
import string

# ---------------- Test framework ----------------
var PASS_COUNT = 0
var FAIL_COUNT = 0
var TEST_LIST = []

def assert_true(cond, msg)
    if cond
        print("  PASS: " .. msg)
        PASS_COUNT += 1
    else
        print("  FAIL: " .. msg)
        FAIL_COUNT += 1
    end
end

def assert_eq(actual, expected, msg)
    var a = str(actual)
    var e = str(expected)
    if a == e
        print("  PASS: " .. msg .. " (" .. a .. ")")
        PASS_COUNT += 1
    else
        print("  FAIL: " .. msg .. " expected=" .. e .. " actual=" .. a)
        FAIL_COUNT += 1
    end
end

def section(name)
    print("== " .. name .. " ==")
end

# ---------------- Tasmota stub ----------------
var tasmota = module('tasmota_port')
var SIM = {
    'millis': 0,
    'rtc_local': 1700000000,
    'sensors': {},
    'cmds': list(),
    'rules': map(),
    'timers': map(),   # id -> map('delay':ms,'cb':...) ; real fire not emulated
    'crons': map(),
    'drivers': map(),
    'cmnds': map(),
    'websend': list(),
    'append': list(),
}
var SIM_POWER = [false, false, false, false]
SIM['sensors'] = {'ANALOG': {'A1': 900, 'A2': 900}, 'COUNTER': {'C1': 0, 'C2': 0}}

def SIM_CMD(s)
    SIM['cmds'].push(s)
    # print("  CMD: " .. s)
end

tasmota.read_sensors = def ()
    return json.dump(SIM['sensors'])
end
tasmota.millis = def () return SIM['millis'] end
tasmota.delay = def (ms) end
tasmota.rtc = def () return {'local': SIM['rtc_local']} end

tasmota.cmd = def (c)
    SIM_CMD(c)
end
tasmota.set_timer = def (d, f, id)
    SIM['timers'][id] = {'delay': d, 'cb': f}
    # print("  TIMER set: " .. string(id) .. " " .. string(d))
end
tasmota.remove_timer = def (id)
    if SIM['timers'].find(id) != nil
        SIM['timers'].remove(id)
        # print("  TIMER remove: " .. string(id))
    end
end
tasmota.add_rule = def (tr, cb, id)
    SIM['rules'][tr] = cb
end
tasmota.remove_rule = def (tr, id)
    if SIM['rules'].find(tr) != nil
        SIM['rules'].remove(tr)
    end
end
tasmota.add_cron = def (p, cb, id)
    SIM['crons'][id] = p
end
tasmota.remove_cron = def (id)
    if SIM['crons'].find(id) != nil
        SIM['crons'].remove(id)
    end
end
tasmota.add_driver = def (d)
    SIM['drivers'][d] = true
end
tasmota.remove_driver = def (d)
    SIM['drivers'].remove(d)
end
tasmota.add_cmd = def (n, f)
    SIM['cmnds'][n] = f
end
tasmota.remove_cmd = def (n)
    if SIM['cmnds'].find(n) != nil
        SIM['cmnds'].remove(n)
    end
end
tasmota.resp_cmnd_done = def () end
tasmota.resp_cmnd_error = def () end
tasmota.resp_cmnd_failed = def () end
tasmota.resp_cmnd_str = def (m) end
tasmota.get_power = def (i) return SIM_POWER[i] end
tasmota.set_power = def (idx, onoff)
    SIM_POWER[idx] = onoff ? true : false
    SIM_CMD("Power" .. (idx+1) .. " " .. (onoff ? "1" : "0"))
end
tasmota.strftime = def (f, t) return "2023-01-01 10:00:00" end
tasmota.web_send_decimal = def (m)
    SIM['websend'].push(m)
end
tasmota.response_append = def (m)
    SIM['append'].push(m)
end
tasmota.add_fast_loop = def (f) end

def cmds_include(pat)
    for c: SIM['cmds']
        if string.find(str(c), pat) >= 0
            return true
        end
    end
    return false
end

def log(msg, level)
    level = level == nil ? 2 : level
    print("LOG[" .. level .. "]: " .. msg)
end

class webclient
  def begin(url) end
  def GET() return 0 end
  def get_string() return "" end
end

# ---------------- persist stub -----------------
# Module file tests/modules/persist.be provides `import persist` (class instance).
# It lives as a module so Tasmota-style `import persist` in watering.be resolves.
# Defined in the module file itself; this header only tracks the boot variable.

# ---------------- global stub so boot introspect.get(global,"wp1") works ----------------
var global = module('global')
global.wp1 = nil