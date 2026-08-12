# 📘 Berry Script for Tasmota v15.3.0 - AI Context & Reference
> Версия прошивки: Tasmota v15.3.0 (Susan)
> Язык: Berry (ultra-lightweight embedded scripting)
> Цель: Генерация валидного, безопасного и эффективного кода для IoT-контроллеров

---

## ⛔ STRICT RULES (НЕ ИГНОРИРОВАТЬ)
1. **НЕТ внешних библиотек**: `import` разрешен только для встроенных модулей Tasmota: `string`, `json`, `math`, `path`, `persist`, `mqtt`, `gpio`, `webserver`, `sys`, `introspect`, `strict`, `undefined` и др. Никаких `requests`, `time`, `os` и т.д.
2. **НЕТ async/await или потоков**: Только callback-стиль и таймеры.
3. **НЕ блокируйте главный цикл**: `tasmota.delay()` блокирует весь Tasmota. Для задержек используйте `tasmota.set_timer()`.
4. **Ограничение памяти**: ~64 КБ на скрипт. Избегайте больших строк, вложенных структур и бесконечных массивов.
5. **Типы данных**: Berry динамически типизирован, но строго относится к `nil`. Всегда проверяйте `!= nil` перед использованием результатов I2C/HTTP/MQTT.
6. **Команды консоли**: Все кастомные команды ДОЛЖНЫ вызывать `tasmota.resp_cmnd_*()` для завершения.
7. **Неиспользуемый код**: Если проблема вызвана неиспользуемым (мёртвым) кодом — не удаляйте его без явного разрешения. Сначала спросите пользователя. Обращайте внимание на классы/функции, которые нигде не инстанцируются и не вызываются.

---

## 📦 CORE API REFERENCE

### `tasmota` object (System & Hardware)
| Метод | Описание |
|-------|----------|
| `tasmota.delay(ms)` | Блокирующая задержка (использовать только в инициализации) |
| `tasmota.set_timer(ms, callback_fn)` | Неблокирующий таймер. `callback_fn` вызывается через `ms` миллисекунд (разрешение ~50 мс) |
| `tasmota.set_power(idx, onoff)` | Управление реле: `idx` (0-based), `onoff` (boolean `true`/`false`) |
| `tasmota.get_power()` | Возвращает список boolean-состояний всех реле/света; с аргументом `get_power(idx)` — состояние одного канала |
| `tasmota.add_cmd('CmdName', func_ref)` | Регистрация команды консоли. Сигнатура: `def func(cmd, idx, payload, payload_json)` (все аргументы опциональны) |
| `tasmota.resp_cmnd_done()` | Ответ "Done" в консоль |
| `tasmota.resp_cmnd_error()` | Ответ "Error" |
| `tasmota.resp_cmnd_failed()` | Ответ "Fail" |
| `tasmota.resp_cmnd_str(msg)` | Ответ произвольной строкой |
| `tasmota.resp_cmnd(json_str)` | Ответ, переопределяющий весь ответ команды. Принимает **строку** с валидным JSON |
| `mqtt.publish(topic, payload, retain)` | Публикация в MQTT (через `import mqtt`). `retain`: boolean; `tasmota.publish()` устарел |
| `persist` (`import persist`) | Персистентность в `_persist.json` (один общий файл для всех скриптов). API: `persist.key = val`, `persist.save()`, `persist.dirty()`(пометить как изменённый), `persist.has(key)`, `persist.find(key, dflt)`, `persist.member(key)`, `persist.remove(key)`, `persist.zero()`. **НЕ** `save_data`/`load_data`. Подробности и ловушки см. секцию below |
| `tasmota.gc()` | Принудительная сборка мусора. Возвращает `int` (выделено байт); только для отладки |

