import webserver
import strict
import persist

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
        self.Raw = sensors[key0][self.SensorID[1]]
    end

    def web_sensor()
        import string
        var msg
        msg  = string.format(
            "{s}" .. self.Name .. "{e}",
            self.SensorID[1])
        tasmota.web_send_decimal(msg)
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

    def init(Sensor)
        self.SensorID = ['ANALOG', Sensor]
        self.Name = 'Soil%sHymidity'
        self.setScale(842, 1105)
        self.EMAN = 600
        self.RawDry = 800
        self.RawWet = 750
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
        import introspect
        introspect.set(persist, 'TargetDry', self.RawDry)
        persist.save()
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
        import introspect
        introspect.set(persist, 'TargetWet', self.RawWet)
        persist.save()
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
            import introspect
            introspect.set(persist, 'TargetDry', self.RawDry)
            persist.save()
        elif name == 'Wet'
            self.RawWet = self.Hymidity2Raw(value)
            import introspect
            introspect.set(persist, 'TargetWet', self.RawWet)
            persist.save()
        else
            raise 'attribute_error', "the 'SoilSensor' object has no attribute '"..name.."'"
        end
    end

    def IsDry()
        return self.Raw >= self.RawDry
    end

    def IsWet()
        return self.Raw <= self.RawWet
    end

    def web_sensor()
        import string
        var msg
        msg  = string.format(
            "{s}" .. self.Name .. "{e}"..
            "{s}| auto hreshold{m}%01.2f{e}"..
            "{s}| | Hu{m}%01.1f%%{e}"..
            "{s}| auto target{m}%01.2f{e}"..
            "{s}| | Hu{m}%01.1f%%{e}",
            self.SensorID[1],
            self.RawDry, self.Raw2Hu(self.RawDry),
            self.RawWet, self.Raw2Hu(self.RawWet)
            )
        msg = msg .. string.format(
            "{s}| Raw{m}%i{e}" ..
#            "{s}| Raw EMA(%i){m}%01.4f{e}",
            "{s}| Raw EMA(%i){m}%01.4f{e}",
            self.Raw, self.EMAN, self.RawEma)
        msg = msg .. string.format(
            "{s}| Hymidity u{m}%01.1f%%{e}"..
            "{s}| | mV{m}%01.1f mV{e}",
            self.Hu, self.mV)

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

    def web_sensor()
        import string
        var msg
        msg = string.format(
            "{s}" .. self.Name .. "{e}",
            self.SensorID[1])
        msg = msg .. string.format(
                  "{s}| Water used{m}%01.1f ml{e}",
                  self.Raw2Flow(self.Raw))
        msg = msg .. string.format(
                  "{s}| Water flow{m}%i pulse/s{e}"..
                  "{s}| Water flow{m}%01.1f ml/min{e}",
                  self.RawRate, self.Rate != nil ? self.Rate*60 : nil)

#        msg = msg .. string.format(
#                  "{s}| MillsDeltaEMA{m}%f{e}"..
#                  "{s}| MillsDeltaStdDevEMA{m}%f{e}",
#                  self.MillisDeltaEMA, self.MillisDeltaStdDevEMA)

        tasmota.web_send_decimal(msg)
    end
end








