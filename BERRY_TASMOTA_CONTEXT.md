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
7. **`auto_flood`**: партия prev-статов (`PrevSoil*`, `PrevFloodedVol`) пишется одним `persist.save()` ПОСЛЕ цикла `for`, а не внутри него (иначе 4 записи во Flash за раз).
8. **Для тестов (stub persist)**: persist обязан быть **классом с виртуальными `member`/`setmember`** (`class Persist ... end; var persist = Persist()`), а не module-instance. Только так `introspect.set(persist, k, v)` реально попадает в внутренний map (module-instance не даёт virtual setters — `introspect.set` молча не пишет).

### `webserver` object (Web UI)
| Метод | Описание |
|-------|----------|
| `webserver.has_arg(name)` | Проверка наличия GET-параметра (возвращает `bool`) |
| `webserver.arg(name)` | Получение значения параметра (по имени или по индексу `0..arg_size()-1`) |
| `webserver.arg_size()` | Количество аргументов в запросе |
| `webserver.content_send(html)` | Отправка HTML в ответ веб-сервера |
| `webserver.content_open(http_code, mimetype)` | Установка HTTP-кода и MIME-типа ответа (нет `send_content_type`) |

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

---

## 📐 SoilSensor & EMA (проект irrigation) — ТЕКУЩЕЕ СОСТОЯНИЕ
- **Все актуальные расчёты идут в RAW отсчётах ADC** (сырые `Raw`/`RawEma`; пороги `RawDry`/`RawWet`). Калибровки в % (`Hymidity`) и мВ (`mV`/`Hu`) — **недоделаны, не трогать**.
- **Пороги**: `RawDry=800`, `RawWet=750`; линейная шкала по двум точкам `setScale(842, 1105)`.
- **EMA** (`EMAN=600`): `k=2/(N+1)`, `RawEma_new = RawEma_old*(1-k) + Raw*k`; инициализация `RawEma = Raw` при первом тике. Функция `EMA()` в начале watering.be.
- **Наблюдаемый артефакт (приемлемый)**: в InfluxDB кривая EMA огибает кривую RAW СВЕРХУ со смещением +1..+2. Возможные причины: округления, дискретность отчётов (раз в 5 мин попадает на заниженное значение), помехи питания. **Пользователя смещение устраивает — не оптимизировать, не «чинить».**
- ADC: `Raw2mVScale` из делителя 30k/30k (≈1.197 mV/source), полином `Hu_C` — недоделка.