### `persist` module — ЛОВУШКИ (КЛЮЧЕВЫЕ ФАКТЫ)
1. **ПОЧТИ СИНГЛТОН, НО НЕ ВСЕГДА**: `import persist` в пределах одного скрипт-файла кэшируется → один экземпляр. **Разные скрипт-файлы (autoexec.be, watering.be, watering_ui.be) получают отдельные экземпляры** (внутри `persist.be` `init` возвращает новый `Persist()`). Все экземпляры читают/пишут один и тот же `_persist.json`, но синхронизации между ними НЕТ.
2. **`save()` перезаписывает файл ЦЕЛИКОМ** из памяти своего экземпляра. Данные, которых нет в этом экземпляре (например, записанные другим скриптом или вручную в файл), **будут затёрты**.
3. **Ручное редактирование `_persist.json` «на лету» НЕ надёжно**: работает только если скрипт перезагружен ПОСЛЕ правки и больше не вызывал `save()` из экземпляра, не знающего этих ключей.
4. **`save()` — запись во Flash, wear-out**: не вызывать часто (не в циклах, не каждый тик `every_second`). Сначала несколько `introspect.set(persist, k, v)` / `persist.key = v`, затем ОДИН `persist.save()`. В реальном `persist.be` `save()` пишет только если `_dirty` (после `setmember`) или передан `force_save=true` / вызван `persist.dirty()`.
5. **Рекомендация**: держать ОДИН `import persist` на верхнем уровне скрипта и использовать его во всех функциях (не импортировать повторно внутри функций).
6. **Калибровка Dry/Wet (проект irrigation)**: `SoilSensor.setmember('Dry'/'Wet')` (watering.be) теперь пишет `TargetDry`/`TargetWet` в persist и вызывает `save()`. В `init()` эти ключи читаются как **RAW-значения** (`int(persist.find("TargetDry","800"))`), а `setmember` принимает **процент влажности** и конвертирует через `Hymidity2Raw()`. Т.е. в файле хранится RAW, в setter передаётся %.
7. **`auto_flood`**: prev-статы (`PrevSoil*`, `PrevFloodedVol`) и estimate-входы (`SoilHPreFlood`/`LastFloodVol`/`SoilMaxHymidity`) пишутся ОДНОЙ партией через `self._persist_batch([...], self)` — цикл `introspect.set` + ОДИН `persist.save()` (7 ключей за один save, не 7 записей). `_persist_batch(keys, source)` у `Watering` читает значения из `source` (по умолчанию `self`) и делает один `save()`; применён в `auto_flood`, `every_second` (подтверждение SoilMaxHymidity, 2 ключа).
8. **Команда `counter1` (Tasmota)**: положительное число без знака (`counter1 500`) = PRESET (перезапись абсолютного значения); `counter1 0` = reset; `-n` = вычесть; `+n` = добавить. Форма `counter1??` (с `??`) — НЕ команда: это консольный суффикс группового применения, в справочнике команд не документирована. `_compensate_backflow()` использует preset-форму для коррекции счётчика после pump stop.
8. **Для тестов (stub persist)**: persist обязан быть **классом с виртуальными `member`/`setmember`** (`class Persist ... end; var persist = Persist()`), а не module-instance. Только так `introspect.set(persist, k, v)` реально попадает в внутренний map (module-instance не даёт virtual setters — `introspect.set` молча не пишет).

### `webserver` object (Web UI)
| Метод | Описание |
|-------|----------|
| `webserver.has_arg(name)` | Проверка наличия GET-параметра (возвращает `bool`) |
| `webserver.arg(name)` | Получение значения параметра (по имени или по индексу `0..arg_size()-1`) |
| `webserver.arg_size()` | Количество аргументов в запросе |
| `webserver.content_send(html)` | Отправка HTML в ответ веб-сервера |
| `webserver.content_open(http_code, mimetype)` | Установка HTTP-кода и MIME-типа ответа (нет `send_content_type`) |

