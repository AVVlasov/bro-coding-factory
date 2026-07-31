#!/usr/bin/env bash
# Runs fast validation after writing TypeScript or Python files.
# Receives JSON via stdin: {"tool_name":"Write|Edit","tool_input":{"file_path":"..."},"tool_result":...}

set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

if [ -z "$file_path" ]; then
  exit 0
fi

normalized=$(echo "$file_path" | sed 's|\\|/|g')
ext="${file_path##*.}"

# Один архитектурный запрет вынесен в конфиг: «какой слой не имеет права импортировать
# что» — свойство проекта, а не хука. Хардкод здесь означал бы, что гейт молча ничего
# не проверяет во всех проектах, кроме одного.
hooks_cfg() {
  for cand in .claude/hooks/hooks-config.json hooks-config.json; do
    [ -f "$cand" ] || continue
    python -c "import json,sys; print(json.load(open('$cand',encoding='utf-8')).get('$1','') or '')" 2>/dev/null && return
  done
  echo ""
}

# --- TypeScript / TSX: check for forbidden patterns ---
if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
  violations=""

  # Check for console.log
  if grep -qn "console\.log" "$file_path" 2>/dev/null; then
    violations="${violations}\n- console.log found — remove before commit (use structured logger)"
  fi

  # Check for 'any' type annotations
  if grep -qnE ':\s*any[\s,\)\]>]|<any>|as any' "$file_path" 2>/dev/null; then
    violations="${violations}\n- 'any' type found — use 'unknown' or specific types"
  fi

  # Forbidden cross-layer import (renderer_dir / renderer_forbidden_import in hooks-config.json)
  rdir=$(hooks_cfg renderer_dir)
  rimp=$(hooks_cfg renderer_forbidden_import)
  if [ -n "$rdir" ] && [ -n "$rimp" ] \
     && echo "$normalized" | grep -q "/${rdir%/}/" \
     && grep -qnE "$rimp" "$file_path" 2>/dev/null; then
    violations="${violations}\n- forbidden import in ${rdir} (matches ${rimp}) — go through the declared boundary instead"
  fi

  # Check for string interpolation in SQL
  if grep -qnE '`\s*(SELECT|INSERT|UPDATE|DELETE).*\$\{' "$file_path" 2>/dev/null; then
    violations="${violations}\n- SQL string interpolation detected — use parametrized queries only"
  fi

  if [ -n "$violations" ]; then
    echo "{\"continue\": true, \"systemMessage\": \"⚠️ Code quality issues in $(basename $file_path):$(echo -e "$violations")\"}"
  fi
fi

# --- Python: check for forbidden patterns ---
if [[ "$ext" == "py" ]]; then
  violations=""

  # Check for print() statements
  if grep -qnE '^[^#]*print\(' "$file_path" 2>/dev/null; then
    violations="${violations}\n- print() found — use logging module instead"
  fi

  # Check for f-string SQL
  if grep -qnE 'f"(SELECT|INSERT|UPDATE|DELETE)|f'"'"'(SELECT|INSERT|UPDATE|DELETE)' "$file_path" 2>/dev/null; then
    violations="${violations}\n- f-string SQL detected — SECURITY RISK: use parametrized queries"
  fi

  # Check for bare Any type
  if grep -qnE ':\s*Any\b' "$file_path" 2>/dev/null; then
    violations="${violations}\n- Bare 'Any' type found — use specific types from typing module"
  fi

  # Compile check
  if command -v python3 &>/dev/null; then
    if ! python3 -m py_compile "$file_path" 2>/tmp/py_compile_err; then
      err=$(cat /tmp/py_compile_err)
      echo "{\"continue\": true, \"systemMessage\": \"🚨 Python syntax error in $(basename $file_path): $err\"}"
      exit 0
    fi
  fi

  if [ -n "$violations" ]; then
    echo "{\"continue\": true, \"systemMessage\": \"⚠️ Code quality issues in $(basename $file_path):$(echo -e "$violations")\"}"
  fi
fi

exit 0
