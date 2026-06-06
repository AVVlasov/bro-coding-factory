# Agent vector memory

Optional vector-memory stack for a coding agent and its sub-agents. It stores
**anti-pattern** entries — situations where the agent previously went wrong — so
that on the next embedding match they can be injected into the system context and
the same mistake is not repeated. It also holds a per-task **bug ledger** and a
log of evolutionary **proposals**.

> Anti-patterns are written only by the retrospector step. Agents do not write
> directly — they read via the memory-inject hook.

## Stack

- Postgres 16 + [pgvector](https://github.com/pgvector/pgvector), container
  `bcf-agent-memory`, exposed on `localhost:5433` (5433 to avoid clashing with a
  system Postgres on 5432).
- Embeddings: bge-m3 (1024 dim) served by any OpenAI-compatible embeddings
  endpoint — e.g. LM Studio at `http://localhost:1234/v1/embeddings`, or any other
  server exposing `POST /v1/embeddings`.

## Run

```bash
docker compose up -d
# wait until the container reports healthy:
docker inspect -f '{{.State.Health.Status}}' bcf-agent-memory
pwsh smoke-test.ps1          # checks DB + schema (in-container psql, no host client needed)
pwsh smoke-test-client.ps1   # full embed -> upsert -> recall round-trip (needs the embeddings server)
```

`init.sql` is applied automatically on the first container start (empty volume).
To re-apply after schema edits:

```bash
docker exec -e PGPASSWORD="$BCF_PG_PASSWORD" bcf-agent-memory \
    psql -U bcf -d bcf_agent_memory -f /docker-entrypoint-initdb.d/init.sql
```

## Configuration

Connection and embedding settings live in `config/memory.config.json` at the repo
root (database name, user, port, embedding model/dim/endpoint). The DB password is
read from the environment variable named by `password_env` (default
`BCF_PG_PASSWORD`); `password_default` (`bcf_local_dev`) is a non-secret local-dev
fallback only — set a real value via the environment for anything shared. No secret
values are committed.

`docker-compose.yml` honours `BCF_PG_PASSWORD` and `BCF_MEM_CONTAINER` from the
environment, falling back to the same local-dev defaults.

## Schema

`init.sql` is the single source of truth. Tables (all in schema `agent_memory`):

- `anti_patterns` — the main table: `agent_scope`, `trigger_summary`,
  `what_went_wrong`, `correct_alternative`, `evidence` (jsonb), `embedding`
  (`vector(1024)`), hit counters. HNSW index on `embedding vector_cosine_ops`,
  plus a btree on `agent_scope` for scope-filtered recall.
- `recall_events` — log of memory hits, for "how often did memory fire" metrics.
- `proposals` — accumulated evolutionary proposals (skill_new / skill_update /
  subagent_skill) with dedup + frequency.
- `bugs` — per-task bug ledger written by `bug_tracker.py`. `short_id` (e.g.
  `B-001`) is allocated per task, so uniqueness is `UNIQUE (task_id, short_id)`,
  not `short_id` alone; HNSW index for same-task matching.

## Backup

```bash
docker exec bcf-agent-memory pg_dump -U bcf bcf_agent_memory > backup-$(date +%F).sql
```

## Cross-platform notes

- The `.ps1` smoke tests require PowerShell 7+ (`pwsh`), available on Linux, macOS,
  and Windows; they resolve all paths relative to the script (`$PSScriptRoot`).
- `docker compose` and the `docker exec ... psql` snippets work the same on every
  platform. The shell snippets above use POSIX syntax (`$VAR`, `$(...)`); on
  Windows PowerShell use `$env:BCF_PG_PASSWORD` and `Get-Date -F yyyy-MM-dd` instead.
