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
        for i: 0..(self.d.NumChannels - 1)
            jsp.push("window._wdSec['soil" .. str(i + 1) .. "']=_m.indexOf('" .. str(i + 1) .. "')>=0;")
        end
        jsp.push("window._wdSec.flow=_m.indexOf('c')>=0;")
        jsp.push("window._wdEnc=function(){var s='';")
        for i: 0..(self.d.NumChannels - 1)
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
        jsp.push("var _wdF=[['wds_dry','Soil Dry(Raw)','m_soildry_','dry'],['wds_wet','Soil Wet(Raw)','m_soilwet_','wet'],['wds_thr','Dry threshold(Raw)','m_drythr_','thr'],['wds_dose','Soak start dose (ml)','m_soakdose_','dose'],['wds_maxflood','Max flood (ml)','m_maxflood_','maxflood'],['wds_c1def','Flood dose default (ml)','m_c1def_','c1def']];")
        jsp.push("window._wdSettingsOpen=function(a){")
        jsp.push("if(!window._wdSett){var d=document.createElement('div');d.id='wdsv';var h='<div class=\"box\"><div class=\"hd\"><span>Настройки полива</span><a href=\"#\" onclick=\"_wdSettingsClose();return false;\">✕</a></div><div class=\"bd\">';")
        jsp.push("for(var i=0;i<_wdF.length;i++){h+='<label>'+_wdF[i][1]+' <input id=\"'+_wdF[i][0]+'\" type=\"text\"></label>';}")
        jsp.push("h+='</div><div class=\"ft\"><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsSave();return false;\">Сохранить</a><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsClose();return false;\">Отмена</a></div></div>';d.innerHTML=h;document.body.appendChild(d);window._wdSett=d;}")
        jsp.push("window._wdSett._num=a.getAttribute('data-num');")
        jsp.push("for(var i=0;i<_wdF.length;i++){eb(_wdF[i][0]).value=a.getAttribute('data-'+_wdF[i][3]);}")
        jsp.push("window._wdSett.className+=' open';};")
        jsp.push("window._wdSettingsClose=function(){if(window._wdSett)window._wdSett.className=window._wdSett.className.replace(' open','');};")
        jsp.push("window._wdSettingsSave=function(){var n=window._wdSett._num,q='';")
        jsp.push("for(var i=0;i<_wdF.length;i++){var a=_wdF[i][2].slice(0,-1);if(n>1)a+='_'+n;q+='&'+a+'='+encodeURIComponent(eb(_wdF[i][0]).value);}")
        jsp.push("la(q);window._wdSettingsClose();};")
        jsp.push("}")
        jsp.push("}catch(e){}</script>")
        var js = ""
        for f: jsp js = js .. f end
        webserver.content_send(js)
        # Soil Dry/Wet, Dry threshold, Soak start dose, Max flood and flood dose
        # default forms moved into the per-channel detail popup (see
        # web_soil_detail + _wdSettingsOpen).
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









    def web_soil_detail(pi)
        # Per-channel accordion detail, shared by every soil section: sensor
        # thresholds (Уставки) with the settings button, live sensor values
        # (Датчик), session/pump status, dry soak and the previous/current
        # session stats — everything under one expanded channel. One method
        # owns the whole detail (SoilSensor.web_sensor only emits the header).
        var plant = self.d.plants[pi]
        var num = plant.Num
        try
            var ss = plant.SoilSensor
            var msg = web_kit.wgrp("Уставки")
            msg = msg .. string.format(
                web_kit.wrow("Сухо", "%01.2f raw<br/><span class='stk'>%01.1f%% u</span>") ..
                web_kit.wrow("Влажно", "%01.2f raw<br/><span class='stk'>%01.1f%% u</span>"),
                plant.TargetDry, ss.Raw2Hu(plant.TargetDry),
                plant.TargetWet, ss.Raw2Hu(plant.TargetWet)
                )
            # Per-channel settings button: opens the JS popup with this channel's
            # Soil Dry/Wet, Dry threshold, Soak start dose, Max flood and flood
            # dose default (current values in data-* attrs). Lives in the Уставки
            # group. The popup itself sits in document.body (outside #l1) so it
            # survives the 2.3s polling redraw; see _wdSettingsOpen in
            # web_add_main_button().
            msg = msg .. string.format(
                web_kit.wrow("Настройки порогов",
                     "<a class='wcbtn' data-num='%i' data-dry='%i' data-wet='%i' data-thr='%i' data-dose='%s' data-maxflood='%i' data-c1def='%i' " ..
                     web_kit.wonclick('_wdSettingsOpen(this);return false;') .. ">⚙</a>"),
                num, plant.TargetDry, plant.TargetWet,
                plant.DryThreshold,
                str(int(real(self.d.Store.get(plant.Prefix .. 'SoakStartDose')))),
                int(real(self.d.Store.get(plant.Prefix .. 'MaxFlood'))),
                int(real(self.d.Store.get(plant.Prefix .. 'Counter1FloodDefault'))))
            msg = msg .. web_kit.wgrp("Датчик")
            # Values may be nil until the first sensor Update (unconnected
            # channels). Guard each one: show "nil" instead of crashing the
            # whole section (which would drop the header and make the accordion
            # un-collapsible).
            var rawv = ss.Raw != nil ? str(ss.Raw) : "nil"
            var rawema = ss.RawEma != nil ? string.format("%01.4f", ss.RawEma) : "nil"
            var hu = ss.RawEma != nil ? string.format("%01.1f%%", ss.Raw2Hu(ss.RawEma)) : "nil"
            var mv = ss.Raw != nil ? string.format("%01.1f mV", ss.Raw2mV(ss.Raw)) : "nil"
            msg = msg .. string.format(
                web_kit.wrow("Raw", "%s") .. web_kit.wrow("Raw EMA(%i)", "%s"),
                rawv, ss.EMAN, rawema)
            msg = msg .. string.format(
                web_kit.wrow("Hymidity u", "%s") .. web_kit.wrow("mV", "%s"),
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
                var rate = self.d.FlowSensors[0].Rate
                if rate != nil
                    pump = pump .. " " .. string.format("%01.1f", rate * 60) .. " ml/min"
                end
            end
            msg = string.format(
                      web_kit.wgrp("Сеанс") .. web_kit.wrow("Сеанс полива", "%s") .. web_kit.wrow("Вода", "%s"),
                      sess, pump)
            tasmota.web_send_decimal(msg)
            msg = string.format(
                      web_kit.wgrp("Размачивание") .. web_kit.wrow("Dry soak", "%s") .. web_kit.wrow("Dry threshold", "%i"),
                      dry_status, plant.DryThreshold)
            tasmota.web_send_decimal(msg)
            msg = web_kit.wgrp("Текущий сеанс")
            if plant.SoilMaxHymidity != nil
                msg += string.format(
                        web_kit.wrow("SoilHymidity" .. str(num) .. " max", "%i"),
                        plant.SoilMaxHymidity)
                if plant.SoilMaxHymidityTime != nil
                    msg += string.format(
                            web_kit.wrow("SoilHymidity" .. str(num) .. " max time", "%s"),
                            self._TimeStr(plant.SoilMaxHymidityTime))
                end
            end
            msg += string.format(
                    web_kit.wrow("LastFloodVol (мл)", "%i") .. web_kit.wrow("SoilHPreFlood", "%s"),
                    int(plant.LastFloodVol), str(plant.SoilHPreFlood))
            tasmota.web_send_decimal(msg)
            msg = web_kit.wgrp("Предыдущий сеанс")
            import introspect
            for k: ['PrevFloodedVol', 'PrevSoilHPreFlood', 'PrevSoilMaxHymidity']
                msg += string.format(
                          web_kit.wrow("%s", "%s"),
                          k, str(introspect.get(plant, k)))
            end
            tasmota.web_send_decimal(msg)
            # Last fill per channel: date + average flow rate. Persisted as
            # P{Num}LastFloodTime / P{Num}LastFlowRate (see _record_flood), so
            # the group survives a reboot. Emitted only when a fill has been
            # recorded (LastFloodTime set).
            if plant.LastFloodTime != nil
                msg = web_kit.wgrp("Последний полив")
                msg += string.format(web_kit.wrow("Last flood time", "%s"), self._TimeStr(plant.LastFloodTime))
                if plant.LastFlowRate != nil
                    msg += string.format(web_kit.wrow("Last flow rate", "%01.1f мл/мин"), plant.LastFlowRate)
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
                self.d.SoilSensors[i].web_sensor(exp_soil[i], 'soil' + str(i + 1), self.d.plants[i])
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
            self.d.FlowSensors[0].web_sensor(exp_flow, 'flow')
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
                          web_kit.wgrp("Сброс") ..
                          web_kit.wrow("Water counter",
                               "<a class='wcbtn' href='#' " .. web_kit.wonclick('if(confirm("Сбросить счётчик воды?")){la("&m_reset_water_counter_1=1");}return false;') .. ">Reset</a>"))
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
