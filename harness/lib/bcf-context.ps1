# bcf-context.ps1 — кто такой «корень» для харнесса.
#
# Движок (этот каталог) живёт в фабрике и НЕ копируется в проект. Проект, над которым
# идёт работа, задаётся снаружи: `bcf` выставляет BCF_PROJECT_ROOT перед запуском любого
# скрипта харнесса. Без этой переменной скрипты остаются работоспособными вручную —
# корнем становится верх git-репозитория текущего каталога.
#
# Разделение нужно ровно за тем, чтобы одна установка фабрики обслуживала любое число
# проектов, а состояние прогонов не смешивалось: всё, что харнесс пишет во время работы,
# уходит в <проект>/.bcf/ и целиком принадлежит проекту.

function Get-BcfProjectRoot {
    param([string]$Explicit = '')

    if ($Explicit) {
        $p = (Resolve-Path -LiteralPath $Explicit -ErrorAction SilentlyContinue)
        if ($p) { return $p.Path }
        return $Explicit.TrimEnd('\', '/')
    }
    if ($env:BCF_PROJECT_ROOT) { return $env:BCF_PROJECT_ROOT.TrimEnd('\', '/') }

    $top = ''
    try { $top = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim() } catch { }
    if ($top) { return ($top -replace '/', [IO.Path]::DirectorySeparatorChar) }

    return (Get-Location).Path
}

# Каталог состояния прогонов. Создаётся по требованию: скрипты, которые только читают,
# не должны оставлять после себя пустую папку в чужом проекте.
function Get-BcfStateDir {
    param([string]$Root = '', [switch]$NoCreate)

    if (-not $Root) { $Root = Get-BcfProjectRoot }
    $d = Join-Path $Root '.bcf'
    if (-not $NoCreate) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

# Чьим именем харнесс коммитит.
#
# ПОРЯДОК: `author.name`/`author.email` из config/harness.json (явная воля владельца
# проекта — тот, кем должны подписываться коммиты фабрики, независимо от того, что
# настроено в самом git) → user.name/user.email репозитория (пустой массив: коммит
# заявки, слияния или отката читается как коммит участника, а не инструмента) →
# `bcf`/`bcf@local` там, где иначе git откажется коммитить вовсе — на голой фикстуре и
# на машине без глобальной настройки.
function Get-BcfGitIdentityArgs {
    param([Parameter(Mandatory)][string]$Root)
    $cfgN = ''; $cfgE = ''
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.author -and $cfg.author.name)  { $cfgN = "$($cfg.author.name)".Trim() }
            if ($cfg.author -and $cfg.author.email) { $cfgE = "$($cfg.author.email)".Trim() }
        }
    } catch { }
    if ($cfgN -and $cfgE) { return @('-c', "user.name=$cfgN", '-c', "user.email=$cfgE") }

    $n = ''; $e = ''
    try { $n = (& git -C $Root config user.name 2>$null | Out-String).Trim() } catch { }
    try { $e = (& git -C $Root config user.email 2>$null | Out-String).Trim() } catch { }
    if ($n -and $e) { return @() }
    return @('-c', 'user.name=bcf', '-c', 'user.email=bcf@local')
}

# --- ТРЕЙЛЕРЫ КОММИТОВ ПРОГОНА -----------------------------------------------------------
#
# ЗАЧЕМ. Коммит «TASK-07: работа агента» сам по себе не говорит, КАКОЙ прогон его сделал,
# какой ролью узла и на какой модели/бэкенде: журнал прогона (.bcf/graph/<runId>/) живёт
# рядом с состоянием и не переживает уборку `.bcf/`, а коммит в git остаётся навсегда.
# Пять полей — минимум, достаточный чтобы восстановить обстоятельства коммита БЕЗ
# журнала, когда разбор дефекта идёт спустя месяцы по одному только `git log`.
#
# Живут здесь, а не в worktree.ps1 (где появились первыми): claims.ps1 тоже коммитит от
# имени прогона (заявка на файлы, снятие заявки, приёмка лидером) и не дот-сорсит
# worktree.ps1 — только наоборот. bcf-context.ps1 — общий предок обоих файлов.
function Format-BcfCommitTrailers {
    param(
        [string]$Task = '', [string]$RunId = '', [string]$Role = '',
        [string]$Model = '', [string]$Backend = ''
    )
    return @(
        "Task: $Task"
        "Run-Id: $RunId"
        "Role: $Role"
        "Model: $Model"
        "Backend: $Backend"
    ) -join "`n"
}

function New-BcfCommitMessage {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Task = '', [string]$RunId = '', [string]$Role = '',
        [string]$Model = '', [string]$Backend = ''
    )
    $trailers = Format-BcfCommitTrailers -Task $Task -RunId $RunId -Role $Role -Model $Model -Backend $Backend
    return "$Subject`n`n$trailers"
}

