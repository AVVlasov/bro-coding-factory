# install-secrets.tests.ps1 — bash в settings.json и секреты перед коммитом.
#
#   pwsh tests/install-secrets.tests.ps1
#
# ЧТО ЭТИ ТЕСТЫ ЛОВЯТ.
#
#   · settings.json с голым 'bash' — на Windows это чаще лаунчер WSL, а не Git Bash: хук
#     виснет на неинициализированном дистрибутиве или падает молча, и вся проводка
#     хуков (deструктивные команды, защита обвязки, DoD) перестаёт работать без единой
#     видимой ошибки на установке.
#   · bash не найден — install не должен ни притвориться, что всё поставилось (записать
#     settings.json с той же голой командой), ни уронить ВЕСЬ install: config/, hooks/,
#     skills/ не зависят от bash и обязаны встать на место, а `bcf init`, который зовёт
#     install подпроцессом и следующим шагом читает config/harness.json, не должен
#     упасть необработанным исключением на файле, которого internal install не написал
#     совсем по другой причине.
#   · секрет, попавший в staged-дифф, — тот же класс, что утечка в публичный репозиторий:
#     коммит обязан заблокироваться раньше, чем секрет уедет в историю git, а сам секрет
#     не должен попасть даже в текст отказа.
#   · свой несекретный дефолт (`password_default` в config/memory.config.json) не должен
#     стать вечно красным гейтом — иначе первый же коммит, задевающий этот файл, встаёт.
#
# Ни сети, ни моделей: хук — запуск в Git Bash на фикстуре, install/init — прямой прогон
# CLI фабрики во временных песочницах. «bash не найден» СКВОЗЬ ПРОЦЕСС install
# симулируется через BCF_BASH_FORCE_NOT_FOUND (Get-BcfBash), а не через сокрытие
# ProgramFiles/ProgramFiles(x86) в окружении: для НОВОГО процесса Windows сама
# переподставляет эти две переменные системными путями при создании процесса, и override
# родителя до дочернего pwsh не доезжает (см. секцию 3 и комментарий у Get-BcfBash) —
# приоритет "git --exec-path перед известными каталогами" поэтому проверяется юнит-вызовом
# функции в этом же процессе, а не через вложенный pwsh.

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$root          = Split-Path $PSScriptRoot -Parent
$bcf           = Join-Path $root 'bin\bcf.ps1'
$secretScanSrc = Join-Path $root 'templates\claude\hooks\secret-scan.sh'
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

# ПОЛНЫЕ ПУТИ ДО ЛЮБОЙ ПОДМЕНЫ PATH. Сценарии «bash не найден» подменяют PATH дочернему
# процессу — если сам pwsh или git резолвятся по голому имени ПОСЛЕ подмены, тест ломает
# то, чем сам же пользуется, а не то, что должен проверить.
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
Write-Host "  BASH В SETTINGS.JSON И СЕКРЕТЫ ПЕРЕД КОММИТОМ   песочница: $sandbox" -ForegroundColor Cyan

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

