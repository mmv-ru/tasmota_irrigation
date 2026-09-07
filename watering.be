import webserver
import strict
import persist

# Maximum number of irrigation channels (2..4). Each channel owns one pump
# relay (Power1..PowerN) and one soil sensor (A1..AN); all channels share the
# flow counter C1, so fills are strictly serialised (one at a time).
var MAX_CHANNELS = 4

def EMA(oldEMA, N, NewValue)
    import math
#    return (math.floor(oldEMA*(N - 1)*10.0) + NewValue*10.0) / (N*10)
#    return (math.floor(oldEMA*((N - 1.)*100./real(N))) + NewValue*100./N)/100 # Систематически занижает среднее на -2,5
#    return oldEMA*((N - 1.)/real(N)) + NewValue/real(N) # Систематически завышает среднее на +2 +4
#    return math.floor(oldEMA*((N - 1)/real(N))*100.0)/100.0 + NewValue/real(N) # Систематически завышает среднее на +2 +4
#    return math.floor(oldEMA*((N - 1)/real(N))*1024.0)/1024.0 + NewValue/real(N) # Систематически завышает среднее на +2 +4
#    return ((math.floor(oldEMA*8192)/8192)*((N - 1)/real(N))) + NewValue/real(N) # Всё равно завышает примерно на 2
    # https://www.investopedia.com/ask/answers/122314/what-exponential-moving-average-ema-formula-and-how-ema-calculated.asp
    var k = 2./(N + 1)
    return oldEMA*(1-k) + NewValue*k
end

# Web rendering helpers. The whole web UI is hand-built HTML emitted via
# tasmota.web_send_decimal(); these two cover the two <tr> templates used
# everywhere (sub-row and group header) so a label/style change lives in one
# place instead of ~30 inline <tr> literals. Output is byte-identical to the
# inline markup they replace.
def wrow(label, value)
    return "<tr class='sub'><th>" .. label .. "</th><td>" .. value .. "</td></tr>"
end

def wgrp(label)
    return "<tr class='grp'><td colspan='2'>" .. label .. "</td></tr>"
end

# onclick attribute with a single quote rule: HTML attr value in single quotes,
# JS inside may use double quotes freely (no Berry-level escape audit per site).
def wonclick(js)
    return "onclick='" .. js .. "'"
end

# Section-toggle onclick (header + chevron share the same _secToggle call).
def wtoggle(sec)
    return wonclick('_secToggle("' .. sec .. '");return false;')
end

# Header badge (raw/сухо/влажно pill in the section header row).
def wpill(label, value)
    return "<span class='pill'><b>" .. label .. "</b> " .. value .. "</span>"
end

class AbstractSensor
    var Name
    var SensorID
    var Raw
    var Scale
    var Offset
    var Status

    def init(Sensor)
        self.Status = 'init'

        self.Update(self.get_sensors())
    end

    static def get_sensors()
        import json
        return json.load(tasmota.read_sensors())
    end

    def Update(sensors)
        if sensors == nil
            return
        end
        var key0 = self.SensorID[0]
        if sensors.find(key0) == nil
            return
        end
        # A configured channel may have no reading yet on a real device
        # (and the test harness only provides A1/A2/C1/C2): a missing sub-key
        # must leave Raw untouched, not raise.
        if sensors[key0].find(self.SensorID[1]) == nil
            return
        end
        self.Raw = sensors[key0][self.SensorID[1]]
    end
end




class SoilSensor: AbstractSensor
    var RawEma
    var EMAN
    var RawDry
    var RawWet
    var ScaleMinRAW
    var ScaleMaxRAW
    var Raw2mVScale
    var Hu_C
    var Store
    var Prefix

    def init(Sensor, store, prefix)
        self.SensorID = ['ANALOG', Sensor]
        self.Name = 'Soil%sHymidity'
        self.setScale(842, 1105)
        self.EMAN = 600
        self.RawDry = 800
        self.RawWet = 750
        self.Store = store
        self.Prefix = prefix != nil ? prefix : ''
        # https://docs.espressif.com/projects/esp-idf/en/release-v4.4/esp32/api-reference/peripherals/adc.html
        # V = D * Vmax / Dmax
        # Tasmota has ADC_ATTEN_DB_11
        # Vmax 2450 mV, Dmax = 4095
        # In-R1-ADC-R2-Ground
        # external divider 30kOm - 30kOm
        var R1 = 30000.
        var R2 = 30000.
        var D = (R1+R2)/R2
        self.Raw2mVScale = D * 2450./4095
        # Hu(Raw) polynmial coef from calibration data
        self.Hu_C = [0.369266, 0.00150216, -1.60819e-06]
        super(self).init(Sensor)
    end

    def setScale(min, max)
        # Set linear scale by two points
        self.ScaleMinRAW = min
        self.ScaleMaxRAW = max
        var ScaleMinVal = 100.
        var ScaleMaxVal = 0.
        self.Scale = (ScaleMinVal-ScaleMaxVal)/(self.ScaleMinRAW-self.ScaleMaxRAW) # (out1-out2)/(in1-in2)
        self.Offset = ScaleMaxVal - self.ScaleMaxRAW*(ScaleMinVal-ScaleMaxVal)/(self.ScaleMinRAW-self.ScaleMaxRAW) # out2-In2*(out1-out2)/(in1-in2)
        print("Soil sensor scale set.")
    end

    def Update(sensors)
        super(self).Update(sensors)
        if self.Raw == nil
            return
        end
        if self.Raw < 2
            self.Status = 'N/C'
            #self.Raw = nil
        else
            #print("Old Sensor" .. self.SensorID[1] .. "RawEma: ", self.RawEma, "Raw", self.Raw)
            if self.RawEma == nil
                self.RawEma = self.Raw
            else
                self.RawEma = EMA(self.RawEma, self.EMAN, self.Raw)
            end
            #print("New Sensor" .. self.SensorID[1] .. "RawEma", self.RawEma)
        end
    end

    def Raw2Hymidity(rawSoil)
        # Dumb scale to Hymidity
        return real(rawSoil) * self.Scale + self.Offset
    end

    def Hymidity2Raw(SoilH)
        # Dumb scale to Hymidity
        return (SoilH - self.Offset) / self.Scale
    end

    def Raw2mV(raw)
        return raw * self.Raw2mVScale
    end

    def mV2Raw(mV)
        return mV / self.Raw2mVScale
    end

    def Raw2Hu(raw)
        return (self.Hu_C[0] + self.Hu_C[1]*raw + self.Hu_C[2]*raw*raw)*100
    end

    def SetDry(raw)
        var r = int(raw)
        if r == nil || r <= 0
            print("SoilSensor: SetDry rejected, bad raw " .. str(raw) .. " -> " .. str(r))
            return false
        end
        if r - self.RawWet <= 20
            print("SoilSensor: SetDry rejected, gap " .. r .. "-" .. self.RawWet .. " <= 20")
            return false
        end
        self.RawDry = r
        if self.Store != nil
            self.Store.set(self.Prefix .. 'TargetDry', self.RawDry)
        else
            import introspect
            introspect.set(persist, 'TargetDry', self.RawDry)
            persist.save()
        end
        return true
    end

    def SetWet(raw)
        var r = int(raw)
        if r == nil || r <= 0
            print("SoilSensor: SetWet rejected, bad raw " .. str(raw) .. " -> " .. str(r))
            return false
        end
        if self.RawDry - r <= 20
            print("SoilSensor: SetWet rejected, gap " .. self.RawDry .. "-" .. r .. " <= 20")
            return false
        end
        self.RawWet = r
        if self.Store != nil
            self.Store.set(self.Prefix .. 'TargetWet', self.RawWet)
        else
            import introspect
            introspect.set(persist, 'TargetWet', self.RawWet)
            persist.save()
        end
        return true
    end

    def member(name)
        if name == 'Hymidity'
            return self.Raw2Hymidity(self.RawEma)
        elif name == 'Dry'
            return self.Raw2Hymidity(self.RawDry)
        elif name == 'Wet'
            return self.Raw2Hymidity(self.RawWet)
        elif name == 'PRH'
            var Scale = 100.0/(self.RawDry-self.RawWet) # (out1-out2)/(in1-in2)
            var Offset = -self.RawWet*(100.0)/(self.RawDry-self.RawWet) # out2-In2*(out1-out2)/(in1-in2)
            return self.Raw*Scale + Offset
        elif name == 'mV'
            return self.Raw2mV(self.Raw)
        elif name == 'Hu'
            return self.Raw2Hu(self.RawEma)
        else
            import undefined
            return undefined
        end
    end

    def setmember(name, value)
        if name == 'Dry'
            self.RawDry = self.Hymidity2Raw(value)
            if self.Store != nil
                self.Store.set(self.Prefix .. 'TargetDry', self.RawDry)
            else
                import introspect
                introspect.set(persist, 'TargetDry', self.RawDry)
                persist.save()
            end
        elif name == 'Wet'
            self.RawWet = self.Hymidity2Raw(value)
            if self.Store != nil
                self.Store.set(self.Prefix .. 'TargetWet', self.RawWet)
            else
                import introspect
                introspect.set(persist, 'TargetWet', self.RawWet)
                persist.save()
            end
        else
            raise 'attribute_error', "the 'SoilSensor' object has no attribute '"..name.."'"
        end
    end

    def IsDry()
        return self.Raw != nil && self.Raw >= self.RawDry
    end

    def IsWet()
        return self.Raw != nil && self.Raw <= self.RawWet
    end

    def web_sensor(expanded, sec, plant)
        import string
        var msg
        var nm = "Канал " .. str(plant.Num)
        var arrow = expanded ? "▲" : "▼"
        # Per-channel status icon in the header: 💧 wait / ⏳ watering
        # session / 💦 pump running, shown left of the title. A JS tooltip
        # (#wdtt, opened by a click on the icon) shows a styled legend of all
        # three states, the current one marked "→".
        var st = "💧"
        var stc = "wait"
        if plant.WaterIsOn()
            st = "💦"
            stc = "run"
        elif plant.AutofloodInProcess
            st = "⏳"
            stc = "sess"
        end
        # Section header as raw HTML: la() only rewrites the {s}/{m}/{e} tokens,
        # any other markup passes through to #l1 unchanged (border-radius etc.
        # styled by the injected <style> block, see web_add_main_button()).
        msg = "<tr class='sec'><th class='hdr' " .. wtoggle(sec) .. ">"
        msg = msg .. "<span class='st " .. stc .. "' " .. wonclick('_wdShowTT(this,event)') .. ">" .. st .. "</span>" .. nm
        msg = msg .. "<span class='params'>"
        if self.RawEma != nil
            msg = msg .. wpill("raw", string.format("%01.2f", self.RawEma))
        end
        msg = msg .. wpill("сухо", str(self.RawDry)) .. wpill("влажно", str(self.RawWet)) .. "</span>" ..
                    "</th><td class='tgl'><a class='chev' href='#' " .. wtoggle(sec) .. ">" .. arrow .. "</a></td></tr>"
        # Expanded rows (Уставки/Датчик/settings button) live in
        # Watering.web_soil_detail — one method owns the whole channel detail.
        # Flooding/session state moved to the expanded detail too: the header
        # carries the status icon instead of a per-row text.

        tasmota.web_send_decimal(msg)

    end
