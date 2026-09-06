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
# ЗНАЧЕНИЕ-ССЫЛКА — НЕ НАХОДКА. `token = process.env.GITHUB_TOKEN`, `apiKey = config.api_key`,
# `API_KEY = os.environ["OPENAI_API_KEY"]`, `pwd = password or os.getenv("DB_PASSWORD")` — это
# код, который УЖЕ читает секрет из окружения (то есть сделал ровно то, что советует текст
# отказа), а не секрет. detect-secrets (KeywordDetector) отбрасывает такие ссылочные значения
# отдельным фильтром; здесь то же самое — REFERENCE_VALUE_RE проверяет само значение
# присваивания, а не только ключевое слово слева, и не даёт результата на код, который
# читает секрет из окружения, а не хранит его текстом. У правила два эффекта одновременно:
# из символов значения без кавычек убрана точка (значения-литералы ключей точек не содержат,
# а `os.environ`/`config.api_key` обрываются на первой же точке короче порога), и отдельно
# отбрасываются значения, начинающиеся с самой ссылки (process.env, os.environ, os.getenv,
# System.getenv, config./cfg./settings., `${...}`) или с бытового ключевого слова-ссылки на
# другую переменную с тем же смыслом (`pwd = password`).
#
# Найденный секрет НЕ печатается — только имя файла, номер строки и имя правила.
#
# СОВЕТ В ТЕКСТЕ ОТКАЗА ЗАВИСИТ ОТ ТОГО, ГДЕ НАХОДКА. Найдено пятым ревью M-05: текст
# отказа безусловно советовал `git restore --staged <файл>` — это верно только для
# находки в РЕАЛЬНОМ индексе (`git diff --cached`, застейджено ДО этой команды отдельным
# `git add`). Находка из широкого/scoped диффа рабочего дерева (-a/-am/--all или add из
# этой же командной строки) и находка в новом файле ещё НЕ в индексе — `git restore
# --staged` там ничего не отменяет, файл сам себе не появляется в индексе, пока команда
# не исполнилась. Поэтому каждая находка размечается источником (staged/unstaged) и
# текст отказа даёт для каждого источника свой, рабочий совет — см. STAGED_REMEDY/
# UNSTAGED_REMEDY ниже.
#
# ГРАНИЦА: ФАЙЛ, СОЗДАННЫЙ В ЭТОЙ ЖЕ КОМАНДНОЙ СТРОКЕ. Хук — PreToolUse, он смотрит на
# командную строку ДО её исполнения. `echo секрет > c.txt && git add c.txt && git commit`
# создаёт c.txt только в момент выполнения `echo` — на момент проверки файла ещё нет на
# диске, `git ls-files --others` его не видит, и `git add --dry-run c.txt` не находит,
# что добавлять. Это не обход разбора pathspec (он отработал бы верно, появись файл раньше),
# а сама природа PreToolUse: хук не может увидеть то, чего команда ещё не создала. Граница
# названа в docs/SETUP.md, а не только здесь.
#
# ОБХОД ЧЕРЕЗ -a/-am/--all. `git commit -a` (и короткая склейка `-am`) стажирует
# отслеживаемые правки ИЗНУТРИ самого commit, уже после того, как этот хук успел
# посмотреть на индекс — секрет, лежащий только в рабочем дереве (git add не делали),
# при сканировании одного `git diff --cached` проезжает мимо: индекс на момент проверки
# пуст. Поэтому при -a/-am/--all в командной строке дополнительно сканируется
# `git diff` (рабочее дерево против индекса, без --cached) — см. HAS_ALL_FLAG ниже.
#
# ОБХОД ЧЕРЕЗ `git add ... && git commit ...` В ОДНОЙ КОМАНДНОЙ СТРОКЕ. Тот же класс
# обхода, что и -a/-am, только без флага commit: этот хук — PreToolUse, он видит
# командную строку и индекс ДО того, как что-либо из неё выполнилось, поэтому `git add`
# в НАЧАЛЕ той же строки ещё не сработал в момент проверки, и `git diff --cached` на
# этот момент пуст независимо от того, что уедет в коммит через долю секунды. Команда
# разбирается на сегменты по &&/||/;/| — сегмент до commit, начинающийся с `git ... add`,
# даёт свои аргументы САМОМУ git через `git add --dry-run` (а не собственный разбор
# pathspec: git уже умеет -A/./glob/.gitignore) — это НЕ исполняет добавление, только
# спрашивает, что было бы добавлено.
#
# ДИФФ РАБОЧЕГО ДЕРЕВА ОГРАНИЧЕН ПУТЯМИ ИЗ `git add --dry-run`, А НЕ ВЕСЬ РЕПОЗИТОРИЙ.
# Найдено пятым ревью M-05: до этой правки при has_add_stage к --cached диффу
# безусловно добавлялся ПОЛНЫЙ `git diff` рабочего дерева — тот же вызов, что и для
# -a/-am/--all. Из-за этого отслеживаемый файл с секретом, который команда вообще не
# трогает («password = ...» правится локально в cfg.txt, но коммитится только
# `git add doc.md && git commit`), блокировал коммит doc.md, хотя в этот коммит cfg.txt
# не попадает. Широкий diff нужен ТОЛЬКО у -a/-am/--all — там git commit сам стажирует
# ЛЮБУЮ отслеживаемую правку. У `git add <pathspec>` набор файлов уже точно известен:
# это и есть ответ `git add --dry-run` (ADD_STAGE_PATHS ниже, накопленный по всем
# add-сегментам команды). Дифф рабочего дерева при has_add_stage запускается с этими
# путями как pathspec (`git diff -- <ADD_STAGE_PATHS...>`), а не без ограничений.
# Отслеживаемые файлы из этого списка получают дифф; неотслеживаемые НОВЫЕ файлы — то,
# чего `git diff` без --no-index вообще не показывает, — сканируются целиком по
# содержимому отдельно (staged_new_files, тот же список, что и раньше).
#
# ФОРМАТ ОТВЕТА PreToolUse. Сверено 2026-09-05 с code.claude.com/docs/en/hooks: для
# PreToolUse ответ обязан идти через hookSpecificOutput.permissionDecision (значение
# "deny"), а не через верхнеуровневое поле decision — дока прямо говорит "should use
# hookSpecificOutput.permissionDecision, not a top-level decision field". Блокировка
# держится на коде возврата 2 ("Exit 2 means a blocking error... blocks whether or not
# you print JSON" — сама дока), JSON с permissionDecisionReason и текст на stderr — это
# то, откуда Claude Code берёт текст причины при показе блокировки.
#
# КИРИЛЛИЦА И ДРУГИЕ НЕ-ASCII ИМЕНА. `git ls-files --others` уважает core.quotepath
# (по умолчанию true у git) и C-квотирует не-ASCII байты имени файла ("\320\272..."),
# а `git add --dry-run` печатает то же имя как есть, без квотирования. Список
# неотслеживаемых файлов и ответ --dry-run сверялись строка в строку — при расхождении
# в квотировании новый файл с не-ASCII именем не находил себя в списке и не сканировался
# вообще. Все git-вызовы этого файла, которые сравнивают или парсят ИМЕНА файлов,
# зовутся с -c core.quotepath=false, чтобы то и другое отдавало один и тот же байтовый
# вид имени.
#
# `cd <каталог> && git add ... && git commit ...`. Pathspec в сегменте `add` — это то,
# что стояло бы в РЕАЛЬНОМ рабочем каталоге на момент выполнения, а не в корне репозитория:
# относительный путь читается от каталога, куда перевели предыдущие `cd` в той же
# командной строке. Сегменты до `commit` разбираются по порядку, `cd <путь>` двигает
# отслеживаемый рабочий каталог (без выражений вида `cd -`/переменных — там смена
# каталога неоднозначна, и текущий каталог остаётся как был), и `git add --dry-run`
# запускается с -C именно этим каталогом. Сам ответ --dry-run от этого не меняется:
# git печатает путь относительно корня репозитория независимо от того, какой -C передан
# (проверено вручную), поэтому дальнейший разбор пути правкой не тронут.
#
# PYTHON НЕ НАЙДЕН. Хук зарегистрирован в settings.json как обязательная проверка перед
# коммитом — тихий exit 0 без python выключил бы её незаметно на любой машине без python,
# хотя python в docs/SETUP.md объявлен опциональным (только под память). Без python
# разобрать JSON от Claude Code по-настоящему нечем, поэтому решение грубое, на grep по
# сырому входу: если строка похожа на git commit — хук ОТКАЗЫВАЕТ явно, с текстом причины
# и кодом 2, а не пропускает секрет молча. На любой другой команде (не commit-подобной)
# по-прежнему тихий exit 0 — иначе хук блокировал бы вообще все Bash-команды в проекте на
# машине без python, а не только коммиты.
#
# Контракт:
#   $CLAUDE_PROJECT_DIR — корень проекта (ставит Claude Code); без него — $PWD
#   BCF_SECRET_SCAN_DISABLED=1 — выключить хук
#   python/python3 не найден — commit-подобная команда отказывает явно (код 2), прочие
#   команды пропускаются молча (см. "PYTHON НЕ НАЙДЕН" выше)

