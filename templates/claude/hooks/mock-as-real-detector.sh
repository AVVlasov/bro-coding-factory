#!/usr/bin/env bash
# PostToolUse-hook (Write|Edit): BLOCK when production code (каталоги — hooks-config.json
# product_paths) imports from mock/fixture/seed/stub/demo/sample modules, а в Java —
# тянет org.mockito или конструирует *Stub / *Fake / *Mock вне тестового дерева.
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

# Продуктовые каталоги и расширения берутся из hooks-config.json (product_paths,
# mock_scan_ext), а не из кода: захардкоженные src/pages и *.ts означали, что в проекте
# с другой раскладкой — Java, Go, любой не-React — хук не срабатывал ни разу, и запрет
# «моки в продуктовом коде» существовал только на бумаге.
cfg_get() {
  for cand in "$ROOT/.claude/hooks/hooks-config.json" "$ROOT/hooks-config.json"; do
    [ -f "$cand" ] || continue
    command -v python >/dev/null 2>&1 || return 0
    CFG_FILE="$cand" CFG_KEY="$1" python -c "
import json, os
try:
    cfg = json.load(open(os.environ['CFG_FILE'], encoding='utf-8'))
except Exception:
    raise SystemExit(0)
v = cfg.get(os.environ['CFG_KEY']) or []
print('\n'.join(str(x) for x in v))
" 2>/dev/null && return
  done
  echo ""
}

prod_paths=()
while IFS= read -r d; do
  [ -z "$d" ] && continue
  prod_paths+=("$ROOT/${d%/}")
done <<< "$(cfg_get product_paths)"
[ "${#prod_paths[@]}" -eq 0 ] && prod_paths=("$ROOT/src")

includes=()
while IFS= read -r e; do
  [ -z "$e" ] && continue
  includes+=("--include=*.${e#.}")
done <<< "$(cfg_get mock_scan_ext)"
[ "${#includes[@]}" -eq 0 ] && includes=("--include=*.ts" "--include=*.tsx" "--include=*.java")

# Первая половина — импорт мок-модуля (JS/TS), вторая — Java: пакет org.mockito и типы
# вида FooStub / FakeBar / MockBaz вне тестового дерева.
patterns='from\s+["'"'"'][^"'"'"']*(mock|fixture|seed|stub|demo-data|sample-data|placeholder-data|pages/day/)[^"'"'"']*["'"'"']|require\(["'"'"'][^"'"'"']*(mock|fixture|seed|stub)[^"'"'"']*["'"'"']\)|import\s+(static\s+)?org\.mockito|\bnew\s+[A-Z][A-Za-z0-9]*(Stub|Fake|Mock)\s*\(|\bnew\s+(Fake|Dummy|Mock)[A-Z][A-Za-z0-9]*\s*\('

hits=()
for p in "${prod_paths[@]}"; do
  [ -d "$p" ] || continue
  while IFS=: read -r file line content; do
    [ -z "$file" ] && continue
    case "$file" in
      */src/test/*|*/test/*|*/tests/*) continue ;;
    esac
    case "$content" in
      *"e2e"*|*"test"*|*"spec"*|*"vitest"*|*"playwright"*) continue ;;
    esac
    hits+=("$file:$line: $(echo "$content" | tr -d '\r' | head -c 160)")
  done < <(grep -rnE "$patterns" "$p" "${includes[@]}" 2>/dev/null || true)
done

[ "${#hits[@]}" -eq 0 ] && exit 0

msg="❌ ЗАПРЕЩЕНО (mock-as-real): продакшн-код импортит mock/fixture/seed/stub/demo (CLAUDE.md §11.1):"
for h in "${hits[@]}"; do msg+=$'\n  - '"$h"; done
msg+=$'\nFix: заменить на реальные данные (IPC / TanStack Query), либо перенести файл в tests/.'
msg+=$'\nFake-интеграции и моки в приложении запрещены (Andrey 2026-05-30).'

# BLOCKING: exit 2 → feedback в агента (PostToolUse).
printf '%s\n' "$msg" >&2
exit 2
