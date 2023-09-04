import webserver
import strict

var TIMERID_ENDFASTTELE = 1
var TIMERID_SOILTRANSITION_AFTERFLOOD = 2

def EMA(oldEMA, N, NewValue)
    import math
    return (math.floor(oldEMA*(N - 1)*10.0) + NewValue*10.0) / (N*10)
end

class SoilSensor
    var SensorID
    var Raw
    var RawEma
    var EMAN
    var RawDry
    var RawWet
    var ScaleMinRAW
    var ScaleMaxRAW
    var Scale
    var Offset
    var Status

    def init(Sensor)
        import json
        self.SensorID = ['ANALOG', Sensor]
        self.setScale(650, 1000)
        self.EMAN = 600
        self.RawDry = 800
        self.RawWet = 750
        self.Status = 'init'

        var sensors = json.load(tasmota.read_sensors())
        self.Update(sensors)
    end

    def setScale(min, max)
        self.ScaleMinRAW = min
        self.ScaleMaxRAW = max
        self.Scale = 100.0/(self.ScaleMinRAW-self.ScaleMaxRAW) # (out1-out2)/(in1-in2)
        self.Offset = -self.ScaleMaxRAW*(100.0)/(self.ScaleMinRAW-self.ScaleMaxRAW) # out2-In2*(out1-out2)/(in1-in2)
        print("Soil sensor scale set.")
    end

    def Update(sensors)
        self.Raw = sensors[self.SensorID[0]][self.SensorID[1]]
        if self.Raw < 100 self.Status = 'N/C' end
        #print("Old Sensor" .. self.SensorID[1] .. "RawEma: ", self.RawEma, "Raw", self.Raw)
        if self.RawEma == nil
            self.RawEma = self.Raw
        else
            self.RawEma = EMA(self.RawEma, self.EMAN, self.Raw)
        end
        #print("New Sensor" .. self.SensorID[1] .. "RawEma", self.RawEma)
    end

    def Raw2Hymidity(rawSoil)
        # Dumb scale to Hymidity
        return real(rawSoil) * self.Scale + self.Offset
    end

    def Hymidity2Raw(SoilH)
        # Dumb scale to Hymidity
        return (SoilH - self.Offset) / self.Scale
    end

    def member(name)
        if name == 'Hymidity'
            return self.Raw2Hymidity(self.Raw)
        elif name == 'Dry'
            return self.Raw2Hymidity(self.RawDry)
        elif name == 'Wet'
            return self.Raw2Hymidity(self.RawWet)
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
            "{s}Soil%sHymidity{m}{e}"..
            "{s}| auto hreshold{m}%01.2f{e}"..
            "{s}| auto target{m}%01.2f{e}",
            self.SensorID[1], self.RawDry, self.RawWet)
        msg = msg .. string.format(
            "{s}| SoilHymidity{m}%i{e}",
            self.Raw)
        msg = msg .. string.format(
            "{s}| SoilHymidity EMA(%i){m}%01.4f{e}",
            self.EMAN, self.RawEma)

        tasmota.web_send_decimal(msg)

    end
end








