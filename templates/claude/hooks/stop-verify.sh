#!/usr/bin/env bash
# Runs on session Stop: checks for obvious issues before Claude finishes.
# Returns a systemMessage if issues found (non-blocking — continue=true).

set -euo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-.}"

summary=""

# --- Check for uncommitted console.log in TypeScript ---
if command -v git &>/dev/null; then
  staged_logs=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null | \
    grep -E '\.(ts|tsx)$' | \
    xargs -I{} git -C "$project_dir" show ":${}:" 2>/dev/null | \
    grep -c "console\.log" 2>/dev/null || echo "0")

  unstaged_logs=$(git -C "$project_dir" diff --name-only 2>/dev/null | \
    grep -E '\.(ts|tsx)$' | \
    xargs grep -l "console\.log" 2>/dev/null | wc -l || echo "0")

  total_logs=$((staged_logs + unstaged_logs))
  if [ "$total_logs" -gt 0 ]; then
    summary="${summary}\n- console.log found in modified TypeScript files — remove before committing"
  fi

  # Check for 'any' type in staged/modified TS files
  any_count=$(git -C "$project_dir" diff --name-only 2>/dev/null | \
    grep -E '\.(ts|tsx)$' | \
    xargs grep -lE ':\s*any[\s,\)\]>]|<any>|as any' 2>/dev/null | wc -l || echo "0")
  if [ "$any_count" -gt 0 ]; then
    summary="${summary}\n- 'any' type in modified TypeScript files — replace with specific types"
  fi
fi

# --- Check for stdout printing / swallowed exceptions in modified Java files ---
if command -v git &>/dev/null; then
  # Наличие, а не счёт: под `set -o pipefail` конструкция `... | wc -l || echo 0`
  # печатает ДВА нуля (grep без совпадений роняет весь конвейер, и запасной echo
  # срабатывает поверх честного нуля от wc), после чего сравнение чисел падает
  # с «integer expression expected».
  changed_java=$(git -C "$project_dir" diff --name-only 2>/dev/null | grep -E '\.java$' || true)
  if [ -n "$changed_java" ]; then
    if printf '%s\n' "$changed_java" | xargs grep -lE 'System\.out\.print' 2>/dev/null | grep -q . ; then
      summary="${summary}\n- System.out.print* in modified Java files — use the project logger"
    fi
    if printf '%s\n' "$changed_java" | xargs grep -lE 'printStackTrace\(\)' 2>/dev/null | grep -q . ; then
      summary="${summary}\n- printStackTrace() in modified Java files — log with context or rethrow"
    fi
  fi
fi

# --- Check for print() in modified Python files ---
if command -v git &>/dev/null; then
  print_count=$(git -C "$project_dir" diff --name-only 2>/dev/null | \
    grep -E '\.py$' | \
    xargs grep -lE '^[^#]*print\(' 2>/dev/null | wc -l || echo "0")
  if [ "$print_count" -gt 0 ]; then
    summary="${summary}\n- print() found in modified Python files — use logging module"
  fi
fi

# --- Check for .env files that might have been created ---
env_files=$(find "$project_dir" -maxdepth 2 -name ".env" ! -name ".env.example" 2>/dev/null | grep -v ".git" | wc -l || echo "0")
if [ "$env_files" -gt 0 ]; then
  summary="${summary}\n- .env file detected — ensure it's in .gitignore and never committed"
fi

if [ -n "$summary" ]; then
  echo "{\"continue\": true, \"systemMessage\": \"📋 Before finishing, address these issues:$(echo -e "$summary")\"}"
fi

exit 0