### 🔑 Web UI Тасmota 14 — МЕХАНИКА ГЛАВНОЙ СТРАНИЦЫ (обнаружена на практике)
1. **Главная страница — «оболочка»**: таблица сенсоров на `/` НЕ рендерится статически. JS-функция `la(argString)` делает асинхронный XHR `GET .?m=1&<args>` и заменяет содержимое `l1`. Хук `web_sensor()` запускается именно на этом `.?m=1`-запросе, а не на обычном `GET /`.
2. **`web_add_main_button()`/`web_add_config_button()` рендерятся в статическую часть `/`** — их видно сразу; а строки `web_sensor()` появляются только после JS-«догрузки».
3. **Форма `<form method='get' action='/'>` с `m_`-инпутами НЕ доставляет аргументы в `web_sensor()`** — наблюдалось, что запрос без `m=1` не обрабатывается (значение не применялось). Рабочий способ — кнопка с `onclick='la("&m_key=value")'`: она дёргает `.?m=1&m_key=value`, и `web_sensor()` видит `webserver.has_arg("m_key")`.
4. **Паттерн для редактируемых полей**: инпуты с `id` + кнопка, собирающая строку из значений: `onclick='la("&m_soildry="+eb("soil_dry").value+"&m_soilwet="+eb("soil_wet").value)'`. Хелперы на странице: `eb(id)` = `document.getElementById`, `qs(sel)` = `querySelector`.
5. **Проверено**: `GET .?m=1&m_soildry=850` применяет порог (в логе `web_sensor: Soil Dry threshold set to 850`); `GET /?m_soildry=850` (без `m=1`) — нет.
6. **Прямой вызов `wp1.web_sensor()` из berry-консоли работает** и отдаёт полные строки; диспетчер `callBerryEventDispatcher` вызывает метод драйвера с 4 аргументами — в Berry это безвредно для методов без параметров.
7. **`Tasmota CSS` растягивает `input`/`button` на `width:100%`** (поля в столбик). Для одной строки — обёртка `<div style='display:flex;flex-wrap:wrap;gap:4px;align-items:center'>` + `style='width:auto'` на кнопке и `style='width:5em'` на инпутах.

### ⚡ Компактный/Detail-режим `web_sensor()` и кэш `_TimeStr()` (защита от LoadAvg)
1. **Проблема**: `web_sensor()` выполняется на КАЖДЫЙ `.?m=1`-запрос (при открытой странице — раз в секунду). Тяжёлые `string.format` (13 вызовов на сенсор) + `tasmota.strftime()` → заметный LoadAvg на ESP32 (~67/200 при открытой странице).
2. **Компактный по умолчанию**: `SoilSensor.web_sensor(detail)`/`FlowSensor.web_sensor(detail)` — при `detail=false` отдают 1 ряд за сенсор: soil → `Raw EMA(N)` + `Hymidity` (Raw и пороги скрыты), flow → только `Water used`. `Watering.web_sensor()` передаёт `self.DetailView`. Измерено на устройстве: compact 21-23 ряда, detail 33.
3. **Тумблер**: кнопка в `web_add_main_button()` шлёт `&m_detail=2`, обработчик в `web_sensor()` трактует `"1"`/`"0"` как явную установку, **любое другое значение — переключение** (`self.DetailView = !self.DetailView`). Флаг `DetailView` живёт в объекте `wp1` → переживает 1-секундный авто-refresh.
4. **Кнопка без релоада**: HTML в `web_add_main_button()` рендерится ОДИН раз при `GET /`, поэтому надпись не обновляется сама. Решение — JS-флип в `onclick` ПЕРЕД `la()`: `this.innerHTML=(this.innerHTML.indexOf("Compact view")>=0)?"Detail view":"Compact view";la("&m_detail=2");`. Надпись = действие по следующему клику, не текущее состояние.
5. **Кэш дат**: `_TimeStr(ts)` кэширует `tasmota.strftime("%d %B %H:%M", ts)` в `self.TimeCache[key/value]`, пересчитывает только при смене таймстампа. Вызывается из `web_sensor()` (строки «Last flood time» и «SoilHymidity1 max time») вместо прямого `strftime` — убирает до 2 тяжёлых вызовов в секунду. Тесты проходят с любым форматом: stub `tasmota.strftime` возвращает фиксированную строку.
6. **Проверено**: `string.format("%s", nil)` даёт `"nil"`, `%i`/`%01.4f` с `nil` — пустую строку (без краха) — поэтому компактные ветки безопасны при `RawEma==nil` (см. тест 25_web_guard).

### `wire` object (I2C)
| Метод | Описание |
|-------|----------|
| `tasmota.wire_scan(addr, idx)` | Поиск устройства (объекты `wire1`/`wire2` для двух шин). Возвращает `wire` объект или `nil`. `idx` = индекс устройства |
| `wire.read(addr, reg, size)` | Читает значение `size` (1..4) байт из регистра `reg`. Возвращает `int` или `nil` |
| `wire.read_bytes(addr, reg, size)` | Читает последовательность `size` байт, возвращает `bytes()` |
| `wire.write(addr, reg, val, size)` | Записывает значение `val` (1..4 байт) в регистр `reg`. Возвращает `bool` |
| `wire.write_bytes(addr, reg, val)` | Записывает `bytes()` val в регистр `reg` |
| `wire.bus` | Номер шины I2C (1 или 2), read-only атрибут |

