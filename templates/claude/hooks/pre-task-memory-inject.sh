#!/usr/bin/env bash
# Хук перед задачей: положить агенту в контекст то, на чём уже обжигались.
#
# Ставится на PreToolUse (или PreCompact — зависит от места установки). В начале
# итерации или субагента отзывает из памяти анти-паттерны, похожие на описание задачи,
# и печатает их блоком «Известные анти-паттерны». Claude Code собирает stdout Pre*-хука
# как дополнительный контекст.
#
# ЧТО ОТКУДА БЕРЁТСЯ. Хук лежит в проекте (.claude/hooks/), а клиент памяти — в
# установке фабрики: одна база на все проекты, копии клиента по проектам не нужны.
# Абсолютных путей здесь нет ни одного, потому что и проект, и фабрика переезжают:
#
#   корень репозитория — git rev-parse --show-toplevel
#   корень фабрики     — $BCF_HOME, иначе поле bcfHome из <репозиторий>/.bcf/project.json
#                        (карточку пишет bcf init), иначе каталог над .claude/
#   клиент памяти      — $BCF_MEMORY_CLIENT, иначе <фабрика>/memory/pgvector/memory_client.py,
#                        иначе <репозиторий>/memory/pgvector/memory_client.py
#
# Контракт окружения:
#   $BCF_TASK_DESCRIPTION — короткое описание задачи (если не пришло со stdin)
#   $BCF_TASK_ID          — id задачи для общей памяти команды
#   $BCF_AGENT_SCOPE      — 'code' | <имя субагента> | 'all'. По умолчанию 'code'
#   $BCF_ITERATION_ID     — id итерации (для журнала отзывов)
#   $EOG_BIN              — путь к eog, если его нет в PATH
#   BCF_MEMORY_INJECT_DISABLED=1 — выключить хук
#
# Хук СОВЕТУЕТ, а не блокирует: выходит нулём всегда, что бы ни отказало.

set -u
[ "${BCF_MEMORY_INJECT_DISABLED:-0}" = "1" ] && exit 0

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Кодировка вывода python. Без неё он печатает в кодировке консоли (на Windows это
# cp1251), и урок приезжает агенту в контекст нечитаемым — а выглядит это как «память
# работает»: блок на месте, длина правильная, смысла нет.
export PYTHONIOENCODING=utf-8

# python нужен и для разбора stdin, и для чтения карточки проекта. Без него хук молчит.
PY=""
for c in python python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -z "$PY" ] && exit 0

# --- Корень репозитория ---------------------------------------------------------------
# Хук зовут из любого каталога дерева, поэтому «текущий каталог» корнем не является.
start_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
REPO_ROOT=""
if command -v git >/dev/null 2>&1; then
  REPO_ROOT="$(cd "$start_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -z "$REPO_ROOT" ] && REPO_ROOT="${BCF_PROJECT_ROOT:-$(cd "$hook_dir/../.." >/dev/null 2>&1 && pwd)}"

# Значение из JSON-файла без jq: он есть не везде, а python здесь уже обязателен.
json_value() {
  [ -f "$1" ] || return 0
  "$PY" - "$1" "$2" <<'PY' 2>/dev/null | tr -d '\r' || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
for part in sys.argv[2].split('.'):
    if not isinstance(d, dict):
        sys.exit(0)
    d = d.get(part)
    if d is None:
        sys.exit(0)
print(d)
PY
}

# --- Корень фабрики и клиент памяти ----------------------------------------------------
FACTORY="${BCF_HOME:-}"
[ -z "$FACTORY" ] && FACTORY="$(json_value "$REPO_ROOT/.bcf/project.json" bcfHome)"
[ -z "$FACTORY" ] && FACTORY="$(cd "$hook_dir/../.." >/dev/null 2>&1 && pwd)"
FACTORY="${FACTORY%/}"

MEMORY_CLIENT="${BCF_MEMORY_CLIENT:-}"
if [ -z "$MEMORY_CLIENT" ]; then
  for c in "$FACTORY/memory/pgvector/memory_client.py" "$REPO_ROOT/memory/pgvector/memory_client.py"; do
    if [ -f "$c" ]; then MEMORY_CLIENT="$c"; break; fi
  done
fi

# --- Описание задачи и её id ------------------------------------------------------------
# СО ВХОДА ЧИТАЕМ С ПОТОЛКОМ ВРЕМЕНИ, а не «пока не кончится».
#
# Claude Code отдаёт хуку JSON и сразу закрывает вход — cat возвращается мгновенно. Но
# запущенный иначе (из оболочки, из обвязки, из теста) хук получает открытый канал,
# который никто не закроет, и `cat` ждёт вечно. Хук перед задачей висит ПЕРЕД работой:
# снаружи это выглядит как «агент не стартовал», без единой строки в логе.
STDIN_JSON=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    STDIN_JSON="$(timeout 2 cat 2>/dev/null || true)"
  else
    STDIN_JSON="$(cat 2>/dev/null || true)"
  fi
