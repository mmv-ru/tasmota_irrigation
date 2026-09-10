# Состояния и переходы алгоритма автополива (event-driven FSM, многоканально)

> Диаграмма отражает **текущую** логику `watering.be` (итерация 2 — многоканальность).
> Архитектура: `Watering` = диспетчер + общие ресурсы (SoilSensors A1..A4, общие
> FlowSensors C1/C2, общий PersistStore), `Plant` = канал (свой насос `Power{Num}`,
> свой SoilSensor, своя FSM, свои persist-ключи `P{Num}_*`). `MAX_CHANNELS = 4`.
> При изменении FSM-логики — обновлять эту схему, чтобы она не рассинхронизировалась с кодом.

```mermaid
flowchart TD
    %% ===================== ВХОДНЫЕ СОБЫТИЯ =====================
    EV_CRON{{"Событие: cron auto_flood (каждый час, окно 14:00–01:00)"}}
    EV_PW_ON{{"Событие: POWER{Num} вкл (relay ON)"}}
    EV_PW_OFF{{"Событие: POWER{Num} выкл (relay OFF)"}}
    EV_BTN{{"Событие: BUTTON1 SINGLE/DOUBLE → канал 1"}}
    EV_FINISH{{"Событие: FinishRule COUNTER#C1>=порог (общий счётчик)"}}
    EV_T_PLANT{{"Событие: cooldown-таймер канала ID_SOILTRANSITION_AFTERFLOOD_P{Num}"}}

    %% ===================== auto_flood — SWEEP =====================
    subgraph AUTO_FLOOD["auto_flood() — sweep-планировщик (round-robin)"]
        EV_CRON --> AF_FLOOD{"_flooding_plant() != nil (чужое реле ON)?"}
        AF_FLOOD -- да --> AF_SKIP[("sweep пропущен — одна заливка за раз")]
        AF_FLOOD -- нет --> AF_LOOP["цикл по каналам с _rr_idx (круг): idx = (_rr_idx + i) % N"]
        AF_LOOP --> AF_DUE{"p.due() = SoilSensor.IsDry() && !AutofloodInProcess?"}
        AF_DUE -- нет --> AF_NEXT["следующий канал"]
        AF_DUE -- да --> AF_RR["_rr_idx = (idx+1) % N"]
        AF_RR --> AF_SESS["p.start_session() — старт ровно ОДНОГО due-канала"]
    end

    %% ===================== start_session / start_flood =====================
    subgraph SESSION["Plant.start_session() — новая сессия (свеп)"]
        AF_SESS --> SS_PICK["0) _pick_preset(): RawEma > DryThreshold → пресет dry | иначе → normal"]
        SS_PICK --> SS_SAVE{"1) _stats_enabled() (пресет normal)?"}
        SS_SAVE -- да --> SS_BATCH["Prev*-статистика + estimate-входы партией Store.save_batch_entries(self._stats_batch()) — один save"]
        SS_SAVE -- нет (dry) --> SS_INIT
        SS_BATCH --> SS_INIT["2) init сессии: LastFloodVol=0, AutofloodInProcess=true, SoilHPreFlood=RawEma, сброс Max/Time/Temp"]
        SS_INIT --> SS_START["3) start_flood()"]
    end

    subgraph START_FLOOD["Plant.start_flood() — единая точка запуска (сессия / повтор / кнопка)"]
        SF_ENTRY --> SF_PICK{"Preset == nil?"}
        SF_PICK -- да --> SF_PK2["_pick_preset() — выбрать стратегию (без init-сессии)"]
        SF_PICK -- нет --> SF_DRY{"RawEma > RawWet — почва сухая по EMA?"}
        SF_PK2 --> SF_DRY
        SF_DRY -- нет --> SF_SKIP[("лог «soil not dry, skip» — помпа НЕ включается")]
        SF_DRY -- да --> SF_PLAN["PlannedFlood = Preset.dose() (normal → planned_dose(); dry → DrySoakDose)"]
        SF_PLAN --> SF_PWR["Power{Num} 1"]
        SF_PWR --> EV_PW_ON
    end

    %% ===================== АРБИТРАЖ (shared C1) =====================
    subgraph ARB["Арбитраж общего счётчика C1 (Watering)"]
        EV_T_PLANT --> ARB_EVAL["Plant.timer_soil_transition_after_flooded() → Preset.evaluate()/'repeat'?"]
        ARB_EVAL --> ARB_RR["'repeat' → Owner.request_repeat(plant)"]
        ARB_RR --> ARB_BUSY{"_flooding_plant() != nil (чужое реле ON)?"}
        ARB_BUSY -- да --> ARB_RETRY["пере-арм soil-таймера канала с retry 60с (_rearm_soil_check(60000))"]
        ARB_BUSY -- нет --> ARB_START["plant.start_flood()"]
        EV_BTN --> ARB_MAN["request_manual(plants[0])"]
        ARB_MAN --> ARB_BUSY2{"_flooding_plant() != nil?"}
        ARB_BUSY2 -- да --> ARB_BLOCK[("ручной запуск заблокирован")]
        ARB_BUSY2 -- нет --> ARB_START2["plant.start_flood()"]
    end

    %% ===================== rule_power диспетчер =====================
    subgraph RULE_PWR["rule_power(value, trigger) — диспетчер по POWER{Num}#State"]
        EV_PW_ON --> RPD["PowerMap[trigger] → Plant.rule_power(value)"]
        RPD --> RPD_ON{"State == 1?"}
        RPD_ON -- да --> RULE_ON_START["water_on()"]
        EV_PW_OFF --> RPD_OFF{"State == 0?"}
        RPD_OFF -- да --> RULE_OFF_START["water_off()"]
        RPD_ON -- нет --> RPD_ELSE["WARNING: unexpected state"]
        RPD_OFF -- нет --> RPD_ELSE
    end

    %% ===================== water_on =====================
    subgraph RULE_ON["Plant.water_on() — старт помпы"]
        RULE_ON_START --> RON_START["PumpStartMillis=now, WaterIsOn()=true"]
        RON_START --> RON_WET{"IsWet() (почва уже мокрая)?"}
        RON_WET -- да --> RON_ABORT["Power{Num} 0 — отмена, помпа не запускается"]
        RON_ABORT --> EV_PW_OFF
        RON_WET -- нет --> RON_TELE["TelePeriod 10 (быстрая телеметрия), PauseSoilMaxStat=true"]
        RON_TELE --> RON_CNT["Counter1BeforeStartTicks = счётчик до старта (тики)"]
        RON_CNT --> RON_CANCEL["отменить таймер ID_ENDFASTTELE (не дать вернуть TelePeriod в 300)"]
        RON_CANCEL --> RON_RULE["FinishRule = COUNTER#C1 >= Counter1BeforeStartTicks + ticks(Backflow) + ticks(доза); доза/backflow в мл переводятся в тики через Plant.ticks() (ml / FlowScale)"]
        RON_RULE --> RON_ADD["add_rule(FinishRule → Plant.rule_flooded)"]
        RON_ADD --> RON_RATE["FlowSensor.RateMeasuring = true (замер расхода)"]
        RON_RATE --> PUMPS_END["Помпа качает, ждём превышения счётчика / PulseTime"]
    end

    %% ===================== rule_flooded =====================
    subgraph RULE_FLOODED["Plant.rule_flooded() — лимит счётчика достигнут"]
        EV_FINISH --> RFL_MSG["Порог COUNTER#C1 достигнут"]
        RFL_MSG --> RFL_OFF["Power{Num} 0 → стоп помпы"]
        RFL_OFF --> EV_PW_OFF
    end

    %% ===================== water_off =====================
    subgraph RULE_OFF["Plant.water_off() — стоп помпы"]
        RULE_OFF_START --> ROFF_CNT["прочитать сенсоры: Counter1 = COUNTER#C1"]
        ROFF_CNT --> ROFF_MILLIS["PumpRunMillis = now − PumpStartMillis (с защитой)"]
        ROFF_MILLIS --> ROFF_RULE["снять FinishRule"]
        ROFF_RULE --> ROFF_DELTA["CounterDeltaTicks = _compensate_backflow(Counter1) — вычесть backflow из счётчика и дельты; backflow задан в мл, в тики переводится ticks(Backflow)"]
        ROFF_DELTA --> ROFF_RATE["FlowSensor.RateMeasuring = false"]
        ROFF_RATE --> ROFF_COMP{"CounterDeltaTicks > BackflowTicks?"}
        ROFF_COMP -- да --> ROFF_BCK["counter1 preset (С1−BackflowTicks); CounterDeltaTicks −= BackflowTicks"]
        ROFF_COMP -- нет --> ROFF_ZERO["counter1 preset (С1BeforeStartTicks); CounterDeltaTicks = 0"]
        ROFF_BCK --> ROFF_VOL{"CounterDeltaTicks > 0 (вода реально прошла)?"}
        ROFF_ZERO --> ROFF_VOL
        ROFF_VOL -- да --> ROFF_REC["_record_flood(CounterDeltaTicks): LastFloodTime=now, LastFloodVol += CounterDeltaTicks × FlowScale (мл), LastFlowRate = мл·60000/длительность"]
        ROFF_REC --> ROFF_DRY{"Preset.Type == 'dry'?"}
        ROFF_DRY -- да --> ROFF_DRYT["DryDailyVol.push({ms, vol}) — в мл, накопление для DailyCap; flood_delay = SoakInterval"]
        ROFF_DRY -- нет --> ROFF_CAP{"LastFloodVol > MaxFlood?"}
        ROFF_CAP -- да --> ROFF_END["remove_timer + _autoflood_end() — сессия закрыта капом объёма"]
        ROFF_CAP -- нет --> ROFF_2["flood_delay = 2ч"]
        ROFF_DRYT --> ROFF_TMR["set_timer пере-армит ID_SOILTRANSITION_AFTERFLOOD_P{Num} → timer_soil_transition_after_flooded"]
        ROFF_2 --> ROFF_TMR
        ROFF_END --> ROFF_60S["set_timer(60с → timer_endfasttele_after_flooded: TelePeriod 300)"]
        ROFF_TMR --> ROFF_60S
        ROFF_VOL -- нет (вода не прошла) --> ROFF_EMPTY["_end_session_no_water(): PauseSoilMaxStat=false, AutofloodInProcess=false (сессия без воды)"]
        ROFF_EMPTY --> ROFF_60S
    end

    %% ===================== timer_soil_transition =====================
    subgraph T_SOIL["Plant.timer_soil_transition_after_flooded() — проверка результата"]
        ARB_EVAL --> TSL_PRESET{"Preset != nil?"}
        TSL_PRESET -- да, normal --> TSL_CLASSIC["Preset.evaluate → _evaluate_escalate()"]
        TSL_PRESET -- нет --> TSL_CLASSIC
        TSL_CLASSIC --> TSL_DRY{"Raw > (RawDry+RawWet)/2 — земля всё ещё сухая?"}
        TSL_DRY -- да (недостаточно) --> TSL_INC["Counter1FloodDefault × 1.2 (с капом MaxFlood)"]
        TSL_INC --> TSL_REP["'repeat' → request_repeat(plant) → start_flood()"]
        TSL_REP --> EV_PW_ON
        TSL_DRY -- нет (достаточно) --> TSL_END["_autoflood_end()"]
        TSL_PRESET -- да, dry --> TSL_TREND["Preset.evaluate → _evaluate_trend()"]
    end

    %% ===================== dry-soak evaluate =====================
    subgraph DRY_SOAK["FloodPreset._evaluate_trend() — сухая замочка (per-plant)"]
        TSL_TREND --> DT_STOP{"RawEma < StopRaw (DryThreshold)?"}
        DT_STOP -- да --> DT_END["_drysoak_end(): AutofloodInProcess=false, Preset=nil, DrySoakDose=nil (Prev* не тронуты)"]
        DT_STOP -- нет --> DT_HIST["DryEmaHistory.push({ms, ema}); prune до SoakTrendWindow"]
        DT_HIST --> DT_CAP{"сумма DryDailyVol за 24ч (мл) >= SoakDailyCap?"}
        DT_CAP -- да --> DT_PAUSE["pause: _rearm_soil_check(SoakInterval)"]
        DT_CAP -- нет --> DT_WIN{"now − старт_окна < SoakTrendWindow (окно не заполнено)?"}
        DT_WIN -- да --> DT_REP["repeat: request_repeat(plant) → start_flood() — та же доза"]
        DT_WIN -- нет --> DT_DELTA{"RawEma_now − RawEma_старт >= 0 (нет отклика)?"}
        DT_DELTA -- да --> DT_ESC["DrySoakDose ×= SoakDoseGrow (кап SoakMaxDose); request_repeat → start_flood()"]
        DT_DELTA -- нет --> DT_HOLD["hold: влажность растёт — _rearm_soil_check(SoakInterval)"]
        DT_ESC --> EV_PW_ON
        DT_REP --> EV_PW_ON
    end

    %% ===================== _autoflood_end =====================
    subgraph T_END["Plant._autoflood_end() — завершение сессии"]
        TSL_END --> TEND_STOP["AutofloodInProcess=false"]
        TEND_STOP --> TEND_RESET{"Counter1ResetPostpone?"}
        TEND_RESET -- да --> TEND_RESET2["FlowSensor.Reset(), Counter1ResetPostpone=false"]
        TEND_RESET -- нет --> TEND_CLR["SoilMaxHymidity=nil, SoilMaxHymidityTime=nil"]
        TEND_RESET2 --> TEND_CLR
        TEND_CLR --> TEND_PREV["PrevFloodedVol = LastFloodVol"]
        TEND_PREV --> TEND_UNPAUSE["PauseSoilMaxStat=false (возобновить слежение за Max), Preset=nil"]
        TEND_UNPAUSE --> IDLE[("IDLE — ожидание следующего часа/события")]
    end

    %% ===================== every_second (фон) =====================
    subgraph EVERY_SEC["every_second() — фон, 1/с (для КАЖДОГО канала)"]
        ES_START["read_sensors → Update SoilSensors/FlowSensors (Raw, RawEma)"]
        ES_START --> ES_PAUSE{"PauseSoilMaxStat или !_stats_enabled() (dry)?"}
        ES_PAUSE -- да --> ES_SKIP["слежение за Min/Max приостановлено"]
        ES_PAUSE -- нет --> ES_MIN{"SoilMaxHymidityTemp==nil или RawEma < текущий Temp?"}
        ES_MIN -- да --> ES_NEWMIN["SoilMaxHymidityTemp=RawEma, SoilMaxHymidityTimeTemp=now (в память, не персистится)"]
        ES_MIN -- нет --> ES_STALE{"RawEma < SoilMaxHymidity? (почва влажнее подтверждённого пика)"}
        ES_STALE -- да --> ES_INVAL["инвалидация: SoilMaxHymidity=nil, SoilMaxHymidityTime=nil (in-memory) — пик завышает влажность"]
        ES_STALE -- нет --> ES_CHK{"Temp != nil и (SoilMaxHymidity==nil или Temp < SoilMaxHymidity) и RawEma > Temp+5?"}
        ES_CHK -- да --> ES_CONF["подтверждение: SoilMaxHymidity=Temp, SoilMaxHymidityTime=TimeTemp, Store.save_batch_entries(p.max_batch()) — один save"]
        ES_SKIP --> ES_DONE["конец тика"]
        ES_NEWMIN --> ES_DONE
        ES_INVAL --> ES_DONE
        ES_CONF --> ES_DONE
        ES_CHK -- нет --> ES_DONE
    end

    %% связи фон-логика
    EVERY_SEC -.->|"данные Raw/RawEma/SoilMaxHymidity читают auto_flood, rule_power, estimateflood, timer"| AUTO_FLOOD
```