set -u
export PYTHONIOENCODING=utf-8

[ "${BCF_SECRET_SCAN_DISABLED:-0}" = "1" ] && exit 0

# СО ВХОДА ЧИТАЕМ С ПОТОЛКОМ ВРЕМЕНИ, а не «пока не кончится» — см. pre-task-memory-inject.sh:
# Claude Code закрывает stdin сразу после JSON, но запуск не из-под Claude Code (тест, рука)
# может оставить канал открытым, и cat без таймаута ждёт вечно ПЕРЕД любой Bash-командой.
# Читаем ДО поиска python: без входа нечего проверять независимо от того, нашёлся python
# или нет, и незачем решать судьбу python-less запуска раньше времени.
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT="$(timeout 2 cat 2>/dev/null || true)"
  else
    INPUT="$(cat 2>/dev/null || true)"
  fi
fi
[ -z "$INPUT" ] && exit 0

PY=""
for c in python python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done

if [ -z "$PY" ]; then
  # См. "PYTHON НЕ НАЙДЕН" в заголовке файла. Без python сам JSON не разобрать — грубая
  # проверка через grep по сырому входу: похоже на git commit — отказ явно, иначе тихий
  # пропуск (не блокировать ВСЕ Bash-команды в проекте из-за одной непроверяемой).
  if printf '%s' "$INPUT" | grep -q '"command"' && printf '%s' "$INPUT" | grep -qiE '\bgit\b.*\bcommit\b'; then
    reason='secret-scan.sh не может проверить коммит на секреты: python (или python3) не найден в PATH. Поставьте python3 или явно отключите проверку BCF_SECRET_SCAN_DISABLED=1, если она сейчас не нужна.'
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$reason\"}}"
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  exit 0
fi

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
RESULT="$(REPO_ROOT="$REPO_ROOT" START_DIR="$start_dir" "$PY" - "$tmpf" <<'PYEOF'
import json
import os
import re
import shlex
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
GIT_COMMIT_RE = re.compile(r'\bgit\b(?:\s+\S+)*?\s+commit\b')
GIT_ADD_RE = re.compile(r'\bgit\b(?:\s+\S+)*?\s+add\b')

