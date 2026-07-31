#!/usr/bin/env bash
# Strict done-gate — fires on Stop. Blocks the agent from declaring "done"
# when programmatic checks fail on the surfaces touched in THIS session.
#
# Behavior:
#   - Computes the set of files changed in the current session (working copy + untracked).
#   - Runs checks ONLY against those files (no flooding on legacy debt).
#   - On failure: emits JSON {decision:"block", reason:"..."} via python (proper escaping).
#   - On success: exit 0 silently.
#
# Universal checks (always on):
#   0. Verdict gate  — a task claiming a passed final gate needs a fresh PASS verdict file.
#   1. TypeScript    — tsc --noEmit when TS files changed and tsconfig.json exists.
#   2. Python        — py_compile on touched .py files.
#   5. Wrapper       — no NEW API-key env reference introduced outside allowed locations.
#
# Project-specific checks (3, 4, 4b, 4c) read hooks/hooks-config.json and NO-OP when
# their config fields are empty. Fill that file to enable IPC triple-wiring / migration guards.
#
# Escape hatch: BCF_DONE_GATE_DISABLED=1 → skip all checks (see below for the audit-note rule).
#
# This is STRICTER than an advisory stop-verify hook. Both can run on Stop.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
config_file="${BCF_HOOKS_CONFIG:-$script_dir/hooks-config.json}"

# Read a config value via python. $1=jq-style dotted/bracket path handled in python; we keep
# it simple: $1 is a top-level key. Lists are returned newline-joined.
cfg() {
  local key="$1"
  [ -f "$config_file" ] || return 0
  command -v python >/dev/null 2>&1 || return 0
  python - "$config_file" "$key" <<'PY' 2>/dev/null || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
v = cfg.get(sys.argv[2])
if v is None:
    sys.exit(0)
if isinstance(v, list):
    print("\n".join(str(x) for x in v))
else:
    print(v)
PY
}

if [ "${BCF_DONE_GATE_DISABLED:-0}" = "1" ]; then
  # Bypass requires a same-day note in docs/decisions.md (keeps an audit trail).
  today="$(date +%Y-%m-%d)"
  if grep -q "^## ${today}.*BCF_DONE_GATE_DISABLED" docs/decisions.md 2>/dev/null; then
    exit 0
  fi
  reason="BCF_DONE_GATE_DISABLED is set, but no same-day entry in docs/decisions.md. Add: '## ${today} — BCF_DONE_GATE_DISABLED <reason>' before retrying."
  python -c "import sys, json; print(json.dumps({'decision':'block','reason':sys.argv[1]}))" "$reason" >&2 2>/dev/null || printf '%s\n' "$reason" >&2
  exit 2
fi

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$project_dir" 2>/dev/null || exit 0

# Load config once.
ipc_dirs="$(cfg ipc_dirs)"
ipc_preload_file="$(cfg ipc_preload_file)"
ipc_types_file="$(cfg ipc_types_file)"
migration_dir="$(cfg migration_dir)"
migration_index_file="$(cfg migration_index_file)"
migration_version_fn="$(cfg migration_version_fn)"
migration_guard_pattern="$(cfg migration_guard_pattern)"
wrapper_allowed="$(cfg wrapper_allowed)"
wrapper_key_pattern="$(cfg wrapper_key_pattern)"
[ -z "$wrapper_key_pattern" ] && wrapper_key_pattern='(MINIMAX|DEEPSEEK|OPENAI|ANTHROPIC|ZAI|MOONSHOT|BCF)_API_KEY'

