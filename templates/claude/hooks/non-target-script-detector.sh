#!/usr/bin/env bash
# Гейт против артефактов декодирования модели в UI-копи: ловит CJK иероглифы,
# хирагану, катакану, хангыль внутри строк продуктового кода (каталоги — из
# .claude/hooks/hooks-config.json → product_paths).
#
# Кейс 2026-05-27: TodayPage.tsx содержал «с昨晚» (с + 昨晚, "yesterday evening" на
# китайском) в середине русского предложения «Вот что изменилось с[昨晚]. Начнём…».
# vision-судья прошёл (визуально это всё ещё похоже на текст), product-critic
# не запускался, никто не grep'нул src на не-целевой алфавит.
#
# Запуск:
#   - PostToolUse-hook (Write|Edit): получает Claude Code JSON со stdin, фильтрует
#     по расширению, проверяет contents.
#   - CLI: ./non-target-script-detector.sh path/to/file [path2 ...]
#
# Допустимые исключения (правится по env):
#   $NONTARGET_ALLOW_PATHS — глобы через `:`, например
#     "docs/**:*.test.ts:scripts/**" — пропускаются.
#   $NONTARGET_DISABLED=1 — полностью отключить.
#
# Exit: 0 — clean | 2 — нарушение.

set -u
[ "${NONTARGET_DISABLED:-0}" = "1" ] && exit 0

# Сбор путей.
paths=()
if [ "$#" -gt 0 ]; then
    paths=("$@")
elif [ ! -t 0 ]; then
    payload="$(cat || true)"
    if command -v python >/dev/null 2>&1 && [ -n "$payload" ]; then
        fp=$(printf '%s' "$payload" | python -c '
import json, sys
try: d = json.load(sys.stdin)
except: sys.exit(0)
ti = d.get("tool_input") or {}
fp = ti.get("file_path") or d.get("file_path")
if fp: print(fp)
' 2>/dev/null)
        [ -n "$fp" ] && paths+=("$fp")
    fi
fi
[ "${#paths[@]}" -eq 0 ] && exit 0

# Сканируем в Python — кириллицу/CJK он умеет без шаманства с locale.
python - "${paths[@]}" <<'PY'
import fnmatch, os, re, sys

# Только эти расширения — продуктовый код, где UI-копи живут.
SCAN_EXT = {'.ts', '.tsx', '.js', '.jsx', '.css', '.scss', '.vue', '.svelte', '.html'}
# Только эти каталоги — продуктовая зона. docs/, scripts/, tests/, .claude/ — пропуск.
# Список задаётся проектом: hooks-config.json → product_paths. Дефолт узкий намеренно —
# гейт, который сканирует весь репозиторий, ловит чужие данные и его выключают целиком.
def _product_paths():
    import json, os
    for cand in ('.claude/hooks/hooks-config.json', 'hooks-config.json'):
        try:
            with open(cand, encoding='utf-8') as fh:
                cfg = json.load(fh)
            pp = cfg.get('product_paths') or []
            if pp:
                return tuple((p.rstrip('/') + '/') for p in pp)
        except Exception:
            continue
    return ('src/',)

SCAN_DIRS = _product_paths()

# Запрещённые скрипты в этих файлах:
# - CJK Unified Ideographs (U+4E00 – U+9FFF)
# - CJK Ext A (U+3400 – U+4DBF)
# - Hiragana (U+3040 – U+309F)
# - Katakana (U+30A0 – U+30FF)
# - Hangul (U+AC00 – U+D7AF)
RX = re.compile('[一-鿿㐀-䶿぀-ヿ가-힯]')

allow_globs = [g for g in (os.environ.get('NONTARGET_ALLOW_PATHS') or '').split(':') if g]

def in_scan_zone(p: str) -> bool:
    n = p.replace('\\', '/').lower()
    if any(fnmatch.fnmatch(n, g.lower()) for g in allow_globs): return False
    if os.path.splitext(n)[1] not in SCAN_EXT: return False
    # Должен попадать в одну из SCAN_DIRS (по подстроке — учитывает абсолютные пути).
    return any(d in n for d in SCAN_DIRS)

violations = []
for p in sys.argv[1:]:
    if not os.path.isfile(p) or not in_scan_zone(p):
        continue
    try:
        with open(p, encoding='utf-8') as f:
            lines = f.read().splitlines()
    except (UnicodeDecodeError, OSError):
        continue
    for i, ln in enumerate(lines, start=1):
        m = RX.search(ln)
        if m:
            # Контекст ±15 символов вокруг матча для понятности.
            start = max(0, m.start() - 15)
            end = min(len(ln), m.end() + 15)
            ctx = ln[start:end].strip()
            violations.append(f"{p}:{i}:col{m.start()+1}: {ctx!r}")

if not violations:
    sys.exit(0)

print("non-target-script-detector: в продуктовом коде найдены CJK/хирагана/катакана/хангыль.", file=sys.stderr)
print("Это почти всегда — артефакт декодирования модели (см. 2026-05-27 TodayPage.tsx 'с昨晚').", file=sys.stderr)
print("Замени на корректный текст на целевом языке UI (рус/англ).", file=sys.stderr)
print("", file=sys.stderr)
for v in violations:
    print(f"  - {v}", file=sys.stderr)
print("", file=sys.stderr)
print("Отключение (для документации/тестов, где CJK действительно нужен):", file=sys.stderr)
print("  - NONTARGET_ALLOW_PATHS='glob1:glob2'  (per-call)", file=sys.stderr)
print("  - NONTARGET_DISABLED=1                  (выключить полностью)", file=sys.stderr)
sys.exit(2)
PY
