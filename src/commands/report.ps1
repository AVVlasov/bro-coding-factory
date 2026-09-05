# bcf report — итог одним экраном или выгрузка за месяц.
#
#   bcf report            последний прогон (граф или ночной цикл — что было позже)
#   bcf report --last     то же явно
#   bcf report <runId>    конкретный прогон графа
#   bcf report --export <yyyy-MM>   docs/reports/<yyyy-MM>.md для заказчика
#
# ПРАВИЛО ЭТОГО ОТЧЁТА: «готово» звучит ТОЛЬКО при полностью закрытой очереди. Раньше
# прогон всегда заканчивался словом «готово» — даже когда закрыто 13 задач из 19, и
# человек, и вызывающий агент принимали неполный прогон за успешный.
#
# --export НЕ ПРИДУМЫВАЕТ ДАННЫЕ ЗА МЕСЯЦ, КОТОРОГО НЕ БЫЛО. Четыре источника, и каждый —
# то же самое, что уже показывают bcf tasks / bcf cost, просто собранное по датам:
# tasks/.verdicts/*.md (поле date:, независимо от того, цикл их написал или граф),
# tasks/.acceptance/*.md (приёмка лидера), журналы графа .bcf/graph/*/journal.jsonl
# (часы и токены по узлам, названным именем задачи) и .bcf/run-all.status.json (незакрытые
# задачи последнего ночного прогона — needs_human/gate_blocked — если сам прогон случился
# в этом месяце). Месяц без единого вердикта и без единого прогона в этом окне даёт честно
# пустой отчёт, а не строку из прошлого месяца, принятую за текущий.

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$project = $script:BcfProject

# --- bcf report --export <yyyy-MM> -------------------------------------------------------
$exportArgIdx = [array]::IndexOf(@($script:BcfArgs), '--export')
$exportMonth = ''
if ($exportArgIdx -ge 0) {
    $exportMonth = if ($exportArgIdx + 1 -lt @($script:BcfArgs).Count) { [string]@($script:BcfArgs)[$exportArgIdx + 1] } else { '' }
}
foreach ($a in @($script:BcfArgs)) { if ($a -match '^--export=(.+)$') { $exportMonth = $Matches[1] } }