# --- 0. VERDICT GATE -----------------------------------------------------------
# A task may be marked done only if an isolated judge produced a fresh PASS verdict.
# For every tasks/<ID>.md whose gate-assertion is checked [V], require a verdict file
# tasks/.verdicts/<ID>.md with `verdict: PASS` and a matching diff_fingerprint.
# Gate-assertion = any "the final gate passed" claim: judge / testers PASS / visual
# contract green / verdict artifact.
# Task-id pattern: a leading prefix-NN id (e.g. STACK-16 from STACK-16-foo.md). Default
# matches the harness taskIdPattern ([A-Za-z][A-Za-z0-9]*-\d+); override via BCF_TASK_ID_PATTERN.
task_id_pattern="${BCF_TASK_ID_PATTERN:-[A-Za-z][A-Za-z0-9]*-[0-9]+}"
verdict_problems=()
if [ -d tasks ]; then
  cur_fp=""
  if command -v git >/dev/null 2>&1; then
    cur_fp=$(git diff HEAD 2>/dev/null | git hash-object --stdin 2>/dev/null || true)
  fi
  for tf in tasks/*.md; do
    [ -f "$tf" ] || continue
    case "$(basename "$tf")" in CURRENT-FOCUS.md|README.md) continue ;; esac
    # task closed? — ANY gate-assertion marked [V]: judge / testers PASS / visual
    # contract green / verdict artifact.
    grep -qiE '^- \[V\].*((judge|verdict artifact)|(tester[s]?.*pass)|((visual|layout|vision).*contract|contract.*(green|pass)|layout-contract.*(green|pass)))' "$tf" 2>/dev/null || continue
    base="$(basename "$tf" .md)"
    tid=$(printf '%s' "$base" | grep -oE "^${task_id_pattern}" | head -1 || true)
    [ -z "$tid" ] && tid="$base"
    [ -z "$tid" ] && continue
    vf="tasks/.verdicts/${tid}.md"
    if [ ! -f "$vf" ]; then
      verdict_problems+=("$tid: gate-assertion = [V] but no verdict file $vf — run the verify step for $tid")
      continue
    fi
    if ! grep -qE '^verdict:[[:space:]]*PASS' "$vf" 2>/dev/null; then
      verdict_problems+=("$tid: $vf exists but verdict != PASS — task not closed")
      continue
    fi
    if [ -n "$cur_fp" ]; then
      vf_fp=$(grep -E '^diff_fingerprint:' "$vf" 2>/dev/null | head -1 | sed -E 's/^diff_fingerprint:[[:space:]]*//' || true)
      if [ -n "$vf_fp" ] && [ "$vf_fp" != "$cur_fp" ]; then
        verdict_problems+=("$tid: verdict is stale — code changed after the verdict (fingerprint mismatch). Re-run verify for $tid")
      fi
    fi
  done
fi
if [ "${#verdict_problems[@]}" -gt 0 ]; then
  vr=("DONE-GATE BLOCKED — evidence-based verdict gate:" "")
  for p in "${verdict_problems[@]}"; do vr+=("- $p"); done
  vr+=("" "A self-applied [V] is not evidence. A verdict file from the verify step is required.")
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' "${vr[@]}" | python -c "
import sys, json
data = sys.stdin.buffer.read().decode('utf-8', 'replace')
sys.stdout.buffer.write(json.dumps({'decision':'block','reason':data.rstrip()}, ensure_ascii=False).encode('utf-8'))
" >&2
  else
    printf '%s\n' "${vr[@]}" >&2
  fi
  exit 2
fi

# --- Discover changed files in this session ---
# Tracked changes (modified vs HEAD) + untracked new files.
changed_files=""
untracked=""
if command -v git >/dev/null 2>&1; then
  tracked=$(git diff --name-only HEAD 2>/dev/null || true)
  staged=$(git diff --cached --name-only 2>/dev/null || true)
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  changed_files=$(printf '%s\n%s\n%s\n' "$tracked" "$staged" "$untracked" | sort -u | grep -v '^$' || true)
fi

# Exit early if nothing changed
if [ -z "$changed_files" ]; then
  exit 0
fi