end







class FlowSensor: AbstractSensor
    # Инкапсулировать в отдельный класс параметры калибровки
    # и хотябы базовую статистику
    var FlowSensorCalibration
    var LastMillis
    var LastRaw
    var _RateMeasuring
    var RawRate

    def init(Sensor)
        self.SensorID = ['COUNTER', Sensor]
        self.Name = 'FlowSensor%s'
        self.setScale(0.1449)  # ml/count
        super(self).init(Sensor)
    end

    def setScale(Scale)
        self.Scale = Scale
        self.Offset = 0
        print("Flow sensor scale set.")
    end

    def Raw2Flow(raw)
        return self.Scale*raw
    end

    def Update(sensors)
        super(self).Update(sensors)
        if self.Raw == nil
            return
        end
        self._WaterFlow(sensors)
        if self.Status == 'init'
            self.Status = 'unverified'
        end
    end

    def Reset()
      import string
      tasmota.cmd(string.format('Counter%s 0', self.SensorID[1][1]))
      self.Raw = 0
    end

    def _WaterFlow(sensors)
        var Res
        var RawDelta
        var CurMillis = tasmota.millis()
        if self._RateMeasuring
            if self.LastMillis != nil
                var MillisDelta = CurMillis - self.LastMillis
                RawDelta = self.Raw - self.LastRaw

                if MillisDelta > 0
                    Res = (RawDelta * 1000.0) / MillisDelta
                    self.RawRate = Res
                end

                # Step mills
                self.LastMillis = CurMillis
            else
                self.LastMillis = CurMillis
            end
            # Step LastRaw
            self.LastRaw = self.Raw
            # log("DBG: RateMeasuring " .. self.LastRaw .. " " .. RawDelta)
        else
            self.LastMillis = nil
        end
    end

    def member(name)
        if name == 'Rate'
            if self.RawRate
                return self.Raw2Flow(self.RawRate)
            else
                return nil
            end
        elif name == 'RateMeasuring'
            return self._RateMeasuring
        else
            import undefined
            return undefined
        end
    end

    def setmember(name, value)
        if name == 'RateMeasuring'
            if self._RateMeasuring != bool(value)
                self._RateMeasuring = bool(value)
                self.Update(self.get_sensors())
                log("DBG: RateMeasuring set " .. value)
            end
        else
            raise 'attribute_error', "the 'SoilSensor' object has no attribute '"..name.."'"
        end
    end

    def web_sensor(expanded, sec)
        import string
        var msg
        var nm = "Common"
        var arrow = expanded ? "▲" : "▼"
        msg = "<tr class='sec'><th class='hdr' " .. wtoggle(sec) .. ">" .. nm ..
              "</th><td class='tgl'><a class='chev' href='#' " .. wtoggle(sec) .. ">" .. arrow .. "</a></td></tr>"
        msg = msg .. string.format(
                  wrow("Water used", "%01.1f ml"),
                  self.Raw2Flow(self.Raw))
        if expanded
            msg = msg .. string.format(
                      wrow("Water flow", "%i pulse/s<br/><span class='stk'>%01.1f ml/min</span>"),
                      self.RawRate, self.Rate != nil ? self.Rate*60 : nil)
        end

        tasmota.web_send_decimal(msg)
    end
end