if not GIT_COMMIT_RE.search(command):
    emit_nothing()

repo_root = os.environ.get('REPO_ROOT') or ''
if not repo_root:
    emit_nothing()   # не git-репозиторий — сканировать нечего, сам git commit откажет

# Командная строка разбирается на сегменты по операторам оболочки — тем же уровнем
# строгости, что и весь остальной разбор в этом файле (без полного шелл-парсера): так
# "git add ..." и "git commit ..." в одной строке не путаются друг с другом при поиске
# ХВОСТА команды commit (иначе первое попавшееся слово "commit" где угодно в строке,
# включая чужой текст до git commit, рвало бы разбор -a/-am не в том месте).
segments = re.split(r'&&|\|\||[;|]|\r?\n', command)
commit_seg_idx = None
for i, seg in enumerate(segments):
    if GIT_COMMIT_RE.search(seg):
        commit_seg_idx = i   # последний git commit в строке — тот, что реально исполнится
if commit_seg_idx is None:
    emit_nothing()   # "git commit" виден только через границу оператора — считаем, что не наш случай
commit_segment = segments[commit_seg_idx]

# HAS_ALL_FLAG: -a/--all у git commit стажируют отслеживаемые правки прямо в момент
# коммита — если это пропустить, секрет из рабочего дерева пройдёт хук на пустом
# --cached и уедет в историю уже после единственной проверки. Берём хвост СЕГМЕНТА
# commit (не всей команды) после слова commit и ищем в нём "--all" целым словом либо
# короткий флаг, содержащий "a" (-a, -am, -qam...) — длинные опции ("--author=...")
# исключены отдельно: они начинаются с двух дефисов, а короткий-флаговый разбор
# смотрит только на "-X", не "--X".
commit_tail = re.sub(r'^.*?\bcommit\b', '', commit_segment, count=1, flags=re.S)
has_all_flag = bool(
    re.search(r'(?:^|\s)--all(?:\s|$)', commit_tail)
    or re.search(r'(?:^|\s)-(?!-)[A-Za-z]*a[A-Za-z]*(?:\s|$)', commit_tail)
)

