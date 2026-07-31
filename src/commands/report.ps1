# bcf report — итог одним экраном.
#
#   bcf report            последний прогон (граф или ночной цикл — что было позже)
#   bcf report --last     то же явно
#   bcf report <runId>    конкретный прогон графа
#
# ПРАВИЛО ЭТОГО ОТЧЁТА: «готово» звучит ТОЛЬКО при полностью закрытой очереди. Раньше
# прогон всегда заканчивался словом «готово» — даже когда закрыто 13 задач из 19, и
# человек, и вызывающий агент принимали неполный прогон за успешный.

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$project = $script:BcfProject
$runId = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1

$stateDir = Join-Path $project '.bcf'
$statusFile = Join-Path $stateDir 'run-all.status.json'
$reviewFile = Join-Path $stateDir 'REVIEW.md'
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
                   ("{0} · узлов {1} · {2:hh\:mm\:ss} · {3} токенов" -f $graphRun.RunId, $graphRun.NodeCount, $graphRun.Duration, [int]$graphRun.Tokens)

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
        Write-BcfNote 'что именно не закрылось и почему — bcf tasks, подробности — .bcf/REVIEW.md'
    }

    Write-Host ''
    Write-BcfNote "доска: bcf board $($graphRun.RunId)   ·   расход: bcf cost $($graphRun.RunId)"
    Write-BcfNote "журнал: .bcf/graph/$($graphRun.RunId)/journal.jsonl"
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
if (Test-Path $reviewFile) { Write-BcfNote 'подробности: .bcf/REVIEW.md' }
Write-BcfNote 'машиночитаемо: .bcf/run-all.status.json   ·   состояние очереди: bcf tasks'
Write-Host ''
exit $(if ($st.complete) { 0 } else { 1 })