if ($exportArgIdx -ge 0 -or $exportMonth) {
    if ($exportMonth -notmatch '^\d{4}-\d{2}$') {
        Write-BcfFail 'нужен месяц в формате yyyy-MM: bcf report --export 2026-09'
        exit 2
    }
    . (Join-Path $BcfRoot 'src\lib\pricing.ps1')
    . (Join-Path (Get-BcfHarness) 'lib\claims.ps1')
    . (Join-Path (Get-BcfHarness) 'lib\team-bus.ps1')

    $monthStart = [datetime]::ParseExact($exportMonth, 'yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
    $monthEnd = $monthStart.AddMonths(1)

    $cfg = $null
    try { $cfg = Get-BcfHarnessConfig -Project $project } catch { }
    $tasksRel = if ($cfg -and $cfg.paths -and $cfg.paths.tasks) { [string]$cfg.paths.tasks } else { 'tasks' }
    $verdictsRel = if ($cfg -and $cfg.paths -and $cfg.paths.verdicts) { [string]$cfg.paths.verdicts } else { "$tasksRel/.verdicts" }
    $verdictsDir = Join-Path $project ($verdictsRel -replace '/', '\')

    # 1. Вердикты датой в этом месяце — тот же файл, что читает `bcf tasks`, только
    # отфильтрованный полем date:, которое пишет verify.ps1 в каждый вердикт.
    function Get-BcfVerdictSummary {
        param([string]$Path)
        $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $raw) { return $null }
        $verdict = ''; $date = ''
        $mv = [regex]::Match($raw, '(?m)^verdict:\s*(\S+)')
        if ($mv.Success) { $verdict = $mv.Groups[1].Value }
        $md = [regex]::Match($raw, '(?m)^date:\s*(\d{4}-\d{2}-\d{2})')
        if ($md.Success) { $date = $md.Groups[1].Value }
        return [pscustomobject]@{ Verdict = $verdict; Date = $date }
    }

    $rows = @()
    if (Test-Path $verdictsDir) {
        foreach ($f in (Get-ChildItem $verdictsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $sum = Get-BcfVerdictSummary -Path $f.FullName
            if (-not $sum -or -not $sum.Date) { continue }
            $d = $null
            try { $d = [datetime]::ParseExact($sum.Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
            if ($d -lt $monthStart -or $d -ge $monthEnd) { continue }
            $rows += [pscustomobject]@{ Task = $f.BaseName; Verdict = $sum.Verdict; Date = $sum.Date; Accepted = ''; Hours = $null; Tokens = 0.0 }
        }
    }

    # 2. Приёмка лидера — по тем же задачам.
    foreach ($row in $rows) {
        $accPath = Get-BcfAcceptancePath -TaskId $row.Task -Root $project
        if (Test-Path -LiteralPath $accPath) {
            $acc = ConvertFrom-BcfAcceptanceText -Body (Get-Content -Raw -LiteralPath $accPath -ErrorAction SilentlyContinue)
            $accDate = ($acc.When -split 'T')[0]
            $row.Accepted = "$($acc.Leader), $accDate".Trim(', ')
        } else {
            $row.Accepted = if (Test-BcfTaskNeedsAcceptance -Class (Get-BcfTaskClass -TaskId $row.Task -Root $project)) { 'ждёт приёмки' } else { '-' }
        }
    }

    # 3. Часы и токены — из журналов графа, попавших в этот месяц. Задача, сделанная
    # циклом (`bcf run loop`/`night`), в журнале графа не появляется вовсе: столбцы
    # остаются "-", а не выдуманным нулём — ноль читается как «бесплатно и мгновенно».
    $runs = @(Get-BcfRuns -Project $project | Where-Object { $_.Started -ge $monthStart -and $_.Started -lt $monthEnd })
    $hoursByTask = @{}; $tokensByTask = @{}; $tokensByModel = @{}
    foreach ($r in $runs) {
        foreach ($n in $r.Nodes) {
            $tid = Get-BcfTaskIdFromLabel -Label $n.Label
            if ($tid) {
                if (-not $hoursByTask.ContainsKey($tid))  { $hoursByTask[$tid] = 0.0 }
                if (-not $tokensByTask.ContainsKey($tid)) { $tokensByTask[$tid] = 0.0 }
                if ($n.Started -and $n.Finished) { $hoursByTask[$tid] += ($n.Finished - $n.Started).TotalHours }
                $tokensByTask[$tid] += [double]$n.Tokens
            }
            if ($n.Model) {
                if (-not $tokensByModel.ContainsKey($n.Model)) { $tokensByModel[$n.Model] = 0.0 }
                $tokensByModel[$n.Model] += [double]$n.Tokens
            }
        }
    }
    foreach ($row in $rows) {
        if ($hoursByTask.ContainsKey($row.Task))  { $row.Hours  = $hoursByTask[$row.Task] }
        if ($tokensByTask.ContainsKey($row.Task)) { $row.Tokens = $tokensByTask[$row.Task] }
    }

    # Деньги — теми же функциями, что `bcf cost`: тариф по модели, честное «неизвестно»
    # вместо нуля там, где бэкенд не сообщает токены или тарифа для модели нет.
    $pricing = Get-BcfPricing -Project $project
    $totalCost = 0.0; $anyUnknownCost = $false; $totalTokensAllRuns = 0.0
    foreach ($m in $tokensByModel.Keys) {
        $totalTokensAllRuns += $tokensByModel[$m]
        $c = Get-BcfNodeCost -Pricing $pricing -Model $m -Tokens $tokensByModel[$m]
        if ($null -eq $c) { $anyUnknownCost = $true } else { $totalCost += $c }
    }

    # 4. Незакрытые задачи последнего ночного прогона — .bcf/run-all.status.json несёт
    # только ОДИН прогон (последний, файл перезаписывается), поэтому его needs_human и
    # gate_blocked попадают в отчёт месяца, только если сам прогон («when») случился в
    # запрошенном окне — иначе застрявшая в прошлом месяце задача выглядела бы затыком
    # текущего.
    $statusFile = Join-Path $project '.bcf\run-all.status.json'
    $stuckRows = @()
    if (Test-Path -LiteralPath $statusFile) {
        try {
            $st = Get-Content -Raw -LiteralPath $statusFile -ErrorAction Stop | ConvertFrom-Json
            $stWhen = $null
            if ($st.when) {
                try { $stWhen = [datetime]::Parse([string]$st.when, [Globalization.CultureInfo]::InvariantCulture) } catch { }
            }
            if ($stWhen -and $stWhen -ge $monthStart -and $stWhen -lt $monthEnd) {
                foreach ($h in @($st.needs_human))  { $stuckRows += [pscustomobject]@{ Task = [string]$h.task; Reason = [string]$h.reason } }
                foreach ($g in @($st.gate_blocked))  { $stuckRows += [pscustomobject]@{ Task = [string]$g.task; Reason = [string]$g.reason } }
            }
        } catch { }
    }

    $reportsDir = Join-Path $project 'docs\reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $reportPath = Join-Path $reportsDir "$exportMonth.md"

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Отчёт фабрики — $exportMonth")
    [void]$lines.Add('')
    [void]$lines.Add("Сгенерировано ``bcf report --export $exportMonth`` — $(Get-Date -Format 'yyyy-MM-dd HH:mm').")
    [void]$lines.Add('')

    $reportEmpty = (-not $rows.Count) -and (-not $runs.Count) -and (-not $stuckRows.Count)

    if ($reportEmpty) {
        [void]$lines.Add("За $exportMonth не найдено ни одного вердикта (``$verdictsRel/*.md``, поле ``date:``),")
        [void]$lines.Add('ни одного прогона графа (`.bcf/graph/*/journal.jsonl`), ни ночного прогона в этом окне')
        [void]$lines.Add('(`.bcf/run-all.status.json`) — фабрика в этом месяце либо не работала над проектом,')
        [void]$lines.Add('либо работала до того, как в нём завели ' + '`config/harness.json`.')
        [void]$lines.Add('')
        [void]$lines.Add('Отчёт умышленно пуст: строка из другого месяца была бы неправдой о этом.')
    } else {
        if ($rows.Count) {
            [void]$lines.Add('## Задачи')
            [void]$lines.Add('')
            [void]$lines.Add('| задача | вердикт | приёмка | часы | токены |')
            [void]$lines.Add('|---|---|---|---|---|')
            $passCount = 0; $failCount = 0; $sumHours = 0.0; $anyHours = $false
            foreach ($row in ($rows | Sort-Object Task)) {
                if ($row.Verdict -eq 'PASS') { $passCount++ } elseif ($row.Verdict) { $failCount++ }
                $hoursCell = if ($null -ne $row.Hours) { $anyHours = $true; $sumHours += $row.Hours; '{0:N1}' -f $row.Hours } else { '-' }
                $tokensCell = if ($row.Tokens -gt 0) { '{0:N0}' -f $row.Tokens } else { '-' }
                $verdictCell = if ($row.Verdict) { $row.Verdict } else { '-' }
                [void]$lines.Add("| $($row.Task) | $verdictCell | $($row.Accepted) | $hoursCell | $tokensCell |")
            }
            [void]$lines.Add('')
        } else {
            $passCount = 0; $failCount = 0; $sumHours = 0.0; $anyHours = $false
        }

        if ($stuckRows.Count) {
            [void]$lines.Add('## Не закрыто по итогу ночного цикла')
            [void]$lines.Add('')
            [void]$lines.Add('| задача | причина |')
            [void]$lines.Add('|---|---|')
            foreach ($sr in ($stuckRows | Sort-Object Task)) {
                [void]$lines.Add("| $($sr.Task) | $($sr.Reason) |")
            }
            [void]$lines.Add('')
        }

        [void]$lines.Add('## Итог за месяц')
        [void]$lines.Add('')
        [void]$lines.Add("- задач с вердиктом: $($rows.Count) (PASS $passCount, FAIL $failCount)")
        [void]$lines.Add("- прогонов графа в периоде: $($runs.Count)")
        [void]$lines.Add("- незакрыто по итогу ночного цикла: $($stuckRows.Count)")
        [void]$lines.Add("- часов по журналу графа: $(if ($anyHours) { '{0:N1}' -f $sumHours } else { 'не измерено (задачи шли циклом, не графом)' })")
        [void]$lines.Add("- токенов: $('{0:N0}' -f $totalTokensAllRuns)")
        if ($pricing) {
            $costLine = "- стоимость: $(Format-BcfMoney $totalCost $pricing.Currency) (тарифы от $($pricing.Updated))"
            if ($anyUnknownCost) { $costLine += ' — часть моделей без тарифа не вошла в сумму' }
            [void]$lines.Add($costLine)
        } else {
            [void]$lines.Add('- стоимость: тарифы не заданы (config/pricing.json) — только токены')
        }
    }
    [void]$lines.Add('')

    Set-Content -LiteralPath $reportPath -Value ($lines -join "`n") -Encoding UTF8

    Write-BcfTitle "ОТЧЁТ ЗА МЕСЯЦ  $exportMonth" (Split-Path $project -Leaf)
    Write-BcfOk (Get-BcfRelPath -Path $reportPath -Project $project)
    if (-not $reportEmpty) { Write-BcfNote "задач: $($rows.Count), прогонов графа: $($runs.Count), не закрыто ночным циклом: $($stuckRows.Count)" }
    else { Write-BcfWarn 'за месяц не найдено ни вердиктов, ни прогонов графа, ни ночного прогона — отчёт честно пуст' }
    Write-Host ''
    exit 0
}

$runId = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1

# Итог ночного прогона ищем и в новом каталоге, и в старом: проект, водивший харнесс
# до перехода на .bcf/, держит его в loop/. Показать «прогонов не было» при лежащем
# рядом отчёте — это не «не нашли», это неправда.
$statusFile = ''
$reviewFile = ''
foreach ($d in @((Join-Path $project '.bcf'), (Join-Path $project 'loop'))) {
    $s = Join-Path $d 'run-all.status.json'
    if (-not $statusFile -and (Test-Path $s)) { $statusFile = $s }
    $rv = Join-Path $d 'REVIEW.md'
    if (-not $reviewFile -and (Test-Path $rv)) { $reviewFile = $rv }
}
if (-not $statusFile) { $statusFile = Join-Path $project '.bcf\run-all.status.json' }
if (-not $reviewFile) { $reviewFile = Join-Path $project '.bcf\REVIEW.md' }
$graphRun = Resolve-BcfRun -Project $project -RunId $runId

# Что показывать, решает время: у ночного цикла и у графа разные артефакты, и брать
# «свой» без сравнения дат значит показать позавчерашний итог как сегодняшний.
$loopAt = if (Test-Path $statusFile) { (Get-Item $statusFile).LastWriteTime } else { [datetime]::MinValue }
$graphAt = if ($graphRun) { $graphRun.Finished } else { [datetime]::MinValue }

if ($loopAt -eq [datetime]::MinValue -and $graphAt -eq [datetime]::MinValue) {
    Write-BcfDim 'прогонов ещё не было — bcf run queue или bcf run night'
    exit 2
}

if ($runId -or $graphAt -gt $loopAt) {
    # --- Граф ---
    if (-not $graphRun) { Write-BcfFail "прогон '$runId' не найден"; exit 2 }

    $failed = @($graphRun.Nodes | Where-Object { $_.Ok -eq $false })

    # Авторитет итога — то, что вернул САМ граф (поле result события run-finish), а не
    # счётчик отработавших узлов. Это не педантизм: узлы могут все отработать, а очередь
    # остаться незакрытой — «работа-TASK-01» честно завершается и тогда, когда задача не
    # достигла PASS. Отчёт по узлам в этом случае говорит «готово» о неполном прогоне,
    # и именно так неполный прогон принимают за успешный.
    $res = $graphRun.Result
    $complete = if ($null -ne $res -and $res.PSObject.Properties['complete']) {
        [bool]$res.complete
    } else {
        $graphRun.Complete -and -not $failed.Count
    }

    $head = if ($graphRun.DryPlan) { "СУХОЙ ПЛАН   $($graphRun.Name)" }
            elseif ($complete)     { "ГОТОВО   $($graphRun.Name)" }
            else                   { "НЕПОЛНО   $($graphRun.Name)" }
    Write-BcfTitle $head `
                   ("{0} · узлов {1} · {2} · {3} токенов" -f $graphRun.RunId, $graphRun.NodeCount, (Format-BcfDuration $graphRun.Duration), [int]$graphRun.Tokens)

    # Сухой прогон не исполнял НИ ОДНОГО узла, поэтому его «не закрыто» — свойство
    # режима, а не факт о задачах. Выдавать его за итог значит врать ровно тем способом,
    # против которого весь этот отчёт и сделан.
    if ($graphRun.DryPlan) {
        Write-BcfWarn 'это сухой план: агенты не запускались, о состоянии задач он не говорит ничего'
        Write-Host ''
        Write-BcfNote "боевой прогон: bcf run $($graphRun.Name)"
        Write-Host ''
        exit 0
    }

    if (-not $graphRun.Complete) {
        Write-BcfWarn 'прогон оборван — часть узлов не отработала'
        Write-BcfNote "доиграть: bcf run $($graphRun.Name) --resume $($graphRun.RunId) (готовые узлы возьмутся из журнала)"
    }
    if ($null -ne $res -and $res.PSObject.Properties['total']) {
        $line = "закрыто $($res.passed) из $($res.total)"
        if ($res.stuck) { Write-BcfLine "  $line · не закрыто $($res.stuck)" 'Yellow' }
        else            { Write-BcfOk $line }
    }
    if ($failed.Count) {
        Write-Host ''
        Write-BcfLine "  УЗЛЫ, КОТОРЫЕ НЕ ДАЛИ РЕЗУЛЬТАТА  $($failed.Count)" 'Red'
        foreach ($n in $failed) {
            Write-BcfLine "    $($n.Label)   ($($n.Role))" 'Red'
            if ($n.Reason) { Write-BcfNote $n.Reason }
        }
    }
    if (-not $complete) {
        Write-Host ''
        $rvHint = if ($reviewFile -and (Test-Path $reviewFile)) { Get-BcfRelPath -Path $reviewFile -Project $project } else { '.bcf/REVIEW.md' }
        Write-BcfNote "что именно не закрылось и почему — bcf tasks, подробности — $rvHint"
    }

    Write-Host ''
    Write-BcfNote "доска: bcf board $($graphRun.RunId)   ·   расход: bcf cost $($graphRun.RunId)"
    # Настоящий путь журнала, а не тот, где он лежал бы у свежего проекта: по неверной
    # подсказке человек пойдёт искать файл и не найдёт.
    Write-BcfNote "журнал: $(Get-BcfRelPath -Path $graphRun.Journal -Project $project)"
    if ($graphRun.Legacy) { Write-BcfNote 'прогон из старого каталога loop/ — перенести историю: bcf migrate' }
    Write-Host ''
    exit $(if ($complete) { 0 } else { 1 })
}

# --- Ночной цикл ---
$st = $null
try { $st = Get-Content -Raw -LiteralPath $statusFile | ConvertFrom-Json } catch { }
if (-not $st) { Write-BcfFail 'run-all.status.json не разобран'; exit 2 }

Write-BcfTitle $(if ($st.complete) { 'ГОТОВО   ночной прогон' } else { 'НЕПОЛНО   ночной прогон' }) `
               "$($st.when) · закрыто $($st.passed) из $($st.total)"

if ($st.complete) {
    Write-BcfOk "все $($st.total) задач закрыты (PASS)"
} else {
    Write-BcfLine "  не закрыто $($st.stuck) из $($st.total)" 'Yellow'

    $human = @($st.needs_human)
    $gate = @($st.gate_blocked)

    # Разделение обязательное: чинить надо КОРНИ, а не список. Задача, заблокированная
    # каскад-гейтом, закроется сама, как только закроется её предшественник; попытка
    # чинить её напрямую — потраченное время.
    if ($human.Count) {
        Write-Host ''
        Write-BcfLine '  ПОЧИНИ ЭТО ПЕРВЫМ (сама задача застряла)' 'Red'
        foreach ($h in $human) {
            $blocks = @($h.blocks | Where-Object { $_ })
            $suffix = if ($blocks.Count) { "  → разблокирует $($blocks.Count): $($blocks -join ', ')" } else { '' }
            Write-BcfLine "    $($h.task)  —  $($h.reason)$suffix" 'Red'
        }
    }
    if ($gate.Count) {
        Write-Host ''
        Write-BcfLine "  ЖДУТ ПРЕДШЕСТВЕННИКА  $($gate.Count)" 'DarkGray'
        Write-BcfDim (($gate | ForEach-Object { $_.task }) -join ', ')
        Write-BcfNote 'эти закроются сами после фикса корней — чинить их напрямую бессмысленно.'
    }
}

Write-Host ''
if (Test-Path $reviewFile) { Write-BcfNote "подробности: $(Get-BcfRelPath -Path $reviewFile -Project $project)" }
Write-BcfNote "машиночитаемо: $(Get-BcfRelPath -Path $statusFile -Project $project)   ·   состояние очереди: bcf tasks"
if ($statusFile -match '[\\/]loop[\\/]') { Write-BcfNote 'итог из старого каталога loop/ — перенести: bcf migrate' }
Write-Host ''
exit $(if ($st.complete) { 0 } else { 1 })
