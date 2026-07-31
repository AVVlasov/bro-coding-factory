#!/usr/bin/env bash
# task-progression-gate — PreToolUse (Write|Edit).
# Closes the loophole where the agent declares a task "done" verbally and moves on
# without a judge verdict. Fires when tasks/CURRENT-FOCUS.md is advanced to a STACK
# task: every Gate-вход predecessor must have a PASS verdict in tasks/.verdicts/.
#
# See docs/agentic/task-execution-protocol.md §3 and orchestration.md §16.7.
# Escape: BCF_PROGRESSION_GATE_DISABLED=1 + same-day docs/decisions.md note.

set -uo pipefail

if [ "${BCF_PROGRESSION_GATE_DISABLED:-0}" = "1" ]; then
  today="$(date +%Y-%m-%d 2>/dev/null || echo x)"
  if grep -q "^## ${today}.*BCF_PROGRESSION_GATE_DISABLED" docs/decisions.md 2>/dev/null; then
    exit 0
  fi
fi

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$project_dir" 2>/dev/null || exit 0

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0
command -v python >/dev/null 2>&1 || exit 0

parsed=$(printf '%s' "$input" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); print(''); sys.exit(0)
ti = d.get('tool_input', {}) or {}
print(ti.get('file_path','') or '')
txt = ti.get('content','') or ti.get('new_string','') or ''
print(' '.join(str(txt).split()))
" 2>/dev/null || true)

target=$(printf '%s' "$parsed" | sed -n '1p')
newtext=$(printf '%s' "$parsed" | sed -n '2p')

# Only guard advancement of CURRENT-FOCUS.md
case "$target" in
  *CURRENT-FOCUS.md) ;;
  *) exit 0 ;;
esac

# Task being set as focus = first STACK-NN mentioned in the new content
focus=$(printf '%s' "$newtext" | grep -oE '(STACK|TASK)-[0-9]+' | head -1 || true)
[ -z "$focus" ] && exit 0

tf=$(ls tasks/${focus}-*.md 2>/dev/null | head -1 || true)
[ -z "$tf" ] && exit 0

# Predecessors from the Gate-вход line of that task file
gate_line=$(grep -m1 -E '^\*\*Gate-вход' "$tf" 2>/dev/null || true)
preds=$(printf '%s' "$gate_line" | grep -oE '(STACK|TASK)-[0-9]+' | sort -u || true)
[ -z "$preds" ] && exit 0

missing=()
while IFS= read -r pred; do
  [ -z "$pred" ] && continue
  vf="tasks/.verdicts/${pred}.md"
  if [ ! -f "$vf" ]; then
    missing+=("$pred — нет verdict-файла $vf")
  elif ! grep -qE '^verdict:[[:space:]]*PASS' "$vf" 2>/dev/null; then
    missing+=("$pred — $vf есть, но verdict ≠ PASS")
  fi
done <<< "$preds"

[ "${#missing[@]}" -eq 0 ] && exit 0

reason_lines=("PROGRESSION-GATE BLOCKED — нельзя переводить фокус на ${focus}.")
reason_lines+=("")
reason_lines+=("Предыдущая(ие) задача(и) по Gate-вход не прошли судью:")
for m in "${missing[@]}"; do reason_lines+=("  - $m"); done
reason_lines+=("")
reason_lines+=("«Выполнено» в чате статусом не является (task-execution-protocol.md §3).")
reason_lines+=("Закрой текущую задачу: /verify <предыдущая> → судья PASS → verdict-файл.")

if command -v python >/dev/null 2>&1; then
  printf '%s\n' "${reason_lines[@]}" | python -c "
import sys, json
data = sys.stdin.buffer.read().decode('utf-8', 'replace')
sys.stdout.buffer.write(json.dumps({'decision':'block','reason':data.rstrip()}, ensure_ascii=False).encode('utf-8'))
" >&2
else
  printf '%s\n' "${reason_lines[@]}" >&2
fi
exit 2
