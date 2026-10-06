import strict
import string

import cfg
import web_kit
import store
import sensors
import fsm
import web

class Watering
    var SoilSensors
    var FlowSensors
    var Conf_Toggle
    var ServiceMode
    var ServiceResult
    var LastCalibration
    var plants
    var PowerMap
    var _rr_idx
    var BootInitTries
    var ui
    var Store
    var NumChannels
    var _channels_pending
    var FlowRateLimit
    var OutOfWater
    var UnwaterSeconds
    var _initialized


    def button_pressed(cmd, idx, payload, raw)
        if !(cmd == '' && idx == 0 && payload == '')
            # print("Watering: button_pressed", type(cmd), cmd, ',', idx, ',', type(payload), payload, ',', raw)
        end
    end

    #def set_power_handler(cmd, idx)
    #    # idx 0 off, 1 on
    #    var power = tasmota.get_power()
    #end

    def rule_button1(value, trigger)
        print(value, trigger)
        if value['Action'] == 'SINGLE' || value['Action'] == 'DOUBLE'
            # The physical button drives channel 1.
            self.request_manual(self.plants[0])
        end
    end

    def rule_power(value, trigger)
        # POWER{Num}#State rules route to the owning Plant.
        var p = self.PowerMap.find(trigger, nil)
        if p == nil
            print("WARNING: No channel for trigger ", trigger)
            return
        end
        p.rule_power(value)
    end

    def _flooding_plant()
        # The channel whose relay is currently ON (shared counter -> serialised).
        for p: self.plants
            if p.WaterIsOn()
                return p
            end
        end
        return nil
    end

    def request_repeat(plant)
        # Repeat fill after a channel's cooldown. Arbitrated: if another channel
        # is currently pumping (shared C1), defer via a short retry timer instead
        # of a queue; due() is re-checked on every sweep anyway.
        if self.ServiceMode
            print("Service mode: repeat blocked")
            return
        end
        if self._flooding_plant() != nil
            print("Autoflood: repeat blocked (another channel flooding), retry in 60s")
            plant._rearm_soil_check(60*1000)
            return
        end
        plant.start_flood()
    end

    def request_manual(plant)
        if self.ServiceMode
            print("Service mode: manual flood blocked")
            return
        end
        if self._flooding_plant() != nil
            print("Watering: manual flood blocked, another channel flooding")
            return
        end
        plant.start_flood()
    end

    def auto_flood()
        # Sweep: start ONE due channel per invocation, round-robin, only when no
        # channel is actively pumping. Called by the hourly cron window and the
        # autoflood command. Cooldown-timer expiry is handled per-plant via
        # request_repeat(); due() is derived, there is no queue.
        if self.ServiceMode
            print("Autoflood: sweep skipped (service mode)")
            return
        end
        print("Autoflood: sweep")
        if self._flooding_plant() != nil
            print("Autoflood: channel flooding, skip sweep")
            return
        end
        var n = self.plants.size()
        var i = 0
        while i < n
            var idx = (self._rr_idx + i) % n
            var p = self.plants[idx]
            if p.due()
                self._rr_idx = (idx + 1) % n
                print("Autoflood: scheduled start on channel " .. str(p.Num))
                p.start_session()
                return
            end
            i += 1
        end
    end

    def service_enter()
        # Explicit entry into service mode (button on /svc). Arms a fixed 2h
        # timeout regardless of activity; re-entering simply re-arms it.
        self.ServiceMode = true
        self.ServiceResult = nil
        tasmota.remove_timer("ID_SERVICE_MODE_TIMEOUT")
        tasmota.set_timer(2*60*60*1000, /-> self.service_timeout(), "ID_SERVICE_MODE_TIMEOUT")
        print("Service mode ON (timeout 2h)")
    end

    def service_exit()
        if !self.ServiceMode
            return
        end
        self.ServiceMode = false
        tasmota.remove_timer("ID_SERVICE_MODE_TIMEOUT")
        # Stop a service pump, if one is mid-run. The relay command fires the
        # POWER{Num}#State rule -> water_off() service branch (keyed on
        # ServiceRun, by now the mode flag is already off and the normal
        # session logic is untouched).
        for p: self.plants
            if p.ServiceRun
                tasmota.set_power(p.Num - 1, false)
            end
        end
        print("Service mode OFF")
    end

    def service_timeout()
        print("Service mode: 2h timeout expired")
        self.service_exit()
    end

    def timer_endfasttele_after_flooded()
        print("Timer: end fast teleperiod after flooded")
        tasmota.cmd("TelePeriod 300") # Default Tasmota teleperiod (not the flood's fast 10s)
    end

    def pulseencode(time)
        #- https://tasmota.github.io/docs/Commands/#pulsetime -#
        if time < 0
            print("pulseencode: MaxPumpRun ".. time .." out of bounds, clamped to 0")
            time = 0
        elif time > 64800
            print("pulseencode: MaxPumpRun ".. time .." out of bounds, clamped to 64800")
            time = 64800
        end
        if 0 <= time && time <= 11.1
           return int(time * 10)
        elif 11.1 < time && time <= 11.5
           return 111
        elif 11.5 < time && time < 12
           return 112
        else
           return int(time + 100)
        end
    end


    def update()

    end

    def init()
        # On early boot Tasmota subsystems (sensors etc.) may not be up yet.
        # Do NOT block the main loop with tasmota.delay() here - it stalls the
        # whole Tasmota and the sensor subsystem never comes up. Defer the
        # service dependent init to a non-blocking timer with retries instead.
        print("Init Watering object")
        print("imported", tasmota)
        self.BootInitTries = 0
        self._channels_pending = nil
        self.Store = store.PersistStore()
        # Channel count is a Store variable (persistent, immediate policy) so
        # the number of channels can be configured without code changes. It is
        # registered before load() and clamped to [1, cfg.MAX_CHANNELS].
        self.Store.register('Channels', {'default': '2', 'policy': 'immediate'})
        # Global flow-sensor calibration (ml per counter tick). The C1 flow
        # meter is shared by every channel, so the scale is a global key, not a
        # per-channel P{Num} one. Calibrated from the service page.
        self.Store.register('FlowScale', {'default': '0.1449', 'policy': 'debounced'})
        # One-time units-upgrade marker: present once the iteration-1 C1-tick
        # persisted values have been converted to ml (see _migrate_units).
        self.Store.register('UnitsV2', {'default': '0', 'policy': 'immediate'})
        # Global low-flow detection limit (ml/min). 0 = detection disabled. When
        # an active channel measures Rate*60 below this, the global OutOfWater
        # flag is set (see _flow_low_check). Configured from the service page.
        self.Store.register('FlowRateLimit', {'default': '0', 'policy': 'debounced'})
        for i: 0..(cfg.MAX_CHANNELS - 1)
            self.Store.register_channel('P' + str(i + 1))
        end
        self.Store.load()
        self.NumChannels = int(self.Store.get('Channels'))
        if self.NumChannels == nil || self.NumChannels < 1
            self.NumChannels = 1
        elif self.NumChannels > cfg.MAX_CHANNELS
            self.NumChannels = cfg.MAX_CHANNELS
        end
        # Global low-flow detection limit (ml/min, 0 = off). Read after load()
        # so a persisted override wins over the registered default. The flag and
        # the grace counter are pure in-memory session state.
        self.FlowRateLimit = int(self.Store.get('FlowRateLimit'))
        if self.FlowRateLimit == nil
            self.FlowRateLimit = 0
        end
        self.OutOfWater = false
        self.UnwaterSeconds = 0
        # Upgrade persisted values from C1 ticks to ml BEFORE the plants read
        # them (plants are created in init_sensors()).
        self._migrate_units(real(self.Store.get('FlowScale')))
        # Phase 2 of init is deferred: init_sensors() reads sensors, creates
        # plants and registers the driver + commands/cron. Running it here,
        # synchronously at script load, puts read_sensors() inside the early
        # boot window where the firmware's own sensor drivers may still be
        # coming up and the read throws through the FUNC_JSON_APPEND dispatch.
        # Arm a one-shot timer instead (non-blocking; ID_DELAY_INIT is then
        # reused by init_sensors()' retry loop if the first read still fails).
        self._initialized = false
        tasmota.set_timer(cfg.BOOT_INIT_DELAY_MS, /-> self.init_sensors(), "ID_DELAY_INIT")
        # The web UI is a separate object holding a reference back to this
        # driver; it is built here (not in init_sensors) because it only needs
        # the driver itself, never the plants that phase 2 creates later.
        self.ui = web.Web(self)
    end

    def _migrate_units(mscale)
        # One-time upgrade of iteration-1 persisted values: config/volume keys
        # and session stats were stored as C1 ticks. The internal canonical unit
        # is ml, so stored ticks are converted (x scale) and the UnitsV2 marker
        # makes the pass idempotent. Keys that were never persisted keep their
        # (already ml) registered defaults - only real stored values convert.
        if self.Store.get('UnitsV2') == '1'
            return
        end
        if mscale == nil || !(mscale > 0)
            mscale = 0.1449
        end
        for i: 0..(self.NumChannels - 1)
            for k: ['SoakStartDose', 'SoakDailyCap', 'SoakMaxDose', 'LastFloodVol', 'PrevFloodedVol']
                var key = 'P' + str(i + 1) .. k
                if self.Store.has(key)
                    var v = real(self.Store.get(key))
                    if v != nil
                        self.Store.set(key, int(v * mscale + 0.5))
                    end
                end
            end
        end
        self.Store.set('UnitsV2', '1')
    end

    def init_sensors()
        # Idempotency: phase 2 may be invoked by the ID_DELAY_INIT timer, by a
        # hot reload retry, or (in tests) directly. Exit immediately if phase 2
        # already completed.
        if self._initialized
            return
        end
        # Retry reading sensors until Tasmota has booted. On real boot the read
        # may throw; catch it and retry via a non-blocking timer instead of
        # failing the whole load(). In tests/runtime read succeeds immediately.
        print("Try reading sensors")
        import json
        import math
        import introspect
        try
            var tmp = tasmota.read_sensors()
            print("Sensors readen from tasmota")
        except .. as e
            self.BootInitTries += 1
            print("Sensors not ready on boot: " .. e)
            if self.BootInitTries <= 30
                tasmota.set_timer(1000, /-> self.init_sensors(), "ID_DELAY_INIT")
            else
                print("Giving up on delayed sensor init")
                print("ERROR: Watering driver NOT registered (sensors never came up)")
            end
            return
        end
        print("Sensors loaded from Json string")

        self.Conf_Toggle = 0

        print("Init sensors")
        self.SoilSensors = list()
        self.FlowSensors = list()
        for i: 0..(self.NumChannels - 1)
            self.SoilSensors.push(sensors.SoilSensor('A' + str(i + 1)))
        end
        self.FlowSensors = [sensors.FlowSensor('C1'), sensors.FlowSensor('C2')]
        # Apply the stored flow calibration (overrides the built-in default).
        # Guarded: an unparsable/corrupt value falls back to the built-in scale.
        var fscale = self.Store.get('FlowScale')
        if fscale != nil
            var fval = real(fscale)
            if fval != nil && fval > 0
                self.FlowSensors[0].setScale(fval)
            end
        end
        print("Sensors initialized")

        # Plants: per-channel state + FSM. Each channel registers its own relay
        # rule (POWER{Num}#State) and gets its PulseTime (MaxPumpRun time cap).
        self.plants = list()
        self.PowerMap = {}
        self._rr_idx = 0
        for i: 0..(self.NumChannels - 1)
            var p = fsm.Plant(i, self)
            self.plants.push(p)
            self.PowerMap['POWER' + str(i + 1)] = p
            var pnum = str(i + 1)
            var PulseTime = int(self.pulseencode(p.MaxPumpRun))
            # Plain numeric form: the structured :{"Set":N,"Remaining":0} form is a
            # silent no-op on the target firmware, keeping the real cap instead.
            tasmota.cmd('PulseTime' .. pnum .. ' ' .. str(PulseTime))
            tasmota.add_rule("POWER" .. pnum, / v, t -> self.rule_power(v, t))
        end

        tasmota.add_driver(self)
        tasmota.cmd('PowerOnState 0') # relay off after PowerOn
        tasmota.cmd('SetOption73 1') # Detach buttons from relays
        tasmota.add_rule("BUTTON1", / v, t -> self.rule_button1(v, t))
        tasmota.remove_cron("auto_flood")
        tasmota.add_cron("0 1 14,15,16,17,18,19,20,21,22,23,0,1 * * *", /-> self.auto_flood(), "auto_flood")
        print("Cron auto_flood initialized")
        tasmota.remove_cmd("autoflood")
        tasmota.add_cmd("autoflood", def () self.auto_flood() tasmota.resp_cmnd_done() end)
        print("Command auto_flood initialized")
        tasmota.remove_cmd("SoilDry")
        tasmota.add_cmd("SoilDry", def (cmd, idx, payload, payload_json)
            # Empty payload (e.g. "SoilDry") means "report current value",
            # never "set to 0" (int("") == 0 would reset the threshold).
            # Affects channel 1 (the primary zone).
            if payload == nil || payload == ""
                tasmota.resp_cmnd_str(str(self.plants[0].TargetDry))
                return
            end
            try
                if self.plants[0].SetDry(int(payload))
                    tasmota.resp_cmnd_done()
                else
                    tasmota.resp_cmnd_error()
                end
            except .. as e
                log("SoilDry: bad payload " .. payload, 1)
                tasmota.resp_cmnd_error()
            end
        end)
        tasmota.remove_cmd("SoilWet")
        tasmota.add_cmd("SoilWet", def (cmd, idx, payload, payload_json)
            # Empty payload means "report current value", not "set to 0".
            if payload == nil || payload == ""
                tasmota.resp_cmnd_str(str(self.plants[0].TargetWet))
                return
            end
            try
                if self.plants[0].SetWet(int(payload))
                    tasmota.resp_cmnd_done()
                else
                    tasmota.resp_cmnd_error()
                end
            except .. as e
                log("SoilWet: bad payload " .. payload, 1)
                tasmota.resp_cmnd_error()
            end
        end)
        print("Commands SoilDry/SoilWet initialized")
        tasmota.remove_cmd("DrySoak")
        tasmota.add_cmd("DrySoak", def (cmd, idx, payload, payload_json)
            # Empty payload means "report current status", "start" forces a dry
            # soak on channel 1 (raw soil dry by EMA is still required inside
            # start_flood).
            var p0 = self.plants[0]
            if payload == nil || payload == "" || payload == "status"
                var ptype = p0.Preset != nil ? p0.Preset.Type : 'none'
                var dose = p0.Preset != nil && p0.Preset.Type == 'dry' ? str(p0.DrySoakDose) : str(p0.PlannedFlood)
                var since = p0.DrySoakStartMillis != nil ? str((tasmota.millis() - p0.DrySoakStartMillis)/1000) : '-'
                tasmota.resp_cmnd_str("preset=" .. ptype .. ", DryThreshold=" .. str(p0.DryThreshold) ..
                    ", dose=" .. dose .. ", since_s=" .. since)
                return
            end
            if payload == "start"
                p0.Preset = fsm.FloodPreset('dry', self.Store, p0.Prefix)
                p0.DrySoakDose = p0.Preset.StartDose
                p0.DrySoakStartMillis = tasmota.millis()
                p0.DryEmaHistory = list()
                p0.DryDailyVol = list()
                self.request_manual(p0)
                tasmota.resp_cmnd_done()
                return
            end
            tasmota.resp_cmnd_error()
        end)
        print("Command DrySoak initialized")
        tasmota.remove_cmd("Store")
        tasmota.add_cmd("Store", def ()
            import json
            tasmota.resp_cmnd_str(json.dump(self.Store.dump()))
        end)
        tasmota.remove_cmd("Channels")
        tasmota.add_cmd("Channels", def (cmd, idx, payload, payload_json)
            # Report or set the channel count (persisted in the Store variable).
            # Empty payload means "report"; a number sets Channels and needs a
            # restart to take effect (init builds sensors/plants/rules from it).
            if payload == nil || payload == ""
                tasmota.resp_cmnd_str(str(self.NumChannels))
                return
            end
            var n = int(payload)
            if n == nil || n < 1 || n > cfg.MAX_CHANNELS
                tasmota.resp_cmnd_error()
                return
            end
            self.Store.set('Channels', str(n))
            tasmota.resp_cmnd_str("Channels set to " .. str(n) .. ", restart required")
        end)
        print("Command Store initialized")
        # The ID_DELAY_INIT timer has served its purpose (this run, or the
        # build.py test shim): drop the pending callback. Harmless on the
        # device (one-shot timer already fired); breaks the closure cycle so
        # test VMs garbage-collect cleanly on exit.
        tasmota.remove_timer("ID_DELAY_INIT")
        self._initialized = true
        print("Watering driver initialized")
    end

    def deinit()
        self.Store.flush(true)
        tasmota.remove_timer("ID_PERSIST_SAVE")
        tasmota.remove_timer("ID_SERVICE_MODE_TIMEOUT")
        tasmota.remove_rule("BUTTON1")
        tasmota.remove_cron("auto_flood")
        tasmota.remove_timer("ID_ENDFASTTELE")
        tasmota.remove_timer("ID_DELAY_INIT")
        tasmota.remove_cmd("autoflood")
        tasmota.remove_cmd("SoilDry")
        tasmota.remove_cmd("SoilWet")
        tasmota.remove_cmd("DrySoak")
        tasmota.remove_cmd("Store")
        tasmota.remove_cmd("Channels")
        for p: self.plants
            tasmota.remove_rule("POWER" + str(p.Num))
            tasmota.remove_timer(p._soil_timer_id())
            tasmota.set_power(p.Num - 1, false)
            if p.FinishRule
                tasmota.remove_rule(p.FinishRule)
                p.FinishRule = nil
                print("Flood FinishRule removed")
            end
        end
        tasmota.remove_driver(self)
        for i: 0..(self.plants.size() - 1)
            self.SoilSensors[i] = nil
        end
        # Drop the UI before the sensors: it holds a reference to this driver,
        # so a stale UI would keep the whole object graph alive.
        self.ui = nil
    end

    def every_second()
        #self.read_tds()
        import json
        import math
        var tmp
        var sensors
        try
            tmp = tasmota.read_sensors()
            sensors = json.load(tmp)
            if sensors == nil
                return
            end
        except .. as _boot_read_exc
            # Same early-boot protection as get_sensors(): right after the
            # load the firmware's own drivers can still be coming up and
            # read_sensors() may throw through the FUNC_JSON_APPEND dispatch.
            # Skip this tick; the next one will read normally.
            return
        end
        for s: self.SoilSensors
            s.Update(sensors)
        end
        for s: self.FlowSensors
            s.Update(sensors)
        end
        try
            self._flow_low_check()
        except .. as e
            print("every_second: flow check failed " .. e)
        end
        for p: self.plants
            if !p.PauseSoilMaxStat && p._stats_enabled()
                if p.SoilMaxHymidityTemp == nil || p.SoilMaxHymidityTemp > p.SoilSensor.RawEma
                    p.SoilMaxHymidityTemp = p.SoilSensor.RawEma
                    p.SoilMaxHymidityTimeTemp = tasmota.rtc()['local']
                end
                # Confirmed peak is stale once the soil reads wetter than it
                # (RawEma below the last confirmed minimum): drop it so the
                # stored value never overstates the current humidity. Gated by
                # the same conditions as the tracker, so the pump's own
                # absorption window and the dry-soak preset never touch it.
                if p.SoilMaxHymidity != nil && p.SoilSensor.RawEma < p.SoilMaxHymidity
                    p.SoilMaxHymidity = nil
                    p.SoilMaxHymidityTime = nil
                end
            end
            if p.SoilMaxHymidityTemp != nil && (p.SoilMaxHymidity == nil || p.SoilMaxHymidityTemp < p.SoilMaxHymidity) && p.SoilSensor.RawEma > p.SoilMaxHymidityTemp + 5
                print("SoilMaxHymidityConfirmed")
                p.SoilMaxHymidity = p.SoilMaxHymidityTemp
                p.SoilMaxHymidityTime = p.SoilMaxHymidityTimeTemp
                self.Store.save_batch_entries(p.max_batch())
            end
        end
    end

    def _flow_low_check()
        # Global "Out of Water" detection. The flow limit (ml/min, 0 = off,
        # global FlowRateLimit Store key) is compared against the live rate of
        # the shared C1 water meter (FlowSensors[0] - the only meter that
        # waters; every Plant reads it via <Owner.FlowSensors[0]). The
        # per-channel dimension is the pump state: any channel whose pump is on
        # (WaterIsOn) while the shared rate stays below the limit for
        # LOWFLOW_GRACE seconds counts as running dry; such a channel flips the
        # global OutOfWater flag. The flag clears as soon as the sustained-low
        # condition does (no active channel below the limit, or all pumps off).
        if self.FlowRateLimit == nil || self.FlowRateLimit <= 0
            self.UnwaterSeconds = 0
            self.OutOfWater = false
            return
        end
        var fs = self.FlowSensors[0]
        var lrate = fs.Rate != nil ? fs.Rate * 60 : 0
        var low = false
        for i: 0..(self.NumChannels - 1)
            var p = self.plants[i]
            if p.WaterIsOn() && lrate < self.FlowRateLimit
                low = true
            end
        end
        if low
            self.UnwaterSeconds += 1
            # Grace period: choke-start of the pump and short bursts must not
            # trip the alarm. 5 s at sub-limit flow is treated as real dry-run.
            if self.UnwaterSeconds >= 5
                if !self.OutOfWater
                    print("OutOfWater: low flow for " .. self.UnwaterSeconds .. "s")
                end
                self.OutOfWater = true
            end
        else
            self.UnwaterSeconds = 0
            if self.OutOfWater
                print("OutOfWater: flow restored")
            end
            self.OutOfWater = false
        end
    end





    def json_append()
        #- add sensor value to teleperiod -#
        # NOTE: Keys of the "Watering" dict are part of the external integration
        # contract (InfluxDB / Grafana / OpenHAB via Ifx + teleperiod JSON).
        # Renaming/removing a key requires updating external consumers first.
        # Channel 1 is the telemetry channel (kept identical to iteration 1).
        import json
        var p0 = self.plants[0]
        var wtele = {
                'Soil1Raw': int(self.SoilSensors[0].Raw),
                'Soil1RawEma': int(self.SoilSensors[0].RawEma),
                'Soil1Hymidity': self.SoilSensors[0].Hymidity,
                'Soil2RawEma': int(self.SoilSensors[1].RawEma),
                'Soil2Hymidity': self.SoilSensors[1].Hymidity,
                'LastFloodSessionVol': p0.ticks(p0.LastFloodVol),
                'LastSoilMaxHymidity':  p0.SoilMaxHymidity,
                'PrevSoilHPreFlood': p0.PrevSoilHPreFlood,
                'PrevFloodedVol': p0.ticks(p0.PrevFloodedVol),
                'PrevSoilMaxHymidity': p0.PrevSoilMaxHymidity,
                'PumpRunMillis': p0.PumpRunMillis,
                'FlowSensorRate': self.FlowSensors[0].Rate,
                'OutOfWater': self.OutOfWater,
                'SoilHPreFlood': p0.SoilHPreFlood,

                     }
        var json_tele = string.format(", \"Watering\": %s", json.dump(wtele))
        #print('json_append:', json_tele)
        tasmota.response_append(json_tele)
        #print("json_append: processed")
    end

    # --- UI delegates -------------------------------------------------------
    # Tasmota's harness calls these by name on the driver, and the test suite
    # calls them directly (page_service 40 sites), so they stay here as
    # no-arg one-liners. The implementation lives in web.Web with the driver
    # injected as self.d.
    def web_sensor()
        return self.ui.web_sensor()
    end

    def web_add_main_button()
        return self.ui.web_add_main_button()
    end

    def web_add_handler()
        return self.ui.web_add_handler()
    end

    def page_service()
        return self.ui.page_service()
    end

end

# Configure InfluxDB telemetry BEFORE (re)creating the Watering driver so that
# system data keeps flowing even if the driver crashes during deinit/init.
tasmota.cmd('ifx {"State":"ON","Host":"172.17.200.197","Port":8086,"Version":2,"Bucket":"e39ac351b59fc1d9","Org":"openhab"}')
tasmota.cmd("IfxToken ");

print("Check for old watering object")
import introspect
#print(introspect.get(global, "wp1"))
if introspect.get(global, "wp1") != nil
    print("Remove old Watering driver")
    introspect.get(global, "wp1").deinit()
end

print("Add new Watering driver")
wp1 = Watering()
# tasmota.cmd("BrRestart");







