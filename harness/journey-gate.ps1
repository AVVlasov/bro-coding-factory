# journey-gate.ps1 — гейт «продуктом можно пользоваться», а не «дерево в порядке».
#
# ЗАЧЕМ. Прогон clinic-scheduler 2026-08-09 закрылся отчётом «COMPLETE — все 35 задач
# закрыты (PASS)». В этот момент в продукте не работал НИ ОДИН клиентский путь: оператор
# не мог найти слот, регистратор не мог принять оплату и напечатать талон, врач и
# регистратор показывали чужой день под сегодняшней датой. Все гейты были зелёные и не
# соврали: tsc проверяет типы, eslint — стиль, юнит-тесты экранов — экран против МОКА
# своего же API. Ни один из них не утверждает, что человек может выполнить работу.
#
# Разрыв не в строгости проверок, а в том, ЧТО ими доказывается. Задача доказывается
# своими тестами — и это правильно. Но у продукта нет собственного условия готовности,
# и сумма закрытых задач молча выдаётся за работающий продукт. Пять кругов приёмки
# нашли 30+ дефектов стыков и ни разу не сказали «оператор не может записать пациента»:
# приёмка читала диффы, а приложение не запускала.
#
# ЧТО ДЕЛАЕТ ЭТОТ ГЕЙТ. Проект объявляет свои СКВОЗНЫЕ СЦЕНАРИИ в config/journeys.json —
# по одному на каждый путь, ради которого продукт существует. Гейт проверяет три вещи,
# и каждая ловит свой способ соврать:
#
#   1. У каждого объявленного сценария есть файл-доказательство. Ловит «сценарий описали
#      и забыли»: без этого реестр превращается в список намерений.
#   2. Команда сценариев отработала с нулевым кодом. Ловит сломанный путь.
#   3. Идентификатор КАЖДОГО сценария встретился в выводе прогона. Ловит тихий ноль:
#      у большинства раннеров фильтр, которому ничего не соответствует, даёт exit 0
#      («0 tests»). Без этой проверки удалённый сценарий выглядит как пройденный.
#
# ЧЕГО ГЕЙТ НАМЕРЕННО НЕ ДЕЛАЕТ. Он не знает ни про браузер, ни про React, ни про HTTP:
# как именно проверяется сценарий — дело проекта, оно в его команде. Гейт отвечает
# только за то, что список сценариев существует, полон и целиком зелёный.
#
# config/journeys.json:
#
#   {
#     "command": "npx --no-install vitest run src/journeys --reporter=basic",
#     "journeys": [
#       { "id": "operator-book",
#         "title": "Оператор находит свободный слот и записывает пациента",
#         "proof": "src/journeys/operator-book.journey.test.tsx" }
#     ]
#   }
#
#   command  — чем сценарии прогоняются. Пусто = взять tests.command из harness.json.
#   commandOne — чем прогоняется ОДИН сценарий; {id} подставляется. Обязателен для всего,
#              кроме vitest и jest: только у них есть флаг -t, которым гейт добирает
#              поштучную атрибуцию. Для Maven это ".\\mvnw.cmd -B verify -Dit.test={id}"
#              (failsafe) или "-Dtest={id}" (surefire).
#   id       — обязан дословно встречаться в выводе прогона (проще всего — в имени теста).
#   proof    — путь к файлу, который сценарий доказывает. Обязан существовать.
#   status   — "required" (по умолчанию) или "planned".
#
# ПРО status. Реестр обязан содержать ВСЕ пути продукта с самого начала, а не по мере
# их реализации: иначе гейт снова доказывает ровно то, что уже сделано, и молчит про
# остальное. Но объявить шесть путей и потребовать все шесть сразу — значит остановить
# очередь на первой же задаче. Поэтому "planned" — это путь, который уже назван, ещё не
# доказан и пока не блокирует слияние; про него громко пишут и гейт, и итоговый отчёт.
# Зелёным гейт становится только когда planned не осталось. Перевод в "required" —
# часть задачи, которая этот путь делает, а не отдельное решение задним числом.
#
# Использование:
#   pwsh harness/journey-gate.ps1                       человекочитаемо
#   pwsh harness/journey-gate.ps1 -Json                 машиночитаемо (для обвязки)
#   pwsh harness/journey-gate.ps1 -Only operator-book   один сценарий
#
# Exit: 0 — все объявленные пути доказаны и зелёные;
#       1 — есть красные или объявленные required без доказательства (блокирует слияние);
#       3 — реестр не заведён или все пути ещё planned;
#       4 — required-пути зелёные, но остались planned: продукт доказан ЧАСТИЧНО.
#
# Слияние блокирует только 1. Коды 3 и 4 означают «доказано не всё» — это дефект
# полноты реестра, а не этой задачи, и он обязан звучать в отчёте, а не останавливать
# конвейер. Но 'complete' от них не наступает: частично доказанный продукт готовым
# не считается.

