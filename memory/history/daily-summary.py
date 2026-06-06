"""CLI: вечерний daily-summary.

Берёт все memory entries за сегодня, опционально свёртывает LLM-ом в одно
"что было сделано сегодня", сохраняет как kind=daily-summary. Запросить через
`ask.py "what was done yesterday" --kind daily-summary`.

Если LLM недоступен (модель не задана или `opencode` отсутствует) — fallback на
сырой список пунктов.

Cron-кандидат: ~23:30 ежедневно (cron на Linux/macOS или Task Scheduler на Windows).
"""
import argparse
import os
import subprocess
import sys
from datetime import datetime, timedelta

from memory import make_memory, parser_common

# Пусто = LLM-свёртка отключена. Env MEMORY_LLM_MODEL, например <model>.
DEFAULT_LLM_MODEL = os.environ.get("MEMORY_LLM_MODEL", "")


def llm(prompt: str, model: str = "") -> str | None:
    import shutil
    if not model or not shutil.which("opencode"):
        return None
    try:
        proc = subprocess.run(
            ["opencode", "run", "--model", model, "--dangerously-skip-permissions"],
            input=prompt, capture_output=True, text=True, timeout=180, encoding="utf-8"
        )
        return proc.stdout.strip() if proc.returncode == 0 else None
    except Exception:
        return None


def main() -> None:
    p = argparse.ArgumentParser(parents=[parser_common()])
    p.add_argument("--date", default=None,
                   help="YYYY-MM-DD (default: сегодня). Свернёт записи именно этой даты.")
    p.add_argument("--llm-model", default=DEFAULT_LLM_MODEL,
                   help="Модель для LLM-свёртки через `opencode run`. Пусто = raw. "
                        "Env: MEMORY_LLM_MODEL")
    a = p.parse_args()

    target = a.date or datetime.now().strftime("%Y-%m-%d")
    m = make_memory(a)
    try:
        entries = m.list_recent(days=1, limit=500)
        # filter по дате (создано today)
        entries = [e for e in entries if e.created_at.startswith(target)
                   and e.kind != "daily-summary"]
        if not entries:
            print(f"[skip] нет entries за {target}")
            return
        bullets = []
        for e in entries:
            bullets.append(f"- [{e.kind}] {e.title}")
            if e.body and len(e.body) < 300:
                bullets.append(f"  {e.body.strip()[:280]}")
        joined = "\n".join(bullets)
        prompt = (
            f"Из списка событий harness за {target} напиши краткую сводку "
            f"«что было сделано сегодня». 5-10 пунктов, на русском, без эмоций.\n\n"
            f"=== EVENTS ===\n{joined}\n"
        )
        summary = llm(prompt, model=a.llm_model) or joined  # fallback — raw bullets
        eid = m.add(
            kind="daily-summary",
            title=f"Daily summary {target}",
            body=summary,
            metadata={"date": target, "source_entries": len(entries)},
            source="daily-summary.py",
            tags=[target]
        )
        print(f"[ok] daily summary entry #{eid} for {target} ({len(entries)} source entries)")
    finally:
        m.close()


if __name__ == "__main__":
    main()
