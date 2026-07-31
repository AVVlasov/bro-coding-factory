#!/usr/bin/env python
"""
memory_client.py — клиент векторной памяти агентов (M-13 C2).

Подкоманды:
  embed    — посчитать embedding для строки через LM Studio (читает stdin или --text)
  upsert   — добавить anti-pattern (читает JSON со stdin)
  recall   — top-K по cosine similarity (флаги --text/--scope/--k/--threshold)
  recall-from-retrospector — взять JSON ретроспектора со stdin, для каждого
             proposal kind=memory_anti_pattern выполнить upsert.

Конфиг — config/memory.config.json в корне репозитория (или $BCF_MEM_CONFIG).

Зависимости: psycopg[binary], requests. Установка:
  python -m pip install --user "psycopg[binary]" requests
"""

from __future__ import annotations
import argparse, json, os, sys, time
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("memory_client: pip install requests")
try:
    import psycopg
    from psycopg.types.json import Json
except ImportError:
    sys.exit("memory_client: pip install 'psycopg[binary]'")

# Порядок поиска конфига важен: одна установка pgvector обслуживает МНОГО проектов,
# поэтому фабричный конфиг — база, а проектный только переопределяет его, если проекту
# нужна своя база или своя модель эмбеддингов. Жёсткий путь «два уровня вверх» ломался
# ровно при этом сценарии: клиент запускался из фабрики, а конфиг искал в проекте.
FACTORY_CFG = Path(__file__).resolve().parents[1] / "memory.config.json"


def _config_candidates() -> list[Path]:
    out = []
    if os.environ.get("BCF_MEM_CONFIG"):
        out.append(Path(os.environ["BCF_MEM_CONFIG"]))
    if os.environ.get("BCF_PROJECT_ROOT"):
        out.append(Path(os.environ["BCF_PROJECT_ROOT"]) / "config" / "memory.config.json")
    out.append(FACTORY_CFG)
    return out


def load_config() -> dict[str, Any]:
    tried = []
    for cand in _config_candidates():
        tried.append(str(cand))
        if cand.is_file():
            return json.loads(cand.read_text(encoding="utf-8"))
    sys.exit("memory_client: конфиг не найден. Искали: " + ", ".join(tried))


def db_conn(cfg: dict) -> psycopg.Connection:
    """Соединение с базой памяти.

    connect_timeout обязателен. Без него недоступная база не даёт ошибку, а ВИСИТ: на
    localhost клиент сначала пробует ::1 и ждёт на нём десятки секунд. Память —
    вспомогательная подсистема, и её недоступность обязана выглядеть как быстрый отказ,
    а не как зависший харнесс: наблюдалось живьём — прогон замирал без единого события,
    снаружи неотличимо от «граф молчит».
    """
    pw_env = cfg.get("password_env") or "BCF_PG_PASSWORD"
    password = os.environ.get(pw_env, cfg.get("password_default", ""))
    return psycopg.connect(
        host=cfg["host"], port=cfg["port"], dbname=cfg["database"],
        user=cfg["user"], password=password, autocommit=True,
        connect_timeout=int(cfg.get("connect_timeout_sec", 5)),
    )


def embed(cfg: dict, text: str) -> list[float]:
    if not text or not text.strip():
        raise ValueError("embed: empty text")
    r = requests.post(
        cfg["embedding_endpoint"],
        json={"model": cfg["embedding_model"], "input": text},
        timeout=60,
    )
    r.raise_for_status()
    data = r.json()["data"]
    v = data[0]["embedding"]
    expected = cfg["embedding_dim"]
    if len(v) != expected:
        raise RuntimeError(
            f"embedding dim mismatch: got {len(v)}, schema expects {expected}. "
            f"Model loaded: {cfg['embedding_model']}. Check lms ls."
        )
    return v


def cmd_embed(args, cfg):
    text = args.text or sys.stdin.read()
    v = embed(cfg, text)
    print(json.dumps(v))


def upsert_entry(cur, cfg, entry: dict) -> str:
    vec = embed(cfg, entry["trigger_summary"])
    vec_lit = "[" + ",".join(f"{x:.6f}" for x in vec) + "]"
    cur.execute(
        """
        INSERT INTO agent_memory.anti_patterns
          (agent_scope, trigger_summary, what_went_wrong, correct_alternative, evidence, embedding)
        VALUES (%s, %s, %s, %s, %s, %s::vector)
        RETURNING id
        """,
        (
            entry.get("agent_scope", "code"),
            entry["trigger_summary"],
            entry.get("what_went_wrong", entry["trigger_summary"]),
            entry.get("correct_alternative"),
            Json(entry.get("evidence", {})),
            vec_lit,
        ),
    )
    return str(cur.fetchone()[0])