class PersistStore
    # Centralised persist layer. Every key is registered once (default value,
    # write policy, optional relative threshold). Cache holds the live value,
    # Shadow the last value actually written to Flash. Writes are deferred via
    # a dirty flag + 15s debounce timer unless the key's policy is immediate.
    # Multi-channel: per-channel keys are registered under a P{idx} prefix via
    # register_channel(), so one shared store serves all channels (memory-quark
    # budget verified for 4 channels, see BERRY_TASMOTA_CONTEXT.md gotcha #10).
    var Meta
    var Cache
    var Shadow
    var Touched
    var Dirty
    var DebounceMs
    var TimerId

    def init()
        self.Meta = {}
        self.Cache = {}
        self.Shadow = {}
        self.Touched = {}
        self.Dirty = false
        self.DebounceMs = 15000
        self.TimerId = "ID_PERSIST_SAVE"
    end

    def register(name, meta)
        self.Meta[name] = meta
        self.Cache[name] = meta.find('default', nil)
        self.Shadow[name] = meta.find('default', nil)
    end

    def register_channel(prefix)
        # Register the per-channel persistent keys (calibration, dry-soak params,
        # session/prev-stats) under a shared prefix like 'P1'. Defaults mirror the
        # iteration-1 flat registry; nothing is global anymore.
        var keys = {
            'TargetDry': '800', 'TargetWet': '760', 'DryThreshold': '820',
            'SoakStartDose': '100', 'SoakInterval': '7200',
            'SoakTrendWindow': '86400', 'SoakDoseGrow': '1.2',
            'SoakDailyCap': '1500', 'SoakMaxDose': '2000',
            'LastFloodVol': '0',
            'SoilHPreFlood': nil,
            'SoilMaxHymidity': nil, 'SoilMaxHymidityTime': nil,
            'PrevSoilMaxHymidity': nil, 'PrevSoilHPreFlood': nil,
            'PrevFloodedVol': nil,
        }
        for p: keys.keys()
            self.register(prefix .. p, {'default': keys[p], 'policy': 'debounced'})
        end
    end

    def get(name)
        return self.Cache.find(name, nil)
    end

    def set(name, value)
        # Update the live cache and the in-memory persist map immediately;
        # the physical save() to Flash is deferred per the key's policy.
        import introspect
        self.Cache[name] = value
        self.Touched[name] = true
        introspect.set(persist, name, value)
        var meta = self.Meta.find(name, {'policy': 'debounced', 'thr': nil})
        var policy = meta.find('policy', 'debounced')
        if policy == 'immediate'
            self.flush(true)
        elif policy == 'threshold'
            var thr = meta.find('thr', nil)
            if thr != nil && self._big_change(name, value, thr)
                self.flush(true)
            else
                self._mark_dirty()
            end
        else
            # debounced (default): mark dirty, the 15s timer does the save
            self._mark_dirty()
        end
    end

    def _mark_dirty()
        self.Dirty = true
        tasmota.remove_timer(self.TimerId)
        tasmota.set_timer(self.DebounceMs, /-> self.flush(), self.TimerId)
    end

    def _big_change(name, value, thr)
        # Relative change vs. the last flushed value, guarding div-by-zero.
        import math
        var old = real(self.Shadow.find(name, self.get(name)))
        var newv = real(value)
        var delta = math.abs(newv - old)
        var base = old
        if base == 0
            base = newv
        end
        if base == 0
            return false
        end
        return delta / base >= thr
    end

    def flush(force)
        # Write all registered keys in one save; Shadow tracks what is on Flash.
        # Keys whose live value is nil are left untouched in persist (they were
        # never written, and writing nil would clear a stored value on boot).
        if !self.Dirty && force != true
            return
        end
        import introspect
        for p: self.Touched.keys()
            var v = self.Cache.find(p, nil)
            if v != nil
                introspect.set(persist, p, v)
            end
            self.Shadow[p] = v
        end
        self.Touched = {}
        persist.save()
        self.Dirty = false
        tasmota.remove_timer(self.TimerId)
    end

    def save_batch_entries(entries)
        # Persist a list of [persist_key, value] pairs in one pass and save once.
        # Used for per-channel prefixed keys, where the persist key name differs
        # from the source member name (Plant stats/session snapshots).
        import introspect
        for e: entries
            var k = e[0]
            var v = e[1]
            self.Cache[k] = v
            self.Touched[k] = true
            introspect.set(persist, k, v)
        end
        self.flush(true)
    end

    def load()
        # Restore Cache/Shadow from persist, falling back to registered defaults.
        for p: self.Meta.keys()
            var d = self.Meta[p].find('default', nil)
            self.Cache[p] = persist.find(p, d)
            self.Shadow[p] = self.Cache[p]
        end
    end

    def dump()
        # name -> live value snapshot (for the Store command and the web table).
        var r = {}
        for p: self.Meta.keys()
            r[p] = self.Cache.find(p, nil)
        end
        return r
    end
end

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
            self.StartDose = int(store.get(self.Prefix .. 'SoakStartDose'))
            self.AdaptMode = 'trend'
            self.StopRaw = int(store.get(self.Prefix .. 'DryThreshold'))
            self.WindowSec = int(store.get(self.Prefix .. 'SoakTrendWindow'))
            self.DoseGrow = real(store.get(self.Prefix .. 'SoakDoseGrow'))
            self.DailyCap = int(store.get(self.Prefix .. 'SoakDailyCap'))
            self.MaxDose = int(store.get(self.Prefix .. 'SoakMaxDose'))
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
        # Sum ticks flooded in the last 24h from the DryDailyTicks ring.
        var capMs = 24*60*60*1000
        var sum = 0
        var i = 0
        while i < plant.DryDailyTicks.size()
            var t = plant.DryDailyTicks[i]
            if now - t['ms'] <= capMs
                sum += int(t['ticks'])
                i += 1
            else
                plant.DryDailyTicks.remove(i)
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
    var Counter1BeforeStart
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
    var DrySoakDose
    var DrySoakStartMillis
    var DryEmaHistory
    var DryDailyTicks

    def init(idx, owner)
        import introspect
        self.Owner = owner
        self.Idx = idx
        self.Num = idx + 1
        self.Prefix = 'P' + str(self.Num)
        self.Store = owner.Store
        self.SoilSensor = owner.SoilSensors[idx]
        self.SoilSensor.RawDry = int(self.Store.get(self.Prefix .. 'TargetDry'))
        self.SoilSensor.RawWet = int(self.Store.get(self.Prefix .. 'TargetWet'))
        self.DryThreshold = int(self.Store.get(self.Prefix .. 'DryThreshold'))
        for p: ['SoilHPreFlood',
                'SoilMaxHymidity', 'SoilMaxHymidityTime',
                'PrevSoilMaxHymidity',
                'PrevSoilHPreFlood', 'PrevFloodedVol']
            var v = self.Store.get(self.Prefix .. p)
            introspect.set(self, p, v)
        end
        self.LastFloodVol = int(self.Store.get(self.Prefix .. 'LastFloodVol'))
        self.MaxPumpRun = 60
        self.MaxFlood = 2000
        # When pipes without check valve, backflow - water
        # self.Counter1Backflow = 133
        self.Counter1Backflow = 0
        self.Counter1FloodDefault = 200
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false
        self.ServiceRun = false
        self.Counter1ResetPostpone = false
        self.Counter1BeforeStart = owner.FlowSensors[0].Raw
    end

    def _soil_timer_id()
        return "ID_SOILTRANSITION_AFTERFLOOD_P" .. str(self.Num)
    end

    def due()
        # Derived "wants a fill right now": soil dry by RAW, no session running.
        # Re-computed on every sweep; there is no persistent queue.
        return self.SoilSensor.IsDry() && !self.AutofloodInProcess
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
            self.Counter1BeforeStart = self.Owner.FlowSensors[0].Raw
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
        if self.SoilSensor.IsWet()
            print("Too wet to flood. Stop pump.")
            tasmota.set_power(self.Num - 1, false)
            return
        end
        tasmota.cmd("TelePeriod 10")
        self.PauseSoilMaxStat = true
        self.Counter1BeforeStart = self.Owner.FlowSensors[0].Raw
        print("Counter: ", self.Owner.FlowSensors[0].Raw)
        # A new flood while the previous "return to default teleperiod"
        # timer is still pending would let it kill this session's fast
        # telemetry mid-run. Cancel it here.
        tasmota.remove_timer("ID_ENDFASTTELE")
        if self.PlannedFlood
            self.FinishRule = "COUNTER#C1>="..(self.Owner.FlowSensors[0].Raw+self.Counter1Backflow+self.PlannedFlood)
        else
            self.FinishRule = "COUNTER#C1>="..(self.Owner.FlowSensors[0].Raw+self.Counter1Backflow+self.Counter1FloodDefault)
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
            var ticks = Counter1 - self.Counter1BeforeStart
            if ticks < 0
                ticks = 0
            end
            self.ServiceRun = false
            self.Owner.ServiceResult = {'num': self.Num, 'ticks': ticks, 'millis': self.PumpRunMillis}
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
        var CounterDelta = self._compensate_backflow(Counter1)
        print("Counter compensated: ", Counter1)
        print("Water flooded " .. CounterDelta)
        if CounterDelta > 0
            self._record_flood(CounterDelta)
        else
            self._end_session_no_water()
        end
        tasmota.remove_timer("ID_ENDFASTTELE")
        tasmota.set_timer(60*1000, /-> self.Owner.timer_endfasttele_after_flooded(), "ID_ENDFASTTELE")
    end

    def _compensate_backflow(Counter1)
        # Subtract backflow (water that returned through the pipe after pump
        # stop) from the counters and from the session delta. Returns the net
        # amount of water that actually left the pipe.
        import string
        var d = Counter1 - self.Counter1BeforeStart
        if d > self.Counter1Backflow
            tasmota.cmd(string.format("counter1 %i", Counter1 - self.Counter1Backflow))
            return d - self.Counter1Backflow
        else
            tasmota.cmd(string.format("counter1 %i", Counter1 - d))
            return 0
        end
    end

    def _record_flood(CounterDelta)
        # Record a finished flood dose and schedule the post-flood soil check.
        var flood_delay = 2*60*60*1000
        self.LastFloodTime = tasmota.rtc()['local']
        self.LastFloodVol += CounterDelta
        # Average flow (ml/min) of this channel's last fill: dose volume over
        # its own pump-on duration. In-memory (not persisted).
        if self.PumpRunMillis != nil && self.PumpRunMillis > 0
            self.LastFlowRate = (CounterDelta * 60000.0) / self.PumpRunMillis
        else
            self.LastFlowRate = nil
        end
        if self.Preset != nil && self.Preset.Type == 'dry'
            # Dry soak cadence: fixed interval + daily volume tracking.
            flood_delay = int(self.Store.get(self.Prefix .. 'SoakInterval')) * 1000
            self.DryDailyTicks.push({'ms': tasmota.millis(), 'ticks': CounterDelta})
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
        self.DryDailyTicks = list()
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
            self.DryDailyTicks = list()
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
        if self.SoilSensor.Raw > (self.SoilSensor.RawDry + self.SoilSensor.RawWet)/2
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
                "RawDry": self.SoilSensor.RawDry,
                "RawWet": self.SoilSensor.RawWet,
                "Dry50": (self.SoilSensor.RawDry + self.SoilSensor.RawWet)/2
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
        if !(self.SoilSensor.RawEma > self.SoilSensor.RawWet)
            print("start_flood: soil not dry (RawEma<=RawWet), skip")
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
            var CurDRaw = self.SoilSensor.RawEma - self.SoilSensor.RawWet
            var EstimatedFlood = real(self.PrevFloodedVol)*CurDRaw/LastFloodDRaw
            if EstimatedFlood < 100
                # estimate too small/negative for a meaningful dose -> nil (use default),
                # not 0 (would falsely mean "no flooding needed")
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