# ОБХОД ЧЕРЕЗ `git add ... && git commit ...` — см. заголовок файла. Сегменты ДО commit,
# которые сами являются "git ... add ...", отдают свои аргументы настоящему git через
# --dry-run: он и разворачивает -A/./glob, и учитывает .gitignore за нас, не нужно
# повторять его логику pathspec самим.
#
# `cd <каталог> && git add ...` — см. "cd <каталог> ..." в заголовке файла. Сегменты до
# commit разбираются ПО ПОРЯДКУ; `cd` двигает отслеживаемый рабочий каталог, `git add`
# запоминается вместе с тем, в каком каталоге он оказался бы на момент своего выполнения.
CD_RE = re.compile(r'^\s*cd\s+(\S.*)$')


def resolve_cd(cwd, raw_target):
    # 'cd -' (предыдущий каталог) и составные/пустые аргументы неоднозначны без полной
    # истории cd — оставляем cwd как был, не гадаем.
    try:
        parts = shlex.split(raw_target)
    except ValueError:
        return cwd
    if not parts or parts[0] == '-':
        return cwd
    target = parts[0]
    if os.path.isabs(target) or re.match(r'^[A-Za-z]:[\\/]', target):
        candidate = target
    else:
        candidate = os.path.join(cwd, target)
    return os.path.normpath(candidate)


cwd = os.environ.get('START_DIR') or repo_root
add_segments = []   # [(сегмент, каталог на момент его выполнения), ...]
for seg in segments[:commit_seg_idx]:
    cd_m = CD_RE.match(seg)
    if cd_m:
        cwd = resolve_cd(cwd, cd_m.group(1))
        continue
    if GIT_ADD_RE.search(seg):
        add_segments.append((seg, cwd))

staged_new_files = []   # неотслеживаемые файлы, которые git add реально бы добавил
add_stage_paths = []    # ВСЕ пути (новые и уже отслеживаемые), которые git add реально
                         # добавил бы — этим списком, а не всем репозиторием, ограничен
                         # дифф рабочего дерева ниже при has_add_stage (см. "ДИФФ РАБОЧЕГО
                         # ДЕРЕВА ОГРАНИЧЕН ПУТЯМИ ИЗ git add --dry-run" в заголовке файла).
if add_segments:
    try:
        # -c core.quotepath=false — см. "КИРИЛЛИЦА И ДРУГИЕ НЕ-ASCII ИМЕНА" в заголовке
        # файла: без этого ls-files C-квотирует не-ASCII имя иначе, чем печатает
        # `git add --dry-run` ниже, и сравнение по множеству строк ниже никогда не совпадает.
        untracked_out = subprocess.run(
            ['git', '-c', 'core.quotepath=false', '-C', repo_root, 'ls-files', '--others', '--exclude-standard'],
            capture_output=True, encoding='utf-8', errors='replace', timeout=20,
        ).stdout
    except Exception:
        untracked_out = ''
    untracked_set = set(p for p in untracked_out.split('\n') if p)

    for seg, seg_cwd in add_segments:
        add_tail = re.sub(r'^.*?\badd\b', '', seg, count=1, flags=re.S).strip()
        try:
            add_args = shlex.split(add_tail)
        except ValueError:
            continue   # незакрытая кавычка в аргументах — эту команду add не разбираем
        add_args = [a for a in add_args if a not in ('-v', '--verbose', '-n', '--dry-run')]
        if not add_args:
            continue
        try:
            # БЕЗ "--" перед аргументами: git-флаги add (-A, -u, .) обязаны остаться
            # флагами, а не превратиться в буквальный pathspec ("-A" файлом с таким
            # именем) — "--" здесь как раз это и сделал бы. -C seg_cwd — каталог, в
            # котором этот add реально оказался бы после предыдущих cd в той же строке
            # (по умолчанию repo_root, если cd не было); ответ --dry-run от этого не
            # меняется — git печатает путь относительно корня репозитория независимо
            # от переданного -C (см. заголовок файла).
            dr_out = subprocess.run(
                ['git', '-c', 'core.quotepath=false', '-C', seg_cwd, 'add', '--dry-run'] + add_args,
                capture_output=True, encoding='utf-8', errors='replace', timeout=20,
            ).stdout
        except Exception:
            continue
        for line in dr_out.split('\n'):
            dm = re.match(r"^add '(.+)'$", line)
            if not dm:
                continue
            # --dry-run НИЧЕГО не пишет в индекс (проверено фикстурой в сюите) — только
            # спрашивает git, что было бы добавлено. Путь идёт в add_stage_paths целиком
            # (и отслеживаемые правки, и новые файлы) — этим списком, а не безусловным
            # git diff, ограничен дифф рабочего дерева ниже; неотслеживаемые НОВЫЕ файлы
            # дополнительно попадают в staged_new_files — им нужно не дифф, а всё
            # содержимое целиком (см. HAS_ALL_FLAG и заголовок файла).
            path = dm.group(1)
            if path not in add_stage_paths:
                add_stage_paths.append(path)
            if path in untracked_set:
                staged_new_files.append(path)

