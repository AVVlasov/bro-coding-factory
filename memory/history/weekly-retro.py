"""CLI: weekly retro = «garbage collection day».

Берёт все memory entries за последние 7 дней (failure + daily-summary + human-callout),
опционально анализирует LLM-ом на повторяющиеся паттерны, lessons, кандидатов в lint-правила.
Если LLM недоступен — fallback на сырой инвентарь событий.

Output:
  1) Новая entry kind=weekly-retro
  2) Markdown отчёт в <retros-dir>/YYYY-WW.md (по умолчанию ./retros рядом со скриптом)

Cron-кандидат: еженедельно, напр. воскресенье 22:00 (cron на Linux/macOS или
Task Scheduler на Windows).
"""
import argparse
import os
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

from memory import make_memory, parser_common

# Пусто = LLM-анализ отключён. Env MEMORY_LLM_MODEL, например <model>.
DEFAULT_LLM_MODEL = os.environ.get("MEMORY_LLM_MODEL", "")


def llm(prompt: str, model: str = "") -> str | None:
    import shutil
    if not model or not shutil.which("opencode"):
        return None
    try:
        proc = subprocess.run(
            ["opencode", "run", "--model", model, "--dangerously-skip-permissions"],
            input=prompt, capture_output=True, text=True, timeout=300, encoding="utf-8"
        )
        return proc.stdout.strip() if proc.returncode == 0 else None
    except Exception:
        return None


def iso_year_week(d: datetime | None = None) -> str:
    d = d or datetime.now()
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def main() -> None:
    p = argparse.ArgumentParser(parents=[parser_common()])
    p.add_argument("--retros-dir", default=None,
                   help="Каталог для markdown отчётов (default: ./retros рядом со скриптом)")
    p.add_argument("--week", default=None,
                   help="YYYY-Www (default: текущая неделя)")
    p.add_argument("--llm-model", default=DEFAULT_LLM_MODEL,
                   help="Модель для LLM-анализа через `opencode run`. Пусто = raw. "
                        "Env: MEMORY_LLM_MODEL")
    a = p.parse_args()

    week_id = a.week or iso_year_week()
    m = make_memory(a)
    try:
        entries = m.list_recent(days=7, limit=1000)
        # фильтр на «значимые»
        keep = {"failure", "human-callout", "daily-summary", "task-closed", "audit-record"}
        entries = [e for e in entries if e.kind in keep]
        if not entries:
            print(f"[skip] нет entries за неделю")
            return

        # компактный inventory
        inventory = []
        for e in entries:
            head = f"[{e.kind}] {e.created_at[:10]} — {e.title}"
            inventory.append(head)
            if e.body:
                inventory.append(e.body[:400].rstrip())
            inventory.append("")
        inv_text = "\n".join(inventory)

        prompt = (
            f"Ты — harness-аналитик. Анализируй события harness за неделю {week_id}.\n\n"
            f"Найди:\n"
            f"a) ПОВТОРЯЮЩИЕСЯ failure-паттерны (одна и та же ошибка ≥2 раз).\n"
            f"b) LESSONS, которые уже зафиксированы, но агент их игнорирует.\n"
            f"c) Новые LINT-ПРАВИЛА или TRIGGERS, превратившие бы конкретные failures в "
            f"compile-time / pre-commit errors.\n"
            f"d) Что в harness РАБОТАЕТ хорошо (закрепить).\n"
            f"e) Что в harness РАБОТАЕТ плохо (изменить).\n\n"
            f"Формат ответа — markdown:\n"
            f"## Repeating failures\n- ...\n\n"
            f"## Ignored lessons\n- ...\n\n"
            f"## Proposed new rules / triggers\n- ...\n\n"
            f"## What works\n- ...\n\n"
            f"## What to change\n- ...\n\n"
            f"Текст на русском, конкретный, со ссылками на entry-id где можно.\n\n"
            f"=== INVENTORY OF EVENTS ({len(entries)}) ===\n{inv_text}\n"
        )
        report = llm(prompt, model=a.llm_model)
        if not report:
            report = "(LLM недоступен — сырой инвентарь ниже)\n\n" + inv_text

        # 1) entry в БД
        eid = m.add(
            kind="weekly-retro",
            title=f"Weekly retro {week_id}",
            body=report,
            metadata={"week": week_id, "source_entries": len(entries)},
            source="weekly-retro.py",
            tags=[week_id]
        )

        # 2) markdown в retros/
        if a.retros_dir:
            retros_dir = Path(a.retros_dir)
        else:
            # по умолчанию — каталог retros/ рядом со скриптом
            retros_dir = Path(__file__).parent / "retros"
        retros_dir.mkdir(parents=True, exist_ok=True)
        md_path = retros_dir / f"{week_id}.md"
        header = (
            f"# Weekly retro {week_id} — {a.project}\n\n"
            f"**Сгенерировано:** {datetime.now().isoformat(timespec='seconds')}\n"
            f"**Memory entry:** #{eid}\n"
            f"**Source entries:** {len(entries)}\n\n---\n\n"
        )
        md_path.write_text(header + report, encoding="utf-8")
        print(f"[ok] weekly retro entry #{eid}; markdown: {md_path}")
    finally:
        m.close()


if __name__ == "__main__":
    main()
