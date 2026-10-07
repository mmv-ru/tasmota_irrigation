import strict
import string

var web_kit = module('web_kit')

# web_kit — слой «как делается HTML». Здесь оформление интерфейса:
# именованные сниппеты строк, CSS и JS главной страницы и функции-словарь,
# собирающие логические элементы (строка, группа, бейдж, иконка, шапка
# аккордеона). О том, ЧТО интерфейс содержит, рассказывает web.be (модель +
# интерпретатор): web_kit не знает о домене (plant/sensor/store) — принимает
# строки и числа, отдаёт HTML.

# --- HTML-сниппеты ----------------------------------------------------------
# Один шаблон — одна повторяющаяся структура вывода. Уникальные оболочки
# (JS-попап настройки, формы /svc) сюда НЕ разбираются: их читаемость от
# дробления на куски не выигрывает.
var T_ROW  = "<tr class='sub'><th>%s</th><td>%s</td></tr>"
var T_GRP  = "<tr class='grp'><td colspan='2'>%s</td></tr>"
var T_PILL = "<span class='pill'><b>%s</b> %s</span>"
var T_ICON = "<span class='st %s' %s>%s</span>"
var T_HEAD = "<tr class='sec'><th class='hdr' %s>%s</th>" ..
             "<td class='tgl'><a class='chev' href='#' %s>%s</a></td></tr>"
var T_STK  = "<br/><span class='stk'>%s</span>"