class Watering
    var SoilSensors
    var FlowSensors
    var FlowSensorCalibration
    var PauseSoilMaxStat
    var Conf_Toggle
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
    var SoilMaxHymidityConfirmed
    var LastFloodTime
    var LastFloodVol
    var Power1
    var SoilHPreFlood
    var SoilHPostFlood
    var PrevSoilMaxHymidity
    var PrevSoilHPreFlood
    var PrevFloodedVol
    var PrevSoilHPostFlood
    var AutofloodInProcess
    var BootInitTries
    var Counter1ResetPostpone


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
            tasmota.set_power(0, !bool(self.Power1))
        end
    end

    def rule_power(value, trigger)
        import string
        import json
        var sensors = json.load(tasmota.read_sensors())
        var Counter1 = 0
        if sensors != nil
            var counter = sensors.find('COUNTER')
            if counter != nil
                Counter1 = counter['C1']
            end
        end
        #print(string.format("value: %s trigger: %s", value, trigger))
        if value['State'] == 1
            self.PumpStartMillis = tasmota.millis()
            print("Water pump ON")
            self.Power1 = 1
            if self.SoilSensors[0].IsWet()
                print("Too wet to flood. Stop pump.")
                tasmota.cmd("Power1 0")
                return
            end
            tasmota.cmd("TelePeriod 10")
            self.PauseSoilMaxStat = true
            self.Counter1BeforeStart = self.FlowSensors[0].Raw
            print("Counter: ", self.FlowSensors[0].Raw)
            # A new flood while the previous "return to default teleperiod"
            # timer is still pending would let it kill this session's fast
            # telemetry mid-run. Cancel it here.
            tasmota.remove_timer("ID_ENDFASTTELE")
            if self.PlannedFlood
                self.FinishRule = "COUNTER#C1>="..(self.FlowSensors[0].Raw+self.Counter1Backflow+self.PlannedFlood)
            else
                self.FinishRule = "COUNTER#C1>="..(self.FlowSensors[0].Raw+self.Counter1Backflow+self.Counter1FloodDefault)
            end
            print("Flooding FinishRule ", self.FinishRule)
            tasmota.add_rule(self.FinishRule, / v, t -> self.rule_flooded(v, t))
            print("Rule on ", self.FinishRule, " set")
            # TODO: delay RateMeasuring when no check-valve
            self.FlowSensors[0].RateMeasuring = true
        elif value['State'] == 0
            try
                self.PumpRunMillis = tasmota.millis() - self.PumpStartMillis
            except .. as e
                log("Pump stop without run.", 1)
            end
            print("Water pump OFF")
            self.Power1 = 0
            if self.FinishRule
                tasmota.remove_rule(self.FinishRule)
                self.FinishRule = nil
                print("Flooding FinishRule removed")
            end
            var CounterDelta = Counter1 - self.Counter1BeforeStart
            print("Counter: ", Counter1)
            print("CounterDelta: ", CounterDelta)
            print("PumpRun: " .. (self.PumpRunMillis/1000.))
            self.FlowSensors[0].RateMeasuring = false
            if CounterDelta > self.Counter1Backflow
                tasmota.cmd(string.format("counter1 %i", Counter1 - self.Counter1Backflow))
                CounterDelta = CounterDelta - self.Counter1Backflow
            else
                tasmota.cmd(string.format("counter1 %i", Counter1 - CounterDelta))
                CounterDelta = 0
            end
            print("Counter compensated: ", Counter1)
            print("Water flooded ".. CounterDelta)
            if CounterDelta > 0
                var flood_delay = 2*60*60*1000
                self.LastFloodTime = tasmota.rtc()['local']
                self.LastFloodVol += CounterDelta
                if (self.LastFloodVol > self.MaxFlood/2)
                   flood_delay = 24*60*60*1000
                end
                tasmota.remove_timer("ID_SOILTRANSITION_AFTERFLOOD")
                tasmota.set_timer(flood_delay, /->self.timer_soil_transition_after_flooded(), "ID_SOILTRANSITION_AFTERFLOOD")
            else
                self.PauseSoilMaxStat = false
                self.AutofloodInProcess = false
            end
            tasmota.remove_timer("ID_ENDFASTTELE")
            tasmota.set_timer(60*1000, /->self.timer_endfasttele_after_flooded(), "ID_ENDFASTTELE")
        else
            print("WARNING: Unexpected watering pump state ", value['State'])
        end
    end

    def rule_flooded(value, trigger)
        print("Flood limit by counter ".. value .. " by rule")
        tasmota.cmd("Power1 0")
    end

    def timer_endfasttele_after_flooded()
        print("Timer: end fast teleperiod after flooded")
        tasmota.cmd("TelePeriod 300") # Default Tasmota teleperiod (not the flood's fast 10s)
    end

    def timer_soil_transition_after_flooded()
        print("Timer: End soil transition after flooding")
        print("timer_soil_transition_after_flooded: self: ", self, "SS: ", self.SoilSensors[0])
        self.SoilHPostFlood = self.SoilSensors[0].Hymidity
        # TODO: Add fast water calibration here
        # Fast water calibration: flood more if necessary
        print({ "Raw": self.SoilSensors[0].Raw,
                "RawDry": self.SoilSensors[0].RawDry,
                "RawWet": self.SoilSensors[0].RawWet,
                "Dry50": (self.SoilSensors[0].RawDry + self.SoilSensors[0].RawWet)/2
              })
        if self.SoilSensors[0].Raw > (self.SoilSensors[0].RawDry + self.SoilSensors[0].RawWet)/2
            print("Autofloood: Wet lewel not reached. Repeat flooding")
            # TODO: increment Default
            self.Counter1FloodDefault = self.Counter1FloodDefault * 1.2
            if self.Counter1FloodDefault > self.MaxFlood
                self.Counter1FloodDefault = self.MaxFlood
                print("Counter1FloodDefault capped at MaxFlood " .. self.MaxFlood)
            end
            tasmota.cmd("Power1 1")
        else
            # Flooding session finished?
            print("Autofloood: Wet lewel reached. End flooding session")
            self._autoflood_end()
        end
    end

    def _autoflood_end()
        print("Autofloood: finishing...")
        self.AutofloodInProcess = false
        if self.Counter1ResetPostpone
          self.FlowSensors[0].Reset()
          self.Counter1ResetPostpone = false
        end
        self.SoilMaxHymidity = nil
        self.SoilMaxHymidityTime = nil
        self.PrevFloodedVol = self.LastFloodVol
        self.PauseSoilMaxStat = false
        print("Autofloood: finished")
    end

    def auto_flood()
        print("Autoflood: AutofloodInProcess ", self.AutofloodInProcess)
        #print("Autoflood: Closure test Sensor ", self.SoilSensors[0])
        #print("Autoflood: Closure test A1 ", self.SoilSensors[0].Raw)
        #print("Autoflood: Closure test A1EMA ", self.SoilSensors[0].RawEma)
        if self.SoilSensors[0].IsDry() && !self.AutofloodInProcess
            print("Autoflood: scheduled start")
            # Save previous session stats
            self.PrevSoilHPreFlood = self.SoilHPreFlood
            self.PrevSoilHPostFlood = self.SoilHPostFlood
            self.PrevFloodedVol = self.LastFloodVol
            self.PrevSoilMaxHymidity = self.SoilMaxHymidity
            import introspect
            for p: ['PrevSoilMaxHymidity',
                   'PrevSoilHPreFlood', 'PrevFloodedVol', 'PrevSoilHPostFlood']
                introspect.set(persist, p, introspect.get(self, p, nil))
            end
            persist.save()

            if self.estimateflood()
               self.PlannedFlood = self.estimateflood()
            else
               self.PlannedFlood = self.Counter1FloodDefault
            end

            # Init new flood session
            self.LastFloodVol = 0
            self.AutofloodInProcess = true
            self.SoilHPreFlood = self.SoilSensors[0].RawEma
            self.SoilMaxHymidityConfirmed = false
            self.SoilMaxHymidity = nil
            self.SoilMaxHymidityTime = nil
            tasmota.cmd("Power1 1")
        end
    end

    def estimateflood()
        try
            # при маленькой дозе полива, может оказаться что влажность не уменьшилась
            # тогда используемая линейная экстраполяция даст отрицательное значение полива!
            var LastFloodDRaw = self.SoilHPreFlood - self.SoilMaxHymidity
            var CurDRaw = self.SoilSensors[0].RawEma - self.SoilSensors[0].RawWet
            var EstimatedFlood = real(self.LastFloodVol)*CurDRaw/LastFloodDRaw
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

        self.FlowSensorCalibration = false
        self.Conf_Toggle = 0

        print("Init sensors")
        self.SoilSensors = [SoilSensor('A1'), SoilSensor('A2')]
        self.SoilSensors[0].RawDry = int(persist.find("TargetDry", "800"))
        self.SoilSensors[0].RawWet = int(persist.find("TargetWet", "760"))
        self.LastFloodVol = int(persist.find("LastFloodVol", "0"))
        self.FlowSensors = [FlowSensor('C1'), FlowSensor('C2')]
        print("Sensors initialized")

        for p: ['SoilHPreFlood', 'SoilHPostFlood',
                'SoilMaxHymidity', 'SoilMaxHymidityTime',
                'PrevSoilMaxHymidity',
                'PrevSoilHPreFlood', 'PrevFloodedVol', 'PrevSoilHPostFlood']
            print('Persist restore - ', p, ': ', persist.find(p, nil))
            introspect.set(self, p, persist.find(p, nil))
        end

        self.MaxPumpRun = 60
        var PulseTime
        PulseTime = int(self.pulseencode(self.MaxPumpRun))
        tasmota.cmd('PulseTime1":{"Set":'.. PulseTime ..',"Remaining":0}')

        self.MaxFlood = 2000

        # When pipes without check valve, backflow - water
        # self.Counter1Backflow = 133
        self.Counter1Backflow = 0
        self.Counter1FloodDefault = 300

        self.Power1 = 0
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false
        self.Counter1ResetPostpone = false
        self.Counter1BeforeStart = self.FlowSensors[0].Raw

        tasmota.add_driver(self)
        tasmota.cmd('PowerOnState 0') # relay off after PowerOn
        tasmota.cmd('SetOption73 1') # Detach buttons from relays
        tasmota.add_rule("POWER1", / v, t -> self.rule_power(v, t))
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
    end

    def deinit()
        persist.save()
        tasmota.remove_rule("POWER1")
        tasmota.remove_rule("BUTTON1")
        tasmota.remove_cron("auto_flood")
        tasmota.remove_timer("ID_SOILTRANSITION_AFTERFLOOD")
        tasmota.remove_timer("ID_ENDFASTTELE")
        tasmota.remove_timer("ID_DELAY_INIT")
        tasmota.remove_cmd("autoflood")
        tasmota.remove_cmd("SoilDry")
        tasmota.remove_cmd("SoilWet")
        tasmota.cmd("Power1 0")
        if self.FinishRule
            tasmota.remove_rule(self.FinishRule)
            self.FinishRule = nil
            print("Flood FinishRule removed")
        end
        tasmota.remove_driver(self)
        for i: 0..1
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
        #print("every_second: trace")
        if ! self.PauseSoilMaxStat
            if self.SoilMaxHymidity == nil || self.SoilMaxHymidity > self.SoilSensors[0].RawEma
                self.SoilMaxHymidity = self.SoilSensors[0].RawEma
                self.SoilMaxHymidityConfirmed = false
                self.SoilMaxHymidityTime = tasmota.rtc()['local']
            end
        end
        if self.SoilMaxHymidity &&  !self.SoilMaxHymidityConfirmed && self.SoilSensors[0].RawEma > self.SoilMaxHymidity + 5
            print("SoilMaxHymidityConfirmed")
            self.SoilMaxHymidityConfirmed = true
            import introspect
            introspect.set(persist, 'SoilMaxHymidity', self.SoilMaxHymidity)
            introspect.set(persist, 'SoilMaxHymidityTime', self.SoilMaxHymidityTime)
            persist.save()
        end

        #print("every_second: processed")
    end

    def web_add_main_button()
        webserver.content_send("<p></p><button onclick='la(\"&m_toggle_flowcalibration=1\");'>Flow Sensor Calibration</button>")
        webserver.content_send("<p></p><button onclick='la(\"&m_reset_water_counter_1=1\");'>Reset water counter 1</button>")
        webserver.content_send(
            "<p></p><div style='display:flex;flex-wrap:wrap;gap:4px;align-items:center'>"
            .. "Soil Dry(Raw) <input type='text' id='soil_dry' name='m_soildry' style='width:5em;padding:2px' value='" .. str(self.SoilSensors[0].RawDry) .. "'> "
            .. "Soil Wet(Raw) <input type='text' id='soil_wet' name='m_soilwet' style='width:5em;padding:2px' value='" .. str(self.SoilSensors[0].RawWet) .. "'> "
            .. "<button style='width:auto;padding:2px 8px' onclick='la(\"&m_soildry=\"+eb(\"soil_dry\").value+\"&m_soilwet=\"+eb(\"soil_wet\").value);'>Set soil thresholds</button></div>")
