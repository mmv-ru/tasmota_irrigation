# Тесты watering.be

Характеризационные тесты логики полива. Запускаются на **локальном интерпретаторе Berry** (без железа), Tasmota-API эмулируется стабом. Цель — зафиксировать текущее поведение (`rule_power`, `auto_flood`, таймеры) до будущего рефакторинга: если после правок тесты станут красными — поведение изменилось.

## Как запустить

```sh
python3 tests/run_all.py                    # все тесты, berry из /tmp/opencode/berry/berry
python3 tests/run_all.py /path/to/berry     # указать бинарник berry
python3 tests/build.py tests/cases/10_rule_power_on.be  # один тест
```

Требуется собранный бинарник Berry (см. ниже). Никаких зависимостей Python — только файлы в `tests/`.

## Структура

| Путь | Что это |
|------|---------|
| `tests/harness_header.be` | Преамбула: фреймворк ассертов + стабы Tasmota. Вклеивается в начало каждого теста |
| `tests/modules/*.be` | Модули-бесплатно имитируемые (`webserver`, `strict`, `undefined`, `webclient`) — их видит `import` |
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
| `16_estimateflood` | Линейная оценка дозы; малая → 0; отсутствие данных → nil |
| `17_pulseencode` | Кодировка MaxPumpRun в PulseTime по докам; clamp вместо raise для вне-диапазона |
| `18_json_append` | Телеметрический JSON: поля, тернарий max-confirmed/nil |
| `19_web_sensor` | Веб-строки: базовые ряды в сенсорех, ряд max-влажности |

## Полезное

- Корень дерева: `watering.be` — источник правды; тесты не дублируют логику, а фиксируют её.
- В `github.com/mmv-ru/tasmota_irrigation` ветка `feature/ai-irrigation-dev`.
- Собрать Berry 1.1.0:

```sh
git clone https://github.com/berry-lang/berry.git /tmp/opencode/berry
cd /tmp/opencode/berry && cmake -B build && make -C build
# бинарник: /tmp/opencode/berry/build/berry
```