function Invoke-SecretScan {
    param([string]$ProjectDir, [string]$Command, [switch]$ForceNoPython)
    $payload = (@{ tool_input = @{ command = $Command } } | ConvertTo-Json -Compress)
    $pf = Join-Path $sandbox ('hook-in-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Set-Content -LiteralPath $pf -Value $payload -Encoding UTF8 -NoNewline
    $prev = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    $prevPath = $env:PATH
    if ($ForceNoPython) {
        # Git Bash сам подставляет СВОИ mingw64/bin и usr/bin впереди любого PATH, который
        # ему дать (проверено вручную) — git, cat, mktemp остаются на месте, а python
        # (стоящий отдельно, в каталогах вида Python3xx/PyManager) из этого набора выпадает.
        $env:PATH = (Split-Path $bash -Parent)
    }
    try {
        $sh = ($secretScanSrc -replace '\\', '/')
        $inp = ($pf -replace '\\', '/')
        $out = (& $bash -c "'$sh' < '$inp'" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prev }
        if ($ForceNoPython) { $env:PATH = $prevPath }
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
Section '1. Обычный install: settings.json получает полный путь к bash, не голое имя'
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
Section '5. secret-scan.sh: обычный коммит без секретов проходит молча'
# ---------------------------------------------------------------------------
$p5 = New-GitFixture 'scan-clean'
Set-Content -LiteralPath (Join-Path $p5 'note.txt') -Value 'просто текст, без секретов' -Encoding UTF8
& $gitExe -C $p5 add -A 2>&1 | Out-Null
$r5 = Invoke-SecretScan -ProjectDir $p5 -Command 'git -c user.name="t" -c user.email="t@local" commit -m "note"'
Check 'хук ничего не печатает на чистом коммите' (-not $r5.Out.Trim()) $r5.Out
Check 'код возврата хука 0 (не блокирует Claude Code хук-протокол)' ($r5.Code -eq 0) $r5.Out
& $gitExe -C $p5 restore --staged . 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '6. secret-scan.sh: блокирует коммит с образцом ключа, значение не печатает'
# ---------------------------------------------------------------------------
# Заведомо ненастоящие строки-образцы: собраны так, чтобы совпасть с форматом ключа, а не
# быть чьим-то реальным секретом.
$fakeAwsKey = 'AKIA' + ('FAKE' * 4)
$p6 = New-GitFixture 'scan-secret'
Set-Content -LiteralPath (Join-Path $p6 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p6 add -A 2>&1 | Out-Null
$r6 = Invoke-SecretScan -ProjectDir $p6 -Command 'git -c user.name="t" -c user.email="t@local" commit -m "add creds"'
# Формат PreToolUse по доке Claude Code (code.claude.com/docs/en/hooks, сверено 2026-09-05):
# hookSpecificOutput.permissionDecision, не верхнеуровневый decision — верхнеуровневое поле
# дока прямо называет неподходящим для PreToolUse. Блокировка держится на коде возврата 2
# («Exit 2 means a blocking error... blocks whether or not you print JSON»), поэтому код
# проверяем отдельно и это не необязательная деталь.
Check 'хук возвращает hookSpecificOutput.permissionDecision: deny' (
    $r6.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r6.Out
Check 'код возврата хука 2 (блокирует по доке Claude Code независимо от JSON)' ($r6.Code -eq 2) "код $($r6.Code): $($r6.Out)"
Check 'причина называет файл и строку' ($r6.Out -match 'creds\.txt:1') $r6.Out
Check 'само значение ключа НЕ печатается' ($r6.Out -notmatch [regex]::Escape($fakeAwsKey)) $r6.Out
& $gitExe -C $p6 restore --staged . 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '7. secret-scan.sh: password_default этого репозитория — не находка'
# ---------------------------------------------------------------------------
# Регрессия: правило на присваивания уже, чем в detect-secrets (там ключевое слово допускает
# суффикс) — иначе каждый коммит, задевающий config/memory.config.json, вставал бы.
$p7 = New-GitFixture 'scan-own-default'
New-Item -ItemType Directory -Force -Path (Join-Path $p7 'config') | Out-Null
Set-Content -LiteralPath (Join-Path $p7 'config\memory.config.json') -Value (
    '{ "host": "localhost", "password_default": "bcf_local_dev", "password_env": "BCF_PG_PASSWORD" }'
) -Encoding UTF8
& $gitExe -C $p7 add -A 2>&1 | Out-Null
$r7 = Invoke-SecretScan -ProjectDir $p7 -Command 'git -c user.name="t" -c user.email="t@local" commit -m "memory config"'
Check 'password_default/password_env не блокируют коммит' (-not $r7.Out.Trim()) $r7.Out
& $gitExe -C $p7 restore --staged . 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '8. secret-scan.sh реагирует только на git commit, не на любую bash-команду'
# ---------------------------------------------------------------------------
$p8 = New-GitFixture 'scan-not-commit'
Set-Content -LiteralPath (Join-Path $p8 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p8 add -A 2>&1 | Out-Null
$r8a = Invoke-SecretScan -ProjectDir $p8 -Command 'git status'
Check '"git status" не сканируется (тот же секрет уже staged)' (-not $r8a.Out.Trim()) $r8a.Out
$r8b = Invoke-SecretScan -ProjectDir $p8 -Command 'docker commit mycontainer myimage'
Check '"docker commit" не путается с "git commit"' (-not $r8b.Out.Trim()) $r8b.Out
& $gitExe -C $p8 restore --staged . 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '9. secret-scan.sh: -a/-am не даёт обойти сканер секретом из рабочего дерева'
# ---------------------------------------------------------------------------
# Регрессия найдена ревью M-05: `git commit -am` стажирует отслеживаемые правки ВНУТРИ
# самого commit, уже после того, как хук проверил `git diff --cached`. Секрет, лежащий
# только в рабочем дереве (git add не делали), на пустом индексе проезжал мимо хука
# молча — ровно так, как воспроизведено ревью.
$p9a = New-GitFixture 'scan-dash-a-bypass'
Set-Content -LiteralPath (Join-Path $p9a 'creds.txt') -Value 'просто текст, без секретов' -Encoding UTF8
& $gitExe -C $p9a add -A 2>&1 | Out-Null
& $gitExe -C $p9a commit -qm 'creds.txt без секрета' 2>&1 | Out-Null
# Правим отслеживаемый файл и НЕ делаем git add — ровно сценарий из находки ревью.
Set-Content -LiteralPath (Join-Path $p9a 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$stagedBefore = & $gitExe -C $p9a diff --cached --stat
Check 'контроль сценария: индекс на момент правки пуст (правка НЕ добавлена в staging)' (-not $stagedBefore)

$r9a = Invoke-SecretScan -ProjectDir $p9a -Command 'git -c user.name="t" -c user.email="t@local" commit -am wip'
Check '-am: хук блокирует секрет из рабочего дерева, а не только из индекса' (
    $r9a.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r9a.Out
Check '-am: код возврата хука 2' ($r9a.Code -eq 2) "код $($r9a.Code): $($r9a.Out)"
Check '-am: причина называет файл и строку' ($r9a.Out -match 'creds\.txt:1') $r9a.Out
Check '-am: само значение ключа НЕ печатается' ($r9a.Out -notmatch [regex]::Escape($fakeAwsKey)) $r9a.Out

# Без -a/-am тот же незастейдженный секрет по-прежнему вне области видимости --cached —
# регресс-контроль, что фикс не начал сканировать рабочее дерево ВСЕГДА.
$r9b = Invoke-SecretScan -ProjectDir $p9a -Command 'git -c user.name="t" -c user.email="t@local" commit -m wip'
Check 'без -a/-am незастейдженный секрет по-прежнему не сканируется (регресс не внесён)' (-not $r9b.Out.Trim()) $r9b.Out
& $gitExe -C $p9a checkout -- creds.txt 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '10. secret-scan.sh: `git add ... && git commit ...` в одной строке не даёт обойти сканер'
# ---------------------------------------------------------------------------
# Регрессия найдена ревью M-05: хук — PreToolUse, он смотрит на командную строку и индекс
# ДО того, как что-либо из неё выполнилось. `git add -A && git commit -m secret` в одну
# команду: на момент проверки git add ещё не сработал, `git diff --cached` пуст, секрет
# из НЕОТСЛЕЖИВАЕМОГО файла (в staging его никогда не заносили — ни здесь, ни отдельной
# командой раньше) проезжал мимо хука молча. Воспроизведение ревью: creds.txt не в
# индексе, {"tool_input":{"command":"git add -A && git commit -m secret"}} -> exit 0.
$p10a = New-GitFixture 'scan-add-commit-bypass'
Set-Content -LiteralPath (Join-Path $p10a 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$stagedBefore10 = & $gitExe -C $p10a diff --cached --stat
Check 'контроль сценария: индекс пуст, creds.txt не добавлен ни разу' (-not $stagedBefore10)

$r10a = Invoke-SecretScan -ProjectDir $p10a -Command 'git add -A && git commit -m secret'
Check 'git add -A && git commit: хук блокирует секрет из НЕотслеживаемого файла' (
    $r10a.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r10a.Out
Check 'git add -A && git commit: код возврата хука 2' ($r10a.Code -eq 2) "код $($r10a.Code): $($r10a.Out)"
Check 'git add -A && git commit: причина называет файл и строку' ($r10a.Out -match 'creds\.txt:1') $r10a.Out
Check 'git add -A && git commit: само значение ключа НЕ печатается' ($r10a.Out -notmatch [regex]::Escape($fakeAwsKey)) $r10a.Out
# Индекс после срабатывания хука обязан остаться пустым — сканирование идёт через
# `git add --dry-run` (git явно обещает ничего не менять), а не через настоящий add.
$stagedAfter10 = & $gitExe -C $p10a diff --cached --stat
Check 'git add --dry-run не оставил побочных следов в индексе' (-not $stagedAfter10) $stagedAfter10

# Тот же секрет, но git add адресует файл по имени, а не -A — pathspec тоже уходит
# настоящему git (git add --dry-run <файл>), а не собственному разбору.
$p10b = New-GitFixture 'scan-add-named-commit-bypass'
Set-Content -LiteralPath (Join-Path $p10b 'creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r10b = Invoke-SecretScan -ProjectDir $p10b -Command 'git add creds.txt && git commit -m secret'
Check 'git add <файл> && git commit: хук тоже блокирует (не только с -A)' (
    $r10b.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r10b.Out
Check 'git add <файл> && git commit: код возврата хука 2' ($r10b.Code -eq 2) "код $($r10b.Code)"
# Копия ответа под своим именем: $r10b дальше переиспользуется в разделе 12 (doctor) под
# ТЕМ ЖЕ именем для другого сценария — раздел 17 ссылается на этот сохранённый ответ, а
# не на $r10b, чтобы не читать чужой, более поздний вывод по случайному совпадению имени.
$r10bAddNamedOut = $r10b.Out

# Регресс-контроль: чистый add+commit (без секрета) по-прежнему проходит молча — фикс не
# начал блокировать любую связку add+commit как таковую.
$p10c = New-GitFixture 'scan-add-commit-clean'
Set-Content -LiteralPath (Join-Path $p10c 'note.txt') -Value 'просто текст, без секретов' -Encoding UTF8
$r10c = Invoke-SecretScan -ProjectDir $p10c -Command 'git add -A && git commit -m note'
Check 'git add -A && git commit без секрета проходит молча (регресс не внесён)' (-not $r10c.Out.Trim()) $r10c.Out
Check 'чистый add+commit: код возврата хука 0' ($r10c.Code -eq 0) "код $($r10c.Code): $($r10c.Out)"

# Регрессия найдена ЧЕТВЁРТЫМ ревью M-05: `git ls-files --others --exclude-standard`
# уважает core.quotepath (по умолчанию true у git) и C-квотирует не-ASCII байты имени
# файла ("\320\272..."), а `git add --dry-run` печатает то же имя как есть, без
# квотирования — из-за расхождения новый файл с кириллическим именем не находил себя в
# списке неотслеживаемых и не сканировался вообще, хотя реально уходил в коммит.
$p10d = New-GitFixture 'scan-add-commit-cyrillic-bypass'
Set-Content -LiteralPath (Join-Path $p10d 'ключи.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r10d = Invoke-SecretScan -ProjectDir $p10d -Command 'git add -A && git commit -m x'
Check 'git add -A && git commit: кириллическое имя файла тоже блокирует (core.quotepath)' (
    $r10d.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r10d.Out
Check 'кириллица: код возврата хука 2' ($r10d.Code -eq 2) "код $($r10d.Code): $($r10d.Out)"
Check 'кириллица: причина называет файл и строку' ($r10d.Out -match 'ключи\.txt:1') $r10d.Out
Check 'кириллица: само значение ключа НЕ печатается' ($r10d.Out -notmatch [regex]::Escape($fakeAwsKey)) $r10d.Out

# ---------------------------------------------------------------------------
Section '11. secret-scan.sh: значение-ссылка на переменную/окружение — не находка'
# ---------------------------------------------------------------------------
# Регрессия найдена ревью M-05: правило "присвоение секрета" считало находкой код, который
# УЖЕ читает секрет из окружения (`process.env.X`, `os.environ[...]`, `os.getenv(...)`,
# `config.api_key`, обращение к другой переменной вида `pwd = password`) — то есть блокировало
# ровно то решение, которое сам текст отказа советует принять. Четыре воспроизведения ревью:
$refFiles = @(
    @{ Name = 'app.js'; Content = 'const token = process.env.GITHUB_TOKEN;'; What = 'JS: token = process.env.*' }
    @{ Name = 'app2.js'; Content = 'const apiKey = config.api_key;'; What = 'JS: apiKey = config.*' }
    @{ Name = 'app3.js'; Content = 'const secret = process.env.MY_SECRET;'; What = 'JS: secret = process.env.*' }
    @{ Name = 'app.py'; Content = 'API_KEY = os.environ["OPENAI_API_KEY"]'; What = 'Python: API_KEY = os.environ[...]' }
    @{ Name = 'app2.py'; Content = 'pwd = password or os.getenv("DB_PASSWORD")'; What = 'Python: pwd = password or os.getenv(...)' }
)
foreach ($rf in $refFiles) {
    $p11 = New-GitFixture ('scan-ref-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    Set-Content -LiteralPath (Join-Path $p11 $rf.Name) -Value $rf.Content -Encoding UTF8
    & $gitExe -C $p11 add -A 2>&1 | Out-Null
    $rRef = Invoke-SecretScan -ProjectDir $p11 -Command 'git -c user.name="t" -c user.email="t@local" commit -m note'
    Check "значение-ссылка не блокирует: $($rf.What)" (-not $rRef.Out.Trim()) $rRef.Out
    & $gitExe -C $p11 restore --staged . 2>&1 | Out-Null
}

# Регресс-контроль: реальный литерал под тем же ключевым словом по-прежнему блокируется —
# фильтр значений-ссылок не должен был выключить правило целиком.
$p11b = New-GitFixture 'scan-real-literal-still-blocks'
Set-Content -LiteralPath (Join-Path $p11b 'config.js') -Value 'const password = "realsecretvalue123";' -Encoding UTF8
& $gitExe -C $p11b add -A 2>&1 | Out-Null
$r11b = Invoke-SecretScan -ProjectDir $p11b -Command 'git -c user.name="t" -c user.email="t@local" commit -m note'
Check 'реальный литерал password = "..." по-прежнему блокируется (правило не выключено)' (
    $r11b.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r11b.Out
& $gitExe -C $p11b restore --staged . 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '12. doctor объявляет Windows требованием'
# ---------------------------------------------------------------------------
# $IsWindows у PowerShell — константа ("Cannot overwrite variable IsWindows because it is
# read-only"), поэтому ветка «не Windows» проверяется тестовым швом BCF_SIMULATE_NOT_WINDOWS,
# а не подменой автоматической переменной.
$p10 = New-GitFixture 'doctor-not-windows'
$r10 = Bcf @('doctor', '--no-probe', '--project', $p10) -Env @{ BCF_SIMULATE_NOT_WINDOWS = '1' }
Check 'doctor отказывает на "не Windows"' ($r10.Code -ne 0) "код $($r10.Code)"
# Матчим ИМЕННО текст гейта из doctor.ps1, а не голое 'Windows' — та подстрока встречается
# в куче безобидных мест (заголовок доктора, версия pwsh) и остаётся зелёной, даже когда
# сам гейт вырезан. Проверено мутацией: со снятой веткой gate в doctor.ps1 этот Check
# краснеет, а с голым 'Windows' — нет.
Check 'причина — конкретный текст гейта doctor.ps1' (
    $r10.Out -match [regex]::Escape('doctor поддерживает только Windows')
) $r10.Out
Check 'дальше живой пробы не идёт (нет вывода про роли/память)' ($r10.Out -notmatch 'ЖИВАЯ ПРОБА РОЛЕЙ|ПАМЯТЬ') $r10.Out

$r10b = Bcf @('doctor', '--no-probe', '--project', $p10)
Check 'на самой Windows doctor отрабатывает как обычно (регресс не внесён)' ($r10b.Out -notmatch 'doctor поддерживает только Windows') $r10b.Out

# Конкретная формулировка требования, а не голое 'Windows' (та подстрока была в обоих
# файлах и до правки M-05 — например "Windows PowerShell 5 не подходит" в SETUP.md).
Check 'README называет Windows требованием (конкретная формулировка)' (
    (Get-Content -Raw -LiteralPath (Join-Path $root 'README.md')) -match [regex]::Escape('Требуется **Windows**')
)
Check 'docs/SETUP.md называет Windows требованием (конкретная формулировка)' (
    (Get-Content -Raw -LiteralPath (Join-Path $root 'docs\SETUP.md')) -match [regex]::Escape('фабрика пока только под неё')
)

# ---------------------------------------------------------------------------
Section '13. CI: workflow гоняет tests/all.ps1 на push и pull_request на windows-latest'
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
Section '14. secret-scan.sh: `cd <каталог> && git add ... && git commit ...` не даёт обойти сканер'
# ---------------------------------------------------------------------------
# Регрессия найдена ЧЕТВЁРТЫМ ревью M-05: pathspec сегмента `git add` разбирался через
# `git add --dry-run -C <корень репозитория>` всегда, без учёта предшествующего
# `cd <каталог>` в той же командной строке — относительный путь, данный ИЗ подкаталога,
# не совпадал ни с чем при поиске от корня, и файл выпадал из сканирования целиком.
# Воспроизведение ревью: секрет в sub/creds.txt, `cd sub && git add creds.txt && git commit -m x`.
$p14 = New-GitFixture 'scan-cd-add-commit-bypass'
New-Item -ItemType Directory -Force -Path (Join-Path $p14 'sub') | Out-Null
Set-Content -LiteralPath (Join-Path $p14 'sub\creds.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
$r14 = Invoke-SecretScan -ProjectDir $p14 -Command 'cd sub && git add creds.txt && git commit -m x'
Check 'cd sub && git add && git commit: хук блокирует секрет из подкаталога' (
    $r14.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r14.Out
Check 'cd-обход: код возврата хука 2' ($r14.Code -eq 2) "код $($r14.Code): $($r14.Out)"
Check 'cd-обход: причина называет путь относительно корня репозитория' ($r14.Out -match 'sub/creds\.txt:1') $r14.Out
Check 'cd-обход: само значение ключа НЕ печатается' ($r14.Out -notmatch [regex]::Escape($fakeAwsKey)) $r14.Out

# Регресс-контроль: та же связка `cd && add && commit` без секрета проходит молча — фикс
# не начал блокировать любой cd+add+commit как таковой.
$p14b = New-GitFixture 'scan-cd-add-commit-clean'
New-Item -ItemType Directory -Force -Path (Join-Path $p14b 'sub') | Out-Null
Set-Content -LiteralPath (Join-Path $p14b 'sub\note.txt') -Value 'просто текст, без секретов' -Encoding UTF8
$r14b = Invoke-SecretScan -ProjectDir $p14b -Command 'cd sub && git add note.txt && git commit -m x'
Check 'cd sub && git add && git commit без секрета проходит молча (регресс не внесён)' (-not $r14b.Out.Trim()) $r14b.Out

# ---------------------------------------------------------------------------
Section '15. secret-scan.sh: python не найден — отказ на git commit, тишина на прочих командах'
# ---------------------------------------------------------------------------
# Регрессия найдена ЧЕТВЁРТЫМ ревью M-05: без python хук выходил кодом 0 БЕЗ разбора
# чего бы то ни было — гейт секретов, зарегистрированный в settings.json, молча исчезал
# на любой машине без python, хотя docs/SETUP.md объявляет python опциональным (только
# под память). PATH подрезается ТОЛЬКО на время вызова хука (Invoke-SecretScan
# -ForceNoPython), сам тестовый прогон и остальные секции им не задеты.
$p15 = New-GitFixture 'scan-no-python'
$r15commit = Invoke-SecretScan -ProjectDir $p15 -Command 'git -c user.name="t" -c user.email="t@local" commit -m x' -ForceNoPython
Check 'без python: commit-подобная команда отказывает явно (permissionDecision: deny)' (
    $r15commit.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r15commit.Out
Check 'без python: код возврата хука 2 на коммите' ($r15commit.Code -eq 2) "код $($r15commit.Code): $($r15commit.Out)"
Check 'без python: причина называет python, а не молчит про секрет' ($r15commit.Out -match 'python') $r15commit.Out

$r15status = Invoke-SecretScan -ProjectDir $p15 -Command 'git status' -ForceNoPython
Check 'без python: не-commit команда по-прежнему проходит молча (хук не блокирует весь Bash)' (
    $r15status.Code -eq 0 -and -not $r15status.Out.Trim()
) "код $($r15status.Code): $($r15status.Out)"

# Контроль сценария: с обычным PATH (python на месте) тот же коммит без секрета проходит
# молча — доказывает, что деградация специфична именно к отсутствию python, а не к
# сломанному сценарию вообще.
$r15control = Invoke-SecretScan -ProjectDir $p15 -Command 'git -c user.name="t" -c user.email="t@local" commit -m ok'
Check 'контроль сценария: с обычным PATH тот же коммит без секрета проходит молча' (-not $r15control.Out.Trim()) $r15control.Out

# ---------------------------------------------------------------------------
Section '16. secret-scan.sh: `git add <файл> && git commit` не задевает секрет в файле, который эта команда не добавляет'
# ---------------------------------------------------------------------------
# ПЯТОЕ РЕВЬЮ M-05 (опровержение находки 10): при has_add_stage хук до этой правки
# добавлял к --cached БЕЗУСЛОВНО ПОЛНЫЙ `git diff` рабочего дерева — тот же вызов, что и
# для -a/-am/--all. Секрет в отслеживаемом файле, который команда не трогает вовсе,
# блокировал чужой чистый коммит. Воспроизведение ревью: cfg.txt правится локально на
# `password = "MyRealLocalPass123"` и НЕ добавляется, коммитится только новый doc.md
# командой `git add doc.md && git commit -m doc`; после реального `git add doc.md`
# `git diff --cached --name-only` показывает один doc.md — cfg.txt в этот коммит не идёт.
$p16 = New-GitFixture 'scan-add-scoped-not-whole-repo'
Set-Content -LiteralPath (Join-Path $p16 'cfg.txt') -Value 'host = "localhost"' -Encoding UTF8
& $gitExe -C $p16 add -A 2>&1 | Out-Null
& $gitExe -C $p16 commit -qm 'cfg.txt без секрета' 2>&1 | Out-Null
# Правим отслеживаемый cfg.txt и НЕ делаем git add — секрет остаётся только в рабочем
# дереве, вне индекса и вне области add ниже.
Set-Content -LiteralPath (Join-Path $p16 'cfg.txt') -Value 'password = "MyRealLocalPass123"' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $p16 'doc.md') -Value 'просто документ, без секретов' -Encoding UTF8

# Контроль сценария: после реального `git add doc.md` в этот коммит идёт только doc.md.
& $gitExe -C $p16 add doc.md 2>&1 | Out-Null
$realStaged16 = & $gitExe -C $p16 diff --cached --name-only
& $gitExe -C $p16 restore --staged doc.md 2>&1 | Out-Null
Check 'контроль сценария: настоящий git add doc.md стажирует только doc.md' (
    ($realStaged16 | Measure-Object).Count -eq 1 -and $realStaged16 -eq 'doc.md'
) $realStaged16

$r16a = Invoke-SecretScan -ProjectDir $p16 -Command 'git add doc.md && git -c user.name="t" -c user.email="t@local" commit -m doc'
Check 'git add doc.md && git commit: посторонний секрет в cfg.txt НЕ блокирует (не входит в add)' (
    $r16a.Code -eq 0 -and -not $r16a.Out.Trim()
) "код $($r16a.Code): $($r16a.Out)"

# Регресс-контроль А: тот же секрет, добавленный ИМЕНЕМ файла, по-прежнему блокирует —
# сужение диффа до add_stage_paths не потеряло путь, который команда РЕАЛЬНО называет.
$r16b = Invoke-SecretScan -ProjectDir $p16 -Command 'git add cfg.txt && git -c user.name="t" -c user.email="t@local" commit -m x'
Check 'git add cfg.txt && git commit: тот же секрет, названный по имени, по-прежнему блокирует' (
    $r16b.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r16b.Out
Check 'git add cfg.txt: код возврата хука 2' ($r16b.Code -eq 2) "код $($r16b.Code)"
Check 'git add cfg.txt: причина называет cfg.txt:1' ($r16b.Out -match 'cfg\.txt:1') $r16b.Out

# Регресс-контроль Б: -A по-прежнему видит cfg.txt (git add --dry-run -A перечисляет и
# изменённые отслеживаемые файлы, не только новые) и блокирует — сужение диффа не
# ослабило -A/--all.
$r16c = Invoke-SecretScan -ProjectDir $p16 -Command 'git add -A && git -c user.name="t" -c user.email="t@local" commit -m x'
Check 'git add -A && git commit: cfg.txt по-прежнему в области видимости -A и блокирует' (
    $r16c.Out -match '"permissionDecision"\s*:\s*"deny"'
) $r16c.Out
Check 'git add -A: причина называет cfg.txt:1' ($r16c.Out -match 'cfg\.txt:1') $r16c.Out

# ---------------------------------------------------------------------------
Section '17. secret-scan.sh: текст отказа советует по месту находки, а не всегда "git restore --staged"'
# ---------------------------------------------------------------------------
# ПЯТОЕ РЕВЬЮ M-05 (опровержение находки 11): текст отказа всегда советовал
# `git restore --staged <файл>` — верно только для находки, УЖЕ лежащей в реальном
# индексе. Для находки из рабочего дерева (-a/-am/--all, add из этой же команды, новый
# файл) эта команда ничего не отменяет: индекс на этот файл пуст, `git restore --staged`
# не находит, что снимать.
Check 'находка РЕАЛЬНО в индексе ($r6, раздел 6: git add -A сделан заранее, вне команды): совет — git restore --staged' (
    $r6.Out -match 'git restore --staged'
) $r6.Out
Check '-am ($r9a, раздел 9): совет НЕ предлагает git restore --staged (нечего снимать)' (
    $r9a.Out -notmatch 'git restore --staged'
) $r9a.Out
Check 'git add -A && git commit ($r10a, раздел 10): совет НЕ предлагает git restore --staged' (
    $r10a.Out -notmatch 'git restore --staged'
) $r10a.Out
Check 'git add <файл> && git commit ($r10bAddNamedOut, раздел 10): совет НЕ предлагает git restore --staged' (
    $r10bAddNamedOut -notmatch 'git restore --staged'
) $r10bAddNamedOut
Check 'cd sub && git add && git commit ($r14, раздел 14): совет НЕ предлагает git restore --staged' (
    $r14.Out -notmatch 'git restore --staged'
) $r14.Out

# Смешанный случай: один секрет РЕАЛЬНО в индексе (застейджен отдельным git add до этой
# команды), второй — в новом файле, который добавляет САМА эта команда. Оба совета
# обязаны прозвучать одновременно, каждый про свою находку.
$p17 = New-GitFixture 'scan-mixed-staged-and-unstaged'
Set-Content -LiteralPath (Join-Path $p17 'indexed.txt') -Value "aws_key = `"$fakeAwsKey`"" -Encoding UTF8
& $gitExe -C $p17 add indexed.txt 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $p17 'new.txt') -Value 'const password = "realsecretvalue123";' -Encoding UTF8
$r17 = Invoke-SecretScan -ProjectDir $p17 -Command 'git add new.txt && git -c user.name="t" -c user.email="t@local" commit -m mixed'
Check 'смешанный случай: обе находки названы (indexed.txt и new.txt)' (
    $r17.Out -match 'indexed\.txt:1' -and $r17.Out -match 'new\.txt:1'
) $r17.Out
Check 'смешанный случай: совет "git restore --staged" присутствует (для indexed.txt)' (
    $r17.Out -match 'git restore --staged'
) $r17.Out
Check 'смешанный случай: совет "не включай этот путь в add" присутствует (для new.txt)' (
    $r17.Out -match 'не включай этот путь в add'
) $r17.Out
& $gitExe -C $p17 restore --staged indexed.txt 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section '18. документация: граница защиты названа, опечатка "диff" не возвращалась'
# ---------------------------------------------------------------------------
# Раздел проверяет две находки четвёртого пункта ревью, не покрытые кодом хука:
# ГРАНИЦА (файл, созданный в той же командной строке, не виден PreToolUse — раньше
# документация читалась как полная защита) и опечатка смешанным алфавитом "диff".
$setupTxt = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\SETUP.md')
Check 'docs/SETUP.md называет границу защиты (файл, созданный той же командной строкой)' (
    $setupTxt -match 'Граница защиты'
)
Check 'docs/SETUP.md: граница даёт конкретный пример (echo ... && git add ... && git commit)' (
    $setupTxt -match 'echo\s+секрет\s*>\s*c\.txt'
)

$archTxt = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\ARCHITECTURE.md')
$cfgTxt  = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\CONFIG.md')
Check 'docs/ARCHITECTURE.md: опечатка смешанным алфавитом не возвращалась' ($archTxt -notmatch 'диff')
Check 'docs/CONFIG.md: опечатка смешанным алфавитом не возвращалась' ($cfgTxt -notmatch 'диff')
Check 'docs/ARCHITECTURE.md: слово написано целиком кириллицей' ($archTxt -match 'дифф')
Check 'docs/CONFIG.md: слово написано целиком кириллицей' ($cfgTxt -match 'дифф')

# ---------------------------------------------------------------------------
Restore-TestEnv
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  ИТОГ: прошло $($script:Pass), провалено $($script:Fail)") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Fail) { exit 1 }
exit 0