# Build extension filters from config (ts/py targets).
ts_targets="$(cfg ts_targets)"; [ -z "$ts_targets" ] && ts_targets=$'.ts\n.tsx'
py_targets="$(cfg py_targets)"; [ -z "$py_targets" ] && py_targets=$'.py'
# Regex alternation from a newline list of extensions, e.g. ".ts\n.tsx" -> "\.ts$|\.tsx$"
ext_regex() {
  local out=""
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    e="${e#.}"
    out="${out}${out:+|}\.${e}\$"
  done <<< "$1"
  printf '%s' "$out"
}
ts_re="$(ext_regex "$ts_targets")"
py_re="$(ext_regex "$py_targets")"

# Filter to files that matter (skip generated/vendored + the harness's own agent definitions).
match_re="$ts_re|$py_re"
[ -n "$migration_dir" ] && match_re="$match_re|^$migration_dir/"
relevant=$(echo "$changed_files" | grep -E "$match_re" | grep -vE '^(node_modules|dist[^/]*|target|build|out|\.bcf|\.claude/(skills|agents|hooks|commands)/)' || true)

if [ -z "$relevant" ]; then
  exit 0
fi

# Categorize touched layers
ts_files=$(echo "$relevant" | grep -E "$ts_re" || true)
py_files=$(echo "$relevant" | grep -E "$py_re" || true)

# IPC files: only when ipc_dirs configured. Match any configured dir prefix, plus the
# explicit preload/types files.
ipc_files=""
if [ -n "$ipc_dirs" ]; then
  ipc_re=""
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    ipc_re="${ipc_re}${ipc_re:+|}^${d}/"
  done <<< "$ipc_dirs"
  [ -n "$ipc_preload_file" ] && ipc_re="${ipc_re}${ipc_re:+|}^${ipc_preload_file}\$"
  [ -n "$ipc_types_file" ]   && ipc_re="${ipc_re}${ipc_re:+|}^${ipc_types_file}\$"
  [ -n "$ipc_re" ] && ipc_files=$(echo "$relevant" | grep -E "$ipc_re" || true)
fi

# Migration files: only when migration_dir configured.
migration_files=""
if [ -n "$migration_dir" ]; then
  migration_files=$(echo "$relevant" | grep -E "^${migration_dir}/[0-9]+_.*\.(ts|tsx|sql|py)$" || true)
fi

failures=()

# --- 1. TypeScript: tsc --noEmit (project-wide type-check) ---
if [ -n "$ts_files" ] && [ -f tsconfig.json ] && command -v npx >/dev/null 2>&1; then
  tsc_out=$(timeout 60 npx --no-install tsc --noEmit 2>&1)
  tsc_exit=$?
  if [ "$tsc_exit" != "0" ] && [ "$tsc_exit" != "124" ]; then
    first=$(echo "$tsc_out" | head -8)
    failures+=("tsc --noEmit failed (exit $tsc_exit). First errors:|$first")
  fi
fi

# --- 2. Python: py_compile only on touched .py files ---
if [ -n "$py_files" ] && command -v python >/dev/null 2>&1; then
  for f in $py_files; do
    [ -f "$f" ] || continue
    out=$(python -m py_compile "$f" 2>&1)
    rc=$?
    if [ "$rc" != "0" ]; then
      failures+=("py_compile failed for $f|$out")
    fi
  done
fi

