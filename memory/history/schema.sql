-- harness memory schema (SQLite + sqlite-vec)
-- Применяется один раз через `python -c "from memory import Memory; Memory('memory.db').init()"` или install.ps1.

CREATE TABLE IF NOT EXISTS memory_entries (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT    NOT NULL CHECK (kind IN
                ('decision','failure','pattern','daily-summary','weekly-retro','glossary','audit-record','research-source','task-closed')),
  project     TEXT    NOT NULL,
  title       TEXT    NOT NULL,
  body        TEXT    NOT NULL,
  metadata    TEXT,            -- JSON (task_id, phase, severity, etc)
  source      TEXT,            -- file:line или event:id
  tags        TEXT,            -- comma-separated
  created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_kind     ON memory_entries(kind);
CREATE INDEX IF NOT EXISTS idx_project  ON memory_entries(project);
CREATE INDEX IF NOT EXISTS idx_created  ON memory_entries(created_at);

-- vec0 virtual table — vector index (entry_id FK на memory_entries.id)
-- Embedding model: nomic-embed-text-v1.5 → 768d float32.
CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(
  entry_id    INTEGER PRIMARY KEY,
  embedding   float[768]
);

-- журнал ingest-прогонов
CREATE TABLE IF NOT EXISTS memorize_runs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  source          TEXT NOT NULL,           -- e.g. 'loop/events.jsonl', 'tasks/.verdicts', 'manual'
  ran_at          TEXT NOT NULL DEFAULT (datetime('now')),
  events_seen     INTEGER DEFAULT 0,
  entries_created INTEGER DEFAULT 0,
  last_cursor     TEXT,                    -- e.g. last event ts processed
  notes           TEXT
);