## Методы и их роль

### Watering (диспетчер, общее)
| Метод | Роль в FSM |
|-------|-----------|
| `auto_flood()` | Sweep-планировщик по cron (часы 14–01): если `_flooding_plant() == nil` — round-robin по `_rr_idx`, стартует ровно ОДИН due-канал (`Plant.due()`) через `start_session()`; очередь НЕ ведётся, `due()` производное |
| `rule_power(value, trigger)` | Диспетчер `POWER{Num}#State`: `PowerMap[trigger]` → `Plant.rule_power(value)`; неизвестный trigger — WARNING |
| `_flooding_plant()` | Возвращает канал с `WaterIsOn() == true` (реле ON) или nil — основа сериализации общего C1 |
| `request_repeat(plant)` | Арбитраж повтора: при `_flooding_plant() != nil` — retry-пере-арм soil-таймера канала (60с); иначе `plant.start_flood()` |
| `request_manual(plant)` | Ручной запуск (кнопка/`DrySoak start`) с тем же guardian, что и `request_repeat` |
| `init_sensors()` | Создаёт SoilSensors A1..A4, общие FlowSensors C1/C2, `Plant(0..3)`, `PowerMap`, правила `POWER{Num}`, `PulseTime{Num}`, cron, команды; правила каналов/кнопки снимаются в `deinit()` |
| `web_sensor()` / `json_append()` | Веб-ряды и телеметрия: канал 1 — телеметрический (`Soil1*`, `Soil2*`, `LastFloodSessionVol` и т.д.), детальный Store-блок — ключи `P1*` |
| `every_second()` | Фон 1/с: Update сенсоров + трекинг минимума влажности для каждого канала (только при `_stats_enabled()`) |

