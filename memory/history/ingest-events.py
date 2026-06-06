"""CLI: ingest pipeline — читает источники, фильтрует значимые события, свёртывает в entries.

Источники:
1) loop/events.jsonl                   — event-sourced harness (--events-path)
2) tasks/.verdicts/*.md                — verdict-файлы (--verdicts-dir)

Свёртка событий в memory entries делается опционально через `opencode run` (CLI вызов,
модель задаётся --llm-model / env). Если LLM недоступен — fallback: записываем raw event
как entry без свёртки. Все источники работают и без LLM.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from datetime import datetime

from memory import make_memory, parser_common

# Модель для опциональной LLM-свёртки. Пусто = свёртка отключена, пишем raw events.
# Задаётся через --llm-model или env MEMORY_LLM_MODEL (например <model>).
DEFAULT_LLM_MODEL = os.environ.get("MEMORY_LLM_MODEL", "")


def find_repo_root(start: Path) -> Path:
    p = start.resolve()
    while p != p.parent:
        if (p / ".git").exists() or (p / "loop").exists():
            return p
        p = p.parent
    return start.resolve()


def _rel(path: Path, repo: Path) -> str:
    """Стабильный ключ-источник: путь относительно repo (или абсолютный, если вне repo).
    POSIX-разделители — чтобы ключ курсора не зависел от ОС."""
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def have_opencode() -> bool:
    return shutil.which("opencode") is not None


def llm_summarize(prompt: str, model: str = "") -> str | None:
    """Вызвать opencode run на свёртку. Возвращает stdout или None при ошибке/отключении."""
    if not model or not have_opencode():
        return None
    try:
        proc = subprocess.run(
            ["opencode", "run", "--model", model, "--dangerously-skip-permissions"],
            input=prompt, capture_output=True, text=True, timeout=180, encoding="utf-8"
        )
        if proc.returncode != 0:
            return None
        return proc.stdout.strip()
    except Exception:
        return None


def ingest_verdicts(m, vdir: Path, repo: Path, llm_model: str = "") -> int:
    """Прочитать <verdicts-dir>/*.md и записать новые в память."""
    if not vdir.exists():
        return 0
    source_key = _rel(vdir, repo)
    last_cursor = m.last_cursor(source_key) or ""
    created = 0
    for vf in sorted(vdir.glob("*.md")):
        # Простой курсор: имя файла как ключ; пропускаем, если уже видели по mtime
        marker = f"{vf.name}:{int(vf.stat().st_mtime)}"
        if marker <= last_cursor:
            continue
        content = vf.read_text(encoding="utf-8", errors="replace")
        # Извлекаем verdict
        verdict = "UNKNOWN"
        for line in content.splitlines():
            if line.startswith("verdict:"):
                verdict = line.split(":", 1)[1].strip()
                break
        kind = "task-closed" if verdict == "PASS" else "failure"
        task_id = vf.stem
        title = f"{task_id} verdict: {verdict}"

        # Свёртка через LLM (если включена)
        body = content
        summary = llm_summarize(
            f"Сверни verdict-отчёт задачи {task_id} в memory entry для harness памяти:\n\n"
            f"- Если PASS: 2-3 предложения о том, что было сделано (для daily/weekly summary).\n"
            f"- Если FAIL/NEEDS-MORE-EVIDENCE: 2-3 предложения о root cause + lesson learned "
            f"(чтобы в следующий раз не повторить).\n\n"
            f"Не дублируй полный verdict. Только сжатые тезисы.\n\n"
            f"=== VERDICT ===\n{content}\n",
            model=llm_model,
        )
        if summary:
            body = summary + "\n\n---\n\n" + content[:2000]

        m.add(
            kind=kind, title=title, body=body,
            metadata={"task_id": task_id, "verdict": verdict, "file": _rel(vf, repo)},
            source=f"{source_key}/{vf.name}",
            tags=[task_id, verdict.lower()],
        )
        created += 1
        last_cursor = max(last_cursor, marker)
    m.record_run(source=source_key, events_seen=len(list(vdir.glob("*.md"))),
                 entries_created=created, last_cursor=last_cursor)
    return created


def ingest_events_jsonl(m, ef: Path, repo: Path) -> int:
    """Прочитать events.jsonl (event-sourced harness)."""
    if not ef.exists():
        return 0
    source_key = _rel(ef, repo)
    last_cursor = m.last_cursor(source_key) or ""
    significant = {"phase-failed", "restart-required", "verdict-fail", "human-callout",
                   "commit", "task-closed", "loop-paused"}
    created = 0
    new_cursor = last_cursor
    seen = 0
    with ef.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            seen += 1
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = ev.get("ts", "")
            if ts <= last_cursor:
                continue
            if ev.get("event_type") not in significant:
                new_cursor = max(new_cursor, ts)
                continue
            title = f"{ev.get('event_type')} · {ev.get('phase', '?')} · {ev.get('task_id', '?')}"
            body = json.dumps(ev, ensure_ascii=False, indent=2)
            m.add(
                kind="failure" if "fail" in ev.get("event_type", "") else "task-closed",
                title=title, body=body, metadata=ev,
                source=f"{source_key}#{ts}",
                tags=[ev.get("event_type", ""), ev.get("task_id", "")]
            )
            created += 1
            new_cursor = max(new_cursor, ts)
    m.record_run(source=source_key, events_seen=seen,
                 entries_created=created, last_cursor=new_cursor)
    return created


def main() -> None:
    p = argparse.ArgumentParser(parents=[parser_common()],
                                description="Ingest pipeline в harness memory")
    p.add_argument("--repo", default=None,
                   help="Корень проекта (auto-detect по .git/loop)")
    p.add_argument("--sources", default="verdicts,events",
                   help="comma-list: verdicts,events (default: verdicts,events)")
    p.add_argument("--verdicts-dir", default="tasks/.verdicts",
                   help="Каталог verdict-файлов (относительно --repo или абсолютный). "
                        "Default: tasks/.verdicts")
    p.add_argument("--events-path", default="loop/events.jsonl",
                   help="Путь к events.jsonl (относительно --repo или абсолютный). "
                        "Default: loop/events.jsonl")
    p.add_argument("--llm-model", default=DEFAULT_LLM_MODEL,
                   help="Модель для опциональной LLM-свёртки verdict-ов через `opencode run`. "
                        "Пусто = свёртка отключена (пишем raw). Env: MEMORY_LLM_MODEL")
    a = p.parse_args()

    repo = Path(a.repo) if a.repo else find_repo_root(Path(__file__).parent)

    def _resolve(spec: str) -> Path:
        sp = Path(spec)
        return sp if sp.is_absolute() else repo / sp

    vdir = _resolve(a.verdicts_dir)
    events_path = _resolve(a.events_path)

    m = make_memory(a)
    total = 0
    try:
        sources = [s.strip() for s in a.sources.split(",")]
        if "verdicts" in sources:
            n = ingest_verdicts(m, vdir, repo, llm_model=a.llm_model)
            print(f"[verdicts] +{n} entries")
            total += n
        if "events" in sources:
            n = ingest_events_jsonl(m, events_path, repo)
            print(f"[events.jsonl] +{n} entries")
            total += n
        print(f"[total] +{total} entries to {a.db}")
    finally:
        m.close()


if __name__ == "__main__":
    main()
