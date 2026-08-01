# runview.ps1 — живой экран прогона: лента сверху, прибитая доска снизу.
#
# ЗАЧЕМ. Прогон — самый долгий и самый рассматриваемый экран продукта: за ним сидят
# часами. До сих пор `bcf run` просто пробрасывал наружу сырой лог движка —
# «[20:21:49] [graph] TASK-02 готова; правит crates/...» — то есть ровно то, что было в
# проекте ДО появления фабрики. Все спроектированные экраны (карточка, таблицы, доска)
# жили в других командах, а главный оставался нетронутым.
#
# УСТРОЙСТВО (макет «ход 1 · 1a — ПОТОК: лента + прибитая доска»):
#
#   лента          события прогона сверху вниз, scrollback живой — можно отмотать
#   ═════          разделитель
#   доска          перерисовывается на месте: фазы, кто работает, ждут, готово, полоса
#   статус-бар     одна строка итога и подсказок
#
# ПОЧЕМУ ЛЕНТА ОТДЕЛЬНО ОТ ДОСКИ. Доска отвечает на «что сейчас», лента — на «что было».
# Одно без другого не работает: по доске нельзя понять, почему узел упал полчаса назад,
# а по ленте нельзя за секунду увидеть, сколько осталось.
#
# ЧЕСТНОСТЬ. Доска не показывает того, чего не знает: нет тарифов — нет денег, нет
# истории — нет оценки «осталось». Выдуманное число здесь дороже отсутствующего: по нему
# принимают решение, останавливать прогон или ждать.

. (Join-Path $PSScriptRoot 'tui.ps1')
. (Join-Path $PSScriptRoot 'journal.ps1')
. (Join-Path $PSScriptRoot 'pricing.ps1')