### Plant (канал, своя FSM)
| Метод | Роль в FSM |
|-------|-----------|
| `due()` | Производное «хочет полива сейчас»: `SoilSensor.IsDry() && !AutofloodInProcess`; пересчитывается на каждом sweep |
| `start_session()` | Новая сессия (вход со sweep): 0) `_pick_preset()` (ДО проверки `_stats_enabled()` — dry не пишет статы), 1) при normal `Store.save_batch_entries(self._stats_batch())` (Prev*+estimate, один save), 2) init сессии, 3) `start_flood()` |
| `start_flood()` | Единая точка запуска (сессия/повтор/кнопка): pick пресета при `nil`, dry-check `RawEma > RawWet` (иначе skip), `PlannedFlood = Preset.dose()`, `Power{Num} 1` |
| `planned_dose()` | Эффективная доза для пресета `normal`: `estimateflood()` если оценка валидна, иначе `Counter1FloodDefault` |
| `estimateflood()` | Линейная экстраполяция на **Prev*** (`PrevSoilHPreFlood − PrevSoilMaxHymidity`, `PrevFloodedVol`); <15 мл или исключение → nil (fallback на default) |
| `_pick_preset()` | Выбор стратегии: `RawEma > DryThreshold` → `FloodPreset('dry', Store, Prefix)`; иначе `FloodPreset('normal', ...)`. Ставит `DrySoakDose`/`DrySoakStartMillis` для dry |
| `_stats_batch()` / `max_batch()` | Пары `[P{Num}ключ, value]` для `save_batch_entries`: старт сессии (7) / подтверждение Max (2) |
| `rule_power(value)` | Диспетчер события канала: `State` 1/0 → `water_on()`/`water_off()`; неизвестный — WARNING |
| `water_on()` | Старт: защита от мокрой почвы, `FinishRule = COUNTER#C1 >= ...` (общий счётчик), быстрая телеметрия, RateMeasuring |
| `water_off()` | Стоп: читает Counter1, `_compensate_backflow()`, затем `_record_flood()` (вода прошла) или `_end_session_no_water()` (нет воды), таймер возврата TelePeriod |
| `ticks(vol_ml)` | Граница C1: перевод объёма мл → тики (`round(ml / FlowScale)`); nil/<=0 scale → тождество (int); nil объём → nil. Используется в `water_on` (FinishRule), `_compensate_backflow`, `json_append` (телявые объёмы экспортируются в тиках) |
| `_compensate_backflow(Counter1)` | Вычитает backflow (мл → тики через `ticks()`) из счётчика (preset `counter1`) и из дельты, возвращает нетто-объём (тики) |
| `_record_flood(CounterDeltaTicks)` | Фиксирует дозу: `DeltaMl = CounterDeltaTicks × FlowScale` (guard на scale), `LastFloodVol += DeltaMl`, `LastFloodTime=now`, `LastFlowRate = DeltaMl*60000/PumpRunMillis` (настоящие мл/мин, guard на `PumpRunMillis` set/>0, иначе nil); при dry — пушит `{ms, vol}` в `DryDailyVol` (каденс SoakInterval); при normal и `LastFloodVol > MaxFlood` — `remove_timer` + `_autoflood_end()` (сессия закрыта капом объёма, таймер проверки не ставится); иначе таймер проверки 2ч, пере-арм `ID_SOILTRANSITION_AFTERFLOOD_P{Num}` |
| `_end_session_no_water()` | Помпа работала без воды: закрывает сессию без таймера проверки почвы |
| `rule_flooded()` | Триггер лимита: счётчик достиг порога → `Power{Num} 0` |
| `timer_soil_transition_after_flooded()` | Диспетчер оценки результата: при `Preset != nil` → `Preset.evaluate()`, иначе классика `_escalate_evaluate()`; 'repeat' → `Owner.request_repeat(self)` |
| `_autoflood_end()` | Завершение: сброс флагов/пресета, опциональный отложенный сброс счётчика, восстановление слежения за Max |
| `_drysoak_end()` | Завершение dry-сессии: сброс `AutofloodInProcess`, `Preset`, `DrySoakDose`, `DrySoakStartMillis`, `DryEmaHistory`, `DryDailyVol` (Prev* не пишет) |

