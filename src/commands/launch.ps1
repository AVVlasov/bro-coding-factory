# bcf (без аргументов) — карточка состояния и выбор запуска.
#
# ЗАЧЕМ ЭТО ЭКРАН, А НЕ СПИСОК КОМАНД. Решение «что запускать» принимается по состоянию:
# сколько задач готово, отвечают ли бэкенды, жива ли память, во что это обойдётся. Список
# команд ничего из этого не показывает — человек всё равно идёт смотреть сам, а потом
# запускает по памяти. Поэтому здесь сразу состояние, а список команд — `bcf help`.
#
# Экран деградирует до печати: без консоли (пайп, CI, планировщик) он показывает то же
# состояние и подсказку, а не падает на чтении клавиши.

. (Join-Path $BcfRoot 'src\lib\tui.ps1')
. (Join-Path $BcfRoot 'src\lib\journal.ps1')
. (Join-Path $BcfRoot 'src\lib\pricing.ps1')
. (Join-Path (Get-BcfHarness) 'lib\claims.ps1')
. (Join-Path $BcfRoot 'src\lib\mascot.ps1')
. (Join-Path $BcfRoot 'src\lib\queue.ps1')
. (Join-Path $BcfRoot 'src\lib\banner.ps1')

$project = $script:BcfProject
$status = Get-BcfBannerStatus -Project $project

Write-BcfBanner -Status $status

$MODES = @(
    @{ key = 'queue';  what = 'очередь задач как граф (волны по зависимостям)' }
    @{ key = 'review'; what = 'разноракурсная приёмка по слитому дереву' }
    @{ key = 'night';  what = 'ночной цикл по всей очереди, автономно' }
    @{ key = 'doctor'; what = 'проверка окружения, агентов не зовёт' }
)

# --screen — отрисовать ОДИН кадр выбора и выйти.
#
# Не украшение и не отладка: без него интерактивный экран не покрыт ничем. Крэш в
# построении кадра (пустой бэклог, задача без файлов, отсутствующая смета) вылезал бы
# только у человека за клавиатурой, то есть в единственном месте, где его нельзя
# ни залогировать, ни воспроизвести.
$screenOnly = $script:BcfArgs -contains '--screen'

# --- Неинтерактивный режим -------------------------------------------------------------
if (-not $screenOnly -and (-not (Test-BcfInteractive) -or (Get-BcfAssumeYes))) {
    Write-BcfLine '  что можно запустить' 'White'
    foreach ($m in $MODES) {
        $suffix = switch ($m.key) {
            'queue'  { "   $($status.Ready) готовы · $($status.Closed) закрыто" }
            'review' { '   по незакоммиченным правкам' }
            default  { '' }
        }
        # doctor — не режим прогона: у него своя команда. Печатать «bcf run doctor»
        # значит дать строку, которую нельзя скопировать и выполнить.
        $line = if ($m.key -eq 'doctor') { "    bcf {0,-12} {1}" -f $m.key, $m.what }
                else { "    bcf run {0,-8} {1}{2}" -f $m.key, $m.what, $suffix }
        Write-Host $line
    }
    Write-Host ''
    Write-BcfNote 'полный список команд — bcf help   ·   состояние очереди — bcf tasks'
    if (-not (Test-BcfInteractive)) {
        Write-BcfNote 'интерактивный выбор недоступен: вывод не в консоль (пайп, CI или фоновый запуск).'
    }
    Write-Host ''
    exit 0
}

# --- Интерактивный выбор ---------------------------------------------------------------
#
# ОДИН курсор на весь экран, а не два. Ходит он по единому списку строк: сначала режимы,
# потом задачи. Благодаря этому «отметить» всегда означает «отметить ТО, НА ЧЁМ СТОИШЬ», а
# не «то, что оказалось первым в текущем окне прокрутки»: второе выглядит работающим ровно
# до первой прокрутки, а дальше молча отмечает не ту задачу.

$queueTasks = @($status.Tasks | Where-Object { -not $_.Pass })
$marked = @{}
foreach ($t in $queueTasks) { $marked[$t.Id] = $t.Ready }   # по умолчанию — то, что готово

$modeIdx  = 0     # какой режим запустится по enter
$cursor   = 0     # 0..MODES-1 — режимы, дальше — задачи
$scroll   = 0
$MAXROWS  = 8

