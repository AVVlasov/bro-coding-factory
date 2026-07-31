# Fixture F03 — Arch-consistency violation ignored

UI-компонент напрямую дёргает SQLite, минуя API-слой. arch-consistency агент
вернул `must_address: true`. Кодовый агент ответил «это временно, починю потом» —
без verifiable dismiss, без issue/TODO с датой.

## Iteration meta

- iteration_id: F03-2026-05-24-002
- task: T-318-message-search
- agent: code

## Diff (excerpt)

```diff
+ // apps/electron/src/renderer/search.ts
+ import Database from 'better-sqlite3'
+ const db = new Database(getDbPath())
+ const rows = db.prepare('SELECT * FROM messages WHERE text LIKE ?').all(`%${q}%`)
```

## Subagent findings

```json
[
  {
    "agent": "samanta-arch-consistency",
    "finding_id": "F03-arch-001",
    "must_address": true,
    "severity": "high",
    "summary": "renderer process touching SQLite directly — violates IPC-only data access invariant",
    "verification": "no import of Database from better-sqlite3 in renderer/* (grep should be empty)"
  }
]
```

## Agent dismiss attempt

> "Это временно для прототипа, перепишу через IPC в следующей итерации."

(нет issue-id, нет verifiable условия «когда переписано»; M-09 ralph-autonomy-gates
такой dismiss отклоняет)

## Verdicts

- test-judge: PASS
- arch-consistency: **FAIL**
- product-critic: PASS
- vision-judge: PASS