# Проверка ОБРАТНАЯ построению: сообщение обязано нести все пять трейлеров строкой
# «Ключ: значение» — значение может быть пустым (бэкенд без роли, модель не сообщена),
# важно само наличие ключа. Разбор дефекта, идущий по `git log`, не имеет права
# наткнуться на коммит прогона без опознавательных полей — тогда узнать, чем он сделан,
# можно только гадая.
function Test-BcfCommitTrailers {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    $required = @('Task', 'Run-Id', 'Role', 'Model', 'Backend')
    $missing = @()
    foreach ($k in $required) {
        if ($Message -notmatch "(?m)^$([regex]::Escape($k)):[ \t]?") { $missing += $k }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

# То же самое, но на НАСТОЯЩЕМ коммите git, по sha — доказывает, что конкретный коммит
# прогона несёт трейлеры, а не только что билдер их умеет строить.
function Test-BcfCommitHasTrailers {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sha)
    $msg = (& git -C $Root log -1 --format=%B $Sha 2>$null | Out-String)
    return (Test-BcfCommitTrailers -Message $msg)
}

# Версия фабрики — печатается в каждый вердикт (factory_version:), чтобы разбор дефекта
# видел, каким движком задача была проверена. Не полагаемся на src/lib/paths.ps1
# (CLI-слой): harness обязан работать и без него, при ручном запуске verify.ps1.
function Get-BcfFactoryVersion {
    $f = Join-Path (Get-BcfHomeRoot) 'VERSION'
    if (Test-Path -LiteralPath $f) { return (Get-Content -Raw -LiteralPath $f).Trim() }
    return '0.0.0-dev'
}

# Короткий отпечаток содержимого файла — 12 hex-символов sha256, тот же формат, что уже
# используют межпроцессные замки доски задач. Пустая строка — файла нет, путь пуст или
# не прочитался: вызывающий решает, что это значит для него самого (для графа — «прогон
# шёл не по графу, хэшировать нечего»).
function Get-BcfFileHash {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower().Substring(0, 12)
    } catch { return '' }
}

# Корень движка (фабрика/harness). Нужен, когда узел графа или планировщик запускает
# другой скрипт харнесса: путь до него не выводится из корня проекта.
function Get-BcfHarnessRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

