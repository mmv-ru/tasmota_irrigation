# Тесты watering.be

Характеризационные тесты логики полива. Запускаются на **локальном интерпретаторе Berry** (без железа), Tasmota-API эмулируется стабом. Цель — зафиксировать текущее поведение (`rule_power`, `auto_flood`, таймеры) до будущего рефакторинга: если после правок тесты станут красными — поведение изменилось.

Актуальный набор покрывает **итерацию 2 (многоканальность)**: `Watering`-диспетчер + `Plant` на канал (свой насос `Power{Num}`, per-channel persist `P{Num}_*`, сериализация общего счётчика C1). Сводка на текущий момент: **500 PASS / 0 FAIL** (кейсы 00–40).

## Как запустить

```sh
bash tests/setup_berry.sh                 # развернуть Berry VM с зафиксированной версией (один раз)
python3 tests/run_all.py                  # все тесты (бинарь ищется в PATH, ~/.local/bin, $BERRY_BIN)
python3 tests/run_all.py /path/to/berry   # указать бинарник berry явно
python3 tests/build.py tests/cases/10_rule_power_on.be  # один тест
```

Требуется собранный бинарник Berry (см. ниже). Никаких зависимостей Python — только файлы в `tests/`.

## Развёртывание (процедура с зафиксированными версиями)

Бинарь Berry **не живёт в `/tmp`** (теряется при каждом ребуте) и **не кэшируется** где-то ещё. Среда разворачивается скриптом `tests/setup_berry.sh`, который сам клонирует и собирает **пиннённую версию**:

| Зависимость | Версия | Где зафиксировано |
|-------------|--------|-------------------|
| Berry VM | `v1.1.0` (тег, коммит `b5ede66`) | `tests/setup_berry.sh` (`BERRY_REF`) |
| Сборка | Makefile репо + `gcc` + `libreadline` (cmake НЕ нужен для v1.1.0) | `tests/setup_berry.sh` |
| Python | `>= 3.10` | `tests/build.py`, `tests/run_all.py` |

```
bash tests/setup_berry.sh
# -> исходники:  ~/.local/src/berry
# -> бинарь:     ~/.local/bin/berry
```

Тестеры (`run_all.py`/`build.py`) ищут бинарь в порядке: **аргумент командной строки > `$BERRY_BIN` > `PATH` > `~/.local/bin/berry`**. Настрой `PATH` (например `export PATH="$HOME/.local/bin:$PATH"` в `~/.bashrc`).

### Важно о stock Berry vs Tasmota-патч

Это **stock Berry 1.1.0**, а не Tasmota-сборка. Реальные отличия, зафиксированные тестами:

- `introspect.setmodule()` в stock **отсутствует**; persist подменяется файлом-модулем `tests/modules/persist.be` (класс-инстанс, как реальный persist).
- `string.format('%d', '1')` (строка) в stock даёт **пусто**, в Tasmota-патче — `'1'`. Поэтому `FlowSensor.Reset()` использует `%s`, а не `%d` (watering.be:253).
- `string.format('%i'/…` поведение идентично Tasmota по остальным тестам.

## Структура

| Путь | Что это |
|------|---------|
| `tests/harness_header.be` | Преамбула: фреймворк ассертов + стабы Tasmota. Вклеивается в начало каждого теста |
| `tests/modules/*.be` | Модули-стабы (`webserver`, `strict`, `undefined`, `webclient`, `persist`) — их видит `import` |
| `tests/cases/NN_*.be` | Тест-кейсы |
| `tests/build.py` | Склейка: `header + watering.be + case` → `tests/out/combined.be`, запуск berry |
| `tests/run_all.py` | Прогон всех кейсов и сводка |
| `tests/out/` | Сгенерировано, в гит не входит |

## Как писать тест-кейс

Кейс — это дробный Berry-скрипт, который исполняется **после** загрузки `watering.be`. В нём доступны:

### Ассерты (из header)

```berry
assert_true(boolean_value, "описание")        # положить boolean
assert_eq(actual, expected, "описание")       # сравнить значения (str-эквивалентно)
section("имя_секции")                          # разделитель вывода
```

При провале выводится `FAIL:` и считается счётчик; в конце каждого кейса не требуется итог — `run_all.py` считает `PASS:`/`FAIL:` сам.