### FloodPreset (стратегия сессии)
| Метод | Роль |
|-------|------|
| `dose(watering)` | Доза для запуска: `dry` → `DrySoakDose` (стартует с `SoakStartDose`); `normal` → `planned_dose()` |
| `evaluate(plant)` | Диспетчер пост-поливной проверки: `dry` → `_evaluate_trend()`, `normal` → `_evaluate_escalate()`; возвращает `'repeat'/'hold'/'pause'/'stop'` (запуск НЕ делает — арбитр `request_repeat`) |
| `_evaluate_trend(plant)` | Сухая замочка: stop при `RawEma < StopRaw`, кольцо `DryEmaHistory`, DailyCap-пауза, repeat пока окно не заполнено, эскалация `×DoseGrow` (кап `SoakMaxDose`) либо hold |

## Ключевые флаги-состояния (per-channel, поля Plant)

| Флаг | Смысл |
|------|-------|
| `AutofloodInProcess` | true — идёт сессия канала (влияет на `due()`); ставится только `start_session()`, снимается `_autoflood_end()`/`_drysoak_end()`/`_end_session_no_water()` |
| `PauseSoilMaxStat` | true — слежение за минимумом влажности приостановлено (во время пролива и до завершения сессии) |
| `Preset` | активная стратегия сессии канала (`FloodPreset` 'dry'/'normal'); ставится `_pick_preset()`, снимается `_autoflood_end()`/`_drysoak_end()` |
| `DryThreshold` | RAW-порог переключения на сухую замочку (persist `P{Num}DryThreshold`, дефолт 820); он же `StopRaw` пресета dry |
| `DrySoakDose` | адаптивная доза dry-замочки (мл): стартует с `SoakStartDose` (15), растёт `×SoakDoseGrow` (кап `SoakMaxDose` 300 мл) |
| `DrySoakStartMillis` | момент старта текущей dry-замочки (для отчёта команды `DrySoak`) |
| `DryEmaHistory` | in-memory кольцо `{ms, ema}` тренда за `SoakTrendWindow` (24ч), не персистится |
| `DryDailyVol` | in-memory кольцо `{ms, vol}` объёмов в мл за 24ч для `SoakDailyCap` (220 мл), не персистится |
| `Counter1ResetPostpone` | запрошен сброс счётчика, но отложен до конца сессии канала |
| `PlannedFlood` | запланированный объём дозы (мл) для текущего запуска: `Preset.dose()`; выставляется внутри `start_flood()` (пока `RawEma > RawWet`) |
| `FinishRule` | активное правило `COUNTER#C1>=...` канала; снимается при остановке помпы |
| `WaterIsOn()` | Читает `tasmota.get_power(Num-1)` напрямую (реле канала); источник правды — железо, кэша нет |
| `SoilMaxHymidity` | последний **подтверждённый** минимум влажности (non-nil = подтверждено); persist `P{Num}SoilMaxHymidity` — после ребута восстанавливается и сразу эмитится в телеметрию; инвалидизируется (nil, in-memory) в `every_second`, когда `RawEma < SoilMaxHymidity` при `!PauseSoilMaxStat && _stats_enabled()` — почва влажнее пика |
| `SoilMaxHymidityTemp` | текущий трекаемый минимум (в память, не персистится); подтверждается после роста `RawEma > Temp+5` на новом минимуме и переносится в `SoilMaxHymidity` |

