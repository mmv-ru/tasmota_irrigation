# Workflow разработки

Два варианта работы с ветками: постоянная dev-ветка и свежая ветка на каждый цикл.

## Рабочий процесс A: постоянная dev-ветка

Для паттерна «одна долгоживущая ветка» (например, `feature/ai-irrigation-dev`):

1. **Перед PR**: `git fetch origin && git merge origin/main` (или rebase) в dev-ветку — ветка в курсе main, конфликтов минимум.
2. **Merge PR на GitHub через «Create a merge commit»** — SHA коммитов в main и dev совпадают, дублей не возникает. Не использовать «Rebase and merge»: он пересоздаёт коммиты с новыми хешами → ветка расходится с main.
3. **Сразу после merge**: синхронизировать dev-ветку с main — `git checkout dev && git merge origin/main` (fast-forward, т.к. ветка была источником). Дальше работа идёт с чистого листа.
4. **Локальный main**: всегда `git fetch` / `git pull --ff-only` после merge — не держать его устаревшим.

**Опасность**: если влить PR через Rebase-and-merge или не синхронизировать ветку после merge, накопятся дубли (те же коммиты с другими SHA), PR начнёт показывать «лишние» коммиты, появятся конфликты.

## Рабочий процесс B: свежая ветка на каждый цикл (рекомендуется)

GitHub Flow — проще и безотказно:

1. Конец сеанса → PR `feature/<имя>` → main.
2. Merge PR через **«Create a merge commit»**.
3. `git fetch origin && git checkout main && git pull --ff-only`.
4. Новая ветка создаётся **прямо из main**: `git checkout -b feature/<имя>` — она уже на актуальном main, шаг «merge из main» не нужен.

Если ветка создана заранее, а main за это время продвинулся: `git merge origin/main` (или rebase) перед работой/PR.

**Почему B лучше**: ветка живёт один цикл → нет накопления дублей, нет расхождения хешей, PR всегда показывает только свежие коммиты.

## Чистка уже разошедшихся веток

Если ветка разошлась с main (те же коммиты с другими SHA после Rebase-and-merge):

1. `git fetch origin`
2. `git rebase --onto origin/main <последний общий коммит>` — переложить только новые коммиты, отбросить дубли.
3. `git push --force-with-lease origin <ветка>`
4. `git checkout main && git merge --ff-only origin/main`

Определить новые коммиты можно так: `git cherry origin/main <ветка>` — `+` новые, `-` дубли (уже есть в main).