param(
    [string]$ProjectRoot = '',
    [string]$Only = '',
    [switch]$Json,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

function Out-Result([string]$state, [string]$summary, $journeys, [int]$code) {
    if ($Json) {
        ([ordered]@{
            state    = $state          # ok | fail | not-configured
            summary  = $summary
            total    = @($journeys).Count
            green    = @(@($journeys) | Where-Object { $_.status -eq 'ok' }).Count
            journeys = @($journeys)
        } | ConvertTo-Json -Depth 6)
    }
    exit $code
}

# --- Реестр -------------------------------------------------------------------------
$regFile = Join-Path $root 'config\journeys.json'
if (-not (Test-Path -LiteralPath $regFile)) {
    if (-not $Json) {
        Write-Host "journey-gate: реестр сквозных сценариев не заведён (config/journeys.json)." -ForegroundColor Yellow
        Write-Host "Пока его нет, зелёные гейты доказывают только состояние дерева." -ForegroundColor Yellow
        Write-Host "«Все задачи закрыты» при этом НЕ означает, что продуктом можно пользоваться." -ForegroundColor Yellow
    }
    Out-Result 'not-configured' 'config/journeys.json отсутствует' @() 3
}

try { $reg = Get-Content -Raw -LiteralPath $regFile | ConvertFrom-Json }
catch {
    if (-not $Json) { Write-Host "journey-gate: config/journeys.json не разобран: $($_.Exception.Message)" -ForegroundColor Red }
    Out-Result 'fail' "config/journeys.json не разобран: $($_.Exception.Message)" @() 1
}

$all = @($reg.journeys | Where-Object { $_ -and $_.id })
if (-not $all.Count) {
    if (-not $Json) { Write-Host "journey-gate: в config/journeys.json нет ни одного сценария." -ForegroundColor Red }
    Out-Result 'fail' 'реестр пуст' @() 1
}

$isPlanned = { param($j) ([string]$j.status) -eq 'planned' }
$planned = @($all | Where-Object { & $isPlanned $_ })
$required = @($all | Where-Object { -not (& $isPlanned $_) })

$selected = if ($Only) { @($all | Where-Object { $_.id -eq $Only }) } else { $required }
if ($Only -and -not $selected.Count) {
    if (-not $Json) { Write-Host "journey-gate: сценарий '$Only' в реестре не найден." -ForegroundColor Red }
    Out-Result 'fail' "сценарий '$Only' не найден" @() 1
}
if (-not $Only -and -not $required.Count) {
    if (-not $Json) {
        Write-Host "journey-gate: все $($all.Count) сценариев в статусе planned — ни один путь ещё не доказан." -ForegroundColor Yellow
        foreach ($p in $planned) { Write-Host "  · $($p.id) — $($p.title)" -ForegroundColor Yellow }
    }
    Out-Result 'not-configured' "все сценарии в статусе planned ($($all.Count))" @() 3
}

if ($ListOnly) {
    foreach ($j in $selected) { Write-Host ("{0,-28} {1}" -f $j.id, $j.title) }
    Out-Result 'ok' 'список' @($selected | ForEach-Object { @{ id = $_.id; status = 'listed' } }) 0
}

# --- 1. Доказательства на месте -------------------------------------------------------
# Сценарий без файла — намерение, а не проверка. Отдельная ступень, потому что дальше
# прогон такого сценария просто «ничего не нашёл» и завершился бы нулём.
$results = @()
$missing = @()
foreach ($j in $selected) {
    $proof = [string]$j.proof
    $exists = $proof -and (Test-Path -LiteralPath (Join-Path $root ($proof -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $exists) { $missing += $j.id }
    $results += [ordered]@{ id = $j.id; title = [string]$j.title; proof = $proof
                            status = $(if ($exists) { 'pending' } else { 'missing-proof' }) }
}

if ($missing.Count) {
    if (-not $Json) {
        Write-Host "journey-gate: у $($missing.Count) сценариев нет файла-доказательства:" -ForegroundColor Red
        foreach ($id in $missing) {
            $p = ($selected | Where-Object { $_.id -eq $id } | Select-Object -First 1).proof
            Write-Host "  $id -> $p" -ForegroundColor Red
        }
        Write-Host "Объявленный, но не доказанный сценарий хуже отсутствующего: он выглядит покрытым." -ForegroundColor Red
    }
    Out-Result 'fail' "нет доказательств: $($missing -join ', ')" $results 1
}

# --- 2. Прогон ------------------------------------------------------------------------
$cmd = if ($reg.command) { [string]$reg.command } else { '' }
if (-not $cmd) {
    $cfgFile = Join-Path $root 'config\harness.json'
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $hc = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($hc.tests.command) { $cmd = [string]$hc.tests.command }
        } catch { }
    }
}
if (-not $cmd) {
    if (-not $Json) {
        Write-Host "journey-gate: нечем прогонять сценарии — задай journeys.command в config/journeys.json." -ForegroundColor Red
    }
    Out-Result 'fail' 'journeys.command не задан' $results 1
}

# Команда для ОДНОГО сценария. Нужна там, где важно не «всё зелено», а «какой именно
# путь красный»: гейт слияния сравнивает множество зелёных путей до и после, и без
# поштучной атрибуции он не отличит поломку от чужого предсуществующего долга.
# {id} подставляется.
#
# ФОЛБЭК СУЖЕН ДО ТОГО, ГДЕ ОН ВЕРЕН. Раньше при пустом commandOne команда собиралась
# как «общая команда + флаг -t <id>». Флаг -t понимают vitest и jest, и больше никто:
# Maven, pytest, cargo и go на нём валятся разбором аргументов, а гейт истолковывал это
# как «сценарий красный». Проект узнавал не о том, что у него нет команды поштучного
# прогона, а о том, что у него якобы сломан сквозной путь — и чинил не то.
$cmdOne = if ($reg.commandOne) { [string]$reg.commandOne } else { '' }
$cmdOneFallbackOk = ($cmd -match '(?i)(^|[\\/\s])(vitest|jest)([\s"'']|$)')
$cmdOneRefusal = "journeys.commandOne не задан, а общая команда — не vitest и не jest (`$cmd`). Флаг -t, из которого собирался фолбэк, понимают только они: Maven, pytest, cargo и go на нём падают разбором аргументов, и гейт назвал бы это «сценарий красный». Задай commandOne с подстановкой {id}, например `.\mvnw.cmd -B verify -Dit.test={id}`."

# Возвращает Code/Out, либо Refused=$true, если поштучный прогон собрать нечем.
# Отказ вслух вместо заведомо неверной команды: неверная команда даёт красный сценарий
# и посылает чинить продукт вместо конфига.
function Invoke-One([string]$id) {
    if (-not $cmdOne -and -not $cmdOneFallbackOk) { return @{ Refused = $true; Code = 2; Out = '' } }
    $c = if ($cmdOne) { $cmdOne -replace '\{id\}', $id } else { "$cmd -t `"$id`"" }
    $o = (& pwsh -NoProfile -NonInteractive -Command $c 2>&1 | Out-String)
    return @{ Refused = $false; Code = $LASTEXITCODE; Out = $o }
}

if ($Only) {
    # Одиночный прогон: вопрос «работает ли ИМЕННО этот путь», а не «всё ли зелено».
    $r1 = Invoke-One $Only
    if ($r1.Refused) {
        if (-not $Json) { Write-Host "journey-gate: $cmdOneRefusal" -ForegroundColor Red }
        foreach ($r in $results) { $r.status = 'no-command' }
        Out-Result 'fail' $cmdOneRefusal $results 1
    }
    $ran = ($r1.Out -match [regex]::Escape($Only))
    $ok  = ($r1.Code -eq 0) -and $ran
    foreach ($r in $results) { $r.status = $(if ($ok) { 'ok' } elseif ($ran) { 'red' } else { 'silent' }) }
    if (-not $Json) {
        if ($ok) { Write-Host "OK: сценарий '$Only' зелёный." -ForegroundColor Green }
        elseif (-not $ran) { Write-Host "ПРОВАЛ: сценарий '$Only' не прогонялся (нулевой код при нуле тестов ничего не доказывает)." -ForegroundColor Red }
        else { Write-Host "ПРОВАЛ: сценарий '$Only' красный (exit=$($r1.Code))." -ForegroundColor Red
               Write-Host ((($r1.Out -split "`r?`n") | Select-Object -Last 25) -join "`n") }
    }
    Out-Result $(if ($ok) { 'ok' } else { 'fail' }) "сценарий '$Only': $(if ($ok) { 'зелёный' } else { 'красный' })" $results $(if ($ok) { 0 } else { 1 })
}

if (-not $Json) { Write-Host "journey-gate: $cmd" }
$out  = (& pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String)
$code = $LASTEXITCODE

# --- 3. Каждый сценарий отметился в выводе --------------------------------------------
# Именно здесь ловится тихий ноль: exit 0 при нулевом числе прогнанных тестов.
$silent = @()
foreach ($r in $results) {
    if ($out -match [regex]::Escape($r.id)) { $r.status = 'ran' }
    else { $r.status = 'silent'; $silent += $r.id }
}

$runFailed = ($code -ne 0)
foreach ($r in $results) { if ($r.status -eq 'ran' -and -not $runFailed) { $r.status = 'ok' } }

# ПОШТУЧНАЯ АТРИБУЦИЯ ПРИ КРАСНОМ ПРОГОНЕ.
#
# Совокупный код ничего не говорит о том, КАКОЙ путь сломался. Вызывающему это нужно:
# гейт слияния сравнивает множества зелёных путей до и после и без атрибуции считал бы
# «красным всё» — то есть не отличал бы поломку от чужого долга и не блокировал бы
# вообще ничего. Доплачиваем прогоном на путь только когда общий прогон уже красный.
$attributionRefused = $false
if ($runFailed -and $Json) {
    foreach ($r in $results) {
        if ($r.status -eq 'silent') { continue }
        $one = Invoke-One $r.id
        if ($one.Refused) { $attributionRefused = $true; $r.status = 'no-command'; continue }
        $r.status = if (($one.Code -eq 0) -and ($one.Out -match [regex]::Escape($r.id))) { 'ok' } else { 'red' }
    }
}

$tail = (($out -split "`r?`n") | Select-Object -Last 30) -join "`n"

if ($runFailed -or $silent.Count) {
    if (-not $Json) {
        if ($runFailed) {
            Write-Host "ПРОВАЛ: прогон сценариев завершился кодом $code — сквозной путь сломан." -ForegroundColor Red
            if (-not $cmdOne -and -not $cmdOneFallbackOk) {
                Write-Host "Какой именно путь красный — не установлено: $cmdOneRefusal" -ForegroundColor Red
            }
        }
        if ($silent.Count) {
            Write-Host "ПРОВАЛ: сценарии объявлены, но в выводе прогона не встретились: $($silent -join ', ')" -ForegroundColor Red
            Write-Host "Нулевой код при нуле прогнанных тестов — обычное поведение раннера, а не доказательство." -ForegroundColor Red
        }
        Write-Host $tail
    }
    $why = @()
    if ($runFailed) { $why += "прогон упал (exit $code)" }
    if ($silent.Count) { $why += "не прогнаны: $($silent -join ', ')" }
    if ($attributionRefused) { $why += "поштучная атрибуция не сделана: $cmdOneRefusal" }
    Out-Result 'fail' ($why -join '; ') $results 1
}

if (-not $Json) {
    Write-Host "OK: сквозных сценариев зелёных — $($results.Count) из $($all.Count) заявленных в реестре." -ForegroundColor Green
    foreach ($r in $results) { Write-Host ("  ✓ {0,-28} {1}" -f $r.id, $r.title) -ForegroundColor Green }
    if ($planned.Count) {
        Write-Host "Ещё не доказано (status: planned) — $($planned.Count):" -ForegroundColor Yellow
        foreach ($p in $planned) { Write-Host ("  · {0,-28} {1}" -f $p.id, $p.title) -ForegroundColor Yellow }
        Write-Host "Пока они planned, «продукт готов» сказать нельзя — доказана только часть путей." -ForegroundColor Yellow
    }
}
# Зелёный ответ отдаётся ТОЛЬКО когда объявленных-но-не-доказанных путей не осталось.
# Иначе `run-all` получил бы 'ok' и напечатал COMPLETE, имея пять ненаписанных сценариев —
# то есть ровно тот отчёт, из-за которого весь этот гейт и появился.
if ($planned.Count) {
    Out-Result 'partial' "зелёных: $($results.Count), ещё не доказано (planned): $($planned.Count) — $(@($planned | ForEach-Object { $_.id }) -join ', ')" $results 4
}
Out-Result 'ok' "зелёных сценариев: $($results.Count)" $results 0
