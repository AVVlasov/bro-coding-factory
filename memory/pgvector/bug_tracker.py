#!/usr/bin/env python
"""
bug_tracker.py — клиент bug-стора (M-13 Phase 1).

Подкоманды:
  open      JSON [{task, summary, verification, severity, opened_by, must_address?}]
              → создаёт B-NN запись или возвращает существующую по embedding-match;
              ↻ если match.status=fixed → reopened_count++, status→open|chronic.
  close     --short-id B-NN --diff-fingerprint <hash> --iteration <n>
              → status=fixed.
  list      --task STACK-03 [--status open|chronic|fixed|all]
              → JSON-массив для bundle.
  link-test --short-id B-NN --test-path tests/electron/regressions/B-NN.spec.ts
              → ставит regression_test_path; не меняет status.

Reopen-rule: при match.status=fixed → reopen +1 → если total >= 2 → status=chronic.

Markdown-зеркало для git-аудита: при open/close/reopen синхронизируется
tasks/.bugs/<task>/<short_id>.md (header YAML + history бахнутся туда же).
"""
from __future__ import annotations
import argparse, json, os, re, sys, uuid
from pathlib import Path
from datetime import datetime, timezone
from typing import Any

import psycopg
from psycopg.types.json import Json

# Reuse embed() from memory_client.
sys.path.insert(0, str(Path(__file__).parent))
from memory_client import db_conn, load_config, embed  # type: ignore

PROJECT_ROOT = Path(os.getenv("BCF_PROJECT_ROOT", Path(__file__).resolve().parents[2]))
BUGS_DIR     = PROJECT_ROOT / "tasks" / ".bugs"
SIM_THRESHOLD = 0.65   # cosine sim для match: тот же баг (bge-m3, эмпирически на STACK-03 — variant'ы формулировки UI-багов дают 0.66-0.72)
CHRONIC_AT    = 2      # reopened_count >= 2 → chronic