try:
    # -c core.quotepath=false — тот же повод, что у ls-files выше: без этого заголовок
    # диффа (+++ b/<путь>) C-квотирует не-ASCII имя, и парсер ниже (который квотирование
    # не разбирает) отдаёт current_file строкой в кавычках вместо реального пути.
    cached_diff = subprocess.run(
        ['git', '-c', 'core.quotepath=false', '-C', repo_root, 'diff', '--cached', '-U0', '--no-color'],
        capture_output=True, encoding='utf-8', errors='replace', timeout=20,
    ).stdout
except Exception:
    emit_nothing()

# UNSTAGED_DIFF — рабочее дерево, ЕЩЁ не в индексе. -a/-am/--all стажирует ЛЮБУЮ
# отслеживаемую правку внутри самого commit, поэтому там дифф безусловный и полный.
# has_add_stage — это КОНКРЕТНЫЙ git add с уже известным git'у списком путей
# (add_stage_paths, ответ --dry-run) — дифф ограничен ИМ, а не всем репозиторием: секрет
# в файле, который эта команда не добавляет и не коммитит, её не касается (см. "ДИФФ
# РАБОЧЕГО ДЕРЕВА ОГРАНИЧЕН..." в заголовке файла — пятое ревью M-05). Одновременное
# -am и add (редкий состав) разрешается в пользу более широкой проверки: -am и так
# покрывает любой путь из add_stage_paths.
unstaged_diff = ''
if has_all_flag:
    try:
        unstaged_diff = subprocess.run(
            ['git', '-c', 'core.quotepath=false', '-C', repo_root, 'diff', '-U0', '--no-color'],
            capture_output=True, encoding='utf-8', errors='replace', timeout=20,
        ).stdout
    except Exception:
        pass   # --cached уже прочитан — не откатываем всю проверку из-за второго вызова
elif add_stage_paths:
    try:
        unstaged_diff = subprocess.run(
            ['git', '-c', 'core.quotepath=false', '-C', repo_root, 'diff', '-U0', '--no-color', '--'] + add_stage_paths,
            capture_output=True, encoding='utf-8', errors='replace', timeout=20,
        ).stdout
    except Exception:
        pass

if not cached_diff and not unstaged_diff and not staged_new_files:
    emit_nothing()   # нечего коммитить — ни staged, ни рабочее дерево, ни новые файлы не тронуты

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
    # Значение — ИЛИ кавычная строка (qval), ИЛИ голое слово без точки (uval): точка
    # убрана из символов uval нарочно — литералы ключей точек не содержат, а типичные
    # ссылки-обходы ("os.environ", "config.api_key", "process.env") обрываются на первой
    # же точке короче порога в 8 символов и просто не матчатся здесь вообще. См.
    # REFERENCE_VALUE_RE ниже — второй, независимый барьер для случаев подлиннее.
    ('присвоение секрета',          re.compile(
        r"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?key|private[_-]?key|token)\b"
        r"['\"]?\s*[:=]{1,2}\s*"
        r"(?:(?P<q>['\"])(?P<qval>[^'\"]{8,})(?P=q)|(?P<uval>[A-Za-z0-9][A-Za-z0-9/+_=-]{7,}))"
    )),
]