fi

DESC=""
if [ -n "$STDIN_JSON" ]; then
  DESC=$(printf '%s' "$STDIN_JSON" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
for k in ("prompt", "description", "task", "instruction"):
    v = ti.get(k) or d.get(k)
    if v: print(v); break
' 2>/dev/null || true)
fi
[ -z "$DESC" ] && DESC="${BCF_TASK_DESCRIPTION:-}"

SCOPE="${BCF_AGENT_SCOPE:-code}"
ITER="${BCF_ITERATION_ID:-}"

# id задачи: явный, иначе из текущего фокуса, иначе первый похожий на id в описании.
TASK_ID="${BCF_TASK_ID:-}"
task_id_pattern="${BCF_TASK_ID_PATTERN:-[A-Za-z][A-Za-z0-9]*-[0-9]+}"
if [ -z "$TASK_ID" ] && [ -f "$REPO_ROOT/tasks/CURRENT-FOCUS.md" ]; then
  TASK_ID=$(grep -oE "$task_id_pattern" "$REPO_ROOT/tasks/CURRENT-FOCUS.md" 2>/dev/null | head -1 || true)
fi
if [ -z "$TASK_ID" ] && [ -n "$DESC" ]; then
  TASK_ID=$(printf '%s' "$DESC" | grep -oE "$task_id_pattern" | head -1 || true)
fi

# Имя репозитория для общей памяти команды: как назвал владелец в config/harness.json,
# иначе имя каталога. Каталог переименовывают и клонируют под другим именем, поэтому
# явное имя в конфиге сильнее.
REPO_NAME="$(json_value "$REPO_ROOT/config/harness.json" repo)"
[ -z "$REPO_NAME" ] && REPO_NAME="$(basename "$REPO_ROOT")"

# --- 1. Уроки из векторной памяти -------------------------------------------------------
RESULT=""
COUNT=0
if [ -n "$DESC" ] && [ -n "$MEMORY_CLIENT" ] && [ -f "$MEMORY_CLIENT" ]; then
  RESULT=$(BCF_PROJECT_ROOT="${BCF_PROJECT_ROOT:-$REPO_ROOT}" "$PY" "$MEMORY_CLIENT" recall \
              --text "$DESC" --scope "$SCOPE" --k 3 --threshold 0.55 \
              --iteration-id "$ITER" 2>/dev/null || true)
  if [ -n "$RESULT" ]; then
    # python на Windows печатает перевод строки как CRLF, поэтому число приезжает
    # с хвостовым CR: дальше оно попадает и в текст блока, и в сравнения. Срезаем.
    COUNT=$(printf '%s' "$RESULT" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)' 2>/dev/null | tr -d '\r' || echo 0)
  fi
fi
[ -z "$COUNT" ] && COUNT=0

if [ "$COUNT" != "0" ]; then
  printf '### Известные анти-паттерны (память агентов, область %s, совпадений %s)\n' "$SCOPE" "$COUNT"
  printf '%s\n' "Это уже случалось. Не повторять."
  printf '%s' "$RESULT" | "$PY" -c "
import json, sys
for e in json.load(sys.stdin):
    sim = e.get('similarity', 0.0)
    where = e.get('project') or ''
    tag = ('  [проект: %s]' % where) if where else ''
    print('- [сходство %.2f]%s %s' % (sim, tag, e.get('trigger_summary', '')))
    ww = e.get('what_went_wrong')
    if ww: print('    что пошло не так: ' + ww)
    ca = e.get('correct_alternative')
    if ca: print('    как надо: ' + ca)
" | tr -d '\r'
fi

# --- 2. Заметки общей памяти команды ----------------------------------------------------
#
# Контракт eog: печатает текстовый блок или «заметок по теме нет». Ненулевой код
# игнорируется — общая память необязательна, и её отсутствие не повод ронять итерацию.
EOG="${EOG_BIN:-}"
if [ -z "$EOG" ] && command -v eog >/dev/null 2>&1; then EOG="$(command -v eog)"; fi
if [ -n "$EOG" ]; then
  if [ -n "$TASK_ID" ]; then
    EOG_OUT=$("$EOG" memory context --repo "$REPO_NAME" --task "$TASK_ID" 2>/dev/null || true)
  else
    EOG_OUT=$("$EOG" memory context --repo "$REPO_NAME" 2>/dev/null || true)
  fi
  if [ -n "$EOG_OUT" ]; then
    [ "$COUNT" != "0" ] && printf '\n'
    printf '### Заметки общей памяти (%s)\n' "$REPO_NAME"
    printf '%s\n' "$EOG_OUT"
  fi
fi

exit 0
