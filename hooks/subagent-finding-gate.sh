#!/usr/bin/env bash
# Stop hook: blocks closing an iteration when it has subagent findings with
# must_address=true that have neither a code fix (matched by verification keywords in the
# diff) nor a verifiable dismissal (issue_id + verification_condition in dismissals.json).
#
# Iteration-artifact contract:
#   $BCF_ITERATION_DIR/findings.json   — JSON array [{agent, finding_id, must_address, severity, summary, verification}, ...]
#   $BCF_ITERATION_DIR/diff.patch      — unified diff (optional but recommended)
#   $BCF_ITERATION_DIR/dismissals.json — JSON array [{finding_id, issue_id, verification_condition, rationale}]
#
# No-op if $BCF_ITERATION_DIR is unset or the directory is missing.
# Disable in context — BCF_FINDING_GATE_DISABLED=1.
#
# Exit: 0 — ok, 2 — block (Claude Code Stop hook blocking).

set -u
[ "${BCF_FINDING_GATE_DISABLED:-0}" = "1" ] && exit 0
[ -z "${BCF_ITERATION_DIR:-}" ] && exit 0
[ -d "$BCF_ITERATION_DIR" ] || exit 0

FINDINGS="$BCF_ITERATION_DIR/findings.json"
DIFF="$BCF_ITERATION_DIR/diff.patch"
DISMISS="$BCF_ITERATION_DIR/dismissals.json"
[ -f "$FINDINGS" ] || exit 0

if ! command -v python >/dev/null 2>&1; then
  echo "subagent-finding-gate: python not on PATH; refusing to gate blindly." >&2
  exit 2
fi

OUT=$(BCF_FG_FINDINGS="$FINDINGS" \
      BCF_FG_DIFF="$DIFF" \
      BCF_FG_DISMISS="$DISMISS" \
      python - <<'PY'
import json, os, re, sys

NOISE = {"must","should","the","that","with","from","when","none","true","false","this","there","than","into","does","is","be","a"}

def load(p):
    if not p or not os.path.isfile(p): return None
    with open(p, 'r', encoding='utf-8') as f: return json.load(f)

findings  = load(os.environ.get('BCF_FG_FINDINGS')) or []
diff_path = os.environ.get('BCF_FG_DIFF') or ''
diff_text = ''
if diff_path and os.path.isfile(diff_path):
    with open(diff_path, 'r', encoding='utf-8', errors='replace') as f:
        diff_text = f.read().lower()
dismissals = load(os.environ.get('BCF_FG_DISMISS')) or []

# index by finding_id for fast dismiss-lookup
dmap = {d.get('finding_id'): d for d in dismissals if isinstance(d, dict)}

unaddressed = []
for f in findings:
    if not isinstance(f, dict) or not f.get('must_address'): continue
    fid = f.get('finding_id') or '<no-id>'
    summary = (f.get('summary') or '').strip()
    vrf = (f.get('verification') or '').strip()

    # 1) verifiable dismiss
    d = dmap.get(fid)
    if d and (d.get('issue_id') or '').strip() and (d.get('verification_condition') or '').strip():
        continue

    # 2) keywords from verification appear in the diff
    tokens = [t for t in re.split(r'[^A-Za-z0-9_./-]+', vrf)
              if len(t) >= 4 and t.lower() not in NOISE]
    # unique, up to 8
    seen = []
    for t in tokens:
        if t.lower() not in (s.lower() for s in seen):
            seen.append(t)
        if len(seen) >= 8: break

    if diff_text and any(t.lower() in diff_text for t in seen):
        continue

    unaddressed.append(f"{fid} :: {summary}")

if not unaddressed:
    sys.exit(0)

print("subagent-finding-gate: BLOCK — must_address findings with no fix and no verifiable dismiss:", file=sys.stderr)
for u in unaddressed:
    print(f"  - {u}", file=sys.stderr)
print("", file=sys.stderr)
print("To close the iteration: either make changes that cover the verification,", file=sys.stderr)
print(f"or add an entry to {os.environ.get('BCF_FG_DISMISS')} with issue_id and verification_condition.", file=sys.stderr)
sys.exit(2)
PY
)
rc=$?
[ -n "$OUT" ] && echo "$OUT"
exit $rc
