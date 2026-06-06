"""CLI: запрос в память.

Примеры:
  python ask.py "similar tests with startMinimized"
  python ask.py "failures last week" --kind failure --since-days 7
  python ask.py "what was done yesterday" --kind daily-summary --k 1
  python ask.py --list-recent --days 14 --kind decision

Опционально --format=json для машинной обработки (вызов из агента / другого инструмента).
"""
import argparse
import json
import sys

from memory import VALID_KINDS, make_memory, parser_common


def main() -> None:
    p = argparse.ArgumentParser(parents=[parser_common()],
                                description="Semantic search в harness memory")
    p.add_argument("query", nargs="?", default=None, help="Запрос (если не --list-recent)")
    p.add_argument("--kind", choices=sorted(VALID_KINDS), default=None)
    p.add_argument("-k", "--k", type=int, default=5)
    p.add_argument("--since-days", type=int, default=None)
    p.add_argument("--list-recent", action="store_true",
                   help="Не делать semantic search, а вернуть последние записи")
    p.add_argument("--days", type=int, default=7, help="Для --list-recent: за сколько дней")
    p.add_argument("--format", choices=["text", "json", "markdown"], default="text")
    p.add_argument("--filter-project", default=None,
                   help="Фильтр по project (по умолчанию — все)")
    a = p.parse_args()

    m = make_memory(a)
    try:
        if a.list_recent:
            results = m.list_recent(kind=a.kind, days=a.days, limit=a.k)
        else:
            if not a.query:
                print("ERROR: укажите query или --list-recent", file=sys.stderr)
                sys.exit(2)
            results = m.search(a.query, k=a.k, kind=a.kind, project=a.filter_project,
                               since_days=a.since_days)
    finally:
        m.close()

    if not results:
        print("(нет совпадений)" if a.format != "json" else "[]")
        return

    if a.format == "json":
        out = [{
            "id": e.id, "kind": e.kind, "project": e.project, "title": e.title,
            "body": e.body, "metadata": e.metadata, "source": e.source, "tags": e.tags,
            "created_at": e.created_at, "score": e.score,
        } for e in results]
        print(json.dumps(out, ensure_ascii=False, indent=2))
    elif a.format == "markdown":
        for e in results:
            sim = f" (sim={1 - e.score:.3f})" if e.score is not None else ""
            print(f"### [{e.id}] {e.kind} — {e.title}{sim}")
            print(f"*{e.created_at} · {e.project}{' · ' + e.source if e.source else ''}*\n")
            print(e.body)
            print()
    else:
        for e in results:
            print(e)
            print()


if __name__ == "__main__":
    main()
