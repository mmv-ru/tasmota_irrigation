import strict
import string
import json
import introspect

import store
import sensors

var fsm = module('fsm')

class FloodPreset
    # Flood strategy for a session. 'normal' reproduces the classic auto-flood:
    # escalating dose on a fixed 2h/24h interval, writing Prev*/estimate stats
    # (WriteStats=true). 'dry' is the dry-soil soak: small fixed doses on the
    # SoakInterval cadence, adapted by the SoakTrendWindow RawEma trend, capped
    # by a daily volume, and it does NOT pollute the Prev*/estimate stats
    # (WriteStats=false). Per-channel parameters are read under the plant's
    # persist prefix (SoakStartDose etc. are per-channel).
    var Type
    var StartDose
    var AdaptMode
    var StopRaw
    var WindowSec
    var DoseGrow
    var DailyCap
    var MaxDose
    var WriteStats
    var Prefix

    def init(ptype, store, prefix)
        self.Type = ptype
        self.Prefix = prefix != nil ? prefix : ''
        if ptype == 'dry'
            # Soak volumes are ml (StartDose/DailyCap/MaxDose); raw/interval
            # knobs stay integers in their own units.
            self.StartDose = real(store.get(self.Prefix .. 'SoakStartDose'))
            self.AdaptMode = 'trend'
            self.StopRaw = int(store.get(self.Prefix .. 'DryThreshold'))
            self.WindowSec = int(store.get(self.Prefix .. 'SoakTrendWindow'))
            self.DoseGrow = real(store.get(self.Prefix .. 'SoakDoseGrow'))
            self.DailyCap = real(store.get(self.Prefix .. 'SoakDailyCap'))
            self.MaxDose = real(store.get(self.Prefix .. 'SoakMaxDose'))
            self.WriteStats = false
        else
            self.StartDose = 0
            self.AdaptMode = 'escalate'
            self.StopRaw = nil
            self.WindowSec = nil
            self.DoseGrow = 1.2
            self.DailyCap = nil
            self.MaxDose = nil
            self.WriteStats = true
        end
    end

    def dose(plant)
        # StartDose==0 means "use the classic planned dose (estimate or default)".
        # The dry soak uses the adaptive DrySoakDose, which starts at StartDose
        # and grows with the trend escalation.
        if self.StartDose != nil && self.StartDose > 0
            return plant.DrySoakDose != nil ? plant.DrySoakDose : self.StartDose
        end
        return plant.planned_dose()
    end

    def evaluate(plant)
        # Post-flood soil check. Returns 'repeat' | 'hold' | 'pause' | 'stop'.
        # 'repeat' is NOT started here: the dispatcher arbitrates (shared flow
        # counter, one fill at a time) via plant.Owner.request_repeat().
        if self.AdaptMode == 'trend'
            return self._evaluate_trend(plant)
        end
        return self._evaluate_escalate(plant)
    end

    def _evaluate_escalate(plant)
        return plant._escalate_evaluate()
    end

    def _evaluate_trend(plant)
        var sensor = plant.SoilSensor
        var now = tasmota.millis()
        # Soil recovered past the dry threshold -> the soak is done.
        if sensor.RawEma < self.StopRaw
            print("Dry soak: RawEma " .. sensor.RawEma .. " < StopRaw " .. self.StopRaw .. ", stop session")
            plant._drysoak_end()
            return 'stop'
        end
        # Record current EMA into the in-memory history ring (pruned to window).
        plant.DryEmaHistory.push({'ms': now, 'ema': sensor.RawEma})
        var windowMs = self.WindowSec * 1000
        while plant.DryEmaHistory.size() > 1 && now - plant.DryEmaHistory[0]['ms'] > windowMs
            plant.DryEmaHistory.remove(0)
        end
        # Daily volume cap: no more soaking today, re-check after the cadence.
        if self._cap_reached(plant, now)
            print("Dry soak: daily cap reached, pausing")
            plant._rearm_soil_check(int(plant.Store.get(self.Prefix .. 'SoakInterval')) * 1000)
            return 'pause'
        end
        # Trend window not full yet -> no escalation basis, repeat same dose.
        if now - plant.DryEmaHistory[0]['ms'] < windowMs
            print("Dry soak: trend window not full, repeating dose")
            return 'repeat'
        end
        # Soil got drier or stayed put over the window -> dose up, else hold.
        # Humidity rises as RawEma falls: DeltaRaw < 0 means the soak works.
        var delta = sensor.RawEma - plant.DryEmaHistory[0]['ema']
        if delta >= 0
            plant.DrySoakDose = int(real(plant.DrySoakDose) * self.DoseGrow)
            if plant.DrySoakDose > self.MaxDose
                plant.DrySoakDose = self.MaxDose
                print("Dry soak: dose capped at MaxDose " .. self.MaxDose)
            end
            print("Dry soak: no response over window, dose escalated to " .. plant.DrySoakDose)
            return 'repeat'
        else
            print("Dry soak: humidity rising, holding")
            plant._rearm_soil_check(int(plant.Store.get(self.Prefix .. 'SoakInterval')) * 1000)
            return 'hold'
        end
    end

    def _cap_reached(plant, now)
        # Sum flooded volume in the last 24h from the DryDailyVol ring (ml).
        var capMs = 24*60*60*1000
        var sum = 0.0
        var i = 0
        while i < plant.DryDailyVol.size()
            var t = plant.DryDailyVol[i]
            if now - t['ms'] <= capMs
                sum += real(t['vol'])
                i += 1
            else
                plant.DryDailyVol.remove(i)
            end
        end
        return sum >= self.DailyCap
    end
