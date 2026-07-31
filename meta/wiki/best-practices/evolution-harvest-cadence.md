# Эволюционный harvest: как мета-слой закрывает петлю самоулучшения

**Категория:** best-practices. Введено 2026-05-31 (samanta M-19).

## Петля
```
ретроспектор (каждая итерация) → proposals {skill_new|skill_update|subagent_skill}
   → persist в agent_memory.proposals (дедуп по kind+target, count = частота)
   → REVIEW.md «Эволюция: топ по частоте» (каждый run-all)
   → ГЛАЗ БОГА: harvest → триаж → реализация → status=done
```
Раньше петля была разомкнута: proposals генерились, но не персистились (только anti_patterns) —
испарялись. Теперь копятся с частотой; **частота = приоритет** (что система предлагает чаще всего).

## Команды
```bash
python .claude/memory/memory_client.py harvest-proposals --status new --limit 30   # топ к реализации
python .claude/memory/memory_client.py harvest-proposals --status all              # вся история
```

## Процесс Глаза бога (после каждого run-all или раз в N прогонов)
1. Открыть REVIEW.md → секция «Эволюция» (или `harvest-proposals`).
2. Триаж топ-по-частоте:
   - `skill_new`/`skill_update` → создать/улучшить `.claude/skills/<slug>/SKILL.md`.
   - `subagent_skill` → усилить `.claude/agents/<name>.md` (привязать skill, добавить чеклист).
   - Механически-проверяемый рецидив (высокий count + grep-able) → промоут в БЛОКИРУЮЩИЙ хук
     (как renderer-boundary-guard), а не только recall. Recall ≠ enforcement.
3. После реализации — пометить `status=done` (UPDATE agent_memory.proposals SET status='done'
   WHERE kind=.. AND target=..), нерелевантные → `rejected`.

## Правила
- **Только при ОСТАНОВЛЕННОМ ralph-цикле** (см. common-errors: M-17 изоляция реверит tracked-правки
  и удаляет untracked-файлы при работающем loop). Останови loop → правь harness → рестарт.
- Высокочастотный anti_pattern (hits ≫) — сигнал «recall не держит» → промоут в хук/лишт.
- Skills — позитивная способность; prohibitions → anti_pattern; enforcement → hook.