# --- 3. IPC triple-wiring (project-specific; no-op unless ipc_dirs + preload + types set) ---
if [ -n "$ipc_files" ] && [ -n "$ipc_preload_file" ] && [ -n "$ipc_types_file" ]; then
  # Get list of NEW ipcMain.handle calls (added lines vs HEAD)
  new_handlers=""
  for f in $ipc_files; do
    [ -f "$f" ] || continue
    added=$(git diff HEAD -- "$f" 2>/dev/null | grep -E '^\+' | grep -oE "ipcMain\.handle\(['\"][^'\"]+['\"]" | grep -oE "['\"][^'\"]+['\"]$" | tr -d '"' | tr -d "'" || true)
    new_handlers=$(printf '%s\n%s\n' "$new_handlers" "$added")
  done

  # Also include handlers in fully-untracked new files
  for f in $ipc_files; do
    if echo "$untracked" | grep -qx "$f" 2>/dev/null; then
      added=$(grep -oE "ipcMain\.handle\(['\"][^'\"]+['\"]" "$f" 2>/dev/null | grep -oE "['\"][^'\"]+['\"]$" | tr -d '"' | tr -d "'" || true)
      new_handlers=$(printf '%s\n%s\n' "$new_handlers" "$added")
    fi
  done
  new_handlers=$(echo "$new_handlers" | sort -u | grep -v '^$' || true)

  if [ -n "$new_handlers" ]; then
    missing=()
    while IFS= read -r handler; do
      [ -z "$handler" ] && continue
      in_preload=$(grep -c "['\"]${handler}['\"]" "$ipc_preload_file" 2>/dev/null || echo 0)
      in_types=$(grep -c "['\"]${handler}['\"]" "$ipc_types_file" 2>/dev/null || echo 0)
      if [ "$in_preload" = "0" ] || [ "$in_types" = "0" ]; then
        missing+=("$handler [preload:$in_preload types:$in_types]")
      fi
    done <<< "$new_handlers"
    if [ "${#missing[@]}" -gt 0 ]; then
      summary=$(printf '%s; ' "${missing[@]}")
      failures+=("New IPC channels missing wiring (preload OR typed client)|${summary}")
    fi
  fi
fi

# --- 4. Migration registration (project-specific; no-op unless migration_index_file set) ---
if [ -n "$migration_files" ] && [ -n "$migration_index_file" ] && [ -f "$migration_index_file" ]; then
  for mig in $migration_files; do
    base=$(basename "$mig"); base="${base%.*}"
    if echo "$untracked" | grep -qx "$mig" 2>/dev/null; then
      if ! grep -q "$base" "$migration_index_file"; then
        failures+=("New migration $mig not registered in $migration_index_file|will not apply")
      fi
    fi
  done
fi

# --- 4b. Migration ALTER-safety (project-specific; no-op unless migration_guard_pattern set) ---
# Every touched migration with `ALTER TABLE ... ADD COLUMN` must include a guard matching
# migration_guard_pattern (e.g. a column-existence check), or a re-run crashes with
# "duplicate column".
if [ -n "$migration_files" ] && [ -n "$migration_guard_pattern" ]; then
  unsafe_alters=()
  for mig in $migration_files; do
    [ -f "$mig" ] || continue
    if grep -qE 'ALTER TABLE [^[:space:]]+ ADD COLUMN' "$mig"; then
      if ! grep -qE "$migration_guard_pattern" "$mig"; then
        unsafe_alters+=("$mig")
      fi
    fi
  done
  if [ "${#unsafe_alters[@]}" -gt 0 ]; then
    list=$(printf '%s; ' "${unsafe_alters[@]}")
    failures+=("ALTER TABLE ADD COLUMN without a column-existence guard — re-run will crash with 'duplicate column'.|${list}")
  fi
fi

