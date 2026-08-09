# Tasmota Irrigation

Система полива: `watering.be` — Berry-скрипт (FSM) для Tasmota. Локальная разработка и тесты вместо реального железа.

Перед любой работой прочитай:
- `BERRY_TASMOTA_CONTEXT.md` — ключевые факты, gotchas (Berry), архитектура, текущее состояние полей.
- `tests.md` — карта тестовых кейсов, как их собирать и гонять.

Главные правила:
- `watering.be` — источник правды; тесты фиксируют её, а не диктуют.
- Не трогать недоделанные калибровки %/мВ (`Raw2Hymidity`/`Hymidity2Raw`/`Raw2mV`/`mV2Raw`/`Raw2Hu`) и EMA-режим без явного запроса.
- Тесты только через `python3 tests/run_all.py` (или `python3 tests/build.py tests/cases/<case>.be`); всегда зелёные.
- Если `python3 tests/run_all.py` не находит berry — развернуть среду: `bash tests/setup_berry.sh` (бинарь: `~/.local/bin/berry`; версия зафиксирована в скрипте).