end



class Plant
    # One irrigation channel: own pump relay (Power{Num}), own soil sensor
    # (SoilSensor, = Watering.SoilSensors[Idx]), own flood FSM and dry-soak
    # state. All channels share the flow counter C1 (Watering.FlowSensors[0]),
    # so a fill may only run when no other channel's relay is ON. Persisted
    # state lives under the P{Num} prefix of the shared PersistStore.
    var Owner
    var Idx
    var Num
    var Prefix
    var Store
    var SoilSensor
    var MaxPumpRun
    var PumpStartMillis
    var PumpRunMillis
    var Counter1BeforeStartTicks
    var Counter1Backflow
    var Counter1FloodDefault
    var MaxFlood
    var PlannedFlood
    var FinishRule
    var SoilMaxHymidity
    var SoilMaxHymidityTime
    var SoilMaxHymidityTemp
    var SoilMaxHymidityTimeTemp
    var LastFloodTime
    var LastFloodVol
    var LastFlowRate
    var SoilHPreFlood
    var PrevSoilMaxHymidity
    var PrevSoilHPreFlood
    var PrevFloodedVol
    var AutofloodInProcess
    var Counter1ResetPostpone
    var PauseSoilMaxStat
    var ServiceRun
    var Preset
    var DryThreshold
    var TargetDry
    var TargetWet
    var DrySoakDose
    var DrySoakStartMillis
    var DryEmaHistory
    var DryDailyVol

    def init(idx, owner)
        import introspect
        self.Owner = owner
        self.Idx = idx
        self.Num = idx + 1
        self.Prefix = 'P' + str(self.Num)
        self.Store = owner.Store
        self.SoilSensor = owner.SoilSensors[idx]
        self.TargetDry = int(self.Store.get(self.Prefix .. 'TargetDry'))
        self.TargetWet = int(self.Store.get(self.Prefix .. 'TargetWet'))
        self.DryThreshold = int(self.Store.get(self.Prefix .. 'DryThreshold'))
        for p: ['SoilHPreFlood',
                'SoilMaxHymidity', 'SoilMaxHymidityTime',
                'PrevSoilMaxHymidity',
                'PrevSoilHPreFlood', 'PrevFloodedVol',
                'LastFloodTime', 'LastFlowRate']
            var v = self.Store.get(self.Prefix .. p)
            introspect.set(self, p, v)
        end
        self.LastFloodVol = int(self.Store.get(self.Prefix .. 'LastFloodVol'))
        self.MaxPumpRun = 60
        # Volumes are expressed in ml (the internal canonical unit); the C1
        # counter stays in ticks and is converted at the border via ticks().
        # Session dose parameters are per-channel Store keys (defaults 300/30/0):
        # MaxFlood (session volume cap), Counter1FloodDefault (fallback dose) and
        # Counter1Backflow (backflow compensation, Store-only — no UI field).
        self.MaxFlood = int(self.Store.get(self.Prefix .. 'MaxFlood'))
        self.Counter1FloodDefault = int(self.Store.get(self.Prefix .. 'Counter1FloodDefault'))
        self.Counter1Backflow = int(self.Store.get(self.Prefix .. 'Counter1Backflow'))
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false
        self.ServiceRun = false
        self.Counter1ResetPostpone = false
        self.Counter1BeforeStartTicks = owner.FlowSensors[0].Raw
    end

    def ticks(vol_ml)
        # C1-boundary conversion ml -> counter ticks (counter rules, backflow
        # subtraction, telemetry export). The scale is the calibrated
        # ml-per-tick coefficient; a missing/zero scale keeps ml as-is.
        # Rounding is banker-safe for the expected positive values (int(x+0.5)).
        if vol_ml == nil
            return nil
        end
        var scale = self.Owner.FlowSensors[0].Scale
        if scale == nil
            return int(vol_ml)
        end
        var fscale = real(scale)
        if fscale == nil || !(fscale > 0)
            return int(vol_ml)
        end
        return int(real(vol_ml) / fscale + 0.5)
    end

    def _soil_timer_id()
        return "ID_SOILTRANSITION_AFTERFLOOD_P" .. str(self.Num)
    end

    def due()
        # Derived "wants a fill right now": soil dry by RAW, no session running.
        # Re-computed on every sweep; there is no persistent queue.
        return self.IsDry() && !self.AutofloodInProcess
    end

    def IsDry()
        # Soil counts as dry at/above the per-channel dry threshold. Thresholds
        # are Plant-owned policy; the sensor only measures. Nil-safe: no
        # reading -> not dry.
        return self.SoilSensor.Raw != nil && self.SoilSensor.Raw >= self.TargetDry
    end

    def IsWet()
        # Soil counts as wet at/below the per-channel wet threshold.
        return self.SoilSensor.Raw != nil && self.SoilSensor.Raw <= self.TargetWet
    end

    def SetDry(raw)
        var r = int(raw)
        if r == nil || r <= 0
            print("Plant: SetDry rejected, bad raw " .. str(raw) .. " -> " .. str(r))
            return false
        end
        if r - self.TargetWet <= 20
            print("Plant: SetDry rejected, gap " .. r .. "-" .. self.TargetWet .. " <= 20")
            return false
        end
        self.TargetDry = r
        self.Store.set(self.Prefix .. 'TargetDry', self.TargetDry)
        return true
    end

    def SetWet(raw)
        var r = int(raw)
        if r == nil || r <= 0
            print("Plant: SetWet rejected, bad raw " .. str(raw) .. " -> " .. str(r))
            return false
        end
        if self.TargetDry - r <= 20
            print("Plant: SetWet rejected, gap " .. self.TargetDry .. "-" .. r .. " <= 20")
            return false
        end
        self.TargetWet = r
        self.Store.set(self.Prefix .. 'TargetWet', self.TargetWet)
        return true
    end

    def WaterIsOn()
        return tasmota.get_power(self.Num - 1)
    end

    def rule_power(value)
        if value['State'] == 1
            self.water_on()
        elif value['State'] == 0
            self.water_off()
        else
            print("WARNING: Unexpected watering pump state ", value['State'])
        end
    end

    def water_on()
        # Service-mode run (started from the /svc page while the mode is on):
        # no wet-soil guard, no FinishRule, no session bookkeeping - just the
        # fast telemetry, the shared counter snapshot and rate measuring, so a
        # stop can report {ticks, millis} for calibration. Re-entry is ignored.
        if self.Owner.ServiceMode && !self.ServiceRun
            self.ServiceRun = true
            self.Owner.ServiceResult = nil
            self.PumpStartMillis = tasmota.millis()
