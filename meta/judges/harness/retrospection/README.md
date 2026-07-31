# Retrospection Harness (M-13 / C5)

Локальный тест-харнес для проверки петли саморефлексии итераций <проект>.

> **Зона ответственности:** Глаз бога (см. [[feedback_testing-infra-is-my-job]]).
> Харнес должен **реально проходить** на текущем коде ретроспектора/памяти/гейтов,
> а не считаться рабочим «по старому аудиту».

## Что проверяет

Сквозной прогон петли на синтетических фикстурах:

1. **Retrospector** (`retrospector` из `D:\<проект>\.claude\agents\`) —
   получает фикстурный транскрипт+diff+verdicts → выдаёт JSON с root-causes и proposals.
   Сверяем с `expected/<fixture>.json`.
2. **Memory inject** — на следующей итерации (того же сценария) проверяем, что
   anti-pattern из шага 1 матчится по embedding и подмешивается в системный контекст
   (фикстура `recall-after-write`).
3. **Subagent-finding gate** — фикстура с `must_address: true` finding от vision-judge,
   на которую кодовый агент не отреагировал, → гейт должен **блокировать** закрытие
   итерации.

## Структура

```
retrospection/
├── README.md             # этот файл
├── run.ps1               # точка входа: pwsh run.ps1
├── runner/
│   ├── run-fixture.ps1   # прогон одной фикстуры
│   ├── compare-json.ps1  # семантическое сравнение с expected (поля, не порядок)
│   └── env-check.ps1     # LM Studio / Postgres / агент существуют
├── fixtures/
│   ├── F01-ignored-vision-finding/   # игнор must_address от vision-judge
│   ├── F02-repeated-mock-as-real/    # повторение mock-as-real ошибки
│   └── F03-arch-violation/           # нарушение arch-consistency проигнорировано
└── expected/
    ├── F01.json
    ├── F02.json
    └── F03.json
```

## Запуск

```powershell
pwsh "<BCF_HOME>/meta/judges/harness/retrospection/run.ps1"
```

Выход — markdown-отчёт в `$(Join-Path $env:BCF_PROJECT_ROOT '.bcfetros')\M-13-harness-run-<YYYY-MM-DD>.md`.

## Зависимости (env-check)

- LM Studio с загруженной `bge-m3` на `http://localhost:1234/v1/embeddings`.
- Postgres с pgvector, БД `bcf_agent_memory`, схема `agent_memory` (см. M-13 C2.0).
- `$(Join-Path $env:BCF_PROJECT_ROOT '.claudegentsetrospector.md')` существует.
- Хук `$(Join-Path $env:BCF_PROJECT_ROOT '.claude\hooks\subagent-finding-gate.sh')` существует и исполняем.

`env-check.ps1` падает явным сообщением, если чего-то нет — это **ожидаемое красное состояние**
до завершения C1/C2/C4. Не правим харнес под отсутствие зависимостей.

## Семантика expected/*.json

Сравнение не строковое. `compare-json.ps1` проверяет:

- `root_causes[*].category` — точное совпадение из словаря категорий (`wiki/categories/root-cause.md`).
- `ignored_subagent_findings[*].agent` + `.finding_id` — точное.
- `proposals[*].kind` — точное; `target` — substring-match (имена скилов/файлов могут
  слегка дрейфовать).
- Лишние поля в actual допускаются; недостающие из expected — fail.

## Политика обновления фикстур

Менять `expected/*.json` можно только вместе с записью в
`projects/<проект>/audit-log.md` («почему ожидание изменилось»).
Иначе харнес теряет смысл как регресс-сеть.