### Управление симулятором

Глобальный объект `SIM` — модель Tasmota:

```berry
SIM['millis'] = 5000        # внутренние часы tasmota.millis()
SIM['sensors'] = {'ANALOG': {'A1': 900, 'A2': 900}, 'COUNTER': {'C1': 0, 'C2': 0}}
SIM['cmds']                 # список всех tasmota.cmd(...) — команды, отправленные в Tasmota
SIM['timers']               # map: id -> {'delay': ms, 'cb': callback}  (set_timer записывает)
SIM['rules']                # map: триггер -> callback (add_rule)
SIM['websend']              # собранные web_send_decimal()
SIM['append']               # собранные response_append()
```

Датчики в объекты `wp1.SoilSensors[0]` попадают при `Update()`, а не при прямой правке `/sensors`:

```berry
SIM['sensors']['ANALOG']['A1'] = 900
wp1.SoilSensors[0].Update(json.load(tasmota.read_sensors()))
```

Хелперы:

```berry
cmds_include("Power1 1")    # была ли в истории команд подстрока
```

### Основной объект

`wp1` — глобальное Water из boot-секции `watering.be` (создался при сборке). Вызывайте его методы напрямую:

```berry
wp1.rule_power({'State': 1}, 'POWER1')            # событие реле канала 1 (диспетчер по PowerMap)
wp1.auto_flood()                                  # sweep-планировщик (round-robin по каналам)
wp1.every_second()
wp1.pulseencode(60)                               # чистая функция
```

### Доступ к каналам (`wp1.plants[i]`) — ВАЖНО (баг Berry 1.1.0)

`wp1.plants` — список каналов (`Plant`): `wp1.plants[0]`, `wp1.plants[1]`, …

**Не пишите цепочки `wp1.plants[0].X` в top-level коде теста** — на stock Berry 1.1.0
(global → member-список → индекс → member) это падает `index_error: list index out of range`
после накопления мусора/персист-записей (зафиксировано в тестах 32/33). Обязательно хойстите
в локальную переменную и переобъявляйте её после пересоздания `wp1`:

```berry
var P1 = wp1.plants[0]        # локальная ссылка на канал 1
P1.SoilMaxHymidity = nil      # OK
assert_eq(P1.Preset.Type, 'dry', "...")

wp1 = Watering()              # пересоздание (reboot) — обновите и ссылку:
var P1 = wp1.plants[0]
```

Внутри методов классов (`self.plants[0].X`) баг не проявляется; безопасны и `wp1.Store.method(...)`,
и `wp1.SoilSensors[0].Update(...)` (цепочка global → member, без индекса посредине).

Таймеры не «тикают» сами — их зарегистрированные колбэки в `SIM['timers']` можно вызывать вручную или проверять по `id`. Имена таймеров каналов — `ID_SOILTRANSITION_AFTERFLOOD_P{Num}` (счётчик единый).

### Пример кейса

```berry
import json

section("заливка_начинается")

SIM['sensors']['ANALOG']['A1'] = 900     # сухой грунт
SIM['millis'] = 1000
wp1.rule_power({'State': 1}, 'POWER1')

assert_eq(wp1.Power1, 1, "реле вкл")
assert_true(wp1.FinishRule != nil, "сработало правило окончания")
assert_true(cmds_include("TelePeriod 10"), "быстрая телеметрия во время помпы")
```

## Тонкости Berry (о чём легко споткнуться)

- `true`/`false` — **строчными** literal'ом (не слова `True`/`False`).
- Длина строки: `size(s)` (в байтах); `string.len()` нет.
- Подстроки: `string.find(hay, needle)` возвращает индекс или `-1`; `string.split(s, sep)` и `string.replace` работают; `string.mid` нет.
- map-объекты не переприсваивают члены через `=`; для переопределения стаб использует module-инстанции (см. `webserver`).
- Errors: `try ... except .. as e, m ... end`.
- `list.push(x)` — добавить элемент; `list.size()` — длина.
- JSON: `json.load(str)`, `json.dump(map)`.

## Текущие кейсы

