# bcf watch — живая доска прогона.
#
#   bcf watch            следить за идущим прогоном (или ждать, пока он начнётся)
#   bcf watch <runId>    проиграть доску конкретного прогона
#   bcf watch --once     нарисовать один кадр и выйти
#
# ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА, А НЕ «СМОТРЕТЬ В ОКНО ПРОГОНА». Прогон идёт часами и обычно
# запущен в другом окне, на другой машине или по расписанию. Вопрос «что там сейчас»
# возникает постоянно, и до сих пор ответом было «открой journal.jsonl» — то есть читать
# JSON глазами. Доска отвечает на него за секунду.
#
# ЧИТАЕТ ЖУРНАЛ, А НЕ ПРОЦЕСС. Поэтому она работает и для чужого прогона, и после его
# конца, и одновременно в трёх окнах. Ни одной новой сущности состояния не заводится:
# журнал уже есть и уже единственный источник правды.

. (Join-Path $BcfRoot 'src\lib\tui.ps1')
. (Join-Path $BcfRoot 'src\lib\journal.ps1')
. (Join-Path $BcfRoot 'src\lib\pricing.ps1')

$project = $script:BcfProject
$once = $script:BcfArgs -contains '--once'
$runId = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1

$pricing = Get-BcfPricing -Project $project

# Прогон считаем живым, если журнал дописывался недавно. Отдельного признака «идёт» у нас
# нет и заводить его нельзя: файл-маркер переживёт падение процесса и будет врать, что
# прогон идёт, до следующей уборки.
$LIVE_SEC = 90

function Get-BcfWatchTarget {
    param([string]$Id)
    if ($Id) { return (Resolve-BcfRun -Project $project -RunId $Id) }
    return (Get-BcfLastRun -Project $project)
}

# Спиннер — не украшение. Он отвечает на единственный вопрос, который задают доске в
# первую секунду: «оно вообще живое или подвисло?». Статичный экран на этот вопрос не
# отвечает вовсе.
$SPIN = @('⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$SPIN_ASCII = @('|', '/', '-', '\')

function Get-Spin { param([int]$Tick, [int]$Offset = 0)
    if ($script:BcfAscii -or -not (Test-BcfColor)) { return $SPIN_ASCII[($Tick + $Offset) % $SPIN_ASCII.Count] }
    return $SPIN[($Tick + $Offset) % $SPIN.Count]
}

function Format-Dur { param($Span) return (Format-BcfDuration $Span) }

function Build-Board {
    param($Run, [int]$Tick)

    $L = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Run) {
        $L.Add(@{ t = '  прогонов ещё не было'; c = 'DarkGray' })
        $L.Add(@{ t = '  запустить: bcf run queue'; c = 'DarkGray' })
        return $L.ToArray()
    }

    $age = (Get-Date) - $Run.Finished
    $live = (-not $Run.Complete) -and ($age.TotalSeconds -lt $LIVE_SEC)
    $elapsed = if ($live) { (Get-Date) - $Run.Started } else { $Run.Duration }

    $state = if ($Run.DryPlan) { 'сухой план' }
             elseif ($live) { 'идёт' }
             elseif (-not $Run.Complete) { 'ОБОРВАН' }
             else { 'завершён' }
    $stateColor = if ($live) { 'Cyan' } elseif ($Run.DryPlan) { 'DarkGray' } elseif (-not $Run.Complete) { 'Yellow' } else { 'Green' }

    $head = '  ' + (Ink 'ГРАФ' 'White') + ' ' + (Ink $Run.Name 'Cyan') +
            '  ' + (Ink $Run.RunId 'DarkGray') +
            '  ' + (Ink (Format-Dur $elapsed) 'White') +
            '  ' + (Ink ("{0:N0} ток." -f $Run.Tokens) 'White')
    $cost = Get-BcfNodeCost -Pricing $pricing -Model '' -Tokens 0
    $L.Add(@{ t = $head + '  ' + (Ink $state $stateColor); c = '' })
    $L.Add('')

    # --- Фазы: одна строка на фазу, потому что фаз мало, а узлов много -------------------
    $phases = @($Run.Nodes | ForEach-Object { $_.Phase } | Where-Object { $_ } | Select-Object -Unique)
    $bar = ''
    foreach ($ph in $phases) {
        $inPh = @($Run.Nodes | Where-Object { $_.Phase -eq $ph })
        $done = @($inPh | Where-Object { $null -ne $_.Ok }).Count
        $failed = @($inPh | Where-Object { $_.Ok -eq $false }).Count
        $sym = if ($failed) { Sym 'fail' } elseif ($done -eq $inPh.Count) { Sym 'ok' } else { Get-Spin $Tick }
        $c = if ($failed) { 'Red' } elseif ($done -eq $inPh.Count) { 'Green' } else { 'Cyan' }
        $L.Add(@{ t = ("  {0} {1,-12} {2}/{3}" -f $sym, $ph, $done, $inPh.Count); c = $c })
    }
    $L.Add('')

    # --- Кто работает прямо сейчас -------------------------------------------------------
    $running = @($Run.Nodes | Where-Object { $null -eq $_.Ok })
    if ($running.Count) {
        # Заголовок и таймер зависят от того, ЖИВОЙ ли прогон. У оборванного узел не
        # работает — он не завершился, и растущий счётчик там означал бы, что работа идёт,
        # когда процесса давно нет. Время считаем до последней записи в журнал, а не до
        # «сейчас».
        $L.Add(@{ t = $(if ($live) { '  работают сейчас' } else { '  не завершились' }); c = $(if ($live) { 'White' } else { 'Yellow' }) })
        $i = 0
        foreach ($n in ($running | Select-Object -First 8)) {
            $until = if ($live) { Get-Date } else { $Run.Finished }
            $d = if ($n.Started) { $until - $n.Started } else { $null }
            $who = @($n.Role, $n.Model) | Where-Object { $_ }
            $spin = if ($live) { Get-Spin $Tick $i } else { Sym 'warn' }
            $L.Add(@{ t = ("   {0} {1,-28} {2,-26} {3}" -f $spin, $n.Label, ($who -join ' / '), (Format-Dur $d)); c = $(if ($live) { '' } else { 'Yellow' }) })
            $i++
        }
        if ($running.Count -gt 8) { $L.Add(@{ t = "     ещё $($running.Count - 8) узлов"; c = 'DarkGray' }) }
        $L.Add('')
    }

    # --- Провалы: рядом с причиной, а не отдельным разделом внизу ------------------------
    $failed = @($Run.Nodes | Where-Object { $_.Ok -eq $false })
    if ($failed.Count) {
        $L.Add(@{ t = "  не дали результата  $($failed.Count)"; c = 'Red' })
        foreach ($n in ($failed | Select-Object -First 5)) {
            $L.Add(@{ t = ("   {0} {1,-28} {2}" -f (Sym 'fail'), $n.Label, $n.Reason); c = 'Red' })
        }
        $L.Add('')
    }

    # --- Готовые -------------------------------------------------------------------------
    $ok = @($Run.Nodes | Where-Object { $_.Ok -eq $true })
    if ($ok.Count) {
        $tail = @($ok | Select-Object -Last 4)
        $L.Add(@{ t = "  готово $($ok.Count)"; c = 'DarkGray' })
        foreach ($n in $tail) {
            $d = if ($n.Started -and $n.Finished) { $n.Finished - $n.Started } else { $null }
            $L.Add(@{ t = ("   {0} {1,-28} {2}  {3,8} ток." -f (Sym 'ok'), $n.Label, (Format-Dur $d), [int]$n.Tokens); c = 'DarkGray' })
        }
        $L.Add('')
    }

    # --- Полоса и строка состояния -------------------------------------------------------
    $total = [math]::Max(1, $Run.NodeCount)
    $doneN = @($Run.Nodes | Where-Object { $null -ne $_.Ok }).Count
    $pct = [int](100.0 * $doneN / $total)
    $w = 40
    $fill = [int]($w * $pct / 100)
    $barTxt = ('█' * $fill) + ('░' * ($w - $fill))
    if ($script:BcfAscii -or -not (Test-BcfColor)) { $barTxt = ('#' * $fill) + ('.' * ($w - $fill)) }

    $money = ''
    if ($pricing) {
        $c = 0.0; $known = $true
        foreach ($n in $Run.Nodes) {
            $v = Get-BcfNodeCost -Pricing $pricing -Model $n.Model -Tokens $n.Tokens
            if ($null -eq $v -and $n.Tokens -gt 0) { $known = $false; break }
            if ($null -ne $v) { $c += $v }
        }
        if ($known) { $money = '  ' + (Format-BcfMoney $c $pricing.Currency) }
    }

    $L.Add(@{ t = '  ' + (Ink $barTxt 'Cyan') + (Ink ("  {0,3}%  {1}/{2} узлов{3}" -f $pct, $doneN, $total, $money) 'White'); c = '' })
    return $L.ToArray()
}

