import strict
import string
import json

import web_kit

var sensors = module('sensors')

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
        # On real hardware an early-boot read_sensors() may throw while the
        # firmware's own berry drivers are still coming up (framework event
        # dispatch during FUNC_JSON_APPEND). A failed read must not abort the
        # whole load(): return nil and let the periodic updates fill the value
        # on a later cycle (Raw stays nil, Update() ignores it).
        try
            var raw = tasmota.read_sensors()
            if raw == nil
                return nil
            end
            return json.load(raw)
        except .. as _boot_read_exc
            return nil
        end
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
    var ScaleMinRAW
    var ScaleMaxRAW
    var Raw2mVScale
    var Hu_C

    def init(Sensor)
        self.SensorID = ['ANALOG', Sensor]
        self.Name = 'Soil%sHymidity'
        self.setScale(842, 1105)
        self.EMAN = 600
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

    def member(name)
        if name == 'Hymidity'
            return self.Raw2Hymidity(self.RawEma)
        elif name == 'mV'
            return self.Raw2mV(self.Raw)
        elif name == 'Hu'
            return self.Raw2Hu(self.RawEma)
        else
            import undefined
            return undefined
        end
    end

    def web_sensor(expanded, sec, plant)
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
        msg = "<tr class='sec'><th class='hdr' " .. web_kit.wtoggle(sec) .. ">"
        msg = msg .. "<span class='st " .. stc .. "' " .. web_kit.wonclick('_wdShowTT(this,event)') .. ">" .. st .. "</span>" .. nm
        msg = msg .. "<span class='params'>"
        if self.RawEma != nil
            msg = msg .. web_kit.wpill("raw", string.format("%01.2f", self.RawEma))
        end
        msg = msg .. web_kit.wpill("сухо", str(plant.TargetDry)) .. web_kit.wpill("влажно", str(plant.TargetWet)) .. "</span>" ..
                    "</th><td class='tgl'><a class='chev' href='#' " .. web_kit.wtoggle(sec) .. ">" .. arrow .. "</a></td></tr>"
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
        var msg
        var nm = "Common"
        var arrow = expanded ? "▲" : "▼"
        msg = "<tr class='sec'><th class='hdr' " .. web_kit.wtoggle(sec) .. ">" .. nm ..
              "</th><td class='tgl'><a class='chev' href='#' " .. web_kit.wtoggle(sec) .. ">" .. arrow .. "</a></td></tr>"
        msg = msg .. string.format(
                  web_kit.wrow("Water used", "%01.1f ml"),
                  self.Raw2Flow(self.Raw))
        if expanded
            msg = msg .. string.format(
                      web_kit.wrow("Water flow", "%i pulse/s<br/><span class='stk'>%01.1f ml/min</span>"),
                      self.RawRate, self.Rate != nil ? self.Rate*60 : nil)
        end

        tasmota.web_send_decimal(msg)
    end
end

# Berry's module() does not auto-collect file-level names (gotcha #13).
sensors.EMA = EMA
sensors.AbstractSensor = AbstractSensor
sensors.SoilSensor = SoilSensor
sensors.FlowSensor = FlowSensor

return sensors
