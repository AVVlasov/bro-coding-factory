#!/usr/bin/env bash
# PreToolUse hook (or PreCompact, depending on where it is installed): at the start of an
# iteration/subagent it recalls anti-pattern records matching the task description and
# injects the top-K into the agent's context as a "known pitfalls — do not repeat" block.
#
# Contract:
#   $BCF_TASK_DESCRIPTION — short task description (read by this hook).
#   $BCF_AGENT_SCOPE      — 'code' | <subagent-name> | 'all'. Default 'code'.
#   $BCF_ITERATION_ID     — id of the current iteration (for the recall-events log).
#
# The hook reads stdin JSON (Claude Code Pre* hook input); if tool_input.prompt or
# description is present it uses that. Otherwise it falls back to $BCF_TASK_DESCRIPTION.
# If there is no description — exit 0 (nothing to match).
#
# Memory client path: $BCF_MEMORY_CLIENT, else $BCF_PROJECT_ROOT/memory/pgvector/memory_client.py.
# Disable: BCF_MEMORY_INJECT_DISABLED=1.
# Always exits 0 (advisory); injects the block via stdout.

set -u
[ "${BCF_MEMORY_INJECT_DISABLED:-0}" = "1" ] && exit 0

# Resolve project root: env override, else repo root relative to this hook (hooks/ -> repo root).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="${BCF_PROJECT_ROOT:-$(cd "$script_dir/.." >/dev/null 2>&1 && pwd)}"
MEMORY_CLIENT="${BCF_MEMORY_CLIENT:-$PROJECT_ROOT/memory/pgvector/memory_client.py}"
[ -f "$MEMORY_CLIENT" ] || exit 0
command -v python >/dev/null 2>&1 || exit 0

# Extract the task description: from stdin (if present), then from env.
STDIN_JSON=""
if [ ! -t 0 ]; then STDIN_JSON="$(cat || true)"; fi

DESC=""
if [ -n "$STDIN_JSON" ]; then
  DESC=$(printf '%s' "$STDIN_JSON" | python -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
for k in ("prompt", "description", "task", "instruction"):
    v = ti.get(k) or d.get(k)
    if v: print(v); break
' 2>/dev/null || true)
fi
[ -z "$DESC" ] && DESC="${BCF_TASK_DESCRIPTION:-}"
[ -z "$DESC" ] && exit 0

SCOPE="${BCF_AGENT_SCOPE:-code}"
ITER="${BCF_ITERATION_ID:-}"

RESULT=$(python "$MEMORY_CLIENT" recall \
            --text "$DESC" --scope "$SCOPE" --k 3 --threshold 0.55 \
            --iteration-id "$ITER" 2>/dev/null || true)

# If the result is empty / an empty array — inject nothing.
[ -z "$RESULT" ] && exit 0
COUNT=$(printf '%s' "$RESULT" | python -c 'import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)' 2>/dev/null || echo 0)
[ "$COUNT" = "0" ] && exit 0

# Print the inject block to stdout. Claude Code collects PreToolUse hook stdout as extra context.
cat <<EOF
<known-anti-patterns source="agent_memory" scope="$SCOPE" matched="$COUNT">
$(printf '%s' "$RESULT" | python -c "
import json, sys
for e in json.load(sys.stdin):
    sim = e.get('similarity', 0.0)
    ts = e.get('trigger_summary', '')
    print('- [sim=%.2f] %s' % (sim, ts))
    ww = e.get('what_went_wrong')
    if ww: print('    what went wrong: ' + ww)
    ca = e.get('correct_alternative')
    if ca: print('    do this instead: ' + ca)
")
</known-anti-patterns>
EOF
exit 0
