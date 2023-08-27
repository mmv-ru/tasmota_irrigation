import webserver

var TIMERID_ENDFASTTELE = 1

class Watering
    var FlowSensorCalibration
    var Conf_Toggle
    var A1ema
    var averageN
    var MaxPumpRun
    var Counter1
    var LastCounter1
    var Flow1
    var Counter1BeforeStart
    var Counter1Backflow
    var Counter1Flood
    var CounterScale
    var FinishRule
    var SoilDry
    var SoilWet
    var SoilMaxHymidity
    var SoilMaxHymidityTime
    var LastFloodTime
    var LastFloodVol
    var LastMillis
    var LastMillisDelta
    var MillisDeltaEMA
    var MillisDeltaStdDevEMA
    var Power1

    def rule_power(value, trigger)
        import string
        import json
        var sensors = json.load(tasmota.read_sensors())
        var Counter1 = sensors['COUNTER']['C1']
        #print(string.format("value: %s trigger: %s", value, trigger))
        if value['State'] == 1
            print("Watering pump ON")
            self.Power1 = 1
            if self.A1ema <= self.SoilWet
                print("Too wet to flood. Stop pump.")
                tasmota.cmd("Power1 0")
                return
            end
            tasmota.cmd("TelePeriod 10")
            self.Counter1BeforeStart = Counter1
            print("Counter: ", Counter1)
            self.FinishRule = "COUNTER#C1>="..(Counter1+self.Counter1Backflow+self.Counter1Flood)
            print("FinishRule ", self.FinishRule)
            tasmota.add_rule(self.FinishRule, / v, t -> self.rule_flooded(v, t))
            print("Rule on ", self.FinishRule, " set")
        elif value['State'] == 0
            print("Watering pump OFF")
            if self.FinishRule
                tasmota.remove_rule(self.FinishRule)
                self.FinishRule = nil
                print("FinishRule removed")
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
                self.LastFloodVol = CounterDelta
            end 
            self.Power1 = 0
            tasmota.set_timer(60*1000, /->self.timer_endfasttele_after_flooded(), TIMERID_ENDFASTTELE)
        else
            print("WARNING: Watering pump state ", value['State'])
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

    def check_flood()
        if self.A1ema >= self.SoilDry
            print("Autoflood start")
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

        self.FlowSensorCalibration = false
        self.Conf_Toggle = 0

        self.averageN = 1200
        import json
        sensors = json.load(tasmota.read_sensors())
        self.A1ema = sensors['ANALOG']['A1']

        self.MaxPumpRun = 40
        var PulseTime
        PulseTime = int(self.pulseencode(self.MaxPumpRun))
        tasmota.cmd('PulseTime1":{"Set":'.. PulseTime ..',"Remaining":0}')

        self.Counter1Backflow = 140
        self.Counter1Flood = 450
        self.CounterScale = 0.1449 # ml/count
        self.SoilDry = 830
        self.SoilWet = 720

        tasmota.add_driver(self)
        tasmota.add_rule("POWER1", / v, t -> self.rule_power(v, t))
        tasmota.add_cron("0 1 19,20,21,22,23,0,1 * * *", /-> self.check_flood(), "check_flood")
        self.LastCounter1 = sensors['COUNTER']['C1']
        self.Counter1 = sensors['COUNTER']['C1']
        self.LastMillis = tasmota.millis()
        self.LastMillisDelta = 1000
        self.MillisDeltaEMA = 1000
        self.MillisDeltaStdDevEMA = 0
        self.Flow1 = 0
    end

    def destroy()
        tasmota.remove_rule("POWER1")
        tasmota.cmd("Power1 0")
        if self.FinishRule
            tasmota.remove_rule(self.FinishRule)
            self.FinishRule = nil
            print("FinishRule removed")
        end
        tasmota.remove_driver(self)
    end

    def timer_stability_stats()
        import math
        var CurMills = tasmota.millis()
        var CurMillsDelta = CurMills - self.LastMillis
        var MillsDeltaDev = self.LastMillisDelta - CurMillsDelta
        var MillsEMAN = 30

        self.MillsDeltaEMA = (math.floor(self.MillsDeltaEMA*(MillsEMAN - 1)*10.0) + CurMillsDelta*10.0) / (MillsEMAN*10)
        self.MillsDeltaStdDevEMA = (math.floor(self.MillsDeltaStdDevEMA*(MillsEMAN - 1)*10.0) + MillsDeltaDev*MillsDeltaDev*10.0) / (MillsEMAN*10)

        # Step
        self.LastMillisDelta = CurMillsDelta
        self.LastMillis = CurMills
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

            #self.Flow1EMA = (math.floor(self.Flow1EMA*(MillsEMAN - 1)*10.0) + Res*10.0) / (MillsEMAN*10)
            self.Flow1 = Res

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
        var sensors, A1
        #self.read_tds()
        import json
        import math
        sensors = json.load(tasmota.read_sensors())
        A1 = sensors['ANALOG']['A1']
        #print("Old A1ema: ", self.A1ema, "A1", A1)
        self.A1ema = (math.floor(self.A1ema*(self.averageN - 1)*10.0) + A1*10.0) / (self.averageN*10)
        #print("New A1ema:", self.A1ema)
        if self.SoilMaxHymidity == nil || self.SoilMaxHymidity > self.A1ema
            self.SoilMaxHymidity = self.A1ema
            self.SoilMaxHymidityTime = tasmota.rtc()['local']
        end
        self.Counter1 = sensors['COUNTER']['C1']

        if self.Power1 == 1
            self.WaterFlow()
        end
        #self.timer_stability_stats()
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
                  "{s}FlowSensor Calibration mode{m}%s{e}"..
                  "{s}Conf_Toggl{m}%i{e}",
                  self.FlowSensorCalibration, self.Conf_Toggle)
        tasmota.web_send_decimal(msg)

        msg = string.format(
                  "{s}SoilHymidity1 autoflood{m}%i{e}",
                  self.SoilDry)
        tasmota.web_send_decimal(msg)

        msg = string.format(
                  "{s}SoilHymidity1 EMA(%i){m}%01.4f{e}",
                  self.averageN, self.A1ema)
        tasmota.web_send_decimal(msg)

        msg = string.format(
                  "{s}SoilHymidity1 max{m}%i{e}"..
                  "{s}SoilHymidity1 max time{m}%s{e}",
                  self.SoilMaxHymidity, tasmota.strftime("%d %B %H:%M", self.SoilMaxHymidityTime))
        tasmota.web_send_decimal(msg)

        if self.LastFloodTime != nil
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
                  self.Flow1, self.Flow1*self.CounterScale*60)
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
        var wtele = {'SoilEMA1': int(self.A1ema)}
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

