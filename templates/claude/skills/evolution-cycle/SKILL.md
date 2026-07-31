---
name: evolution-cycle
description: Use this skill when the user says "запусти цикл эволюции", "evolve", "обнови систему разработки", "что улучшить дальше", or implicitly after 30 commits / after Andrey-reported regression. It explains the 5-step cycle (OBSERVE → REFLECT → PROPOSE → APPLY → MEASURE), names the responsible agents per axis, and points the main agent at the `/evolve` slash command for orchestration. Mandatory reading: `docs/agentic/evolution-model.md`.
---

# Evolution cycle — behavioural guide

Самосовершенствующаяся модель разработки. Каждый цикл оставляет систему более зрелой по 7 осям одновременно (A1 архитектура, A2 harness, A3 design, A4 product value, A5 quality, A6 analytics, A7 UX/UI).

## When to invoke

- После 30 коммитов или 14 дней.
- После Andrey-reported regression.
- При прямом запросе пользователя.

## What to do

1. Прочитать [`docs/agentic/evolution-model.md`](../../../docs/agentic/evolution-model.md).
2. Запустить `/evolve` — see [`.claude/commands/evolve.md`](../../commands/evolve.md).
3. Цикл задействует трёх **новых** агентов:
   - `/evolve command` — OBSERVE.
   - `/evolve command` — REFLECT + PROPOSE.
   - `supervisor` — A4 axis evaluation.
4. Plus existing agents as evidence: `architecture`, `ux-vision`, `ux-vision`, `ux-vision`, `judge`.

## Hard rules (CLAUDE.md §15)

- Stable sections (CLAUDE.md §11/§12/§13.7/§14) **не эволюционируют** — изменения требуют decision-log + Andrey.
- Каждый цикл — **минимум +1 уровень на одной оси**, **0 регрессов** на остальных.
- Скоркард только апгрейдится; даунгрейд = новая запись с обоснованием.
- Каждая proposed delta имеет owner, DoD, predicted scorecard impact, anti-decay protection.

## Anti-patterns

- Запуск REFLECT без OBSERVE. Без сигналов это просто мнение.
- Предложение >9 deltas за цикл — не приоритизировано.
- Замалчивание carry-over deltas из предыдущего цикла.
- Hire-more-agents как дефолтная delta. Новый агент ≠ прогресс.
