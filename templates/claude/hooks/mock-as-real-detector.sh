#!/usr/bin/env bash
# PostToolUse-hook (Write|Edit): BLOCK when production code in src/pages/ or src/components/
# imports from mock/fixture/seed/stub/demo/sample modules.
# Это дефект «mocks-as-reality»: экран выглядит рабочим, потому что данные ему подложили.
#
# ПОЛИТИКА: fake-интеграции и моки ЗАПРЕЩЕНЫ в продуктовом коде — только настоящие
# интеграции с настоящими источниками. Хук БЛОКИРУЮЩИЙ (exit 2).
# Примечание: захардкоженные плейсхолдеры БЕЗ импорта этот детектор не ловит — они
# закрываются контрактными тестами и визуальной приёмкой, а не импорт-анализом.
#
# Disable with BCF_MOCK_DETECTOR_DISABLED=1.

set -u
[ "${BCF_MOCK_DETECTOR_DISABLED:-0}" = "1" ] && exit 0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

prod_paths=("$ROOT/src/pages" "$ROOT/src/components" "$ROOT/src/hooks")
patterns='from\s+["'"'"'][^"'"'"']*(mock|fixture|seed|stub|demo-data|sample-data|placeholder-data|pages/day/)[^"'"'"']*["'"'"']|require\(["'"'"'][^"'"'"']*(mock|fixture|seed|stub)[^"'"'"']*["'"'"']\)'

hits=()
for p in "${prod_paths[@]}"; do
  [ -d "$p" ] || continue
  while IFS=: read -r file line content; do
    [ -z "$file" ] && continue
    case "$content" in
      *"e2e"*|*"test"*|*"spec"*|*"vitest"*|*"playwright"*) continue ;;
    esac
    hits+=("$file:$line: $(echo "$content" | tr -d '\r' | head -c 160)")
  done < <(grep -rnE "$patterns" "$p" --include='*.ts' --include='*.tsx' 2>/dev/null || true)
done

[ "${#hits[@]}" -eq 0 ] && exit 0

msg="❌ ЗАПРЕЩЕНО (mock-as-real): продакшн-код импортит mock/fixture/seed/stub/demo (CLAUDE.md §11.1):"
for h in "${hits[@]}"; do msg+=$'\n  - '"$h"; done
msg+=$'\nFix: заменить на реальные данные (IPC / TanStack Query), либо перенести файл в tests/.'
msg+=$'\nFake-интеграции и моки в приложении запрещены (Andrey 2026-05-30).'

# BLOCKING: exit 2 → feedback в агента (PostToolUse).
printf '%s\n' "$msg" >&2
exit 2