$script:RvSpin = @('⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$script:RvSpinAscii = @('|', '/', '-', '\')

function _RvSpin { param([int]$Tick, [int]$Offset = 0)
    if ($script:BcfAscii -or -not (Test-BcfColor)) { return $script:RvSpinAscii[($Tick + $Offset) % $script:RvSpinAscii.Count] }
    return $script:RvSpin[($Tick + $Offset) % $script:RvSpin.Count]
}

function _RvDur { param($Span) return (Format-BcfDuration $Span) }

function _RvTokens { param([double]$N)
    if ($N -ge 1000000) { return ('{0:N2}M' -f ($N / 1000000)) }
    if ($N -ge 1000)    { return ('{0:N0}k' -f ($N / 1000)) }
    return ([int]$N).ToString()
}

# --- Лента: сырая строка движка → строка события -----------------------------------------
#
# Движок пишет `[HH:MM:SS] [graph] текст`. Показывать это как есть нельзя: «[graph]»
# повторяется в каждой строке и не несёт ничего, а важное (провал, слияние, урок) ничем
# не выделено. Разбираем на время + тему + текст и красим по смыслу.
function Convert-BcfFeedLine {
    param([string]$Line)

    $t = $Line.TrimEnd()
    if (-not $t.Trim()) { return $null }

    $time = ''
    $m = [regex]::Match($t, '^\[(\d{2}:\d{2}:\d{2})\]\s*')
    if ($m.Success) { $time = $m.Groups[1].Value; $t = $t.Substring($m.Length) }

    # Служебные префиксы источника: [graph] несёт ноль информации, [memory] — тему.
    $topic = ''
    $m2 = [regex]::Match($t, '^\[(\w+)\]\s*')
    if ($m2.Success) {
        $src = $m2.Groups[1].Value
        $t = $t.Substring($m2.Length)
        if ($src -ne 'graph') { $topic = $src }
    }

    $body = $t.TrimEnd()
    if (-not $body.Trim()) { return $null }

    # Заголовки фаз движок рисует сам — они становятся вехой ленты.
    $mp = [regex]::Match($body, '^──\s*фаза:\s*(.+)$')
    if ($mp.Success) {
        return @{ Time = $time; Kind = 'phase'; Text = $mp.Groups[1].Value.Trim(); Color = 'Cyan' }
    }

    $kind = 'info'; $color = ''
    switch -Regex ($body) {
        '^\s*✗|^\s*!\s' { $kind = 'fail'; $color = 'Red';    break }
        '^\s*✓'         { $kind = 'ok';   $color = 'Green';  break }
        '^\s*→'         { $kind = 'start';$color = 'White';  break }
        '^\s*·'         { $kind = 'dim';  $color = 'DarkGray'; break }
        'волна \d'      { $kind = 'wave'; $color = 'Cyan';   break }
        'урок'          { $kind = 'lesson'; $color = 'DarkCyan'; break }
        'итог:'         { $kind = 'total'; $color = 'White'; break }
    }
    if ($topic -eq 'memory' -and $color -eq '') { $color = 'DarkCyan' }

    return @{ Time = $time; Kind = $kind; Text = $body.Trim(); Topic = $topic; Color = $color }
}

function Write-BcfFeedLine {
    param($Ev)
    if (-not $Ev) { return }
    $w = Get-BcfConsoleWidth
    $stamp = if ($Ev.Time) { Ink ("  " + $Ev.Time) 'DarkGray' } else { '    ' }

    if ($Ev.Kind -eq 'phase') {
        Write-Host ''
        Write-Host ('  ' + (Ink ('── фаза: ' + $Ev.Text + ' ') 'Cyan'))
        return
    }

    $topic = if ($Ev.Topic) { ' ' + (Ink ("[$($Ev.Topic)]") 'DarkGray') } else { '' }
    $text = $Ev.Text
    # Обрезаем по ВИДИМОЙ длине и только то, что длиннее окна: лента листается, и резать
    # её агрессивно значит прятать причины провалов.
    $budget = $w - 14
    if ($text.Length -gt $budget -and $budget -gt 20) { $text = $text.Substring(0, $budget - 1) + '…' }
    $body = if ($Ev.Color) { Ink $text $Ev.Color } else { $text }
    Write-Host ("$stamp$topic  $body")
}

# --- Доска ---------------------------------------------------------------------------------
function Get-BcfRunBoardLines {
    param($Run, [int]$Tick, $Pricing, [string]$Project, [int]$Concurrency = 0)

    $L = New-Object 'System.Collections.Generic.List[object]'
    $w = [math]::Min(100, (Get-BcfConsoleWidth) - 2)

    $L.Add(@{ t = '  ' + (Ink ('═' * $w) 'DarkGray'); c = '' })

    if (-not $Run) {
        $L.Add(@{ t = '  ' + (Ink 'граф стартует…' 'DarkGray'); c = '' })
        return $L.ToArray()
    }

    $running = @($Run.Nodes | Where-Object { $null -eq $_.Ok })
    $doneN   = @($Run.Nodes | Where-Object { $null -ne $_.Ok }).Count
    $okN     = @($Run.Nodes | Where-Object { $_.Ok -eq $true })
    $failed  = @($Run.Nodes | Where-Object { $_.Ok -eq $false })

    $live = Test-BcfRunLive -Run $Run -Project $Project
    $elapsed = if ($live) { (Get-Date) - $Run.Started } else { $Run.Duration }

    # --- Шапка ---
    $agents = if ($Concurrency -gt 0) { "$($running.Count)/$Concurrency" } else { "$($running.Count)" }
    $head = '  ' + (Ink 'ГРАФ' 'White') + ' ' + (Ink $Run.Name 'Cyan') +
            '  ' + (Ink $Run.RunId 'DarkGray') +
            '  ' + (Ink (_RvDur $elapsed) 'White') +
            '  ' + (Ink 'агентов' 'DarkGray') + ' ' + (Ink $agents 'White') +
            '  ' + (Ink 'токенов' 'DarkGray') + ' ' + (Ink (_RvTokens $Run.Tokens) 'White')
    $L.Add(@{ t = $head; c = '' })

    # --- Конвейер фаз ---
    $phases = @($Run.Nodes | ForEach-Object { $_.Phase } | Where-Object { $_ } | Select-Object -Unique)
    if ($phases.Count) {
        $parts = @()
        foreach ($ph in $phases) {
            $inPh = @($Run.Nodes | Where-Object { $_.Phase -eq $ph })
            $d = @($inPh | Where-Object { $null -ne $_.Ok }).Count
            $f = @($inPh | Where-Object { $_.Ok -eq $false }).Count
            $sym = if ($f) { Sym 'fail' } elseif ($d -eq $inPh.Count) { Sym 'ok' } elseif ($d -gt 0 -or $live) { _RvSpin $Tick } else { '·' }
            $c = if ($f) { 'Red' } elseif ($d -eq $inPh.Count) { 'Green' } else { 'Cyan' }
            $parts += (Ink ("$sym $ph $d/$($inPh.Count)") $c)
        }
        $L.Add(@{ t = '  ' + ($parts -join (Ink '  →  ' 'DarkGray')); c = '' })
    }

    # --- Полоса ---
    $total = [math]::Max(1, $Run.NodeCount)
    $pct = [int](100.0 * $doneN / $total)
    $bw = 40
    $fill = [int]($bw * $pct / 100)
    $barTxt = ('█' * $fill) + ('░' * ($bw - $fill))
    if ($script:BcfAscii -or -not (Test-BcfColor)) { $barTxt = ('#' * $fill) + ('.' * ($bw - $fill)) }
    $barColor = if ($failed.Count) { 'Yellow' } elseif ($live) { 'Cyan' } else { 'Green' }

    # Оценка «осталось» — ТОЛЬКО по фактическим длительностям этого прогона. Без основания
    # числа нет: выдуманное «осталось 6 минут» решает за человека, ждать ему или гасить.
    $eta = ''
    $closed = @($okN | Where-Object { $_.Started -and $_.Finished })
    if ($live -and $closed.Count -ge 2 -and $doneN -lt $total) {
        $avg = ($closed | ForEach-Object { ($_.Finished - $_.Started).TotalSeconds } | Measure-Object -Average).Average
        $slots = [math]::Max(1, $running.Count)
        $left = [timespan]::FromSeconds($avg * ($total - $doneN) / $slots)
        $eta = '   ' + (Ink ("осталось ≈ " + (_RvDur $left)) 'DarkGray')
    }
    $L.Add(@{ t = '  ' + (Ink $barTxt $barColor) + (Ink ("  {0,3}%" -f $pct) 'White') + $eta; c = '' })

    # --- Кто работает ---
    if ($running.Count) {
        $L.Add('')
        $L.Add(@{ t = '  работают сейчас'; c = 'White' })
        $pulse = Get-BcfFleetPulse -Project $Project
        $i = 0
        foreach ($n in ($running | Select-Object -First 6)) {
            $until = if ($live) { Get-Date } else { $Run.Finished }
            $d = if ($n.Started) { $until - $n.Started } else { $null }
            $who = @($n.Role, $n.Model) | Where-Object { $_ }
            $money = ''
            if ($Pricing) {
                $c = Get-BcfNodeCost -Pricing $Pricing -Model $n.Model -Tokens $n.Tokens
                if ($null -ne $c) { $money = '  ' + (Format-BcfMoney $c $Pricing.Currency) }
            }
            $spin = if ($live) { _RvSpin $Tick $i } else { Sym 'warn' }
            $L.Add(@{ t = ("   {0} {1,-26} {2,-24} {3,8} {4,8}{5}" -f `
                            $spin, $n.Label, ($who -join ' / '), (_RvDur $d), (_RvTokens $n.Tokens), $money)
                      c = $(if ($live) { '' } else { 'Yellow' }) })
            $i++
        }
        if ($running.Count -gt 6) { $L.Add(@{ t = "     ещё $($running.Count - 6) узлов"; c = 'DarkGray' }) }
        # Пульс — единственное, что мы ЗНАЕМ про «чем занят прямо сейчас»: сколько идёт и
        # сколько молчит поток. Придумывать «правит такой-то файл» мы не станем — агент
        # об этом не сообщает, а правдоподобная выдумка хуже отсутствия строки.
        if ($live -and $pulse -and $pulse.Detail) {
            $L.Add(@{ t = "     пульс: $($pulse.Detail)"; c = 'DarkGray' })
        }
    }

    # --- Провалы ---
    if ($failed.Count) {
        $L.Add('')
        $L.Add(@{ t = "  не дали результата  $($failed.Count)"; c = 'Red' })
        foreach ($n in ($failed | Select-Object -First 3)) {
            $L.Add(@{ t = ("   {0} {1,-26} {2}" -f (Sym 'fail'), $n.Label, $n.Reason); c = 'Red' })
        }
    }

    # --- Готово ---
    if ($okN.Count) {
        $L.Add('')
        $tail = @($okN | Select-Object -Last 3)
        $L.Add(@{ t = "  готово $($okN.Count)"; c = 'DarkGray' })
        foreach ($n in $tail) {
            $d = if ($n.Started -and $n.Finished) { $n.Finished - $n.Started } else { $null }
            $L.Add(@{ t = ("   {0} {1,-26} {2}" -f (Sym 'ok'), $n.Label, (_RvDur $d)); c = 'DarkGray' })
        }
    }

    # --- Статус-бар ---
    $bar = @()
    $bar += (Ink "$($Run.Name) $pct%" 'White')
    $bar += (Ink "$($running.Count) агентов" 'DarkGray')
    $bar += (Ink ((_RvTokens $Run.Tokens) + ' ток.') 'DarkGray')
    if ($Pricing) {
        $c = 0.0; $known = $true
        foreach ($n in $Run.Nodes) {
            $v = Get-BcfNodeCost -Pricing $Pricing -Model $n.Model -Tokens $n.Tokens
            if ($null -eq $v -and $n.Tokens -gt 0) { $known = $false; break }
            if ($null -ne $v) { $c += $v }
        }
        if ($known) { $bar += (Ink (Format-BcfMoney $c $Pricing.Currency) 'DarkGray') }
    }
    $bar += (Ink 'Ctrl-C остановить' 'DarkGray')
    $L.Add('')
    $L.Add(@{ t = '  ' + ($bar -join (Ink ' │ ' 'DarkGray')); c = '' })

    return $L.ToArray()
}

# --- Живой прогон ---------------------------------------------------------------------------
function Invoke-BcfRunLive {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$HarnessArgs,
        [Parameter(Mandatory)][string]$Project,
        [int]$Concurrency = 0
    )

    $log = Join-Path $env:TEMP ("bcf-run-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
    $err = "$log.err"
    $pricing = Get-BcfPricing -Project $Project

    $all = @('-NoProfile', '-File', $ScriptPath) + $HarnessArgs
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $all -NoNewWindow -PassThru `
                          -RedirectStandardOutput $log -RedirectStandardError $err

    $shown = 0
    $tick = 0
    $boardTop = $null
    $boardLines = 0
    $lastRunId = ''

    function _ClearBoard {
        if ($null -eq $script:RvBoardTop) { return }
        try {
            $Host.UI.RawUI.CursorPosition = $script:RvBoardTop
            $w = Get-BcfConsoleWidth
            for ($i = 0; $i -lt $script:RvBoardLines; $i++) { Write-Host (' ' * ($w - 1)) }
            $Host.UI.RawUI.CursorPosition = $script:RvBoardTop
        } catch { }
        $script:RvBoardLines = 0
    }

    $script:RvBoardTop = $null
    $script:RvBoardLines = 0

    while ($true) {
        $exited = $proc.HasExited

        # 1. Новые строки ленты
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue) } catch { }
        if ($lines.Count -gt $shown) {
            _ClearBoard
            for ($i = $shown; $i -lt $lines.Count; $i++) {
                Write-BcfFeedLine (Convert-BcfFeedLine $lines[$i])
            }
            $shown = $lines.Count
            $script:RvBoardTop = $null
        }

        # 2. Доска — на текущем месте курсора
        $run = Get-BcfLastRun -Project $Project
        if ($run -and $run.RunId -ne $lastRunId) { $lastRunId = $run.RunId }

        if (Test-BcfInteractive) {
            if ($null -eq $script:RvBoardTop) {
                try { $script:RvBoardTop = $Host.UI.RawUI.CursorPosition } catch { }
            } else {
                try { $Host.UI.RawUI.CursorPosition = $script:RvBoardTop } catch { }
            }
            $bl = Get-BcfRunBoardLines -Run $run -Tick $tick -Pricing $pricing -Project $Project -Concurrency $Concurrency
            $w = Get-BcfConsoleWidth
            foreach ($l in $bl) {
                $text = if ($l -is [string]) { $l } else { [string]$l.t }
                $color = if ($l -is [string]) { '' } else { [string]$l.c }
                $plain = [regex]::Replace($text, "`e\[[0-9;]*m", '')
                $pad = [math]::Max(0, ($w - 1) - $plain.Length)
                if ($color) { Write-Host ($text + (' ' * $pad)) -ForegroundColor $color }
                else { Write-Host ($text + (' ' * $pad)) }
            }
            $script:RvBoardLines = $bl.Count
        }

        if ($exited) { break }
        Start-Sleep -Milliseconds 900
        $tick++
    }

    $proc.WaitForExit()
    _ClearBoard

    # Хвост stderr показываем всегда: молча проглоченная ошибка запуска — это «прогон
    # отработал мгновенно и ничего не сделал» без единого объяснения.
    try {
        $e = @(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
        if ($e.Count) {
            Write-Host ''
            Write-BcfLine '  ОШИБКИ ДВИЖКА' 'Red'
            foreach ($l in ($e | Select-Object -Last 10)) { Write-Host "  $l" }
        }
    } catch { }

    Remove-Item $log, $err -Force -ErrorAction SilentlyContinue
    return $proc.ExitCode
}
