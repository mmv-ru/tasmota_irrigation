import strict
import webserver
import string
import introspect

import web_kit
import cfg

var web = module('web')

class Web
    var d              # the Watering driver, injected once by init(d)
    var TimeCacheKey
    var TimeCache

    def init(d)
        self.d = d
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
    def web_add_main_button()
        # Кнопка перехода на /svc + оформление главной страницы. CSS и JS
        # живут в web_kit (слой «как делается HTML»): блоки собираются там
        # один раз при загрузке модуля, здесь они только уходят браузеру.
        # Формы Soil Dry/Wet, Dry threshold, Soak start dose, Max flood и
        # flood dose default живут в попапе канала (web_soil_detail +
        # _wdSettingsOpen в web_kit.main_js).
        webserver.content_send("<p></p><button onclick='location.href=\"svc\";'>Сервисный режим</button>")
        webserver.content_send(web_kit.css)
        webserver.content_send(web_kit.main_js(self.d.NumChannels))
    end

    def web_add_handler()
        # Two callers, no guard on our side (a guard would block the cold-boot
        # case, where this first call is a C-side no-op and the official event
        # must be allowed to register for real):
        #  1. Tasmota's one-shot FUNC_WEB_ADD_HANDLER - one per VM, may fire
        #     before this driver exists;
        #  2. Watering.init_sensors(), right after add_driver() - that is what
        #     makes /svc survive BrRestart.
        # The main-page button in web_add_main_button() navigates here.
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
            self.d.service_enter()
        end
        if webserver.has_arg("exit")
            self.d.service_exit()
        end
        if self.d.ServiceMode
            if webserver.has_arg("pump")
                self._service_pump(webserver.arg("pump"))
            end
            if webserver.has_arg("cal")
                self._service_calibrate()
            end
        end
        # The manual scale coefficient is available regardless of the mode: the
        # /svc page offers the direct-entry form even while the mode is off.
        if webserver.has_arg("set")
            self._service_set_scale_arg()
        end
        # The channel count is a global Store variable, so this form works in
        # any mode state (like the scale form). Reducing Channels never removes
        # the stored per-channel parameters of the disabled channels.
        if webserver.has_arg("channels")
            self._service_channels_arg()
        end
        if webserver.has_arg("flowlimit")
            self._service_flowlimit_arg()
        end
        if webserver.has_arg("restart")
            # Deferred so the browser receives the response first. On the harness
            # the timer/command are asserted from SIM.
            tasmota.set_timer(1000, /-> tasmota.cmd('Restart 1'), "ID_SVC_RESTART")
        end
        webserver.content_start("Сервисный режим")
        webserver.content_send_style()
        # Live flow-rate during a service pump run: reload the page every 2 s
        # (same refresh-model as the main page) so the "Прогон" number updates.
        # Strictly while a run is active - after OFF the page settles so the
        # measured-volume field can be filled in.
        if self.d.ServiceMode && self._service_run_plant() != nil
            webserver.content_send("<script>setTimeout(function(){location.reload()},2000);</script>")
        end
        var state = self.d.ServiceMode ? "включен" : "выключен"
        webserver.content_send("<p>Сервисный режим: <b>" .. state .. "</b>.</p>")
        if self.d.ServiceMode
            self._service_page_on()
        else
            webserver.content_send("<form action='svc' style='display: block;' method='get'><input type='hidden' name='start' value='1'><button>Включить сервисный режим</button></form>")
            # Current C1 scale, last calibration stats and the direct-entry form
            # are visible without enabling the mode.
            self._service_cal_fieldset(false)
        end
        self._service_channels_fieldset()
        self._service_limits_fieldset()
        webserver.content_button(webserver.BUTTON_MAIN)
        webserver.content_stop()
    end

    def service_set_scale(v)
        # Apply a new flow calibration (ml per counter tick) and persist it
        # globally (the C1 meter is shared by every channel). Guarded by callers.
        self.d.FlowSensors[0].setScale(v)
        self.d.Store.set('FlowScale', str(v))
        print("Service: flow scale set to " .. str(v))
    end

    def _service_pump(pump_arg)
        # Per-channel pump control from the service page: issue the relay
        # command so the POWER{Num}#State rule dispatches into the service
        # water_on/water_off branches (keyed on the active mode / ServiceRun).
        var n = int(pump_arg)
        if n == nil || n < 1 || n > self.d.NumChannels
            print("Service: bad pump arg '" .. str(pump_arg) .. "'")
            return
        end
        var p = self.d.plants[n - 1]
        if webserver.has_arg("on")
            # Shared C1: a service run must not start while another channel is
            # flooding (their water would leak into our tick delta).
            var busy = self.d._flooding_plant()
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

    def _service_run_plant()
        # The channel currently pumping in service mode, or nil. Drive for the
        # live flow-rate display and the page auto-reload while a run is active.
        for i: 0..(self.d.NumChannels - 1)
            if self.d.plants[i].ServiceRun
                return self.d.plants[i]
            end
        end
        return nil
    end

    def _service_calibrate()
        # ?cal=1&vol=ml: derive the scale from the last service run - the user
        # measured the pumped volume, we know how many counter ticks it took.
        var sr = self.d.ServiceResult
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
        # Keep a snapshot of the run used for this calibration so the /svc page
        # can show the last calibration stats (volume, duration, flow rate) even
        # after the mode is turned off. Survives until the next successful cal.
        self.d.LastCalibration = {
            'num': sr['num'], 'vol': vol, 'ticks': sr['ticks'],
            'millis': sr['millis'], 'scale': v
        }
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

    def _service_channels_arg()
        # ?channels=N: change the (global) channel count. Persisted immediately
        # (immediate policy) and applied on the next boot. The per-channel Store
        # parameters of the disabled channels are left untouched.
        var n = int(webserver.arg("channels"))
        if n == nil || n < 1 || n > cfg.MAX_CHANNELS
            print("Service: bad channels arg '" .. str(webserver.arg("channels")) .. "'")
            return
        end
        self.d.Store.set('Channels', str(n))
        self.d._channels_pending = n
        print("Service: channels set to " .. str(n) .. ", restart required")
    end

    def _service_flowlimit_arg()
        # ?flowlimit=N: change the global low-flow detection limit (ml/min).
        # 0 disables detection. Debounced (like FlowScale); the live value is
        # applied immediately so _flow_low_check picks it up on the next tick.
        # Berry's int() silently maps unparsable input to 0, so a re-roundtrip
        # check (str(int(raw)) == raw) rejects any non-canonical value while
        # still allowing 0 and rejecting negatives via the sign guard.
        var raw = webserver.arg("flowlimit")
        if raw == nil || raw == ""
            print("Service: bad flowlimit arg '" .. str(raw) .. "'")
            return
        end
        var n = int(raw)
        if n < 0 || str(n) != raw
            print("Service: bad flowlimit arg '" .. str(raw) .. "'")
            return
        end
        self.d.FlowRateLimit = n
        self.d.Store.set('FlowRateLimit', str(n))
        print("Service: flow rate limit set to " .. str(n) .. " ml/min")
    end

    def _service_channels_fieldset()
        # Channel-count fieldset rendered in any mode state. After the value has
        # just been changed it shows a "restart required" note plus a restart
        # button (the sensor/plant/rules layout is built on boot).
        webserver.content_send("<fieldset><legend>Каналы</legend>")
        webserver.content_send("<p>Каналов: <b>" .. str(self.d.NumChannels) .. "</b>.</p>")
        if self.d._channels_pending != nil
            webserver.content_send(
                "<p>Задано <b>" .. str(self.d._channels_pending) ..
                "</b>. Требуется перезагрузка, чтобы перестроить каналы.</p>" ..
                "<form action='svc' style='display: block;' method='get'>" ..
                "<input type='hidden' name='restart' value='1'>" ..
                "<button>Перезагрузить устройство</button></form>")
        else
            webserver.content_send(
                "<form action='svc' style='display: block;' method='get'>" ..
                "<input name='channels' type='number' min='1' max='" .. str(cfg.MAX_CHANNELS) ..
                "' value='" .. str(self.d.NumChannels) .. "'> " ..
                "<button>Применить</button></form>")
        end
        webserver.content_send("</fieldset>")
    end

    def _service_limits_fieldset()
        # Low-flow ("Out of Water") fieldset, rendered in any mode state like the
        # channel fieldset. 0 disables detection.
        webserver.content_send("<fieldset><legend>Нет воды</legend>")
        webserver.content_send("<p>Лимит расхода: <b>" .. str(self.d.FlowRateLimit) .. " ml/min</b> (0 = выкл).</p>")
        webserver.content_send(
            "<p>Лимит расхода (мл/мин, 0 — выключить): <form action='svc' style='display: block;' method='get'>"..
            "<input name='flowlimit' type='number' min='0' value='" ..
            str(self.d.FlowRateLimit) .. "'> <button>Применить</button></form></p>")
        webserver.content_send("</fieldset>")
    end

    def _service_page_on()
        # Body of the /svc page while the mode is active. Channel controls only
        # surface here (never on the main page), so they cannot touch a normal
        # flood session.
        webserver.content_send("<fieldset><legend>Каналы</legend>")
        for i: 0..(self.d.NumChannels - 1)
            var p = self.d.plants[i]
            var st = p.WaterIsOn() ? "ON" : "OFF"
            webserver.content_send(
                "<p>Канал " .. str(i + 1) .. " <b>" .. st .. "</b>&nbsp; " ..
                "<form action='svc' style='display: inline-block;' method='get'><input type='hidden' name='pump' value='" .. str(i + 1) .. "'><input type='hidden' name='on' value='1'><button>ON</button></form> " ..
                "<form action='svc' style='display: inline-block;' method='get'><input type='hidden' name='pump' value='" .. str(i + 1) .. "'><input type='hidden' name='off' value='1'><button>OFF</button></form></p>")
        end
        webserver.content_send("</fieldset>")
        var rp = self._service_run_plant()
        if rp != nil
            # Live flow rate (ml/min) from the shared C1 meter using the current
            # calibration - same number the main page shows in the water section.
            var rate = self.d.FlowSensors[0].Rate
            var rate_s = rate != nil ? string.format("%01.1f", rate * 60) : "n/a"
            webserver.content_send(
                "<fieldset><legend>Прогон</legend>" ..
                "<p>Канал " .. str(rp.Num) .. ", расход: <b>" .. rate_s ..
                " ml/min</b> (текущая калибровка).</p></fieldset>")
        end
        self._service_cal_fieldset(true)
        webserver.content_send("<form action='svc' style='display: block;' method='get'><input type='hidden' name='exit' value='1'><button>Выйти</button></form>")
    end

    def _service_cal_fieldset(show_cal)
        # Flow-sensor calibration fieldset shared by the ON and OFF page states.
        # show_cal: ON state also renders the last service run and the measured-
        # volume calibration form (needs the service-only pump controls).
        # OFF state: current C1 scale + last calibration stats + the direct
        # scale-entry form (no mode required).
        webserver.content_send("<fieldset><legend>Калибровка датчика потока</legend>")
        webserver.content_send("<p>Scale (мл/тик): <b>" .. string.format("%01.4f", self.d.FlowSensors[0].Scale) .. "</b></p>")
        if show_cal
            # Last service run: always the same three short rows so the column
            # does not jump; missing data renders as a dash.
            var sr = self.d.ServiceResult
            var dash = "&mdash;"
            if sr == nil
                webserver.content_send("<p>Последний прогон: " .. dash .. "</p>")
                webserver.content_send("<p>При текущем scale: " .. dash .. "</p>")
                webserver.content_send("<p>Окончание " .. dash .. "</p>")
            else
                var num = sr['num'] != nil ? str(sr['num']) : dash
                var ticks = sr['ticks'] != nil ? str(sr['ticks']) : dash
                var dur = sr['millis'] != nil ? string.format("%01.1f", sr['millis'] / 1000.0) : dash
                var tpm = (sr['ticks'] != nil && sr['millis'] != nil && sr['millis'] > 0) ?
                          string.format("%01.1f", sr['ticks'] * 60000.0 / sr['millis']) : dash
                var uml = (sr['ticks'] != nil) ? string.format("%01.1f", self.d.FlowSensors[0].Scale * sr['ticks']) : dash
                # Average flow over the whole run (ml/min at the current scale)
                # and the run-end timestamp - nozzle adjustment data.
                var uml_rate = (sr['ticks'] != nil && sr['millis'] != nil && sr['millis'] > 0 && self.d.FlowSensors[0].Scale > 0) ?
                               string.format("%01.1f", sr['ticks'] * self.d.FlowSensors[0].Scale * 60000.0 / sr['millis']) : dash
                var end_s = sr['finished'] != nil ? self._TimeStr(sr['finished']) : dash
                webserver.content_send(
                    "<p>Последний прогон: канал " .. num .. ", " .. dur ..
                    " с, " .. ticks .. " тиков (" .. tpm .. " тиков/мин)</p>")
                webserver.content_send(
                    "<p>При текущем scale: " .. uml .. " мл, средний расход <b>" .. uml_rate .. " ml/min</b></p>")
                webserver.content_send("<p>Окончание " .. end_s .. "</p>")
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
        else
            # Last calibration: always the same two short rows so the column
            # does not jump; missing data renders as a dash.
            var lc = self.d.LastCalibration
            var dash = "&mdash;"
            if lc == nil
                webserver.content_send("<p>Последняя калибровка: " .. dash .. "</p>")
                webserver.content_send("<p>Scale: " .. dash .. "</p>")
            else
                var num = lc['num'] != nil ? str(lc['num']) : dash
                var vol = lc['vol'] != nil ? string.format("%01.0f", lc['vol']) : dash
                var ticks = lc['ticks'] != nil ? str(lc['ticks']) : dash
                var scale = lc['scale'] != nil ? string.format("%01.4f", lc['scale']) : dash
                var dur = lc['millis'] != nil ? string.format("%01.1f", lc['millis'] / 1000.0) : dash
                var tpm = (lc['ticks'] != nil && lc['millis'] != nil && lc['millis'] > 0) ?
                          string.format("%01.1f", lc['ticks'] * 60000.0 / lc['millis']) : dash
                var uml = (lc['ticks'] != nil) ? string.format("%01.1f", lc['scale'] * lc['ticks']) : dash
                webserver.content_send(
                    "<p>Последняя калибровка: канал " .. num .. ", " .. vol ..
                    " мл / " .. ticks .. " тиков</p>")
                webserver.content_send(
                    "<p>Scale: " .. scale .. " мл/тик, " .. dur .. " с, " ..
                    tpm .. " тиков/мин (" .. uml .. " мл/мин)</p>")
            end
            webserver.content_send(
                "<form action='svc' style='display: block;' method='get'>" ..
                "<input type='hidden' name='set' value='1'>" ..
                "<input name='scale' type='text' placeholder='коэффициент, мл/тик'> " ..
                "<button>Установить коэффициент</button></form>")
        end
        webserver.content_send("</fieldset>")
    end









    def _soil_section(expanded, sec, plant, sensor)
        # Шапка канала (перенесено из SoilSensor.web_sensor, ADR-6 закрыт).
        # Сборка разметки шапки — web_kit (wsec_head/wsec_icon/wpill); здесь
        # только доменная логика: какое состояние какой иконкой показывать.
        # Иконка слева от названия: 💧 ожидание / ⏳ сеанс полива / 💦 работает
        # насос; клик по ней открывает легенду (#wdtt, JS в web_kit.main_js).
        var st = "💧"
        var stc = "wait"
        if plant.WaterIsOn()
            st = "💦"
            stc = "run"
        elif plant.AutofloodInProcess
            st = "⏳"
            stc = "sess"
        end
        var pills = ""
        if sensor.RawEma != nil
            pills = pills .. web_kit.wpill("raw", string.format("%01.2f", sensor.RawEma))
        end
        pills = pills .. web_kit.wpill("сухо", str(plant.TargetDry)) .. web_kit.wpill("влажно", str(plant.TargetWet))
        # Детальное тело канала (Уставки/Датчик/кнопка настроек) и статусы
        # сессии/помпы — в web_soil_detail; в шапке осталась только иконка.
        tasmota.web_send_decimal(web_kit.wsec_head(sec, web_kit.wsec_icon(stc, st),
            "Канал " .. str(plant.Num), pills, expanded))
    end

    def _flow_section(expanded, sec, sensor)
        # Перенесено из FlowSensor.web_sensor (ADR-6 закрыт). Шапка Common —
        # без иконки и бейджей; под ней всегда расход за всё время, при
        # раскрытии — ещё и мгновенный расход (импульсы + мл/мин).
        var msg = web_kit.wsec_head(sec, "", "Common", "", expanded)
        msg += web_kit.wparam_stack("Water used",
            [string.format("%01.1f ml", sensor.Raw2Flow(sensor.Raw))])
        if expanded
            msg += web_kit.wparam_stack("Water flow", [
                string.format("%i pulse/s", sensor.RawRate),
                string.format("%01.1f ml/min", sensor.Rate != nil ? sensor.Rate * 60 : nil)])
        end
        tasmota.web_send_decimal(msg)
    end

    def _soil_model(plant, ss)
        # Модель детального тела канала — читается как опись интерфейса:
        # секции (группы) → параметры → один или более «масштабов» вывода.
        #   секция   = [заголовок, [параметр, ...]]
        #   параметр = [метка, [шкала, ...]] — первая шкала в ячейке,
        #              остальные уходят подстроками .stk (см. wparam_stack)
        # Значения здесь уже готовы к показу (nil-защита выполнена);
        # условный элемент — это отсутствие его в списке: условий внутри
        # строк и шаблонов нет. Считает — web_soil_detail, он же шлёт.
        var num = plant.Num
        var groups = []

        # --- секция «Уставки» ------------------------------------------------
        # Кнопка настроек открывает JS-попап канала: значения полей — в data-*,
        # отправляемые аргументы (m_soildry_N и т.д.) разбирает web_sensor().
        var settings = string.format(
            "<a class='wcbtn' data-num='%i' data-dry='%i' data-wet='%i' data-thr='%i' data-dose='%s' data-maxflood='%i' data-c1def='%i' %s>⚙</a>",
            num, plant.TargetDry, plant.TargetWet,
            plant.DryThreshold,
            str(int(real(self.d.Store.get(plant.Prefix .. 'SoakStartDose')))),
            int(real(self.d.Store.get(plant.Prefix .. 'MaxFlood'))),
            int(real(self.d.Store.get(plant.Prefix .. 'Counter1FloodDefault'))),
            web_kit.wonclick('_wdSettingsOpen(this);return false;'))
        groups.push(['Уставки', [
            ['Сухо', [string.format("%01.2f raw", plant.TargetDry),
                      string.format("%01.1f%% u", ss.Raw2Hu(plant.TargetDry))]],
            ['Влажно', [string.format("%01.2f raw", plant.TargetWet),
                        string.format("%01.1f%% u", ss.Raw2Hu(plant.TargetWet))]],
            ['Настройки порогов', [settings]],
        ]])

        # --- секция «Датчик» ------------------------------------------------
        # До первого Update значения могут быть nil — показываем "nil" вместо
        # падения (иначе теряется шапка и аккордеон не раскрывается).
        var rawv = ss.Raw != nil ? str(ss.Raw) : "nil"
        var rawema = ss.RawEma != nil ? string.format("%01.4f", ss.RawEma) : "nil"
        var hu = ss.RawEma != nil ? string.format("%01.1f%%", ss.Raw2Hu(ss.RawEma)) : "nil"
        var mv = ss.Raw != nil ? string.format("%01.1f mV", ss.Raw2mV(ss.Raw)) : "nil"
        groups.push(['Датчик', [
            ['Raw', [rawv]],
            [string.format("Raw EMA(%i)", ss.EMAN), [rawema]],
            ['Hymidity u', [hu]],
            ['mV', [mv]],
        ]])

        # --- секция «Сеанс» -------------------------------------------------
        # Сеанс полива: active (идёт заливка) / wait. Помпа: run|idle, при
        # работающей помпе к статусу добавляется живой расход (ml/min).
        var sess = plant.AutofloodInProcess ? "active" : "wait"
        var pump = plant.WaterIsOn() ? "run" : "idle"
        if plant.WaterIsOn()
            var rate = self.d.FlowSensors[0].Rate
            if rate != nil
                pump = pump .. " " .. string.format("%01.1f", rate * 60) .. " ml/min"
            end
        end
        groups.push(['Сеанс', [
            ['Сеанс полива', [sess]],
            ['Вода', [pump]],
        ]])

        # --- секция «Размачивание» ------------------------------------------
        var dry_status = "none"
        if plant.Preset != nil && plant.Preset.Type == 'dry'
            dry_status = "soak, dose " .. (plant.DrySoakDose != nil ? str(plant.DrySoakDose) : "?")
        end
        groups.push(['Размачивание', [
            ['Dry soak', [dry_status]],
            ['Dry threshold', [string.format("%i", plant.DryThreshold)]],
        ]])

        # --- секция «Текущий сеанс» -----------------------------------------
        # Дата и средний расход последнего полива — та же часть сессии, что и
        # LastFloodVol (переехали сюда из отдельной группы «Последний полив»).
        # Оба поля живут в Store (P{N}LastFloodTime / P{N}LastFlowRate, см.
        # _record_flood) и переживают ребут; до первого полива значения nil и
        # показываются как "nil".
        var cur = []
        if plant.SoilMaxHymidity != nil
            cur.push(['SoilHymidity' .. str(num) .. ' max',
                      [string.format("%i", plant.SoilMaxHymidity)]])
            if plant.SoilMaxHymidityTime != nil
                cur.push(['SoilHymidity' .. str(num) .. ' max time',
                          [self._TimeStr(plant.SoilMaxHymidityTime)]])
            end
        end
        cur.push(['LastFloodVol (мл)', [string.format("%i", int(plant.LastFloodVol))]])
        cur.push(['SoilHPreFlood', [str(plant.SoilHPreFlood)]])
        # _TimeStr(nil) отдаёт Berry nil, который wparam_stack через %s печатает
        # как "nil"; а %01.1f с nil дал бы пустую строку — поэтому guard.
        cur.push(['Last flood time', [self._TimeStr(plant.LastFloodTime)]])
        cur.push(['Last flow rate',
                  [plant.LastFlowRate != nil ?
                   string.format("%01.1f мл/мин", plant.LastFlowRate) : "nil"]])
        groups.push(['Текущий сеанс', cur])

        # --- секция «Предыдущий сеанс» --------------------------------------
        var prev = []
        for k: ['PrevFloodedVol', 'PrevSoilHPreFlood', 'PrevSoilMaxHymidity']
            prev.push([k, [str(introspect.get(plant, k))]])
        end
        groups.push(['Предыдущий сеанс', prev])
        return groups
    end

    def web_soil_detail(pi)
        # Интерпретатор модели канала: обходит секции, собирает параметры
        # через web_kit.wparam_stack и шлёт каждую секцию отдельным
        # фрагментом. Падение в модели или рендере не должно ронять секции
        # соседей — try/except здесь и собственные try в web_sensor().
        var plant = self.d.plants[pi]
        try
            var groups = self._soil_model(plant, plant.SoilSensor)
            for g: groups
                var msg = web_kit.wgrp(g[0])
                for r: g[1]
                    msg += web_kit.wparam_stack(r[0], r[1])
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
        var msg

        # Main-page status banner while the service mode is active.
        if self.d.ServiceMode
            try
                tasmota.web_send_decimal(web_kit.wrow("Сервисный режим", "включен"))
            except .. as e
                print("web_sensor: service banner failed " .. e)
            end
        end

        # Global "Out of Water" banner: an active channel ran below the flow
        # rate limit for the grace period (see _flow_low_check).
        if self.d.OutOfWater
            try
                tasmota.web_send_decimal(web_kit.wrow("Нет воды", "да"))
            except .. as e
                print("web_sensor: out-of-water banner failed " .. e)
            end
        end

        try
            if webserver.has_arg("m_reset_water_counter_1")
              if self.d.plants[0].AutofloodInProcess
                self.d.plants[0].Counter1ResetPostpone = true
              else
                self.d.FlowSensors[0].Reset()
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
            for i: 0..(self.d.NumChannels - 1)
                exp_soil.push(string.find(me, str(i + 1)) >= 0)
            end
            exp_flow = string.find(me, "c") >= 0
        except .. as e
            print("web_sensor: expand args failed " .. e)
        end

        try
            # Per-channel settings (popup in each channel detail): args carry a
            # channel suffix m_soildry_N / m_soilwet_N / m_drythr_N /
            # m_soakdose_N / m_maxflood_N / m_c1def_N. The bare args (m_soildry
            # etc.) still mean channel 1 (legacy forms). One field table shared
            # conceptually with the JS popup (_wdF in web_add_main_button):
            # adding a field = one row here + one in _wdF.
            for i: 1..self.d.NumChannels
                var s = str(i)
                var pl = self.d.plants[i - 1]
                var sfx = i == 1 ? "" : "_" .. s
                # Dry/Wet are validated by the plant (gap > 20). Dry threshold,
                # soak dose, Max flood and flood dose default are plain int > 0
                # stored on the plant / Store.
                if webserver.has_arg("m_soildry" .. sfx)
                    if pl.SetDry(int(webserver.arg("m_soildry" .. sfx)))
                        print("web_sensor: channel " .. s .. " Soil Dry threshold set to " .. pl.TargetDry)
                    else
                        print("web_sensor: channel " .. s .. " Soil Dry threshold rejected")
                    end
                end
                if webserver.has_arg("m_soilwet" .. sfx)
                    if pl.SetWet(int(webserver.arg("m_soilwet" .. sfx)))
                        print("web_sensor: channel " .. s .. " Soil Wet threshold set to " .. pl.TargetWet)
                    else
                        print("web_sensor: channel " .. s .. " Soil Wet threshold rejected")
                    end
                end
                if webserver.has_arg("m_drythr" .. sfx)
                    var dt = int(webserver.arg("m_drythr" .. sfx))
                    if dt != nil && dt > 0
                        pl.DryThreshold = dt
                        self.d.Store.set('P' .. s .. 'DryThreshold', dt)
                        print("web_sensor: channel " .. s .. " Dry threshold set to " .. dt)
                    end
                end
                if webserver.has_arg("m_soakdose" .. sfx)
                    var sd = int(webserver.arg("m_soakdose" .. sfx))
                    if sd != nil && sd > 0
                        self.d.Store.set('P' .. s .. 'SoakStartDose', sd)
                        print("web_sensor: channel " .. s .. " Soak start dose set to " .. sd)
                    end
                end
                if webserver.has_arg("m_maxflood" .. sfx)
                    var mf = int(webserver.arg("m_maxflood" .. sfx))
                    if mf != nil && mf > 0
                        pl.MaxFlood = mf
                        self.d.Store.set('P' .. s .. 'MaxFlood', mf)
                        print("web_sensor: channel " .. s .. " Max flood set to " .. mf)
                    end
                end
                if webserver.has_arg("m_c1def" .. sfx)
                    var cd = int(webserver.arg("m_c1def" .. sfx))
                    if cd != nil && cd > 0
                        pl.Counter1FloodDefault = cd
                        self.d.Store.set('P' .. s .. 'Counter1FloodDefault', cd)
                        print("web_sensor: channel " .. s .. " flood dose default set to " .. cd)
                    end
                end
            end
        except .. as e
            print("web_sensor: per-channel settings args failed " .. e)
        end

        # Per-channel accordions: one section per channel, header + per-channel
        # detail rows (dry soak/dry threshold/max/Store snapshot) under its own
        # expansion. Same logic for every channel (see web_soil_detail()).
        for i: 0..(self.d.NumChannels - 1)
            try
                self._soil_section(exp_soil[i], 'soil' + str(i + 1), self.d.plants[i], self.d.SoilSensors[i])
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
            self._flow_section(exp_flow, 'flow', self.d.FlowSensors[0])
        except .. as e
            print("web_sensor: flow1 row failed " .. e)
        end

        # Common detail rows (expanded Common section only): the reset-water-
        # counter action (the main-page button was moved here). The service-mode
        # entry lives on its own /svc page via web_add_main_button().
        # Session/pump state is per-channel and lives in each soil section.
        if exp_flow
            try
                msg = web_kit.wgrp("Сброс") ..
                          web_kit.wrow("Water counter",
                               "<a class='wcbtn' href='#' " .. web_kit.wonclick('if(confirm("Сбросить счётчик воды?")){la("&m_reset_water_counter_1=1");}return false;') .. ">Reset</a>")
                tasmota.web_send_decimal(msg)
            except .. as e
                print("web_sensor: reset counter row failed " .. e)
            end
        end

        #print("web_sensor: processed")

    end
end

# Berry's module() does not auto-collect file-level names (gotcha #13).
web.Web = Web

return web