class Watering
    var SoilSensors
    var FlowSensors
    var Conf_Toggle
    var ServiceMode
    var ServiceResult
    var plants
    var PowerMap
    var _rr_idx
    var BootInitTries
    var TimeCacheKey
    var TimeCache
    var Store
    var NumChannels


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

    def _TimeStr(ts)
        # Cache formatted timestamp: web_sensor() runs every second on page
        # refresh, strftime() is expensive; the value changes rarely.
        if ts == self.TimeCacheKey
            return self.TimeCache
        end
        var s = ts != nil ? tasmota.strftime("%d %B %H:%M", ts) : nil
        self.TimeCacheKey = ts
        self.TimeCache = s
        return s
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
        self.Store = PersistStore()
        # Channel count is a Store variable (persistent, immediate policy) so
        # the number of channels can be configured without code changes. It is
        # registered before load() and clamped to [1, MAX_CHANNELS].
        self.Store.register('Channels', {'default': '4', 'policy': 'immediate'})
        # Global flow-sensor calibration (ml per counter tick). The C1 flow
        # meter is shared by every channel, so the scale is a global key, not a
        # per-channel P{Num} one. Calibrated from the service page.
        self.Store.register('FlowScale', {'default': '0.1449', 'policy': 'debounced'})
        for i: 0..(MAX_CHANNELS - 1)
            self.Store.register_channel('P' + str(i + 1))
        end
        self.Store.load()
        self.NumChannels = int(self.Store.get('Channels'))
        if self.NumChannels == nil || self.NumChannels < 1
            self.NumChannels = 1
        elif self.NumChannels > MAX_CHANNELS
            self.NumChannels = MAX_CHANNELS
        end
        self.init_sensors()
    end

    def init_sensors()
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
                print("WARNING: Watering driver NOT registered (sensors never came up)")
            end
            return
        end
        print("Sensors loaded from Json string")

        self.Conf_Toggle = 0

        print("Init sensors")
        self.SoilSensors = list()
        self.FlowSensors = list()
        for i: 0..(self.NumChannels - 1)
            self.SoilSensors.push(SoilSensor('A' + str(i + 1), self.Store, 'P' + str(i + 1)))
        end
        self.FlowSensors = [FlowSensor('C1'), FlowSensor('C2')]
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
            var p = Plant(i, self)
            self.plants.push(p)
            self.PowerMap['POWER' + str(i + 1)] = p
            var pnum = str(i + 1)
            var PulseTime = int(self.pulseencode(p.MaxPumpRun))
            tasmota.cmd('PulseTime' .. pnum .. ':{"Set":' .. str(PulseTime) .. ',"Remaining":0}')
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
                tasmota.resp_cmnd_str(str(self.SoilSensors[0].RawDry))
                return
            end
            try
                if self.SoilSensors[0].SetDry(int(payload))
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
                tasmota.resp_cmnd_str(str(self.SoilSensors[0].RawWet))
                return
            end
            try
                if self.SoilSensors[0].SetWet(int(payload))
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
                p0.Preset = FloodPreset('dry', self.Store, p0.Prefix)
                p0.DrySoakDose = p0.Preset.StartDose
                p0.DrySoakStartMillis = tasmota.millis()
                p0.DryEmaHistory = list()
                p0.DryDailyTicks = list()
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
            if n == nil || n < 1 || n > MAX_CHANNELS
                tasmota.resp_cmnd_error()
                return
            end
            self.Store.set('Channels', str(n))
            tasmota.resp_cmnd_str("Channels set to " .. str(n) .. ", restart required")
        end)
        print("Command Store initialized")
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
    end

    def every_second()
        #self.read_tds()
        import json
        import math
        var tmp = tasmota.read_sensors()
        var sensors = json.load(tmp)
        if sensors == nil
            return
        end
        for s: self.SoilSensors
            s.Update(sensors)
        end
        for s: self.FlowSensors
            s.Update(sensors)
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

    def web_add_main_button()
        webserver.content_send("<p></p><button onclick='location.href=\"svc\";'>Сервисный режим</button>")
        # Section design (variant B): band headers with badges and a status
        # Styled via an injected <style> block (la() only rewrites {s}/{m}/{e},
        # everything else lands in #l1 verbatim). CSS rules are kept as a list
        # of strings, one rule per element, joined once — avoids the old
        # ..-monolith where a color change meant editing 5 inline literals.
        # Palette lives in CSS variables (:root) so restyling is one line.
        var css = [
            "<style>",
            ":root{"..
              "--wd-acc:#1fa3ec;--wd-acc-h:#33b1f5;--wd-acc-a:#0f8fd6;"..
              "--wd-green:#8bc34a;--wd-pill-bg:#25303d;--wd-btn-tx:#0a0a0a;"..
              "--wd-bg-hdr:#3a3a3a;--wd-bg-hdr-h:#444;"..
              "--wd-tx:#eaeaea;--wd-tx-sub:#ccc;--wd-tx-grp:#8ca0b3;--wd-tx-pill:#7a8aa0;--wd-tx-tt:#b8c4cf;"..
              "--wd-bd:#3e3e3e;--wd-pop-bg:#1b2127;--wd-tt-bg:#232a33;--wd-in-bg:#12161b;}",
            # section bands (headers + chevrons)
            "#l1 table{border-collapse:separate;border-spacing:0;}",
            "#l1 tr.sec{display:table-row;width:100%;}",
            "#l1 tr.sec + tr td[colspan='2'] hr{display:none;}",
            "#l1 tr.sec + tr td[colspan='2']{height:2px;line-height:2px;}",
            "#l1 tr.sec th.hdr,#l1 tr.sec td.tgl{background:var(--wd-bg-hdr);transition:background .2s;cursor:pointer;}",
            "#l1 tr.sec th.hdr{display:flex;flex-wrap:wrap;align-items:center;gap:0 4px;vertical-align:middle;border-left:4px solid var(--wd-acc);border-radius:8px 0 0 8px;padding:8px 10px;font-weight:600;font-size:.95rem;color:var(--wd-tx);}",
            "#l1 tr.sec th.hdr .params{margin-left:auto;}",
            "#l1 tr.sec td.tgl{display:table-cell;vertical-align:middle;text-align:right;border-radius:0 8px 8px 0;padding:0 10px;white-space:nowrap;}",
            "#l1 tr.sec:hover th.hdr,#l1 tr.sec:hover td.tgl{background:var(--wd-bg-hdr-h);}",
            "#l1 tr.sec a.chev{color:var(--wd-acc);text-decoration:none;font-size:1.1rem;padding:4px 2px;display:inline-block;vertical-align:middle;}",
            "#l1 tr.sec .pill{vertical-align:middle;}",
            # sub rows / group headers / buttons
            "#l1 tr.sub th{padding:3px 10px 3px 26px;color:var(--wd-tx-sub);font-weight:400;font-size:.88rem;}",
            "#l1 tr.sub td{padding:3px 10px;text-align:right;color:#fff;font-weight:500;font-size:.88rem;}",
            "#l1 tr.grp td{padding:8px 10px 2px 26px;color:var(--wd-tx-grp);font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;border-top:1px solid var(--wd-bd);}",
            "#l1 a.wcbtn{display:inline-block;background:var(--wd-acc);color:var(--wd-btn-tx);padding:2px 12px;border-radius:10px;font-size:.8rem;font-weight:600;text-decoration:none;cursor:pointer;}",
            "#l1 a.wcbtn:hover{background:var(--wd-acc-h);}",
            "#l1 a.wcbtn:active{background:var(--wd-acc-a);}",
            "#l1 .stk{display:block;color:var(--wd-tx-grp);font-size:.75rem;font-weight:400;}",
            "#l1 .pill{display:inline-block;background:var(--wd-pill-bg);color:var(--wd-green);padding:1px 8px;border-radius:10px;font-size:.72rem;font-weight:600;margin-right:4px;}",
            "#l1 .pill b{color:var(--wd-green);font-weight:600;}",
            "#l1 .pill b:first-child{color:var(--wd-tx-pill);font-weight:400;}",
            # status icons (wait/sess/run) + pulse animations
            "#l1 .st{display:inline-block;font-size:1.4rem;line-height:1;vertical-align:middle;margin-right:6px;cursor:pointer;}",
            "#l1 .st.wait{filter:grayscale(1);opacity:.75;}",
            "#l1 .st.sess{animation:wdsess 1.6s ease-in-out infinite;}",
            "#l1 .st.run{animation:wdrun 1s ease-in-out infinite;}",
            "@keyframes wdsess{0%,100%{opacity:1}50%{opacity:.3}}",
            "@keyframes wdrun{0%,100%{opacity:1}50%{opacity:.3}}",
            # status tooltip (#wdtt)
            "#wdtt{position:fixed;z-index:9999;display:none;background:var(--wd-tt-bg);border:1px solid var(--wd-bd);border-radius:8px;padding:6px 10px;font-size:.8rem;line-height:1.6;white-space:nowrap;box-shadow:0 2px 8px rgba(0,0,0,.4);}",
            "#wdtt .ttrow{display:flex;align-items:center;gap:8px;min-width:160px;color:var(--wd-tx-tt);}",
            "#wdtt .ttrow.cur{color:var(--wd-green);}",
            "#wdtt .ttmark{display:inline-block;width:16px;text-align:center;}",
            "#wdtt .ttic{display:inline-block;width:20px;text-align:center;vertical-align:middle;}",
            "#wdtt .ttdrop{display:inline-block;font-size:.9rem;filter:grayscale(1);opacity:.8;vertical-align:-2px;}",
            # per-channel settings popup (#wdsv)
            "#wdsv{position:fixed;z-index:9998;display:none;inset:0;background:rgba(0,0,0,.55);align-items:center;justify-content:center;}",
            "#wdsv.open{display:flex;}",
            "#wdsv .box{background:var(--wd-pop-bg);border:1px solid var(--wd-bd);border-radius:12px;min-width:260px;box-shadow:0 6px 24px rgba(0,0,0,.5);}",
            "#wdsv .hd{display:flex;align-items:center;justify-content:space-between;padding:10px 14px;border-bottom:1px solid var(--wd-bd);color:var(--wd-tx);font-weight:600;}",
            "#wdsv .hd a{color:var(--wd-tx-grp);text-decoration:none;font-size:1.1rem;cursor:pointer;}",
            "#wdsv .bd{padding:10px 14px;display:flex;flex-direction:column;gap:8px;}",
            "#wdsv .bd label{display:flex;align-items:center;justify-content:space-between;gap:10px;color:var(--wd-tx-tt);font-size:.85rem;}",
            "#wdsv .bd input{width:7em;padding:3px 6px;background:var(--wd-in-bg);color:#fff;border:1px solid var(--wd-bd);border-radius:6px;text-align:right;}",
            "#wdsv .ft{display:flex;justify-content:flex-end;gap:8px;padding:10px 14px;border-top:1px solid var(--wd-bd);}",
            "#wdsv a.wcbtn{margin-left:0;}",
            "</style>",
        ]
        var style = ""
        for c: css style = style .. c end
        webserver.content_send(style)
        # Script inject, same list-of-strings approach as the CSS above. Keeps
        # the Berry-level `..` concatenation out of the JS source so a JS
        # string containing quotes needs no hand-audited escape matrix.
        var jsp = [
            # Per-tab per-section expand state lives in the browser URL as one
            # compact param me (1..9 = channels, c = Common; e.g. me=12c):
            # every poll from this tab carries its own me, URL is rewritten via
            # history.replaceState so a refresh keeps the tab's view. No
            # server-side global flag.
            "<script>try{",
            "if(typeof window._wdInit==='undefined'){",
              "window._wdInit=true;",
              "var _m=location.search.match(/[?&]me=([0-9c]*)/);_m=_m?_m[1]:'';",
              "window._wdSec={};",
        ]
        for i: 0..(self.NumChannels - 1)
            jsp.push("window._wdSec['soil" .. str(i + 1) .. "']=_m.indexOf('" .. str(i + 1) .. "')>=0;")
        end
        jsp.push("window._wdSec.flow=_m.indexOf('c')>=0;")
        jsp.push("window._wdEnc=function(){var s='';")
        for i: 0..(self.NumChannels - 1)
            jsp.push("if(window._wdSec['soil" .. str(i + 1) .. "'])s+='" .. str(i + 1) .. "';")
        end
        jsp.push("if(window._wdSec.flow)s+='c';return s;};")
        jsp.push("var _la0=window.la;")
        jsp.push("window.la=function(p){var np=p||'';")
        jsp.push("if(np.indexOf('me=')===-1){np+='&me='+window._wdEnc();}")
        jsp.push("_la0(np);};")
        jsp.push("window._secToggle=function(name){")
        jsp.push("window._wdSec[name]=!window._wdSec[name];")
        jsp.push("var u='?me='+window._wdEnc();")
        jsp.push("try{history.replaceState(null,'',u);}catch(e){}")
        jsp.push("la('');};")
        jsp.push("window._wdTT=null;")
        jsp.push("window._wdShowTT=function(ic,ev){if(ev&&ev.stopPropagation)ev.stopPropagation();var t=window._wdTT;")
        jsp.push("if(t&&t.style.display!=='none'){t.style.display='none';return;}")
        jsp.push("if(!t){t=document.createElement('div');t.id='wdtt';document.body.appendChild(t);window._wdTT=t;}")
        jsp.push("var cls=ic.className.indexOf('run')>=0?'run':ic.className.indexOf('sess')>=0?'sess':'wait';")
        jsp.push("var R=[['wait','Ожидание'],['sess','Сеанс полива'],['run','Работа насоса']];")
        jsp.push("var h='';for(var i=0;i<3;i++){var s=R[i][0];")
        jsp.push("var ic2=s=='wait'?'<span class=\"ttdrop\">💧</span>':(s=='sess'?'⏳':'💦');")
        jsp.push("h+='<div class=\"ttrow'+(s==cls?' cur':'')+'\"><span class=\"ttmark\">'+(s==cls?'→':'')+'</span><span class=\"ttic\">'+ic2+'</span><span>'+R[i][1]+'</span></div>';}")
        jsp.push("t.innerHTML=h;t.style.display='block';")
        jsp.push("var r=ic.getBoundingClientRect();var tw=t.offsetWidth;")
        jsp.push("var x=r.left-tw-8;if(x<4)x=r.right+8;var y=r.top+r.height/2-t.offsetHeight/2;if(y<4)y=r.top+8;")
        jsp.push("t.style.left=x+'px';t.style.top=y+'px';};")
        jsp.push("document.addEventListener('click',function(e){if(window._wdTT&&window._wdTT.style.display!=='none'){if(!e.target.closest('.st')&&!e.target.closest('#wdtt'))window._wdTT.style.display='none';}},true);")
        jsp.push("window._wdSett=null;")
        jsp.push("var _wdF=[['wds_dry','Soil Dry(Raw)','m_soildry_','dry'],['wds_wet','Soil Wet(Raw)','m_soilwet_','wet'],['wds_thr','Dry threshold(Raw)','m_drythr_','thr'],['wds_dose','Soak start dose','m_soakdose_','dose']];")
        jsp.push("window._wdSettingsOpen=function(a){")
        jsp.push("if(!window._wdSett){var d=document.createElement('div');d.id='wdsv';var h='<div class=\"box\"><div class=\"hd\"><span>Настройки полива</span><a href=\"#\" onclick=\"_wdSettingsClose();return false;\">✕</a></div><div class=\"bd\">';")
        jsp.push("for(var i=0;i<_wdF.length;i++){h+='<label>'+_wdF[i][1]+' <input id=\"'+_wdF[i][0]+'\" type=\"text\"></label>';}")
        jsp.push("h+='</div><div class=\"ft\"><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsSave();return false;\">Сохранить</a><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsClose();return false;\">Отмена</a></div></div>';d.innerHTML=h;document.body.appendChild(d);window._wdSett=d;}")
        jsp.push("window._wdSett._num=a.getAttribute('data-num');")
        jsp.push("for(var i=0;i<_wdF.length;i++){eb(_wdF[i][0]).value=a.getAttribute('data-'+_wdF[i][3]);}")
        jsp.push("window._wdSett.className+=' open';};")
        jsp.push("window._wdSettingsClose=function(){if(window._wdSett)window._wdSett.className=window._wdSett.className.replace(' open','');};")
        jsp.push("window._wdSettingsSave=function(){var n=window._wdSett._num,q='';")
        jsp.push("for(var i=0;i<_wdF.length;i++){q+='&'+_wdF[i][2]+n+'='+encodeURIComponent(eb(_wdF[i][0]).value);}")
        jsp.push("la(q);window._wdSettingsClose();};")
        jsp.push("}")
        jsp.push("}catch(e){}</script>")
        var js = ""
        for f: jsp js = js .. f end
        webserver.content_send(js)
        # Soil Dry/Wet, Dry threshold and Soak start dose forms moved into the
        # per-channel detail popup (see web_soil_detail + _wdSettingsOpen).
    end

    def web_add_handler()
        # Called by Tasmota once the web server is up: register the /svc route
        # bound to this instance (a closure captures self). The main-page button
        # in web_add_main_button() navigates here.
        import webserver
        webserver.on("/svc", / -> self.page_service(), webserver.HTTP_GET)
        print("Watering: /svc page registered")
    end

    def page_service()
        # Standalone service page (/svc). Mode entry/exit is explicit (buttons,
        # not mere page load): a tab opened and closed in the browser toggles
        # nothing. While the mode is active: per-channel pump ON/OFF, the last
        # service run (ticks/duration) and flow calibration (measured volume or
        # a manual ml-per-tick coefficient).
        import webserver
        if !webserver.check_privileged_access()
            return nil
        end
        # Act on args BEFORE rendering so the page reflects the result.
        # NB: the enable command is 'start' (NOT 'enter'): some browsers/networks
        # fail to load URLs whose query contains the literal substring 'enter=1'
        # (observed on this setup), so a bare ?input name='enter' value='1' form
        # would land on a browser error page instead of enabling the mode.
        if webserver.has_arg("start")
            self.service_enter()
        end
        if webserver.has_arg("exit")
            self.service_exit()
        end
        if self.ServiceMode
            if webserver.has_arg("pump")
                self._service_pump(webserver.arg("pump"))
            end
            if webserver.has_arg("cal")
                self._service_calibrate()
            end
            if webserver.has_arg("set")
                self._service_set_scale_arg()
            end
        end
        webserver.content_start("Сервисный режим")
        webserver.content_send_style()
        var state = self.ServiceMode ? "включен" : "выключен"
        webserver.content_send("<p>Сервисный режим: <b>" .. state .. "</b>.</p>")
        if self.ServiceMode
            self._service_page_on()
        else
            webserver.content_send("<form action='svc' style='display: block;' method='get'><input type='hidden' name='start' value='1'><button>Включить сервисный режим</button></form>")
        end
        webserver.content_button(webserver.BUTTON_MAIN)
        webserver.content_stop()
    end

    def service_set_scale(v)
        # Apply a new flow calibration (ml per counter tick) and persist it
        # globally (the C1 meter is shared by every channel). Guarded by callers.
        self.FlowSensors[0].setScale(v)
        self.Store.set('FlowScale', str(v))
        print("Service: flow scale set to " .. str(v))
    end

    def _service_pump(pump_arg)
        # Per-channel pump control from the service page: issue the relay
        # command so the POWER{Num}#State rule dispatches into the service
        # water_on/water_off branches (keyed on the active mode / ServiceRun).
        var n = int(pump_arg)
        if n == nil || n < 1 || n > self.NumChannels
            print("Service: bad pump arg '" .. str(pump_arg) .. "'")
            return
        end
        var p = self.plants[n - 1]
        if webserver.has_arg("on")
            # Shared C1: a service run must not start while another channel is
            # flooding (their water would leak into our tick delta).
            var busy = self._flooding_plant()
            if busy != nil && busy.Num != n
                print("Service: channel " .. str(busy.Num) .. " flooding, shared C1 busy")
                return
            end
            if !p.WaterIsOn()
                tasmota.set_power(n - 1, true)
            end
        elif webserver.has_arg("off")
            if p.WaterIsOn()
                tasmota.set_power(n - 1, false)
            end
        end
    end

    def _service_calibrate()
        # ?cal=1&vol=ml: derive the scale from the last service run - the user
        # measured the pumped volume, we know how many counter ticks it took.
        var sr = self.ServiceResult
        if sr == nil || sr['ticks'] == nil || sr['ticks'] <= 0
            print("Service: no usable run to calibrate (ticks=0/none)")
            return
        end
        var vol = webserver.has_arg("vol") ? real(webserver.arg("vol")) : nil
        if vol == nil || vol <= 0
            print("Service: bad calibration volume")
            return
        end
        var v = vol / real(sr['ticks'])
        if v <= 0
            return
        end
        self.service_set_scale(v)
    end

    def _service_set_scale_arg()
        # ?set=1&scale=coef: manual ml-per-tick coefficient.
        var sc = webserver.has_arg("scale") ? real(webserver.arg("scale")) : nil
        if sc == nil || sc <= 0
            print("Service: bad scale coefficient")
            return
        end
        self.service_set_scale(sc)
    end

    def _service_page_on()
        # Body of the /svc page while the mode is active. Channel controls only
        # surface here (never on the main page), so they cannot touch a normal
        # flood session.
        import string
        webserver.content_send("<fieldset><legend>Каналы</legend>")
        for i: 0..(self.NumChannels - 1)
            var p = self.plants[i]
            var st = p.WaterIsOn() ? "ON" : "OFF"
            webserver.content_send(
                "<p>Канал " .. str(i + 1) .. " <b>" .. st .. "</b>&nbsp; " ..
                "<form action='svc' style='display: inline-block;' method='get'><input type='hidden' name='pump' value='" .. str(i + 1) .. "'><input type='hidden' name='on' value='1'><button>ON</button></form> " ..
                "<form action='svc' style='display: inline-block;' method='get'><input type='hidden' name='pump' value='" .. str(i + 1) .. "'><input type='hidden' name='off' value='1'><button>OFF</button></form></p>")
        end
        webserver.content_send("</fieldset>")
        var sr = self.ServiceResult
        webserver.content_send("<fieldset><legend>Калибровка датчика потока</legend>")
        webserver.content_send("<p>Scale (мл/тик): <b>" .. string.format("%01.4f", self.FlowSensors[0].Scale) .. "</b></p>")
        if sr != nil
            var dur = sr['millis'] != nil ? string.format("%01.1f", sr['millis'] / 1000.0) : "0"
            var tpm = (sr['ticks'] != nil && sr['millis'] != nil && sr['millis'] > 0) ?
                      string.format("%01.1f", sr['ticks'] * 60000.0 / sr['millis']) : "0"
            var uml = (sr['ticks'] != nil) ? string.format("%01.1f", self.FlowSensors[0].Scale * sr['ticks']) : "0"
            webserver.content_send(
                "<p>Последний прогон: канал " .. str(sr['num']) ..
                ", " .. dur .. " с, " .. str(sr['ticks']) .. " тиков (" ..
                tpm .. " тиков/мин, " .. uml .. " мл при текущем scale).</p>")
        end
        webserver.content_send(
            "<p>Прокачайте воду (кнопки Канал ON/OFF) и укажите измеренный объём:</p>" ..
            "<form action='svc' style='display: block;' method='get'>" ..
            "<input type='hidden' name='cal' value='1'>" ..
            "<input name='vol' type='text' placeholder='объём, мл'> " ..
            "<button>Калибровать (мл/тик)</button></form>" ..
            "<form action='svc' style='display: block;' method='get'>" ..
            "<input type='hidden' name='set' value='1'>" ..
            "<input name='scale' type='text' placeholder='коэффициент, мл/тик'> " ..
            "<button>Установить коэффициент</button></form>")
        webserver.content_send("</fieldset>")
        webserver.content_send("<form action='svc' style='display: block;' method='get'><input type='hidden' name='exit' value='1'><button>Выйти</button></form>")
    end









    def web_soil_detail(pi)
        # Per-channel accordion detail, shared by every soil section: sensor
        # thresholds (Уставки) with the settings button, live sensor values
        # (Датчик), session/pump status, dry soak and the previous/current
        # session stats — everything under one expanded channel. One method
        # owns the whole detail (SoilSensor.web_sensor only emits the header).
        import string
        var plant = self.plants[pi]
        var num = plant.Num
        try
            var ss = plant.SoilSensor
            var msg = wgrp("Уставки")
            msg = msg .. string.format(
                wrow("Сухо", "%01.2f raw<br/><span class='stk'>%01.1f%% u</span>") ..
                wrow("Влажно", "%01.2f raw<br/><span class='stk'>%01.1f%% u</span>"),
                ss.RawDry, ss.Raw2Hu(ss.RawDry),
                ss.RawWet, ss.Raw2Hu(ss.RawWet)
                )
            # Per-channel settings button: opens the JS popup with this channel's
            # Soil Dry/Wet, Dry threshold and Soak start dose (current values in
            # data-* attrs). Lives in the Уставки group. The popup itself sits in
            # document.body (outside #l1) so it survives the 2.3s polling redraw;
            # see _wdSettingsOpen in web_add_main_button().
            msg = msg .. string.format(
                wrow("Настройки порогов",
                     "<a class='wcbtn' data-num='%i' data-dry='%i' data-wet='%i' data-thr='%i' data-dose='%s' " ..
                     wonclick('_wdSettingsOpen(this);return false;') .. ">⚙</a>"),
                num, ss.RawDry, ss.RawWet,
                plant.DryThreshold, str(ss.Store.get(ss.Prefix .. 'SoakStartDose')))
            msg = msg .. wgrp("Датчик")
            # Values may be nil until the first sensor Update (unconnected
            # channels). Guard each one: show "nil" instead of crashing the
            # whole section (which would drop the header and make the accordion
            # un-collapsible).
            var rawv = ss.Raw != nil ? str(ss.Raw) : "nil"
            var rawema = ss.RawEma != nil ? string.format("%01.4f", ss.RawEma) : "nil"
            var hu = ss.RawEma != nil ? string.format("%01.1f%%", ss.Raw2Hu(ss.RawEma)) : "nil"
            var mv = ss.Raw != nil ? string.format("%01.1f mV", ss.Raw2mV(ss.Raw)) : "nil"
            msg = msg .. string.format(
                wrow("Raw", "%s") .. wrow("Raw EMA(%i)", "%s"),
                rawv, ss.EMAN, rawema)
            msg = msg .. string.format(
                wrow("Hymidity u", "%s") .. wrow("mV", "%s"),
                hu, mv)
            tasmota.web_send_decimal(msg)
            var dry_status = "none"
            if plant.Preset != nil && plant.Preset.Type == 'dry'
                dry_status = "soak, dose " .. (plant.DrySoakDose != nil ? str(plant.DrySoakDose) : "?")
            end
            # Session: active (flooding in progress) / wait. Pump: run|idle;
            # the live flow rate (ml/min) is shown while the pump runs.
            var sess = plant.AutofloodInProcess ? "active" : "wait"
            var pump = plant.WaterIsOn() ? "run" : "idle"
            if plant.WaterIsOn()
                var rate = self.FlowSensors[0].Rate
                if rate != nil
                    pump = pump .. " " .. string.format("%01.1f", rate * 60) .. " ml/min"
                end
            end
            msg = string.format(
                      wgrp("Сеанс") .. wrow("Сеанс полива", "%s") .. wrow("Вода", "%s"),
                      sess, pump)
            tasmota.web_send_decimal(msg)
            msg = string.format(
                      wgrp("Размачивание") .. wrow("Dry soak", "%s") .. wrow("Dry threshold", "%i"),
                      dry_status, plant.DryThreshold)
            tasmota.web_send_decimal(msg)
            msg = wgrp("Текущий сеанс")
            if plant.SoilMaxHymidity != nil
                msg += string.format(
                        wrow("SoilHymidity" .. str(num) .. " max", "%i"),
                        plant.SoilMaxHymidity)
                if plant.SoilMaxHymidityTime != nil
                    msg += string.format(
                            wrow("SoilHymidity" .. str(num) .. " max time", "%s"),
                            self._TimeStr(plant.SoilMaxHymidityTime))
                end
            end
            msg += string.format(
                      wrow("LastFloodVol", "%i") .. wrow("SoilHPreFlood", "%s"),
                      plant.LastFloodVol, str(plant.SoilHPreFlood))
            tasmota.web_send_decimal(msg)
            msg = wgrp("Предыдущий сеанс")
            import introspect
            for k: ['PrevFloodedVol', 'PrevSoilHPreFlood', 'PrevSoilMaxHymidity']
                msg += string.format(
                          wrow("%s", "%s"),
                          k, str(introspect.get(plant, k)))
            end
            tasmota.web_send_decimal(msg)
            # Last fill per channel: date + average flow rate (in-memory).
            # Emitted only when a fill has been recorded (LastFloodTime set).
            if plant.LastFloodTime != nil
                msg = wgrp("Последний полив")
                msg += string.format(wrow("Last flood time", "%s"), self._TimeStr(plant.LastFloodTime))
                if plant.LastFlowRate != nil
                    msg += string.format(wrow("Last flow rate", "%01.1f мл/мин"), plant.LastFlowRate)
                end
                tasmota.web_send_decimal(msg)
            end
        except .. as e
            print("web_sensor: detail rows failed " .. e)
        end
    end

    def web_sensor()
    #- As we can add only one sensor method we will have to combine them besides all other sensor readings in one method -#
    #- each section is guarded: a crash in one must not truncate the rest -#
        import string
        var msg

        # Main-page status banner while the service mode is active.
        if self.ServiceMode
            try
                tasmota.web_send_decimal(wrow("Сервисный режим", "включен"))
            except .. as e
                print("web_sensor: service banner failed " .. e)
            end
        end

        try
            if webserver.has_arg("m_reset_water_counter_1")
              if self.plants[0].AutofloodInProcess
                self.plants[0].Counter1ResetPostpone = true
              else
                self.FlowSensors[0].Reset()
              end
            end
        except .. as e
            print("web_sensor: reset counter failed " .. e)
        end

        # Per-section expand state is per-request, carried in the browser URL
        # as a single compact param: me=12c (1=soil1, 2=soil2, ..., c=Common
        # flow, any order, empty/absent = all collapsed). No global flag
        # (sections and tabs are independent). One char per channel (1..9),
        # c = Common.
        var exp_soil = list()
        var exp_flow = false
        try
            var me = webserver.has_arg("me") ? webserver.arg("me") : ""
            for i: 0..(self.NumChannels - 1)
                exp_soil.push(string.find(me, str(i + 1)) >= 0)
            end
            exp_flow = string.find(me, "c") >= 0
        except .. as e
            print("web_sensor: expand args failed " .. e)
        end

        try
            # Per-channel settings (popup in each channel detail): args carry a
            # channel suffix m_soildry_N / m_soilwet_N / m_drythr_N / m_soakdose_N.
            # The bare args (m_soildry etc.) still mean channel 1 (legacy forms).
            # One field table shared conceptually with the JS popup (_wdF in
            # web_add_main_button): adding a field = one row here + one in _wdF.
            for i: 1..self.NumChannels
                var s = str(i)
                var ss = self.SoilSensors[i - 1]
                var pl = self.plants[i - 1]
                var sfx = i == 1 ? "" : "_" .. s
                # Dry/Wet are validated by the sensor (gap > 20). Dry threshold
                # and soak dose are plain int > 0 stored on the plant / Store.
                if webserver.has_arg("m_soildry" .. sfx)
                    if ss.SetDry(int(webserver.arg("m_soildry" .. sfx)))
                        print("web_sensor: channel " .. s .. " Soil Dry threshold set to " .. ss.RawDry)
                    else
                        print("web_sensor: channel " .. s .. " Soil Dry threshold rejected")
                    end
                end
                if webserver.has_arg("m_soilwet" .. sfx)
                    if ss.SetWet(int(webserver.arg("m_soilwet" .. sfx)))
                        print("web_sensor: channel " .. s .. " Soil Wet threshold set to " .. ss.RawWet)
                    else
                        print("web_sensor: channel " .. s .. " Soil Wet threshold rejected")
                    end
                end
                if webserver.has_arg("m_drythr" .. sfx)
                    var dt = int(webserver.arg("m_drythr" .. sfx))
                    if dt != nil && dt > 0
                        pl.DryThreshold = dt
                        self.Store.set('P' .. s .. 'DryThreshold', dt)
                        print("web_sensor: channel " .. s .. " Dry threshold set to " .. dt)
                    end
                end
                if webserver.has_arg("m_soakdose" .. sfx)
                    var sd = int(webserver.arg("m_soakdose" .. sfx))
                    if sd != nil && sd > 0
                        self.Store.set('P' .. s .. 'SoakStartDose', sd)
                        print("web_sensor: channel " .. s .. " Soak start dose set to " .. sd)
                    end
                end
            end
        except .. as e
            print("web_sensor: per-channel settings args failed " .. e)
        end

        # Per-channel accordions: one section per channel, header + per-channel
        # detail rows (dry soak/dry threshold/max/Store snapshot) under its own
        # expansion. Same logic for every channel (see web_soil_detail()).
        for i: 0..(self.NumChannels - 1)
            try
                self.SoilSensors[i].web_sensor(exp_soil[i], 'soil' + str(i + 1), self.plants[i])
            except .. as e
                print("web_sensor: soil" .. str(i + 1) .. " row failed " .. e)
            end
            if exp_soil[i]
                try
                    self.web_soil_detail(i)
                except .. as e
                    print("web_sensor: detail rows failed " .. e)
                end
            end
        end

        try
            self.FlowSensors[0].web_sensor(exp_flow, 'flow')
        except .. as e
            print("web_sensor: flow1 row failed " .. e)
        end

        # Common detail rows (expanded Common section only): the reset-water-
        # counter action (the main-page button was moved here). The service-mode
        # entry lives on its own /svc page via web_add_main_button().
        # Session/pump state is per-channel and lives in each soil section.
        if exp_flow
            try
                msg = string.format(
                          wgrp("Сброс") ..
                          wrow("Water counter",
                               "<a class='wcbtn' href='#' " .. wonclick('if(confirm("Сбросить счётчик воды?")){la("&m_reset_water_counter_1=1");}return false;') .. ">Reset</a>"))
                tasmota.web_send_decimal(msg)
            except .. as e
                print("web_sensor: reset counter row failed " .. e)
            end
        end

        #print("web_sensor: processed")

    end




    def json_append()
        #- add sensor value to teleperiod -#
        # NOTE: Keys of the "Watering" dict are part of the external integration
        # contract (InfluxDB / Grafana / OpenHAB via Ifx + teleperiod JSON).
        # Renaming/removing a key requires updating external consumers first.
        # Channel 1 is the telemetry channel (kept identical to iteration 1).
        import json
        import string
        var p0 = self.plants[0]
        var wtele = {
                'Soil1Raw': int(self.SoilSensors[0].Raw),
                'Soil1RawEma': int(self.SoilSensors[0].RawEma),
                'Soil1Hymidity': self.SoilSensors[0].Hymidity,
                'Soil2RawEma': int(self.SoilSensors[1].RawEma),
                'Soil2Hymidity': self.SoilSensors[1].Hymidity,
                'LastFloodSessionVol': p0.LastFloodVol,
                'LastSoilMaxHymidity':  p0.SoilMaxHymidity,
                'PrevSoilHPreFlood': p0.PrevSoilHPreFlood,
                'PrevFloodedVol': p0.PrevFloodedVol,
                'PrevSoilMaxHymidity': p0.PrevSoilMaxHymidity,
                'PumpRunMillis': p0.PumpRunMillis,
                'FlowSensorRate': self.FlowSensors[0].Rate,
                'SoilHPreFlood': p0.SoilHPreFlood,

                     }
        var json_tele = string.format(", \"Watering\": %s", json.dump(wtele))
        #print('json_append:', json_tele)
        tasmota.response_append(json_tele)
        #print("json_append: processed")
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
print("Watering driver initialized")
# tasmota.cmd("BrRestart");







