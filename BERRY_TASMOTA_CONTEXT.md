# 📘 Berry Script for Tasmota v15.3.0 - AI Context & Reference
> Версия прошивки: Tasmota v15.3.0 (Susan)
> Язык: Berry (ultra-lightweight embedded scripting)
> Цель: Генерация валидного, безопасного и эффективного кода для IoT-контроллеров

---

## ⛔ STRICT RULES (НЕ ИГНОРИРОВАТЬ)
1. **НЕТ внешних библиотек**: `import` разрешен только для встроенных модулей (`string`, `json`, `math`, `path`). Никаких `requests`, `time`, `os` и т.д.
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
| `tasmota.set_timer(sec, callback_fn)` | Неблокирующий таймер. `callback_fn` вызывается через `sec` секунд |
| `tasmota.set_power(idx, state)` | Управление реле: `idx` (1-8), `state` (0=OFF, 1=ON) |
| `tasmota.get_power(idx)` | Возвращает текущее состояние реле |
| `tasmota.add_cmd('CmdName', func_ref)` | Регистрация команды консоли. Сигнатура: `def func(cmd, idx, payload, payload_json)` |
| `tasmota.resp_cmnd_done()` | Ответ "Done" в консоль |
| `tasmota.resp_cmnd_error()` | Ответ "Error" |
| `tasmota.resp_cmnd_str(msg)` | Ответ произвольной строкой |
| `tasmota.resp_cmnd(json_map)` | Ответ JSON-объектом |
| `tasmota.mqtt_publish(topic, payload, retain)` | Публикация в MQTT (`retain`: 0 или 1) |
| `tasmota.save_data(key, val)` / `tasmota.load_data(key)` | Сохранение/чтение в энергонезависимую память (flash) |
| `tasmota.gc()` | Принудительная сборка мусора |

### `webserver` object (Web UI)
| Метод | Описание |
|-------|----------|
| `webserver.has_arg(name)` | Проверка наличия GET-параметра |
| `webserver.arg(name)` | Получение значения параметра |
| `webserver.content_send(html)` | Вставка HTML в ответ веб-сервера |
| `webserver.send_content_type(type)` | Установка MIME-типа ответа |

### `wire` object (I2C)
| Метод | Описание |
|-------|----------|
| `tasmota.wire_scan(addr, idx)` | Поиск устройства. Возвращает `wire` объект или `nil`. `idx` = индекс устройства |
| `wire.read(addr, reg, len)` | Чтение `len` байт из регистра `reg` |
| `wire.write(addr, reg, data, len)` | Запись `len` байт в регистр `reg` |
| `wire.bus` | Номер шины I2C (1 или 2) |

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
  var state = 1 if payload == "on" else 0
  tasmota.set_power(idx, state)
  tasmota.resp_cmnd_done()
end

tasmota.add_cmd('SetMyRelay', my_cmd)