## Ключевой цикл самокоррекции (одного канала, с арбитражем)

```
auto_flood (sweep, round-robin) → Plant.start_session → _pick_preset (dry/normal) → start_flood() →
Power{Num} 1 → water_on() → COUNTER#C1 превышен →
rule_flooded → Power{Num} 0 → water_off() → таймер 2ч (dry: SoakInterval) →
timer_soil_transition_after_flooded →
  normal/escalate: сухо? (доза ×1.2, 'repeat' → request_repeat → start_flood()) : _autoflood_end → IDLE
  dry/trend:      RawEma<StopRaw → _drysoak_end → IDLE
                  | нет отклика → DrySoakDose×1.2 (кап MaxDose) + repeat
                  | DailyCap → pause (пере-арм)
                  | влажность растёт → hold (пере-арм)
Арбитраж: пока любой канал имеет WaterIsOn() (_flooding_plant != nil), sweep пропускается,
а repeat/manual откладывается на 60с (retry-пере-арм soil-таймера) — общий счётчик C1 сериализует заливки.
```

## Сухая замочка (команда/веб) — канал 1

- Команда `DrySoak` (регистрируется в `init_sensors()`, снимается в `deinit()`): пусто/`status` → строка `preset=…, DryThreshold=…, dose=…, since=…`; `start` → принудительная dry-замочка на канале 1 (пресет `dry`, доза `SoakStartDose`, через `request_manual`), иначе `resp_cmnd_error()`.
- Веб: настройки канала — кнопка `⚙` (label `Настройки порогов`) в группе `Уставки` detail канала, JS-попап, суффиксные арги `m_drythr_N`/`m_soakdose_N` (+ `m_soildry_N`/`m_soilwet_N` для порогов; bare-арги = канал 1, legacy), пишутся в `P{Num}DryThreshold`/`P{Num}SoakStartDose` через `Store.set`, debounced; ряды `web_sensor()`: `Flooding in process`, `Dry soak` (`none` / `soak, dose N`), `Dry threshold`.
- Сухая замочка НЕ пишет Prev*/estimate-статы (`WriteStats=false`): `save_batch_entries` в `start_session`, трекинг `SoilMaxHymidity` и его инвалидация в `every_second` пропускаются (`_stats_enabled()`).

