-- Agent vector-memory schema.
-- Runs automatically on first container start (docker-entrypoint-initdb.d).
-- Idempotent: safe to re-run by hand after schema changes.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS agent_memory;

-- Anti-pattern entries. Written only by the retrospector.
CREATE TABLE IF NOT EXISTS agent_memory.anti_patterns (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_scope     text NOT NULL,                       -- 'code' | <subagent-name> | 'all'
    trigger_summary text NOT NULL,                       -- short description of the situation
    what_went_wrong text NOT NULL,
    correct_alternative text,                            -- skill reference / short instruction
    evidence        jsonb NOT NULL DEFAULT '{}'::jsonb,  -- iteration_id, file:line, judge_id
    embedding       vector(1024) NOT NULL,               -- bge-m3 dim
    hits            integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_hit_at     timestamptz
);

-- HNSW for cosine similarity. m=16, ef_construction=64 (defaults) — enough for thousands of rows.
CREATE INDEX IF NOT EXISTS anti_patterns_embedding_hnsw
    ON agent_memory.anti_patterns USING hnsw (embedding vector_cosine_ops);

-- Scope filter in recall — plain btree.
CREATE INDEX IF NOT EXISTS anti_patterns_scope_idx
    ON agent_memory.anti_patterns (agent_scope);

-- Recall-event log (metrics: "how often did memory fire").
CREATE TABLE IF NOT EXISTS agent_memory.recall_events (
    id              bigserial PRIMARY KEY,
    iteration_id    text NOT NULL,
    agent_scope     text NOT NULL,
    matched_id      uuid REFERENCES agent_memory.anti_patterns(id) ON DELETE CASCADE,
    similarity      real NOT NULL,
    at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS recall_events_iter_idx ON agent_memory.recall_events (iteration_id);

-- Bug ledger. Written by bug_tracker.py (open/close/list/link-test).
-- short_id (B-NN) is allocated per task, so uniqueness MUST be (task_id, short_id),
-- NOT short_id alone — a global UNIQUE on short_id caused cross-task UniqueViolation.
CREATE TABLE IF NOT EXISTS agent_memory.bugs (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    short_id             text NOT NULL,                  -- per-task id, e.g. B-001
    task_id              text NOT NULL,
    signature            text,                           -- slug / stable signature
    summary              text NOT NULL,
    verification         text,                           -- how to reproduce / verify
    severity             text NOT NULL DEFAULT 'medium', -- critical | high | medium | low
    status               text NOT NULL DEFAULT 'open',   -- open | fixed | chronic
    must_address         boolean NOT NULL DEFAULT true,
    embedding            vector(1024),                   -- bge-m3 dim, embedded from summary
    history              jsonb NOT NULL DEFAULT '[]'::jsonb,
    opened_by            text,
    opened_at            timestamptz NOT NULL DEFAULT now(),
    closed_at            timestamptz,
    fix_diff_fingerprint text,
    fix_iteration        text,
    reopened_count       integer NOT NULL DEFAULT 0,
    regression_test_path text,
    last_seen_at         timestamptz,
    -- short_id uniqueness is scoped per task (fixes historical global-uniqueness bug).
    UNIQUE (task_id, short_id)
);

-- HNSW for same-task bug matching by cosine similarity.
CREATE INDEX IF NOT EXISTS bugs_embedding_hnsw
    ON agent_memory.bugs USING hnsw (embedding vector_cosine_ops);

-- Bug lookups are task-scoped — plain btree on task_id.
CREATE INDEX IF NOT EXISTS bugs_task_idx
    ON agent_memory.bugs (task_id);

-- Evolutionary proposals (skill_new / skill_update / subagent_skill), accumulated with
-- dedup + frequency. memory_client.py also creates this at runtime via CREATE TABLE
-- IF NOT EXISTS (ensure_proposals_schema); defined here so a fresh container has it too.
CREATE TABLE IF NOT EXISTS agent_memory.proposals (
    id          serial PRIMARY KEY,
    kind        text NOT NULL,
    target      text NOT NULL,
    rationale   text,
    count       int  NOT NULL DEFAULT 1,
    status      text NOT NULL DEFAULT 'new',
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    sources     jsonb NOT NULL DEFAULT '[]'::jsonb,
    UNIQUE (kind, target)
);