# --- CSS --------------------------------------------------------------------
# Правила по одному на строку, блок собирается ОДИН РАЗ при загрузке модуля
# (раньше пересобирался на каждый рендер главной страницы). Палитра живёт в
# CSS-переменных (:root) — перекраска в одну строку. Блок уходит в #l1 как
# есть: la() переписывает только {s}/{m}/{e}, остальное проходит verbatim.
var css_lines = [
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
var css = ""
for c: css_lines css = css + c end
css_lines = nil

# --- JS ---------------------------------------------------------------------
# Скрипт главной страницы. Состояние раскрытия секций живёт в URL браузера
# (me=12c, 1..9 = каналы, c = Common); оба обхода каналов — в самом JS
# (for i=1..N): Berry больше не собирает строку push'ами на каждый рендер.
# @N@ подставляет main_js() (число каналов).
var js_lines = [
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
      "for(var i=1;i<=@N@;i++){window._wdSec['soil'+i]=_m.indexOf(''+i)>=0;}",
    "window._wdSec.flow=_m.indexOf('c')>=0;",
    "window._wdEnc=function(){var s='';",
      "for(var i=1;i<=@N@;i++){if(window._wdSec['soil'+i])s+=i;}",
    "if(window._wdSec.flow)s+='c';return s;};",
    "var _la0=window.la;",
    "window.la=function(p){var np=p||'';",
    "if(np.indexOf('me=')===-1){np+='&me='+window._wdEnc();}",
    "_la0(np);};",
    "window._secToggle=function(name){",
    "window._wdSec[name]=!window._wdSec[name];",
    "var u='?me='+window._wdEnc();",
    "try{history.replaceState(null,'',u);}catch(e){}",
    "la('');};",
    "window._wdTT=null;",
    "window._wdShowTT=function(ic,ev){if(ev&&ev.stopPropagation)ev.stopPropagation();var t=window._wdTT;",
    "if(t&&t.style.display!=='none'){t.style.display='none';return;}",
    "if(!t){t=document.createElement('div');t.id='wdtt';document.body.appendChild(t);window._wdTT=t;}",
    "var cls=ic.className.indexOf('run')>=0?'run':ic.className.indexOf('sess')>=0?'sess':'wait';",
    "var R=[['wait','Ожидание'],['sess','Сеанс полива'],['run','Работа насоса']];",
    "var h='';for(var i=0;i<3;i++){var s=R[i][0];",
    "var ic2=s=='wait'?'<span class=\"ttdrop\">💧</span>':(s=='sess'?'⏳':'💦');",
    "h+='<div class=\"ttrow'+(s==cls?' cur':'')+'\"><span class=\"ttmark\">'+(s==cls?'→':'')+'</span><span class=\"ttic\">'+ic2+'</span><span>'+R[i][1]+'</span></div>';}",
    "t.innerHTML=h;t.style.display='block';",
    "var r=ic.getBoundingClientRect();var tw=t.offsetWidth;",
    "var x=r.left-tw-8;if(x<4)x=r.right+8;var y=r.top+r.height/2-t.offsetHeight/2;if(y<4)y=r.top+8;",
    "t.style.left=x+'px';t.style.top=y+'px';};",
    "document.addEventListener('click',function(e){if(window._wdTT&&window._wdTT.style.display!=='none'){if(!e.target.closest('.st')&&!e.target.closest('#wdtt'))window._wdTT.style.display='none';}},true);",
    "window._wdSett=null;",
    "var _wdF=[['wds_dry','Soil Dry(Raw)','m_soildry_','dry'],['wds_wet','Soil Wet(Raw)','m_soilwet_','wet'],['wds_thr','Dry threshold(Raw)','m_drythr_','thr'],['wds_dose','Soak start dose (ml)','m_soakdose_','dose'],['wds_maxflood','Max flood (ml)','m_maxflood_','maxflood'],['wds_c1def','Flood dose default (ml)','m_c1def_','c1def']];",
    "window._wdSettingsOpen=function(a){",
    "if(!window._wdSett){var d=document.createElement('div');d.id='wdsv';var h='<div class=\"box\"><div class=\"hd\"><span>Настройки полива</span><a href=\"#\" onclick=\"_wdSettingsClose();return false;\">✕</a></div><div class=\"bd\">';",
    "for(var i=0;i<_wdF.length;i++){h+='<label>'+_wdF[i][1]+' <input id=\"'+_wdF[i][0]+'\" type=\"text\"></label>';}",
    "h+='</div><div class=\"ft\"><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsSave();return false;\">Сохранить</a><a class=\"wcbtn\" href=\"#\" onclick=\"_wdSettingsClose();return false;\">Отмена</a></div></div>';d.innerHTML=h;document.body.appendChild(d);window._wdSett=d;}",
    "window._wdSett._num=a.getAttribute('data-num');",
    "for(var i=0;i<_wdF.length;i++){eb(_wdF[i][0]).value=a.getAttribute('data-'+_wdF[i][3]);}",
    "window._wdSett.className+=' open';};",
    "window._wdSettingsClose=function(){if(window._wdSett)window._wdSett.className=window._wdSett.className.replace(' open','');};",
    "window._wdSettingsSave=function(){var n=window._wdSett._num,q='';",
    "for(var i=0;i<_wdF.length;i++){var a=_wdF[i][2].slice(0,-1);if(n>1)a+='_'+n;q+='&'+a+'='+encodeURIComponent(eb(_wdF[i][0]).value);}",
    "la(q);window._wdSettingsClose();};",
    "}",
    "}catch(e){}</script>",
]
var JS_TPL = ""
for f: js_lines JS_TPL = JS_TPL + f end
js_lines = nil
var js_cache = nil

def main_js(n)
    # N не меняется без перезагрузки модуля (Channels перестраиваются на
    # старте устройства), поэтому шаблон одноразовый: после первой сборки
    # копия @N@ освобождается, дальше страница отдаёт кэш.
    if js_cache == nil
        js_cache = string.replace(JS_TPL, "@N@", str(n))
        JS_TPL = nil
    end
    return js_cache
end

# --- функции-словарь ---------------------------------------------------------
# Логические элементы интерфейса. Сигнатуры wrow/wgrp/wonclick/wtoggle/wpill
# исторические и не меняются (прямые вызовы в web.be).

def wrow(label, value)
    # Строка-параметр: метка + значение (значение может содержать стек шкал).
    return string.format(T_ROW, label, value)
end

def wgrp(label)
    # Заголовок секции (группа).
    return string.format(T_GRP, label)
end

def wparam_stack(label, scales)
    # Параметр с одним или более «масштабами» вывода: первая шкала — значение
    # строки, остальные — подстроки .stk под ним (сырое значение + %, импульсы
    # + мл/мин и т.п.).
    var v = scales[0]
    if size(scales) > 1
        for i: 1..(size(scales) - 1)
            v = v .. string.format(T_STK, scales[i])
        end
    end
    return string.format(T_ROW, label, v)
end

def wonclick(js)
    # onclick-атрибут с правилом одинарных кавычек: значение атрибута в
    # одинарных кавычках, JS внутри может свободно использовать двойные —
    # без ручной аудитации экранирования в каждой точке вызова.
    return "onclick='" .. js .. "'"
end

def wtoggle(sec)
    # onclick раскрытия секции (шапка и шеврон делят один _secToggle-вызов).
    return wonclick('_secToggle("' .. sec .. '");return false;')
end

def wpill(label, value)
    # Бейдж в шапке секции (raw / сухо / влажно).
    return string.format(T_PILL, label, value)
end

def wsec_icon(cls, glyph)
    # Иконка состояния в шапке секции; клик открывает легенду (#wdtt).
    return string.format(T_ICON, cls, wonclick('_wdShowTT(this,event)'), glyph)
end

def wsec_head(sec, icon_html, name, params_html, expanded)
    # Шапка аккордеона: иконка состояния, имя, блок бейджей params_html
    # ("" — без span.params), шеврон ▲/▼. Атрибут toggle в шаблоне двойной —
    # считается один раз.
    var tg = wtoggle(sec)
    var inner = icon_html .. name
    if params_html != ""
        inner = inner .. "<span class='params'>" .. params_html .. "</span>"
    end
    return string.format(T_HEAD, tg, inner, tg, expanded ? "▲" : "▼")
end

# Berry module() не собирает имена файла автоматически (gotcha #13), поэтому
# всё публикуем явно.
web_kit.css = css
web_kit.main_js = main_js
web_kit.wrow = wrow
web_kit.wgrp = wgrp
web_kit.wparam_stack = wparam_stack
web_kit.wonclick = wonclick
web_kit.wtoggle = wtoggle
web_kit.wpill = wpill
web_kit.wsec_icon = wsec_icon
web_kit.wsec_head = wsec_head

return web_kit