self.Counter1BeforeStartTicks = self.Owner.FlowSensors[0].Raw
            tasmota.cmd("TelePeriod 10")
            tasmota.remove_timer("ID_ENDFASTTELE")
            self.Owner.FlowSensors[0].RateMeasuring = true
            print("Service: pump " .. str(self.Num) .. " ON")
            return
        end
        if self.ServiceRun
            print("Service: pump " .. str(self.Num) .. " already running")
            return
        end
        self.PumpStartMillis = tasmota.millis()
        print("Water pump " .. str(self.Num) .. " ON")
        if self.IsWet()
            print("Too wet to flood. Stop pump.")
            tasmota.set_power(self.Num - 1, false)
            return
        end
        tasmota.cmd("TelePeriod 10")
        self.PauseSoilMaxStat = true
        self.Counter1BeforeStartTicks = self.Owner.FlowSensors[0].Raw
        print("Counter: ", self.Owner.FlowSensors[0].Raw)
        # A new flood while the previous "return to default teleperiod"
        # timer is still pending would let it kill this session's fast
        # telemetry mid-run. Cancel it here.
        tasmota.remove_timer("ID_ENDFASTTELE")
        if self.PlannedFlood
            self.FinishRule = "COUNTER#C1>="..(self.Owner.FlowSensors[0].Raw + self.ticks(self.Counter1Backflow) + self.ticks(self.PlannedFlood))
        else
            self.FinishRule = "COUNTER#C1>="..(self.Owner.FlowSensors[0].Raw + self.ticks(self.Counter1Backflow) + self.ticks(self.Counter1FloodDefault))
        end
        print("Flooding FinishRule ", self.FinishRule)
        tasmota.add_rule(self.FinishRule, / v, t -> self.rule_flooded(v, t))
        print("Rule on ", self.FinishRule, " set")
        # TODO: delay RateMeasuring when no check-valve
        self.Owner.FlowSensors[0].RateMeasuring = true
    end

    def water_off()
        import json
        var sensors = json.load(tasmota.read_sensors())
        var Counter1 = 0
        if sensors != nil
            var counter = sensors.find('COUNTER')
            if counter != nil
                Counter1 = counter['C1']
            end
        end
        if self.ServiceRun
            # Service-mode stop: report the raw ticks and run time for the
            # calibration math, without touching the counter (no backflow
            # compensation) and without session bookkeeping. Fall back to the
            # normal finish path when this was a real flood.
            self.Owner.FlowSensors[0].RateMeasuring = false
            self.PumpRunMillis = tasmota.millis() - self.PumpStartMillis
            var ticks = Counter1 - self.Counter1BeforeStartTicks
            if ticks < 0
                ticks = 0
            end
            self.ServiceRun = false
            self.Owner.ServiceResult = {'num': self.Num, 'ticks': ticks, 'millis': self.PumpRunMillis, 'finished': tasmota.rtc()['local']}
            print("Service: pump " .. str(self.Num) .. " OFF, ticks=" .. str(ticks) .. " millis=" .. str(self.PumpRunMillis))
            tasmota.remove_timer("ID_ENDFASTTELE")
            tasmota.set_timer(60*1000, /-> self.Owner.timer_endfasttele_after_flooded(), "ID_ENDFASTTELE")
            return
        end
        try
            self.PumpRunMillis = tasmota.millis() - self.PumpStartMillis
        except .. as e
            log("Pump stop without run.", 1)
        end
        print("Water pump " .. str(self.Num) .. " OFF")
        if self.FinishRule
            tasmota.remove_rule(self.FinishRule)
            self.FinishRule = nil
            print("Flooding FinishRule removed")
        end
        self.Owner.FlowSensors[0].RateMeasuring = false
        var CounterDeltaTicks = self._compensate_backflow(Counter1)
        print("Counter compensated: ", Counter1)
        print("Water flooded " .. CounterDeltaTicks)
        if CounterDeltaTicks > 0
            self._record_flood(CounterDeltaTicks)
        else
            self._end_session_no_water()
        end
        tasmota.remove_timer("ID_ENDFASTTELE")
        tasmota.set_timer(60*1000, /-> self.Owner.timer_endfasttele_after_flooded(), "ID_ENDFASTTELE")
    end

    def _compensate_backflow(Counter1)
        # Subtract backflow (water that returned through the pipe after pump
        # stop) from the counters and from the session delta. The backflow is a
        # volume in ml: converted to counter ticks via the C1 scale. Returns the
        # net amount of water (ticks) that actually left the pipe.
        var d = Counter1 - self.Counter1BeforeStartTicks
        var BackflowTicks = self.ticks(self.Counter1Backflow)
        if d > BackflowTicks
            tasmota.cmd(string.format("counter1 %i", Counter1 - BackflowTicks))
            return d - BackflowTicks
        else
            tasmota.cmd(string.format("counter1 %i", Counter1 - d))
            return 0
        end
    end

    def _record_flood(CounterDeltaTicks)
        # Record a finished flood dose and schedule the post-flood soil check.
        # The session volume accumulates in ml (ticks x the calibrated C1 scale);
        # the scale guard is shared with ticks() so both directions stay in sync.
        var flood_delay = 2*60*60*1000
        self.LastFloodTime = tasmota.rtc()['local']
        var scale = self.Owner.FlowSensors[0].Scale
        if scale == nil
            scale = 1.0
        end
        var fscale = real(scale)
        if fscale == nil || !(fscale > 0)
            fscale = 1.0
        end
        var DeltaMl = CounterDeltaTicks * fscale
        self.LastFloodVol += DeltaMl
        # Average flow (ml/min) of this channel's last fill: dose volume over
        # its own pump-on duration. Persisted (see below) so the web group
        # "Последний полив" survives a reboot.
        if self.PumpRunMillis != nil && self.PumpRunMillis > 0
            self.LastFlowRate = (DeltaMl * 60000.0) / self.PumpRunMillis
        else
            self.LastFlowRate = nil
        end
        # Persist the last-fill date and average flow rate (debounced policy,
        # one save). The rate is guarded: a fill without a tracked pump-run
        # must not resurrect a stale rate from Flash after a reboot.
        self.Store.set(self.Prefix .. 'LastFloodTime', self.LastFloodTime)
        if self.LastFlowRate != nil
            self.Store.set(self.Prefix .. 'LastFlowRate', self.LastFlowRate)
        end
        if self.Preset != nil && self.Preset.Type == 'dry'
            # Dry soak cadence: fixed interval + daily volume tracking (ml).
            flood_delay = int(self.Store.get(self.Prefix .. 'SoakInterval')) * 1000
            self.DryDailyVol.push({'ms': tasmota.millis(), 'vol': DeltaMl})
        elif self.LastFloodVol > self.MaxFlood
            # Session volume cap (normal preset): accumulated water is enough,
            # close the session now instead of the removed 24h check delay. The
            # daily scheduler will start a fresh session anyway. Keep the soil
            # check timer off so a stale one cannot re-open the session.
            print("Autoflood: session volume over MaxFlood, ending session")
            tasmota.remove_timer(self._soil_timer_id())
            self._autoflood_end()
            return
        end
        tasmota.remove_timer(self._soil_timer_id())
        tasmota.set_timer(flood_delay, /-> self.timer_soil_transition_after_flooded(), self._soil_timer_id())
    end

    def _end_session_no_water()
        # The pump ran but no water passed (or the run was aborted before any
        # water flowed): close the session without scheduling a soil check.
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false
    end

    def _rearm_soil_check(intervalMs)
        # Re-schedule the post-flood soil check (dry soak hold/pause path).
        tasmota.remove_timer(self._soil_timer_id())
        tasmota.set_timer(intervalMs, /-> self.timer_soil_transition_after_flooded(), self._soil_timer_id())
    end

    def _drysoak_end()
        # The dry soak is done (soil recovered below StopRaw): close the session
        # without writing Prev*/estimate stats.
        print("Dry soak: session finished")
        self.AutofloodInProcess = false
        self.PauseSoilMaxStat = false
        self.DrySoakDose = nil
        self.DrySoakStartMillis = nil
        self.DryEmaHistory = list()
        self.DryDailyVol = list()
        self.Preset = nil
    end

    def _stats_enabled()
        # The dry soak deliberately does not track SoilMaxHymidity nor persist
        # the Prev*/estimate inputs: they belong to the classic normal flood.
        return self.Preset == nil || self.Preset.WriteStats
    end

    def _pick_preset()
        # Choose the flood strategy for a new session by how dry the soil EMA is.
        if self.SoilSensor.RawEma > self.DryThreshold
            self.Preset = FloodPreset('dry', self.Store, self.Prefix)
            self.DrySoakDose = self.Preset.StartDose
            self.DrySoakStartMillis = tasmota.millis()
            self.DryEmaHistory = list()
            self.DryDailyVol = list()
            print("Preset: dry soak (RawEma " .. self.SoilSensor.RawEma .. " > DryThreshold " .. self.DryThreshold .. ")")
        else
            self.Preset = FloodPreset('normal', self.Store, self.Prefix)
            self.DrySoakDose = nil
            print("Preset: normal flood")
        end
    end

    def rule_flooded(value, trigger)
        print("Flood limit by counter ".. value .. " by rule")
        tasmota.set_power(self.Num - 1, false)
    end

    def _escalate_evaluate()
        # Classic repeat-flood evaluation (normal preset / no-preset fallback):
        # soil still dry -> escalate Counter1FloodDefault and ask the dispatcher
        # to flood again, else the flooding session finished.
        if self.SoilSensor.Raw > (self.TargetDry + self.TargetWet)/2
            print("Autofloood: Wet lewel not reached. Repeat flooding")
            # TODO: increment Default
            self.Counter1FloodDefault = self.Counter1FloodDefault * 1.2
            if self.Counter1FloodDefault > self.MaxFlood
                self.Counter1FloodDefault = self.MaxFlood
                print("Counter1FloodDefault capped at MaxFlood " .. self.MaxFlood)
            end
            return 'repeat'
        else
            # Flooding session finished?
            print("Autofloood: Wet lewel reached. End flooding session")
            self._autoflood_end()
            return nil
        end
    end

    def timer_soil_transition_after_flooded()
        print("Timer: End soil transition after flooding")
        print("timer_soil_transition_after_flooded: self: ", self, "SS: ", self.SoilSensor)
        # TODO: Add fast water calibration here
        # Fast water calibration: flood more if necessary
        print({ "Raw": self.SoilSensor.Raw,
                "RawDry": self.TargetDry,
                "RawWet": self.TargetWet,
                "Dry50": (self.TargetDry + self.TargetWet)/2
              })
        var result = nil
        if self.Preset != nil
            result = self.Preset.evaluate(self)
        else
            result = self._escalate_evaluate()
        end
        if result == 'repeat'
            self.Owner.request_repeat(self)
        end
    end

    def _autoflood_end()
        print("Autofloood: finishing...")
        self.AutofloodInProcess = false
        if self.Counter1ResetPostpone
          self.Owner.FlowSensors[0].Reset()
          self.Counter1ResetPostpone = false
        end
        self.SoilMaxHymidity = nil
        self.SoilMaxHymidityTime = nil
        self.SoilMaxHymidityTemp = nil
        self.SoilMaxHymidityTimeTemp = nil
        self.PrevFloodedVol = self.LastFloodVol
        self.PauseSoilMaxStat = false
        self.Preset = nil
        print("Autofloood: finished")
    end

    def start_flood()
        # Planned flood dose + pump ON. Shared entry point for session start,
        # repeat flooding and the manual button. Only acts when the soil is
        # actually dry by EMA, so a wet reading cannot turn the pump on.
        if !(self.SoilSensor.RawEma > self.TargetWet)
            print("start_flood: soil not dry (RawEma<=TargetWet), skip")
            return
        end
        # No preset yet (manual button) -> choose one by current dryness.
        if self.Preset == nil
            self._pick_preset()
        end
        # Effective dose: preset (dry soak) or estimate/default (normal flood).
        self.PlannedFlood = self.Preset.dose(self)
        tasmota.set_power(self.Num - 1, true)
    end

    def start_session()
        # New flood session (cron sweep entry). Picks the preset first so the
        # dry soak can veto the Prev*/estimate archive, then archives the
        # previous session's stats into the P{Num} persist prefix, and finally
        # starts the fill via the shared entry point.
        print("Autoflood: start session on channel " .. str(self.Num))
        self._pick_preset()
        if self._stats_enabled()
            # Save previous session stats and the last finished session's estimate
            # inputs in one batch. Persisting the estimate inputs (PrevSoilHPreFlood /
            # PrevFloodedVol / PrevSoilMaxHymidity) keeps estimateflood() working after
            # a reboot; otherwise they come back nil -> estimate returns nil ->
            # fallback to default. Skipped for the dry soak preset: it must not
            # pollute the estimate stats.
            self.PrevSoilHPreFlood = self.SoilHPreFlood
            self.PrevFloodedVol = self.LastFloodVol
            self.PrevSoilMaxHymidity = self.SoilMaxHymidity
            self.Store.save_batch_entries(self._stats_batch())
        end
        # Init new flood session
        self.LastFloodVol = 0
        self.AutofloodInProcess = true
        self.SoilHPreFlood = self.SoilSensor.RawEma
        self.SoilMaxHymidity = nil
        self.SoilMaxHymidityTime = nil
        self.SoilMaxHymidityTemp = nil
        self.SoilMaxHymidityTimeTemp = nil
        self.start_flood()
    end

    def _stats_batch()
        # [persist_key, value] pairs for the session-start archive. Reads the
        # current (pre-reset) values so LastFloodVol persists before zeroing.
        return [
            [self.Prefix .. 'PrevSoilMaxHymidity', self.PrevSoilMaxHymidity],
            [self.Prefix .. 'PrevSoilHPreFlood', self.PrevSoilHPreFlood],
            [self.Prefix .. 'PrevFloodedVol', self.PrevFloodedVol],
            [self.Prefix .. 'SoilHPreFlood', self.SoilHPreFlood],
            [self.Prefix .. 'LastFloodVol', self.LastFloodVol],
        ]
    end

    def max_batch()
        # [persist_key, value] pairs for the confirmed soil-max snapshot.
        return [
            [self.Prefix .. 'SoilMaxHymidity', self.SoilMaxHymidity],
            [self.Prefix .. 'SoilMaxHymidityTime', self.SoilMaxHymidityTime],
        ]
    end

    def estimateflood()
        try
            # при маленькой дозе полива, может оказаться что влажность не уменьшилась
            # тогда используемая линейная экстраполяция даст отрицательное значение полива!
            # Оценка строится на последней завершённой сессии (Prev*), которая копируется
            # из текущих полей до начала новой сессии и персистится при старте auto_flood.
            var LastFloodDRaw = self.PrevSoilHPreFlood - self.PrevSoilMaxHymidity
            var CurDRaw = self.SoilSensor.RawEma - self.TargetWet
            var EstimatedFlood = real(self.PrevFloodedVol)*CurDRaw/LastFloodDRaw
            if EstimatedFlood < 15
                # estimate too small for a meaningful dose (~15 ml) -> nil (use
                # default), not 0 (would falsely mean "no flooding needed")
                log("EstimatedFlood: " .. EstimatedFlood)
                return nil
            else
                return int(EstimatedFlood)
            end
        except .. as exception
            log("estimateflood: unable to estimate. " .. exception , 1)
            return nil
        end
    end

    def planned_dose()
        # Effective planned dose for the upcoming flood: the linear estimate
        # when it is usable, otherwise fall back to the default flood volume.
        var est = self.estimateflood()
        return est != nil ? est : self.Counter1FloodDefault
    end
end




# Berry's module() does not auto-collect file-level names (gotcha #13).
fsm.FloodPreset = FloodPreset
fsm.Plant = Plant

return fsm
