# Setup

## Prerequisites

| Need | For | Notes |
|---|---|---|
| **PowerShell 7+** (`pwsh`) | the harness (all `.ps1`) | Cross-platform: Windows, Linux, macOS. |
| **git** | WIP snapshots, diffs, triggers | Must be on PATH; run from inside a git repo. |
| **A CLI coding agent** | the actual code edits | Default [`opencode`](https://github.com/sst/opencode). Any CLI agent works via `config/harness.json` → `agent.command`. |
| **Python 3.10+** | memory subsystems (optional) | Only if you enable `features.memory` or use `memory/history`. |
| **Docker** | pgvector memory (optional) | Only for `memory/pgvector`. |
| **An embedding server** | vector memory (optional) | LM Studio or any OpenAI-compatible `/v1/embeddings`. bge-m3 (1024-dim) for pgvector; nomic-embed-text (768-dim) for history. |

## Minimal run (no memory, no vision)

1. `cp .env.example .env` and set `BCF_API_KEY` / `BCF_API_HOST` for your agent backend.
2. Edit `config/harness.json`: set `agent.command`, `models.code`, and `productPaths`
   (your source roots, e.g. `["src","server"]`). Add your always-on checks to
   `config/checks.json` (`_default`, e.g. `["npx --no-install tsc --noEmit"]`).
3. `cp agents/PROJECT-KNOWLEDGE.example.md agents/PROJECT-KNOWLEDGE.md` and fill it in.
4. Create a task file `tasks/<TASK-ID>-<slug>.md`; point `tasks/CURRENT-FOCUS.md` at it.
5. `pwsh loop/loop.ps1 <TASK-ID>`

`features.*` in `config/harness.json` are all **off** by default, so the loop runs with zero
external dependencies beyond the agent backend.

## Enabling the vector memory (pgvector)

```bash
# 1. start the DB
cd memory/pgvector
docker compose up -d
pwsh smoke-test.ps1          # container healthy + schema present

# 2. point an embedding server (e.g. LM Studio) at bge-m3 on http://localhost:1234
pwsh smoke-test-client.ps1   # embed -> upsert -> recall round-trip
```

Then set `features.memory: true` in `config/harness.json` and `BCF_PG_PASSWORD` in `.env`.
Connection + embedding settings live in `config/memory.config.json`.

## Enabling the SQLite history memory

```bash
cd memory/history
pwsh install.ps1             # venv + deps + db init
python ask.py "some query" --k 3
```

## Enabling the visual phase

Set `features.vision: true` and provide your visual test commands via env
(`BCF_VISION_BUILD_CMD`, `BCF_VISION_CONTRACT_CMD`, `BCF_VISION_CONTRACT_DIR`) — see
[CONFIG.md](CONFIG.md). Map slugs → paths in `config/scope-map.json` (`vision`).

## Scheduling (optional)

The runner is foreground/bounded by design (stops at PASS). To run unattended, wrap
`loop/run-all.ps1` in cron (Linux/macOS) or Task Scheduler (Windows).
