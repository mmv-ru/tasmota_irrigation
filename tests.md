# Тесты watering.be

Характеризационные тесты логики полива. Запускаются на **локальном интерпретаторе Berry** (без железа), Tasmota-API эмулируется стабом. Цель — зафиксировать текущее поведение (`rule_power`, `auto_flood`, таймеры) до будущего рефакторинга: если после правок тесты станут красными — поведение изменилось.

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
wp1.rule_power({'State': 1}, 'POWER1')            # событие реле
wp1.auto_flood()                                  # крон
wp1.every_second()
wp1.pulseencode(60)                               # чистая функция
```

Таймеры не «тикают» сами — их зарегистрированные колбэки в `SIM['timers']` можно вызывать вручную или проверять по `id`.

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
| `13_auto_flood` | Старт по расписанию на сухой; пропуск при влажной/в работе; estimate подхватывается |
| `14_timer_soil_transition` | После паузы: повторная проливка при сухой (xxx1.2) либо завершение сессии при мокрой |
| `15_every_second` | Отслеживание минимальной влажности, подтверждение после роста, пауза |
| `16_estimateflood` | Линейная оценка дозы; малая → nil (fallback); отсутствие данных → nil |
| `17_pulseencode` | Кодировка MaxPumpRun в PulseTime по докам; clamp вместо raise для вне-диапазона |
| `18_json_append` | Телеметрический JSON: поля, тернарий max-confirmed/nil |
| `19_web_sensor` | Веб-строки: базовые ряды в сенсорех, ряд max-влажности |
| `20_persist_target` | Калибровка Dry/Wet через setmember пишет TargetDry/Wet в persist (по одному save); init восстанавливает raw-значения |
| `21_flow_sensor` | FlowSensor: scale/Raw2Flow, измерение расхода (RawRate), сброс, member/setmember RateMeasuring, Rate=nil-ветка |
| `22_session_end` | Завершение сессии: rule_flooded, _autoflood_end, timer_endfasttele, button_pressed, rule_button1 |
| `23_web_deinit` | web_add_main/config_button (HTML), deinit: снятие правил/cron/cmd, off насоса, persist.save |
| `24_soil_sensor` | SoilSensor: init-поля из persist, EMA (сходимость/прилипание при малых Raw), статус N/C, Dry/Wet-пороги |
| `25_web_guard` | web_sensor не обрезает вывод при падении Soil-блока (тип_error от nil): следующий soil, flow и max-столбцы живы |
| `26_persist_reboot` | persist переживает BrRestart (deinit + Watering()): калибровка Dry/Wet и Prev*-статистика восстановлены; LastFloodVol дефолт 0 |
| `27_soil_threshold` | RawDry/RawWet редактируются командами SoilDry/SoilWet и веб-аргами m_soildry/m_soilwet; валидация разрыва > 20; persist TargetDry/TargetWet; снятие команд в deinit |
| `28_sensors_empty` | Загрузка когда read_sensors не отдаёт сенсоры (пустые map) — инициализация без краха |
| `29_rule_power_helpers` | Хелперы OFF-ветки `rule_power`: `_compensate_backflow` (все 3 ветки: дельта выше/ниже backflow), `_record_flood` (накопление объёма, 2ч/24ч таймер, пере-арм), `_end_session_no_water`; полный проход OFF через `rule_power` |
| `30_water_on_off` | Диспетчер `rule_power` → `water_on()`/`water_off()`: маршрутизация по State, старт на сухой, отмена на мокрой (без новой правит и без FinishRule), запись дозы в OFF, пустая сессия без таймера проверки, неизвестный State без краха |

## Полезное

- Корень дерева: `watering.be` — источник правды; тесты не дублируют логику, а фиксируют её.
- В `github.com/mmv-ru/tasmota_irrigation` ветка `feature/ai-irrigation-dev`.