function Get-MarkedCount { return @($queueTasks | Where-Object { $marked[$_.Id] }).Count }
function Update-Estimate {
    return (Get-BcfRunEstimate -Project $project -TaskCount (Get-MarkedCount) -Pricing $status.Pricing)
}
$estimate = Update-Estimate

function Get-RowCount {
    if ($MODES[$modeIdx].key -in @('queue', 'night')) { return $MODES.Count + $queueTasks.Count }
    return $MODES.Count
}

function Build-Screen {
    $L = New-Object 'System.Collections.Generic.List[object]'
    $L.Add(@{ t = '  что запускаем'; c = 'White' })

    for ($i = 0; $i -lt $MODES.Count; $i++) {
        $mark = if ($cursor -eq $i) { Sym 'cursor' } else { ' ' }
        $sel  = if ($modeIdx -eq $i) { Sym 'dot' } else { ' ' }
        $extra = switch ($MODES[$i].key) {
            'queue'  { "$($status.Tasks.Count) задач · $($status.Closed) закрыто · готово $($status.Ready)" }
            'review' { 'по незакоммиченным правкам' }
            'night'  { 'останов — файл .bcf/STOP' }
            'doctor' { 'без единого токена при --no-probe' }
        }
        $c = if ($cursor -eq $i) { 'Cyan' } elseif ($modeIdx -eq $i) { 'White' } else { 'DarkGray' }
        $L.Add(@{ t = ("  {0}{1} {2,-8} {3,-45} {4}" -f $mark, $sel, $MODES[$i].key, $MODES[$i].what, $extra); c = $c })
    }
    $L.Add('')

    if ($MODES[$modeIdx].key -in @('queue', 'night')) {
        $L.Add(@{ t = "  задачи   отмечено $(Get-MarkedCount) из $($queueTasks.Count)   ·   space — отметить, a — все, d — только готовые"; c = 'White' })

        if (-not $queueTasks.Count) {
            $L.Add(@{ t = '      незакрытых задач нет — очередь пуста'; c = 'DarkGray' })
        }
        for ($j = $scroll; $j -lt [math]::Min($scroll + $MAXROWS, $queueTasks.Count); $j++) {
            $t = $queueTasks[$j]
            $row = $MODES.Count + $j
            $mark = if ($cursor -eq $row) { Sym 'cursor' } else { ' ' }
            $box  = if ($marked[$t.Id]) { '[' + (Sym 'boxOn') + ']' } else { '[ ]' }
            $state = if ($t.Ready) { 'готова' }
                     elseif ($t.Preds.Count -gt 2) { "ждёт $($t.Preds.Count) задач" }
                     else { "ждёт $((($t.Preds | ForEach-Object { $_ -replace '^.*-', '' }) -join ','))" }
            $files = if ($t.Files.Count) { $t.Files[0] } else { 'ФАЙЛЫ НЕ ОБЪЯВЛЕНЫ' }
            if ($t.Files.Count -gt 1) { $files += " +$($t.Files.Count - 1)" }
            $c = if ($cursor -eq $row) { 'Cyan' } elseif ($marked[$t.Id]) { '' } else { 'DarkGray' }
            $L.Add(@{ t = ("  {0}{1} {2,-9} {3,-16} {4,-14} {5}" -f $mark, $box, $t.Id, $t.Slug, $state, $files); c = $c })
        }
        $rest = $queueTasks.Count - $scroll - $MAXROWS
        if ($rest -gt 0) { $L.Add(@{ t = "      ещё $rest задач $(Sym down)"; c = 'DarkGray' }) }
        $L.Add('')
    }

    # Смета. Её основание называется всегда: число без видимого происхождения принимают
    # за факт, а решение о запуске принимается именно по нему.
    if ($estimate.Known) {
        $money = if ($null -ne $estimate.Cost) { "   ≈ $(Format-BcfMoney $estimate.Cost $status.Pricing.Currency)" } else { '' }
        $L.Add(@{ t = "  оценка по $($estimate.Runs) прошлым прогонам этого проекта"; c = 'White' })
        $L.Add(@{ t = ("    узлов ~{0}   токенов ~{1:N0}{2}" -f $estimate.Nodes, $estimate.Tokens, $money); c = 'DarkGray' })
        if ($estimate.TopRole) {
            $onModel = if ($estimate.TopModel) { " на $($estimate.TopModel)" } else { '' }
            $L.Add(@{ t = "    дороже всего: $($estimate.TopRole)$onModel — $($estimate.TopShare)% расхода"; c = 'DarkGray' })
        }
        if ($null -eq $estimate.Cost) {
            $L.Add(@{ t = '    в деньгах не считается: тарифов на эти модели нет (config/pricing.json)'; c = 'DarkGray' })
        }
    } else {
        $L.Add(@{ t = "  сметы нет: $($estimate.Why)"; c = 'DarkGray' })
    }
    $L.Add('')
    $L.Add(@{ t = "  $(Sym updown) курсор · space отметить · a все · d готовые · enter запустить · p сухой план · q выход"; c = 'DarkGray' })
    return $L.ToArray()
}