| Кейс | Что проверяет |
|------|---------------|
| `00_smoke` | Загрузка `watering.be`, объект `wp1` создался |
| `10_rule_power_on` | ON на сухой почве: флаги, FinishRule, быстрая телеметрия, PulseTime |
| `11_rule_power_on_wet` | ON на мокрой: стоп, и OFF без протекания счётчика не даст краша (Counter1BeforeStart инициализирован в init) |
| `12_flood_cycle` | Полный цикл: ON → счётчик набрал → rule_flooded → OFF с компенсацией → таймеры 2ч/1м |
| `13_auto_flood` | Старт по расписанию на сухой; пропуск при влажной/в работе; estimate подхватывается. Многоканально: sweep round-robin стартует ровно один due-канал; при чужом включённом реле (`_flooding_plant() != nil`) sweep пропускается |
| `14_timer_soil_transition` | После паузы: повторная проливка при сухой (xxx1.2) либо завершение сессии при мокрой |
| `15_every_second` | Отслеживание минимальной влажности, подтверждение после роста, пауза; инвалидация устаревшего пика при влажной почве (кроме паузы после полива) с подтверждением новой впадины |
| `16_estimateflood` | Линейная оценка дозы по **Prev*** (последняя завершённая сессия); малая → nil (fallback); отсутствие данных → nil |
| `17_pulseencode` | Кодировка MaxPumpRun в PulseTime по докам; clamp вместо raise для вне-диапазона |
| `18_json_append` | Телеметрический JSON: поля, тернарий max-confirmed/nil |
| `19_web_sensor` | Веб-строки (сырой HTML-секции): detail soil1: группы `Уставки/Датчик/Сеанс/Размачивание/Текущий сеанс/Предыдущий сеанс`, стек `Сухо/Влажно` (`raw` + `<span class='stk'>% u`), max-ряд, Dry soak/Dry threshold при `me=1`, `me=` — нет; строки detail без префикса `|`; кнопка настроек канала: `Настройки порогов</th>` + `data-num='2'` + `_wdSettingsOpen(this)` в развёрнутом канале (`me=2`), в компакте (`me=`) НЕТ; Common-секция: `me=c` даёт flow-детали (pulse/s, ml/min — один label `Water flow` стеком `stk`) + Calibration mode + группа `Сброс` (ряд `Water counter` с кнопкой `Reset` и `confirm(` + `m_reset_water_counter_1`, при `me=` кнопки НЕТ); пер-канал: `me=2` → свои max/max time и ряды «Текущий сеанс»/«Предыдущий сеанс» (`LastFloodVol` есть, soil1 max скрыт) и группа «Последний полив» (`Last flood time` + `Last flow rate` мл/мин — средний расход последнего полива канала, показывается только когда `LastFloodTime` уже записан), отдельной глобальной группы «Последний полив» у канала 1 внизу страницы больше НЕТ; `Сеанс полива</th>` (`active`|`wait`) и `Вода</th>` (`run`|`idle`) — только в detail развёрнутого канала: в компакте (`me=`) рядов НЕТ, у активного канала `active` ровно один раз, у idle-канала `Вода=idle`; статус-иконка в заголовке: тултип-легенда всех 3 статусов с маркером текущего (`→ 💧 Ожидание` по одному на канал в компакте, активный канал переключает на `→ ⏳ Сеанс полива`, при `WaterIsOn()` — `→ 💦 Работа насоса` + `Вода=run` с живым `ml/min`); заголовки по `NumChannels` (default 4): «Канал 1»..«Канал 4» есть, «Канал 5» нет |
| `20_persist_target` | Калибровка Dry/Wet через setmember пишет TargetDry/Wet через `Store.set` (debounced: значение сразу в persist-мапу, save по 15s-таймеру/flush); init восстанавливает raw-значения |
| `21_flow_sensor` | FlowSensor: scale/Raw2Flow, измерение расхода (RawRate), сброс, member/setmember RateMeasuring, Rate=nil-ветка |
| `22_session_end` | Завершение сессии: rule_flooded, _autoflood_end, timer_endfasttele, button_pressed, rule_button1 (запуск через start_flood при сухости, skip при влажной) |
| `23_web_deinit` | web_add_main_button (HTML: кнопка Calibration есть, мёртвая кнопка Toggle Conf УБРАНА, `Reset water counter` с главной УБРАН — перенесён в Common detail; инжект содержит `_wdSettingsOpen` и суффиксные `m_soildry_`; bare-форм Soil Dry/Wet/Dry threshold/Soak dose на главной НЕТ), deinit: снятие правил/cron/cmd, off насоса, `Store.flush(true)` (persist.save) |
| `24_soil_sensor` | SoilSensor: init-поля из persist, EMA (сходимость/прилипание при малых Raw), статус N/C, Dry/Wet-пороги |
| `25_web_guard` | web_sensor не обрезает вывод при падении Soil-блока (тип_error от nil): следующий soil, flow и max-столбцы живы (soil1-секция через `me=1`); статус-иконка в заголовке эмитится и при `RawEma=nil` |
| `26_persist_reboot` | persist переживает BrRestart (deinit + Watering()): калибровка Dry/Wet (через Store, debounced + flush) и Prev*-статистика восстановлены; LastFloodVol дефолт 0; после ребута EMA ниже RawWet → start_flood скипает и доза не планируется (persist-данные не страдают) |
| `27_soil_threshold` | RawDry/RawWet редактируются командами SoilDry/SoilWet и веб-аргами m_soildry/m_soilwet (bare = канал 1) + суффиксными m_soildry_2/m_soilwet_2 (per-channel: канал 2 меняет свой порог, канал 1 не тронут); валидация разрыва > 20; TargetDry/TargetWet через `Store.set` (debounced, flush); bare-форм (id soil_dry/soil_wet/dry_thr/soak_dose) на главной НЕТ; снятие команд в deinit |
| `28_sensors_empty` | Загрузка когда read_sensors не отдаёт сенсоры (пустые map) — инициализация без краха |
| `29_rule_power_helpers` | Хелперы OFF-ветки `rule_power`: `_compensate_backflow` (все 3 ветки: дельта выше/ниже backflow), `_record_flood` (накопление объёма, 2ч таймер, пере-арм, **кап сеанса**: `LastFloodVol > MaxFlood` → remove_timer + `_autoflood_end()`, `PrevFloodedVol` = закапанный объём; `LastFlowRate = доза*60000/PumpRunMillis`: с заданным PumpRunMillis=60с и дозой 250 → 250.0 мл/мин), `_end_session_no_water`; полный проход OFF через `rule_power` |
| `30_water_on_off` | Диспетчер `rule_power` → `water_on()`/`water_off()`: маршрутизация по State, старт на сухой, отмена на мокрой (без новой правит и без FinishRule), запись дозы в OFF (millis сдвинут на 60с → `LastFlowRate = 250.0` мл/мин), пустая сессия без таймера проверки, неизвестный State без краха |
| `31_start_flood` | `start_flood()`: сухо → доза (default/оценка по Prev*) + Power1 1; влажно по EMA → skip без команды реле |
| `32_persist_store` | `PersistStore`: `register_channel` ×4 = 64 ключа (`P1*`..`P4*`); load дефолты, set по политикам debounced (Dirty+таймер+flush)/immediate/threshold (относительный, div-0 guard), flush clean=noop, `save_batch_entries` (список пар `[P{Num}ключ, value]`, один save), dump/команда Store с `P1*`; `Channels` — Store-переменная (default `'4'`) с командой `Channels` (отчёт текущего, отказ вне диапазона, установка «restart required», `NumChannels` не меняется до рестарта; в deinit снимается как и Store); веб-ряды сеанса в развёрнутых soil-секциях («Текущий сеанс»: `LastFloodVol`/`SoilHPreFlood` из живых plant-атрибутов; «Предыдущий сеанс»: `PrevSoilHPreFlood`/`PrevFloodedVol`/`PrevSoilMaxHymidity`; без `Store.P{Num}*`-префиксов, порядок тек.→пред. сессия, в свёрнутом виде скрыты; независимость секций: `me=1` не разворачивает soil2 (по split `Влажно</th>`), `me=2` — только rows канала 2 без soil1 max, `me=12` — обе), `d.size() >= 18` после сессии, deinit flush(true) |
| `33_dry_soak` | Сухая замочка (пресет `dry`, `FloodPreset('dry', wp1.Store, wp1.plants[0].Prefix)` — префикс канала): пик при RawEma>P1DryThreshold с дозой SoakStartDose и без записи Prev*-статов; `_record_flood` → DryDailyTicks + каденс SoakInterval; тренд: repeat до заполнения окна, эскалация ×1.2 (кап SoakMaxDose) при нет-отклике, hold при росте влажности, DailyCap-пауза, stop при RawEma<StopRaw (сессия закрыта, Prev* чисты); `every_second` не трекает SoilMaxHymidity при dry; команда `DrySoak` (status/start через `request_manual`); `P1DryThreshold` восстанавливается после ребута |
| `34_…` | (резерв, свободен) |
| `35_sequential` | Sweep round-robin по каналам: стартует ровно один due-канал, в один момент времени включено не более одного реле (`Power1`/`Power2` взаимоисключающие), wrap с 4-го канала на 1-й |
| `36_shared_counter` | Сериализация общего C1: повтор/ручной запуск при чужом реле ON блокируется (retry-пере-арм soil-таймера, 60с); `request_manual` → `start_flood` НЕ ставит `AutofloodInProcess` (в отличие от `start_session`); эскалация `PlannedFlood` (default ×1.2 → 360 → 432) |
| `37_plant_reboot` | Per-channel persist изоляция: ключи `P{Num}*` сохраняются/восстанавливаются по каналам после BrRestart (deinit + Watering()); общий Store с register_channel ×4; параметры канала не перетекают в соседние |
| `38_plant_drysoak` | Dry-пресет на канале 2: per-channel `P2DryThreshold`/дозы, dry-сессия 2-го канала не трогает статы/трекинг 1-го; префикс источника партий в `save_batch_entries` |
| `39_flood_timecap` | Аппаратный кап времени на канал: `PulseTime1..4` из `MaxPumpRun` при init; finish-правило на общем счётчике C1 (Counter1BeforeStart+backflow+доза) |
| `40_sweep_repeat` | Sweep стартует ровно один due-канал; repeat при занятом общем счётчике (чужое реле) откладывается; wet-завершение закрывает сессию (`_autoflood_end`, без повторного полива) |

