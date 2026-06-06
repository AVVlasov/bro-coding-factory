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

[ -z "$blocked" ] && exit 0

reason_lines=("AGENT-INFRA-PROTECT BLOCKED — cannot edit ${blocked}.")
reason_lines+=("")
reason_lines+=("File: ${target}")
reason_lines+=("")
reason_lines+=("This is agent-harness refactoring (subagents, hooks, judges, skills, settings,")
reason_lines+=("slash-commands, CLAUDE.md, docs/agentic/) — NOT the coding agent's task in the loop.")
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