if ($screenOnly) {
    foreach ($l in (Build-Screen)) {
        if ($l -is [string]) { Write-Host $l } else { Write-BcfLine ([string]$l.t) ([string]$l.c) }
    }
    Write-Host ''
    exit 0
}

$frame = New-BcfFrame
$run = ''
$dryPlan = $false
$quit = $false

while (-not $quit -and -not $run) {
    Write-BcfFrame -Frame $frame -Lines (Build-Screen)
    $k = Read-BcfKey
    if (-not $k) { $quit = $true; continue }

    $rows = Get-RowCount
    switch ($k.Key) {
        'UpArrow' {
            if ($cursor -gt 0) { $cursor-- }
            if ($cursor -lt $MODES.Count) { $modeIdx = $cursor; $scroll = 0 }
            elseif (($cursor - $MODES.Count) -lt $scroll) { $scroll = $cursor - $MODES.Count }
        }
        'DownArrow' {
            if ($cursor -lt $rows - 1) { $cursor++ }
            if ($cursor -lt $MODES.Count) { $modeIdx = $cursor; $scroll = 0 }
            elseif (($cursor - $MODES.Count) -ge $scroll + $MAXROWS) { $scroll = $cursor - $MODES.Count - $MAXROWS + 1 }
        }
        'Spacebar' {
            if ($cursor -ge $MODES.Count) {
                $t = $queueTasks[$cursor - $MODES.Count]
                $marked[$t.Id] = -not $marked[$t.Id]
                $estimate = Update-Estimate
            }
        }
        'A' {
            foreach ($t in $queueTasks) { $marked[$t.Id] = $true }
            $estimate = Update-Estimate
        }
        'D' {
            foreach ($t in $queueTasks) { $marked[$t.Id] = $t.Ready }
            $estimate = Update-Estimate
        }
        'Enter'  { $run = $MODES[$modeIdx].key }
        'P'      { $run = $MODES[$modeIdx].key; $dryPlan = $true }
        'Q'      { $quit = $true }
        'Escape' { $quit = $true }
    }
}

Write-Host ''
if (-not $run) {
    Write-BcfDim 'отменено — ничего не запущено'
    Write-Host ''
    exit 130
}

# Отметки обязаны влиять на запуск. Экран, чьи галочки ни на что не влияют, — худший вид
# интерфейса: он выглядит управлением, а является украшением.
$chosen = @($queueTasks | Where-Object { $marked[$_.Id] } | ForEach-Object { $_.Id })

$call = @()
if ($run -eq 'doctor') {
    $call = @('doctor')
} else {
    $call = @('run', $run)
    if ($dryPlan) { $call += '--dry-plan' }
    if ($run -eq 'queue' -and $chosen.Count -and $chosen.Count -lt $queueTasks.Count) {
        $call += ($chosen | ConvertTo-Json -Compress)
    }
}

Write-BcfLine ("  запускаю: bcf " + ($call -join ' ')) 'Cyan'
if ($run -in @('queue', 'night') -and $chosen.Count) {
    Write-BcfNote "задач отмечено: $($chosen.Count) — $($chosen -join ', ')"
}
Write-Host ''

& pwsh -NoProfile -File (Join-Path $BcfRoot 'bin\bcf.ps1') @call --project $project
exit $LASTEXITCODE