## Сервисный режим (Watering, не FSM-канал)

- Вход/выход строго по явным кнопкам на странице `/svc` (`?start=1` / `?exit=1`); простое открытие страницы режим не меняет (вкладка в браузере не должна ничего переключать). Команды форм страницы передаются скрытыми `input`-полями (а НЕ в `action='?...'`): по спецификации HTML5 GET-submit полностью перетирает query из `action` данными формы, поэтому аргументы в action до сервера не долетают (проверено браузером). Команда включения — `start`, а не `enter`: на этом стенде браузеры отказывались грузить URL с литеральной подстрокой `enter=1` в query (net::ERR_FAILED на навигациях Chrome; curl при этом отвечает 200) — `?start=1` проверен на живом браузере.
- `Watering.ServiceMode` (bool, in-memory, не персистится) + таймер `ID_SERVICE_MODE_TIMEOUT` = ровно 2ч (фикс, без учёта активности); повторный вход пере-армит таймер, `service_timeout()` (`?exit=1`) снимает его.
- В активном режиме заблокированы все точки запуска автополива: `auto_flood()` (sweep), `request_repeat()`, `request_manual()` — помпа НЕ включается.
- На главной странице при активном режиме — баннер «Сервисный режим: включен» (в `web_sensor()`).
- Управление каналами, сервисные прогоны и калибровка датчика потока живут на `/svc`. В **выключенном** режиме страница тоже показывает текущий `Scale (мл/тик)` C1, форму прямого ввода `?set=1&scale=коэф`, — если калибровка уже была — снэпшот `LastCalibration` (канал, объём, тики, время, тиков/мин), а также поле количества каналов `?channels=N` (пишется в Store-ключ `Channels` сразу, применяется после перезагрузки; при уменьшении параметры отключённых каналов из Store не удаляются), т.е. смотреть scale/менять коэффициент/число каналов можно без включения режима (`cal` по объёму и кнопки каналов доступны только при активном режиме). После смены каналов страница предлагает кнопку «Перезагрузить устройство» (`?restart=1` → отложенный ~1с `Restart 1`). При активном режиме:
  - Каждый канал — кнопки `?pump=N&on=1` / `?pump=N&off=1` → `tasmota.set_power(N-1, …)`, правило `POWER{Num}#State` диспетчеризует в сервисные ветки `water_on()`/`water_off()` (ключ — `Plant.ServiceRun`). Повторный ON уже горящего канала — no-op; старт второго канала, пока первый льёт (общий счётчик C1), отклоняется (арбитраж `_flooding_plant()`).
  - Сервисный прогон: без мокрого-грунта, без `FinishRule`/сессии/статистки, но с `TelePeriod 10` + rate-измерением и снимком `Counter1BeforeStart`; стоп отдаёт `Watering.ServiceResult = {num, ticks, millis}` (тики = C1-дельта, без компенсации счётчика) и пере-армит `ID_ENDFASTTELE` на 60с. `PulseTime` (60с) остаётся предохранителем.
  - Калибровка: `?cal=1&vol=мл` — `scale = объём / тики последнего прогона`; `?set=1&scale=коэф` — ручной ввод мл/тик (работает в любом состоянии режима). Результат (`service_set_scale`) пишется глобально (C1 общий) в Store-ключ `FlowScale` (default `0.1449`, политика `debounced`); `init_sensors()` читает его при старте (невалидное значение → фолбэк на встроенный scale). Успешная `cal` сохраняет `Watering.LastCalibration = {num, vol, ticks, millis, scale}` — его рендерит OFF-страница.
  - `service_exit()` дополнительно останавливает идущий сервисный прогон (`set_power` своего канала), таймер/баннер как выше.