def _slug(text: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", text.lower()).strip("-")
    return s[:60]


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _next_short_id(cur, task: str) -> str:
    cur.execute("SELECT short_id FROM agent_memory.bugs WHERE task_id=%s ORDER BY opened_at", (task,))
    used = [r[0] for r in cur.fetchall()]
    n = 1
    while f"B-{n:03d}" in used:
        n += 1
    return f"B-{n:03d}"


def _md_path(task: str, short_id: str) -> Path:
    return BUGS_DIR / task / f"{short_id}.md"


def _write_md(bug: dict[str, Any]) -> None:
    p = _md_path(bug["task_id"], bug["short_id"])
    p.parent.mkdir(parents=True, exist_ok=True)
    history_lines = "\n".join(f"  - {h}" for h in bug.get("history", []))
    test = bug.get("regression_test_path") or "(none yet)"
    body = f"""# {bug['short_id']} — {bug['summary']}

```yaml
id: {bug['short_id']}
task: {bug['task_id']}
signature: {bug['signature']}
opened_at: {bug.get('opened_at') or _now()}
opened_by: {bug.get('opened_by') or 'unknown'}
severity: {bug['severity']}
must_address: {str(bug.get('must_address', True)).lower()}
status: {bug['status']}
reopened_count: {bug.get('reopened_count', 0)}
regression_test: {test}
verification: |
  {bug['verification']}
fix_diff_fingerprint: {bug.get('fix_diff_fingerprint') or '(open)'}
fix_iteration: {bug.get('fix_iteration') or '(open)'}
```

## history

{history_lines or '  - (none)'}
"""
    p.write_text(body, encoding="utf-8")


def _row_to_dict(row, cols) -> dict[str, Any]:
    d = dict(zip(cols, row))
    if "history" in d and d["history"] is None:
        d["history"] = []
    return d


BUG_COLS = (
    "id::text", "short_id", "task_id", "signature", "summary", "verification",
    "severity", "status", "must_address", "fix_diff_fingerprint",
    "fix_iteration", "reopened_count", "regression_test_path", "history",
    "opened_by", "opened_at::text", "closed_at::text"
)
BUG_COLS_OUT = (
    "id", "short_id", "task_id", "signature", "summary", "verification",
    "severity", "status", "must_address", "fix_diff_fingerprint",
    "fix_iteration", "reopened_count", "regression_test_path", "history",
    "opened_by", "opened_at", "closed_at"
)


def _select_match(cur, cfg: dict, task: str, summary: str, verification: str) -> dict | None:
    """Search same-task bug by embedding similarity на summary (verification — техн.
    условие, лексика плавает; summary — семантическая суть). Returns dict or None."""
    if not summary.strip():
        return None
    vec = embed(cfg, summary)
    vec_lit = "[" + ",".join(f"{x:.6f}" for x in vec) + "]"
    cur.execute(
        f"""
        SELECT {', '.join(BUG_COLS)},
               1 - (embedding <=> %s::vector) AS sim
        FROM agent_memory.bugs
        WHERE task_id = %s
          AND status IN ('open', 'fixed', 'chronic')
        ORDER BY embedding <=> %s::vector
        LIMIT 1
        """,
        (vec_lit, task, vec_lit),
    )
    row = cur.fetchone()
    if not row:
        return None
    sim = row[-1]
    if sim < SIM_THRESHOLD:
        return None
    d = _row_to_dict(row[:-1], BUG_COLS_OUT)
    d["_similarity"] = float(sim)
    return d


def cmd_open(args, cfg):
    payload = json.loads(args.json or sys.stdin.read())
    items = payload if isinstance(payload, list) else [payload]
    results = []
    with db_conn(cfg) as conn, conn.cursor() as cur:
        for it in items:
            task = it["task"]
            summary = it["summary"]
            verification = it.get("verification", "")
            severity = it.get("severity", "medium")
            opened_by = it.get("opened_by", "unknown")
            must_address = bool(it.get("must_address", True))
            iteration = it.get("iteration")
            signature = it.get("signature") or _slug(summary)

            existing = _select_match(cur, cfg, task, summary, verification)
            # embedding для хранения тоже summary-only (consistency для будущих recall'ов).
            vec = embed(cfg, summary)
            vec_lit = "[" + ",".join(f"{x:.6f}" for x in vec) + "]"

            if existing:
                # Re-detect → reopen if fixed, else just touch last_seen.
                new_status = existing["status"]
                reopened = existing["reopened_count"]
                hist = list(existing.get("history") or [])
                if existing["status"] == "fixed":
                    reopened += 1
                    new_status = "chronic" if reopened >= CHRONIC_AT else "open"
                    hist.append(f"iter {iteration}: REOPENED (status {existing['status']} → {new_status}, count={reopened})")
                else:
                    hist.append(f"iter {iteration}: re-detected (status stays {existing['status']})")
                cur.execute(
                    """
                    UPDATE agent_memory.bugs
                    SET status=%s, reopened_count=%s, last_seen_at=now(), history=%s,
                        severity=%s, opened_by=COALESCE(opened_by, %s)
                    WHERE id = %s
                    RETURNING short_id
                    """,
                    (new_status, reopened, Json(hist), severity, opened_by, existing["id"]),
                )
                sid = cur.fetchone()[0]
                d = dict(existing)
                d.update(status=new_status, reopened_count=reopened, history=hist, severity=severity)
                _write_md(d)
                results.append({"action": "reopened" if new_status != existing["status"] else "redetected",
                                "short_id": sid, "similarity": existing["_similarity"], "status": new_status})
            else:
                short_id = _next_short_id(cur, task)
                hist = [f"iter {iteration}: opened by {opened_by}"]
                cur.execute(
                    """
                    INSERT INTO agent_memory.bugs
                      (short_id, task_id, signature, summary, verification, severity,
                       status, must_address, embedding, history, opened_by)
                    VALUES (%s, %s, %s, %s, %s, %s, 'open', %s, %s::vector, %s, %s)
                    RETURNING short_id
                    """,
                    (short_id, task, signature, summary, verification, severity,
                     must_address, vec_lit, Json(hist), opened_by),
                )
                sid = cur.fetchone()[0]
                _write_md({
                    "short_id": sid, "task_id": task, "signature": signature,
                    "summary": summary, "verification": verification, "severity": severity,
                    "status": "open", "must_address": must_address, "reopened_count": 0,
                    "history": hist, "opened_by": opened_by, "opened_at": _now()
                })
                results.append({"action": "opened", "short_id": sid, "status": "open"})
    print(json.dumps(results, ensure_ascii=False, indent=2))


def cmd_close(args, cfg):
    with db_conn(cfg) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT {', '.join(BUG_COLS)} FROM agent_memory.bugs WHERE short_id=%s AND task_id=%s",
            (args.short_id, args.task),
        )
        row = cur.fetchone()
        if not row:
            sys.exit(f"bug not found: {args.task}/{args.short_id}")
        d = _row_to_dict(row, BUG_COLS_OUT)
        hist = list(d.get("history") or [])
        hist.append(f"iter {args.iteration}: closed (diff={args.diff_fingerprint[:12] if args.diff_fingerprint else 'n/a'})")
        cur.execute(
            """
            UPDATE agent_memory.bugs
            SET status='fixed', fix_diff_fingerprint=%s, fix_iteration=%s, closed_at=now(),
                last_seen_at=now(), history=%s
            WHERE id=%s
            """,
            (args.diff_fingerprint, args.iteration, Json(hist), d["id"]),
        )
        d.update(status='fixed', fix_diff_fingerprint=args.diff_fingerprint,
                 fix_iteration=args.iteration, history=hist)
        _write_md(d)
    print(json.dumps({"closed": args.short_id, "task": args.task}, ensure_ascii=False))


