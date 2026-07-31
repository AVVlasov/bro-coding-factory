# Skill (draft): retro-metrics

Skill для Глаза бога — собрать метрики «здоровья» петли ретроспекции для проекта.

## Use when

При периодическом аудите (раз в 1–2 недели) или при подозрении, что петля
деградирует (ретроспектор штампует пустые JSON, память не вспоминается,
finding'и снова игнорируются).

## What it produces

Markdown-отчёт в `D:\eye of god\projects\<project>\retros\metrics-<YYYY-MM-DD>.md`
со следующими разделами:

1. **Vector memory health**
   - всего записей в `agent_memory.anti_patterns`
   - записей за последние 14 дней
   - top-10 по `hits` (часто-вспоминаемые грабли — кандидаты в `skills/`)
   - «холодные» (0 hits за 60 дней) — кандидаты в архив
2. **Recall coverage**
   - recall_events за последние 14 дней / 30 дней
   - доля итераций с recall (по уникальным `iteration_id`)
   - средний similarity у successful recall'ов
3. **Ignored findings trend**
   - доля ретроспективных JSON, где `ignored_subagent_findings` не пуст
   - сравнение последних 14 дней vs предыдущих 14
4. **Judge activity**
   - retrospector-judge: ACCEPT/REJECT/NEEDS-MORE-EVIDENCE counts
5. **Skill-lint state**
   - кол-во `SKILL.md` с нарушениями (для samanta — baseline 2026-05-27 = 14/15)

## Implementation sketch

```powershell
# retro-metrics.ps1 — пока не существует, набросок.
$cfg = Get-Content 'D:\samanta_project\.claude\memory\db.config.json' | ConvertFrom-Json
$psql = { docker exec -e PGPASSWORD=$($env:SAMANTA_PG_PASSWORD ?? 'samanta_local_dev') `
            samanta-agent-memory psql -U $cfg.user -d $cfg.database -tAc $args[0] }

# 1. Memory
$total      = & $psql "SELECT count(*) FROM agent_memory.anti_patterns"
$last14     = & $psql "SELECT count(*) FROM agent_memory.anti_patterns WHERE created_at > now() - interval '14 days'"
$topHits    = & $psql "SELECT trigger_summary || ' (' || hits || ')' FROM agent_memory.anti_patterns ORDER BY hits DESC LIMIT 10"
$cold       = & $psql "SELECT count(*) FROM agent_memory.anti_patterns WHERE hits = 0 AND created_at < now() - interval '60 days'"

# 2. Recall coverage
$recalls14  = & $psql "SELECT count(*) FROM agent_memory.recall_events WHERE at > now() - interval '14 days'"
$iters14    = & $psql "SELECT count(DISTINCT iteration_id) FROM agent_memory.recall_events WHERE at > now() - interval '14 days'"
$avgSim     = & $psql "SELECT round(avg(similarity)::numeric, 3) FROM agent_memory.recall_events WHERE at > now() - interval '14 days'"

# 3-5: ретроспективные JSON хранятся в samanta retros/ — парсятся отдельно.

# Записать .md отчёт в D:\eye of god\projects\samanta_project\retros\metrics-<date>.md
```

## When NOT to use

Каждый день — overkill. Раз в день вызывает шум; интересен тренд за 1–2 недели.

## Related

- `D:\eye of god\wiki\best-practices\project-audit-checklist.md` §9 — чеклист, который
  этот отчёт автоматизирует.
- M-13 C6 — задача, в рамках которой драфт создан.

## Status

**Draft.** Полная реализация — отдельная мета-задача (M-XX) после того, как
M-13 базово работает и накопится 2 недели реальных recall_events.
