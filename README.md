# bro-coding-factory

A **project-agnostic autonomous coding harness** — the "Ralph" loop pattern, hardened and
generalized for open source. It drives any CLI coding agent to work a task to completion in
**bounded, self-correcting iterations**, then gates the result behind a deterministic
verification + adversarial judge, and (optionally) learns from its own failures.

Everything project-specific lives in `config/` and `agents/PROJECT-KNOWLEDGE.md`. The harness
itself contains **no project specifics and no secrets** — point it at your repo, set a few
config values, bring your own agent backend + API key (via `.env`), and run.

> Runtime: **PowerShell 7** (cross-platform — Windows / Linux / macOS) + **Python 3.10+**
> (only for the optional memory subsystems). No build step.

---

## What it does

Each iteration starts with a **fresh agent context** (no context-window rot), the agent does
**one step** of the active task, and the runner applies **backpressure**:

- **Loop runner** (`loop/loop.ps1`) — fresh-context iterations; iteration timeout with
  process-tree kill; optional network/SSE-stall watchdog; loop-detection (same error ×N);
  no-progress detection; durable git WIP snapshots; verdict-gate stop for human review.
- **Verification + judge** (`loop/verify.ps1`) — runs LLM testers and deterministic checks,
  an optional visual phase, and an isolated adversarial judge. The verdict is **deterministic**
  (PASS ⟺ all gates green); the judge is advisory.
- **Self-learning memory** (optional) — two independent stores: a lightweight SQLite
  "development history" (`memory/history`) and a pgvector "anti-pattern + bug-ledger"
  (`memory/pgvector`). Past failures are recalled into the next iteration so the agent
  doesn't repeat them. Embeddings are served by a local **[LM Studio](https://lmstudio.ai)**
  instance (or any OpenAI-compatible `/v1/embeddings` endpoint) — bge-m3 (1024-dim) for
  pgvector, nomic-embed-text (768-dim) for history.
- **Friction triggers / hooks** — pause for human review on irreversible edits (migrations,
  deps, CI, auth…), config-driven.

## Repo layout

```
config/      harness.json · agents.json · triggers.json · checks.json · scope-map.json · memory.config.json
loop/        loop.ps1 · verify.ps1 · triggers.ps1 · lint-gate.ps1 · start.ps1 · run-all.ps1 · inspect.ps1
             PROMPT.md   (the per-iteration prompt)
             lib/        event-bus · harness-guard · evidence · hard-cap · memory bridge · …
             lib/adapters/  opencode stream renderer (swap for a different backend)
agents/      generic role templates (judge, retrospector, supervisor, test-author, testers/…)
             PROJECT-KNOWLEDGE.example.md  (copy → PROJECT-KNOWLEDGE.md, fill in your specifics)
             bin/        invoke-*.ps1  (role invokers)
hooks/       done-gate · agent-infra-protect · pre-task-memory-inject · finding-gate + hooks-config.json
memory/      pgvector/ (Docker + Postgres+pgvector)   history/ (SQLite + embeddings)
docs/        ARCHITECTURE.md · SETUP.md · CONFIG.md
```

## Quick start

1. **Prereqs:** PowerShell 7 (`pwsh`), git, and a CLI coding agent on PATH (default: `opencode`).
   For the optional memory: Python 3.10+, Docker (pgvector), and [LM Studio](https://lmstudio.ai)
   serving an embedding model (or any OpenAI-compatible `/v1/embeddings` endpoint).
   See [docs/SETUP.md](docs/SETUP.md).
2. **Configure:** edit `config/harness.json` — set `agent.command`, `models.*`, and
   `productPaths`. Copy `.env.example` → `.env` and add your agent API key. Copy
   `agents/PROJECT-KNOWLEDGE.example.md` → `agents/PROJECT-KNOWLEDGE.md` and fill it in.
3. **Define a task:** create `tasks/<TASK-ID>-<slug>.md` and point `tasks/CURRENT-FOCUS.md` at it.
4. **Run:**
   ```powershell
   pwsh loop/start.ps1 <TASK-ID>      # background launcher
   # or directly:
   pwsh loop/loop.ps1 <TASK-ID>
   ```
   Progress: `loop/loop.log`. Inspect events: `pwsh loop/inspect.ps1 --task <TASK-ID>`.
   The loop stops at `verdict: PASS` for your review.

See [docs/CONFIG.md](docs/CONFIG.md) for every config knob and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for how the pieces fit together.

## Bring your own backend

The agent backend is a configurable command template (`config/harness.json` → `agent.command`,
with `{model}` substituted; the prompt is piped on stdin). It ships defaulting to
[opencode](https://github.com/sst/opencode) (provider-agnostic, open source). To use another
CLI agent, change `agent.command` and provide a matching stream adapter under
`loop/lib/adapters/`.

## Status & provenance

Extracted and generalized from a private project's battle-tested harness. The control logic
(timeouts, loop/no-progress detection, deterministic verdict gate, WIP snapshots) is preserved;
all project identifiers, paths, model ids, and keys were removed. MIT licensed.