def cmd_list(args, cfg):
    where = ["task_id=%s"]
    params: list = [args.task]
    if args.status and args.status != "all":
        where.append("status=%s")
        params.append(args.status)
    with db_conn(cfg) as conn, conn.cursor() as cur:
        cur.execute(
            f"SELECT {', '.join(BUG_COLS)} FROM agent_memory.bugs "
            f"WHERE {' AND '.join(where)} "
            f"ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 "
            f"  WHEN 'medium' THEN 2 ELSE 3 END, opened_at",
            tuple(params),
        )
        rows = cur.fetchall()
    out = [_row_to_dict(r, BUG_COLS_OUT) for r in rows]
    print(json.dumps(out, ensure_ascii=False, indent=2))


def cmd_link_test(args, cfg):
    with db_conn(cfg) as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE agent_memory.bugs SET regression_test_path=%s "
            "WHERE short_id=%s AND task_id=%s RETURNING short_id",
            (args.test_path, args.short_id, args.task),
        )
        if not cur.fetchone():
            sys.exit(f"bug not found: {args.task}/{args.short_id}")
    print(json.dumps({"linked": args.short_id, "test": args.test_path}))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    pop = sub.add_parser("open"); pop.add_argument("--json")
    pcl = sub.add_parser("close")
    pcl.add_argument("--task", required=True)
    pcl.add_argument("--short-id", required=True, dest="short_id")
    pcl.add_argument("--diff-fingerprint", required=True, dest="diff_fingerprint")
    pcl.add_argument("--iteration", required=True)
    pls = sub.add_parser("list")
    pls.add_argument("--task", required=True)
    pls.add_argument("--status", default="open")
    plt = sub.add_parser("link-test")
    plt.add_argument("--task", required=True)
    plt.add_argument("--short-id", required=True, dest="short_id")
    plt.add_argument("--test-path", required=True, dest="test_path")
    args = p.parse_args()
    cfg = load_config()
    if args.cmd == "open":      cmd_open(args, cfg)
    elif args.cmd == "close":   cmd_close(args, cfg)
    elif args.cmd == "list":    cmd_list(args, cfg)
    elif args.cmd == "link-test": cmd_link_test(args, cfg)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        sys.stderr.write(f"bug_tracker: {type(e).__name__}: {e}\n")
        sys.exit(1)