## Параметры полива

Использованные сокращения:
- **RAW** — сырое значение почвенного датчика (ADC, приблизительно 0..4095); суше — выше (`IsDry()`: `Raw >= RawDry`, `IsWet()`: `Raw <= RawWet`).
- **тик C1** — импульс расходомера на общем счётчике Tasmota `COUNTER#C1`.
- **мл (единица канона)** — **внутренние объёмы-дозы хранятся в мл** (сессия, дозы, капы: `LastFloodVol`, `PrevFloodedVol`, `MaxFlood`, `Counter1FloodDefault`, `Counter1Backflow`, `SoakStartDose`/`SoakDailyCap`/`SoakMaxDose`, `DryDailyVol`). В тики переводится только на границе C1: правила `COUNTER#C1 >= …` и вычитание backflow — через `Plant.ticks()` (`ml / FlowScale`); в телеметрии `json_append()` мл-объёмы экспортируются **обратно в тики** (`ticks(ml)`) — контракт InfluxDB не меняется.

### Глобальные (Watering, общие для всех каналов)

| Параметр | Где задан | Store-ключ | Default | Размерность | Описание |
|---|---|---|---|---|---|
| `Channels` | `Watering.init()` | `Channels` (immediate) | 2 | шт | число каналов, clamp `[1, MAX_CHANNELS=4]`; задаётся на `/svc` (`?channels=N`, применяется после перезагрузки; параметры отключённых каналов в Store не удаляются) |
| `FlowScale` | `FlowSensors[0]` | `FlowScale` (debounced) | 0.1449 | мл/тик C1 | калибровка расходомера C1, общий счётчик всех каналов; пишется с `/svc` (калибровка/ручной ввод) |

### Per-Plant: захардкожены в `Plant.init()`

Не персистятся, одинаковы для всех каналов; меняются только в коде.

| Параметр | Store | Default | Размерность | Описание |
|---|---|---|---|---|
| `MaxPumpRun` | нет | 60 | с | кап времени работы помпы → `PulseTime{Num}` (аппаратный предохранитель этого FSM) |
| `MaxFlood` | нет | 300 | мл | кап объёма сессии: `LastFloodVol > MaxFlood` → сессия закрывается; одновременно кап эскалации `Counter1FloodDefault` |
| `Counter1FloodDefault` | нет | 30 | мл | доза полива по умолчанию (fallback, когда `estimateflood()` вернул nil); при повторной заливке растёт ×1.2 до `MaxFlood` в RAM и теряется при рестарте |
| `Counter1Backflow` | нет | 0 | мл | компенсация обратного потока (для труб без обратного клапана, в коде закомментирован пример 19 мл) |

### Per-Plant: персистятся под префиксом `P{Num}`

Регистрируются `Store.register_channel()` c политикой `debounced`; меняются через веб-настройки канала (пороги/сухая замочка) или Store.

