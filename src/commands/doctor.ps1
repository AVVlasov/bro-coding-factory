# bcf doctor — живая проба окружения. Без работы, но с настоящими запросами.
#
#   bcf doctor              бэкенды + память + проверки проекта
#   bcf doctor --no-probe   без запросов к моделям (только бинари и авторизации)
#   bcf doctor --checks     ещё и прогнать backpressure проекта
#
# ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА. Дефекты проводки МОЛЧАЛИВЫ. Неавторизованный бэкенд отвечает
# штатным событием, а не падением: снаружи это выглядит как пустой ответ модели, и
# обвязка спокойно записывает «агент ничего не сделал». Поймать это можно только
# настоящим запуском — поэтому он здесь и есть, на тривиальном промпте, до того как от
# бэкенда начнёт зависеть боевой прогон.

. (Join-Path $BcfRoot 'src\lib\backends.ps1')
. (Join-Path $BcfRoot 'src\lib\detect.ps1')

$noProbe   = $script:BcfArgs -contains '--no-probe'
$runChecks = $script:BcfArgs -contains '--checks'
$project   = $script:BcfProject

Write-BcfTitle "ОКРУЖЕНИЕ  $(Split-Path $project -Leaf)" "фабрика v$(Get-BcfVersion) · $(Get-BcfHome)"

$bad = 0
$warn = 0

# --- Бэкенды --------------------------------------------------------------------------
Write-BcfLine '  БЭКЕНДЫ' 'White'
Write-Host ''

$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { Write-BcfWarn "config/harness.json: $($_.Exception.Message)" }

# Какие роли на каком бэкенде — определяет, что считать поломкой: сломанный бэкенд без
# ролей это факт, сломанный бэкенд С ролью это остановленный прогон.
$roleOf = @{}
if ($cfg -and $cfg.graph -and $cfg.graph.roles) {
    foreach ($p in $cfg.graph.roles.PSObject.Properties) {
        if ($p.Name -eq '$comment' -or -not $p.Value.backend) { continue }
        $b = [string]$p.Value.backend
        if (-not $roleOf.ContainsKey($b)) { $roleOf[$b] = @() }
        $roleOf[$b] += $p.Name
    }
}

$survey = Invoke-BcfBackendSurvey
foreach ($r in $survey) {
    $roles = @()
    foreach ($k in $roleOf.Keys) {
        if ($k -eq $r.Name -or (Get-BcfKnownBackends)[$k].aliasOf -eq $r.Name) { $roles += $roleOf[$k] }
    }
    $roleTxt = if ($roles.Count) { "роли: $($roles -join ', ')" } else { 'ролей нет' }

    if (-not $r.Installed) {
        Write-BcfDim ("{0,-11} не установлен   ({1})" -f $r.Name, $roleTxt)
        if ($roles.Count) { $bad++ }
        continue
    }
    if (-not $r.AuthOk) {
        Write-BcfFail ("{0,-11} НЕ АВТОРИЗОВАН   ({1})" -f $r.Name, $roleTxt)
        if ($r.AuthDetail) { Write-BcfNote $r.AuthDetail }
        if ($roles.Count) { $bad++ } else { $warn++ }
        continue
    }
    $ver = if ($r.Version) { "v$($r.Version)" } else { '' }
    Write-BcfOk ("{0,-11} {1,-9} {2,-13} ({3})" -f $r.Name, $ver, $r.Auth, $roleTxt)
    if (-not $r.OnPath) {
        Write-BcfNote "не на PATH, найден по пути: $($r.Path)"
        Write-BcfNote 'путь содержит версию сборки и меняется после обновления приложения — перепроверь после апдейта.'
        $warn++
    }
    if (-not $r.Tokens -and $roles.Count) {
        Write-BcfLine "     ⚠ расход токенов в потоке не виден — бюджетный ограничитель на ролях $($roles -join ', ') слеп" 'Yellow'
        $warn++
    }
}

# --- Живая проба ролей ----------------------------------------------------------------
#
# Здесь и только здесь тратятся токены. Один короткий запрос на роль: этого достаточно,
# чтобы отличить «CLI отвечает» от «модель отвечает и её ответ разбирается».
if (-not $noProbe -and $roleOf.Count) {
    Write-Host ''
    Write-BcfLine '  ЖИВАЯ ПРОБА РОЛЕЙ' 'White'
    Write-BcfNote 'по одному короткому запросу на роль — единственное место, где doctor тратит токены'
    Write-Host ''

    $graphPs1 = Join-Path (Get-BcfHarness) 'graph.ps1'
    $out = & pwsh -NoProfile -File $graphPs1 -Doctor -ProjectRoot $project 2>&1 | Out-String
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { Write-Host $line }
    }
    if ($LASTEXITCODE -ne 0) { $bad++ }
} elseif ($noProbe) {
    Write-Host ''
    Write-BcfDim 'живая проба пропущена (--no-probe): «бинарь есть» ещё не значит «модель отвечает».'
} elseif (-not $roleOf.Count) {
    Write-Host ''
    Write-BcfWarn 'роли графа не назначены — пробовать нечего. Назначить: bcf init'
    $warn++
}

