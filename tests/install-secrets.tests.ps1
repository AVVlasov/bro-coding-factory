# install-secrets.tests.ps1 — bash в settings.json, git-хук pre-commit и сканер секретов.
#
#   pwsh tests/install-secrets.tests.ps1
#
# ЧТО ЭТИ ТЕСТЫ ЛОВЯТ.
#
#   · settings.json с голым 'bash' — на Windows это чаще лаунчер WSL, а не Git Bash: хук
#     виснет на неинициализированном дистрибутиве или падает молча, и вся проводка
#     хуков (деструктивные команды, защита обвязки, DoD) перестаёт работать без единой
#     видимой ошибки на установке.
#   · bash не найден — install не должен ни притвориться, что всё поставилось (записать
#     settings.json с той же голой командой), ни уронить ВЕСЬ install: config/, hooks/,
#     skills/, git-хук секретов не зависят от bash и обязаны встать на место, а `bcf init`,
#     который зовёт install подпроцессом и следующим шагом читает config/harness.json, не
#     должен упасть необработанным исключением на файле, которого internal install не
#     написал совсем по другой причине.
#   · секрет, попавший в индекс настоящего `git commit` — тот же класс, что утечка в
#     публичный репозиторий: коммит обязан заблокироваться раньше, чем секрет уедет в
#     историю git, а сам секрет не должен попасть даже в текст отказа.
#   · свой несекретный дефолт (`password_default` в config/memory.config.json) не должен
#     стать вечно красным гейтом — иначе первый же коммит, задевающий этот файл, встаёт.
#
# СМЕНА АРХИТЕКТУРЫ (2026-09-06, см. docs/ROADMAP.md M-05a). До этой правки сканер жил в
# `.claude/hooks/secret-scan.sh` и сам разбирал командную строку `git commit`, чтобы
# угадать будущий индекс — `-a`/`-am`/`--all`, `git add && git commit` одной строкой, `cd`
# перед `add`, pathspec внутри `commit` каждый раз были новым обходом, потому что разбор
# командной строки не закрыть в принципе. Теперь единственный сканер — настоящий git-хук
# `.githooks/pre-commit`: git вызывает его сам, уже ПОСЛЕ того, как разрешил любой способ
# стажирования, и раздел 8 и далее проверяют это НАСТОЯЩИМИ `git commit` во временном
# репозитории с установленным хуком — не симуляцией разбора командной строки.
#
# Ни сети, ни моделей: хук — запуск в Git Bash на фикстуре, install/init — прямой прогон
# CLI фабрики во временных песочницах. «bash не найден» СКВОЗЬ ПРОЦЕСС install
# симулируется через BCF_BASH_FORCE_NOT_FOUND (Get-BcfBash), а не через сокрытие
# ProgramFiles/ProgramFiles(x86) в окружении: для НОВОГО процесса Windows сама
# переподставляет эти две переменные системными путями при создании процесса, и override
# родителя до дочернего pwsh не доезжает (см. секцию 3 и комментарий у Get-BcfBash) —
# приоритет "git --exec-path перед известными каталогами" поэтому проверяется юнит-вызовом
# функции в этом же процессе, а не через вложенный pwsh. «python не найден» на хуке
# симулируется вычищением python/PyManager/WindowsApps-шима из PATH перед вызовом
# (проверено вручную: Git Bash подставляет собственные mingw64/bin/usr/bin впереди любого
# унаследованного PATH, так что git остаётся резолвящимся, а python — нет).

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$root          = Split-Path $PSScriptRoot -Parent
$bcf           = Join-Path $root 'bin\bcf.ps1'
$sandbox       = Join-Path ([IO.Path]::GetTempPath()) ("bcf-installsec-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
    Write-Host 'Git Bash не найден — хук прогнать нечем. Пропуск считался бы зелёным прогоном при' -ForegroundColor Red
    Write-Host 'непроверенном хуке, поэтому это ПРОВАЛ.' -ForegroundColor Red
    exit 1
}
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { $python = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $python) {
    Write-Host 'python не найден — секретный сканер прогнать нечем. ПРОВАЛ.' -ForegroundColor Red
    exit 1
}

# ПОЛНЫЕ ПУТИ ДО ЛЮБОЙ ПОДМЕНЫ PATH. Сценарии «bash/python не найден» подменяют PATH
# дочернему процессу — если сам pwsh или git резолвятся по голому имени ПОСЛЕ подмены,
# тест ломает то, чем сам же пользуется, а не то, что должен проверить.
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) {
    Write-Host 'pwsh не найден полным путём — сценарии со скрытым PATH прогнать нечем. ПРОВАЛ.' -ForegroundColor Red
    exit 1
}
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe) {
    Write-Host 'git не найден полным путём — фикстуры и сценарий "bash не найден" прогнать нечем. ПРОВАЛ.' -ForegroundColor Red
    exit 1
}
$gitBinDir = Split-Path $gitExe -Parent

New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
Write-Host ''
Write-Host "  BASH, GIT-ХУК СЕКРЕТОВ И НАСТОЯЩИЕ GIT COMMIT   песочница: $sandbox" -ForegroundColor Cyan

function Bcf {
    param([string[]]$CliArgs, [hashtable]$Env = @{})
    $prev = @{}
    foreach ($k in $Env.Keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $Env[$k] }
    $out = & $pwshExe -NoProfile -File $bcf @CliArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($k in $prev.Keys) {
        if ($null -eq $prev[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $prev[$k] }
    }
    return [pscustomobject]@{ Out = $out; Code = $code }
}

function New-GitFixture {
    param([string]$Name)
    $p = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & $gitExe -C $p init -q 2>&1 | Out-Null
    & $gitExe -C $p config user.email 't@local' 2>&1 | Out-Null
    & $gitExe -C $p config user.name 't' 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'README.md') -Value '# fixture' -Encoding UTF8
    & $gitExe -C $p add -A 2>&1 | Out-Null
    & $gitExe -C $p commit -qm init 2>&1 | Out-Null
    return $p
}

# Фикстура + настоящий `bcf install` поверх нeё: единственный способ получить
# `.githooks/pre-commit` реально включённым (core.hooksPath = .githooks), тем же кодом,
# которым его получает владелец проекта — не ручной копией шаблона в обход install.
function New-HookedFixture {
    param([string]$Name)
    $p = New-GitFixture $Name
    $installResult = Bcf @('install', '--project', $p)
    return [pscustomobject]@{ Path = $p; Install = $installResult }
}

# Настоящий `git commit` (в т.ч. составной, с `&&`) в Git Bash — не симуляция хука, а
# именно то, что запускает Claude Code/человек. env:PATH временно урезается сценарием
# «python не найден»; остальные переменные — точечные (BCF_SECRET_SCAN_DISABLED и т.п.).
function Invoke-RealCommit {
    param([string]$ProjectDir, [string]$Command, [hashtable]$Env = @{})
    $prev = @{}
    foreach ($k in $Env.Keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $Env[$k] }
    Push-Location $ProjectDir
    try {
        $out = & $bash -c $Command 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in $prev.Keys) {
            if ($null -eq $prev[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $prev[$k] }
        }
    }
    return [pscustomobject]@{ Out = $out; Code = $code }
}

# Откатывает фикстуру к заведомо чистому коммиту между сценариями — дешевле, чем отдельная
# фикстура (со своим `bcf install`, ~0.8с) на каждый из полутора десятков сценариев ниже,
# и так же надёжно: каждый сценарий стартует с одного и того же известного состояния.
function Reset-Fixture {
    param([string]$ProjectDir, [string]$Sha)
    & $gitExe -C $ProjectDir reset --hard $Sha 2>&1 | Out-Null
    & $gitExe -C $ProjectDir clean -fd 2>&1 | Out-Null   # без -x: .bcf/ игнорируется .gitignore и не трогается
}

