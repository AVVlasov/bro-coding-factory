#!/usr/bin/env bash
# Skill-lint (M-13 C3): отклоняет skill-файлы с prohibition-формулировками.
# Skills описывают навык позитивно; «как НЕ надо» уходит в векторную память.
#
# Запуск:
#   - PostToolUse-hook (Write|Edit): получает Claude Code JSON со stdin.
#   - CLI:  ./skill-lint.sh path/to/SKILL.md [path2 ...]
#
# Exit: 0 — clean | 2 — нарушение.
# Исключение: разделы '## When NOT to use' / '## Когда НЕ применять'.

set -u

# Сбор путей из argv или из stdin JSON.
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

# Всё дальше — в Python (кириллицу и регистр он умеет).
python - "${paths[@]}" <<'PY'
import os, re, sys

# Только SKILL.md и только в скилах.
def is_skill(p: str) -> bool:
    if not p.endswith('SKILL.md'): return False
    n = p.replace('\\', '/').lower()
    return '/skills/' in n or '/skills\\' in n or n.endswith('/skill.md')

paths = [p for p in sys.argv[1:] if is_skill(p) and os.path.isfile(p)]
if not paths:
    sys.exit(0)

# Шаблоны запретов.
patterns = [
    re.compile(r"\b(don'?t|do not|never|avoid|must not|shall not|forbidden|prohibited)\b", re.I),
    re.compile(r"(не\s+делай|не\s+используй|никогда|избегай|запрещ|нельзя|не\s+следует|не\s+разрешено)", re.I | re.U),
]

# Вырезаем разрешённые секции "когда НЕ применять/использовать", "when not to use/apply".
section_excl = re.compile(
    r'(?ims)^##+\s+(?:when\s+not\s+to\s+(?:use|apply)|когда\s+не\s+(?:применять|использовать)).*?(?=^##+\s|\Z)',
    re.U,
)

violations = []
for p in paths:
    src = open(p, encoding='utf-8', errors='replace').read()
    cleaned = section_excl.sub('', src)
    # сохраняем нумерацию строк относительно исходника
    cleaned_lines = cleaned.splitlines()
    orig_lines = src.splitlines()
    # Грубый, но рабочий маппинг: ищем cleaned-строку в исходнике начиная с прошлого индекса.
    cursor = 0
    for line in cleaned_lines:
        # найдём её в исходнике
        for i in range(cursor, len(orig_lines)):
            if orig_lines[i] == line:
                cursor = i + 1
                break
        for rx in patterns:
            if rx.search(line):
                snippet = line.strip()[:140]
                violations.append(f"{p}:{cursor}: {snippet}")
                break

if not violations:
    sys.exit(0)

print("skill-lint: skills должны описывать НАВЫК, а не запреты.", file=sys.stderr)
print("Перенеси формулировки 'как НЕ надо' в векторную память (anti_patterns), переформулируй skill позитивно.", file=sys.stderr)
print("", file=sys.stderr)
for v in violations:
    print(f"  - {v}", file=sys.stderr)
print("", file=sys.stderr)
print("Допустимая секция для границ применимости: '## When NOT to use' / '## Когда НЕ применять'.", file=sys.stderr)
sys.exit(2)
PY