### `path` object (Files)
| Метод | Описание |
|-------|----------|
| `path.listdir("dir")` | Список файлов в директории |
| `path.listdir("archive.tapp#")` | v15.3.0+: Список файлов внутри `.tapp` архива |

### `.bec` (Bytecode) — МЕХАНИКА ЗАГРУЗКИ (v13.4.0.3+)
1. **До v13.4.0.3** `load()` автоматически компилировал `.be` в байткод и **сохранял `.bec` рядом** (аналог `.py`/`.pyc`).
2. **С v13.4.0.3** автосоздание `.bec` **убранo**: при `load("x.be")` приоритет у исходника `.be`, а существующий `x.bec` **удаляется** (защита от рассинхронизации версий).
3. **`load("x.bec")`** грузит только байткод (`.be` игнорируется); если `.be` нет — `load("x.be")` пробует `x.bec`.
4. **Создать `.bec`** можно только явно: `tasmota.compile("x.be")` → `true` + создаёт `x.bec`.
5. **На практике (v14/v15)**: `.bec`-файлы в ФС не появляются при обычном `load()` из `autoexec.be` — это нормальное поведение, НЕ ошибка.

---

## 💡 SYNTAX & PATTERNS (Few-Shot Examples)

### ✅ Correct: Custom Command Registration
```berry
def my_cmd(cmd, idx, payload, json_payload)
  var state = true if payload == "on" else false
  tasmota.set_power(idx, state)
  tasmota.resp_cmnd_done()
end

tasmota.add_cmd('SetMyRelay', my_cmd)
```

### 🐛 Berry GOTCHAS (обнаружены на практике)
1. `true`/`false` — **строчными буквами** (не `True`/`False`).
2. У `map` НЕТ `.has()` — проверять через `.find(k) != nil` (у list есть `.has()`).
3. `introspect.set(obj, k, v)` вызывает виртуальный `setmember` только у **class-instance**; module-instance — молча игнорирует (пишет/не пишет в память незаметно).
4. `string.find()` возвращает **индекс или -1** (нет `.has()`/`.contains()`); `string.split()` есть; `string.len`/`string.mid` отсутствуют — длина строки через `size(s)`, преобразование в строку через `str(x)` (не `string(x)` — у module `string` нет конструктора).
5. `list.push(...)` — добавление; `size(list)` — длина.
6. `try ... except .. as e, m ... end` — правильная защищенная конструкция. Синтаксис: **`..` (две точки)** ставится между `except` и `as`, т.е. `except .. as e` (перехват без переменной — краткая форма) или `except .. as e, m` (e — текст, m — стек-трейс). Без `..` нельзя писать `except e` — это `syntax_error` (`'e' undeclared`).
7. **ВАЖНО (Berry 1.1.0):** голый `except` (без `.. as var`) — НЕ гасит исключение. Тело `except` выполняется и print/log пишутся, но исключение всё равно пробрасывается выше: печатается `stack traceback`, `rc≠0`, дальнейший код не исполняется. Для реальной защиты используйте **только `except .. as e`** (или `.. as e, m`).
8. **Сборка для тестов — stock Berry v1.1.0** (не Tasmota-патч). Отличия, критичные для кода: (a) `introspect.setmodule` отсутствует — persist-стаб это файл-модуль `tests/modules/persist.be` (class-instance); (b) `string.format('%d', 'строка')` даёт **пусто**, а не число — для команды счётчика обязателен `%s` (`Reset()`, watering.be:253).
9. **`import string` — скоуп инструкции, НЕ глобальный**: `import string` внутри одной функции/метода доступен только там. Если вынесли код с `string.format()` в отдельный метод — добавьте `import string` в него (пример: `_compensate_backflow()` после рефакторинга из `rule_power`, watering.be:519). **ВАЖНО**: в тестовом окружении `string` доступен глобально (часть harness-стаба), поэтому на устройстве вылезает `syntax_error: 'string' undeclared (first use in this function)`, а тесты зелёные. Всегда проверять реальным `make deploy`.

