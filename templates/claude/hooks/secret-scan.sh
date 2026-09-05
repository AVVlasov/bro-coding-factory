#!/usr/bin/env bash
# secret-scan.sh — перед git commit сканирует staged-дифф на признаки секретов и блокирует
# коммит, если что-то похоже на ключ доступа или приватный ключ.
#
# Ставится на PreToolUse Bash (тот же matcher, что pre-bash-guard.sh): перехватывает
# команду ДО выполнения. Реагирует только на git commit (в любом виде, включая
# `git -c user.name=... -c user.email=... commit -m ...`, как того требует конвенция
# коммитов этого харнесса) — на прочих командах молчит и ничего не сканирует.
#
# ИСТОЧНИК ОБРАЗЦОВ. Регэкспы для облаков/GitHub/Slack/приватных ключей взяты из
# vendor-конфига gitleaks (github.com/gitleaks/gitleaks, config/gitleaks.toml, правила
# aws-access-token, gcp-api-key, github-pat/oauth/app-token/refresh-token/fine-grained-pat,
# slack-bot-token/legacy-bot-token/user-token/app-token/webhook-url, private-key), сверено
# 2026-09-05. Приватный ключ ловится по строке BEGIN — этого достаточно как сигнала и не
# требует склеивать многострочное тело ключа из отдельных added-строк диффа.
#
# ПРИСВОЕНИЯ password/secret/api_key/token — СВОЁ правило, УЖЕ принятого в detect-secrets
# (detect_secrets/plugins/keyword.py): там ключевое слово матчится с произвольным
# суффиксом (`\w*`), и `password_default`/`password_env` в этом же репозитории (несекретный
# локальный фолбэк, см. config/memory.config.json) считались бы находкой при каждом
# коммите, задевающем эту строку. Здесь ключевое слово обязано стоять СРАЗУ перед
# оператором присваивания — без суффикса.
#
# Найденный секрет НЕ печатается — только имя файла, номер строки и имя правила.
#
# ОБХОД ЧЕРЕЗ -a/-am/--all. `git commit -a` (и короткая склейка `-am`) стажирует
# отслеживаемые правки ИЗНУТРИ самого commit, уже после того, как этот хук успел
# посмотреть на индекс — секрет, лежащий только в рабочем дереве (git add не делали),
# при сканировании одного `git diff --cached` проезжает мимо: индекс на момент проверки
# пуст. Поэтому при -a/-am/--all в командной строке дополнительно сканируется
# `git diff` (рабочее дерево против индекса, без --cached) — см. HAS_ALL_FLAG ниже.
#
# ФОРМАТ ОТВЕТА PreToolUse. Сверено 2026-09-05 с code.claude.com/docs/en/hooks: для
# PreToolUse ответ обязан идти через hookSpecificOutput.permissionDecision (значение
# "deny"), а не через верхнеуровневое поле decision — дока прямо говорит "should use
# hookSpecificOutput.permissionDecision, not a top-level decision field". Блокировка
# держится на коде возврата 2 ("Exit 2 means a blocking error... blocks whether or not
# you print JSON" — сама дока), JSON с permissionDecisionReason и текст на stderr — это
# то, откуда Claude Code берёт текст причины при показе блокировки.
#
# Контракт:
#   $CLAUDE_PROJECT_DIR — корень проекта (ставит Claude Code); без него — $PWD
#   BCF_SECRET_SCAN_DISABLED=1 — выключить хук

set -u
export PYTHONIOENCODING=utf-8

[ "${BCF_SECRET_SCAN_DISABLED:-0}" = "1" ] && exit 0

PY=""
for c in python python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -z "$PY" ] && exit 0   # без python сканировать нечем