# --- 4c. Migration index must record the schema version per migration (project-specific;
#         no-op unless migration_index_file + migration_version_fn set). ---
if [ -n "$migration_files" ] && [ -n "$migration_index_file" ] && [ -n "$migration_version_fn" ] && [ -f "$migration_index_file" ]; then
  # Accept either: (a) >=2 static call sites, OR (b) a call inside a for/forEach/while loop.
  insert_calls=$(grep -cE "${migration_version_fn}\(" "$migration_index_file" || echo 0)
  in_loop=$(MIG_IDX="$migration_index_file" MIG_FN="$migration_version_fn" python -c "
import os, re
src = open(os.environ['MIG_IDX'], encoding='utf-8').read()
fn = re.escape(os.environ['MIG_FN'])
patterns = [r'for\s*\([^)]+\)\s*\{[^}]*'+fn+r'\s*\(', r'\.forEach\s*\([^)]*=>\s*\{[^}]*'+fn+r'\s*\(', r'while\s*\([^)]+\)\s*\{[^}]*'+fn+r'\s*\(']
for p in patterns:
    if re.search(p, src, re.S):
        print('1'); break
else:
    print('0')
" 2>/dev/null || echo 0)
  if [ "$insert_calls" -lt 2 ] && [ "$in_loop" != "1" ]; then
    failures+=("$migration_index_file must call ${migration_version_fn} per migration. Found $insert_calls call(s), no for/forEach/while loop containing it.|Re-run on a populated DB will replay every ALTER and crash.")
  fi
fi

# --- 5. Wrapper-principle: API-key reference INTRODUCED in this session ---
# (legacy violations are not blocked — those are pre-existing debt the user knows about)
if [ -n "$ts_files" ] || [ -n "$py_files" ]; then
  introduced_keys=""
  for f in $relevant; do
    [ -f "$f" ] || continue
    # Look at ADDED lines only (+, not -)
    added=$(git diff HEAD -- "$f" 2>/dev/null | grep -E '^\+' | grep -E "$wrapper_key_pattern" || true)
    if [ -n "$added" ]; then
      # Allowed in configured wrapper_allowed prefixes/files.
      is_allowed=0
      while IFS= read -r a; do
        [ -z "$a" ] && continue
        case "$a" in
          */) case "$f" in $a*) is_allowed=1 ;; esac ;;
          *)  case "$f" in $a|*/$a) is_allowed=1 ;; esac ;;
        esac
      done <<< "$wrapper_allowed"
      if [ "$is_allowed" = "0" ]; then
        introduced_keys="$introduced_keys|$f: $(echo "$added" | head -1)"
      fi
    fi
  done
  if [ -n "$introduced_keys" ]; then
    failures+=("API-key reference newly INTRODUCED outside allowed locations (keep keys in env/.env)${introduced_keys}")
  fi
fi

# --- Verdict ---
if [ "${#failures[@]}" -eq 0 ]; then
  exit 0
fi

# Build human-readable reason and emit JSON via python (proper escaping)
reason_lines=("DONE-GATE BLOCKED. Programmatic checks failed on YOUR session changes:")
reason_lines+=("")
for f in "${failures[@]}"; do
  # f format: "title|detail" — split
  title="${f%%|*}"
  detail="${f#*|}"
  reason_lines+=("- $title")
  if [ -n "$detail" ] && [ "$detail" != "$title" ]; then
    # Indent detail lines
    while IFS= read -r dl; do
      [ -z "$dl" ] && continue
      reason_lines+=("    $dl")
    done <<< "$(echo "$detail" | head -6)"
  fi
done
reason_lines+=("")
reason_lines+=("How to proceed:")
reason_lines+=("  1. Fix the issues above; let Stop fire again.")
reason_lines+=("  2. Or run the verify step for the task to get the full picture from the auditor + judge.")
reason_lines+=("  3. Emergency only: BCF_DONE_GATE_DISABLED=1 (record reason in docs/decisions.md).")

# Emit JSON via python (handles escaping)
if command -v python >/dev/null 2>&1; then
  printf '%s\n' "${reason_lines[@]}" | python -c "
import sys, json
reason = sys.stdin.read().rstrip()
print(json.dumps({'decision': 'block', 'reason': reason}))
" >&2
elif command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "${reason_lines[@]}" | python3 -c "
import sys, json
reason = sys.stdin.read().rstrip()
print(json.dumps({'decision': 'block', 'reason': reason}))
" >&2
else
  # Fallback: plain text, no JSON (the harness can still read stderr on exit 2)
  printf '%s\n' "${reason_lines[@]}" >&2
fi

exit 2