# ЗНАЧЕНИЯ-ССЫЛКИ — см. заголовок файла. Применяется ТОЛЬКО к правилу "присвоение
# секрета": вендорские образцы (AKIA…, ghp_…, приватный ключ) матчят сам секрет
# буквально и в фильтре не нуждаются.
REFERENCE_VALUE_RE = re.compile(
    r"^(?:"
    r"process\.env\b|os\.environ\b|os\.getenv\b|getenv\(|System\.getenv\b|System\.Environment\b"
    r"|\$\{"
    r"|(?:config|cfg|settings|options|opts)\."
    r"|password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?key|private[_-]?key|token"
    r")\b",
    re.IGNORECASE,
)


def check_line(content):
    """Возвращает имя сработавшего правила или None — общая точка для diff и для
    полного содержимого новых файлов, чтобы фильтр значений-ссылок не жил в двух
    местах и не разошёлся между ними на следующей правке."""
    for name, rx in PATTERNS:
        m = rx.search(content)
        if not m:
            continue
        if name == 'присвоение секрета':
            val = m.group('qval')
            if val is None:
                val = m.group('uval')
            if val and REFERENCE_VALUE_RE.match(val):
                continue   # значение — ссылка на переменную/окружение, не литерал
        return name
    return None


hunk_re = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')


def scan_diff_text(diff_text, source):
    """Разбирает unified diff (-U0) и возвращает находки (файл, строка, правило,
    источник). Общая точка для --cached и рабочего дерева, чтобы разбор не жил в двух
    местах и не разошёлся между ними на следующей правке — source ТОЛЬКО помечает,
    откуда пришла находка (staged/unstaged), для текста отказа ниже."""
    out = []
    current_file = None
    new_line = 0
    for raw in diff_text.split('\n'):
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
                name = check_line(content)
                if name:
                    out.append((current_file, new_line, name, source))
            new_line += 1
            continue
        # '-' (удалённая строка) и служебные строки diff --git/index/rename на новую
        # нумерацию не влияют — их пропускаем.
    return out


# source='staged' — находка уже в индексе (git diff --cached): её туда занёс отдельный
# git add ДО этой команды, `git restore --staged` реально её оттуда уберёт. source=
# 'unstaged' — находка из рабочего дерева (-a/-am/--all или пути add_stage_paths) либо
# из нового файла: в индексе её ЕЩЁ нет, `git restore --staged` там ничего не отменяет
# (см. "СОВЕТ В ТЕКСТЕ ОТКАЗА..." в заголовке файла — пятое ревью M-05).
hits = scan_diff_text(cached_diff, 'staged')
hits += scan_diff_text(unstaged_diff, 'unstaged')

# Новые (ранее неотслеживаемые) файлы, которые `git add` из командной строки реально
# добавил бы, — они не проходят через diff-парсер выше (для git нет "before", значит нет
# и unified diff), поэтому читаются и сканируются целиком, с первой строки. В индексе их
# тоже ещё нет — source='unstaged'.
for path in dict.fromkeys(staged_new_files):
    try:
        with open(os.path.join(repo_root, path), encoding='utf-8', errors='replace') as f:
            for lineno, line in enumerate(f, start=1):
                name = check_line(line)
                if name:
                    hits.append((path, lineno, name, 'unstaged'))
    except Exception:
        continue

if not hits:
    emit_nothing()

STAGED_REMEDY = (
    'уже в индексе — убери находку из индекса (git restore --staged <файл>) '
    'или замени на переменную окружения.'
)
UNSTAGED_REMEDY = (
    'ещё не в индексе (рабочее дерево, -a/-am/--all или git add из этой же команды) — '
    'убери секрет из файла или не включай этот путь в add/-a/-am, закоммить остальное отдельно.'
)
remedies = []
if any(h[3] == 'staged' for h in hits):
    remedies.append(STAGED_REMEDY)
if any(h[3] == 'unstaged' for h in hits):
    remedies.append(UNSTAGED_REMEDY)

lines = [f'  {f}:{ln} — {name}' for f, ln, name, _src in hits]
reason = (
    'коммит заблокирован: похоже на секрет (само значение не печатается):\n'
    + '\n'.join(lines) + '\n'
    + '\n'.join(remedies)
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
