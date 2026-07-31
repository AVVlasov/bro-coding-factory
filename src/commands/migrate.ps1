# bcf migrate — перенести состояние прогонов из старого каталога loop/ в .bcf/.
#
#   bcf migrate --dry      показать, что будет перенесено
#   bcf migrate            перенести
#   bcf migrate --copy     скопировать, а не переместить (старое остаётся на месте)
#
# ЗАЧЕМ. Проекты, которые водили харнесс до перехода на .bcf/, держат историю в
# loop/.graph, loop/.fleet, loop/retros и так далее. Читать её `bcf` умеет и без переноса
# (иначе он врал бы «прогонов не было» при полусотне журналов), но ПИШЕТ он только в
# .bcf/. Пока история разделена, список прогонов склеивается из двух источников — и
# однажды кто-нибудь удалит loop/ вместе с ней.
#
# ЧЕГО ЭТА КОМАНДА НЕ ДЕЛАЕТ. Не трогает СКРИПТЫ старого харнесса (loop/*.ps1): движок
# теперь живёт в фабрике, а копия в проекте может оставаться сколько угодно — она не
# мешает. Не трогает git-историю. Не трогает config/, tasks/, agents/.

$project = $script:BcfProject
$dry = $script:BcfArgs -contains '--dry'
$copy = $script:BcfArgs -contains '--copy'

$legacyRoot = Join-Path $project 'loop'
$stateDir = Join-Path $project '.bcf'

# Что чем становится. Скрытые каталоги теряют точку: внутри .bcf она уже ничего не
# скрывает, а «.bcf/.graph» читается как опечатка.
$MAP = @(
    @{ from = '.graph';                 to = 'graph';        what = 'журналы прогонов графа' }
    @{ from = '.fleet';                 to = 'fleet';        what = 'заявки на файлы и история конфликтов' }
    @{ from = '.workers';               to = 'workers';      what = 'песочницы CLI-агентов' }
    @{ from = '.verify';                to = 'verify';       what = 'выводы тестеров и судьи' }
    @{ from = 'retros';                 to = 'retros';       what = 'ретроспективы итераций' }
    @{ from = 'state';                  to = 'state';        what = 'проекция состояния цикла' }
    @{ from = 'events.jsonl';           to = 'events.jsonl'; what = 'журнал событий цикла' }
    @{ from = 'loop.log';               to = 'loop.log';     what = 'лог цикла' }
    @{ from = 'REVIEW.md';              to = 'REVIEW.md';    what = 'итог ночного прогона' }
    @{ from = 'REVIEW-graph.md';        to = 'REVIEW-graph.md'; what = 'итог приёмки графом' }
    @{ from = 'run-all.status.json';    to = 'run-all.status.json'; what = 'машиночитаемый статус очереди' }
    @{ from = 'STATE.md';               to = 'STATE.md';     what = 'состояние для агента (legacy)' }
    @{ from = 'human-callout.md';       to = 'human-callout.md'; what = 'вызов человека' }
    @{ from = 'tester-scope-map.json';  to = $null;          what = 'карта тестеров — это КОНФИГ, ему место в config/' }
)