# --- Память ---------------------------------------------------------------------------
#
# Проверяем не «доступна ли», а ЧТО В НЕЙ ЛЕЖИТ. «Память активна» — бесполезный признак:
# она бывает активна и при этом содержит один-единственный урок, который перечитывается
# полсотни раз. Живое обучение — это рост чисел от прогона к прогону.
Write-Host ''
Write-BcfLine '  ПАМЯТЬ' 'White'
Write-Host ''

$memClient = Join-Path (Get-BcfMemoryDir) 'pgvector\memory_client.py'
$memOn = $cfg -and $cfg.features -and $cfg.features.memory
if (-not (Test-Path $memClient)) {
    Write-BcfWarn "клиент памяти не найден: $memClient"
    $warn++
} elseif (-not $memOn) {
    Write-BcfDim 'выключена в config/harness.json → features.memory'
    Write-BcfNote 'без неё прогоны не учатся на прошлых ошибках: один и тот же провал повторяется каждый прогон.'
} else {
    $stats = ''
    try { $stats = (& python $memClient stats 2>&1 | Out-String).Trim() } catch { $stats = '' }
    if ($stats -match '\{') {
        try {
            $j = $stats | ConvertFrom-Json
            $ap = [int]$j.anti_patterns; $bg = [int]$j.bugs; $rc = [int]$j.recalls
            $col = if ($ap -le 1) { 'Yellow' } else { 'Green' }
            Write-BcfLine ("  ✓ доступна · уроков {0} · багов {1} · отзывов {2}" -f $ap, $bg, $rc) $col
            if ($ap -le 1) {
                Write-BcfLine '    ⚠ уроков почти нет: чтение работает, запись — нет. После прогона число обязано вырасти.' 'Yellow'
                $warn++
            }
        } catch { Write-BcfOk 'доступна (счётчики не разобрались)' }
    } else {
        Write-BcfFail 'недоступна — уроки не отзываются и не пишутся, обучение выключено'
        Write-BcfNote 'поднять: bcf memory init'
        $warn++
    }
}

# --- Проверки проекта -----------------------------------------------------------------
Write-Host ''
Write-BcfLine '  ПРОВЕРКИ ПРОЕКТА' 'White'
Write-Host ''

$bp = @()
if ($cfg -and $cfg.backpressure -and $cfg.backpressure.typecheck) { $bp = @($cfg.backpressure.typecheck | Where-Object { $_ }) }
if (-not $bp.Count) {
    Write-BcfWarn 'backpressure.typecheck пуст — ошибки компиляции всплывут только на верификации'
    $warn++
} elseif ($runChecks) {
    foreach ($c in $bp) {
        $r = Test-BcfCommand -Command $c -Root $project -TimeoutSec 300
        if ($r.Ok) { Write-BcfOk ("{0}   {1}s" -f $c, $r.Seconds) }
        else {
            Write-BcfFail ("{0}   exit {1}" -f $c, $r.ExitCode)
            Write-BcfNote ($r.Output -replace "`n", "`n    ")
            $bad++
        }
    }
} else {
    foreach ($c in $bp) { Write-BcfDim "$c   (не запускалась — bcf doctor --checks)" }
}

$testsRunner = if ($cfg -and $cfg.tests) { [string]$cfg.tests.runner } else { '' }
if (-not $testsRunner) {
    Write-BcfWarn 'tests.runner не задан — гейт «фича доказана тестами» не работает'
    $warn++
} else {
    Write-BcfOk "раннер тестов: $testsRunner"
}

$checksFile = Join-Path $project 'config\checks.json'
if (Test-Path $checksFile) {
    try {
        $cj = Get-Content -Raw -LiteralPath $checksFile | ConvertFrom-Json
        $def = @($cj._default | Where-Object { $_ -is [string] -and $_.Trim() })
        if (-not $def.Count) {
            Write-BcfWarn 'config/checks.json → _default пуст: задача без собственных проверок может получить PASS на одном судье'
            $warn++
        } else { Write-BcfOk "обязательных проверок по умолчанию: $($def.Count)" }
    } catch { Write-BcfFail "config/checks.json не разобран: $($_.Exception.Message)"; $bad++ }
} else {
    Write-BcfWarn 'config/checks.json нет — вердикт не на чем строить (bcf install)'
    $warn++
}

# --- Итог -----------------------------------------------------------------------------
Write-Host ''
if ($bad) {
    Write-BcfLine "  НЕ ГОТОВ: блокирующих проблем — $bad, предупреждений — $warn." 'Red'
    Write-BcfNote 'Прогон упрётся в перечисленное выше. Чинить сверху вниз.'
    Write-Host ''
    exit 1
}
if ($warn) {
    Write-BcfLine "  ГОТОВ С ОГОВОРКАМИ: предупреждений — $warn." 'Yellow'
    Write-BcfNote 'Прогон поедет, но часть гарантий не работает — см. выше.'
    Write-Host ''
    exit 0
}
Write-BcfLine '  ГОТОВ: все роли отвечают, гейты на месте.' 'Green'
Write-Host ''
exit 0
