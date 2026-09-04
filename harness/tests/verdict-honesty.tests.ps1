# verdict-honesty.tests.ps1 — вердикт не имеет права звучать зеленее, чем есть.
#
#   pwsh harness/tests/verdict-honesty.tests.ps1
#
# ЧТО ЛОВЯТ ЭТИ ТЕСТЫ. Четыре места, где фабрика говорила «готово» без права на это.
#
# 1. Проверки на слитом дереве были fail-open. Команда шла через Invoke-Expression, а
#    вердикт читался из $LASTEXITCODE — который несуществующая команда в pwsh 7 НЕ
#    трогает. Гейт, который не смог запуститься, читался как зелёный: задача уезжала в
#    основную ветку и попадала в PASS. Первый раздел воспроизводит это на самом языке,
#    чтобы регрессия была видна, если поведение pwsh однажды изменится.
#
# 2. Emit-RunAllReport — функция, решающая, звучит ли слово COMPLETE, — не была покрыта
#    ни одним тестом репозитория. Она написана headless-тестируемой (BCF_REPORT_LIB_ONLY)
#    специально ради этого, и никто ею не воспользовался.
#
# 3. Кодовый агент мог править config/ — источник собственного вердикта. docs/WORKFLOW.md
#    обещал, что не может; кода за обещанием не стояло.
#
# 4. Ночной прогон заканчивался модальным окном: процесс висел до нажатия ОК, и код
#    возврата, ради которого всё писалось, никто не получал.
#
# Плюс git-состояние проекта: оборванный прогон оставляет дерево в MERGING, и следующая
# ночь уходит целиком на очередь, где каждая задача падает по чужой причине.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # корень фабрики
$runAll  = Join-Path $root 'harness\run-all.ps1'
$hookSrc = Join-Path $root 'templates\claude\hooks\agent-infra-protect.sh'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-verdict-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ok   $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ПРОВАЛ  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Assert-True { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-False { param($Cond, [string]$Msg = 'ожидалось ложное') if ($Cond) { throw $Msg } }
function Assert-Eq {
    param($Actual, $Expected, [string]$Msg = '')
    if ("$Actual" -ne "$Expected") { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "ждал «$Expected», получил «$Actual»") }
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" +
               (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 20) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
$env:BCF_PROJECT_ROOT = $sandboxRoot
. (Join-Path $root 'harness\lib\bcf-context.ps1')
. (Join-Path $root 'harness\lib\scheduler.ps1')
. (Join-Path $root 'src\lib\git-readiness.ps1')

Write-Host ''
Write-Host "  ЧЕСТНОСТЬ ВЕРДИКТА   песочница: $sandboxRoot" -ForegroundColor Cyan

# --- 1. Fail-open: воспроизведение дефекта на самом языке ---------------------------------
Write-Host ''
Write-Host '1. Fail-open в pwsh: несуществующая команда не трогает $LASTEXITCODE' -ForegroundColor White

# Замер идёт в отдельном процессе: в текущем $LASTEXITCODE уже испачкан предыдущими
# вызовами, и «ноль остался от git» было бы не видно.
function Invoke-Pwsh {
    param([string]$Script)
    $f = Join-Path $sandboxRoot ("probe-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    Set-Content -LiteralPath $f -Value $Script -Encoding UTF8
    $out = (& pwsh -NoProfile -NonInteractive -File $f 2>&1 | Out-String)
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return $out
}

It 'ноль от предыдущей команды переживает несуществующую' {
    $o = Invoke-Pwsh @'
& git --version | Out-Null
Invoke-Expression "definitely-not-a-real-command 2>&1" | Out-Null
Write-Output "LASTEXITCODE=$LASTEXITCODE"
'@
    Assert-Match $o 'LASTEXITCODE=0' 'pwsh перестал наследовать код — предохранитель Get-Command можно пересмотреть'
}

It 'чужой ненулевой код тоже наследуется — липкость в обе стороны' {
    $o = Invoke-Pwsh @'
Invoke-Expression "cmd /c exit 7 2>&1" | Out-Null
Invoke-Expression "definitely-not-a-real-command 2>&1" | Out-Null
Write-Output "LASTEXITCODE=$LASTEXITCODE"
'@
    Assert-Match $o 'LASTEXITCODE=7' 'ненулевой код перестал липнуть'
}

It 'старое тело цикла объявляет ненайденный гейт зелёным' {
    # Дословно строки 250-253 из main:harness/lib/scheduler.ps1.
    $o = Invoke-Pwsh @'
$MergeChecks = @('git --version', 'mvn -q -DskipTests verify')
$mergeOk = $true
foreach ($cmd in $MergeChecks) {
    Invoke-Expression "$cmd 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) { $mergeOk = $false; break }
}
Write-Output "mergeOk=$mergeOk"
'@
    Assert-Match $o 'mergeOk=True' 'дефект не воспроизвёлся — проверь, что mvn действительно не установлен'
}

# --- 2. Invoke-MergeCheck: четыре исхода, зелёный только один -----------------------------
Write-Host ''
Write-Host '2. Проверка на слитом дереве: green / red / not-runnable / timeout' -ForegroundColor White

It 'команды нет → FAIL с отдельной причиной, а не зелёный' {
    $r = Invoke-MergeCheck 'mvn -q -DskipTests verify' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-False $r.Ok 'ненайденная команда прошла как зелёная — это и есть fail-open'
    Assert-Eq $r.Kind 'not-runnable'
    Assert-Match $r.Reason 'не запустилась' 'причина не отличает «не запустилась» от «красная»'
    Assert-Match $r.Reason 'mvn' 'в причине не названа команда, которой не хватает'
}

It 'зелёная команда остаётся зелёной' {
    $r = Invoke-MergeCheck 'git --version' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-True $r.Ok "зелёная проверка прочитана как красная: $($r.Reason)"
    Assert-Eq $r.Kind 'green'
}

It 'красная команда красная, и настоящий код возврата сохранён' {
    $r = Invoke-MergeCheck 'cmd /c exit 7' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-False $r.Ok
    Assert-Eq $r.Kind 'red'
    Assert-Eq $r.ExitCode 7 'код подменён кодом самого pwsh — в отчёте будет «код 1» вместо семёрки'
}

It 'ошибка PowerShell без кода возврата читается как красная, а не зелёная' {
    # Write-Error не выставляет $LASTEXITCODE вовсе. Наивное `; exit $LASTEXITCODE`
    # превратило бы это в ноль — тот же fail-open с другого конца.
    $r = Invoke-MergeCheck 'Write-Error "боль"' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-False $r.Ok 'непойманная ошибка прошла как зелёная'
    Assert-Eq $r.Kind 'red'
}

It 'исключение внутри проверки красное' {
    $r = Invoke-MergeCheck 'throw "боль"' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-False $r.Ok
    Assert-Eq $r.Kind 'red'
}

It 'код не липнет от проверки к проверке' {
    $red = Invoke-MergeCheck 'cmd /c exit 3' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-False $red.Ok
    $green = Invoke-MergeCheck 'git --version' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-True $green.Ok 'зелёная проверка после красной покраснела — код унаследован'
    $nr = Invoke-MergeCheck 'definitely-not-a-real-command' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-Eq $nr.Kind 'not-runnable' 'после зелёной ненайденная команда снова стала зелёной'
}

It 'проверка, не уложившаяся в срок, не считается пройденной' {
    $r = Invoke-MergeCheck 'Start-Sleep -Seconds 30' -WorkDir $sandboxRoot -TimeoutSec 2
    Assert-False $r.Ok
    Assert-Eq $r.Kind 'timeout'
}

It 'хвост вывода попадает в причину' {
    $r = Invoke-MergeCheck 'Write-Output "сборка упала на модуле auth"; exit 1' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-Match $r.Reason 'модуле auth' 'причина не несёт ни строчки вывода — «проверки красные» и всё'
}

It 'команда исполняется в дереве, где идёт слияние' {
    $marker = Join-Path $sandboxRoot 'here.txt'
    Set-Content -LiteralPath $marker -Value 'x' -Encoding UTF8
    $r = Invoke-MergeCheck 'if (Test-Path ./here.txt) { exit 0 } else { exit 9 }' -WorkDir $sandboxRoot -TimeoutSec 60
    Assert-True $r.Ok 'рабочий каталог проверки не совпал с деревом слияния'
}

# --- 3. Разбор имени программы ------------------------------------------------------------
Write-Host ''
Write-Host '3. Get-MergeCheckExecutable: что именно пробовать через Get-Command' -ForegroundColor White

It 'первое слово простой команды' { Assert-Eq (Get-MergeCheckExecutable 'cargo test --all') 'cargo' }
It 'путь в кавычках с пробелами' { Assert-Eq (Get-MergeCheckExecutable '"C:/Program Files/x/y.exe" -q') 'C:/Program Files/x/y.exe' }
It 'относительный путь остаётся относительным' { Assert-Eq (Get-MergeCheckExecutable './gradlew build') './gradlew' }
It 'конвейер и подстановка разбору не поддаются' {
    Assert-Eq (Get-MergeCheckExecutable '& { npm test }') '' 'вызов через & разобран как имя программы'
    Assert-Eq (Get-MergeCheckExecutable '$env:X = 1; npm test') '' 'подстановка разобрана как имя программы'
}
It 'пустая команда не выдумывает имя' { Assert-Eq (Get-MergeCheckExecutable '   ') '' }

# --- 4. Emit-RunAllReport: когда звучит слово COMPLETE -------------------------------------
Write-Host ''
Write-Host '4. Emit-RunAllReport: COMPLETE только при закрытой очереди, зелёных сценариях и нуле P1' -ForegroundColor White

$reportProj = Join-Path $sandboxRoot 'report'
New-Item -ItemType Directory -Force -Path (Join-Path $reportProj 'config') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $reportProj 'tests') | Out-Null
Set-Content -LiteralPath (Join-Path $reportProj 'tests\j01.txt') -Value 'доказательство' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $reportProj 'tests\j02.txt') -Value 'доказательство' -Encoding UTF8

