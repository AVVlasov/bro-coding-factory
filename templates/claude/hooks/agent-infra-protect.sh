#!/usr/bin/env bash
# agent-infra-protect — PreToolUse (Write|Edit).
# Blocks the coding agent from modifying its own agent harness:
# subagent definitions, hooks, slash-commands, skills, settings, and judge/critic
# scripts. These artifacts are harness refactoring, not the coding agent's task in the
# loop. If a change is genuinely needed, open a separate meta-task.
#
# Escape: BCF_AGENT_INFRA_PROTECT_DISABLED=1 + a same-day docs/decisions.md note.

set -uo pipefail

if [ "${BCF_AGENT_INFRA_PROTECT_DISABLED:-0}" = "1" ]; then
  today="$(date +%Y-%m-%d 2>/dev/null || echo x)"
  if grep -q "^## ${today}.*BCF_AGENT_INFRA_PROTECT_DISABLED" docs/decisions.md 2>/dev/null; then
    exit 0
  fi
fi

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$project_dir" 2>/dev/null || exit 0

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0
command -v python >/dev/null 2>&1 || exit 0

target=$(printf '%s' "$input" | python -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); sys.exit(0)
print((d.get('tool_input',{}) or {}).get('file_path','') or '')
" 2>/dev/null || true)

[ -z "$target" ] && exit 0

# Normalise backslashes to forward slashes for matching
norm=$(printf '%s' "$target" | tr '\\' '/')

# Path relative to the project root. Needed for config/ and tasks/: a `*/config/*`
# pattern would also hit src/config/, app/config/ and every other config directory a
# product legitimately has, and the agent would be blocked from its own work.
projnorm=$(printf '%s' "$project_dir" | tr '\\' '/')
projnorm="${projnorm%/}"
rel="$norm"
case "$norm" in
  "$projnorm"/*) rel="${norm#"$projnorm"/}" ;;
  ./*)           rel="${norm#./}" ;;
esac
# The two paths can be spelled differently (POSIX vs drive-letter form) even though they
# point at the same tree. A prefix that does not match would leave rel absolute and the
# guard silently open, so fall back to anchoring on the project directory's own name.
if [ "$rel" = "$norm" ] && [ -n "$projnorm" ]; then
  base="${projnorm##*/}"
  case "$norm" in
    */"$base"/*) rel="${norm##*/"$base"/}" ;;
  esac
fi

blocked=""
case "$norm" in
  */.claude/agents/*|*/.claude/agents)        blocked="subagent (.claude/agents/)" ;;
  */.claude/hooks/*|*/.claude/hooks)          blocked="hook (.claude/hooks/)" ;;
  */.claude/commands/*|*/.claude/commands)    blocked="slash-command (.claude/commands/)" ;;
  */.claude/skills/*|*/.claude/skills)        blocked="skill (.claude/skills/)" ;;
  */.claude/settings.json|*/.claude/settings.local.json) blocked="settings.json" ;;
esac

# Generic judge/critic/verdict scripts in scripts/
if [ -z "$blocked" ]; then
  case "$norm" in
    */scripts/*judge*|*/scripts/*critic*|*/scripts/*verdict*)
      blocked="judge/critic script ($norm)"
      ;;
  esac
fi

# CLAUDE.md and docs/agentic/** — agent protocol, also off-limits to the coding agent
if [ -z "$blocked" ]; then
  case "$norm" in
    */CLAUDE.md)                blocked="CLAUDE.md (agent protocol)" ;;
    */docs/agentic/*)           blocked="docs/agentic/ (agent protocol)" ;;
  esac
fi

# config/** — the gates themselves.
#
# config/checks.json is the authority behind the verdict: an agent that trims it down to
# a trivially green list passes its own gate. docs/WORKFLOW.md already promises "the
# owner sets them and the agent cannot narrow them" — until now that promise lived in
# prose only, and nothing enforced it. Matched on the project-root-relative path, so a
# product's own src/config/ stays writable.
if [ -z "$blocked" ]; then
  case "$rel" in
    config/*) blocked="config/ (gates, journeys, scope-map — the owner sets these)" ;;
  esac
fi

# tasks/ — only the parts the harness owns, not the whole directory.
#
# The loop's own contract (harness/PROMPT.md) has the agent tick DoD checkboxes in
# tasks/<ID>-*.md, so blocking tasks/ wholesale would break the loop it is meant to
# protect. What is blocked is what DECIDES the verdict and what the harness writes:
#   .verdicts/  — the verdict file (verify.ps1 writes it after the agent, PROMPT.md:1071)
#   .claims/    — who took which task, on which branch, since when. It travels in git so
#                 the rest of the team sees it; an agent editing it would be handing
#                 itself a task somebody else is already working on
#   .acceptance/, .inbox/, .bugs/ — acceptance signatures, critic drafts, bug ledger
#   CURRENT-FOCUS.md — which task is active (loop.ps1 sets it; PROMPT.md:132 forbids the
#                      agent from moving it, and prose is not a guard)
# The bodies of task files stay editable and are guarded by dod-immutability-check.sh.
if [ -z "$blocked" ]; then
  case "$rel" in
    tasks/.verdicts/*)   blocked="tasks/.verdicts/ (the verdict — written by the harness)" ;;
    tasks/.claims/*)     blocked="tasks/.claims/ (who took which task — written by the harness)" ;;
    tasks/.acceptance/*) blocked="tasks/.acceptance/ (human acceptance signatures)" ;;
    tasks/.inbox/*)      blocked="tasks/.inbox/ (critic findings)" ;;
    tasks/.bugs/*)       blocked="tasks/.bugs/ (bug ledger)" ;;
    tasks/CURRENT-FOCUS.md) blocked="tasks/CURRENT-FOCUS.md (the loop sets the focus)" ;;
  esac
fi

[ -z "$blocked" ] && exit 0

reason_lines=("AGENT-INFRA-PROTECT BLOCKED — cannot edit ${blocked}.")
reason_lines+=("")
reason_lines+=("File: ${target}")
reason_lines+=("")
reason_lines+=("This is agent-harness territory (subagents, hooks, judges, skills, settings,")
reason_lines+=("slash-commands, CLAUDE.md, docs/agentic/, config/, the harness-owned parts of")
reason_lines+=("tasks/) — NOT the coding agent's task in the loop. config/ holds the gates your")
reason_lines+=("work is judged by, and tasks/.verdicts/ holds the verdict itself: editing either")
reason_lines+=("means grading your own paper.")
reason_lines+=("If the change is truly needed:")
reason_lines+=("  1. Stop the loop.")
reason_lines+=("  2. Describe the problem — let the harness owner open a meta-task.")
reason_lines+=("  3. Do not swap the harness mid-run just to pass the current judge.")

printf '%s\n' "${reason_lines[@]}" | python -c "
import sys, json
data = sys.stdin.buffer.read().decode('utf-8', 'replace')
sys.stdout.buffer.write(json.dumps({'decision':'block','reason':data.rstrip()}, ensure_ascii=False).encode('utf-8'))
" >&2
exit 2
