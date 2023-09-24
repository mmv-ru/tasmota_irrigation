import webserver
import strict

var TIMERID_ENDFASTTELE = 1
var TIMERID_SOILTRANSITION_AFTERFLOOD = 2

def EMA(oldEMA, N, NewValue)
    import math
#    return (math.floor(oldEMA*(N - 1)*10.0) + NewValue*10.0) / (N*10)
#    return (math.floor(oldEMA*((N - 1.)*100./real(N))) + NewValue*100./N)/100 # Систематически занижает среднее на -2,5
#    return oldEMA*((N - 1.)/real(N)) + NewValue/real(N) # Систематически завышает среднее на +2 +4
#    return math.floor(oldEMA*((N - 1)/real(N))*100.0)/100.0 + NewValue/real(N) # Систематически завышает среднее на +2 +4
#    return math.floor(oldEMA*((N - 1)/real(N))*1024.0)/1024.0 + NewValue/real(N) # Систематически завышает среднее на +2 +4
    return ((math.floor(oldEMA*8192)/8192)*((N - 1)/real(N))) + NewValue/real(N) #
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
        self.Raw = sensors[self.SensorID[0]][self.SensorID[1]]
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

    def init(Sensor)
        self.SensorID = ['ANALOG', Sensor]
        self.Name = 'Soil%sHymidity'
        self.setScale(577, 1105)
        self.EMAN = 600
        self.RawDry = 800
        self.RawWet = 750
        # https://docs.espressif.com/projects/esp-idf/en/release-v4.4/esp32/api-reference/peripherals/adc.html
        # V = D * Vmax / Dmax
        # Tasmota has ADC_ATTEN_DB_11
        # Vmax 2450 mV, Dmax = 4095
        # external divider 30kOm - 30kOm
        self.Raw2mVScale = 2 * 2450./4095
        super(self).init(Sensor)
    end

    def setScale(min, max)
        self.ScaleMinRAW = min
        self.ScaleMaxRAW = max
        self.Scale = 100.0/(self.ScaleMinRAW-self.ScaleMaxRAW) # (out1-out2)/(in1-in2)
        self.Offset = -self.ScaleMaxRAW*(100.0)/(self.ScaleMinRAW-self.ScaleMaxRAW) # out2-In2*(out1-out2)/(in1-in2)
        print("Soil sensor scale set.")
    end

    def Update(sensors)
        super(self).Update(sensors)

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

    def member(name)
        if name == 'Hymidity'
            return self.Raw2Hymidity(self.Raw)
        elif name == 'Dry'
            return self.Raw2Hymidity(self.RawDry)
        elif name == 'Wet'
            return self.Raw2Hymidity(self.RawWet)
        elif name == 'PRH'
            var Scale = 100.0/(self.RawDry-self.RawWet) # (out1-out2)/(in1-in2)
            var Offset = -self.RawWet*(100.0)/(self.RawDry-self.RawWet) # out2-In2*(out1-out2)/(in1-in2)
            return self.Raw*Scale + Offset
        else
            import undefined
            return undefined
        end
    end

    def setmember(name, value)
        if name == 'Dry'
            self.RawDry = self.Hymidity2Raw(value)
        elif name == 'Wet'
            self.RawWet = self.Hymidity2Raw(value)
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
            "{s}| auto target{m}%01.2f{e}",
            self.SensorID[1], self.RawDry, self.RawWet)
        msg = msg .. string.format(
            "{s}| Raw{m}%i{e}",
            self.Raw)
        msg = msg .. string.format(
            "{s}| Raw EMA(%i){m}%01.4f{e}",
            self.EMAN, self.RawEma)
        msg = msg .. string.format(
            "{s}| Hymidity{m}%01.1f{e}",
            self.Hymidity)

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
        self._WaterFlow(sensors)
        if self.Status == 'init'
            self.Status = 'unverified'
        end
    end

    def _WaterFlow(sensors)
        var Res
        var RawDelta
        var CurMillis = tasmota.millis()
        if self._RateMeasuring
            log("DBG: RateMeasuring " .. value)
            if self.LastMillis != nil
                var MillisDelta = CurMillis - self.LastMillis
                RawDelta = self.Raw - self.LastRaw

                Res = (RawDelta * 1000.0) / MillisDelta

                #self.RawRateEMA = self.EMA(self.RawRateEMA, self.EMAN, Res)
                self.RawRate = Res

                # Step mills
                self.LastMillis = CurMillis
            else
                self.LastMillis = CurMillis
            end
            # Step LastRaw
            self.LastRaw = self.Raw
            log("DBG: RateMeasuring " .. self.LastRaw .. RawDelta)
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


    def button_pressed(cmd, idx, payload, raw)
        if !(cmd == '' && idx == 0 && payload == '')
            print("Watering: button_pressed", type(cmd), cmd, ',', idx, ',', type(payload), payload, ',', raw)
        end
    end

    #def set_power_handler(cmd, idx)
    #    # idx 0 off, 1 on
    #    var power = tasmota.get_power()
    #end


    def rule_power(value, trigger)
        import string
        import json
        var sensors = json.load(tasmota.read_sensors())
        var Counter1 = sensors['COUNTER']['C1']
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
            except
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
                self.LastFloodTime = tasmota.rtc()['local']
                self.LastFloodVol += CounterDelta
                tasmota.set_timer(40*60*1000, /->self.timer_soil_transition_after_flooded(), TIMERID_SOILTRANSITION_AFTERFLOOD)
            else
                self.PauseSoilMaxStat = false
            end
            tasmota.set_timer(60*1000, /->self.timer_endfasttele_after_flooded(), TIMERID_ENDFASTTELE)
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
        tasmota.cmd("TelePeriod 1") # Default
    end

    def timer_soil_transition_after_flooded()
        print("Timer: End soil transition after flooding")
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
            tasmota.cmd("Power1 1")
        else
            # Flooding session finished?
            print("Autofloood: Wet lewel reached. End flooding session")
            self._autoflood_end()
        end
    end

    def _autoflood_end()
        self.AutofloodInProcess = false
        self.SoilMaxHymidity = nil
        self.SoilMaxHymidityTime = nil
        self.PrevFloodedVol = self.LastFloodVol
        self.PauseSoilMaxStat = false
        print("Autofloood: finished")
    end

    def auto_flood()
        import persist
        print("Autoflood: AutofloodInProcess ", self.AutofloodInProcess)
        print("Autoflood: Closure test A1 ", self.SoilSensors[0].Raw)
        print("Autoflood: Closure test A1EMA ", self.SoilSensors[0].RawEma)
        if self.SoilSensors[0].IsDry() && !self.AutofloodInProcess
            print("Autoflood: scheduled start")
            if self.estimateflood()
               self.PlannedFlood = self.estimateflood()
            else
               self.PlannedFlood = self.Counter1FloodDefault
            end
            # Save previous session stats
            self.PrevSoilHPreFlood = self.SoilHPreFlood
            self.PrevSoilHPostFlood = self.SoilHPostFlood
            self.PrevFloodedVol = self.LastFloodVol
            self.PrevSoilMaxHymidity = self.SoilMaxHymidity
            for p: ['PrevSoilMaxHymidity',
                   'PrevSoilHPreFlood', 'PrevFloodedVol', 'PrevSoilHPostFlood']
                import introspect
                introspect.set(self, p, persist.find(p, nil))
                persist.save()
            end

            # Init new flood session
            self.LastFloodVol = 0
            self.AutofloodInProcess = true
            self.SoilHPreFlood = self.SoilSensors[0].RawEma
            tasmota.cmd("Power1 1")
        end
    end

    def estimateflood()
        try
            var LastFloodDRaw = self.SoilHPreFlood - self.SoilMaxHymidity
            var CurDRaw = self.SoilSensors[0].RawEma - self.SoilSensors[0].RawDry
            var EstimatedFlood = real(LastFloodDRaw)*CurDRaw/self.LastFloodVol
            if EstimatedFlood < 100
                return 0
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
        if 0 <= time && time <= 11.1
           return int(time * 10)
        elif 11.1 < time && time <= 11.5
           return 111
        elif 11.5 < time && time < 12
           return 112
        elif 12 <= time && time <= 64900
           return int(time + 100)
        else
           raise 'value_outofbound', 'ERROR: MaxPumpRun '.. time ..' out of bounds'
        end
    end

    def update()

    end

    def init()
        var sensors
        import json
        import math
        import persist
        import introspect
        print("Init Watering object")
        print("imported", tasmota)
        var tmp = tasmota.read_sensors()
        print("Sensors raeden from tasmota")
        sensors = json.load(tmp)
        #sensors = json.load(tasmota.read_sensors()) # Don`t work on boot stage
        print("Sensors loaded from Json string")

        self.FlowSensorCalibration = false
        self.Conf_Toggle = 0

        print("Init sensors")
        self.SoilSensors = [SoilSensor('A1'), SoilSensor('A2')]
        self.SoilSensors[0].RawDry = int(persist.find("TargetDry", "815"))
        self.SoilSensors[0].RawWet = int(persist.find("TargetWet", "730"))
        self.LastFloodVol = int(persist.find("LastFloodVol", "0"))
        self.FlowSensors = [FlowSensor('C1'), FlowSensor('C2')]
        print("Sensors initialized")

        for p: ['SoilHPreFlood', 'SoilHPostFlood', 'PrevSoilMaxHymidity',
               'PrevSoilHPreFlood', 'PrevFloodedVol', 'PrevSoilHPostFlood']
            introspect.set(self, p, persist.find(p, nil))

        end


        self.MaxPumpRun = 40
        var PulseTime
        PulseTime = int(self.pulseencode(self.MaxPumpRun))
        tasmota.cmd('PulseTime1":{"Set":'.. PulseTime ..',"Remaining":0}')

        # When pipes without check valve, backflow - water
        self.Counter1Backflow = 140
        self.Counter1FloodDefault = 200

        self.Power1 = 0
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false

        tasmota.add_driver(self)
        tasmota.add_rule("POWER1", / v, t -> self.rule_power(v, t))
        tasmota.add_cron("0 */5 19,20,21,22,23,0,1,2,3 * * *", /-> self.auto_flood(), "auto_flood")

    end

    def deinit()
        import persist
        persist.save()
        tasmota.remove_rule("POWER1")
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
        if !self.SoilMaxHymidity && self.SoilSensors[0].RawEma > self.SoilMaxHymidity + 5
            self.SoilMaxHymidityConfirmed = true
        end

        #print("every_second: processed")
    end

    def web_add_main_button()
        webserver.content_send("<p></p><button onclick='la(\"&m_toggle_flowcalibration=1\");'>Flow Sensor Calibration</button>")
    end


    def web_add_config_button()
    #- the onclick function "la" takes the function name and the respective value you want to send as an argument -#
    # this not work. It wrong way. https://github.com/arendst/Tasmota/discussions/18753
        webserver.content_send("<p></p><button onclick='la(\"&m_toggle_conf=1\");'>Toggle Conf</button>")
    end






    def web_sensor()
    #- As we can add only one sensor method we will have to combine them besides all other sensor readings in one method -#
        var msg

        if webserver.has_arg("m_toggle_flowcalibration")
          self.FlowSensorCalibration = ! self.FlowSensorCalibration
          print("FlowSensor Calibration mode" .. self.FlowSensorCalibration)
        end

        if webserver.has_arg("m_toggle_conf") # takes a string as argument name and returns a boolean
            # we can even call another function and use the value as a parameter
            # takes a string or integer(index of arguments) to get the value of the argument
            print("Conf button pressed")
            #self.Conf_Toggle = int(webserver.arg("m_toggle_conf"))
        end

        import string
        msg = string.format(
                  "{s}FlowSensor Calibration mode{m}%s{e}",
                  self.FlowSensorCalibration)
        tasmota.web_send_decimal(msg)

        self.SoilSensors[0].web_sensor()
        #tasmota.web_send_decimal(msg)
        self.SoilSensors[1].web_sensor()

        if self.SoilMaxHymidity != nil
            msg = string.format(
                    "{s}SoilHymidity1 max{m}%i{e}",
                    self.SoilMaxHymidity)
            if self.SoilMaxHymidityConfirmed
                msg += string.format(
                        "{s}SoilHymidity1 max time{m}%s{e}",
                        tasmota.strftime("%d %B %H:%M", self.SoilMaxHymidityTime))
            end
            tasmota.web_send_decimal(msg)
        end

        if self.LastFloodTime != nil
            #print("Web S: LastFlood")
            #print("Web S: LastFlood ".. self.LastFloodVol)
            #print("Web S: LastFloodTime ".. self.LastFloodTime)
            msg = string.format(
                      "{s}Last flood time{m}%s{e}"..
                      "{s}Last flood{m}%01.1f ml{e}",
                      tasmota.strftime("%d %B %H:%M", self.LastFloodTime),
                      self.FlowSensors[0].Raw2Flow(self.LastFloodVol))
            tasmota.web_send_decimal(msg)
        end

        self.FlowSensors[0].web_sensor()

        #print("web_sensor: processed")

    end




    def json_append()
        #- add sensor value to teleperiod -#
        import json
        import string
        var wtele = {
                'Soil1RawEma': int(self.SoilSensors[0].RawEma),
                'Soil1Hymidity': self.SoilSensors[0].Hymidity,
                'Soil2RawEma': int(self.SoilSensors[1].RawEma),
                'Soil2Hymidity': self.SoilSensors[1].Hymidity,
                'LastFloodSessionVol': self.LastFloodVol,
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
