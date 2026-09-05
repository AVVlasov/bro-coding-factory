# acceptance-report.tests.ps1 — приёмка лидером, трейлеры коммитов, отчёт за месяц.
#
#   pwsh tests/acceptance-report.tests.ps1
#
# ЧТО ЛОВЯТ ЭТИ ТЕСТЫ. verdict: PASS доказывает только то, что гейты задачи зелёные —
# ничего не говорит о том, что задача решает нужную проблему правильным способом. Три
# дыры, которые лежат рядом с этим фактом, и каждая обнаруживается поздно:
#
#   · CORE/NFR-задача уезжает в общую ветку сама, доказав себя только своими тестами,
#     и никто из людей не посмотрел на неё глазами.
#   · Коммит, который сделала фабрика, не говорит, каким прогоном, узлом, моделью и
#     бэкендом он сделан — разбор дефекта месяц спустя идёт по `git log` и упирается
#     в подпись без опознавательных полей.
#   · Отчёт за месяц выдаёт заказчику данные из другого месяца или из головы, вместо
#     честного «в этом месяце не было ни одного вердикта».
#
# Ни одного сетевого вызова и ни одного обращения к модели: гейт и трейлеры — чистая
# git-механика на настоящих репозиториях (тот же приём, что в merge-integration.tests.ps1),
# `bcf task accept`/`bcf report --export` — реальные прогоны CLI на фикстурах без backend.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent
$bcf  = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-accrep-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null

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
function Assert-True  { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-False { param($Cond, [string]$Msg = 'ожидалось ложное')  if ($Cond) { throw $Msg } }
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

. (Join-Path $root 'harness\lib\worktree.ps1')       # тянет claims.ps1 и bcf-context.ps1
. (Join-Path $root 'harness\lib\graph-runtime.ps1')  # Initialize-GraphRun / Get-GraphRunId

function Get-Sha { param([string]$Repo, [string]$Ref = 'HEAD') return (& git -C $Repo rev-parse $Ref 2>$null | Out-String).Trim() }

Write-Host ''
Write-Host "  ПРИЁМКА · ТРЕЙЛЕРЫ · ОТЧЁТ   песочница: $sandboxRoot" -ForegroundColor Cyan

# --- 1. Класс задачи и гейт продвижения в integration.branch ------------------------------
Write-Host ''
Write-Host '1. Merge-TaskWorktree: CORE/NFR без приёмки не сливаются, GEN сливается' -ForegroundColor White

# Фикстура один в один как в merge-integration.tests.ps1 (New-Fixture), плюс настоящий
# файл задачи с шапкой — гейт читает класс из «## Файлы» той же функцией, что и
# «Исполнитель:»/«Блокер:».
function New-GateFixture {
    param([string]$TaskId, [string]$Class = '')
    $d = Join-Path $sandboxRoot ("gate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null

    'исходная строка' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
    $classLine = if ($Class) { "Класс: $Class`n" } else { '' }
    @"
# $TaskId — тестовая задача гейта

Исполнитель: фабрика
$classLine
## Файлы

- ``src.rs``
"@ | Set-Content -LiteralPath (Join-Path $d "tasks\$TaskId-gate.md") -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null

    & git -C $d checkout -q -b "bcf/task/$TaskId" 2>&1 | Out-Null
    'правка задачи' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m "$TaskId" 2>&1 | Out-Null
    & git -C $d checkout -q main 2>&1 | Out-Null
    return $d
}

It 'CORE БЕЗ ПРИЁМКИ НЕ СЛИВАЕТСЯ' {
    $d = New-GateFixture -TaskId 'TASK-51' -Class 'CORE'
    $before = Get-Sha -Repo $d
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-51'
    Assert-False $r.Ok 'CORE без файла приёмки слился'
    Assert-Eq $r.Kind 'needs-acceptance'
    Assert-Match $r.Message 'ждёт приёмки лидера'
    Assert-Eq (Get-Sha -Repo $d) $before 'HEAD сдвинулся — слияние всё же произошло'
    Assert-Eq ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim()) 'исходная строка' `
        'работа непринятой CORE-задачи попала в основную ветку'
}

It 'БЕЗ СТРОКИ «КЛАСС:» ЗАДАЧА СЧИТАЕТСЯ CORE И ТОЖЕ ЖДЁТ ПРИЁМКИ' {
    $d = New-GateFixture -TaskId 'TASK-52' -Class ''
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-52'
    Assert-False $r.Ok 'задача без объявленного класса получила самый мягкий режим'
    Assert-Eq $r.Kind 'needs-acceptance'
}

It 'NFR БЕЗ ПРИЁМКИ ТОЖЕ НЕ СЛИВАЕТСЯ' {
    $d = New-GateFixture -TaskId 'TASK-53' -Class 'NFR'
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-53'
    Assert-False $r.Ok 'NFR без приёмки слилась'
    Assert-Eq $r.Kind 'needs-acceptance'
}

It 'GEN СЛИВАЕТСЯ БЕЗ ПРИЁМКИ' {
    $d = New-GateFixture -TaskId 'TASK-54' -Class 'GEN'
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-54'
    Assert-True $r.Ok "GEN не слился: вид=$($r.Kind) $($r.Message)"
    Assert-Eq ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim()) 'правка задачи'
}

It 'ПОСЛЕ ПРИЁМКИ ЛИДЕРОМ CORE СЛИВАЕТСЯ' {
    $d = New-GateFixture -TaskId 'TASK-55' -Class 'CORE'
    $blocked = Merge-TaskWorktree -Root $d -Task 'TASK-55'
    Assert-False $blocked.Ok 'предусловие теста не воспроизводит затык'

    $accDir = Join-Path $d 'tasks\.acceptance'
    New-Item -ItemType Directory -Force -Path $accDir | Out-Null
    $accBody = ConvertTo-BcfAcceptanceText -TaskId 'TASK-55' -Leader 'Иван' -Lens 'архитектура' -VerdictSha 'deadbeef'
    Set-Content -LiteralPath (Join-Path $accDir 'TASK-55.md') -Value $accBody -Encoding UTF8

    $r = Merge-TaskWorktree -Root $d -Task 'TASK-55'
    Assert-True $r.Ok "принятая CORE не слилась: вид=$($r.Kind) $($r.Message)"
    Assert-Eq ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim()) 'правка задачи'
}

It 'КОНТРОЛЬ: БЕЗ ФАЙЛА ЗАДАЧИ ГЕЙТ НЕ ПРИМЕНИМ (старая механика слияния не сломана)' {
    # Ровно фикстура merge-integration.tests.ps1: git-репозиторий с веткой bcf/task/TASK-99
    # и НИ ОДНОГО файла задачи. Если бы отсутствие файла тоже читалось как «CORE без
    # приёмки», это не прошло бы нигде, где Merge-TaskWorktree уже проходит.
    $d = Join-Path $sandboxRoot ("nofile-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    'база' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null
    & git -C $d checkout -q -b bcf/task/TASK-99 2>&1 | Out-Null
    'правка' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m TASK-99 2>&1 | Out-Null
    & git -C $d checkout -q main 2>&1 | Out-Null

    $r = Merge-TaskWorktree -Root $d -Task 'TASK-99'
    Assert-True $r.Ok "задача без файла отказалась сливаться: вид=$($r.Kind) $($r.Message)"
}

# --- 2. Трейлеры коммитов прогона ----------------------------------------------------------
Write-Host ''
Write-Host '2. Трейлеры коммитов: строятся, проверяются, доезжают до реального merge-коммита' -ForegroundColor White

function New-PlainRepo {
    $d = Join-Path $sandboxRoot ("plain-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    'а' | Set-Content -LiteralPath (Join-Path $d 'a.txt') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null
    return $d
}

It 'КОММИТ С ТРЕЙЛЕРАМИ ПРОХОДИТ ПРОВЕРКУ' {
    $d = New-PlainRepo
    $msg = New-BcfCommitMessage -Subject 'TASK-60: слияние работы задачи' `
               -Task 'TASK-60' -RunId 'g_test_1' -Role 'worker' -Model 'opus' -Backend 'claude'
    'б' | Set-Content -LiteralPath (Join-Path $d 'b.txt') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m $msg 2>&1 | Out-Null
    $sha = Get-Sha -Repo $d
    $t = Test-BcfCommitHasTrailers -Root $d -Sha $sha
    Assert-True $t.Ok "не хватает: $($t.Missing -join ', ')"
}

It 'КОММИТ БЕЗ ТРЕЙЛЕРОВ НЕ ПРОХОДИТ ПРОВЕРКУ' {
    $d = New-PlainRepo
    'б' | Set-Content -LiteralPath (Join-Path $d 'b.txt') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'обычный коммит без единого трейлера' 2>&1 | Out-Null
    $sha = Get-Sha -Repo $d
    $t = Test-BcfCommitHasTrailers -Root $d -Sha $sha
    Assert-False $t.Ok 'коммит без опознавательных полей прошёл проверку'
    Assert-Eq @($t.Missing).Count 5 "ждал все пять полей отсутствующими, получил: $($t.Missing -join ', ')"
}

It 'СЛИЯНИЕ С МЕТАДАННЫМИ ПРОГОНА ДАЁТ РЕАЛЬНЫЙ MERGE-КОММИТ С ТРЕЙЛЕРАМИ' {
    $d = New-GateFixture -TaskId 'TASK-56' -Class 'GEN'
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-56' -RunId 'g_test_2' -Role 'worker' -Model 'opus' -Backend 'claude'
    Assert-True $r.Ok "слияние не прошло: вид=$($r.Kind) $($r.Message)"
    $sha = Get-Sha -Repo $d
    $t = Test-BcfCommitHasTrailers -Root $d -Sha $sha
    Assert-True $t.Ok "merge-коммит без трейлеров: не хватает $($t.Missing -join ', ')"
    $body = (& git -C $d log -1 --format=%B $sha | Out-String)
    Assert-Match $body 'Task: TASK-56'
    Assert-Match $body 'Run-Id: g_test_2'
    Assert-Match $body 'Role: worker'
}

It 'КОНТРОЛЬ: СЛИЯНИЕ БЕЗ МЕТАДАННЫХ ПРОГОНА — БЕЗ ТРЕЙЛЕРОВ, КАК РАНЬШЕ' {
    $d = New-GateFixture -TaskId 'TASK-57' -Class 'GEN'
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-57'
    Assert-True $r.Ok $r.Message
    $sha = Get-Sha -Repo $d
    $t = Test-BcfCommitHasTrailers -Root $d -Sha $sha
    Assert-False $t.Ok 'юнит-вызов без RunId вдруг получил трейлеры — обычный merge --no-edit'
}

It 'ИДЕНТИЧНОСТЬ MERGE-КОММИТА БЕРЁТСЯ ИЗ author.* КОНФИГА' {
    $d = New-GateFixture -TaskId 'TASK-58' -Class 'GEN'
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    (@{ author = @{ name = 'Фабрика Х'; email = 'x@factory.local' } } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $d 'config\harness.json') -Encoding UTF8
    $r = Merge-TaskWorktree -Root $d -Task 'TASK-58' -RunId 'g_test_3' -Role 'worker' -Model 'm' -Backend 'b'
    Assert-True $r.Ok $r.Message
    $author = (& git -C $d log -1 --format='%an <%ae>' | Out-String).Trim()
    Assert-Eq $author 'Фабрика Х <x@factory.local>' `
        'коммит подписан не тем именем, что задано в config/harness.json — репозиторий уже настроен на t/t@t, и старое поведение взяло бы его'
}

# --- 2b. Параллельный планировщик (scheduler.ps1) — та же идентичность и трейлеры, что граф --
Write-Host ''
Write-Host '2b. scheduler.ps1 (ночной прогон при limits.taskConcurrency > 1): не ralph, есть трейлеры' -ForegroundColor White

# Живой прогон здесь не поставить: путь включается limits.taskConcurrency > 1 и реально
# запускает loop.ps1 отдельным процессом на каждую задачу — платную модель. Дешёвая
# проверка вместо этого — тот же приём, что уже принят в этом репозитории для ЭТОГО ЖЕ
# файла (team-claims.tests.ps1: «в откате слияния не осталось reset --hard HEAD~1»):
# регекс/подстрока по исходнику, а не запуск. Строительные блоки (Get-BcfGitIdentityArgs,
# New-BcfCommitMessage, Merge-TaskWorktree с трейлерами) уже доказаны живьём выше —
# здесь проверяется только то, что scheduler.ps1 их действительно зовёт, а не то, что
# они вообще работают.
$schedulerSrc = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\lib\scheduler.ps1')

It 'SCHEDULER.PS1: АВТО-КОММИТ РАБОТЫ ЗАДАЧИ БОЛЬШЕ НЕ ПОДПИСАН НАМЕРТВО ВШИТЫМ ralph' {
    # Проверяем именно КОД git-вызова (`-c user.name=ralph ...`), а не любое упоминание
    # слова «ralph» — в комментарии рядом честно описана прежняя ошибка тем же словом.
    Assert-False $schedulerSrc.Contains('-c user.name=ralph -c user.email=ralph@local') `
        'параллельный прогон снова коммитит работу задачи от имени ralph, минуя author.* конфига проекта'
}

It 'SCHEDULER.PS1: АВТО-КОММИТ РАБОТЫ ЗАДАЧИ БЕРЁТ ИДЕНТИЧНОСТЬ И ТРЕЙЛЕРЫ ТАК ЖЕ, КАК ГРАФ' {
    Assert-True $schedulerSrc.Contains('$wid = Get-BcfGitIdentityArgs -Root $r.Worktree') `
        'идентичность авто-коммита не берётся из Get-BcfGitIdentityArgs (author.*/git config)'
    Assert-True $schedulerSrc.Contains('$wmsg = New-BcfCommitMessage -Subject "${task}: работа агента (авто-коммит перед слиянием)"') `
        'сообщение авто-коммита не строится New-BcfCommitMessage — трейлеров не будет'
    Assert-True $schedulerSrc.Contains('-Task $task -RunId $Run -Role ''worker'' -Model $Model -Backend $Backend') `
        'авто-коммит не передаёт все пять полей трейлера (Task/Run-Id/Role/Model/Backend)'
    Assert-True $schedulerSrc.Contains('& git -C $r.Worktree @wid commit -m $wmsg') `
        'коммит выполняется не с той идентичностью ($wid), что была вычислена из конфига'
}

It 'SCHEDULER.PS1: MERGE-TASKWORKTREE ЗОВЁТСЯ С МЕТАДАННЫМИ ПРОГОНА — MERGE-КОММИТ ПАРАЛЛЕЛЬНОГО ПРОГОНА НЕСЁТ ТРЕЙЛЕРЫ' {
    $mergeCallIdx = $schedulerSrc.IndexOf('$merge = Merge-TaskWorktree -Root $Root -Task $task -GeneratedFiles $GeneratedFiles')
    Assert-True ($mergeCallIdx -ge 0) 'не нашёл вызов Merge-TaskWorktree в параллельном прогоне — сигнатура вызова изменилась, поправь тест'
    $mergeCallTail = $schedulerSrc.Substring($mergeCallIdx, [Math]::Min(220, $schedulerSrc.Length - $mergeCallIdx))
    Assert-True $mergeCallTail.Contains('-RunId $Run') `
        'Merge-TaskWorktree в параллельном прогоне вызывается без -RunId — merge-коммит останется без трейлеров, как раньше'
    Assert-True $mergeCallTail.Contains("-Role 'worker'") 'Merge-TaskWorktree в параллельном прогоне вызывается без -Role'
    Assert-True $mergeCallTail.Contains('-Model $Model') 'Merge-TaskWorktree в параллельном прогоне вызывается без -Model'
    Assert-True $mergeCallTail.Contains('-Backend $Backend') 'Merge-TaskWorktree в параллельном прогоне вызывается без -Backend'
}

It 'SCHEDULER.PS1: ОТКАЗ ИЗ-ЗА НЕДОСТАЮЩЕЙ ПРИЁМКИ — ОТДЕЛЬНАЯ ВЕТКА С ДОСЛОВНОЙ ПРИЧИНОЙ ГЕЙТА, А НЕ «GIT ОТВЕРГ СЛИЯНИЕ»' {
    Assert-True $schedulerSrc.Contains("if (`$merge.Kind -eq 'needs-acceptance') {") `
        'нет отдельной ветки needs-acceptance — затык приёмки лидера обрабатывается как обычный отказ слияния'
    # Причина уходит в $stuck ДОСЛОВНО ($merge.Message = «ждёт приёмки лидера» от
    # Test-BcfTaskAcceptanceGate), а не завёрнутой в «git отверг слияние: …», как было
    # раньше (то же неверно и про механику отказа, и про сам текст затыка).
    Assert-True $schedulerSrc.Contains('$stuck += [pscustomobject]@{ Task = $task; Reason = $merge.Message }') `
        'ветка needs-acceptance не пробрасывает дословную причину гейта ($merge.Message) — заворачивает её в другой текст'
    # needs-acceptance обязана проверяться РАНЬШЕ общего разбора причины ($why): иначе тот
    # доберётся до неё первым и напечатает «git отверг слияние: ждёт приёмки лидера».
    $branchIdx = $schedulerSrc.IndexOf("if (`$merge.Kind -eq 'needs-acceptance') {")
    $genericIdx = $schedulerSrc.IndexOf('$why = if ($merge.Conflicts.Count)')
    Assert-True ($branchIdx -ge 0 -and $genericIdx -gt $branchIdx) `
        'ветка needs-acceptance стоит не РАНЬШЕ общего разбора причины — тот доберётся до неё первым'
}

# --- 3. Версия фабрики и хэш файла графа ---------------------------------------------------
Write-Host ''
Write-Host '3. factory_version / graph_hash: строительные блоки и определение файла графа' -ForegroundColor White

It 'GET-BCFFACTORYVERSION ЧИТАЕТ НАСТОЯЩИЙ VERSION ФАБРИКИ' {
    $expected = (Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim()
    Assert-Eq (Get-BcfFactoryVersion) $expected
}

It 'GET-BCFFILEHASH: 12 hex-символов на реальном файле, пусто — на отсутствующем' {
    $f = Join-Path $sandboxRoot 'hashme.txt'
    'содержимое для хэша' | Set-Content -LiteralPath $f -Encoding UTF8
    $h1 = Get-BcfFileHash -Path $f
    Assert-Match $h1 '^[0-9a-f]{12}$' "хэш не похож на 12 hex-символов: $h1"
    $h2 = Get-BcfFileHash -Path $f
    Assert-Eq $h1 $h2 'хэш одного и того же файла разошёлся между вызовами'
    Assert-Eq (Get-BcfFileHash -Path (Join-Path $sandboxRoot 'нет-такого-файла.txt')) ''
    Assert-Eq (Get-BcfFileHash -Path '') ''
}

It 'INITIALIZE-GRAPHRUN, ВЫЗВАННЫЙ ИЗ .graph.ps1, ПРОСТАВЛЯЕТ BCF_GRAPH_FILE' {
    $fakeGraphDir = Join-Path $sandboxRoot 'fake-graphs'
    New-Item -ItemType Directory -Force -Path $fakeGraphDir | Out-Null
    $fakeGraph = Join-Path $fakeGraphDir 'probe.graph.ps1'
    $probeRoot = Join-Path $sandboxRoot ('probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
    Set-Content -LiteralPath $fakeGraph -Encoding UTF8 -Value @'
Initialize-GraphRun -Root $probeRoot -Meta @{ name = 'probe'; description = 'т' } -MaxConcurrency 1 | Out-Null
'@
    Remove-Item Env:\BCF_GRAPH_FILE -ErrorAction SilentlyContinue
    . $fakeGraph

    $got = $env:BCF_GRAPH_FILE
    Assert-True ([bool]$got) 'BCF_GRAPH_FILE не выставлен — verify.ps1 не узнает, каким графом он вызван'
    Assert-Eq ((Resolve-Path $got).Path) ((Resolve-Path $fakeGraph).Path) 'BCF_GRAPH_FILE указывает не на тот файл графа'
    $h = Get-BcfFileHash -Path $got
    Assert-Match $h '^[0-9a-f]{12}$' "graph_hash не посчитался по BCF_GRAPH_FILE: «$h»"
}

It 'КОНТРОЛЬ: ВЫЗОВ НЕ ИЗ .graph.ps1 ОСТАВЛЯЕТ BCF_GRAPH_FILE ПУСТЫМ' {
    # Прогон вне графа (bcf run loop/night) не обязан знать о файле графа вовсе — это
    # не «забыли передать», а честное отсутствие: гейт применялся не к графу.
    $probeRoot2 = Join-Path $sandboxRoot ('probe2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $probeRoot2 | Out-Null
    Initialize-GraphRun -Root $probeRoot2 -Meta @{ name = 'probe2'; description = 'т' } -MaxConcurrency 1 | Out-Null
    Assert-Eq $env:BCF_GRAPH_FILE '' 'вызов не из файла графа всё равно проставил BCF_GRAPH_FILE'
}

Remove-Item Env:\BCF_GRAPH_FILE -ErrorAction SilentlyContinue

It 'VERIFY.PS1: FACTORY_VERSION И GRAPH_HASH ЛЕЖАТ ВНУТРИ ТЕЛА ВЕРДИКТА, А ЗНАЧЕНИЯ СЧИТАНЫ ДО ЕГО ЗАПИСИ' {
    # Живой вердикт здесь не снять — verify.ps1 зовёт модели, а платные прогоны запрещены
    # правилами задания. Дешёвая проверка вместо этого — тот же приём, что уже принят в
    # этом репозитории (team-claims.tests.ps1:396-402): регекс/подстрока по исходнику.
    # Строительные блоки (Get-BcfFactoryVersion, Get-BcfFileHash) уже доказаны живьём выше —
    # здесь проверяется только то, что verify.ps1 кладёт их результат в тело вердикта, а не
    # то, что они вообще работают.
    $verifySrc = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\verify.ps1')

    Assert-True $verifySrc.Contains('$FactoryVersion = Get-BcfFactoryVersion') `
        'версия фабрики не считывается Get-BcfFactoryVersion'
    Assert-True $verifySrc.Contains('$GraphHash = Get-BcfFileHash -Path $env:BCF_GRAPH_FILE') `
        'хэш файла графа не считывается Get-BcfFileHash по BCF_GRAPH_FILE'

    $bodyIdx = $verifySrc.IndexOf('$verdictBody = @"')
    Assert-True ($bodyIdx -ge 0) 'не нашёл объявление $verdictBody — конструкция изменилась, поправь тест'
    $closeIdx = $verifySrc.IndexOf('"@', $bodyIdx)
    Assert-True ($closeIdx -gt $bodyIdx) 'не нашёл закрытие here-string тела вердикта'
    $body = $verifySrc.Substring($bodyIdx, $closeIdx - $bodyIdx)

    Assert-True $body.Contains('factory_version: $FactoryVersion') 'factory_version: не внутри тела вердикта ($verdictBody)'
    Assert-True $body.Contains('graph_hash: $GraphHashLine') 'graph_hash: не внутри тела вердикта ($verdictBody)'

    # Присвоение обязано стоять РАНЬШЕ объявления $verdictBody — иначе тело вердикта
    # увидит переменную ещё не проставленной (обращение к необъявленной/пустой $null).
    $assignIdx = $verifySrc.IndexOf('$FactoryVersion = Get-BcfFactoryVersion')
    Assert-True ($assignIdx -ge 0 -and $bodyIdx -gt $assignIdx) `
        '$FactoryVersion присваивается ПОСЛЕ объявления $verdictBody — вердикт получит незаполненное значение'
    $hashLineAssignIdx = $verifySrc.IndexOf('$GraphHashLine = if ($GraphHash)')
    Assert-True ($hashLineAssignIdx -ge 0 -and $bodyIdx -gt $hashLineAssignIdx) `
        '$GraphHashLine присваивается ПОСЛЕ объявления $verdictBody — вердикт получит незаполненное значение'

    # Место записи ровно одно (Set-Content ... -Value $verdictBody) — если появится второе,
    # эта проверка тела перестаёт быть доказательством того, что реально едет в файл.
    $writeSites = ([regex]::Matches($verifySrc, [regex]::Escape('-Value $verdictBody'))).Count
    Assert-Eq $writeSites 1 'найдено не одно место записи $verdictBody в файл — тест проверял не то тело, которое реально пишется'
}

# --- 4. bcf task accept ---------------------------------------------------------------------
Write-Host ''
Write-Host '4. bcf task accept: пишет и коммитит tasks/.acceptance/<TASK>.md' -ForegroundColor White

function New-AcceptFixture {
    param([string]$TaskId = 'TASK-70')
    $d = Join-Path $sandboxRoot ("accept-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks\.verdicts') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    "# $TaskId — задача приёмки`n`n## Файлы`n`n- ``x.txt```n" |
        Set-Content -LiteralPath (Join-Path $d "tasks\$TaskId-x.md") -Encoding UTF8
    @"
# Verdict — $TaskId
verdict: PASS
date: 2026-09-05
diff_fingerprint: cafef00d
"@ | Set-Content -LiteralPath (Join-Path $d "tasks\.verdicts\$TaskId.md") -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null
    return $d
}

It 'BCF TASK ACCEPT ПИШЕТ ФАЙЛ, КОММИТИТ ЕГО И НЕ ОСТАВЛЯЕТ ГРЯЗИ' {
    $d = New-AcceptFixture -TaskId 'TASK-70'
    $out = & pwsh -NoProfile -File $bcf task accept 'TASK-70' --as 'Иван' --lens 'архитектура' --note 'смотрел граничные случаи' --project $d 2>&1 | Out-String
    Assert-Match $out 'ПРИЁМКА TASK-70' "команда не отчиталась об успехе:`n$out"

    $accFile = Join-Path $d 'tasks\.acceptance\TASK-70.md'
    Assert-True (Test-Path $accFile) "файл приёмки не создан:`n$out"
    $body = Get-Content -Raw -LiteralPath $accFile
    Assert-Match $body '(?m)^Лидер: Иван\s*$'
    Assert-Match $body '(?m)^Ракурс: архитектура\s*$'
    Assert-Match $body '(?m)^Заметка: смотрел граничные случаи\s*$'
    Assert-Match $body '(?m)^Когда: \d{4}-\d{2}-\d{2}T'
    Assert-Match $body '(?m)^Вердикт: [0-9a-f]{8,}\s*$' 'sha вердикта не записан'

    $tracked = @(& git -C $d ls-files 'tasks/.acceptance/TASK-70.md' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'файл приёмки не закоммичен — второй участник команды его не увидит'
    $dirty = @(& git -C $d status --porcelain 2>$null | Where-Object { $_ })
    Assert-Eq $dirty.Count 0 "коммит приёмки оставил дерево грязным: $($dirty -join '; ')"

    $msg = (& git -C $d log -1 --format=%s | Out-String).Trim()
    Assert-Match $msg 'приёмка' "сообщение коммита не называет действие: $msg"
}

It 'BCF TASK ACCEPT БЕЗ ВЕРДИКТА ОТКАЗЫВАЕТ И НИЧЕГО НЕ ПИШЕТ' {
    $d = New-AcceptFixture -TaskId 'TASK-71'
    Remove-Item -LiteralPath (Join-Path $d 'tasks\.verdicts\TASK-71.md') -Force
    $out = & pwsh -NoProfile -File $bcf task accept 'TASK-71' --as 'Иван' --project $d 2>&1 | Out-String
    Assert-Match $out '(?i)нет вердикта' "отказ не назвал причину:`n$out"
    Assert-False (Test-Path (Join-Path $d 'tasks\.acceptance\TASK-71.md')) 'файл приёмки создан без вердикта'
}

It 'BCF TASK ACCEPT БЕЗ --AS ОТКАЗЫВАЕТ' {
    $d = New-AcceptFixture -TaskId 'TASK-72'
    $out = & pwsh -NoProfile -File $bcf task accept 'TASK-72' --project $d 2>&1 | Out-String
    Assert-Match $out '(?i)имя лидера'
    Assert-False (Test-Path (Join-Path $d 'tasks\.acceptance\TASK-72.md'))
}

# WORKFLOW.md обещает: «новый прогон перепишет вердикт, sha разойдётся, и bcf task show
# покажет приёмку устаревшей». До этой правки ничего не сравнивало записанный sha с
# текущим (ни гейт слияния, ни `bcf task show`) — устаревшая приёмка молча продолжала
# считаться действующей.
It 'BCF TASK SHOW: СВЕЖАЯ ПРИЁМКА ПОКАЗАНА ПРИНЯТОЙ, БЕЗ ПРЕДУПРЕЖДЕНИЯ ОБ УСТАРЕВАНИИ' {
    $d = New-AcceptFixture -TaskId 'TASK-73'
    & pwsh -NoProfile -File $bcf task accept 'TASK-73' --as 'Иван' --project $d 2>&1 | Out-Null
    $out = & pwsh -NoProfile -File $bcf task show 'TASK-73' --project $d 2>&1 | Out-String
    Assert-Match $out 'принято: Иван' "свежая приёмка не показана принятой:`n$out"
    Assert-NoMatch $out 'устарела' "свежая приёмка ошибочно помечена устаревшей:`n$out"
}

It 'BCF TASK SHOW: ПЕРЕЗАПИСАННЫЙ ВЕРДИКТ ДЕЛАЕТ ПРИЁМКУ ВИДИМО УСТАРЕВШЕЙ (SHA РАЗОШЁЛСЯ)' {
    $d = New-AcceptFixture -TaskId 'TASK-74'
    & pwsh -NoProfile -File $bcf task accept 'TASK-74' --as 'Иван' --project $d 2>&1 | Out-Null
    # Новый прогон переписал файл вердикта — ровно случай, который называет WORKFLOW.md.
    @"
# Verdict — TASK-74
verdict: PASS
date: 2026-09-06
diff_fingerprint: deadbeef00
"@ | Set-Content -LiteralPath (Join-Path $d 'tasks\.verdicts\TASK-74.md') -Encoding UTF8

    $out = & pwsh -NoProfile -File $bcf task show 'TASK-74' --project $d 2>&1 | Out-String
    Assert-Match $out 'устарела' "перезаписанный вердикт не отмечен как расхождение приёмки:`n$out"
    Assert-NoMatch $out 'принято: Иван' "устаревшая приёмка всё ещё показана зелёной как действующая:`n$out"
}

# --- 5. bcf report --export <yyyy-MM> --------------------------------------------------------
Write-Host ''
Write-Host '5. bcf report --export: месяц без прогонов честен, месяц с вердиктом — нет' -ForegroundColor White

function New-ReportFixture {
    $d = Join-Path $sandboxRoot ("report-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $d 'x.txt') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null
    return $d
}

It 'ОТЧЁТ ЗА МЕСЯЦ БЕЗ ЕДИНОГО ВЕРДИКТА ИЛИ ПРОГОНА ЧЕСТНО ПУСТ' {
    $d = New-ReportFixture
    $out = & pwsh -NoProfile -File $bcf report --export '2019-01' --project $d 2>&1 | Out-String
    $reportFile = Join-Path $d 'docs\reports\2019-01.md'
    Assert-True (Test-Path $reportFile) "файл отчёта не создан:`n$out"
    $body = Get-Content -Raw -LiteralPath $reportFile
    Assert-Match $body 'умышленно пуст' 'отчёт не назвал пустоту честно'
    Assert-NoMatch $body '\| *TASK-' 'в пустом отчёте появилась строка задачи — данные придуманы'
    Assert-NoMatch $body '## Задачи' 'таблица задач нарисована на пустом месте'
}

It 'ОТЧЁТ ЗА МЕСЯЦ С ВЕРДИКТОМ ПОКАЗЫВАЕТ ЗАДАЧУ, А СОСЕДНИЙ МЕСЯЦ ЕЁ НЕ ВИДИТ' {
    $d = New-ReportFixture
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks\.verdicts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    "# TASK-61 — задача отчёта`n`n## Файлы`n`n- ``x.txt```n" |
        Set-Content -LiteralPath (Join-Path $d 'tasks\TASK-61-x.md') -Encoding UTF8
    @"
# Verdict — TASK-61
verdict: PASS
date: 2026-09-15
"@ | Set-Content -LiteralPath (Join-Path $d 'tasks\.verdicts\TASK-61.md') -Encoding UTF8

    $out = & pwsh -NoProfile -File $bcf report --export '2026-09' --project $d 2>&1 | Out-String
    $reportFile = Join-Path $d 'docs\reports\2026-09.md'
    Assert-True (Test-Path $reportFile) "файл отчёта не создан:`n$out"
    $body = Get-Content -Raw -LiteralPath $reportFile
    Assert-Match $body '\| *TASK-61 *\| *PASS *\|' "строка задачи не найдена:`n$body"
    # Класс по умолчанию — CORE, приёмки нет: ячейка обязана назвать затык, а не молчать.
    Assert-Match $body 'ждёт приёмки' 'отчёт не сказал, что CORE без приёмки ждёт лидера'

    $outOther = & pwsh -NoProfile -File $bcf report --export '2026-08' --project $d 2>&1 | Out-String
    $otherFile = Join-Path $d 'docs\reports\2026-08.md'
    $otherBody = Get-Content -Raw -LiteralPath $otherFile
    Assert-NoMatch $otherBody 'TASK-61' 'вердикт сентября утёк в отчёт за август'
    Assert-Match $otherBody 'умышленно пуст'
}

It 'ОТЧЁТ ЗА МЕСЯЦ ПОКАЗЫВАЕТ НЕЗАКРЫТЫЕ ЗАДАЧИ НОЧНОГО ПРОГОНА, ЕСЛИ САМ ПРОГОН БЫЛ В ЭТОМ ОКНЕ' {
    # .bcf/run-all.status.json назван источником --export в задании, но раньше --export
    # его не открывал вовсе — незакрытые задачи ночного цикла (needs_human/gate_blocked)
    # в месячный отчёт не попадали никак.
    $d = New-ReportFixture
    New-Item -ItemType Directory -Force -Path (Join-Path $d '.bcf') | Out-Null
    $status = [ordered]@{
        complete     = $false
        queue_closed = $false
        when         = '2026-09-20 10:00:00'
        total        = 2
        passed       = 0
        stuck        = 2
        needs_human  = @(@{ task = 'TASK-80'; reason = 'ждёт приёмки лидера'; blocks = @() })
        gate_blocked = @(@{ task = 'TASK-81'; reason = 'gate-block: предшественник TASK-80 не закрыт' })
    }
    ($status | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $d '.bcf\run-all.status.json') -Encoding UTF8

    $out = & pwsh -NoProfile -File $bcf report --export '2026-09' --project $d 2>&1 | Out-String
    $reportFile = Join-Path $d 'docs\reports\2026-09.md'
    Assert-True (Test-Path $reportFile) "файл отчёта не создан:`n$out"
    $body = Get-Content -Raw -LiteralPath $reportFile
    Assert-NoMatch $body 'умышленно пуст' 'месяц с прогоном ночного цикла объявлен пустым, хотя фабрика в нём работала'
    Assert-Match $body '\| *TASK-80 *\|' "незакрытая задача needs_human не попала в отчёт:`n$body"
    Assert-Match $body '\| *TASK-81 *\|' "незакрытая задача gate_blocked не попала в отчёт:`n$body"
    Assert-Match $body 'ждёт приёмки лидера' 'причина needs_human не процитирована дословно'

    # Прогон случился в сентябре — в августовский отчёт его незакрытые задачи попасть не должны.
    $outOther = & pwsh -NoProfile -File $bcf report --export '2026-08' --project $d 2>&1 | Out-String
    $otherFile = Join-Path $d 'docs\reports\2026-08.md'
    $otherBody = Get-Content -Raw -LiteralPath $otherFile
    Assert-NoMatch $otherBody 'TASK-80' 'незакрытая задача сентябрьского прогона утекла в отчёт за август'
    Assert-Match $otherBody 'умышленно пуст'
}

It 'BCF REPORT --EXPORT С НЕВЕРНЫМ ФОРМАТОМ МЕСЯЦА ОТКАЗЫВАЕТ' {
    $d = New-ReportFixture
    & pwsh -NoProfile -File $bcf report --export 'сентябрь' --project $d 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) 'кривой формат месяца принят молча'
}

# --- Итог ---------------------------------------------------------------------------------
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
