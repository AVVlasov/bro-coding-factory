# history — development-history memory (optional)

A small, local **vector memory** for the agent harness. It records what happened during
development so the agent can:

1. **Avoid repeating mistakes** — "we already hit this failure before" (semantic search over past failures).
2. **Keep long-term history** — "what was done yesterday / last week".
3. **Run weekly retros** — surface recurring failure patterns and lint-rule candidates ("garbage collection day").

Everything stays **local**: nothing in this module is sent to the cloud. LLM summarization is
**optional** — if no model is configured (or `opencode` is missing), the scripts degrade
gracefully to raw text.

## Stack

| Component | Technology |
|---|---|
| Storage | SQLite + [sqlite-vec](https://github.com/asg017/sqlite-vec) (single file `memory.db`) |
| Embeddings | Any OpenAI-compatible endpoint (LM Studio / Ollama / llama.cpp server) — default model `nomic-embed-text-v1.5`, 768d |
| Optional LLM rollup | `opencode run --model <model>` (disabled by default) |
| CLI | Python 3.10+ and PowerShell wrappers (pwsh works on Linux/macOS/Windows) |

## Install (once)

Run from this directory:

```pwsh
pwsh ./install.ps1
```

The script (cross-platform via pwsh):

- installs pip dependencies (`sqlite-vec`, `httpx`);
- verifies the `sqlite-vec` extension loads;
- initializes `memory.db` from `schema.sql`;
- probes the embedding endpoint (default `http://localhost:1234/v1/embeddings`).

If you prefer plain Python, you can do the equivalent manually:

```bash
python -m pip install -r requirements.txt
python memory.py init --db memory.db --project default
```

**Before first use**, make sure an OpenAI-compatible embedding server is running:

- a 768d embedding model is loaded (e.g. `nomic-embed-text-v1.5`);
- the local server exposes `/v1/embeddings` (default port 1234).

## Layout

```
history/
├── memory.py          # Memory class — shared module (init / add / search / list_recent)
├── memorize.py        # CLI: write a single entry
├── ask.py             # CLI: semantic search / list-recent
├── ingest-events.py   # CLI: ingest pipeline (verdicts + events.jsonl → entries)
├── daily-summary.py   # CLI: evening daily summary
├── weekly-retro.py    # CLI: weekly pattern analysis
├── schema.sql         # DDL
├── install.ps1        # installer (pwsh, cross-platform)
├── venv-python.ps1    # resolve python from a local .venv next to these scripts
├── requirements.txt
├── memory.db          # the DB (auto-created, gitignored)
└── retros/            # weekly-retro markdown output (gitignored)
```

## Entry kinds (`kind`)

| Kind | Description | Source |
|---|---|---|
| `decision` | Architectural decision (immutable) | manual |
| `failure` | Agent failure + lesson learned | `ingest-events.py` + manual |
| `pattern` | A best/anti-practice found | weekly-retro / manual |
| `daily-summary` | What was done on a given day | `daily-summary.py` |
| `weekly-retro` | Weekly analysis + proposals | `weekly-retro.py` |
| `glossary` | Project terms | manual |
| `audit-record` | Audit-log style record | manual |
| `research-source` | External source (video, article) | manual |
| `task-closed` | PASS verdict for a task | `ingest-events.py` |

## Usage

### Record a failure
```bash
python memorize.py --kind failure \
  --title "TASK-01 4th attempt: init() gated behind test-mode flag" \
  --body "Root cause: refactor removed init() on the !startup branch — window only created in the else branch. Lesson: re-check the test-mode regression spec when touching init()." \
  --source "src/main.ts:456-462" \
  --tags TASK-01,regression,test-infra
```

### Ask "did we hit this before?"
```bash
python ask.py "startup test-mode regression"   # top-5 with similarity scores
```

### What was done yesterday
```bash
python ask.py "what was done yesterday" --kind daily-summary --k 1
```

### Ingest existing verdict files / events
```bash
python ingest-events.py --sources verdicts
python ingest-events.py --sources verdicts,events \
  --verdicts-dir tasks/.verdicts --events-path loop/events.jsonl
```

### Evening daily summary
```bash
python daily-summary.py
```

### Weekly retro
```bash
python weekly-retro.py            # creates a weekly-retro entry + retros/YYYY-WW.md
```

## Harness integration

The ingest pipeline reads two sources (both optional, both relative to the repo root or
absolute):

- **verdict files** — `--verdicts-dir` (default `tasks/.verdicts`), one `*.md` per task with a
  `verdict:` line (`PASS` → `task-closed`, anything else → `failure`). Task ids are taken from
  the filename stem; any string id is accepted.
- **event log** — `--events-path` (default `loop/events.jsonl`), JSONL with `ts` / `event_type`
  / `phase` / `task_id` fields.

Typical hooks:

- **Before planning**: `python ask.py "<task description>" --kind failure --k 3` and read the hits.
- **On every FAIL**: after the verify step writes a verdict file, call
  `python ingest-events.py --sources verdicts` to record a `failure` entry.

## Scheduling

These are cron/scheduler candidates — use whatever your OS provides:

| Job | Suggested trigger |
|---|---|
| `daily-summary.py` | daily ~23:30 |
| `weekly-retro.py` | weekly (e.g. Sunday 22:00) |
| `ingest-events.py` | hourly (optional) |

Linux/macOS (cron):
```cron
30 23 * * *  cd /path/to/history && python daily-summary.py
0  22 * * 0  cd /path/to/history && python weekly-retro.py
```

Windows (Task Scheduler):
```pwsh
schtasks /Create /SC DAILY /TN "bcf-daily-summary" /ST 23:30 `
  /TR "pwsh -File $PSScriptRoot\daily-summary.ps1"
```

## Config (environment variables)

| Var | Default | Purpose |
|---|---|---|
| `MEMORY_EMBED_URL` | `http://localhost:1234/v1/embeddings` | OpenAI-compat embeddings endpoint |
| `MEMORY_EMBED_MODEL` | `text-embedding-nomic-embed-text-v1.5` | embedding model id |
| `MEMORY_EMBED_DIM` | `768` | embedding dimension (must match the model) |
| `MEMORY_LLM_MODEL` | *(empty)* | optional `opencode run` model for rollups; empty = raw text only |

CLI flags `--project`, `--db`, `--embed-url`, `--embed-model`, `--embed-dim` override the
defaults. `--project` is just a logical namespace string for entries (default `default`).

## Backup

`memory.db` is a plain SQLite file. Back it up by copying the file — but **not** while a
writer is running (stop any scheduled jobs first).
```