Write-BcfTitle "ПЕРЕНОС СОСТОЯНИЯ  $(Split-Path $project -Leaf)" `
               "loop/ → .bcf/$(if ($dry) { '   · сухой прогон, ничего не пишется' } elseif ($copy) { '   · копирование, старое остаётся' } else { '   · перемещение' })"

if (-not (Test-Path $legacyRoot)) {
    Write-BcfOk 'старого каталога loop/ нет — переносить нечего'
    Write-Host ''
    exit 0
}

$plan = @()
foreach ($m in $MAP) {
    $src = Join-Path $legacyRoot $m.from
    if (-not (Test-Path $src)) { continue }
    $isDir = (Get-Item -LiteralPath $src).PSIsContainer
    $size = if ($isDir) { @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue).Count } else { 1 }
    $plan += [pscustomobject]@{
        From = $src; Rel = $m.from; To = $m.to; What = $m.what; IsDir = $isDir; Items = $size
    }
}

if (-not $plan.Count) {
    Write-BcfOk 'в loop/ нет состояния прогонов — переносить нечего'
    Write-BcfNote 'скрипты старого харнесса (loop/*.ps1) эта команда не трогает: движок теперь в фабрике,'
    Write-BcfNote 'а их копия в проекте не мешает.'
    Write-Host ''
    exit 0
}

$rows = New-BcfRows
foreach ($p in $plan) {
    $dest = if ($p.To) { ".bcf/$($p.To)" } else { '— (не переносится)' }
    Add-BcfRow $rows @("loop/$($p.Rel)", $dest, "$($p.Items)", $p.What)
}
Write-BcfTable -Headers @('откуда', 'куда', 'файлов', 'что это') -Widths @(24, 24, 8, 44) -Rows $rows

$skipped = @($plan | Where-Object { -not $_.To })
if ($skipped.Count) {
    Write-Host ''
    foreach ($s in $skipped) {
        Write-BcfWarn "loop/$($s.Rel) не переносится: $($s.What)"
        Write-BcfNote "перенеси руками в config/ и проверь, что на него ссылается config/harness.json."
    }
}

# Столкновение имён — единственный случай, когда перенос может ПОТЕРЯТЬ данные, поэтому
# он останавливается, а не «решает сам, что новее».
$clash = @()
foreach ($p in ($plan | Where-Object { $_.To })) {
    $dst = Join-Path $stateDir $p.To
    if (Test-Path $dst) { $clash += $p }
}
if ($clash.Count) {
    Write-Host ''
    Write-BcfFail "в .bcf/ уже есть: $(($clash | ForEach-Object { $_.To }) -join ', ')"
    Write-BcfNote 'перенос остановлен: слить две истории автоматически нельзя, а выбрать «которая новее»'
    Write-BcfNote 'за тебя — значит однажды выбрать не ту. Разнеси руками или удали лишнее.'
    Write-Host ''
    exit 1
}

if ($dry) {
    Write-Host ''
    Write-BcfWarn 'сухой прогон: на диск ничего не записано.'
    Write-BcfNote 'перенести: bcf migrate   ·   скопировать: bcf migrate --copy'
    Write-Host ''
    exit 0
}

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$moved = 0
foreach ($p in ($plan | Where-Object { $_.To })) {
    $dst = Join-Path $stateDir $p.To
    try {
        if ($copy) { Copy-Item -LiteralPath $p.From -Destination $dst -Recurse -Force }
        else       { Move-Item -LiteralPath $p.From -Destination $dst -Force }
        $moved++
        Write-BcfOk "loop/$($p.Rel) → .bcf/$($p.To)   ($($p.Items) файлов)"
    } catch {
        Write-BcfFail "loop/$($p.Rel): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-BcfLine "  перенесено: $moved из $(@($plan | Where-Object { $_.To }).Count)" 'White'

# .gitignore старого харнесса перечисляет loop/-пути. Оставить их — не ошибка, но
# состояние в .bcf/ окажется НЕ игнорируемым, и первый же коммит утащит журналы в git.
$gi = Join-Path $project '.gitignore'
if (Test-Path $gi) {
    $lines = @(Get-Content -LiteralPath $gi)
    if ($lines -notcontains '.bcf/') {
        Add-Content -LiteralPath $gi -Value "`n# --- bcf: состояние прогонов ---`n.bcf/" -Encoding UTF8
        Write-BcfOk '.gitignore: добавлен .bcf/'
    }
    $stale = @($lines | Where-Object { $_ -match '^loop/\.' -or $_ -match '^loop/(loop\.log|events\.jsonl|REVIEW|STATE|run-all|retros)' })
    if ($stale.Count) {
        Write-BcfNote "в .gitignore остались строки для старых путей ($($stale.Count)) — они больше ничего не игнорируют, можно убрать."
    }
}

Write-Host ''
Write-BcfNote 'проверить: bcf runs   ·   итог последнего: bcf report'
Write-Host ''
exit 0