---

## 📐 SoilSensor & EMA (проект irrigation) — ТЕКУЩЕЕ СОСТОЯНИЕ
- **`watering_ui.be` — рудимент**: незавершённая попытка вынести web-интерфейс в отдельный модуль. Не используется, в пуш/поддержку не входит, не развивать.
- **Все актуальные расчёты идут в RAW отсчётах ADC** (сырые `Raw`/`RawEma`; пороги `RawDry`/`RawWet`). Калибровки в % (`Hymidity`) и мВ (`mV`/`Hu`) — **недоделаны, не трогать**.
- **Пороги**: `RawDry=800`, `RawWet=750`; линейная шкала по двум точкам `setScale(842, 1105)`.
- **Пороги редактируются** (RAW, не %): команды `SoilDry`/`SoilWet` (persist `TargetDry`/`TargetWet`, один `save()`) и веб-форма на главной странице (`m_soildry`/`m_soilwet`, id `soil_dry`/`soil_wet`). **Валидация**: разрыв `|RawDry - RawWet|` должен быть **строго > 20**, иначе значение не применяется (отвергается). Реализация: `SoilSensor.SetDry(raw)`/`SetWet(raw)` возвращают `bool`.
- **EMA** (`EMAN=600`): `k=2/(N+1)`, `RawEma_new = RawEma_old*(1-k) + Raw*k`; инициализация `RawEma = Raw` при первом тике. Функция `EMA()` в начале watering.be.
- **Наблюдаемый артефакт (приемлемый)**: в InfluxDB кривая EMA огибает кривую RAW СВЕРХУ со смещением +1..+2. Возможные причины: округления, дискретность отчётов (раз в 5 мин попадает на заниженное значение), помехи питания. **Пользователя смещение устраивает — не оптимизировать, не «чинить».**
- ADC: `Raw2mVScale` из делителя 30k/30k (≈1.197 mV/source), полином `Hu_C` — недоделка.

### 🔄 FSM автополива (event-driven) — КРАТКОЕ РЕЗЮМЕ
- **Планировщик**: `auto_flood()` по cron (часы 14–01) — если `IsDry()` и не идёт сессия → сохраняет Prev*-статистику + estimate-входы одной партией (`_persist_batch`), считает дозу `planned_dose()` (= `estimateflood()` при валидной оценке, иначе `Counter1FloodDefault`), инициализирует сессию, `Power1 1`.
- **Старт** (`rule_power(ON)`): защита от запуска на мокрой почве (`IsWet()` → `Power1 0`), TelePeriod 10, `FinishRule = COUNTER#C1 >= before+backflow+доза`, `RateMeasuring=true`.
- **Лимит** (`rule_flooded`): превышен счётчик → `Power1 0`.
- **Стоп** (`rule_power(OFF)`): хелпер `_compensate_backflow(Counter1)` — вычитает backflow из счётчика (preset `counter1`) и из дельты, возвращает нетто; `_record_flood(CounterDelta)` — `LastFloodVol += delta`, задержка проверки 2ч (24ч при `LastFloodVol > MaxFlood/2`) + таймер `timer_soil_transition_after_flooded`; при `CounterDelta==0` вместо него `_end_session_no_water()` (закрывает сессию без проверки почвы). Затем таймер возврата TelePeriod 300 через 60с.
- **Проверка результата** (`timer_soil_transition_after_flooded`, через 2ч/24ч): земля всё ещё сухая → `Counter1FloodDefault × 1.2` (cap `MaxFlood`) и повторный полив; иначе `_autoflood_end()`.
- **Завершение** (`_autoflood_end`): сброс флагов, опциональный отложенный сброс счётчика (`Counter1ResetPostpone`), `PauseSoilMaxStat=false`.
- **Фон** (`every_second`, 1/с): `read_sensors` → Update сенсоров; трекинг минимума `SoilMaxHymidity` (кроме периода `PauseSoilMaxStat`), подтверждение после роста +5 — через `_persist_batch(['SoilMaxHymidity','SoilMaxHymidityTime'])` (один save).
- **Полная блоксхема**: `docs/irrigation_fsm.md` (mermaid + таблица методов/флагов + цикл самокоррекции). Обновлять её при изменении FSM-логики в `watering.be`.