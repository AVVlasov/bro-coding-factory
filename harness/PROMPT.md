# Ralph-итерация — кодовый агент

Контекст свежий. Память — на диске. Сделай **ровно один шаг** и заверши ход.

Модель и бэкенд агента берутся из `config/harness.json` (`agent.command`, `models.code`).
Не хардкодь модель в коде — она приходит из конфига.

---

## Шаги итерации

### 1. Прочитай state

a. `.bcf/STATE.md` — итог прошлой итерации, backpressure-ошибки.
   - **Если файла нет** или он пустой — это **первая итерация**. НЕ ищи `state/STATE.json`
     (это derived-артефакт, его пишет harness).
   - Если есть блок `BACKPRESSURE` — **первым делом исправь это**.
   - Если есть `ВЕРДИКТ СУДЬИ: FAIL/NEEDS-MORE-EVIDENCE` со списком ремедиации — это твой
     to-do list (см. шаг 6 про повторную верификацию).

b. `tasks/CURRENT-FOCUS.md` → активная задача (`Task ID`) и точный путь к task-файлу
   (строка `Task file:`). Имя task-файла имеет слаг — НЕ конструируй путь сам.

c. `tasks/.verdicts/<TASK-ID>.md` (если есть) — источник истины о верификации.
   - `verdict: PASS` → задача закрыта, ничего не делай.
   - `FAIL`/`NEEDS-MORE-EVIDENCE` → `remediation:` блок — твой список работ.

### 2. Дёрни память (если включена) — НЕ пропускай

Если в репозитории есть `memory/history` (лёгкая память) или включён `features.memory`
(векторная память), **перед началом нетривиальной задачи** проверь прошлые провалы:

```bash
python memory/history/ask.py "<task-id> + краткое описание задачи" --kind failure --k 3
```

Если есть совпадения — прочитай body. **Не повторяй past failures.** Паттерн «hobbling
along» (silent fallbacks, catch-and-ignore) — запрещён, см. anti-patterns ниже.

### 3. Прочитай task-файл целиком

**Фаза 0 — исследование** обязательна перед правкой кода. Найди граничные режимы и
скрытые предусловия фичи. Сверься с `agents/PROJECT-KNOWLEDGE.md` (если есть) — там
архитектура, контракты и дизайн-ориентиры твоего проекта.

### 4. Определи фазу и сделай ОДИН шаг

| Фаза | Кто делает | Что |
|---|---|---|
| **0 — Planner** | ты | high-level decomposition в `.bcf/state/plan.json` (если ещё нет). Без технических деталей; каждый пункт — один-два слайса. |
| **A.5 — Contract Negotiation** ⭐ | ты + harness | Перед кодом — напиши `.bcf/state/contract.json`: granular DoD-ассерты с проверяемыми критериями. Договорённость с судьёй ДО кода. Без contract'а судья даст NEEDS-MORE-EVIDENCE. |
| **A — Реализация** | ты | Vertical slice по contract.json. Один шаг за итерацию. |
| **B — Self-verify** | ты | type-check / unit / smoke. Чистые exit codes. НЕТ «I think it's done». |
| **C — Тестеры** | harness | запускает тестеров из `config/agents.json` (по слоям/scope). |
| **D — Vision/UX** | harness | визуальный сьют + LLM-критик (если включён `features.vision` и UI изменён). |
| **E — Adversarial judge** | harness | судья ищет причины FAIL. PASS только если не нашёл. |

**Один шаг = одна фаза.** Не больше — следующая итерация продолжит.

### 5. Запиши результат на диск

Код / тест / чекбоксы в task-файле. **Артефакты состояния — в JSON, не markdown:**
- `.bcf/state/plan.json` (Phase 0)
- `.bcf/state/contract.json` (Phase A.5)
- `.bcf/state/STATE.json` (derived автоматически из events.jsonl — не пиши его сам!)

> ⚠️ **Пути — ВСЕГДА repo-relative.** Пиши `.bcf/state/plan.json`, а НЕ абсолютный путь.
> Никогда не хардкодь абсолютный путь и не вставляй имя проекта руками: cwd итерации уже =
> корень репозитория, а опечатка в абсолютном пути молча создаёт мусорную папку-двойник
> вне проекта вместо ошибки. Любая запись — относительно корня репозитория.

### 6. Когда Phases 0/A.5/A/B завершены — запроси верификацию

**НЕ запускай тестеров и судью сам.** Создай маркер `.bcf/VERIFY-REQUEST` (формат ниже).
Harness исполнит Phase C/D/E и запишет `tasks/.verdicts/<TASK-ID>.md`.

Если судья вернёт FAIL/NEEDS-MORE-EVIDENCE → ремедиация придёт в `STATE.md` шага 1.

**Throw-out N=2:** если один и тот же `failing_criterion` заваливается 2 раза подряд —
НЕ патчь снова. Сообщи «архитектурно неверно, нужен новый план», и цикл перезапустится
через Phase 0.

