# /start

> **Что делает.** Запускает `supervisor` — autonomous session orchestrator. Он читает state (CLAUDE.md, CURRENT-FOCUS, decisions tail, red-team verdicts) и **сам решает что делать дальше**, объявляет в 8 строк, авто-создаёт task-files если CURRENT-FOCUS не имеет активной задачи.
>
> Это **первое**, что делается в каждой новой сессии. SessionStart hook прилетает первым system message — он подсказывает «запусти /start или прочитай CURRENT-FOCUS вручную».

## Usage

```
/start                # обычный auto-orchestration
/start --dry          # только декларация плана, без auto-task-creation
/start --refresh      # принудительно перечитывает CURRENT-FOCUS (если внешне правился)
```

## What it does

1. Spawns `supervisor`.
2. Orchestrator:
   - reads CLAUDE.md / CURRENT-FOCUS / decisions tail / red-team verdicts;
   - applies decision tree (см. agent spec);
   - announces ONE next action (≤8 lines);
   - if appropriate — auto-creates D-<seq>-*.md task files from CRITICAL/HIGH findings;
   - hands off to user for approval or to specialist agent for execution.

## When NOT to use

- Mid-task (already implementing something). `/start` для re-orientation, не interrupt.
- Если ты уже знаешь точно что делать — иди делать.

## Sample output

```
🧭 Orchestrator — Task (none yet)

Decided next action:
  Run sanity check before starting work.
  Owner: main
  Command: <backpressure.typecheck из config/harness.json>

Blockers (require Andrey approval before proceeding):
  - none (sanity is permitted)

Will auto-create:
  - nothing this turn — after sanity + red-team I'll auto-create D-1..4 from F-1..F-4.
```

## Triggers (informational)

Главный агент **обязан** вызвать `/start` или прочитать CURRENT-FOCUS:
- В начале каждой новой сессии (SessionStart hook напоминает).
- После любого user-reported regression — могла поменяться CURRENT-FOCUS.
- При неуверенности «что делать дальше».
