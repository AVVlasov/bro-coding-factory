#!/usr/bin/env bash
# Runs on session Stop: checks for obvious issues before Claude finishes.
# Returns a systemMessage if issues found (non-blocking — continue=true).

set -euo pipefail

project_dir="${CLAUDE_PROJECT_DIR:-.}"

# git отдаёт пути относительно корня репозитория, а grep ищет от текущего каталога.
# Пока хук стоял в произвольном каталоге, каждый grep получал несуществующий путь и
# молчал: замечаний не было не потому, что код чист, а потому, что читать было нечего.
cd "$project_dir" 2>/dev/null || true

summary=""

# --- Check for uncommitted console.log in TypeScript ---
# Наличие, а не счёт. Под `set -o pipefail` конструкция `... | wc -l || echo "0"`
# печатает ДВА нуля: grep без совпадений роняет весь конвейер, и запасной echo ложится
# поверх честного нуля от wc. Дальше `$((a + b))` и `[ "$x" -gt 0 ]` падают с
# «integer expression expected», и вместо замечаний пользователь видит ошибки bash.
if command -v git &>/dev/null; then
  changed_ts=$(git -C "$project_dir" diff --name-only 2>/dev/null | grep -E '\.(ts|tsx)$' || true)
  staged_ts=$(git -C "$project_dir" diff --cached --name-only 2>/dev/null | grep -E '\.(ts|tsx)$' || true)

  ts_logs=0
  if [ -n "$changed_ts" ] && printf '%s\n' "$changed_ts" | xargs grep -l "console\.log" 2>/dev/null | grep -q . ; then
    ts_logs=1
  fi
  # Проиндексированное читается из индекса: рабочая копия могла уйти вперёд.
  if [ "$ts_logs" = "0" ] && [ -n "$staged_ts" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if git -C "$project_dir" show ":$f" 2>/dev/null | grep -q "console\.log"; then ts_logs=1; break; fi
    done <<< "$staged_ts"
  fi
  if [ "$ts_logs" = "1" ]; then
    summary="${summary}\n- console.log found in modified TypeScript files — remove before committing"
  fi

  # Check for 'any' type in modified TS files
  if [ -n "$changed_ts" ] && printf '%s\n' "$changed_ts" | xargs grep -lE ':\s*any[\s,\)\]>]|<any>|as any' 2>/dev/null | grep -q . ; then
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
  changed_py=$(git -C "$project_dir" diff --name-only 2>/dev/null | grep -E '\.py$' || true)
  if [ -n "$changed_py" ] && printf '%s\n' "$changed_py" | xargs grep -lE '^[^#]*print\(' 2>/dev/null | grep -q . ; then
    summary="${summary}\n- print() found in modified Python files — use logging module"
  fi
fi

# --- Check for .env files that might have been created ---
if find "$project_dir" -maxdepth 2 -name ".env" ! -name ".env.example" 2>/dev/null | grep -v "\.git" | grep -q . ; then
  summary="${summary}\n- .env file detected — ensure it's in .gitignore and never committed"
fi

if [ -n "$summary" ]; then
  echo "{\"continue\": true, \"systemMessage\": \"📋 Before finishing, address these issues:$(echo -e "$summary")\"}"
fi

exit 0