# Прогон отчёта — отдельным процессом: функция ходит в journey-gate, меняет рабочий каталог
# и пишет файлы состояния. В общем процессе один случай отравлял бы следующий.
$reportRunner = Join-Path $sandboxRoot 'run-report.ps1'
Set-Content -LiteralPath $reportRunner -Encoding UTF8 -Value @'
param([string]$RunAll, [string]$Root, [string]$Review, [string]$Status, [string]$Payload, [string]$Result)
$ErrorActionPreference = 'Stop'
$in = Get-Content -Raw -LiteralPath $Payload | ConvertFrom-Json
$env:BCF_REPORT_LIB_ONLY = '1'
$env:BCF_PROJECT_ROOT = $Root
. $RunAll -ProjectRoot $Root
$rep = Emit-RunAllReport -Passed @($in.passed) -Stuck @($in.stuck) -Total ([int]$in.total) `
    -Root $Root -ReviewFile $Review -Ts '2026-09-04 00:00:00' -StatusFile $Status -AcceptanceP1 ([int]$in.p1)
([ordered]@{
    complete    = [bool]$rep.complete
    passed      = [int]$rep.passed
    stuck       = [int]$rep.stuck
    needsHuman  = [int]$rep.needsHuman
    gateBlocked = [int]$rep.gateBlocked
    rootList    = [string]$rep.rootList
    review      = (Get-Content -Raw -LiteralPath $Review)
    status      = (Get-Content -Raw -LiteralPath $Status)
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Result -Encoding UTF8
'@

function Invoke-Report {
    param([string[]]$Passed = @(), [array]$Stuck = @(), [int]$Total, [int]$P1 = 0)
    $tag     = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $payload = Join-Path $sandboxRoot "payload-$tag.json"
    $result  = Join-Path $sandboxRoot "result-$tag.json"
    $review  = Join-Path $sandboxRoot "REVIEW-$tag.md"
    $status  = Join-Path $sandboxRoot "status-$tag.json"
    (@{ passed = @($Passed); stuck = @($Stuck); total = $Total; p1 = $P1 } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath $payload -Encoding UTF8
    & pwsh -NoProfile -NonInteractive -File $reportRunner -RunAll $runAll -Root $reportProj `
        -Review $review -Status $status -Payload $payload -Result $result *> $null
    if (-not (Test-Path -LiteralPath $result)) { throw "Emit-RunAllReport не отработал (нет $result)" }
    $r = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
    $r | Add-Member -NotePropertyName statusObj -NotePropertyValue ($r.status | ConvertFrom-Json)
    return $r
}

