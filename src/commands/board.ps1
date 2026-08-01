# bcf board — доска прогона: узлы по фазам, роли, время, токены.
#
#   bcf board            последний прогон
#   bcf board <runId>    конкретный
#
# ЗАЧЕМ. «Какие узлы упали и на чём» читается с доски за секунду, а из journal.jsonl —
# нет. Доска строится ПО ЖУРНАЛУ, а не по отдельной сводке: сводка, живущая рядом с
# журналом, рано или поздно начинает с ним расходиться, и расходится молча.

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$project = $script:BcfProject
$runId = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1

$run = Resolve-BcfRun -Project $project -RunId $runId
if (-not $run) {
    if ($runId) { Write-BcfFail "прогон '$runId' не найден" } else { Write-BcfDim 'прогонов ещё не было — bcf run queue' }
    exit 2
}

$state = if (-not $run.Complete) { 'ОБОРВАН' } elseif ($run.Failed) { "провалов $($run.Failed)" } else { 'завершён' }
Write-BcfTitle "ГРАФ  $($run.Name)  ·  $($run.RunId)" `
               ("{0}  ·  узлов {1}  ·  {2}  ·  {3} токенов" -f $state, $run.NodeCount, (Format-BcfDuration $run.Duration), [int]$run.Tokens)

$phases = @($run.Nodes | ForEach-Object { $_.Phase } | Where-Object { $_ } | Select-Object -Unique)
if (-not $phases.Count) { $phases = @('') }

foreach ($ph in $phases) {
    $inPhase = @($run.Nodes | Where-Object { $_.Phase -eq $ph })
    $ok = @($inPhase | Where-Object { $_.Ok -eq $true }).Count
    $title = if ($ph) { $ph } else { '(без фазы)' }
    $mark = if ($ok -eq $inPhase.Count) { '✓' } elseif (@($inPhase | Where-Object { $_.Ok -eq $false }).Count) { '✗' } else { '⏳' }
    Write-Host ''
    Write-BcfLine ("  {0} {1}   {2}/{3}" -f $mark, $title, $ok, $inPhase.Count) `
                 $(if ($ok -eq $inPhase.Count) { 'Green' } else { 'Yellow' })

    foreach ($n in $inPhase) {
        $dur = if ($n.Started -and $n.Finished) { '{0:mm\:ss}' -f ($n.Finished - $n.Started) } else { '  —  ' }
        $who = @($n.Role, $n.Model) | Where-Object { $_ }
        $sym = if ($n.Ok -eq $true) { '✓' } elseif ($n.Ok -eq $false) { '✗' } else { '·' }
        $col = if ($n.Ok -eq $true) { '' } elseif ($n.Ok -eq $false) { 'Red' } else { 'DarkGray' }
        $suffix = @()
        if ($n.Cached) { $suffix += 'из журнала' }
        if ($n.Dry)    { $suffix += 'сухой' }
        Write-BcfLine ("      {0} {1,-34} {2,-26} {3}  {4,8} ток. {5}" -f `
                       $sym, $n.Label, ($who -join ' / '), $dur, [int]$n.Tokens, ($suffix -join ' · ')) $col
        # Причина провала печатается ЗДЕСЬ, а не в отдельном разделе внизу: разбор идёт
        # сверху вниз, и заставлять человека искать причину в конце — значит платить его
        # вниманием за экономию трёх строк.
        if ($n.Ok -eq $false -and $n.Reason) { Write-BcfNote "  ↳ $($n.Reason)" }
    }
}

Write-Host ''
# Печатаем НАСТОЯЩИЙ путь журнала, а не тот, где он лежал бы у свежего проекта:
# у проекта со старым каталогом человек пойдёт по подсказке и файла там не найдёт.
Write-BcfNote "журнал: $(Get-BcfRelPath -Path $run.Journal -Project $project)"
if ($run.Legacy) { Write-BcfNote 'прогон из старого каталога loop/ — перенести историю: bcf migrate' }
if (-not $run.Complete) {
    Write-BcfNote "доиграть: bcf run $($run.Name) --resume $($run.RunId)"
}
Write-BcfNote "расход по ролям: bcf cost $($run.RunId)"
Write-Host ''
exit 0