class FlowSensor
    # Инкапсулировать в отдельный класс параметры калибровки
    # и хотябы базовую статистику
    var FlowSensorCalibration
    var CounterScale
    var Raw
    var LastMillis
    var LastRaw
    var Rate

    def init(Sensor)
        import json
        self.SensorID = ['COUNTER', Sensor]
        self.setScale(0.1449)  # ml/count
        self.Status = 'init'

        var sensors = json.load(tasmota.read_sensors())
        self.Update(sensors)
    end

    def setScale(Scale)
        self.Scale = Scale
        self.Offset = 0
        print("Flow sensor scale set.")
    end

    def Update(sensors)
        self.Raw = sensors[self.SensorID[0]][self.SensorID[1]]
        self.Status = 'unknown'
    end

    def member(name)
        if name == 'Hymidity'
            return self.Raw2Hymidity(self.Raw)
        elif name == 'Dry'
            return self.Raw2Hymidity(self.RawDry)
        elif name == 'Wet'
            return self.Raw2Hymidity(self.RawWet)
        else
            import undefined
            return undefined
        end
    end

    def web_sensor()
        import string
        var msg
        msg = string.format(
                  "{s}FlowSensor Calibration mode{m}%s{e}",
                  self.FlowSensorCalibration)
        msg = msg .. string.format(
                  "{s}Water used{m}%01.1f ml{e}",
                  self.Counter1*self.CounterScale)

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
    var Counter1
    var LastCounter1
    var Pump1Rate
    var Counter1BeforeStart
    var Counter1Backflow
    var Counter1Flood
    var CounterScale
    var FinishRule
    var SoilMaxHymidity
    var SoilMaxHymidityTime
    var LastFloodTime
    var LastFloodVol
    var LastMillis
    var Power1
    var SoilHPreFlood
    var SoilHPostFlood
    var PrevSoilMaxHymidity
    var PrevSoilHPreFlood
    var PrevFloodedVol
    var PrevSoilHPostFlood
    var AutofloodInProcess




    def rule_power(value, trigger)
        import string
        import json
        var sensors = json.load(tasmota.read_sensors())
        var Counter1 = sensors['COUNTER']['C1']
        #print(string.format("value: %s trigger: %s", value, trigger))
        if value['State'] == 1
            print("Water pump ON")
            self.Power1 = 1
            if self.SoilSensors[0].IsWet()
                print("Too wet to flood. Stop pump.")
                tasmota.cmd("Power1 0")
                return
            end
            tasmota.cmd("TelePeriod 10")
            self.PauseSoilMaxStat = true
            self.SoilH = self.SoilSensors[0].Raw2Humidity(self.SoilSensors[0].RawEma)
            self.Counter1BeforeStart = Counter1
            print("Counter: ", Counter1)
            self.FinishRule = "COUNTER#C1>="..(Counter1+self.Counter1Backflow+self.Counter1Flood)
            print("Flooding FinishRule ", self.FinishRule)
            tasmota.add_rule(self.FinishRule, / v, t -> self.rule_flooded(v, t))
            print("Rule on ", self.FinishRule, " set")
        elif value['State'] == 0
            print("Water pump OFF")
            if self.FinishRule
                tasmota.remove_rule(self.FinishRule)
                self.FinishRule = nil
                print("Flooding FinishRule removed")
            end
            var CounterDelta = Counter1 - self.Counter1BeforeStart
            print("Counter: ", Counter1)
            print("CounterDelta: ", CounterDelta)
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
            self.Power1 = 0
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
        if self.SoilSensors[0].Raw < (self.SoilSensors[0].RawDry + self.SoilSensors[0].RawWet)/2
            print("Autofloood: Wet lewel not reached. Repeat flooding")
            tasmota.cmd("Power1 1")
        else
            # Flooding session finished?
            self.SoilMaxHymidity = nil
            self.SoilMaxHymidityTime = nil
            print("Autofloood: Wet lewel reached. Finish flooding session")
            self.PrevFloodedVol = self.LastFlood
            self.AutofloodInProcess = false
            self.PauseSoilMaxStat = false
        end
    end

    def check_flood()
        print("Autoflood: AutofloodInProcess " .. self.AutofloodInProcess)
        print("Autoflood: Closure test A1 ", self.SoilSensors[0].Raw)
        print("Autoflood: Closure test A1EMA " , self.SoilSensors[0].RawEma)
        if self.SoilSensors[0].IsDry() && !self.AutofloodInProcess
            print("Autoflood: scheduled start")
            self.LastFloodVol = 0
            self.AutofloodInProcess = true
            tasmota.cmd("Power1 1")
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

    def init()
        var sensors
        import json
        import math
        sensors = json.load(tasmota.read_sensors())

        self.FlowSensorCalibration = false
        self.Conf_Toggle = 0

        print("Init sensors")
        self.SoilSensors = [SoilSensor('A1'), SoilSensor('A2')]
        self.SoilSensors[0].RawDry = 815
        self.SoilSensors[0].RawWet = 730
        print("Sensors initialized")

        self.MaxPumpRun = 40
        var PulseTime
        PulseTime = int(self.pulseencode(self.MaxPumpRun))
        tasmota.cmd('PulseTime1":{"Set":'.. PulseTime ..',"Remaining":0}')

        self.Counter1Backflow = 140
        self.Counter1Flood = 150
        self.CounterScale = 0.1449 # ml/count

        tasmota.add_driver(self)
        tasmota.add_rule("POWER1", / v, t -> self.rule_power(v, t))
        tasmota.add_cron("0 1 19,20,21,22,23,0,1 * * *", /-> self.check_flood(), "check_flood")
        self.LastCounter1 = sensors['COUNTER']['C1']
        self.Counter1 = sensors['COUNTER']['C1']
        self.LastMillis = tasmota.millis()
        self.Power1 = 0
        self.Pump1Rate = 0
        self.PauseSoilMaxStat = false
        self.AutofloodInProcess = false

    end

    def destroy()
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

    def WaterFlow()
        import math
        var Res
        var MillsEMAN = 30
        var CurMillis = tasmota.millis()
        if self.LastMillis != nil
            var CurMillisDelta = CurMillis - self.LastMillis
            var Counter1Delta = self.Counter1 - self.LastCounter1

            Res = (Counter1Delta * 1000.0) / CurMillisDelta

            #self.Pump1RateEMA = (math.floor(self.Pump1RateEMA*(MillsEMAN - 1)*10.0) + Res*10.0) / (MillsEMAN*10)
            self.Pump1Rate = Res

            # Step
            self.LastCounter1 = self.Counter1
            if self.Power1 == 1
                self.LastMillis = CurMillis
            elif self.Power1 == 0
                self.LastMillis = nil
            else
                raise "wp_Incorect_self_power" ""
            end
        else
            if self.Power1 == 1
                self.LastMillis = CurMillis
            elif self.Power1 == 0
            else
                raise "wp_Incorect_self_power" ""
            end
        end
    end

    def every_second()
        #self.read_tds()
        import json
        import math
        var sensors = json.load(tasmota.read_sensors())
        for s: self.SoilSensors
            s.Update(sensors)
        end
        if ! self.PauseSoilMaxStat
            if self.SoilMaxHymidity == nil || self.SoilMaxHymidity < self.SoilSensors[0].Hymidity
                self.SoilMaxHymidity = self.SoilSensors[0].RawEma
                self.SoilMaxHymidityTime = tasmota.rtc()['local']
            end
        end
        self.Counter1 = sensors['COUNTER']['C1']

        self.WaterFlow()
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

        if self.SoilMaxHymidity != nil
            msg = string.format(
                    "{s}SoilHymidity1 max{m}%i{e}"..
                    "{s}SoilHymidity1 max time{m}%s{e}",
                    self.SoilMaxHymidity, tasmota.strftime("%d %B %H:%M", self.SoilMaxHymidityTime))
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
                      self.LastFloodVol*self.CounterScale)
            tasmota.web_send_decimal(msg)
        end

        msg = string.format(
                  "{s}Water used{m}%01.1f ml{e}",
                  self.Counter1*self.CounterScale)
        tasmota.web_send_decimal(msg)

        msg = string.format(
                  "{s}Water flow{m}%01f pulse/s{e}"..
                  "{s}Water flow{m}%01f ml/min{e}",
                  self.Pump1Rate, self.Pump1Rate*self.CounterScale*60)
        tasmota.web_send_decimal(msg)

#        msg = string.format(
#                  "{s}MillsDeltaEMA{m}%f{e}"..
#                  "{s}MillsDeltaStdDevEMA{m}%f{e}",
#                  self.MillisDeltaEMA, self.MillisDeltaStdDevEMA)
#        tasmota.web_send_decimal(msg)

    end




    def json_append()
        #- add sensor value to teleperiod -#
        import json
        import string
        var wtele = {'Soil1RawEma': int(self.SoilSensors[0].RawEma), 'Soil1Hymidity': self.SoilSensors[0].Hymidity}
        var json_tele = string.format(", \"Watering\": %s", json.dump(wtele))
        #print('json_append:', json_tele)
        tasmota.response_append(json_tele)
    end

end

import introspect
#print(introspect.get(global, "wp1"))
if introspect.get(global, "wp1") != nil
    print("Remove old Watering driver")
    introspect.get(global, "wp1").destroy()
end

wp1 = Watering()
print("Add new Watering driver")
