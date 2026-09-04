#!/usr/bin/env bash
# Blocks destructive bash commands before they execute.
# Receives JSON via stdin: {"tool_name":"Bash","tool_input":{"command":"..."}}

set -euo pipefail

input=$(cat)
# Try python (available on Windows Git Bash) first, fallback to python3.
if command -v python >/dev/null 2>&1; then
  PY=python
elif command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  PY=""
fi
if [ -n "$PY" ]; then
  command=$(echo "$input" | "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")
else
  command=""
fi

if [ -z "$command" ]; then
  exit 0
fi

# --- BLOCKERS ---

# Recursive delete
if echo "$command" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+-[a-zA-Z]*f|rm\s+-[a-zA-Z]*f[a-zA-Z]*\s+-[a-zA-Z]*r|rm\s+--recursive|rm\s+--force.*--recursive'; then
  echo '{"decision":"block","reason":"Destructive command blocked: rm -rf is not allowed. Use specific file deletion instead."}'
  exit 0
fi

# Force push
if echo "$command" | grep -qE 'git\s+push\s+.*--force|git\s+push\s+.*-f\s|git\s+push\s+.*-f$'; then
  echo '{"decision":"block","reason":"Force push blocked: git push --force requires explicit user confirmation. Ask the user to run this manually."}'
  exit 0
fi

# Hard reset
if echo "$command" | grep -qE 'git\s+reset\s+--hard'; then
  echo '{"decision":"block","reason":"Destructive git operation blocked: git reset --hard can destroy uncommitted work. Ask the user to confirm and run manually."}'
  exit 0
fi

# DROP TABLE in SQL
if echo "$command" | grep -qiE 'DROP\s+TABLE|DROP\s+DATABASE|TRUNCATE\s+TABLE'; then
  echo '{"decision":"block","reason":"Destructive SQL blocked: DROP/TRUNCATE operations must be done via a migration file, not executed directly."}'
  exit 0
fi

# Deleting outside project directory
if echo "$command" | grep -qE 'rm\s+.*\.\./|rm\s+/[^D]|del\s+/[sS]'; then
  echo '{"decision":"block","reason":"Deletion outside project directory blocked. Only modify files inside the repository root (git rev-parse --show-toplevel)."}'
  exit 0
fi

# git push without explicit user request (warn, don't block — user may have approved)
# Only block push to main/master without PR
if echo "$command" | grep -qE 'git\s+push\s+.*\s+main$|git\s+push\s+.*\s+master$|git\s+push\s+origin\s+main|git\s+push\s+origin\s+master'; then
  echo '{"decision":"block","reason":"Direct push to main/master blocked. Create a branch and open a PR instead."}'
  exit 0
fi

exit 0