# СО ВХОДА ЧИТАЕМ С ПОТОЛКОМ ВРЕМЕНИ, а не «пока не кончится» — см. pre-task-memory-inject.sh:
# Claude Code закрывает stdin сразу после JSON, но запуск не из-под Claude Code (тест, рука)
# может оставить канал открытым, и cat без таймаута ждёт вечно ПЕРЕД любой Bash-командой.
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT="$(timeout 2 cat 2>/dev/null || true)"
  else
    INPUT="$(cat 2>/dev/null || true)"
  fi
fi
[ -z "$INPUT" ] && exit 0

start_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
REPO_ROOT=""
if command -v git >/dev/null 2>&1; then
  REPO_ROOT="$(cd "$start_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
fi

# JSON — ВО ВРЕМЕННЫЙ ФАЙЛ, А НЕ В ПАЙП. `python - <<HEREDOC` читает СЦЕНАРИЙ из stdin —
# heredoc для скрипта и пайп с данными в один и тот же stdin несовместимы: последняя
# переустановка stdin побеждает, и то, что должно было прийти как данные, либо теряется,
# либо (что хуже) пытается исполниться как программа. Данные — аргументом, скрипт — heredoc.
tmpf="$(mktemp)"
trap 'rm -f "$tmpf"' EXIT
printf '%s' "$INPUT" > "$tmpf"

# Один вызов python: разобрать JSON от Claude Code, узнать, git ли это commit, при
# необходимости прогнать git diff --cached и решить. Два процесса (разбор JSON отдельно,
# скан отдельно) означали бы два места, где можно молча разойтись форматом.
RESULT="$(REPO_ROOT="$REPO_ROOT" "$PY" - "$tmpf" <<'PYEOF'
import json
import os
import re
import subprocess
import sys


def emit_nothing():
    sys.exit(0)


try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
        payload = json.load(f)
except Exception:
    emit_nothing()

command = (payload.get('tool_input') or {}).get('command') or ''
if not command:
    emit_nothing()

# "git ... commit" как фраза, без точного разбора флагов: -c user.name="Andrey Vlasov"
# рвёт значение пробелом на два токена, и жёсткий разбор -c/--flag это упускает. Не
# требует, чтобы "git" и "commit" были соседними словами — только чтобы между ними не
# было конца команды. Отсекает "docker commit" (нет "git" перед "commit").
if not re.search(r'\bgit\b(?:\s+\S+)*?\s+commit\b', command):
    emit_nothing()

repo_root = os.environ.get('REPO_ROOT') or ''
if not repo_root:
    emit_nothing()   # не git-репозиторий — сканировать нечего, сам git commit откажет

# HAS_ALL_FLAG: -a/--all у git commit стажируют отслеживаемые правки прямо в момент
# коммита — если это пропустить, секрет из рабочего дерева пройдёт хук на пустом
# --cached и уедет в историю уже после единственной проверки. Без полного шелл-парсера
# (тот же уровень строгости, что и у regex на "git ... commit" выше): берём хвост
# команды после слова commit до конца строки или ближайшего оператора шелла (&&, ||,
# ;, |) и ищем в нём "--all" целым словом либо короткий флаг, содержащий "a"
# (-a, -am, -qam...) — длинные опции ("--author=...") исключены отдельно: они
# начинаются с двух дефисов, а короткий-флаговый разбор смотрит только на "-X", не "--X".
commit_tail = re.split(r'&&|\|\||[;|]', re.sub(r'^.*?\bcommit\b', '', command, count=1, flags=re.S), maxsplit=1)[0]
has_all_flag = bool(
    re.search(r'(?:^|\s)--all(?:\s|$)', commit_tail)
    or re.search(r'(?:^|\s)-(?!-)[A-Za-z]*a[A-Za-z]*(?:\s|$)', commit_tail)
)

try:
    diff = subprocess.run(
        ['git', '-C', repo_root, 'diff', '--cached', '-U0', '--no-color'],
        capture_output=True, encoding='utf-8', errors='replace', timeout=20,
    ).stdout
except Exception:
    emit_nothing()