function Set-Journeys {
    param([string]$Kind)
    $f = Join-Path $reportProj 'config\journeys.json'
    switch ($Kind) {
        'none'    { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        'ok'      { Set-Content -LiteralPath $f -Encoding UTF8 -Value (@'
{ "command": "Write-Output 'J-01 зелёный'",
  "journeys": [ { "id": "J-01", "title": "человек заводит запись", "proof": "tests/j01.txt" } ] }
'@) }
        'partial' { Set-Content -LiteralPath $f -Encoding UTF8 -Value (@'
{ "command": "Write-Output 'J-01 зелёный'",
  "journeys": [ { "id": "J-01", "title": "человек заводит запись", "proof": "tests/j01.txt" },
                { "id": "J-02", "title": "человек её отменяет", "proof": "tests/j02.txt", "status": "planned" } ] }
'@) }
        'fail'    { Set-Content -LiteralPath $f -Encoding UTF8 -Value (@'
{ "command": "Write-Output 'J-01 зелёный'",
  "journeys": [ { "id": "J-01", "title": "человек заводит запись", "proof": "tests/нет-такого.txt" } ] }
'@) }
    }
}

It 'закрытая очередь и зелёные сценарии при нуле P1 → COMPLETE' {
    Set-Journeys 'ok'
    $r = Invoke-Report -Passed @('TASK-01', 'TASK-02') -Stuck @() -Total 2
    Assert-True $r.complete "COMPLETE не прозвучал там, где обязан:`n$($r.review)"
    Assert-Match $r.review 'Статус:\*\* COMPLETE'
    Assert-Eq $r.statusObj.complete 'True'
    Assert-Eq $r.statusObj.queue_closed 'True'
}

It 'незакрытая очередь → INCOMPLETE даже при зелёных сценариях' {
    Set-Journeys 'ok'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @(@{ Task = 'TASK-02'; Reason = 'агент упёрся в потолок итераций' }) -Total 2
    Assert-False $r.complete 'неполный прогон объявлен готовым'
    Assert-Match $r.review 'Статус:\*\* INCOMPLETE'
    Assert-Match $r.review 'НЕ принимать за «готово»'
    Assert-Eq $r.needsHuman 1
}

It 'закрытая очередь без реестра сценариев → не COMPLETE, и сказано почему' {
    Set-Journeys 'none'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @() -Total 1
    Assert-False $r.complete 'закрытая очередь приравнена к готовому продукту'
    Assert-Match $r.review 'ПРОДУКТ НЕ ПРОВЕРЕН'
    Assert-Eq $r.statusObj.journeys 'not-configured'
}

It 'красные сценарии при закрытой очереди → не COMPLETE' {
    Set-Journeys 'fail'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @() -Total 1
    Assert-False $r.complete
    Assert-Match $r.review 'СЦЕНАРИИ КРАСНЫЕ'
    Assert-Eq $r.statusObj.journeys 'fail'
}

It 'часть путей ещё planned → доказано частично, не COMPLETE' {
    Set-Journeys 'partial'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @() -Total 1
    Assert-False $r.complete 'planned-пути не помешали объявить готовность'
    Assert-Match $r.review 'ДОКАЗАН ЧАСТИЧНО'
    Assert-Eq $r.statusObj.journeys 'partial'
}

It 'P1 приёмки отменяет COMPLETE при всём зелёном' {
    Set-Journeys 'ok'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @() -Total 1 -P1 3
    Assert-False $r.complete 'три P1 не помешали напечатать COMPLETE'
    Assert-Match $r.review 'ЕСТЬ P1 ПРИЁМКИ'
    Assert-Eq $r.statusObj.acceptance_p1 3
}

It 'каскад-гейт сводится к корню, а не к списку следствий' {
    Set-Journeys 'ok'
    $stuck = @(
        @{ Task = 'TASK-01'; Reason = 'агент упёрся в потолок итераций' },
        @{ Task = 'TASK-02'; Reason = 'gate-block: предшественник TASK-01 не закрыт' },
        @{ Task = 'TASK-03'; Reason = 'gate-block: предшественник TASK-02 не закрыт' }
    )
    $r = Invoke-Report -Passed @() -Stuck $stuck -Total 3
    Assert-Eq $r.needsHuman 1 'корней должно быть ровно один'
    Assert-Eq $r.gateBlocked 2
    Assert-Match $r.rootList 'TASK-01 \(блокирует 2\)' "корень назван неверно: $($r.rootList)"
    Assert-Match $r.review 'Корень: почини это первым'
}

It 'blocks у корня без блокируемых — пустой список, а не [null]' {
    Set-Journeys 'ok'
    $r = Invoke-Report -Passed @() -Stuck @(@{ Task = 'TASK-01'; Reason = 'агент упал' }) -Total 1
    Assert-NoMatch $r.status 'null' 'в машиночитаемом статусе снова появился null — «блокирует 1» там, где не блокирует никого'
    Assert-Eq @($r.statusObj.needs_human[0].blocks).Count 0
}

It 'машиночитаемый статус называет все три условия готовности' {
    Set-Journeys 'ok'
    $r = Invoke-Report -Passed @('TASK-01') -Stuck @() -Total 1 -P1 2
    foreach ($k in @('complete', 'queue_closed', 'journeys', 'acceptance_p1')) {
        Assert-Match $r.status "`"$k`"" "в статусе нет поля $k — вызывающий агент не сможет отличить причины"
    }
}

# --- 5. agent-infra-protect.sh: config/ и tasks/ ------------------------------------------
Write-Host ''
Write-Host '5. Хук agent-infra-protect: чего кодовый агент не правит (прогон через Git Bash)' -ForegroundColor White

$bash = Get-BcfBash
$hookProj = Join-Path $sandboxRoot 'hookproj'
New-Item -ItemType Directory -Force -Path $hookProj | Out-Null
$hookCopy = Join-Path $hookProj 'agent-infra-protect.sh'
Copy-Item -LiteralPath $hookSrc -Destination $hookCopy -Force

# Пути внутри Git Bash: C:\x → C:/x. Хук нормализует их сам, но передавать надо то же,
# что передаёт Claude Code, — абсолютный путь Windows.
function Invoke-Hook {
    param([string]$FilePath, [string]$ProjectDir = $hookProj)
    if (-not $bash) { throw 'Git Bash не найден — .sh-хуки проверить нечем (BCF_BASH задаёт путь явно)' }
    $payload = (@{ tool_input = @{ file_path = $FilePath } } | ConvertTo-Json -Compress)
    $pf = Join-Path $sandboxRoot ('hook-in-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Set-Content -LiteralPath $pf -Value $payload -Encoding UTF8 -NoNewline
    $prev = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $ProjectDir
    try {
        $sh = ($hookCopy -replace '\\', '/')
        $inp = ($pf -replace '\\', '/')
        $out = (& $bash -c "'$sh' < '$inp'" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $env:CLAUDE_PROJECT_DIR = $prev
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Code = $code; Out = $out }
}

It 'Git Bash найден — иначе .sh-хуки нечем проверять' {
    Assert-True $bash 'на машине нет bash, кроме WSL-лаунчера'
}

It 'config/checks.json — блок: агент не правит гейт, которым его судят' {
    $r = Invoke-Hook (Join-Path $hookProj 'config\checks.json')
    Assert-Eq $r.Code 2 "хук пропустил правку config/checks.json:`n$($r.Out)"
    Assert-Match $r.Out 'config/' 'в причине не назван config/'
}

It 'config/scope-map.json и config/journeys.json тоже под запретом' {
    foreach ($f in @('config\scope-map.json', 'config\journeys.json')) {
        $r = Invoke-Hook (Join-Path $hookProj $f)
        Assert-Eq $r.Code 2 "$f прошёл мимо хука"
    }
}

It 'src/config/ продукта остаётся своей — запрет не по слову config' {
    $r = Invoke-Hook (Join-Path $hookProj 'src\config\app.json')
    Assert-Eq $r.Code 0 "хук заблокировал продуктовый каталог конфигурации:`n$($r.Out)"
}

It 'tasks/.verdicts/ — блок: вердикт пишет обвязка, не подсудимый' {
    $r = Invoke-Hook (Join-Path $hookProj 'tasks\.verdicts\TASK-01.md')
    Assert-Eq $r.Code 2 "агент смог править собственный вердикт:`n$($r.Out)"
    Assert-Match $r.Out 'verdict'
}

It 'tasks/.acceptance, tasks/.inbox, tasks/.bugs, CURRENT-FOCUS — блок' {
    foreach ($f in @('tasks\.acceptance\TASK-01.md', 'tasks\.inbox\f.md', 'tasks\.bugs\b.json', 'tasks\CURRENT-FOCUS.md')) {
        $r = Invoke-Hook (Join-Path $hookProj $f)
        Assert-Eq $r.Code 2 "$f прошёл мимо хука"
    }
}

It 'тело задачи агент правит — иначе он не отметит DoD' {
    $r = Invoke-Hook (Join-Path $hookProj 'tasks\TASK-01-нарезка.md')
    Assert-Eq $r.Code 0 "хук запретил отмечать DoD в собственной задаче:`n$($r.Out)"
}

It 'старая защита обвязки цела: .claude/hooks и CLAUDE.md' {
    foreach ($f in @('.claude\hooks\x.sh', 'CLAUDE.md', '.claude\agents\worker.md')) {
        $r = Invoke-Hook (Join-Path $hookProj $f)
        Assert-Eq $r.Code 2 "$f перестал быть защищённым"
    }
}

It 'продуктовый код не трогаем' {
    $r = Invoke-Hook (Join-Path $hookProj 'src\app\main.ts')
    Assert-Eq $r.Code 0 "хук заблокировал обычную работу агента:`n$($r.Out)"
}

It 'относительный путь ловится так же, как абсолютный' {
    $r = Invoke-Hook 'config/checks.json'
    Assert-Eq $r.Code 2 'относительный путь прошёл мимо запрета'
}

It 'корень в POSIX-написании не открывает запрет' {
    # CLAUDE_PROJECT_DIR приходит в другом написании, чем file_path: префикс не совпадает,
    # и без запасного якоря по имени каталога rel остался бы абсолютным, а защита — открытой.
    $posix = '/' + ($hookProj -replace '^([A-Za-z]):', { $_.Groups[1].Value.ToLower() } ) -replace '\\', '/'
    $r = Invoke-Hook -FilePath (Join-Path $hookProj 'config\checks.json') -ProjectDir $posix
    Assert-Eq $r.Code 2 "при POSIX-написании корня запрет config/ отключился:`n$($r.Out)"
}

# --- 5б. Откат правки config/ на интеграции ------------------------------------------------
Write-Host ''
Write-Host '5б. Правка config/ из ветки задачи откатывается перед слиянием' -ForegroundColor White

function New-CfgFixture {
    $d = Join-Path $sandboxRoot ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Encoding UTF8 `
        -Value '{ "_default": ["cargo test --workspace", "cargo clippy -- -D warnings"] }'
    Set-Content -LiteralPath (Join-Path $d 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null
    return $d
}

It 'сужение checks.json откатано, путь возвращён вызывающему' {
    $d = New-CfgFixture
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Value '{ "_default": [] }' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'src\main.rs') -Value 'fn main() { работа }' -Encoding UTF8
    $undone = Undo-AgentConfigEdits -Worktree $d
    Assert-Eq @($undone).Count 1 "откат не заметил правку гейта: $($undone -join ', ')"
    # Индексация именно через @(): массив из одного элемента PowerShell разворачивает в
    # строку, и без обёртки [0] дал бы первую букву пути.
    Assert-Eq @($undone)[0] 'config/checks.json'
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $d 'config\checks.json')) 'cargo clippy' `
        'гейт остался сужённым — агент судит сам себя'
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $d 'src\main.rs')) 'работа' `
        'вместе с конфигом откатили работу задачи'
}

It 'новый файл в config/ удаляется: откатывать его нечем' {
    $d = New-CfgFixture
    Set-Content -LiteralPath (Join-Path $d 'config\journeys.json') -Value '{ "journeys": [] }' -Encoding UTF8
    $undone = Undo-AgentConfigEdits -Worktree $d
    Assert-Eq @($undone).Count 1
    Assert-False (Test-Path -LiteralPath (Join-Path $d 'config\journeys.json')) `
        'нетронутый git файл конфигурации уехал бы в слияние'
}

It 'без правок конфига откат ничего не делает и ничего не возвращает' {
    $d = New-CfgFixture
    Set-Content -LiteralPath (Join-Path $d 'src\main.rs') -Value 'fn main() { работа }' -Encoding UTF8
    $undone = Undo-AgentConfigEdits -Worktree $d
    Assert-Eq @($undone).Count 0 "откат сработал на пустом месте: $($undone -join ', ')"
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $d 'src\main.rs')) 'работа'
}

It 'src/config продукта откат не трогает' {
    $d = New-CfgFixture
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\config') | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'src\config\app.json') -Value '{ "порт": 8080 }' -Encoding UTF8
    $undone = Undo-AgentConfigEdits -Worktree $d
    Assert-Eq @($undone).Count 0 'откат забрал продуктовый каталог конфигурации'
    Assert-True (Test-Path -LiteralPath (Join-Path $d 'src\config\app.json'))
}

It 'нарушение попадает в журнал конфликтов, а не только в лог' {
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $root 'harness\lib\scheduler.ps1')) `
        "Register-TaskConflict -Pair @\(\`$task, '\(config\)'\) -Files \`$cfgTouched -Kind 'config-violation'" `
        'откат конфига перестал записываться как нарушение скоупа'
}

# --- 6. Ночной прогон заканчивается кодом возврата, а не окном ----------------------------
Write-Host ''
Write-Host '6. run-all: итог читается без нажатия ОК' -ForegroundColor White

$runAllText = Get-Content -Raw -LiteralPath $runAll
# Смотрим на исполняемые строки, а не на весь файл: комментарий, объясняющий, ПОЧЕМУ окна
# больше нет, называет убранный вызов по имени — и на нём же тест краснел бы вечно.
$runAllCode = ((Get-Content -LiteralPath $runAll) | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"

It 'в исполняемом коде run-all.ps1 нет MessageBox' {
    Assert-NoMatch $runAllCode 'MessageBox' 'модальное окно держит процесс до нажатия ОК — прогон по расписанию не завершается'
}

It 'System.Windows.Forms больше не подгружается' {
    Assert-NoMatch $runAllCode 'System\.Windows\.Forms'
    Assert-NoMatch $runAllCode 'Add-Type\s+-AssemblyName'
}

It 'объяснение, почему окна нет, осталось в файле' {
    Assert-Match $runAllText 'MessageBox' 'из файла пропала причина — следующая правка вернёт окно обратно'
}

It 'итог по-прежнему уходит в код возврата и в два файла' {
    Assert-Match $runAllText 'run-all\.status\.json'
    Assert-Match $runAllText 'exit 1'
    Assert-Match $runAllText 'exit 0'
}

# --- 7. Состояние репозитория перед прогоном ----------------------------------------------
Write-Host ''
Write-Host '7. Git-состояние: оборванный прогон не должен уносить следующую ночь' -ForegroundColor White

$gitProj = Join-Path $sandboxRoot 'gitproj'
New-Item -ItemType Directory -Force -Path $gitProj | Out-Null
& git -C $gitProj init -q 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $gitProj 'README.md') -Value 'проект' -Encoding UTF8
& git -C $gitProj add -A 2>&1 | Out-Null
& git -C $gitProj -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null

It 'чистое дерево — ни блокеров, ни предупреждений' {
    $s = Get-BcfGitReadiness -Root $gitProj
    Assert-True $s.IsRepo
    Assert-Eq @($s.Blocking).Count 0 "на чистом дереве найден блокер: $($s.Blocking -join '; ')"
    Assert-Eq @($s.Warnings).Count 0 "на чистом дереве найдено предупреждение: $($s.Warnings -join '; ')"
}

It 'MERGE_HEAD — блокер с командой восстановления' {
    $mh = Join-Path $gitProj '.git\MERGE_HEAD'
    Set-Content -LiteralPath $mh -Value ((& git -C $gitProj rev-parse HEAD) | Out-String).Trim() -Encoding ASCII
    try {
        $s = Get-BcfGitReadiness -Root $gitProj
        Assert-True $s.Merging
        Assert-Match ($s.Blocking -join ' ') 'посреди слияния' 'оборванное слияние не названо блокером'
        Assert-Match ($s.Fix -join ' ') 'merge --abort' 'не названа команда восстановления'
    } finally { Remove-Item -LiteralPath $mh -Force -ErrorAction SilentlyContinue }
}

It 'незавершённый rebase — тоже блокер' {
    $rd = Join-Path $gitProj '.git\rebase-merge'
    New-Item -ItemType Directory -Force -Path $rd | Out-Null
    try {
        $s = Get-BcfGitReadiness -Root $gitProj
        Assert-True $s.Rebasing
        Assert-Match ($s.Fix -join ' ') 'rebase --abort'
    } finally { Remove-Item -Recurse -Force $rd -ErrorAction SilentlyContinue }
}

It 'грязное дерево — предупреждение с последствием, а не блокер' {
    Set-Content -LiteralPath (Join-Path $gitProj 'README.md') -Value 'правка человека' -Encoding UTF8
    try {
        $s = Get-BcfGitReadiness -Root $gitProj
        Assert-Eq @($s.Blocking).Count 0 'правка в рабочем дереве запретила запуск одиночного цикла'
        Assert-Match ($s.Warnings -join ' ') 'слияние веток задач их отклонит' 'последствие грязного дерева не названо'
        Assert-True (@($s.Dirty).Count -ge 1)
    } finally {
        & git -C $gitProj checkout -- README.md 2>&1 | Out-Null
    }
}

It 'рабочее дерево задачи, которого нет на диске, — блокер с git worktree prune' {
    $wt = Join-Path $gitProj '.worktrees\TASK-01'
    & git -C $gitProj worktree add -b bcf/task/TASK-01 $wt HEAD 2>&1 | Out-Null
    try {
        $alive = Get-BcfGitReadiness -Root $gitProj
        Assert-Eq @($alive.OrphanWorktrees).Count 0 'живое дерево задачи посчитано осиротевшим'
        Assert-Eq @($alive.TaskWorktrees).Count 1

        Remove-Item -Recurse -Force $wt -ErrorAction SilentlyContinue
        $dead = Get-BcfGitReadiness -Root $gitProj
        Assert-Eq @($dead.OrphanWorktrees).Count 1 'учётная запись без каталога не замечена'
        Assert-Match ($dead.Fix -join ' ') 'worktree prune'
    } finally {
        & git -C $gitProj worktree remove --force $wt 2>&1 | Out-Null
        & git -C $gitProj worktree prune 2>&1 | Out-Null
        & git -C $gitProj branch -D bcf/task/TASK-01 2>&1 | Out-Null
    }
}

It 'ветка задачи без дерева — предупреждение: там незакрытая работа' {
    & git -C $gitProj branch bcf/task/TASK-09 2>&1 | Out-Null
    try {
        $s = Get-BcfGitReadiness -Root $gitProj
        Assert-Eq @($s.Blocking).Count 0 'осиротевшая ветка запретила прогон, хотя лечится сама'
        Assert-Match ($s.Warnings -join ' ') 'TASK-09'
    } finally { & git -C $gitProj branch -D bcf/task/TASK-09 2>&1 | Out-Null }
}

It 'не-git каталог не выдаёт себя за репозиторий' {
    $plain = Join-Path $sandboxRoot 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    $s = Get-BcfGitReadiness -Root $plain
    Assert-False $s.IsRepo
    Assert-Match ($s.Warnings -join ' ') 'не git-репозиторий'
}

# --- 8. bcf run: флаг, который не действует, отказывает вслух ------------------------------
Write-Host ''
Write-Host '8. bcf run: --budget и --resume в цикле' -ForegroundColor White

$bcf = Join-Path $root 'bin\bcf.ps1'
$cliProj = Join-Path $sandboxRoot 'cliproj'
New-Item -ItemType Directory -Force -Path $cliProj | Out-Null
& git -C $cliProj init -q 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $cliProj 'README.md') -Value 'проект' -Encoding UTF8
& git -C $cliProj add -A 2>&1 | Out-Null
& git -C $cliProj -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null

function Bcf { param([string[]]$CliArgs)
    $out = & pwsh -NoProfile -File $bcf @CliArgs 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
Bcf @('install', '--project', $cliProj) | Out-Null

It '--budget в ночном режиме отказывает вслух, а не проглатывается' {
    $r = Bcf @('run', 'night', '--budget', '500000', '--project', $cliProj)
    Assert-Eq $r.Code 2 "прогон стартовал с потолком, которого не существует:`n$($r.Out)"
    Assert-Match $r.Out '--budget в режиме night не действует'
    Assert-Match $r.Out 'bcf run queue --budget' 'не сказано, где потолок работает'
}

It '--budget в одиночном цикле — тот же отказ' {
    $r = Bcf @('run', 'loop', 'TASK-01', '--budget', '1000', '--project', $cliProj)
    Assert-Eq $r.Code 2
    Assert-Match $r.Out '--budget в режиме loop не действует'
}

It '--resume в ночном режиме отказывает и называет, что делать вместо' {
    $r = Bcf @('run', 'night', '--resume', 'run-123', '--project', $cliProj)
    Assert-Eq $r.Code 2 "флаг проглочен молча:`n$($r.Out)"
    Assert-Match $r.Out '--resume в режиме night не действует'
    # Подсказка переносится по ширине окна, поэтому ищем её начало, а не фразу целиком.
    Assert-Match $r.Out 'запусти bcf run night снова' 'не сказано, что повтор и есть возобновление'
}

It 'прогон на дереве в состоянии слияния не стартует' {
    $mh = Join-Path $cliProj '.git\MERGE_HEAD'
    Set-Content -LiteralPath $mh -Value ((& git -C $cliProj rev-parse HEAD) | Out-String).Trim() -Encoding ASCII
    try {
        $r = Bcf @('run', 'night', '--project', $cliProj)
        Assert-Eq $r.Code 2 "прогон поехал по дереву в MERGING — ночь уйдёт впустую:`n$($r.Out)"
        Assert-Match $r.Out 'посреди слияния'
        Assert-Match $r.Out 'merge --abort'
    } finally { Remove-Item -LiteralPath $mh -Force -ErrorAction SilentlyContinue }
}

It 'doctor докладывает то же состояние теми же словами' {
    $mh = Join-Path $cliProj '.git\MERGE_HEAD'
    Set-Content -LiteralPath $mh -Value ((& git -C $cliProj rev-parse HEAD) | Out-String).Trim() -Encoding ASCII
    try {
        $r = Bcf @('doctor', '--no-probe', '--project', $cliProj)
        Assert-Match $r.Out 'СОСТОЯНИЕ РЕПОЗИТОРИЯ' 'в doctor нет раздела о состоянии git'
        Assert-Match $r.Out 'посреди слияния'
        Assert-Eq $r.Code 1 'doctor признал готовым проект, на котором прогон не стартует'
    } finally { Remove-Item -LiteralPath $mh -Force -ErrorAction SilentlyContinue }
}

# --- Итог ---------------------------------------------------------------------------------
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
