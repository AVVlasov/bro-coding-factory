# Architecture

## The loop (per iteration)

```
┌─ loop/loop.ps1 ────────────────────────────────────────────────┐
│ 1. read loop/STATE.md (last iter result + backpressure)        │
│ 2. run the agent ONE step in a FRESH context                   │
│      agent.command from config/harness.json, prompt = PROMPT.md │
│      + STATE.md, piped on stdin                                 │
│ 3. backpressure: type-check + lint-gate + friction-triggers    │
│      failures → written back into STATE.md for the next iter    │
│ 4. agent drops loop/VERIFY-REQUEST when code is ready           │
│ 5. runner invokes loop/verify.ps1 (Phases C–E)                 │
│ 6. verdict written to tasks/.verdicts/<TASK>.md                │
│      PASS → stop for human review (bounded mode)               │
└────────────────────────────────────────────────────────────────┘
```

Safety rails: iteration timeout (process-tree kill), optional network/SSE-stall watchdog,
loop-detection (same error ×N → stop), no-progress detection (N iters without product-code
change → stop), MaxIterations ceiling, `loop/STOP` file, durable git WIP snapshots
(`refs/loop/wip/<task>`), idempotency gate (skip verify when nothing changed).

The agent only ever runs phases **0 → A.5 → A → B** (plan, contract, implement, self-verify).
Phases **C → D → E** are executed by the harness, never the agent.

## Verification (loop/verify.ps1)

- **Phase C — testers:** each configured LLM tester runs isolated, in a fresh context, with
  the diff + task scope. Heartbeat / silent-timeout protection; orphan-process reaper.
- **Phase D — visual (optional, `features.vision`):** deterministic visual contract run +
  optional LLM vision critic.
- **Phase E — judge:** an isolated adversarial judge ("PASS only if I can't find a reason to
  fail"). **Advisory only.**
- **Verdict is deterministic:** PASS ⟺ every gate is green (checks exit 0 + lint + in-scope
  visual). The judge's opinion influences remediation, not the verdict. Result + machine-
  collected evidence → `tasks/.verdicts/<TASK>.md`.

## Event sourcing

`loop/lib/event-bus.ps1` appends every event to `loop/events.jsonl` (append-only). State is a
derived projection (`loop/state/STATE.json`) recomputable from the log. `loop/inspect.ps1`
queries/replays it.

## Memory (optional, two independent stores)

| | `memory/history` | `memory/pgvector` |
|---|---|---|
| Backend | SQLite + sqlite-vec | Postgres 16 + pgvector (Docker) |
| Purpose | development history (decisions, failures, retros) | agent anti-patterns + bug-ledger |
| Embeddings | nomic-embed-text (768-dim) | bge-m3 (1024-dim) |
| Written by | manual / verdict ingestion | retrospector / supervisor agents |
| Read by | `ask.py` queries | pre-task injection hook |

They share nothing. Both degrade gracefully when their embedding/LLM backend is absent.
The pgvector schema (`memory/pgvector/init.sql`) includes `anti_patterns`, `recall_events`,
`proposals`, and `bugs` (bug-ledger, with `UNIQUE(task_id, short_id)`).

## Agents

Generic role templates in `agents/` (`judge`, `retrospector`, `supervisor`, `test-author`,
`reference-digester`, `testers/*`). Each keeps universal role logic and points to
`agents/PROJECT-KNOWLEDGE.md` for product specifics you provide. `config/agents.json` maps
roles → files + models. Invokers in `agents/bin/` call them over an OpenAI-compatible endpoint.