# Вызов `.claude/hooks/secret-scan.sh` напрямую (как это делает Claude Code: JSON во
# stdin) — для проверки ТОНКОГО ПРЕДВАРИТЕЛЬНОГО вызова (разделы 19-21), не для проверки
# самого сканирования (это разделы 8-18 через настоящий git commit).
function Invoke-ClaudeHookWrapper {
    param([string]$ProjectDir, [string]$Command)
    $payload = (@{ tool_input = @{ command = $Command } } | ConvertTo-Json -Compress)
    $pf = Join-Path $sandbox ('hook-in-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Set-Content -LiteralPath $pf -Value $payload -Encoding UTF8 -NoNewline
    $prev = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    try {
        $sh = (Join-Path $root 'templates\claude\hooks\secret-scan.sh') -replace '\\', '/'
        $inp = ($pf -replace '\\', '/')
        $out = (& $bash -c "'$sh' < '$inp'" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prev }
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Code = $code; Out = $out }
}

# Окружение поиска bash подчищаем сами: BCF_BASH, случайно выставленный снаружи, сделал бы
# сценарий "не найден" зелёным по чужой причине.
$savedEnv = @{}
foreach ($n in @('BCF_BASH', 'BCF_BASH_FORCE_NOT_FOUND', 'PATH', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) {
    $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}
function Restore-TestEnv {
    foreach ($n in $savedEnv.Keys) {
        if ($null -eq $savedEnv[$n]) { Remove-Item "env:$n" -ErrorAction SilentlyContinue } else { Set-Item "env:$n" $savedEnv[$n] }
    }
}

# ---------------------------------------------------------------------------
Section '1. Обычный install: settings.json получает полный путь к bash, git-хук секретов включён'
# ---------------------------------------------------------------------------
$p1 = New-GitFixture 'install-normal'
$r1 = Bcf @('install', '--project', $p1)
Check 'install отработал зелёным' ($r1.Code -eq 0) "код $($r1.Code): $($r1.Out)"

$settings1 = Join-Path $p1 '.claude\settings.json'
Check 'settings.json записан' (Test-Path $settings1)
if (Test-Path $settings1) {
    $txt1 = Get-Content -Raw -LiteralPath $settings1
    Check 'плейсхолдер {{BASH_PATH}} не остался' ($txt1 -notmatch '\{\{BASH_PATH\}\}') $txt1
    Check 'команда хука — не голый "bash"' ($txt1 -notmatch '"command":\s*"bash ') $txt1

    # Через ConvertFrom-Json, а не регэксп по сырому тексту: сырой текст хранит
    # экранированные кавычки вокруг пути (\"...\"), и регэксп на "не-кавычку" рвётся на
    # первой же \" — ровно та ловушка, из-за которой дефект без кавычек прошёл прошлый
    # прогон незамеченным.
    $settingsObj1 = $txt1 | ConvertFrom-Json
    $guardCmd1 = $settingsObj1.hooks.PreToolUse[0].hooks[0].command
    $scanCmd1  = $settingsObj1.hooks.PreToolUse[0].hooks[1].command
    Check 'pre-bash-guard: команда хука — существующий bash.exe' ($guardCmd1 -match 'bash\.exe') $guardCmd1
    Check 'путь к bash.exe обёрнут в кавычки (пробел в "Program Files" не рвёт команду)' (
        $guardCmd1 -match '^"[^"]*bash\.exe"\s'
    ) $guardCmd1
    if ($guardCmd1 -match '^"([^"]*bash\.exe)"\s') {
        Check 'путь из settings.json реально существует' (Test-Path -LiteralPath ($Matches[1] -replace '/', '\'))
    }
    Check 'secret-scan.sh подключён рядом с pre-bash-guard' ($txt1 -match 'secret-scan\.sh') $txt1
    Check 'secret-scan: путь к bash.exe тоже обёрнут в кавычки' ($scanCmd1 -match '^"[^"]*bash\.exe"\s') $scanCmd1

    # РЕАЛЬНЫЙ ЗАПУСК, а не догадка по строке: именно эта команда, слово в слово, уйдёт
    # оболочке (Claude Code на Windows отдаёт command Git Bash; путь к settings.json может
    # читать и обычный Windows-шелл). Пустой stdin — pre-bash-guard.sh на пустом
    # tool_input.command молча выходит 0 (см. сам хук: command="" => exit 0), поэтому
    # exit 0 здесь означает «команда СТАРТОВАЛА и отработала», а не «повезло с содержимым».
    # На пути установки Git по умолчанию (с пробелом в "Program Files") дефект без кавычек
    # ломает это ИМЕННО здесь: cmd.exe возвращает 1 («'C:/Program' is not recognized»),
    # Git Bash — 127 («C:/Program: No such file or directory»).
    Push-Location $p1
    try {
        $viaCmd = '' | & cmd.exe /c $guardCmd1 2>&1 | Out-String
        $viaCmdCode = $LASTEXITCODE
        Check 'команда хука реально запускается через cmd.exe (exit 0, без ошибки поиска команды)' (
            $viaCmdCode -eq 0 -and $viaCmd -notmatch 'is not recognized'
        ) "код $viaCmdCode : $viaCmd"

        $viaBash = '' | & $bash -c $guardCmd1 2>&1 | Out-String
        $viaBashCode = $LASTEXITCODE
        Check 'команда хука реально запускается через Git Bash (exit 0, без "No such file")' (
            $viaBashCode -eq 0 -and $viaBash -notmatch 'No such file'
        ) "код $viaBashCode : $viaBash"
    } finally { Pop-Location }
}

# Git-хук секретов — независимая от bash часть install (см. docs/ROADMAP.md M-05a):
# .githooks/pre-commit версионируемый, core.hooksPath активирует его на этой машине.
Check '.githooks/pre-commit поставлен' (Test-Path (Join-Path $p1 '.githooks\pre-commit'))
Check 'core.hooksPath указывает на .githooks' (
    (& $gitExe -C $p1 config --get core.hooksPath) -eq '.githooks'
)

# ---------------------------------------------------------------------------
Section '2. bash не найден вообще: install отказывается писать settings.json с голым bash'
# ---------------------------------------------------------------------------
# BCF_BASH_FORCE_NOT_FOUND, а не сокрытие ProgramFiles/ProgramFiles(x86) через окружение
# ДОЧЕРНЕГО процесса: Windows сама переподставляет эти две переменные системными путями
# при создании НОВОГО процесса — override родителя пропадает ровно на границе
# CreateProcess (см. комментарий у Get-BcfBash в harness/lib/bcf-context.ps1), и install,
# запущенный вложенным pwsh, всё равно нашёл бы настоящий Git Bash на этой же машине.
$noBashEnv = @{ BCF_BASH = ''; BCF_BASH_FORCE_NOT_FOUND = '1' }

$p2 = New-GitFixture 'install-refuse-01'
$r2 = Bcf @('install', '--project', $p2) -Env $noBashEnv
Check 'install отказывает ненулевым кодом' ($r2.Code -ne 0) "код $($r2.Code)"
Check 'отказ называет причину (Git Bash не найден)' ($r2.Out -match 'Git Bash не найден') $r2.Out
Check 'отказ говорит, куда положить bash' ($r2.Out -match 'git-scm\.com|BCF_BASH') $r2.Out

$settings2 = Join-Path $p2 '.claude\settings.json'
Check 'settings.json НЕ записан' (-not (Test-Path $settings2))
Check 'хуки при этом поставлены (не зависят от bash)' (Test-Path (Join-Path $p2 '.claude\hooks\secret-scan.sh'))
Check 'config поставлен (init не упадёт на его отсутствии)' (Test-Path (Join-Path $p2 'config\harness.json'))
Check 'CLAUDE.md поставлен' (Test-Path (Join-Path $p2 'CLAUDE.md'))
# Git-хук секретов вообще не зависит от bash (это git, а не Claude Code) — обязан встать
# и включиться, даже когда settings.json не поставлен из-за отсутствующего Git Bash.
Check '.githooks/pre-commit поставлен, несмотря на отказ bash' (Test-Path (Join-Path $p2 '.githooks\pre-commit'))
Check 'core.hooksPath включён, несмотря на отказ bash' (
    (& $gitExe -C $p2 config --get core.hooksPath) -eq '.githooks'
)

# Повторный install --force тоже не имеет права родить settings.json с голым bash.
$r2b = Bcf @('install', '--project', $p2, '--force') -Env $noBashEnv
Check '--force тоже отказывает, а не пишет голый bash' ($r2b.Code -ne 0 -and -not (Test-Path $settings2)) "код $($r2b.Code)"

# ---------------------------------------------------------------------------
Section '3. git --exec-path сам находит Git Bash — без известных каталогов установки'
# ---------------------------------------------------------------------------
# Юнит-уровень, В ЭТОМ ЖЕ ПРОЦЕССЕ (не вложенным pwsh) — ровно по той же причине, что и
# выше: только внутри одного процесса override ProgramFiles/ProgramFiles(x86)/LOCALAPPDATA
# реально виден коду, который их читает. Прячем известные каталоги, оставляем в PATH
# ТОЛЬКО каталог git.exe (без bash.exe — проверено при формировании $gitBinDir выше), и
# единственный путь к успеху — резолв через git --exec-path.
. (Join-Path $root 'harness\lib\bcf-context.ps1')

$scratchDirs = Join-Path $sandbox 'no-programs'
New-Item -ItemType Directory -Force -Path $scratchDirs | Out-Null

$unitSaved = @{}
foreach ($n in @('BCF_BASH', 'BCF_BASH_FORCE_NOT_FOUND', 'PATH', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) {
    $unitSaved[$n] = [Environment]::GetEnvironmentVariable($n)
}
try {
    Remove-Item env:BCF_BASH -ErrorAction SilentlyContinue
    Remove-Item env:BCF_BASH_FORCE_NOT_FOUND -ErrorAction SilentlyContinue
    $env:PATH = $gitBinDir
    $env:ProgramFiles = $scratchDirs
    Set-Item 'env:ProgramFiles(x86)' $scratchDirs
    $env:LOCALAPPDATA = $scratchDirs

    $viaExecPath = Get-BcfBash
    Check 'известные каталоги действительно скрыты (контроль сценария)' (
        -not (Test-Path (Join-Path $scratchDirs 'Git\bin\bash.exe'))
    )
    Check 'Get-BcfBash находит bash через git --exec-path без известных каталогов' (
        $viaExecPath -and (Test-Path -LiteralPath $viaExecPath) -and ($viaExecPath -notlike "$scratchDirs*")
    ) "вернулось: [$viaExecPath]"
} finally {
    foreach ($n in $unitSaved.Keys) {
        if ($null -eq $unitSaved[$n]) { Remove-Item "env:$n" -ErrorAction SilentlyContinue } else { Set-Item "env:$n" $unitSaved[$n] }
    }
}

# Тот же порядок — сквозь настоящий install (отдельным процессом, на реальном окружении
# машины: здесь ProgramFiles скрыть нельзя, но и не нужно — просто убеждаемся, что
# settings.json получает существующий bash.exe, а не {{BASH_PATH}}/голое имя).
$p3 = New-GitFixture 'install-exec-path-e2e'
$r3 = Bcf @('install', '--project', $p3)
Check 'install (полноценное окружение) отработал зелёным' ($r3.Code -eq 0) "код $($r3.Code): $($r3.Out)"
$settings3 = Join-Path $p3 '.claude\settings.json'
# Через ConvertFrom-Json — тот же приём, что в разделе 1. Регэксп на "не-кавычку" по сырому
# тексту рвётся на экранированной кавычке вокруг {{BASH_PATH}} (\"...\") и даёт ложный
# провал даже при верно подставленном пути.
$guardCmd3 = if (Test-Path $settings3) {
    (Get-Content -Raw -LiteralPath $settings3 | ConvertFrom-Json).hooks.PreToolUse[0].hooks[0].command
} else { '' }
Check 'settings.json записан с реальным путём к bash' (
    $guardCmd3 -match '^"[^"]*bash\.exe"\s'
) $guardCmd3

# ---------------------------------------------------------------------------
Section '4. bcf init переживает отказ bash: config/harness.json всё равно появляется'
# ---------------------------------------------------------------------------
$p4 = New-GitFixture 'init-refuse-01'
$r4 = Bcf @('init', '--yes', '--project', $p4) -Env $noBashEnv
Check 'init не падает необработанным исключением' ($r4.Out -notmatch 'Exception|ParserError|At line:\d+ char:\d+') $r4.Out
# Не искать голое 'bash' — это подстрока и у названия фикстуры, и у 'Git Bash', и у имени
# файла .claude/hooks/pre-bash-guard.sh, любая из которых даёт ложный "ok" без починки
# forwarding-кода в init-write.ps1. Ищем ИМЕННО текст предупреждения, который добавляет он.
Check 'init сообщает о непоставленном settings.json' ($r4.Out -match 'закончился отказом') $r4.Out
Check 'config/harness.json создан несмотря на отказ install' (Test-Path (Join-Path $p4 'config\harness.json'))
Check 'settings.json НЕ создан голым' (-not (Test-Path (Join-Path $p4 '.claude\settings.json')))
Check 'git-хук секретов поставлен и включён несмотря на отказ bash' (
    (Test-Path (Join-Path $p4 '.githooks\pre-commit')) -and
    ((& $gitExe -C $p4 config --get core.hooksPath) -eq '.githooks')
)
# Регрессия найдена ревью M-05: init отчитывался кодом 0 при неподключённых 15 хуках —
# «init прошёл зелёным» читалось как «обвязка на месте», хотя settings.json не поставлен.
# install при этом же отказе сам выходит кодом 2 (см. install.ps1: exit 2 при
# $refused.Count) — init, вызвавший его подпроцессом, не имеет права отчитаться нулём.
Check 'init код возврата ненулевой при отказе install (не тихий частичный успех)' ($r4.Code -ne 0) "код $($r4.Code)"
Check 'init выносит отказ в "без этого прогон не поедет" (блокирующий список, не просто предупреждение мимоходом)' (
    $r4.Out -match 'БЕЗ ЭТОГО ПРОГОН НЕ ПОЕДЕТ'
) $r4.Out

Restore-TestEnv

# ---------------------------------------------------------------------------
Section '5. git-хук: чужой .git/hooks/pre-commit уже есть — install не перезаписывает и не дописывает вслепую'
# ---------------------------------------------------------------------------
# Чужой хук может быть на любом языке — python `pre-commit` framework, Husky-обёртка,
# рукописный скрипт. Дозапись команды в конец чужого файла вслепую способна его сломать
# так, что заметят не сразу (свой ранний `exit`, другой интерпретатор). install вместо
# этого ставит .githooks/pre-commit (файл доступен), НЕ трогает core.hooksPath (иначе
# существующий .git/hooks/pre-commit молча перестал бы вызываться) и печатает готовую
# строку для ручной дозаписи.
$p5 = New-GitFixture 'githook-legacy-precommit'
$legacyHook5 = Join-Path $p5 '.git\hooks\pre-commit'
Set-Content -LiteralPath $legacyHook5 -Value "#!/bin/sh`necho `"third party hook`"`n" -Encoding UTF8
$r5 = Bcf @('install', '--project', $p5, '--only', 'claude')
Check 'install (с чужим .git/hooks/pre-commit) отработал зелёным' ($r5.Code -eq 0) "код $($r5.Code): $($r5.Out)"
Check '.githooks/pre-commit всё равно поставлен (файл доступен для ручной дозаписи)' (
    Test-Path (Join-Path $p5 '.githooks\pre-commit')
)
Check 'core.hooksPath НЕ тронут (чужой .git/hooks/pre-commit не выключен молча)' (
    -not (& $gitExe -C $p5 config --get core.hooksPath)
)
Check 'чужой .git/hooks/pre-commit не перезаписан (содержимое то же самое)' (
    (Get-Content -Raw -LiteralPath $legacyHook5) -match 'third party hook'
)
Check 'install предупреждает и даёт готовую строку для дозаписи' (
    $r5.Out -match 'сканер секретов перед коммитом: требуется ручное внимание' -and
    $r5.Out -match '\.git/hooks/pre-commit' -and
    $r5.Out -match '\.githooks/pre-commit'
) $r5.Out

# ---------------------------------------------------------------------------
Section '6. git-хук: core.hooksPath уже указывает на чужую систему хуков — install не перезаписывает'
# ---------------------------------------------------------------------------
$p6 = New-GitFixture 'githook-foreign-hookspath'
New-Item -ItemType Directory -Force -Path (Join-Path $p6 'my-hooks') | Out-Null
& $gitExe -C $p6 config core.hooksPath 'my-hooks' 2>&1 | Out-Null
$r6 = Bcf @('install', '--project', $p6, '--only', 'claude')
Check 'install (с чужим core.hooksPath) отработал зелёным' ($r6.Code -eq 0) "код $($r6.Code): $($r6.Out)"
Check 'core.hooksPath остался чужим (my-hooks), не переписан на .githooks' (
    (& $gitExe -C $p6 config --get core.hooksPath) -eq 'my-hooks'
)
Check '.githooks/pre-commit всё равно поставлен (для ручной дозаписи)' (
    Test-Path (Join-Path $p6 '.githooks\pre-commit')
)
Check 'install называет текущий core.hooksPath в предупреждении' ($r6.Out -match "'my-hooks'") $r6.Out

# ---------------------------------------------------------------------------
Section '7. git-хук: не git-репозиторий — install не падает, предупреждает и не ставит хук'
# ---------------------------------------------------------------------------
$p7 = Join-Path $sandbox 'githook-not-a-repo'
New-Item -ItemType Directory -Force -Path $p7 | Out-Null
$r7 = Bcf @('install', '--project', $p7, '--only', 'claude')
Check 'install на не-git-каталоге не падает необработанным исключением' ($r7.Out -notmatch 'Exception|ParserError') $r7.Out
Check 'install на не-git-каталоге по-прежнему отрабатывает зелёным (остальное не зависит от git)' ($r7.Code -eq 0) "код $($r7.Code): $($r7.Out)"
Check '.githooks/pre-commit НЕ поставлен (некуда — нет .git)' (-not (Test-Path (Join-Path $p7 '.githooks\pre-commit')))
Check 'install называет причину (нет .git)' ($r7.Out -match 'не git-репозиторий') $r7.Out

# ---------------------------------------------------------------------------
Section '8. настоящий git commit с установленным хуком: подготовка общей фикстуры, чистый коммит проходит'
# ---------------------------------------------------------------------------
# Разделы 8-18 работают на ОДНОЙ фикстуре с РЕАЛЬНО установленным и включённым
# `.githooks/pre-commit` (настоящий `bcf install`, не ручная копия шаблона в обход него).
# Каждый сценарий откатывает фикстуру к одному known-good коммиту (Reset-Fixture) вместо
# отдельного `bcf install` на сценарий — дешевле и так же надёжно.
$hf = New-HookedFixture 'real-commits'
$p = $hf.Path
Check 'install (для живых git commit) отработал зелёным' ($hf.Install.Code -eq 0) "код $($hf.Install.Code): $($hf.Install.Out)"
Check '.githooks/pre-commit реально стоит' (Test-Path (Join-Path $p '.githooks\pre-commit'))
Check 'core.hooksPath реально указывает на .githooks' (
    (& $gitExe -C $p config --get core.hooksPath) -eq '.githooks'
)

Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value 'host = "localhost"' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $p 'note.txt')  -Value 'просто заметка, без секретов' -Encoding UTF8
& $gitExe -C $p add -A 2>&1 | Out-Null
& $gitExe -C $p commit -qm 'baseline: harness + чистые файлы' 2>&1 | Out-Null
$cleanSha = (& $gitExe -C $p rev-parse HEAD).Trim()
Check 'контроль сценария: baseline-коммит реально создан' ([bool]$cleanSha)

Add-Content -LiteralPath (Join-Path $p 'note.txt') -Value 'вторая строка' -Encoding UTF8
& $gitExe -C $p add note.txt 2>&1 | Out-Null
$r8 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m clean'
Check 'чистый коммит (без секретов) проходит' ($r8.Code -eq 0) $r8.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

$fakeAwsKey = 'AKIA' + ('FAKE' * 4)   # 16 симв. после AKIA — заведомо ненастоящий, формат ключа

# ---------------------------------------------------------------------------
Section '9. настоящий commit: -a / -am / -am"wip" блокируют секрет из рабочего дерева'
# ---------------------------------------------------------------------------
# creds.txt уже отслеживается (baseline). Правим его В РАБОЧЕМ ДЕРЕВЕ и НЕ делаем git
# add — ровно сценарий, который проезжал мимо разбора командной строки: `-a`/`-am`
# стажируют правку ВНУТРИ самого commit, git-хук видит уже собранный git'ом индекс.
foreach ($form in @(
    @{ Label = 'git commit -a -m wip';              Cmd = 'git commit -a -m wip' }
    @{ Label = 'git commit -am wip';                Cmd = 'git commit -am wip' }
    @{ Label = 'git commit -am"wip" (без пробела)'; Cmd = 'git commit -am"wip"' }
)) {
    Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
    $r = Invoke-RealCommit -ProjectDir $p -Command $form.Cmd
    Check "$($form.Label): блокирует" ($r.Code -ne 0) "код $($r.Code): $($r.Out)"
    Check "$($form.Label): причина называет файл и строку" ($r.Out -match 'creds\.txt:1') $r.Out
    Check "$($form.Label): значение ключа НЕ печатается" ($r.Out -notmatch [regex]::Escape($fakeAwsKey)) $r.Out
    Reset-Fixture -ProjectDir $p -Sha $cleanSha
}

# ---------------------------------------------------------------------------
Section '10. настоящий commit: `git add ... && git commit ...` в одной команде блокирует'
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path $p 'newsecret.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r10 = Invoke-RealCommit -ProjectDir $p -Command 'git add newsecret.txt && git commit -m secret'
Check 'git add newsecret.txt && git commit: блокирует новый файл с секретом' ($r10.Code -ne 0) "код $($r10.Code): $($r10.Out)"
Check 'причина называет newsecret.txt:1' ($r10.Out -match 'newsecret\.txt:1') $r10.Out
Check 'значение ключа НЕ печатается' ($r10.Out -notmatch [regex]::Escape($fakeAwsKey)) $r10.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Регресс-контроль: та же форма команды без секрета проходит молча — фикс не начал
# блокировать любую связку add+commit как таковую.
Set-Content -LiteralPath (Join-Path $p 'harmless.txt') -Value 'без секретов' -Encoding UTF8
$r10b = Invoke-RealCommit -ProjectDir $p -Command 'git add -A && git commit -m harmless'
Check 'git add -A && git commit без секрета проходит (регресс не внесён)' ($r10b.Code -eq 0) $r10b.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '11. настоящий commit: pathspec внутри самого `commit` (-m msg <файл>, --include, --only) блокирует'
# ---------------------------------------------------------------------------
foreach ($form in @(
    @{ Label = 'git commit -m wip <файл> (pathspec)'; Cmd = 'git commit -m wip creds.txt' }
    @{ Label = 'git commit --include <файл>';         Cmd = 'git commit --include creds.txt -m wip' }
    @{ Label = 'git commit --only <файл>';            Cmd = 'git commit --only creds.txt -m wip' }
)) {
    Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
    $r = Invoke-RealCommit -ProjectDir $p -Command $form.Cmd
    Check "$($form.Label): блокирует" ($r.Code -ne 0) "код $($r.Code): $($r.Out)"
    Check "$($form.Label): причина называет файл и строку" ($r.Out -match 'creds\.txt:1') $r.Out
    Check "$($form.Label): значение ключа НЕ печатается" ($r.Out -notmatch [regex]::Escape($fakeAwsKey)) $r.Out
    Reset-Fixture -ProjectDir $p -Sha $cleanSha
}

# ---------------------------------------------------------------------------
Section '12. секрет в отслеживаемом файле, которого коммит не касается, не блокирует'
# ---------------------------------------------------------------------------
$today = Get-Date -Format 'yyyy-MM-dd'
New-Item -ItemType Directory -Force -Path (Join-Path $p 'docs') | Out-Null
Set-Content -LiteralPath (Join-Path $p 'docs\decisions.md') -Value "## $today — BCF_SECRET_SCAN_DISABLED сид фикстуры для раздела 12" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $p 'cfg.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add -A 2>&1 | Out-Null
$rSeed = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m seed' -Env @{ BCF_SECRET_SCAN_DISABLED = '1' }
Check 'сид: секрет в cfg.txt закоммичен через обход (для теста ниже)' ($rSeed.Code -eq 0) $rSeed.Out

Add-Content -LiteralPath (Join-Path $p 'note.txt') -Value 'третья строка' -Encoding UTF8
& $gitExe -C $p add note.txt 2>&1 | Out-Null
$r12 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m unrelated'
Check 'секрет в cfg.txt (не тронутом этим коммитом) НЕ блокирует' ($r12.Code -eq 0) $r12.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '13. текст -m с «-a» внутри не даёт ложного расширения проверки'
# ---------------------------------------------------------------------------
# Регрессия старого механизма (пятое ревью M-05, до этой правки): короткий флаг искался по
# сырой строке хвоста commit, поэтому `-m "правка -a теперь" doc.md` включал ПОЛНЫЙ diff
# рабочего дерева и блокировал коммит из-за секрета в постороннем файле. Git-хук команду
# вообще не разбирает — сценарий физически не может повториться, регресс-контроль не лишний.
Set-Content -LiteralPath (Join-Path $p 'doc.md') -Value 'обычный документ' -Encoding UTF8
& $gitExe -C $p add doc.md 2>&1 | Out-Null
$r13 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "правка -a теперь" doc.md'
Check 'commit с «-a» внутри текста сообщения проходит, если секретов нет' ($r13.Code -eq 0) $r13.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '14. значение-ссылка на переменную/окружение — не находка; реальный литерал по-прежнему блокирует'
# ---------------------------------------------------------------------------
$refFiles = @(
    @{ Name = 'app.js';  Content = 'const token = process.env.GITHUB_TOKEN;'; What = 'JS: token = process.env.*' }
    @{ Name = 'app2.js'; Content = 'const apiKey = config.api_key;'; What = 'JS: apiKey = config.*' }
    @{ Name = 'app3.js'; Content = 'const secret = process.env.MY_SECRET;'; What = 'JS: secret = process.env.*' }
    @{ Name = 'app.py';  Content = 'API_KEY = os.environ["OPENAI_API_KEY"]'; What = 'Python: API_KEY = os.environ[...]' }
    @{ Name = 'app2.py'; Content = 'pwd = password or os.getenv("DB_PASSWORD")'; What = 'Python: pwd = password or os.getenv(...)' }
)
foreach ($rf in $refFiles) {
    Set-Content -LiteralPath (Join-Path $p $rf.Name) -Value $rf.Content -Encoding UTF8
    & $gitExe -C $p add $rf.Name 2>&1 | Out-Null
    $rRef = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m note'
    Check "значение-ссылка не блокирует: $($rf.What)" ($rRef.Code -eq 0) $rRef.Out
    Reset-Fixture -ProjectDir $p -Sha $cleanSha
}

Set-Content -LiteralPath (Join-Path $p 'config.js') -Value 'const password = "realsecretvalue123";' -Encoding UTF8
& $gitExe -C $p add config.js 2>&1 | Out-Null
$r14b = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m note'
Check 'реальный литерал password = "..." по-прежнему блокируется (фильтр ссылок не выключил правило)' ($r14b.Code -ne 0) $r14b.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# password_default/password_env этого же репозитория (см. config/memory.config.json,
# поставленный bcf install в baseline) — правка файла не должна вставать вечно-красным
# гейтом на каждом коммите, задевающем его.
Set-Content -LiteralPath (Join-Path $p 'config\memory.config.json') -Value (
    '{ "host": "localhost", "password_default": "bcf_local_dev", "password_env": "BCF_PG_PASSWORD" }'
) -Encoding UTF8
& $gitExe -C $p add config\memory.config.json 2>&1 | Out-Null
$r14c = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "memory config"'
Check 'password_default/password_env в config/memory.config.json не блокирует' ($r14c.Code -eq 0) $r14c.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '15. BCF_SECRET_SCAN_DISABLED=1 с записью в docs/decisions.md пропускает и оставляет след'
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $p 'docs') | Out-Null
Set-Content -LiteralPath (Join-Path $p 'docs\decisions.md') -Value "## $today — BCF_SECRET_SCAN_DISABLED тестовый обход раздела 15" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add -A 2>&1 | Out-Null
$r15 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "disabled scan"' -Env @{ BCF_SECRET_SCAN_DISABLED = '1' }
Check 'BCF_SECRET_SCAN_DISABLED=1 с записью в decisions.md пропускает секрет' ($r15.Code -eq 0) $r15.Out
$decisionsCommitted = & $gitExe -C $p show HEAD:docs/decisions.md
Check 'запись BCF_SECRET_SCAN_DISABLED реально уехала в коммит вместе с обходом' ($decisionsCommitted -match 'BCF_SECRET_SCAN_DISABLED') $decisionsCommitted
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '16. BCF_SECRET_SCAN_DISABLED=1 БЕЗ записи в docs/decisions.md — отказывает'
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add -A 2>&1 | Out-Null
$r16 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "should refuse"' -Env @{ BCF_SECRET_SCAN_DISABLED = '1' }
Check 'без docs/decisions.md отказывает (не пропускает молча)' ($r16.Code -ne 0) $r16.Out
Check 'причина называет BCF_SECRET_SCAN_DISABLED и decisions.md' (
    $r16.Out -match 'BCF_SECRET_SCAN_DISABLED' -and $r16.Out -match 'decisions\.md'
) $r16.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '17. python не найден на хуке — коммит отказывает явно'
# ---------------------------------------------------------------------------
# Git Bash подставляет собственные mingw64/bin/usr/bin впереди унаследованного PATH — git
# остаётся резолвящимся, а python (и лаунчеры PyManager/WindowsApps) вычищены из PATH
# отдельно (проверено вручную перед написанием этого раздела).
$noPyPath = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'python' -and $_ -notmatch 'PyManager' -and $_ -notmatch 'WindowsApps' }) -join ';'
Add-Content -LiteralPath (Join-Path $p 'note.txt') -Value 'без python' -Encoding UTF8
& $gitExe -C $p add note.txt 2>&1 | Out-Null
$r17 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "no python"' -Env @{ PATH = $noPyPath }
Check 'без python в PATH коммит отказывает явно' ($r17.Code -ne 0) $r17.Out
Check 'причина называет python' ($r17.Out -match 'python') $r17.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Контроль сценария: с обычным PATH тот же коммит без секрета проходит — деградация
# специфична именно к отсутствию python, а не к сломанному сценарию вообще.
Add-Content -LiteralPath (Join-Path $p 'note.txt') -Value 'с python' -Encoding UTF8
& $gitExe -C $p add note.txt 2>&1 | Out-Null
$r17control = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "with python"'
Check 'контроль сценария: с обычным PATH тот же коммит без секрета проходит' ($r17control.Code -eq 0) $r17control.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '18. МУТАЦИЯ: с выключенным сканером все блокирующие случаи из разделов 9-11 проходят'
# ---------------------------------------------------------------------------
# Доказывает, что разделы 9-11 блокируют ИМЕННО из-за сканера, а не из-за чего-то ещё
# (сломанная фикстура, посторонний гейт) — с тем же самым BCF_SECRET_SCAN_DISABLED-обходом
# каждая ранее блокирующая форма обязана теперь пройти.
New-Item -ItemType Directory -Force -Path (Join-Path $p 'docs') | Out-Null
Set-Content -LiteralPath (Join-Path $p 'docs\decisions.md') -Value "## $today — BCF_SECRET_SCAN_DISABLED мутация раздела 18" -Encoding UTF8
& $gitExe -C $p add docs\decisions.md 2>&1 | Out-Null
$rSeed18 = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m "decisions seed"' -Env @{ BCF_SECRET_SCAN_DISABLED = '1' }
Check 'мутация: сид decisions.md закоммичен' ($rSeed18.Code -eq 0) $rSeed18.Out
$cleanSha18 = (& $gitExe -C $p rev-parse HEAD).Trim()

$mutationForms = @(
    @{ Label = 'git commit -am wip';                  Cmd = 'git commit -am wip';                Setup = { Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8 } }
    @{ Label = 'git add newsecret.txt && git commit'; Cmd = 'git add newsecret.txt && git commit -m secret'; Setup = { Set-Content -LiteralPath (Join-Path $p 'newsecret.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8 } }
    @{ Label = 'git commit -m wip <файл> (pathspec)';  Cmd = 'git commit -m wip creds.txt';        Setup = { Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8 } }
    @{ Label = 'git commit --include <файл>';          Cmd = 'git commit --include creds.txt -m wip'; Setup = { Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8 } }
    @{ Label = 'git commit --only <файл>';             Cmd = 'git commit --only creds.txt -m wip'; Setup = { Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8 } }
)
foreach ($form in $mutationForms) {
    & $form.Setup
    $r = Invoke-RealCommit -ProjectDir $p -Command $form.Cmd -Env @{ BCF_SECRET_SCAN_DISABLED = '1' }
    Check "мутация «$($form.Label)»: со сканером выключен блокирующий случай теперь проходит" ($r.Code -eq 0) "код $($r.Code): $($r.Out)"
    Reset-Fixture -ProjectDir $p -Sha $cleanSha18
}

Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '19. secret-scan.sh (Claude Code): тонкий вызов делегирует .githooks/pre-commit, deny, значение не печатается'
# ---------------------------------------------------------------------------
# Простой случай: секрет уже застейджен ОТДЕЛЬНОЙ командой git add, а сама команда commit
# индекс не меняет (без -a/-am/pathspec) — текущий git diff --cached уже ровно то, что
# увидел бы настоящий git commit, и wrapper может дать ответ ДО запуска git.
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add creds.txt 2>&1 | Out-Null
$r19 = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git -c user.name="t" -c user.email="t@local" commit -m note'
Check 'secret-scan.sh: возвращает hookSpecificOutput.permissionDecision: deny' (
    $r19.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r19.Out
Check 'secret-scan.sh: код возврата 2 (блокирует по доке Claude Code независимо от JSON)' ($r19.Code -eq 2) "код $($r19.Code): $($r19.Out)"
Check 'secret-scan.sh: причина называет файл и строку' ($r19.Out -match 'creds\.txt:1') $r19.Out
Check 'secret-scan.sh: само значение ключа НЕ печатается' ($r19.Out -notmatch [regex]::Escape($fakeAwsKey)) $r19.Out
& $gitExe -C $p restore --staged creds.txt 2>&1 | Out-Null
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Регресс-контроль: чистый staged-коммит проходит молча.
Set-Content -LiteralPath (Join-Path $p 'note.txt') -Value 'чисто' -Encoding UTF8
& $gitExe -C $p add note.txt 2>&1 | Out-Null
$r19clean = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m note'
Check 'secret-scan.sh: чистый застейдженный коммит проходит молча' (-not $r19clean.Out.Trim()) $r19clean.Out
Check 'secret-scan.sh: код возврата 0 на чистом коммите' ($r19clean.Code -eq 0) "код $($r19clean.Code): $($r19clean.Out)"
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '20. secret-scan.sh (Claude Code): молчит на не-commit командах и когда git-хук не установлен'
# ---------------------------------------------------------------------------
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add creds.txt 2>&1 | Out-Null
$r20a = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git status'
Check '"git status" не проверяется (тот же секрет уже staged)' (-not $r20a.Out.Trim()) $r20a.Out
$r20b = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'docker commit mycontainer myimage'
Check '"docker commit" не путается с "git commit"' (-not $r20b.Out.Trim()) $r20b.Out
& $gitExe -C $p restore --staged creds.txt 2>&1 | Out-Null
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Проект без git-хука (обычный git init, install не вызывался) — wrapper не имеет права
# продублировать сканер, когда некому исполнить его на настоящем commit; должен смолчать.
$p20c = New-GitFixture 'no-githook-installed'
Set-Content -LiteralPath (Join-Path $p20c 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p20c add creds.txt 2>&1 | Out-Null
Check 'контроль сценария: .githooks/pre-commit реально отсутствует' (-not (Test-Path (Join-Path $p20c '.githooks\pre-commit')))
$r20c = Invoke-ClaudeHookWrapper -ProjectDir $p20c -Command 'git commit -m note'
Check 'secret-scan.sh молчит, когда .githooks/pre-commit не поставлен (не дублирует сканер)' (
    $r20c.Code -eq 0 -and -not $r20c.Out.Trim()
) "код $($r20c.Code): $($r20c.Out)"

# ---------------------------------------------------------------------------
Section '21. secret-scan.sh не дублирует сканер: текст отказа совпадает с прямым вызовом .githooks/pre-commit'
# ---------------------------------------------------------------------------
# Проверяет требование "двух независимых логик быть не должно" буквально: wrapper не
# пересчитывает находки заново, а передаёт РОВНО тот же текст, что напечатал бы сам хук.
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add creds.txt 2>&1 | Out-Null
# Push-Location — обязательно: pre-commit резолвит свой репозиторий через `git rev-parse
# --show-toplevel` от ТЕКУЩЕГО каталога процесса (без -C). Без этого прямой вызов из cwd
# тестового раннера резолвил бы чужой репозиторий и дал бы пустой (ложный) эталон для
# сравнения — ту же ошибку когда-то повторял и сам wrapper (см. правку secret-scan.sh).
Push-Location $p
try {
    $directHookOut = (& $bash -c ((Join-Path $p '.githooks\pre-commit') -replace '\\', '/') 2>&1 | Out-String)
} finally { Pop-Location }
$r21 = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m note'
Check 'текст отказа wrapper совпадает с текстом отказа хука 1:1' (
    $r21.Out -match [regex]::Escape($directHookOut.Trim())
) "хук: [$($directHookOut.Trim())] / wrapper: [$($r21.Out)]"
& $gitExe -C $p restore --staged creds.txt 2>&1 | Out-Null
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '22. doctor объявляет Windows требованием'
# ---------------------------------------------------------------------------
# $IsWindows у PowerShell — константа ("Cannot overwrite variable IsWindows because it is
# read-only"), поэтому ветка «не Windows» проверяется тестовым швом BCF_SIMULATE_NOT_WINDOWS,
# а не подменой автоматической переменной.
$p22 = New-GitFixture 'doctor-not-windows'
$r22 = Bcf @('doctor', '--no-probe', '--project', $p22) -Env @{ BCF_SIMULATE_NOT_WINDOWS = '1' }
Check 'doctor отказывает на "не Windows"' ($r22.Code -ne 0) "код $($r22.Code)"
# Матчим ИМЕННО текст гейта из doctor.ps1, а не голое 'Windows' — та подстрока встречается
# в куче безобидных мест (заголовок доктора, версия pwsh) и остаётся зелёной, даже когда
# сам гейт вырезан. Проверено мутацией: со снятой веткой gate в doctor.ps1 этот Check
# краснеет, а с голым 'Windows' — нет.
Check 'причина — конкретный текст гейта doctor.ps1' (
    $r22.Out -match [regex]::Escape('doctor поддерживает только Windows')
) $r22.Out
Check 'дальше живой пробы не идёт (нет вывода про роли/память)' ($r22.Out -notmatch 'ЖИВАЯ ПРОБА РОЛЕЙ|ПАМЯТЬ') $r22.Out

$r22b = Bcf @('doctor', '--no-probe', '--project', $p22)
Check 'на самой Windows doctor отрабатывает как обычно (регресс не внесён)' ($r22b.Out -notmatch 'doctor поддерживает только Windows') $r22b.Out

# Конкретная формулировка требования, а не голое 'Windows' (та подстрока была в обоих
# файлах и до правки M-05 — например "Windows PowerShell 5 не подходит" в SETUP.md).
Check 'README называет Windows требованием (конкретная формулировка)' (
    (Get-Content -Raw -LiteralPath (Join-Path $root 'README.md')) -match [regex]::Escape('Требуется **Windows**')
)
Check 'docs/SETUP.md называет Windows требованием (конкретная формулировка)' (
    (Get-Content -Raw -LiteralPath (Join-Path $root 'docs\SETUP.md')) -match [regex]::Escape('фабрика пока только под неё')
)

# ---------------------------------------------------------------------------
Section '23. CI: workflow гоняет tests/all.ps1 на push и pull_request на windows-latest'
# ---------------------------------------------------------------------------
# Регрессия найдена ревью M-05: до этого раздела ни одна сюита не читала
# .github/workflows/tests.yml — удаление файла или подмена runs-on/команды прогона не
# красили ничего. Проверяем по содержимому, а не по факту существования: подмена
# 'runs-on: windows-latest' на 'ubuntu-latest' обязана уронить эту секцию.
$workflowPath = Join-Path $root '.github\workflows\tests.yml'
Check 'workflow-файл .github/workflows/tests.yml существует' (Test-Path -LiteralPath $workflowPath)
if (Test-Path -LiteralPath $workflowPath) {
    $wf = Get-Content -Raw -LiteralPath $workflowPath
    Check 'триггер: push' ($wf -match '(?m)^\s*push:\s*$') $wf
    Check 'триггер: pull_request' ($wf -match '(?m)^\s*pull_request:\s*$') $wf
    Check 'раннер: windows-latest' ($wf -match '(?m)^\s*runs-on:\s*windows-latest\s*$') $wf
    Check 'шаг запускает pwsh -NoProfile -File tests/all.ps1' (
        $wf -match 'pwsh\s+-NoProfile\s+-File\s+tests[\\/]all\.ps1'
    ) $wf
}

# ---------------------------------------------------------------------------
Section '24. документация: git-хук секретов назван в SETUP.md/ROADMAP.md, опечатка "диff" не возвращалась'
# ---------------------------------------------------------------------------
$setupTxt = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\SETUP.md')
Check 'docs/SETUP.md называет .githooks/pre-commit единственным сканером' ($setupTxt -match '\.githooks/pre-commit')
Check 'docs/SETUP.md называет core.hooksPath' ($setupTxt -match 'core\.hooksPath')
Check 'docs/SETUP.md объясняет тонкий вызов .claude/hooks/secret-scan.sh' (
    $setupTxt -match 'тонкий предварительный вызов'
)

$roadmapTxt = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\ROADMAP.md')
Check 'docs/ROADMAP.md: M-05a закрыт (git-хук вместо разбора командной строки)' (
    $roadmapTxt -match 'M-05a Секреты: git-хук вместо разбора командной строки'
)
Check 'docs/ROADMAP.md: "В работе" не содержит старую формулировку M-05a про pathspec' (
    $roadmapTxt -notmatch 'M-05a Секреты: pathspec внутри самого коммита'
)

$archTxt = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\ARCHITECTURE.md')
$cfgTxt  = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\CONFIG.md')
Check 'docs/ARCHITECTURE.md: опечатка смешанным алфавитом не возвращалась' ($archTxt -notmatch 'диff')
Check 'docs/CONFIG.md: опечатка смешанным алфавитом не возвращалась' ($cfgTxt -notmatch 'диff')
Check 'docs/ARCHITECTURE.md: слово написано целиком кириллицей' ($archTxt -match 'дифф')
Check 'docs/CONFIG.md: слово написано целиком кириллицей' ($cfgTxt -match 'дифф')

# ---------------------------------------------------------------------------
Section '25. secret-scan.sh (Claude Code): --no-verify/-n и -c core.hooksPath=<чужой> денаятся сразу — единственная точка, где это вообще видно'
# ---------------------------------------------------------------------------
# Ревью нашло: `--no-verify`/`-n` не дают git вообще ВЫЗВАТЬ `.githooks/pre-commit`, а
# `-c core.hooksPath=<чужой>` подменяет систему хуков на время команды — git-хук в
# принципе не может поймать свой собственный обход. Единственная точка, где это видно —
# ЗДЕСЬ, ДО того, как git вообще запустится: секции ниже проверяют, что wrapper денаит
# по присутствию флага в учитывающей кавычки токенизации (shlex), а не угадывает индекс.
# Мутация проверена вручную перед сдачей: с закомментированной веткой `if bypass:` в
# secret-scan.sh все три формы ниже перестают денаить (`--no-verify` реально уезжает в
# HEAD на этой же фикстуре) — восстановлено сразу после проверки, в дифф не входит.
Reset-Fixture -ProjectDir $p -Sha $cleanSha

foreach ($form in @(
    @{ Label = 'git commit --no-verify -am wip';              Cmd = 'git commit --no-verify -am wip';                      Expect = '--no-verify' }
    @{ Label = 'git add X && git commit -n -m secret';        Cmd = 'git add newsecret.txt && git commit -n -m secret';    Expect = 'флаг -n' }
    @{ Label = 'git -c core.hooksPath=... commit -am bypass'; Cmd = 'git -c core.hooksPath=/nonexistent commit -am bypass'; Expect = 'core.hooksPath' }
)) {
    $r = Invoke-ClaudeHookWrapper -ProjectDir $p -Command $form.Cmd
    Check "$($form.Label): secret-scan.sh денаит (обошла бы .githooks/pre-commit целиком)" (
        $r.Code -eq 2 -and $r.Out -match '"permissionDecision"\s*:\s*"deny"'
    ) "код $($r.Code): $($r.Out)"
    Check "$($form.Label): причина называет обход" ($r.Out -match [regex]::Escape($form.Expect)) $r.Out
}

# Негативный случай: текст сообщения коммита СОДЕРЖИТ подстроку "--no-verify" внутри
# кавычек -m — это значение сообщения, не отдельный флаг, и не должно денаить. Регрессия
# старого механизма (M-05, ревью 5): именно так когда-то ловился текст «-a» в сообщении.
Set-Content -LiteralPath (Join-Path $p 'doc.md') -Value 'обычный документ' -Encoding UTF8
& $gitExe -C $p add doc.md 2>&1 | Out-Null
$r25neg = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m "отказ от --no-verify" doc.md'
Check 'текст «--no-verify» внутри -m не даёт ложного deny' (-not $r25neg.Out.Trim()) $r25neg.Out
Check 'код возврата 0 на негативном случае' ($r25neg.Code -eq 0) "код $($r25neg.Code): $($r25neg.Out)"
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Контроль на НАСТОЯЩЕМ git: --no-verify — поведение самого git (хуки не вызываются
# вообще), не дефект этого проекта; git-хук `.githooks/pre-commit` в принципе не может
# перехватить собственный обход. Задокументированная остаточная граница (docs/SETUP.md):
# secret-scan.sh видит только команды, которые выполняет сам Claude Code, а не всё, что
# человек наберёт в своём терминале мимо него.
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r25real = Invoke-RealCommit -ProjectDir $p -Command 'git commit --no-verify -am bypass'
Check 'контроль: настоящий git commit --no-verify пропускает секрет мимо git-хука (задокументированная граница, не наш дефект)' (
    $r25real.Code -eq 0
) $r25real.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '26. secret-scan.sh (Claude Code): обещание "не проверяет pathspec" реализовано в коде, не только в комментарии'
# ---------------------------------------------------------------------------
# Ревью нашло: `git commit -m docs -- doc.md` при секрете, застейдженном в ДРУГОМ файле
# (вне pathspec), wrapper денаил, хотя настоящий git ту же команду коммитит зелёным —
# git подставляет хуку временный индекс, ограниченный pathspec (см. заголовок
# secret-scan.sh). Мутация проверена вручную: с закомментированной строкой
# `print("COMPLEX")` ложный deny из этого раздела возвращается на той же фикстуре —
# восстановлено сразу после проверки, в дифф не входит.
Set-Content -LiteralPath (Join-Path $p 'secret.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add secret.txt 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $p 'doc.md') -Value 'обычный документ' -Encoding UTF8
& $gitExe -C $p add doc.md 2>&1 | Out-Null
$r26a = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m docs -- doc.md'
Check 'pathspec мимо застейдженного (в другом файле) секрета: wrapper молчит (не ложный deny)' (
    $r26a.Code -eq 0 -and -not $r26a.Out.Trim()
) "код $($r26a.Code): $($r26a.Out)"
$r26aReal = Invoke-RealCommit -ProjectDir $p -Command 'git commit -m docs -- doc.md'
Check 'контроль: настоящий git commit с тем же pathspec проходит зелёным (doc.md чист)' ($r26aReal.Code -eq 0) $r26aReal.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Регресс-контроль: если pathspec указывает НА САМ секретный файл, wrapper теперь молчит
# (сужен до простого случая) — ловит `.githooks/pre-commit` на настоящем commit (раздел 11
# это уже покрывает через реальный git commit).
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r26b = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m wip creds.txt'
Check 'pathspec на сам секретный файл: wrapper молчит, а не угадывает (ловит .githooks/pre-commit, см. раздел 11)' (
    $r26b.Code -eq 0 -and -not $r26b.Out.Trim()
) "код $($r26b.Code): $($r26b.Out)"
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# Регресс-контроль: простой случай (без -a/-am/pathspec) по-прежнему ловится РАНО — сужение
# до "простого случая" не выключило основной сценарий раздела 19.
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p add creds.txt 2>&1 | Out-Null
$r26c = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m note'
Check 'простой случай (без -a/pathspec) по-прежнему ловится рано (регресс не внесён)' (
    $r26c.Code -eq 2 -and $r26c.Out -match 'creds\.txt:1'
) "код $($r26c.Code): $($r26c.Out)"
& $gitExe -C $p restore --staged creds.txt 2>&1 | Out-Null
Reset-Fixture -ProjectDir $p -Sha $cleanSha

# ---------------------------------------------------------------------------
Section '27. secret-scan.sh (Claude Code): связка коротких флагов -nm/-anm денаится — mustFix ревью M-05a'
# ---------------------------------------------------------------------------
# Ревью нашло: git бандлит короткие опции в один токен слева направо (`-am` = `-a` + `-m`,
# см. `git commit -h`), а проверка присутствия флага из раздела 25 сравнивала токен
# ЦЕЛИКОМ с "-n"/"--no-verify" — связка "-nm"/"-anm" проезжала мимо неё ровно как
# отдельный "-n" мимо git-хука. Контроль на настоящем git ниже (не Claude-хук) доказывает,
# что бандлинг — поведение самого git, а не придуманный сценарий: creds.txt уже
# отслеживается в baseline (раздел 8), поэтому "-anm" (стажирует правку САМ) реально
# коммитит секрет мимо .githooks/pre-commit, установленного и включённого на этой же
# фикстуре.
Set-Content -LiteralPath (Join-Path $p 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r27real = Invoke-RealCommit -ProjectDir $p -Command 'git commit -anm bypass'
Check 'контроль: настоящий git commit -anm тоже пропускает секрет мимо git-хука (git сам бандлит -a -n -m)' (
    $r27real.Code -eq 0
) $r27real.Out
Reset-Fixture -ProjectDir $p -Sha $cleanSha

foreach ($form in @(
    @{ Label = 'git commit -nm wip (связка -n+-m)';      Cmd = 'git commit -nm wip';    Expect = '-nm' }
    @{ Label = 'git commit -anm "wip" (связка -a-n+-m)'; Cmd = 'git commit -anm "wip"'; Expect = '-anm' }
)) {
    $r = Invoke-ClaudeHookWrapper -ProjectDir $p -Command $form.Cmd
    Check "$($form.Label): secret-scan.sh денаит (обошла бы .githooks/pre-commit целиком)" (
        $r.Code -eq 2 -and $r.Out -match '"permissionDecision"\s*:\s*"deny"'
    ) "код $($r.Code): $($r.Out)"
    Check "$($form.Label): причина называет саму связку" ($r.Out -match [regex]::Escape($form.Expect)) $r.Out
}

# Негативные регресс-контроли: самые частые формы без "-n" не должны денаиться новой
# проверкой связки — иначе обычный `-m`/`-am` стал бы ложно заблокированным.
$r27negM = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -m note'
Check 'git commit -m note: связка "-n" не находится там, где её нет (регресс-контроль)' (
    -not $r27negM.Out.Trim()
) $r27negM.Out
Check 'git commit -m note: код возврата 0' ($r27negM.Code -eq 0) "код $($r27negM.Code): $($r27negM.Out)"

$r27negAM = Invoke-ClaudeHookWrapper -ProjectDir $p -Command 'git commit -am note'
Check 'git commit -am note: "-am" не путается со связкой "-n"+"-m" (регресс-контроль)' (
    -not $r27negAM.Out.Trim()
) $r27negAM.Out
Check 'git commit -am note: код возврата 0' ($r27negAM.Code -eq 0) "код $($r27negAM.Code): $($r27negAM.Out)"

# Мутация проверена вручную перед сдачей: с закомментированной веткой
# `elif short_bundle_has_no_verify(t)` в secret-scan.sh обе позитивные проверки этого
# раздела краснеют (verdict пустой, wrapper молчит и вызывает .githooks/pre-commit по
# текущему — здесь пустому — индексу, коммит с "-nm"/"-anm" перестаёт денаиться) —
# восстановлено сразу после проверки, в дифф не входит.

# ---------------------------------------------------------------------------
Restore-TestEnv
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  ИТОГ: прошло $($script:Pass), провалено $($script:Fail)") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Fail) { exit 1 }
exit 0