# --- Один кадр -------------------------------------------------------------------------
$run = Get-BcfWatchTarget -Id $runId
if ($once -or -not (Test-BcfInteractive)) {
    foreach ($l in (Build-Board -Run $run -Tick 0)) {
        if ($l -is [string]) { Write-Host $l } else { Write-BcfLine ([string]$l.t) ([string]$l.c) }
    }
    Write-Host ''
    if (-not (Test-BcfInteractive) -and -not $once) {
        Write-BcfNote 'живое слежение недоступно: вывод не в консоль. Один кадр — bcf watch --once.'
    }
    exit 0
}

# --- Живое слежение --------------------------------------------------------------------
#
# Перечитываем журнал целиком раз в секунду. Это выглядит расточительно и не является им:
# журнал прогона — десятки килобайт, а инкрементальное чтение с позиции пришлось бы
# синхронизировать с тем, кто в него пишет параллельно, — то есть завести вторую точку
# правды ради экономии, которой не видно.
Write-Host ''
Write-BcfNote 'слежу за прогоном — q или Ctrl-C чтобы выйти (прогон продолжится)'
$frame = New-BcfFrame
$tick = 0
$lastId = if ($run) { $run.RunId } else { '' }

while ($true) {
    $run = Get-BcfWatchTarget -Id $runId
    if ($run -and $run.RunId -ne $lastId) {
        # Начался новый прогон — доска обязана перескочить на него сама. Иначе смотришь на
        # завершившийся и думаешь, что ничего не происходит.
        $lastId = $run.RunId
        $frame = New-BcfFrame
    }
    Write-BcfFrame -Frame $frame -Lines (Build-Board -Run $run -Tick $tick)

    if ($run -and $run.Complete -and -not $runId) {
        Write-Host ''
        Write-BcfNote "прогон завершён — итог: bcf report $($run.RunId)"
        break
    }

    # Ждём секунду, но клавишу читаем сразу: доска, которая не выходит по q целую секунду,
    # ощущается зависшей.
    $waited = 0
    while ($waited -lt 1000) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -in @('Q', 'Escape')) { Write-Host ''; exit 0 }
        }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    $tick++
}
Write-Host ''
exit 0