def cmd_upsert(args, cfg):
    payload = json.loads(args.json or sys.stdin.read())
    entries = payload if isinstance(payload, list) else [payload]
    with db_conn(cfg) as conn, conn.cursor() as cur:
        ids = [upsert_entry(cur, cfg, e) for e in entries]
    print(json.dumps({"inserted": ids}))


def cmd_recall(args, cfg):
    text = args.text or sys.stdin.read()
    vec = embed(cfg, text)
    vec_lit = "[" + ",".join(f"{x:.6f}" for x in vec) + "]"
    with db_conn(cfg) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT id::text, agent_scope, trigger_summary, what_went_wrong,
                   correct_alternative, 1 - (embedding <=> %s::vector) AS similarity
            FROM agent_memory.anti_patterns
            WHERE (%s = '' OR agent_scope = %s OR agent_scope = 'all')
              AND 1 - (embedding <=> %s::vector) >= %s
            ORDER BY embedding <=> %s::vector
            LIMIT %s
            """,
            (vec_lit, args.scope, args.scope, vec_lit, args.threshold, vec_lit, args.k),
        )
        rows = cur.fetchall()
        cols = ["id", "agent_scope", "trigger_summary", "what_went_wrong",
                "correct_alternative", "similarity"]
        out = [dict(zip(cols, r)) for r in rows]
        # лог recall-события для метрик C6
        if args.iteration_id:
            for r in rows:
                cur.execute(
                    "INSERT INTO agent_memory.recall_events (iteration_id, agent_scope, matched_id, similarity) "
                    "VALUES (%s, %s, %s, %s)",
                    (args.iteration_id, args.scope, r[0], r[5]),
                )
                cur.execute(
                    "UPDATE agent_memory.anti_patterns SET hits = hits + 1, last_hit_at = now() WHERE id = %s",
                    (r[0],),
                )
    print(json.dumps(out, ensure_ascii=False, indent=2))


# Evolutionary proposals table. The retrospector proposes skill_new/skill_update/
# subagent_skill every iteration — these used to be discarded (only memory_anti_pattern
# was persisted), breaking the evolution loop. Now they are accumulated with dedup and a
# frequency (count); a maintainer harvests the most frequent ones and turns them into real
# skills/subagents/tasks.
EVOLUTION_KINDS = ("skill_new", "skill_update", "subagent_skill")

def ensure_proposals_schema(cur):
    cur.execute("""
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
        )
    """)

def upsert_proposal(cur, p: dict, iteration_id):
    kind = p.get("kind"); target = (p.get("target") or "").strip()
    if kind not in EVOLUTION_KINDS or not target:
        return None
    rationale = p.get("rationale", "")
    src = {"iteration_id": iteration_id, "rationale": rationale}
    cur.execute("""
        INSERT INTO agent_memory.proposals (kind, target, rationale, sources)
        VALUES (%s, %s, %s, %s::jsonb)
        ON CONFLICT (kind, target) DO UPDATE
          SET count = agent_memory.proposals.count + 1,
              last_seen = now(),
              rationale = EXCLUDED.rationale,
              status = CASE WHEN agent_memory.proposals.status = 'rejected'
                            THEN 'rejected' ELSE agent_memory.proposals.status END,
              sources = agent_memory.proposals.sources || EXCLUDED.sources
        RETURNING id, count
    """, (kind, target, rationale, Json([src])))
    return cur.fetchone()


def cmd_from_retrospector(args, cfg):
    """JSON ретроспектора → anti_patterns (memory_anti_pattern) + proposals (skill/subagent)."""
    retro = json.loads(sys.stdin.read())
    all_props = retro.get("proposals", []) or []
    iter_id = retro.get("iteration_id")
    ap = [p for p in all_props if p.get("kind") == "memory_anti_pattern"]
    ev = [p for p in all_props if p.get("kind") in EVOLUTION_KINDS]
    inserted, prop_results = [], []
    with db_conn(cfg) as conn, conn.cursor() as cur:
        ensure_proposals_schema(cur)
        for p in ap:
            inserted.append(upsert_entry(cur, cfg, {
                "agent_scope": "code",
                "trigger_summary": p.get("rationale", "") or p.get("target", ""),
                "what_went_wrong": p.get("rationale", ""),
                "correct_alternative": p.get("target"),
                "evidence": {"iteration_id": iter_id, "source": "retrospector"},
            }))
        for p in ev:
            r = upsert_proposal(cur, p, iter_id)
            if r: prop_results.append({"id": r[0], "kind": p.get("kind"), "target": p.get("target"), "count": r[1]})
    print(json.dumps({"anti_patterns_inserted": inserted, "proposals_upserted": prop_results}, ensure_ascii=False))


def cmd_harvest_proposals(args, cfg):
    """Evolutionary harvest: proposals ranked by frequency (count) — a maintainer turns the top ones into actions."""
    with db_conn(cfg) as conn, conn.cursor() as cur:
        ensure_proposals_schema(cur)
        where = "" if args.status == "all" else "WHERE status = %s"
        params = () if args.status == "all" else (args.status,)
        cur.execute(f"""
            SELECT kind, target, count, status, rationale,
                   to_char(first_seen,'YYYY-MM-DD') AS first_seen,
                   to_char(last_seen,'YYYY-MM-DD')  AS last_seen
            FROM agent_memory.proposals {where}
            ORDER BY count DESC, last_seen DESC LIMIT %s
        """, params + (args.limit,))
        cols = ["kind","target","count","status","rationale","first_seen","last_seen"]
        out = [dict(zip(cols, r)) for r in cur.fetchall()]
    print(json.dumps(out, ensure_ascii=False, indent=2))


def cmd_stats(args, cfg):
    """Что в памяти НА САМОМ ДЕЛЕ.

    «Память доступна» — бесполезный признак: она бывает доступна и при этом содержать
    один-единственный урок, который перечитывается полсотни раз (наблюдалось: 1 урок,
    57 отзывов за прогон). Живое обучение — это РОСТ чисел от прогона к прогону, поэтому
    здесь печатаются сами числа, а не «ок».
    """
    out = {"anti_patterns": 0, "bugs": 0, "recalls": 0, "proposals": 0}
    with db_conn(cfg) as conn, conn.cursor() as cur:
        for key, table in (("anti_patterns", "anti_patterns"), ("bugs", "bugs"),
                           ("recalls", "recall_events"), ("proposals", "proposals")):
            try:
                cur.execute(f"SELECT count(*) FROM agent_memory.{table}")
                out[key] = int(cur.fetchone()[0])
            except Exception:
                # Таблицы может не быть (схема старее клиента) — это не повод падать:
                # отсутствующий счётчик честнее выдуманного нуля только вместе с фактом,
                # что таблицы нет, поэтому помечаем отдельно.
                out[key] = None
        try:
            cur.execute("""
                SELECT count(*) FROM agent_memory.anti_patterns
                WHERE created_at > now() - interval '7 days'
            """)
            out["anti_patterns_last_7d"] = int(cur.fetchone()[0])
        except Exception:
            out["anti_patterns_last_7d"] = None
    print(json.dumps(out, ensure_ascii=False))


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("embed"); pe.add_argument("--text")
    pu = sub.add_parser("upsert"); pu.add_argument("--json")
    pr = sub.add_parser("recall")
    pr.add_argument("--text"); pr.add_argument("--scope", default="code")
    pr.add_argument("--k", type=int, default=3); pr.add_argument("--threshold", type=float, default=0.55)
    pr.add_argument("--iteration-id", dest="iteration_id", default="")
    sub.add_parser("recall-from-retrospector")
    sub.add_parser("stats")
    ph = sub.add_parser("harvest-proposals")
    ph.add_argument("--status", default="new")   # new | triaged | done | rejected | all
    ph.add_argument("--limit", type=int, default=30)

    args = p.parse_args(argv)
    cfg = load_config()
    # Недоступная база — ожидаемое состояние, а не аварийная ситуация: память
    # опциональна. Трейсбек на пол-экрана здесь только мешает: вызывающий (хук, харнесс,
    # bcf memory) читает stderr и показывает его человеку.
    try:
        return _dispatch(args, cfg)
    except psycopg.OperationalError as e:
        first = str(e).strip().splitlines()[0] if str(e).strip() else "нет соединения"
        print(f"memory_client: база недоступна ({first})", file=sys.stderr)
        return 1


def _dispatch(args, cfg):
    if args.cmd == "embed": cmd_embed(args, cfg)
    elif args.cmd == "upsert": cmd_upsert(args, cfg)
    elif args.cmd == "recall": cmd_recall(args, cfg)
    elif args.cmd == "recall-from-retrospector": cmd_from_retrospector(args, cfg)
    elif args.cmd == "stats": cmd_stats(args, cfg)
    elif args.cmd == "harvest-proposals": cmd_harvest_proposals(args, cfg)
    return 0


if __name__ == "__main__":
    # Код возврата обязан доходить до вызывающего: харнесс отличает «память ответила
    # пусто» (валидный результат recall) от «память не ответила» именно по нему.
    try:
        sys.exit(main() or 0)
    except SystemExit:
        raise
    except Exception as e:
        sys.stderr.write(f"memory_client: {type(e).__name__}: {e}\n")
        sys.exit(1)