## Проверка на реальном железе

Локальные тесты не покрывают деплой и работу Berry-рантайма на устройстве. Каждый релиз проверяй на железе.

### Автоматическая (deploy.py)

```sh
.pyvenv/bin/python deploy.py    # upload + verify + BrRestart + проверки; rc=0 = всё ок
```

`deploy.py` делает сам и падает (rc=1) при любой проблеме:

- заливает `watering.be`, только если файл изменился; верифицирует загрузку (`/ufsd?download=...` 200);
- перед аплоадом читает `/in` (heap: `Free Memory ... (frag. N%)`): при `frag >= 40%` делает полный рестарт устройства (`Restart 1`) и ждёт его возврата — фрагментированный heap ломает и `/ufsu`-аплоад, и загрузку скрипта;
- `BrRestart` и ждёт в логе маркер `Watering driver initialized`;
- собирает лог после старта и ищет краши/ошибки инициализации (`type_error`, `syntax_error`, `index_error`, `stack traceback`, `undeclared`, `MEMORY ALLOCATION FAILED`, `Giving up on delayed sensor init`, `WARNING: Watering driver NOT registered`);
- если после `BrRestart` в логе `MEMORY ALLOCATION FAILED` — автоматически повторяет с полным `Restart 1` (очищает heap и лог);
- `GET /` — страница 200 и в HTML есть секции каналов (`tr.sec`);
- сетевые таймауты помечаются отдельной проблемой + пинг до устройства (одна проверка за прогон).

Если `BrRestart` после деплоя дал `MEMORY ALLOCATION FAILED` и каналы не отдаются — сделай полный рестарт устройства (`cmnd=Restart 1`), не только VM.

### Ручной чеклист

1. Кнопки **Tools** и **Configuration** на главной присутствуют (инжекция `web_add_main_button` работает).
2. На главной видны все каналы (секции `Канал 1..N` + `Common`).
3. Клик по секции раскрывает её (подгружаются детали: датчик, сессии, кнопки уставок).
4. Статус-иконка (💧/⏳/💦) показывает тултип-легенду по клику, страница не сворачивается/не прыгает (stopPropagation).
5. В консоли устройства (`/cs?c2=0`) после старта нет `type_error`/`stack traceback`/`NOT registered`.

## Полезное

- Корень дерева: `watering.be` — источник правды; тесты не дублируют логику, а фиксируют её.
- В `github.com/mmv-ru/tasmota_irrigation` ветка `feature/ai-irrigation-dev`.