| Параметр | Где задан | Store-ключ | Default | Размерность | Описание |
|---|---|---|---|---|---|
| `TargetDry` → `RawDry` | `SoilSensor` | `P{Num}TargetDry` | 800 | RAW | уровень «сухо»: `Raw >= RawDry` → `IsDry()` (претендент на полив) |
| `TargetWet` → `RawWet` | `SoilSensor` | `P{Num}TargetWet` | 760 | RAW | уровень «влажно»: `Raw <= RawWet` → `IsWet()` (стоп-критерий нормального пресета и вход `estimateflood()`) |
| `DryThreshold` | `Plant` | `P{Num}DryThreshold` | 820 | RAW | выбор пресета: `RawEma > DryThreshold` → dry soak; он же `StopRaw` (выход из замочки) |
| `SoakStartDose` | `Plant` | `P{Num}SoakStartDose` | 15 | мл | стартовая доза сухой замочки |
| `SoakInterval` | `Plant` | `P{Num}SoakInterval` | 7200 | с | каденс сухой замочки (пересдача/пауза) |
| `SoakTrendWindow` | `Plant` | `P{Num}SoakTrendWindow` | 86400 | с | окно тренда `RawEma` для адаптации дозы |
| `SoakDoseGrow` | `Plant` | `P{Num}SoakDoseGrow` | 1.2 | множитель | рост дозы замочки при отсутствии отклика |
| `SoakDailyCap` | `Plant` | `P{Num}SoakDailyCap` | 220 | мл | суточный лимит объёма замочки |
| `SoakMaxDose` | `Plant` | `P{Num}SoakMaxDose` | 300 | мл | кап дозы замочки |
| `LastFloodVol` | `Plant` | `P{Num}LastFloodVol` | 0 | мл | накопленный объём текущей сессии; на старте следующей архивируется в `PrevFloodedVol` |
| `SoilHPreFlood` | `Plant` | `P{Num}SoilHPreFlood` | nil | RAW | EMA до полива (текущая сессия) |
| `SoilMaxHymidity` / `SoilMaxHymidityTime` | `Plant` | `P{Num}SoilMaxHymidity` / `…Time` | nil | RAW / timestamp | максимум влажности после полива (текущая сессия) |
| `PrevSoilHPreFlood` | `Plant` | `P{Num}PrevSoilHPreFlood` | nil | RAW | вход `estimateflood()`: EMA до прошлой сессии |
| `PrevSoilMaxHymidity` | `Plant` | `P{Num}PrevSoilMaxHymidity` | nil | RAW | вход `estimateflood()`: макс. влажность после прошлой сессии |
| `PrevFloodedVol` | `Plant` | `P{Num}PrevFloodedVol` | nil | мл | вход `estimateflood()`: объём прошлой сессии |

### `estimateflood()` и планирование дозы

- **Формула** (watering.be `Plant.estimateflood()`):
  `EstimatedFlood = PrevFloodedVol × (RawEma − RawWet) / (PrevSoilHPreFlood − PrevSoilMaxHymidity)`.
- Использует персистенные `Prev*` (выше) и динамику: `RawEma` (in-memory EMA, `EMAN=600`, smoothing `k=2/(N+1)`) и `RawWet` (`P{Num}TargetWet`).
- Если `EstimatedFlood < 15` (мл) или исключение/отсутствие данных → `nil` → `planned_dose()` возвращает `Counter1FloodDefault`.
- Пресет `normal` (выбран когда `RawEma <= DryThreshold`): доза = `estimateflood()` либо default; повторный прогон при недополиве — `Counter1FloodDefault × 1.2` (кап `MaxFlood`).
- Пресет `dry` (сухая замочка, `RawEma > DryThreshold`): доза = `DrySoakDose` (стартует с `SoakStartDose`, адаптируется `SoakTrendWindow`/`SoakDoseGrow`/`SoakMaxDose`, лимит `SoakDailyCap`/24ч), `estimateflood()`/`Prev*` НЕ используются (`WriteStats=false`).

### Сессионные и служебные поля (не персистятся)

`PumpStartMillis`, `PumpRunMillis`, `Counter1BeforeStartTicks`, `FinishRule`, `PlannedFlood`, `AutofloodInProcess`, `ServiceRun`, `ServiceResult`, `LastFlowRate` (настоящие мл/мин: `DeltaMl×60000/PumpRunMillis`), `DrySoakDose`, `DrySoakStartMillis`, `DryEmaHistory`, `DryDailyVol`, `PauseSoilMaxStat` — живут только в RAM и обнуляются при рестарте устройства.

### Миграция размерности (тики → мл)

При переходе итерации «всё в тиках C1» в «мл — канон» персистенные значения не переносятся как есть: `Watering._migrate_units(FlowScale)` один раз (маркер `UnitsV2`, ключ с политикой `immediate`) пересчитывает **только реально сохранённые** ключи `P{Num}SoakStartDose/SoakDailyCap/SoakMaxDose/LastFloodVol/PrevFloodedVol` по формуле `round(тик × FlowScale)` (дефолт шкалы `0.1449`, clamp на nil/<=0). Неперсистенные ключи сохраняют уже-мл дефолты реестра. На устройстве с `Scale=0.1408`: `SoakStartDose 100 → 14`, `SoakDailyCap 1500 → 211`, `SoakMaxDose 2000 → 282` мл.