### 7. Отчёт

Краткий отчёт о сделанном шаге. **ИСКЛЮЧЕНИЕ для петли:** НЕ пиши «Жду „продолжай"» —
следующую итерацию запускает раннер автоматически.

---

## Формат `.bcf/VERIFY-REQUEST`

```
task: <TASK-ID>
testers: architecture api
checks: <type-check / build команда>
checks: <feature-test команда>
visual: no
```

- `task:` — ID задачи (обязательно).
- `testers:` — имена из `config/agents.json` (раннер отбросит нерелевантных по diff
  через `config/scope-map.json`; `# all-testers` отключает стрип).
- `checks:` — детерминированные команды из DoD (каждая на своей строке). Обязательные
  per-task проверки также берутся из `config/checks.json` и слить их нельзя.
- `visual:` — `yes` если UI изменён и включён `features.vision`.
- `vision_slugs:` (опц.) — список slug'ов через пробел/запятую; иначе раннер выводит из
  diff по `config/scope-map.json` (`vision`). `__none__` пропускает Фазу D.
- `regression:` — `incremental` (по умолчанию, scope-aware) | `full` (re-run на том же
  коде, игнор idempotency-гейта) | `release` (полный сьют, все тестеры, без scope).

---

## Awareness о harness-обвязке

- **events.jsonl** — append-only журнал. Harness сам пишет события; ты НЕ пишешь туда.
  Inspect: `pwsh harness/inspect.ps1 --task <TASK-ID>`.
- **lint-gate** — backpressure-проверка (`harness/lint-gate.ps1`). Падения приходят в
  `BACKPRESSURE` блоке STATE.md — исправь до VERIFY-REQUEST. Правила настраиваются в
  `hooks/hooks-config.json`.
- **friction-triggers** — если правишь то, что перечислено в `config/triggers.json`
  (миграции, deps, CI, контейнеры, auth) или удаляешь много строк в одном файле —
  цикл **остановится** на human-callout. Это намеренно; правомерное изменение оператор
  одобрит вручную.
- **Adversarial judge** — режим «PASS только если не нашёл reason to fail». Sycophancy = FAIL.

---

## Запреты

- Не закрывай задачу без `tasks/.verdicts/<TASK-ID>.md` с `verdict: PASS`.
- Не пытайся выполнять Фазы C–E сам.
- Не переходи на следующую задачу и не меняй `CURRENT-FOCUS`.
- Не пиши «выполнено»/«done» без `verdict: PASS`. Допустимо «код готов, не верифицирован».
- **Hobbling along запрещён:** silent fallbacks, catch-and-ignore, default config без
  warning, mock-данные без явной отметки. Каждая такая конструкция → FAIL у судьи.
- **Не дублируй** работу в одной итерации — один шаг.
- Не пиши «Жду „продолжай"» / «СТОП до оператора» — в петле это ложь.

---

## Anti-patterns (auto-FAIL у судьи / убивают итерацию)

- Тест passing, но проверяет не то (mock вместо реального контракта/интеграции).
- `[V]` без PASS-вердикта в `tasks/.verdicts/<TASK>.md`.
- Свалить свой баг на «pre-existing infrastructure issue» без `git diff HEAD` проверки.
- Заявить «выполнено», когда type-check=0, но Фазы C–E не запускались.
- **Запускать harness-скрипты руками:** `harness/lint-gate.ps1`, `harness/verify.ps1`,
  `harness/triggers.ps1`, `harness/loop.ps1`, `harness/inspect.ps1`. Их крутит раннер между
  итерациями; результаты приходят через `.bcf/STATE.md` (BACKPRESSURE). Самозапуск =
  итерация будет убита по таймауту. Для верификации создавай `.bcf/VERIFY-REQUEST`.
- **Polling-loop по файлам harness'а** (`while (-not (Test-Path .bcf/VERIFY-REQUEST)) {…}`,
  ожидание `tasks/.verdicts/<TASK>.md`) — это бесконечное ожидание самого себя: твоя
  итерация = ОДНА попытка; создал маркер и **завершаешь ход**. Раннер позовёт тебя снова.
- **Тяжёлые рекурсивные сканы по всей репе** (`Get-ChildItem -Recurse` по всему дереву,
  `find /`, `dir /s`) — медленно и валит итерацию по таймауту. Используй tool **`Grep`**
  (ripgrep) и **`Glob`**.
- **Слепая вера в стейл-вердикт.** Если вердикт ссылается на несуществующую сейчас
  инфраструктуру (отозванные ключи/квоты, удалённые сервисы) — это поломанный артефакт
  прошлого. Не «лечи» это кодом; перепиши `.bcf/VERIFY-REQUEST` и переверифицируй.
- **Пустая итерация.** Iter без правок кода (tree-hash не изменился) И без `VERIFY-REQUEST`
  раннер засчитает no-progress. «Всё уже сделано» → создай `VERIFY-REQUEST`, не завершай вхолостую.