if has_all_flag:
    try:
        diff += subprocess.run(
            ['git', '-C', repo_root, 'diff', '-U0', '--no-color'],
            capture_output=True, encoding='utf-8', errors='replace', timeout=20,
        ).stdout
    except Exception:
        pass   # --cached уже прочитан — не откатываем всю проверку из-за второго вызова

if not diff:
    emit_nothing()   # нечего коммитить — ни staged, ни (при -a) рабочее дерево не тронуты

# --- Образцы: см. заголовок файла для источника и версии сверки -------------------------
PATTERNS = [
    ('ключ доступа AWS',            re.compile(r'\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\b')),
    ('ключ Google Cloud API',       re.compile(r'\bAIza[\w-]{35}\b')),
    ('токен GitHub (classic PAT)',  re.compile(r'\bghp_[0-9A-Za-z]{36}\b')),
    ('токен GitHub (OAuth)',        re.compile(r'\bgho_[0-9A-Za-z]{36}\b')),
    ('токен GitHub (App/сервер)',   re.compile(r'\b(?:ghu|ghs)_[0-9A-Za-z]{36}\b')),
    ('токен GitHub (refresh)',      re.compile(r'\bghr_[0-9A-Za-z]{36}\b')),
    ('токен GitHub (fine-grained)', re.compile(r'\bgithub_pat_\w{82}\b')),
    ('токен Slack (bot)',           re.compile(r'\bxoxb-[0-9]{10,13}-[0-9]{10,13}[A-Za-z0-9-]*\b')),
    ('токен Slack (legacy bot)',    re.compile(r'\bxoxb-[0-9]{8,14}-[A-Za-z0-9]{18,26}\b')),
    ('токен Slack (user)',          re.compile(r'\bxox[pe](?:-[0-9]{10,13}){3}-[A-Za-z0-9-]{28,34}\b')),
    ('токен Slack (app-level)',     re.compile(r'(?i)\bxapp-\d-[A-Z0-9]+-\d+-[a-z0-9]+\b')),
    ('вебхук Slack',                re.compile(r'(?:https?://)?hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9+/]{43,56}')),
    ('приватный ключ (PEM)',        re.compile(r'(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----')),
    ('присвоение секрета',          re.compile(
        r"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?key|private[_-]?key|token)\b"
        r"['\"]?\s*[:=]{1,2}\s*"
        r"(?:(['\"])[^'\"]{8,}\2|[A-Za-z0-9][A-Za-z0-9/+_.=-]{7,})"
    )),
]

hits = []
current_file = None
new_line = 0
hunk_re = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')

for raw in diff.split('\n'):
    if raw.startswith('+++ '):
        path = raw[4:].strip()
        current_file = None if path == '/dev/null' else re.sub(r'^[ab]/', '', path)
        continue
    if raw.startswith('@@ '):
        m = hunk_re.match(raw)
        if m:
            new_line = int(m.group(1))
        continue
    if raw.startswith('---'):
        continue
    if raw.startswith('+'):
        content = raw[1:]
        if current_file is not None:
            for name, rx in PATTERNS:
                if rx.search(content):
                    hits.append((current_file, new_line, name))
                    break
        new_line += 1
        continue
    # '-' (удалённая строка) и служебные строки diff --git/index/rename на новую
    # нумерацию не влияют — их пропускаем.

if not hits:
    emit_nothing()

lines = [f'  {f}:{ln} — {name}' for f, ln, name in hits]
reason = (
    'коммит заблокирован: в staged-диффе похоже на секрет (само значение не печатается):\n'
    + '\n'.join(lines)
    + '\nубери находку из индекса (git restore --staged <файл>) или замени на переменную окружения.'
    + '\nложное срабатывание — переформулируй строку так, чтобы она не совпадала с образцом.'
)
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': reason,
    },
}, ensure_ascii=False))
print(reason, file=sys.stderr)
sys.exit(2)
PYEOF
)"
code=$?

if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT"
fi
exit "$code"
