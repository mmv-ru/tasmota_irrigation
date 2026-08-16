# Tasmota Irrigation

Система полива: `watering.be` — Berry-скрипт (FSM) для Tasmota. Локальная разработка и тесты вместо реального железа.

Перед любой работой прочитай:
- `BERRY_TASMOTA_CONTEXT.md` — ключевые факты, gotchas (Berry), архитектура, текущее состояние полей.
- `tests.md` — карта тестовых кейсов, как их собирать и гонять.

Главные правила:
- `watering.be` — источник правды; тесты фиксируют её, а не диктуют.
- `watering_ui.be` — рудимент (незавершённая попытка вынести web-UI в отдельный модуль); не используется, не пушить/не развивать.
- Пуш на устройство — только `watering.be` через `make deploy` (deploy.py заливает, только если файл изменился). Запускать: `.pyvenv/bin/python deploy.py` (в venv есть `requests` и `diff_match_patch`). `rc=0` — всё ок; при любой проблеме `rc=1`.
- После деплоя на реальное железо выполнить ручной чеклист из `tests.md` → «Проверка на реальном железе» (кнопки Tools/Configuration, каналы на главной, раскрытие секций, тултип иконки).
- Если после `BrRestart` скрипт не загрузился (`MEMORY ALLOCATION FAILED`, каналы пропали) — полный рестарт устройства `cmnd=Restart 1`, не только VM.
- Не трогать недоделанные калибровки %/мВ (`Raw2Hymidity`/`Hymidity2Raw`/`Raw2mV`/`mV2Raw`/`Raw2Hu`) и EMA-режим без явного запроса.
- Тесты только через `python3 tests/run_all.py` (или `python3 tests/build.py tests/cases/<case>.be`); всегда зелёные.
- Если `python3 tests/run_all.py` не находит berry — развернуть среду: `bash tests/setup_berry.sh` (бинарь: `~/.local/bin/berry`; версия зафиксирована в скрипте).