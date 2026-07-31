#!/usr/bin/env bash
# Stop-hook: validates DoD-checkbox legend usage in tasks/ and subtask chains.
# Reads stdin (Claude Code Stop hook payload), emits JSON decision.
# Allowed checkboxes: [ ] [V] [X] [~] [!]
#
# Failure cases (decision: "block"):
#   1. Use of [v] / [x] (lowercase) on lines that look like checkboxes — must be uppercase.
#   2. [X] without "→ subtask:" or "→ decision:" reference within 2 following lines.
#   3. [~] without a follow-up indented line describing state ("сделано:" / "осталось:").
#   4. Legacy [-] / [?] checkbox markers.
#
# Disable with BCF_DOD_VALIDATOR_DISABLED=1.

set -u
if [ "${BCF_DOD_VALIDATOR_DISABLED:-0}" = "1" ]; then
  today="$(date +%Y-%m-%d)"
  if grep -q "^## ${today}.*BCF_DOD_VALIDATOR_DISABLED" docs/decisions.md 2>/dev/null; then
    echo '{"decision":"approve"}'
    exit 0
  fi
  echo '{"decision":"block","reason":"BCF_DOD_VALIDATOR_DISABLED set without same-day decisions.md entry."}' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TASKS_DIR="$ROOT/tasks"
[ -d "$TASKS_DIR" ] || { echo '{"decision":"approve"}'; exit 0; }

issues=()

while IFS= read -r -d '' f; do

  # 1) lowercase [v] / [x] on bullet lines
  while IFS=: read -r line content; do
    [ -z "$line" ] && continue
    issues+=("$f:$line: lowercase checkbox marker — use [V] or [X] (uppercase)")
  done < <(grep -nE '^\s*-\s+\[[vx]\]' "$f" || true)

  # 2) legacy [-] / [?]
  while IFS=: read -r line content; do
    [ -z "$line" ] && continue
    issues+=("$f:$line: legacy checkbox marker [-]/[?] — convert to [V]/[X]/[~]/[!]")
  done < <(grep -nE '^\s*-\s+\[[-?]\]' "$f" || true)

  # 3) [X] without a → subtask: / → decision: ref nearby
  while IFS=: read -r line _; do
    [ -z "$line" ] && continue
    end=$((line + 3))
    block=$(sed -n "${line},${end}p" "$f")
    if ! printf '%s' "$block" | grep -qE '→\s*(subtask|decision):'; then
      issues+=("$f:$line: [X] checkbox без ссылки → subtask: или → decision: (CLAUDE.md §11.11)")
    fi
  done < <(grep -nE '^\s*-\s+\[X\]' "$f" || true)

  # 4) [~] without indented follow-up describing state
  while IFS=: read -r line _; do
    [ -z "$line" ] && continue
    nextline=$((line + 1))
    next=$(sed -n "${nextline}p" "$f")
    # Allow follow-up that is indented (starts with whitespace+non-dash) OR contains 'сделано'/'осталось'/'status:' on the bullet itself
    bullet=$(sed -n "${line}p" "$f")
    if ! printf '%s' "$bullet" | grep -qiE '(сделано|осталось|status:)' \
       && ! printf '%s' "$next" | grep -qE '^\s+\S'; then
      issues+=("$f:$line: [~] checkbox без описания состояния (CLAUDE.md §11.11)")
    fi
  done < <(grep -nE '^\s*-\s+\[~\]' "$f" || true)

done < <(find "$TASKS_DIR" -type f -name '*.md' -not -path '*/archive/*' -print0)

if [ "${#issues[@]}" -eq 0 ]; then
  echo '{"decision":"approve"}'
  exit 0
fi

reason="DoD format violations (CLAUDE.md §11.11):"$'\n'
for i in "${issues[@]}"; do reason+="  - $i"$'\n'; done

# Emit JSON-safe blocking decision via stdin (avoids heredoc terminator issues)
if command -v python >/dev/null 2>&1; then
  printf '%s' "$reason" | python -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.stdin.read().rstrip()}))" >&2
elif command -v python3 >/dev/null 2>&1; then
  printf '%s' "$reason" | python3 -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.stdin.read().rstrip()}))" >&2
else
  printf '%s' "$reason" >&2
fi
exit 2