#        webserver.content_send("<p></p><button onclick='la(\"&m_reset_water_counter_2=1\");'>Reset water counter 1</button>")
    end


    def web_add_config_button()
    #- the onclick function "la" takes the function name and the respective value you want to send as an argument -#
    # this not work. It wrong way. https://github.com/arendst/Tasmota/discussions/18753
        webserver.content_send("<p></p><button onclick='la(\"&m_toggle_conf=1\");'>Toggle Conf</button>")
    end






    def web_sensor()
    #- As we can add only one sensor method we will have to combine them besides all other sensor readings in one method -#
    #- each section is guarded: a crash in one must not truncate the rest -#
        var msg

        try
            if webserver.has_arg("m_toggle_flowcalibration")
              self.FlowSensorCalibration = ! self.FlowSensorCalibration
              print("FlowSensor Calibration mode" .. self.FlowSensorCalibration)
            end
        except .. as e
            print("web_sensor: flowcal toggle failed " .. e)
        end

        try
            if webserver.has_arg("m_reset_water_counter_1")
              if self.AutofloodInProcess
                self.Counter1ResetPostpone = true
              else
                self.FlowSensors[0].Reset()
              end
            end
        except .. as e
            print("web_sensor: reset counter failed " .. e)
        end

        try
            if webserver.has_arg("m_toggle_conf") # takes a string as argument name and returns a boolean
                # we can even call another function and use the value as a parameter
                # takes a string or integer(index of arguments) to get the value of the argument
                print("Conf button pressed")
                #self.Conf_Toggle = int(webserver.arg("m_toggle_conf"))
            end
        except .. as e
            print("web_sensor: conf toggle failed " .. e)
        end

        try
            if webserver.has_arg("m_soildry")
                if self.SoilSensors[0].SetDry(int(webserver.arg("m_soildry")))
                    print("web_sensor: Soil Dry threshold set to " .. self.SoilSensors[0].RawDry)
                else
                    print("web_sensor: Soil Dry threshold rejected")
                end
            end
            if webserver.has_arg("m_soilwet")
                if self.SoilSensors[0].SetWet(int(webserver.arg("m_soilwet")))
                    print("web_sensor: Soil Wet threshold set to " .. self.SoilSensors[0].RawWet)
                else
                    print("web_sensor: Soil Wet threshold rejected")
                end
            end
        except .. as e
            print("web_sensor: soil threshold failed " .. e)
        end

        import string
        try
            msg = string.format(
                      "{s}FlowSensor Calibration mode{m}%s{e}",
                      self.FlowSensorCalibration)
            tasmota.web_send_decimal(msg)
        except .. as e
            print("web_sensor: calibration row failed " .. e)
        end

        try
            msg = string.format(
                      "{s}Flooding in process{m}%s{e}",
                      self.AutofloodInProcess)
            tasmota.web_send_decimal(msg)
        except .. as e
            print("web_sensor: flooding row failed " .. e)
        end

        try
            self.SoilSensors[0].web_sensor()
        except .. as e
            print("web_sensor: soil1 row failed " .. e)
        end

        try
            self.SoilSensors[1].web_sensor()
        except .. as e
            print("web_sensor: soil2 row failed " .. e)
        end

        if self.SoilMaxHymidity != nil
            try
                msg = string.format(
                        "{s}SoilHymidity1 max{m}%i{e}",
                        self.SoilMaxHymidity)
                if self.SoilMaxHymidityConfirmed
                    msg += string.format(
                            "{s}SoilHymidity1 max time{m}%s{e}",
                            tasmota.strftime("%d %B %H:%M", self.SoilMaxHymidityTime))
                end
                tasmota.web_send_decimal(msg)
            except .. as e
                print("web_sensor: max humidity row failed " .. e)
            end
        end

        if self.LastFloodTime != nil
            try
                msg = string.format(
                          "{s}Last flood time{m}%s{e}"..
                          "{s}Last flood{m}%01.1f ml{e}",
                          tasmota.strftime("%d %B %H:%M", self.LastFloodTime),
                          self.FlowSensors[0].Raw2Flow(self.LastFloodVol))
                tasmota.web_send_decimal(msg)
            except .. as e
                print("web_sensor: last flood row failed " .. e)
            end
        end

        try
            self.FlowSensors[0].web_sensor()
        except .. as e
            print("web_sensor: flow1 row failed " .. e)
        end

        #print("web_sensor: processed")

    end




    def json_append()
        #- add sensor value to teleperiod -#
        # NOTE: Keys of the "Watering" dict are part of the external integration
        # contract (InfluxDB / Grafana / OpenHAB via Ifx + teleperiod JSON).
        # Renaming/removing a key requires updating external consumers first.
        import json
        import string
        var wtele = {
                'Soil1Raw': int(self.SoilSensors[0].Raw),
                'Soil1RawEma': int(self.SoilSensors[0].RawEma),
                'Soil1Hymidity': self.SoilSensors[0].Hymidity,
                'Soil2RawEma': int(self.SoilSensors[1].RawEma),
                'Soil2Hymidity': self.SoilSensors[1].Hymidity,
                'LastFloodSessionVol': self.LastFloodVol,
                'LastSoilMaxHymidity':  self.SoilMaxHymidityConfirmed ? self.SoilMaxHymidity : nil,
                'PrevSoilHPreFlood': self.PrevSoilHPreFlood,
                'PrevFloodedVol': self.PrevFloodedVol,
                'PrevSoilHPostFlood': self.PrevSoilHPostFlood,
                'PrevSoilMaxHymidity': self.PrevSoilMaxHymidity,
                'PumpRunMillis': self.PumpRunMillis,
                'FlowSensorRate': self.FlowSensors[0].Rate,
                'SoilHPreFlood': self.SoilHPreFlood,

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
