"""CLI: добавить одну entry в память.

Пример:
  python memorize.py --kind failure \
      --title "TASK-01 startup branch bug" \
      --body "init() under test-mode flag → test window not created" \
      --source "src/main.ts:456" \
      --tags TASK-01,regression,test-infra

Тело можно передавать через stdin: `echo "тело" | python memorize.py --kind decision --title ...`.
"""
import argparse
import sys

from memory import VALID_KINDS, make_memory, parser_common


def main() -> None:
    p = argparse.ArgumentParser(parents=[parser_common()],
                                description="Записать одну entry в harness memory")
    p.add_argument("--kind", required=True, choices=sorted(VALID_KINDS))
    p.add_argument("--title", required=True)
    p.add_argument("--body", default=None, help="Тело (если не задано — читается из stdin)")
    p.add_argument("--metadata", default=None, help="JSON object")
    p.add_argument("--source", default=None)
    p.add_argument("--tags", default=None, help="comma-separated")
    p.add_argument("--embedding-text", default=None,
                   help="Если задано — embed по этой строке, не по title+body")
    a = p.parse_args()

    body = a.body
    if body is None:
        body = sys.stdin.read().strip()
    if not body:
        print("ERROR: --body не задано и stdin пуст", file=sys.stderr)
        sys.exit(2)

    metadata = None
    if a.metadata:
        import json as _j
        metadata = _j.loads(a.metadata)
    tags = a.tags.split(",") if a.tags else None

    m = make_memory(a)
    try:
        eid = m.add(kind=a.kind, title=a.title, body=body, metadata=metadata,
                    source=a.source, tags=tags, embedding_text=a.embedding_text)
        print(f"[ok] entry #{eid} ({a.kind}) — {a.title}")
    finally:
        m.close()


if __name__ == "__main__":
    main()
