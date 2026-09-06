# memory-team.tests.ps1 — память, которую делят несколько проектов и несколько людей.
#
#   pwsh tests/memory-team.tests.ps1
#
# ЧТО ЭТИ ТЕСТЫ ЛОВЯТ. Одна установка фабрики обслуживает много проектов на одной
# машине, и всё, что она держит общего, ломается одинаково молча:
#
#   · хук перед задачей ищет клиента памяти в проекте — на чужом проекте его там нет,
#     и хук выходит нулём, ничего не сказав: память просто не работает;
#   · записи в общей базе не знают своего проекта — отзыв возвращает урок соседнего
#     стека с высокой похожестью, и агент честно принимает его за свой;
#   · подобранный порт пишется в отслеживаемый конфиг — коммит увозит номер порта
#     ЭТОЙ машины всей команде;
#   · счётчик агентских слотов заведён на проект — два проекта с потолком 6 запускают
#     двенадцать агентов, и провайдер отвечает отказами всем сразу;
#   · пароль базы взят из репозитория, а база в сети.
#
# Ни Docker, ни живая модель здесь не нужны: схема проверяется разбором SQL и подставным
# psycopg, хук — запуском в Git Bash на фикстуре с подставным клиентом памяти.

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$root       = Split-Path $PSScriptRoot -Parent
$bcf        = Join-Path $root 'bin\bcf.ps1'
$hookTpl    = Join-Path $root 'templates\claude\hooks\pre-task-memory-inject.sh'
$initSql    = Join-Path $root 'memory\pgvector\init.sql'
$memClient  = Join-Path $root 'memory\pgvector\memory_client.py'
$envExample = Join-Path $root '.env.example'
$sandbox    = Join-Path ([IO.Path]::GetTempPath()) ("bcf-memteam-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:Pass = 0; $script:Fail = 0
function Check {
    param([string]$Name, $Cond, [string]$Detail = '')
    if ($Cond) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $Name$(if ($Detail) { " — $Detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

function Get-GitBash {
    foreach ($c in @($env:BCF_BASH, 'C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}
$bash = Get-GitBash
if (-not $bash) {
    Write-Host 'Git Bash не найден — хук прогнать нечем.' -ForegroundColor Red
    Write-Host 'Пропуск считался бы зелёным прогоном при непроверенном хуке, поэтому это ПРОВАЛ.' -ForegroundColor Red
    exit 1
}
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $python) {
    Write-Host 'python не найден — клиент памяти и хук прогнать нечем. ПРОВАЛ.' -ForegroundColor Red
    exit 1
}

# Окружение теста не должно тащить настройки машины: BCF_MEM_CONFIG или BCF_PG_PASSWORD,
# выставленные снаружи, сделали бы часть проверок зелёными по чужой причине.
$saved = @{}
foreach ($n in @('BCF_MEM_CONFIG', 'BCF_PG_PASSWORD', 'BCF_PROJECT_ROOT', 'BCF_MEMORY_PROJECT',
                 'BCF_FLEET_DIR', 'BCF_MEMORY_CLIENT', 'BCF_TEST_SQL_LOG', 'PYTHONPATH',
                 'BCF_TASK_ID', 'BCF_TASK_DESCRIPTION', 'EOG_BIN', 'CLAUDE_PROJECT_DIR')) {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    Remove-Item "env:$n" -ErrorAction SilentlyContinue
}
function Restore-TestEnv {
    foreach ($n in $saved.Keys) {
        if ($null -eq $saved[$n]) { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
        else { Set-Item "env:$n" $saved[$n] }
    }
}

New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
Write-Host ''
Write-Host "  ПАМЯТЬ НА НЕСКОЛЬКО ПРОЕКТОВ   песочница: $sandbox" -ForegroundColor Cyan

function Write-Utf8 { param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
}

# ---------------------------------------------------------------------------
Section '1. Хук перед задачей: клиент памяти берётся от установки фабрики'
# ---------------------------------------------------------------------------
# Наблюдаемый признак — блок «Известные анти-паттерны» в выводе хука. Клиента в проекте
# НЕТ ни в одной фикстуре: он лежит в фабрике, и найти его можно только через карточку
# .bcf/project.json или $BCF_HOME. Пока хук искал memory_client.py в проекте, на любом
# чужом проекте он выходил нулём молча — то есть память была выключена и не жаловалась.

function New-HookFixture {
    param([string]$Name, [hashtable]$Harness = $null, [string]$Focus = '')
    $proj = Join-Path $sandbox "$Name\proj"
    $fac  = Join-Path $sandbox "$Name\factory"
    New-Item -ItemType Directory -Force -Path (Join-Path $proj '.claude\hooks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $proj '.bcf') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $fac 'memory\pgvector') | Out-Null
    & git -C $proj init -q 2>&1 | Out-Null

    # Карточка проекта — единственное, что связывает проект с фабрикой без абсолютных
    # путей в самом хуке. Её пишет bcf init.
    (@{ name = $Name; bcfHome = ($fac -replace '\\', '/') } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $proj '.bcf\project.json') -Encoding UTF8

    # Подставной клиент памяти: печатает то, что печатал бы настоящий recall.
    Write-Utf8 (Join-Path $fac 'memory\pgvector\memory_client.py') @'
import json, sys
print(json.dumps([{
    "trigger_summary": "слияние упало на лок-файле",
    "what_went_wrong": "гейт ждал чистое дерево",
    "correct_alternative": "внести лок в generatedFiles",
    "similarity": 0.81,
    "project": "соседний-проект"
}], ensure_ascii=False))
'@
    if ($Harness) {
        Write-Utf8 (Join-Path $proj 'config\harness.json') ($Harness | ConvertTo-Json)
    }
    if ($Focus) {
        New-Item -ItemType Directory -Force -Path (Join-Path $proj 'tasks') | Out-Null
        Set-Content -LiteralPath (Join-Path $proj 'tasks\CURRENT-FOCUS.md') -Value $Focus -Encoding UTF8
    }
    Copy-Item -LiteralPath $hookTpl -Destination (Join-Path $proj '.claude\hooks\pre-task-memory-inject.sh') -Force
    return $proj
}

function Invoke-Hook {
    param([string]$Project, [hashtable]$Env = @{}, [string]$StartDir = '')
    $prev = @{}
    $all = @{ CLAUDE_PROJECT_DIR = $(if ($StartDir) { $StartDir } else { $Project }) } + $Env
    foreach ($k in $all.Keys) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k)
        Set-Item "env:$k" $all[$k]
    }
    $hook = (Join-Path $Project '.claude\hooks\pre-task-memory-inject.sh') -replace '\\', '/'
    # Вход закрываем ПУСТЫМ ФАЙЛОМ: хук читает stdin, и открытый канал держал бы его до
    # потолка времени — тест ждал бы две секунды на каждый случай без всякой пользы.
    $emptyIn = Join-Path $sandbox 'empty.in'
    if (-not (Test-Path $emptyIn)) { [IO.File]::WriteAllText($emptyIn, '') }
    $outFile = Join-Path $sandbox ("hook-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".out")
    $p = Start-Process -FilePath $bash -ArgumentList @($hook) -NoNewWindow -PassThru -Wait `
                       -RedirectStandardInput $emptyIn -RedirectStandardOutput $outFile
    $out = if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
    foreach ($k in $prev.Keys) {
        if ($null -eq $prev[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item "env:$k" $prev[$k] }
    }
    return @{ Out = $out; Code = $p.ExitCode }
}

$p1 = New-HookFixture -Name 'hook-basic'
$r = Invoke-Hook -Project $p1 -Env @{ BCF_TASK_DESCRIPTION = 'слить ветку задачи в основное дерево' }
Check 'блок «Известные анти-паттерны» есть в выводе' ($r.Out -match 'Известные анти-паттерны') $r.Out
Check 'в блоке лежит сама запись памяти' ($r.Out -match 'слияние упало на лок-файле') $r.Out
Check 'у записи назван проект-владелец' ($r.Out -match 'соседний-проект') $r.Out
Check 'хук вышел нулём' ($r.Code -eq 0) "код $($r.Code)"

# Запуск из подкаталога: корень репозитория берётся из git rev-parse, а не из «где стою».
$sub = Join-Path $p1 'src\deep\er'
New-Item -ItemType Directory -Force -Path $sub | Out-Null
$r = Invoke-Hook -Project $p1 -StartDir $sub -Env @{ BCF_TASK_DESCRIPTION = 'слить ветку' }
Check 'из подкаталога корень находится через git rev-parse' ($r.Out -match 'Известные анти-паттерны') $r.Out

# Без описания задачи отзывать нечего — и выдумывать блок не из чего.
$r = Invoke-Hook -Project $p1
Check 'без описания задачи вывод пуст' ([string]::IsNullOrWhiteSpace($r.Out)) $r.Out
Check 'без описания задачи код всё равно нулевой' ($r.Code -eq 0) "код $($r.Code)"

# В самом хуке не должно быть путей этой машины: он уезжает в любой проект как есть.
$hookText = [IO.File]::ReadAllText($hookTpl)
Check 'в хуке нет абсолютных путей' (-not ($hookText -match '(?m)[A-Za-z]:[\\/]{1,2}(develop|Users)')) 'найден абсолютный путь'

# ---------------------------------------------------------------------------
Section '2. Хук зовёт общую память команды (eog) и не падает от её отказа'
# ---------------------------------------------------------------------------
function Set-FakeEog {
    param([string]$Dir, [int]$ExitCode = 0, [string]$Say = 'заметка: этот путь уже чинили в марте')
    $argsFile = (Join-Path $Dir 'eog.args') -replace '\\', '/'
    $body = @"
#!/usr/bin/env bash
printf '%s\n' "`$*" > "$argsFile"
printf '%s\n' "$Say"
exit $ExitCode
"@
    $exe = Join-Path $Dir 'eog'
    Write-Utf8 $exe $body
    return @{ Exe = $exe; ArgsFile = (Join-Path $Dir 'eog.args') }
}

$p2 = New-HookFixture -Name 'hook-eog' -Harness @{ repo = 'платформа-заказов' }
$eog = Set-FakeEog -Dir (Split-Path $p2 -Parent)
$r = Invoke-Hook -Project $p2 -Env @{
    BCF_TASK_DESCRIPTION = 'починить слияние'
    BCF_TASK_ID          = 'TASK-14'
    EOG_BIN              = $eog.Exe
}
$eogArgs = if (Test-Path $eog.ArgsFile) { (Get-Content -Raw -LiteralPath $eog.ArgsFile).Trim() } else { '' }
Check 'eog вызван как memory context' ($eogArgs -match '^memory context') "аргументы: '$eogArgs'"
Check 'имя репозитория взято из harness.json (repo)' ($eogArgs -match '--repo платформа-заказов') "аргументы: '$eogArgs'"
Check 'id задачи передан' ($eogArgs -match '--task TASK-14') "аргументы: '$eogArgs'"
Check 'вывод eog попал в контекст' ($r.Out -match 'уже чинили в марте') $r.Out
Check 'блок памяти при этом остался' ($r.Out -match 'Известные анти-паттерны') $r.Out

# Имя репозитория без harness.json — имя каталога.
$p3 = New-HookFixture -Name 'hook-eog-dirname'
$eog3 = Set-FakeEog -Dir (Split-Path $p3 -Parent)
$r = Invoke-Hook -Project $p3 -Env @{ BCF_TASK_DESCRIPTION = 'разобрать TASK-09 и починить'; EOG_BIN = $eog3.Exe }
$eogArgs3 = if (Test-Path $eog3.ArgsFile) { (Get-Content -Raw -LiteralPath $eog3.ArgsFile).Trim() } else { '' }
Check 'без repo в конфиге берётся имя каталога' ($eogArgs3 -match '--repo proj') "аргументы: '$eogArgs3'"
Check 'id задачи вынут из описания' ($eogArgs3 -match '--task TASK-09') "аргументы: '$eogArgs3'"

# Отказ eog не должен ронять итерацию и не должен съедать блок памяти.
$p4 = New-HookFixture -Name 'hook-eog-fails'
$eog4 = Set-FakeEog -Dir (Split-Path $p4 -Parent) -ExitCode 3 -Say ''
$r = Invoke-Hook -Project $p4 -Env @{ BCF_TASK_DESCRIPTION = 'слить ветку'; EOG_BIN = $eog4.Exe }
Check 'ненулевой код eog не роняет хук' ($r.Code -eq 0) "код $($r.Code)"
Check 'при отказе eog блок памяти остаётся' ($r.Out -match 'Известные анти-паттерны') $r.Out

# ---------------------------------------------------------------------------
Section '3. Схема: поле project и миграция для существующих баз'
# ---------------------------------------------------------------------------
# Контейнер применяет init.sql ровно один раз — при первой инициализации пустого
# каталога данных. Значит одних CREATE TABLE мало: у всех, кто поднял память раньше,
# колонки не появятся никогда, и запись начнёт падать «памятью недоступна».
$sql = [IO.File]::ReadAllText($initSql)
foreach ($t in @('anti_patterns', 'recall_events', 'bugs', 'proposals')) {
    $m = [regex]::Match($sql, "CREATE TABLE IF NOT EXISTS agent_memory\.$t \((.*?)\n\);", 'Singleline')
    Check "в CREATE TABLE $t есть колонка project" ($m.Success -and $m.Groups[1].Value -match '(?m)^\s*project\s+text') 'колонки нет'
    Check "для $t есть миграция ADD COLUMN IF NOT EXISTS project" `
        ($sql -match "ALTER TABLE agent_memory\.$t\s+ADD COLUMN IF NOT EXISTS project text") 'миграции нет'
}
Check 'уникальность предложений расширена проектом' `
    ($sql -match 'CREATE UNIQUE INDEX IF NOT EXISTS proposals_kind_target_project_uidx[\s\S]*?\(kind, target, project\)') 'индекса нет'
Check 'старое ограничение (kind, target) снимается явно' `
    ($sql -match 'DROP CONSTRAINT IF EXISTS proposals_kind_target_key') 'старое ограничение осталось бы и ON CONFLICT упал бы'

# ---------------------------------------------------------------------------
Section '4. Клиент памяти: пишет project, ищет сначала свой проект, потом всю базу'
# ---------------------------------------------------------------------------
# Настоящей базы здесь нет: psycopg подменён и записывает каждый execute в журнал.
# Проверяется не «команда отработала», а ЧТО именно она отправила бы в базу.
$stub = Join-Path $sandbox 'pystub'
Write-Utf8 (Join-Path $stub 'psycopg\__init__.py') @'
import json, os

LOG = os.environ.get("BCF_TEST_SQL_LOG", "")


def _log(rec):
    if not LOG:
        return
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


class OperationalError(Exception):
    pass


class Cursor:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=None):
        self._last = " ".join(str(sql).split())
        _log({"sql": self._last, "params": [repr(p) for p in (params or ())]})

    def fetchone(self):
        return (1, 1)

    def fetchall(self):
        if "FROM agent_memory.anti_patterns" in getattr(self, "_last", ""):
            return [("row-1", "code", "тригер", "что было", "как надо", "чей-то-проект", 0.9)]
        return []


class Connection:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def cursor(self):
        return Cursor()


def connect(**kw):
    _log({"connect": {k: str(v) for k, v in kw.items()}})
    return Connection()
'@
Write-Utf8 (Join-Path $stub 'psycopg\types\__init__.py') ''
Write-Utf8 (Join-Path $stub 'psycopg\types\json.py') @'
class Json:
    def __init__(self, obj):
        self.obj = obj

    def __repr__(self):
        return "Json(%r)" % (self.obj,)
'@
Write-Utf8 (Join-Path $stub 'requests.py') @'
import os


class _Resp:
    def raise_for_status(self):
        pass

    def json(self):
        dim = int(os.environ.get("BCF_TEST_EMBED_DIM", "4"))
        return {"data": [{"embedding": [0.1] * dim}]}


def post(url, json=None, timeout=None):
    return _Resp()
'@

$memProj = Join-Path $sandbox 'demo-project'
New-Item -ItemType Directory -Force -Path (Join-Path $memProj '.bcf') | Out-Null
$memCfg = Join-Path $memProj 'config\memory.config.json'
Write-Utf8 $memCfg (@{
    host = 'localhost'; port = 5433; database = 'db'; user = 'u'
    password_env = 'BCF_PG_PASSWORD'; password_default = 'local_dev'
    embedding_dim = 4; embedding_model = 'stub'; embedding_endpoint = 'http://localhost:1/v1/embeddings'
} | ConvertTo-Json)
# Накладка машины: подобранный порт лежит здесь, а не в конфиге проекта.
Write-Utf8 (Join-Path $memProj '.bcf\memory.local.json') (@{ port = 5599; container = 'demo-mem' } | ConvertTo-Json)

function Invoke-MemClientStub {
    param([string[]]$ClientArgs)
    $log = Join-Path $sandbox ("sql-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".jsonl")
    $prev = @{
        PYTHONPATH = $env:PYTHONPATH; BCF_MEM_CONFIG = $env:BCF_MEM_CONFIG
        BCF_PROJECT_ROOT = $env:BCF_PROJECT_ROOT; BCF_TEST_SQL_LOG = $env:BCF_TEST_SQL_LOG
        PYTHONIOENCODING = $env:PYTHONIOENCODING
    }
    $env:PYTHONPATH = $stub
    $env:BCF_MEM_CONFIG = $memCfg
    $env:BCF_PROJECT_ROOT = $memProj
    $env:BCF_TEST_SQL_LOG = $log
    $env:PYTHONIOENCODING = 'utf-8'
    $out = & $python $memClient @ClientArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($k in $prev.Keys) {
        if ($null -eq $prev[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $prev[$k] }
    }
    $recs = @()
    if (Test-Path $log) {
        foreach ($l in (Get-Content -LiteralPath $log -Encoding UTF8)) {
            if ($l.Trim()) { try { $recs += ($l | ConvertFrom-Json) } catch { } }
        }
    }
    return @{ Out = $out.Trim(); Code = $code; Records = $recs }
}

$up = Invoke-MemClientStub @('upsert', '--json', '{"trigger_summary":"урок","what_went_wrong":"так вышло"}')
$ins = @($up.Records | Where-Object { $_.sql -and $_.sql -match 'INSERT INTO agent_memory.anti_patterns' })
Check 'upsert отработал' ($up.Code -eq 0) $up.Out
Check 'в INSERT анти-паттерна есть колонка project' ($ins.Count -and $ins[0].sql -match '\(project, agent_scope') "SQL: $($ins[0].sql)"
Check 'проектом подставлено имя каталога' ($ins.Count -and (@($ins[0].params) -join ' ') -match 'demo-project') "параметры: $(@($ins[0].params) -join ' ')"

$rc = Invoke-MemClientStub @('recall', '--text', 'слияние упало')
$sel = @($rc.Records | Where-Object { $_.sql -and $_.sql -match 'FROM agent_memory.anti_patterns' })
Check 'recall отработал' ($rc.Code -eq 0) $rc.Out
Check 'первый запрос отзыва ограничен своим проектом' ($sel.Count -ge 1 -and $sel[0].sql -match 'AND project = %s') "SQL: $($sel[0].sql)"
Check 'второй запрос идёт по остальной базе' ($sel.Count -ge 2 -and $sel[1].sql -match 'AND project <> %s') "запросов: $($sel.Count)"
Check 'найденное в первом запросе во второй не попадает' ($sel.Count -ge 2 -and $sel[1].sql -match 'id::text <> ALL') "SQL: $($sel[1].sql)"

$conn = @($rc.Records | Where-Object { $_.connect })
Check 'порт взят из накладки машины, а не из конфига проекта' `
    ($conn.Count -and "$($conn[0].connect.port)" -eq '5599') "порт: $($conn[0].connect.port)"

$mg = Invoke-MemClientStub @('migrate')
$mgSql = (@($mg.Records | Where-Object { $_.sql }) | ForEach-Object { $_.sql }) -join ' '
Check 'команда migrate есть у клиента' ($mg.Code -eq 0) $mg.Out
Check 'migrate применяет миграцию колонки project' ($mgSql -match 'ADD COLUMN IF NOT EXISTS project') 'миграция не отправлена в базу'

# ---------------------------------------------------------------------------
Section '5. Подобранный порт пишется в .bcf, а не в отслеживаемый конфиг'
# ---------------------------------------------------------------------------
# Порт — свойство машины. Пока он писался в config/memory.config.json, у владельца
# появлялся диff, которого он не делал, и коммит увозил номер порта его машины всем.
$portProj = Join-Path $sandbox 'port-project'
$portCfg = Join-Path $portProj 'config\memory.config.json'
Write-Utf8 $portCfg (@{ host = 'localhost'; port = 5433; container = 'bcf-agent-memory' } | ConvertTo-Json)
$before = [IO.File]::ReadAllText($portCfg)

# Подставляем опрос порта: настоящий ходил бы в docker. Функции объявлены ДО загрузки
# memory-port.ps1 — он подтягивает docker.ps1 только если их нет.
function Get-BcfPortHolder { param([int]$Port, [hashtable]$PortMap) return [pscustomobject]@{ Kind = 'container'; Name = 'чужая-база' } }
function Find-BcfFreePort  { param([int]$From) return ($From + 6) }
. (Join-Path $root 'harness\lib\memory-port.ps1')

$pr = Resolve-BcfMemoryPort -Wanted 5433 -Container 'bcf-agent-memory' -ProjectRoot $portProj -HostName 'localhost'
$localFile = Join-Path $portProj '.bcf\memory.local.json'
Check 'порт подобран' ($pr.Changed -and $pr.Port -eq 5440) "порт: $($pr.Port), changed: $($pr.Changed)"
Check 'накладка машины создана в .bcf' (Test-Path $localFile) "нет файла $localFile"
if (Test-Path $localFile) {
    $lj = Get-Content -Raw -LiteralPath $localFile | ConvertFrom-Json
    Check 'в накладке лежит порт и контейнер' ($lj.port -eq 5440 -and $lj.container -eq 'bcf-agent-memory') "$($lj | ConvertTo-Json -Compress)"
}
Check 'отслеживаемый config/memory.config.json не тронут' (([IO.File]::ReadAllText($portCfg)) -eq $before) 'конфиг проекта переписан'

# База на другом хосте — не наш порт: там слушает чужой сервер, подбирать нечего.
$remoteProj = Join-Path $sandbox 'remote-project'
New-Item -ItemType Directory -Force -Path $remoteProj | Out-Null
$pr2 = Resolve-BcfMemoryPort -Wanted 5433 -Container 'bcf-agent-memory' -ProjectRoot $remoteProj -HostName 'db.example.internal'
Check 'для базы на другой машине порт не подбирается' (-not $pr2.Changed) "changed: $($pr2.Changed)"
Check 'и накладка не заводится' (-not (Test-Path (Join-Path $remoteProj '.bcf\memory.local.json'))) 'накладка появилась зря'

# Слитый конфиг: адрес из проекта, порт из накладки машины.
. (Join-Path $root 'harness\lib\memory-config.ps1')
$set = Resolve-BcfMemorySettings -Project $portProj -FactoryMemoryDir (Join-Path $root 'memory')
Check 'резолвер отдаёт порт из накладки' ($set.Port -eq 5440) "порт: $($set.Port)"
Check 'резолвер помечает, что порт местный' ($set.PortFromLocal) 'признак не выставлен'
Check 'адрес сервера берётся из конфига проекта' ($set.Host -eq 'localhost') "host: $($set.Host)"
Check 'localhost считается локальным адресом' ($set.IsLocalHost) 'localhost не признан локальным'

# ---------------------------------------------------------------------------
Section '6. Счётчик слотов агентов — один на установку фабрики'
# ---------------------------------------------------------------------------
# Потолок агентов упирается в rate-limit провайдера, то есть в ресурс, общий для всех
# проектов машины. Проектный счётчик означал двойной перерасход при двух проектах.
. (Join-Path $root 'harness\lib\fleet.ps1')
$defaultRoot = Get-BcfFleetRoot
Check 'по умолчанию реестр лежит в установке фабрики' `
    ($defaultRoot.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) "реестр: $defaultRoot"
Check 'и не внутри проекта' (-not ($defaultRoot -match '(?i)[\\/]port-project[\\/]')) "реестр: $defaultRoot"

$fleetDir = Join-Path $sandbox 'fleet-shared'
$env:BCF_FLEET_DIR = $fleetDir
$projA = Join-Path $sandbox 'fleet-a'
$projB = Join-Path $sandbox 'fleet-b'
New-Item -ItemType Directory -Force -Path $projA, $projB | Out-Null
Register-FleetWorker -Id 'w1' -Role 'code' -Task 'TASK-01' -Project $projA
Register-FleetWorker -Id 'w1' -Role 'code' -Task 'TASK-02' -Project $projB
$all = Get-FleetWorkers -Project $projA
$mine = Get-FleetWorkers -Project $projA -Mine
Check 'слот w1 двух проектов не затирает сам себя' ($all.Count -eq 2) "воркеров: $($all.Count)"
Check 'потолок считает воркеров обоих проектов' (-not (Test-FleetCapacity -MaxAgents 2)) 'потолок 2 не сработал на двух воркерах'
Check 'свои воркеры отделимы от чужих' ($mine.Count -eq 1 -and $mine[0].task -eq 'TASK-01') "своих: $($mine.Count)"
Check 'в .bcf проекта реестр не заводится' (-not (Test-Path (Join-Path $projA '.bcf\fleet'))) 'файлы воркеров легли в проект'
Unregister-FleetWorker -Id 'w1' -Project $projA
Check 'снятие слота убирает только свой файл' ((Get-FleetWorkers -Project $projA).Count -eq 1) 'убрали чужой слот'
Unregister-FleetWorker -Id 'w1' -Project $projB
Remove-Item env:BCF_FLEET_DIR -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section '7. .env.example: все ключи, которые читает обвязка, и ни одного значения'
# ---------------------------------------------------------------------------
# Файл-образец полезен ровно настолько, насколько он полон: ключ, которого в нём нет,
# ищут по исходникам, а найденный со значением копируется в .env как настройка,
# которую никто не выбирал.
Check '.env.example лежит в корне фабрики' (Test-Path $envExample) "нет $envExample"
$exampleLines = @(Get-Content -LiteralPath $envExample -Encoding UTF8)
$declared = @()
foreach ($l in $exampleLines) { if ($l -match '^\s*([A-Z][A-Z0-9_]*)\s*=') { $declared += $Matches[1] } }
$withValue = @($exampleLines | Where-Object { $_ -match '^\s*[A-Z][A-Z0-9_]*\s*=\s*\S' })
Check 'в образце нет ни одного значения' ($withValue.Count -eq 0) ($withValue -join '; ')

# Имена собираем ИЗ ИСХОДНИКОВ, а не списком в тесте: список разошёлся бы с кодом молча.
$scanned = @{}
foreach ($f in (Get-ChildItem -Path (Join-Path $root 'bin'), (Join-Path $root 'src'), (Join-Path $root 'harness'),
                              (Join-Path $root 'templates'), (Join-Path $root 'memory') -Recurse -File -ErrorAction SilentlyContinue)) {
    $text = ''
    try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    $pats = switch ($f.Extension) {
        '.ps1' { @('\$env:([A-Z][A-Z0-9_]*)') }
        '.sh'  { @('\$\{([A-Z][A-Z0-9_]*):-') }
        '.py'  { @('os\.environ(?:\.get)?[\(\[]"([A-Z][A-Z0-9_]*)"') }
        default { @() }
    }
    foreach ($pat in $pats) {
        foreach ($m in [regex]::Matches($text, $pat)) {
            $n = $m.Groups[1].Value
            if ($n -match '^(BCF_|MEMORY_|EOG_)') { $scanned[$n] = $true }
        }
    }
}
$missing = @($scanned.Keys | Where-Object { $declared -notcontains $_ } | Sort-Object)
Check "все ключи обвязки объявлены в образце (нашлось $($scanned.Count))" ($missing.Count -eq 0) ("нет в .env.example: " + ($missing -join ', '))
$ghost = @($declared | Where-Object { $_ -match '^(BCF_|MEMORY_|EOG_)' -and -not $scanned.ContainsKey($_) } | Sort-Object)
Check 'в образце нет ключей, которых обвязка не читает' ($ghost.Count -eq 0) ("лишние: " + ($ghost -join ', '))

# ---------------------------------------------------------------------------
Section '8. Пароль по умолчанию на сетевом адресе: init отказывается, doctor предупреждает'
# ---------------------------------------------------------------------------
# Пароль в конфиге не секрет и заведён для контейнера на этой же машине. На сетевом
# адресе он означает базу, которую открывает любой, кто видел исходники, — а команда
# при этом отчитывается об успешном подключении.
function New-RemoteMemFixture {
    param([string]$Name, [string]$HostName = 'db.example.internal', [string]$PwDefault = 'bcf_local_dev')
    $p = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'config') | Out-Null
    & git -C $p init -q 2>&1 | Out-Null
    Write-Utf8 (Join-Path $p 'config\memory.config.json') (@{
        host = $HostName; port = 5433; database = 'db'; user = 'u'
        password_env = 'BCF_PG_PASSWORD'; password_default = $PwDefault
        embedding_dim = 4; embedding_model = 'stub'; embedding_endpoint = 'http://localhost:1/v1/embeddings'
    } | ConvertTo-Json)
    Write-Utf8 (Join-Path $p 'config\harness.json') (@{
        productPaths = @('src'); features = @{ memory = $true }
    } | ConvertTo-Json -Depth 5)
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src') | Out-Null
    return $p
}
function Bcf {
    param([string[]]$CliArgs, [hashtable]$Env = @{})
    $prev = @{}
    foreach ($k in $Env.Keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $Env[$k] }
    $out = & pwsh -NoProfile -File $bcf @CliArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($k in $prev.Keys) {
        if ($null -eq $prev[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $prev[$k] }
    }
    return @{ Out = $out; Code = $code }
}

$remote = New-RemoteMemFixture -Name 'mem-remote'
$r = Bcf @('memory', 'init', '--project', $remote)
Check 'bcf memory init отказывается от пароля по умолчанию на сетевом адресе' `
    ($r.Code -ne 0 -and $r.Out -match 'пароль') "код $($r.Code): $($r.Out)"
Check 'отказ называет адрес базы' ($r.Out -match 'db\.example\.internal') $r.Out
Check 'отказ случается ДО работы с docker' (-not ($r.Out -match 'демон не отвечает|docker не найден')) $r.Out

# С настоящим паролем отказа быть не должно — иначе проверка запрещала бы сетевую базу.
$r = Bcf @('memory', 'init', '--project', $remote) -Env @{ BCF_PG_PASSWORD = 'настоящий-пароль' }
Check 'с заданным паролем init идёт дальше проверки' (-not ($r.Out -match 'пароль — тот, что лежит в репозитории')) $r.Out

$r = Bcf @('doctor', '--no-probe', '--project', $remote) -Env @{ BCF_AUTH_TIMEOUT_SEC = '2' }
Check 'bcf doctor предупреждает о пароле по умолчанию на нелокальном хосте' `
    ($r.Out -match 'пароль — дефолтный из репозитория') $r.Out
Check 'doctor называет раздел ключей окружения' ($r.Out -match 'КЛЮЧИ ОКРУЖЕНИЯ') $r.Out

# Локальная база с тем же паролем — законное состояние, ругаться не на что.
$localMem = New-RemoteMemFixture -Name 'mem-local' -HostName 'localhost'
$r = Bcf @('doctor', '--no-probe', '--project', $localMem) -Env @{ BCF_AUTH_TIMEOUT_SEC = '2' }
Check 'на localhost дефолтный пароль не считается дефектом' `
    (-not ($r.Out -match 'пароль — дефолтный из репозитория')) $r.Out

# ---------------------------------------------------------------------------
Section '9. doctor: роль без ключа названа заранее'
# ---------------------------------------------------------------------------
# Субагент ходит к модели напрямую и без ключа получает отказ авторизации. Обвязка
# видит пустой ответ и пишет «субагент ничего не нашёл» — гейты при этом зелёные.
$keyProj = New-RemoteMemFixture -Name 'keys-missing' -HostName 'localhost'
$binDir = Join-Path $keyProj '.claude\agents\bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Set-Content -LiteralPath (Join-Path $binDir 'invoke-retrospector.ps1') -Value '# заглушка роли' -Encoding UTF8
$r = Bcf @('doctor', '--no-probe', '--project', $keyProj) -Env @{ BCF_AUTH_TIMEOUT_SEC = '2'; BCF_API_KEY = ''; BCF_RETROSPECTOR_API_KEY = '' }
Check 'doctor называет роль без ключа' ($r.Out -match 'ролей без ключа') $r.Out
Check 'и называет саму роль' ($r.Out -match 'invoke-retrospector\.ps1') $r.Out

# Ключ в .env проекта — там же, откуда его возьмёт сам вызывающий скрипт.
Write-Utf8 (Join-Path $keyProj '.env') "BCF_API_KEY=ключ-для-теста`n"
$r = Bcf @('doctor', '--no-probe', '--project', $keyProj) -Env @{ BCF_AUTH_TIMEOUT_SEC = '2' }
Check 'ключ из .env проекта засчитывается' (-not ($r.Out -match 'ролей без ключа')) $r.Out

# ---------------------------------------------------------------------------
Restore-TestEnv
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  ИТОГ: прошло $($script:Pass), провалено $($script:Fail)") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Fail) { exit 1 }
exit 0
