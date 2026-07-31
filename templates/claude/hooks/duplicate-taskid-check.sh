#!/usr/bin/env bash
# Stop-hook (BLOCKING). Forbids duplicate task-id headers within a single tasks/*.md file.
# Catches the 2026-05-09 PWB-06 incident — agent silently created a second `### PWB-06`
# section with truncated DoD, then marked the first one [V] DONE.
#
# Failure rule:
#   In any tasks/*.md file, headers matching `^### <TOKEN>-\d+(\.\d+)?` must be unique.
#   Two `### PWB-06` headers in the same file = block.
#
# Disable (emergency only): BCF_DUPID_DISABLED=1 + entry in docs/decisions.md (today).

set -uo pipefail

if [ "${BCF_DUPID_DISABLED:-0}" = "1" ]; then
  # Even when disabled, require a same-day decisions.md note.
  today="$(date +%Y-%m-%d)"
  if ! grep -q "^## ${today}.*BCF_DUPID_DISABLED" docs/decisions.md 2>/dev/null; then
    python -c "import json; print(json.dumps({'decision':'block','reason':'BCF_DUPID_DISABLED set without same-day decisions.md entry. Add: ## '+__import__('datetime').date.today().isoformat()+' \u2014 BCF_DUPID_DISABLED <reason>'}))" >&2 2>/dev/null
    exit 2
  fi
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TASKS_DIR="$ROOT/tasks"
[ -d "$TASKS_DIR" ] || { echo '{"decision":"approve"}'; exit 0; }

dups=()
while IFS= read -r -d '' f; do
  # Extract `### TOKEN-NN[.M]` headers
  ids=$(grep -nE '^###[[:space:]]+[A-Z][A-Z0-9-]*-[0-9]+(\.[0-9]+)?' "$f" 2>/dev/null \
        | sed -E 's/^([0-9]+):###[[:space:]]+([A-Z][A-Z0-9-]*-[0-9]+(\.[0-9]+)?).*$/\1 \2/' || true)
  [ -z "$ids" ] && continue

  # Find IDs that occur more than once
  dup_ids=$(echo "$ids" | awk '{print $2}' | sort | uniq -d)
  [ -z "$dup_ids" ] && continue

  while IFS= read -r dup_id; do
    [ -z "$dup_id" ] && continue
    lines=$(echo "$ids" | awk -v id="$dup_id" '$2==id {print $1}' | tr '\n' ',' | sed 's/,$//')
    dups+=("$f: duplicate header '### $dup_id' on lines $lines")
  done <<< "$dup_ids"
done < <(find "$TASKS_DIR" -type f -name '*.md' -not -path '*/archive/*' -print0)

if [ "${#dups[@]}" -eq 0 ]; then
  echo '{"decision":"approve"}'
  exit 0
fi

reason="DUPLICATE-TASKID BLOCKED. Same task-id appears twice in one taskfile (CLAUDE.md \u00a711.15):"$'\n'
for d in "${dups[@]}"; do reason+="  - $d"$'\n'; done
reason+=""$'\n'"Fix: merge the sections (preserve full DoD union, never truncate), or rename second to <id>.1."

if command -v python >/dev/null 2>&1; then
  python -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.stdin.read().rstrip()}))" >&2 <<< "$reason"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.stdin.read().rstrip()}))" >&2 <<< "$reason"
else
  printf '%s' "$reason" >&2
fi
exit 2
