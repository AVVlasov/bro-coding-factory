"""
harness memory — единый модуль развития-истории для bcf-харнеса.
Различие между проектами — только в аргументах CLI (--project, --db, источники).

Backend: SQLite + sqlite-vec; Embeddings: любой OpenAI-compat endpoint
(LM Studio, Ollama, llama.cpp server и т.п.) через переменные MEMORY_EMBED_*.

Использование как библиотека:
    from memory import Memory
    m = Memory("memory.db")
    m.init()                                                # одноразово создаст схему
    m.add(kind="failure", title="...", body="...")          # автоматически embeds + insert
    for hit in m.search("similar boundary issue", k=5): ... # top-K по cosine

CLI обёртки — memorize.py / ask.py / daily-summary.py / weekly-retro.py / ingest-events.py.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import httpx
import sqlite_vec

# Принудительно UTF-8 в stdout/stderr — Windows cp1251 рушит вывод кириллицы/стрелок.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass

# -----------------------------------------------------------------------------
# Конфиг
# -----------------------------------------------------------------------------

DEFAULT_EMBED_URL = os.environ.get("MEMORY_EMBED_URL", "http://localhost:1234/v1/embeddings")
DEFAULT_EMBED_MODEL = os.environ.get("MEMORY_EMBED_MODEL", "text-embedding-nomic-embed-text-v1.5")
DEFAULT_EMBED_DIM = int(os.environ.get("MEMORY_EMBED_DIM", "768"))

VALID_KINDS = {
    "decision", "failure", "pattern", "daily-summary",
    "weekly-retro", "glossary", "audit-record", "research-source", "task-closed",
}

# -----------------------------------------------------------------------------
# Модель данных
# -----------------------------------------------------------------------------

@dataclass
class Entry:
    id: int
    kind: str
    project: str
    title: str
    body: str
    metadata: dict[str, Any] | None
    source: str | None
    tags: list[str]
    created_at: str
    updated_at: str
    score: float | None = None  # из vec0 KNN

    def __str__(self) -> str:
        head = f"[{self.id}] {self.kind} · {self.project} · {self.created_at[:10]}"
        if self.score is not None:
            head += f"  (sim={1 - self.score:.3f})"
        return f"{head}\n  {self.title}\n  {self.body[:200].rstrip()}{'…' if len(self.body) > 200 else ''}"


# -----------------------------------------------------------------------------
# Memory class
# -----------------------------------------------------------------------------

class Memory:
    def __init__(self, db_path: str, project: str = "default",
                 embed_url: str = DEFAULT_EMBED_URL, embed_model: str = DEFAULT_EMBED_MODEL,
                 embed_dim: int = DEFAULT_EMBED_DIM):
        self.db_path = db_path
        self.project = project
        self.embed_url = embed_url
        self.embed_model = embed_model
        self.embed_dim = embed_dim
        self._conn: sqlite3.Connection | None = None

    # --- low-level ----------------------------------------------------------

    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            c = sqlite3.connect(self.db_path)
            c.enable_load_extension(True)
            sqlite_vec.load(c)
            c.enable_load_extension(False)
            c.row_factory = sqlite3.Row
            self._conn = c
        return self._conn

    def init(self) -> None:
        """Применить schema.sql. Идемпотентно."""
        schema_file = Path(__file__).parent / "schema.sql"
        sql = schema_file.read_text(encoding="utf-8")
        self.conn().executescript(sql)
        self.conn().commit()

    def close(self) -> None:
        if self._conn:
            self._conn.close()
            self._conn = None

    # --- embeddings ---------------------------------------------------------

    def embed(self, text: str) -> list[float]:
        """Получить embedding через OpenAI-compat endpoint (LM Studio / Ollama / др.)."""
        if not text:
            return [0.0] * self.embed_dim
        with httpx.Client(timeout=30.0) as cli:
            r = cli.post(self.embed_url, json={"model": self.embed_model, "input": text})
            r.raise_for_status()
            data = r.json()
        vec = data["data"][0]["embedding"]
        if len(vec) != self.embed_dim:
            raise RuntimeError(
                f"Embedding dim mismatch: got {len(vec)}, expected {self.embed_dim}. "
                f"Проверь MEMORY_EMBED_DIM или модель в LM Studio.")
        return vec

    @staticmethod
    def _serialize_vec(v: list[float]) -> bytes:
        return struct.pack(f"{len(v)}f", *v)

    # --- CRUD ----------------------------------------------------------------

    def add(self, *, kind: str, title: str, body: str,
            metadata: dict[str, Any] | None = None,
            source: str | None = None, tags: list[str] | None = None,
            project: str | None = None,
            embedding_text: str | None = None) -> int:
        """Записать entry + автоматически создать вектор.

        embedding_text — если задано, embed-им именно эту строку (не title+body); полезно
        для длинных body, когда хочется embed только title+summary.
        """
        if kind not in VALID_KINDS:
            raise ValueError(f"kind={kind!r} не в {sorted(VALID_KINDS)}")
        proj = project or self.project
        meta_json = json.dumps(metadata, ensure_ascii=False) if metadata else None
        tags_s = ",".join(tags) if tags else None

        embed_in = embedding_text if embedding_text else f"{title}\n\n{body}"
        vec = self.embed(embed_in)

        c = self.conn()
        cur = c.execute(
            "INSERT INTO memory_entries(kind, project, title, body, metadata, source, tags) "
            "VALUES (?,?,?,?,?,?,?)",
            (kind, proj, title, body, meta_json, source, tags_s)
        )
        eid = cur.lastrowid
        c.execute(
            "INSERT INTO memory_vec(entry_id, embedding) VALUES (?, ?)",
            (eid, self._serialize_vec(vec))
        )
        c.commit()
        return eid

    def get(self, entry_id: int) -> Entry | None:
        row = self.conn().execute(
            "SELECT * FROM memory_entries WHERE id=?", (entry_id,)
        ).fetchone()
        return _row_to_entry(row) if row else None

    def search(self, query: str, *, k: int = 5,
               kind: str | None = None, project: str | None = None,
               since_days: int | None = None) -> list[Entry]:
        """Top-K по cosine similarity. vec0 KNN search."""
        qvec = self.embed(query)
        # Базовый KNN: returns entry_id, distance (L2 default by sqlite-vec? cosine via normalize).
        # sqlite-vec >=0.1 uses cosine via vec_distance_cosine; KNN sorts by distance.
        rows = self.conn().execute(
            "SELECT entry_id, distance FROM memory_vec "
            "WHERE embedding MATCH ? AND k = ?",
            (self._serialize_vec(qvec), k * 3)  # over-fetch для post-filter
        ).fetchall()
        if not rows:
            return []

        ids = [r["entry_id"] for r in rows]
        dist_by_id = {r["entry_id"]: r["distance"] for r in rows}
        placeholders = ",".join("?" * len(ids))
        sql = f"SELECT * FROM memory_entries WHERE id IN ({placeholders})"
        params: list[Any] = list(ids)
        clauses = []
        if kind:
            clauses.append("kind = ?")
            params.append(kind)
        if project:
            clauses.append("project = ?")
            params.append(project)
        if since_days is not None:
            clauses.append("datetime(created_at) >= datetime('now', ?)")
            params.append(f"-{since_days} days")
        if clauses:
            sql += " AND " + " AND ".join(clauses)
        result = []
        for r in self.conn().execute(sql, params).fetchall():
            e = _row_to_entry(r)
            e.score = dist_by_id.get(e.id)
            result.append(e)
        # Реcorting по score (vec0 уже ascending по distance, но post-filter мог нарушить порядок)
        result.sort(key=lambda x: x.score or 1.0)
        return result[:k]

    def list_recent(self, *, kind: str | None = None, days: int = 7,
                    limit: int = 100) -> list[Entry]:
        sql = "SELECT * FROM memory_entries WHERE datetime(created_at) >= datetime('now', ?)"
        params: list[Any] = [f"-{days} days"]
        if kind:
            sql += " AND kind = ?"
            params.append(kind)
        sql += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)
        return [_row_to_entry(r) for r in self.conn().execute(sql, params).fetchall()]

    # --- run journal --------------------------------------------------------

    def record_run(self, *, source: str, events_seen: int, entries_created: int,
                   last_cursor: str | None, notes: str | None = None) -> None:
        self.conn().execute(
            "INSERT INTO memorize_runs(source, events_seen, entries_created, last_cursor, notes) "
            "VALUES (?,?,?,?,?)",
            (source, events_seen, entries_created, last_cursor, notes)
        )
        self.conn().commit()

    def last_cursor(self, source: str) -> str | None:
        row = self.conn().execute(
            "SELECT last_cursor FROM memorize_runs WHERE source=? ORDER BY id DESC LIMIT 1",
            (source,)
        ).fetchone()
        return row["last_cursor"] if row else None


def _row_to_entry(row: sqlite3.Row) -> Entry:
    return Entry(
        id=row["id"],
        kind=row["kind"],
        project=row["project"],
        title=row["title"],
        body=row["body"],
        metadata=json.loads(row["metadata"]) if row["metadata"] else None,
        source=row["source"],
        tags=row["tags"].split(",") if row["tags"] else [],
        created_at=row["created_at"],
        updated_at=row["updated_at"],
    )


# -----------------------------------------------------------------------------
# CLI helpers (могут импортироваться скриптами)
# -----------------------------------------------------------------------------

def parser_common() -> argparse.ArgumentParser:
    """Общий parser: --db, --project, --embed-url, --embed-model.

    --project — логический namespace записей (любая строка). По умолчанию "default".
    """
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--db", default=str(Path(__file__).parent / "memory.db"))
    p.add_argument("--project", default="default")
    p.add_argument("--embed-url", default=DEFAULT_EMBED_URL)
    p.add_argument("--embed-model", default=DEFAULT_EMBED_MODEL)
    p.add_argument("--embed-dim", type=int, default=DEFAULT_EMBED_DIM)
    return p


def make_memory(args: argparse.Namespace) -> Memory:
    m = Memory(args.db, args.project, args.embed_url, args.embed_model, args.embed_dim)
    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    m.init()
    return m


if __name__ == "__main__":
    # Удобный smoke-test: python memory.py init
    if len(sys.argv) > 1 and sys.argv[1] == "init":
        p = parser_common()
        a = p.parse_args(sys.argv[2:])
        m = make_memory(a)
        print(f"[ok] schema applied: {a.db}")
    else:
        print("Use memorize.py / ask.py / daily-summary.py / weekly-retro.py / ingest-events.py")
        print("Or: python memory.py init  (smoke-test схема)")