# Корень установки фабрики (родитель harness/) — там лежат templates/, meta/, memory/.
function Get-BcfHomeRoot {
    if ($env:BCF_HOME) { return $env:BCF_HOME.TrimEnd('\', '/') }
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

# Bash Git for Windows по git --exec-path — работает независимо от того, КУДА его
# поставили: exec-path у git-core всегда лежит внутри установки Git, и bash.exe
# гарантированно рядом. Известные каталоги (ProgramFiles и т.п.) ловят только
# стандартные пути установщика; portable-git, scoop, диск не C: — мимо них.
#
# Раскладка Git for Windows: <root>\mingw64\libexec\git-core — это и есть exec-path,
# bash лежит в <root>\bin\bash.exe (шим) либо <root>\usr\bin\bash.exe (настоящий).
# Проверено на этой машине: exec-path = C:\Program Files\Git\mingw64\libexec\git-core,
# оба bash.exe на месте.
function Get-BcfGitForWindowsBash {
    $execPath = ''
    try { $execPath = (& git --exec-path 2>$null | Out-String).Trim() } catch { }
    if (-not $execPath) { return '' }

    # git-core -> libexec -> mingw64 -> корень установки Git.
    $root = Split-Path (Split-Path (Split-Path $execPath -Parent) -Parent) -Parent
    if (-not $root) { return '' }
    foreach ($rel in @('bin\bash.exe', 'usr\bin\bash.exe')) {
        $c = Join-Path $root $rel
        if (Test-Path $c) { return $c }
    }
    return ''
}

# Две строки для шапки вердикта и отчёта. Граф передаёт путь к своему скрипту через
# BCF_GRAPH_FILE; когда задача шла циклом, а не графом, это так и сказано — пустая
# строка читалась бы как «граф был, но не записался».
function Get-BcfProvenanceLines {
    param([string]$GraphFile = '')
    $gf = if ($GraphFile) { $GraphFile } else { [string]$env:BCF_GRAPH_FILE }
    $hash = Get-BcfFileHash -Path $gf
    $graphLine = if ($hash) { "$hash ($(Split-Path $gf -Leaf))" } else { 'нет (прогон без графа)' }
    return @("factory_version: $(Get-BcfFactoryVersion)", "graph_hash: $graphLine")
}

# Какой bash звать под Windows.
#
# `bash` из PATH — НЕ тот, о котором думает автор хука. Первым там обычно стоит
# C:\Windows\System32\bash.exe — это лаунчер WSL, а не POSIX-оболочка для репозитория.
# Если дистрибутив ещё не инициализирован, первый запуск уходит в интерактивную настройку
# («Enter new UNIX username:») и блокируется на stdin — цикл встаёт МЕЖДУ итерациями
# навсегда, не напечатав ни строки. Если дистрибутива нет вовсе, он возвращает ненулевой
# код, и хук выглядит провалившимся, хотя не запускался.
#
# Порядок: BCF_BASH (явная воля владельца) → git --exec-path (Git for Windows, любое
# место установки) → известные каталоги (ProgramFiles и т.п.) → любой bash из PATH,
# кроме WSL.
#
# BCF_BASH_FORCE_NOT_FOUND=1 — имитация «bash нигде нет» для тестов install/init. Не
# заменить обычным сокрытием ProgramFiles/ProgramFiles(x86): для НОВОГО процесса Windows
# сама переподставляет эти две переменные по факту системных путей при создании процесса
# — родительский override пропадает ровно на границе CreateProcess, а не раньше (проверено
# 2026-09-05: тот же скрипт в этом же процессе видит переопределение, а дочерний pwsh —
# уже нет). Тот же приём, что BCF_GRAPH_FAKE_AGENT для графа: явный, поимённый, не
# перепутать со случайным состоянием окружения.
function Get-BcfBash {
    if ($env:BCF_BASH_FORCE_NOT_FOUND -eq '1') { return '' }
    if ($env:BCF_BASH -and (Test-Path $env:BCF_BASH)) { return $env:BCF_BASH }

    $viaExecPath = Get-BcfGitForWindowsBash
    if ($viaExecPath) { return $viaExecPath }

    foreach ($c in @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )) {
        if ($c -and (Test-Path $c)) { return $c }
    }

    foreach ($cmd in @(Get-Command bash -All -ErrorAction SilentlyContinue)) {
        $src = [string]$cmd.Source
        if (-not $src) { continue }
        if ($src -match '(?i)\\Windows\\(System32|SysWOW64)\\bash\.exe$') { continue }   # это WSL
        return $src
    }
    return ''
}
