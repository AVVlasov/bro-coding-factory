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
    param([string]$ProjectDir, [string]$Command)
    $payload = (@{ tool_input = @{ command = $Command } } | ConvertTo-Json -Compress)
    $pf = Join-Path $sandbox ('hook-in-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Set-Content -LiteralPath $pf -Value $payload -Encoding UTF8 -NoNewline
    $prev = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    try {
        $sh = ($secretScanSrc -replace '\\', '/')
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
Section '10. doctor объявляет Windows требованием'
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
Section '11. CI: workflow гоняет tests/all.ps1 на push и pull_request на windows-latest'
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
Restore-TestEnv
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  ИТОГ: прошло $($script:Pass), провалено $($script:Fail)") -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Fail) { exit 1 }
exit 0
