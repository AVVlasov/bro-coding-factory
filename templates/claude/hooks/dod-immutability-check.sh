#!/usr/bin/env bash
# Stop-hook (BLOCKING). Enforces DoD immutability for tasks already marked [V].
#
# Rule (CLAUDE.md \u00a711.17):
#   In any tasks/*.md file, if HEAD has a `### <TASK-ID>` section containing
#   any `[V]` checkbox, then in the working tree the DoD-assertion lines under
#   that header MUST NOT be removed or substantively modified.
#   - Adding new assertions (extending DoD) is allowed.
#   - Demoting [V] -> [!] is allowed only with a follow-up "**Reason:**" paragraph.
#   - Removing/rewording a [V]-passed assertion text = block.
#
# This catches the 2026-05-09 incident where an agent silently truncated PWB-06
# DoD when "merging" a duplicate header.
#
# Disable (emergency): BCF_DODIMMUT_DISABLED=1 + same-day decisions.md note.

set -uo pipefail

if [ "${BCF_DODIMMUT_DISABLED:-0}" = "1" ]; then
  today="$(date +%Y-%m-%d)"
  if ! grep -q "^## ${today}.*BCF_DODIMMUT_DISABLED" docs/decisions.md 2>/dev/null; then
    echo '{"decision":"block","reason":"BCF_DODIMMUT_DISABLED set without same-day decisions.md note."}' >&2
    exit 2
  fi
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$ROOT" 2>/dev/null || { echo '{"decision":"approve"}'; exit 0; }

command -v git >/dev/null 2>&1 || { echo '{"decision":"approve"}'; exit 0; }

# Collect modified taskfiles
modified=$(git diff --name-only HEAD -- 'tasks/*.md' 2>/dev/null || true)
[ -z "$modified" ] && { echo '{"decision":"approve"}'; exit 0; }

issues=()

while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue

  # For each `### <ID>` section in HEAD that contains [V], collect its DoD-assertion
  # lines (lines matching `^- \[[V ~X!]\]`). Then verify they all still exist in
  # the working tree (string-match; trivial reordering allowed).
  head_blob=$(git show "HEAD:$f" 2>/dev/null) || continue
  [ -z "$head_blob" ] && continue

  # Walk HEAD blob, find sections with [V]
  python - "$f" <<'PY' "$head_blob" 2>/dev/null
import sys, subprocess, re, json

f = sys.argv[1]
head = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    work = open(f, encoding='utf-8').read()
except Exception:
    sys.exit(0)

# Extract sections from HEAD: split on `^### ` headers
def split_sections(text):
    parts = re.split(r'(?m)^(### .+)$', text)
    out = []
    i = 1
    while i < len(parts):
        header = parts[i]
        body = parts[i+1] if i+1 < len(parts) else ""
        out.append((header, body))
        i += 2
    return out

head_sections = split_sections(head)
work_text = work

violations = []
for header, body in head_sections:
    if '[V]' not in body:
        continue
    # Extract DoD-assertion lines (- [V|X|~|!| ] ...)
    assertions = re.findall(r'(?m)^[ \t]*-[ \t]*\[[VX~! ]\][^\n]*', body)
    for a in assertions:
        # Strip the checkbox marker and any "(verified ...)" parenthetical for matching
        norm = re.sub(r'\[[VX~! ]\]', '[?]', a).strip()
        norm_pattern = re.escape(norm).replace(r'\[\?\]', r'\[[VX~! ]\]')
        if not re.search(norm_pattern, work_text):
            violations.append(f"{f}:: section '{header.strip()}' lost assertion: {a.strip()[:120]}")

for v in violations:
    print(v)
PY
  out=$(python - "$f" "$head_blob" <<'PY' 2>/dev/null
import sys, re
f = sys.argv[1]
head = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    work = open(f, encoding='utf-8').read()
except Exception:
    sys.exit(0)
def split_sections(text):
    parts = re.split(r'(?m)^(### .+)$', text)
    out = []
    i = 1
    while i < len(parts):
        header = parts[i]
        body = parts[i+1] if i+1 < len(parts) else ""
        out.append((header, body))
        i += 2
    return out
for header, body in split_sections(head):
    if '[V]' not in body: continue
    for a in re.findall(r'(?m)^[ \t]*-[ \t]*\[[VX~! ]\][^\n]*', body):
        norm = re.sub(r'\[[VX~! ]\]', '[?]', a).strip()
        pat = re.escape(norm).replace(r'\[\?\]', r'\[[VX~! ]\]')
        if not re.search(pat, work):
            print(f"{f} :: '{header.strip()}' lost assertion: {a.strip()[:140]}")
PY
)
  if [ -n "$out" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && issues+=("$line")
    done <<< "$out"
  fi
done <<< "$modified"

if [ "${#issues[@]}" -eq 0 ]; then
  echo '{"decision":"approve"}'
  exit 0
fi

reason="DOD-IMMUTABILITY BLOCKED (CLAUDE.md \u00a711.17):"$'\n'
for i in "${issues[@]}"; do reason+="  - $i"$'\n'; done
reason+=""$'\n'"DoD assertions of already-[V] tasks are immutable. To remove/change one:"$'\n'
reason+="  1) Demote [V] -> [!] with a **Reason:** paragraph."$'\n'
reason+="  2) Add decision-record in docs/decisions.md."

python -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.stdin.read().rstrip()}))" >&2 <<< "$reason"
exit 2
