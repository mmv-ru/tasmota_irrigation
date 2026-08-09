# 📘 Berry Script for Tasmota v15.3.0 - AI Context & Reference
> Версия прошивки: Tasmota v15.3.0 (Susan)
> Язык: Berry (ultra-lightweight embedded scripting)
> Цель: Генерация валидного, безопасного и эффективного кода для IoT-контроллеров

---

## ⛔ STRICT RULES (НЕ ИГНОРИРОВАТЬ)
1. **НЕТ внешних библиотек**: `import` разрешен только для встроенных модулей Tasmota: `string`, `json`, `math`, `path`, `persist`, `mqtt`, `gpio`, `webserver`, `sys` и др. Никаких `requests`, `time`, `os` и т.д.
2. **НЕТ async/await или потоков**: Только callback-стиль и таймеры.
3. **НЕ блокируйте главный цикл**: `tasmota.delay()` блокирует весь Tasmota. Для задержек используйте `tasmota.set_timer()`.
4. **Ограничение памяти**: ~64 КБ на скрипт. Избегайте больших строк, вложенных структур и бесконечных массивов.
5. **Типы данных**: Berry динамически типизирован, но строго относится к `nil`. Всегда проверяйте `!= nil` перед использованием результатов I2C/HTTP/MQTT.
6. **Команды консоли**: Все кастомные команды ДОЛЖНЫ вызывать `tasmota.resp_cmnd_*()` для завершения.

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
| `persist` (`import persist`) | Персистентность в `_persist.json`: `persist.key = val`, `persist.save()`, `persist.has(key)`, `persist.find(key)`, `persist.remove(key)`, `persist.zero()` (не `save_data`/`load_data`) |
| `tasmota.gc()` | Принудительная сборка мусора. Возвращает `int` (выделено байт); только для отладки |

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