# graph.ps1 — запуск графа агентов.
#
#   pwsh harness/graph.ps1 -List                              что вообще есть
#   pwsh harness/graph.ps1 queue -DryPlan                     план без единого запуска
#   pwsh harness/graph.ps1 queue                              боевой прогон
#   pwsh harness/graph.ps1 queue -ArgsJson '["TASK-06"]'      вход графа (JSON → $GraphArgs)
#   pwsh harness/graph.ps1 -Runs                              журналы прошлых прогонов
#   pwsh harness/graph.ps1 queue -ResumeFromRunId g_2026…     доиграть остановленный
#
# СКРИПТ ГРАФА — обычный .ps1 из harness/graphs/, устроенный так:
#
#     $Meta = @{ name = '…'; description = '…'; phases = @(@{ title = '…'; detail = '…' }) }
#     if ($GraphMetaOnly) { return }
#     … тело: Set-Phase / Invoke-Node / Invoke-Pipeline / Invoke-Barrier …
#
# Разделение на «мету» и «тело» нужно ровно для одного: показать состав фаз ДО того,
# как что-то запустится. Прогон роя стоит денег, и решение «запускать ли» принимается
# по списку фаз, а не по факту уже потраченного бюджета.

param(
    [Parameter(Position = 0)][string]$Graph = '',
    # JSON. Разобранное значение попадает в скрипт графа как $GraphArgs.
    # ИМЯ ПАРАМЕТРА НАМЕРЕННО ДРУГОЕ: параметр типизирован строкой, и присваивание
    # разобранного объекта той же переменной молча приводило его обратно к строке —
    # граф получал "@{base=HEAD~6}" вместо объекта, а .base становился пустым.
    [string]$ArgsJson = '',
    [switch]$DryPlan,                 # ничего не запускать, только показать состав узлов
    [switch]$List,
    [switch]$Runs,
    [switch]$Doctor,                  # проверить бэкенды живьём: бинарь, авторизация, разбор ответа
    [string]$Board = '',              # показать доску прошлого прогона: runId или 'last'
    [string]$ResumeFromRunId = '',
    [int]$Concurrency = 0,
    [double]$Budget = 0,              # потолок токенов на прогон; 0 = без потолка
    [switch]$Yes                      # не спрашивать подтверждения,
  [string]$ProjectRoot = '',        # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    chcp 65001 | Out-Null
} catch { }

$graphsDir = Join-Path $PSScriptRoot 'graphs'

function Get-GraphMeta([string]$Path) {
    $GraphMetaOnly = $true
    $Meta = $null
    try { . $Path } catch { return $null }
    return $Meta
}

# --- Что есть ---
if ($List) {
    Write-Host "`nГрафы в harness/graphs/:`n" -ForegroundColor Cyan
    $any = $false
    foreach ($f in (Get-ChildItem $graphsDir -Filter '*.graph.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $m = Get-GraphMeta $f.FullName
        $name = if ($m -and $m.name) { $m.name } else { ($f.BaseName -replace '\.graph$', '') }
        Write-Host ("  {0,-16} {1}" -f $name, $(if ($m) { $m.description } else { '(мета не читается)' }))
        if ($m -and $m.phases) {
            foreach ($p in @($m.phases)) { Write-Host ("      фаза: {0,-16} {1}" -f $p.title, $p.detail) -ForegroundColor DarkGray }
        }
        $any = $true
    }
    if (-not $any) { Write-Host "  (пусто)" -ForegroundColor DarkGray }
    Write-Host ""
    exit 0
}

# --- Прошлые прогоны ---
if ($Runs) {
    $dir = Join-Path $PSScriptRoot '.graph'
    Write-Host "`nПрогоны графов:`n" -ForegroundColor Cyan
    $found = $false
    foreach ($d in (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $j = Join-Path $d.FullName 'journal.jsonl'
        if (-not (Test-Path $j)) { continue }
        $found = $true
        $starts = 0; $fins = 0; $fails = 0; $tok = 0; $name = ''; $done = $false
        foreach ($line in (Get-Content -LiteralPath $j -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            try { $r = $line | ConvertFrom-Json } catch { continue }
            switch ([string]$r.event) {
                'run-start'   { $name = [string]$r.name }
                'node-start'  { $starts++ }
                'node-finish' { $fins++; if (-not $r.ok) { $fails++ }; if ($r.tokens) { $tok += [double]$r.tokens } }
                'run-finish'  { $done = $true }
            }
        }
        $state = if ($done) { 'завершён' } else { 'ОБОРВАН' }
        Write-Host ("  {0}  {1,-14} узлов {2,-4} провал {3,-3} ток. {4,-8} {5}" -f $d.Name, $name, $starts, $fails, [int]$tok, $state) `
            -ForegroundColor $(if ($done -and $fails -eq 0) { 'Green' } elseif ($done) { 'Yellow' } else { 'DarkYellow' })
    }
    if (-not $found) { Write-Host "  (пусто)" -ForegroundColor DarkGray }
    Write-Host "`nДоиграть оборванный:  pwsh harness/graph.ps1 <граф> -ResumeFromRunId <id>`n"
    exit 0
}

# --- Доска завершённого прогона ---
#
# Тот же кадр, что рисуется вживую, но по журналу прошлого прогона. Нужен для разбора:
# «какие узлы упали и на чём» читается с доски за секунду, а из journal.jsonl — нет.
if ($Board) {
    . (Join-Path $PSScriptRoot 'lib\agent-sandbox.ps1')
    . (Join-Path $PSScriptRoot 'lib\fleet.ps1')
    . (Join-Path $PSScriptRoot 'lib\worktree.ps1')
    . (Join-Path $PSScriptRoot 'lib\graph-runtime.ps1')
    . (Join-Path $PSScriptRoot 'lib\graph-memory.ps1')

    $graphRoot = Join-Path $root '.bcf\graph'
    $runId = $Board
    if ($Board -eq 'last') {
        $last = Get-ChildItem $graphRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'journal.jsonl') } |
                Sort-Object LastWriteTime | Select-Object -Last 1
        if (-not $last) { Write-Host "Прогонов графа ещё не было." -ForegroundColor Yellow; exit 2 }
        $runId = $last.Name
    }
    $jf = Join-Path $graphRoot "$runId\journal.jsonl"
    if (-not (Test-Path $jf)) { Write-Host "Нет журнала прогона '$runId'." -ForegroundColor Red; exit 2 }

    # Мета берём из журнала, чтобы не гадать, какой граф это был.
    $nm = 'graph'; $started = (Get-Item $jf).CreationTime
    foreach ($l in (Get-Content -LiteralPath $jf -Encoding UTF8)) {
        if ($l -match '"event":"run-start"') { try { $o = $l | ConvertFrom-Json; if ($o.name) { $nm = $o.name }; if ($o.ts) { $started = [datetime]$o.ts } } catch { } ; break }
    }
    Initialize-GraphRun -Root $root -Meta @{ name = $nm; description = '' } -RunId $runId -MaxConcurrency 1 | Out-Null
    $script:GraphCtx.Journal = $jf
    $script:GraphCtx.StartedAt = $started

    Write-Host ""
    foreach ($l in (Get-GraphBoardLines -Final)) { Write-Host ([string]$l.t) -ForegroundColor $l.c }
    Write-Host ""
    Write-Host "  журнал: .bcf/graph/$runId/journal.jsonl" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# --- Проверка проводки бэкендов ---
#
# Отдельная команда нужна потому, что дефекты этого слоя МОЛЧАЛИВЫ: бэкенд без
# авторизации отвечает штатным событием, а не падением, и без разбора это выглядит как
# пустой ответ модели. Ловится это только настоящим запуском — поэтому здесь он и есть,
# на тривиальном промпте, до того как от бэкенда начнёт зависеть боевой прогон.
if ($Doctor) {
    . (Join-Path $PSScriptRoot 'lib\agent-sandbox.ps1')
    . (Join-Path $PSScriptRoot 'lib\fleet.ps1')
    . (Join-Path $PSScriptRoot 'lib\worktree.ps1')
    . (Join-Path $PSScriptRoot 'lib\graph-runtime.ps1')
    . (Join-Path $PSScriptRoot 'lib\graph-memory.ps1')

    $ctx = Initialize-GraphRun -Root $root -Meta @{ name = 'doctor'; description = 'проверка бэкендов' } -MaxConcurrency 1
    Write-Host "`nБэкенды графа:`n" -ForegroundColor Cyan

    $probeDir = Join-Path $ctx.Dir 'probe'
    New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
    $bad = 0
    foreach ($name in @($ctx.Backends.Keys | Sort-Object)) {
        $b = $ctx.Backends[$name]
        $usedBy = @($ctx.Roles.Keys | Where-Object { $ctx.Roles[$_].Backend -eq $name } | Sort-Object)
        $roleTxt = if ($usedBy.Count) { "роли: $($usedBy -join ', ')" } else { 'ролей нет' }

        # Бинарь: первое слово команды, либо путь в кавычках после '&'.
        $exe = if ($b.Command -match "^&\s*'([^']+)'") { $Matches[1] } else { ($b.Command -split '\s+')[0] }
        $found = (Test-Path -LiteralPath $exe) -or [bool](Get-Command $exe -ErrorAction SilentlyContinue)
        if (-not $found) {
            Write-Host ("  {0,-10} ✗ бинарь не найден: {1}   ({2})" -f $name, $exe, $roleTxt) -ForegroundColor Red
            if ($usedBy.Count) { $bad++ }
            continue
        }

        # Сначала — бесплатная проверка авторизации, если бэкенд её умеет. Гонять
        # пробный запрос в незалогиненную CLI значит платить за то, что можно спросить.
        if ($b.AuthCheck) {
            # Проверке нужны те же переменные, что и самому бэкенду. Без этого она врала
            # ровно так же, как врал бы прогон: Windows не пробрасывает переменные в уже
            # запущенные процессы, и харнесс, стартовавший до `claude setup-token`,
            # видит «не авторизован» при полностью исправной учётке.
            $pre = ''
            foreach ($n in @($b.Env)) {
                if (-not $n) { continue }
                $v = [Environment]::GetEnvironmentVariable($n)
                if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'User') }
                if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'Machine') }
                if ($v) { $pre += "`$env:$n='$($v -replace "'", "''")';" }
            }
            $ao = (& pwsh -NoProfile -NonInteractive -Command "$pre $($b.AuthCheck)" 2>&1 | Out-String)
            if ($b.AuthOk -and $ao -notmatch $b.AuthOk) {
                # Вывод бывает многострочным JSON — первая строка тогда «{» и не говорит
                # ничего. Схлопываем в одну строку целиком.
                $why = (($ao -replace '\s+', ' ')).Trim()
                if ($why.Length -gt 120) { $why = $why.Substring(0, 120) + '…' }
                Write-Host ("  {0,-10} ✗ не авторизован — {1}   ({2})" -f $name, $why, $roleTxt) -ForegroundColor Red
                if ($usedBy.Count) { $bad++ }
                continue
            }
        }

        $model = ''
        foreach ($r in $usedBy) { if ($ctx.Roles[$r].Model) { $model = $ctx.Roles[$r].Model; break } }
        if (-not $model) { $model = $b.ProbeModel }
        if (-not $model) {
            Write-Host ("  {0,-10} · бинарь есть, {1} — проверить нечем (нет probeModel)" -f $name, $roleTxt) -ForegroundColor DarkGray
            continue
        }

        $res = _GraphRunAgent -Prompt 'Ответь ровно одним словом: PROBE_OK' -Model $model `
                    -Label "doctor-$name" -WorkDir $probeDir -TimeoutSec 180 -SilentSec 0 `
                    -CommandTpl $b.Command -Format $b.Format -RequiredEnv $b.Env
        if ($res.Ok -and $res.Text -match 'PROBE_OK') {
            Write-Host ("  {0,-10} ✓ {1} / {2}   ток. {3}   ({4})" -f $name, $b.Format, $model, [int]$res.Tokens, $roleTxt) -ForegroundColor Green
        } else {
            $why = if ($res.Reason) { $res.Reason } else { "неожиданный ответ: $(($res.Text -split "`n")[0])" }
            Write-Host ("  {0,-10} ✗ {1}   ({2})" -f $name, $why, $roleTxt) -ForegroundColor Red
            if ($usedBy.Count) { $bad++ }
        }
    }

    # --- Память ---
    #
    # Проверяем не «доступна ли», а ЧТО В НЕЙ ЛЕЖИТ. «Память активна» — бесполезный
    # признак: на прошлом прогоне она была активна и при этом содержала один-единственный
    # урок, который перечитывался 57 раз. Живое обучение — это рост чисел от прогона к
    # прогону, поэтому здесь печатаются сами числа.
    # Доктор не только сообщает о неготовности, но и ПОДНИМАЕТ окружение: смысл проверки
    # перед прогоном в том, чтобы после неё можно было запускаться, а не в том, чтобы
    # узнать диагноз и чинить руками то, что чинится само.
    Write-Host "Память:`n" -ForegroundColor Cyan
    . (Join-Path $PSScriptRoot 'lib\m13-bridge.ps1')
    try { Ensure-M13Memory | Out-Null } catch { }
    Test-GraphMemory -Recheck | Out-Null
    if (-not (Test-GraphMemory)) {
        Write-Host "  ✗ недоступна — уроки не отзываются и не пишутся (обучение выключено)" -ForegroundColor Red
        Write-Host "    поднять: docker compose -f memory/pgvector/docker-compose.yml up -d`n"
    } else {
        $st = Get-GraphMemoryStats
        if ($st) {
            $warn = ($st.AntiPatterns -le 1)
            Write-Host ("  ✓ доступна · уроков {0} · багов {1} · отзывов {2}" -f $st.AntiPatterns, $st.Bugs, $st.Recalls) `
                -ForegroundColor $(if ($warn) { 'Yellow' } else { 'Green' })
            if ($warn) {
                Write-Host "    ⚠ уроков почти нет: чтение работает, запись — нет. После прогона число обязано вырасти." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ✓ доступна (счётчики не прочитались)" -ForegroundColor Green
        }
        Write-Host ""
    }

    if ($bad) {
        Write-Host "  НЕ ГОТОВ: сломанных бэкендов с назначенными ролями — $bad. Граф на них упрётся." -ForegroundColor Red
        Write-Host "  Чинить в config/harness.json → graph.backends / graph.roles.`n"
        exit 1
    }
    Write-Host "  Все бэкенды с назначенными ролями отвечают.`n" -ForegroundColor Green
    exit 0
}

if (-not $Graph) {
    Write-Host "Укажи граф. Список: pwsh harness/graph.ps1 -List" -ForegroundColor Yellow
    exit 2
}

# --- Находим скрипт графа ---
$scriptPath = $null
foreach ($cand in @(
    $Graph,
    (Join-Path $graphsDir $Graph),
    (Join-Path $graphsDir "$Graph.graph.ps1")
)) {
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $scriptPath = (Resolve-Path $cand).Path; break }
}
if (-not $scriptPath) {
    Write-Host "Граф '$Graph' не найден. Список: pwsh harness/graph.ps1 -List" -ForegroundColor Red
    exit 2
}

$Meta = Get-GraphMeta $scriptPath
if (-not $Meta -or -not $Meta.name) {
    Write-Host "В '$scriptPath' нет валидного `$Meta (нужны как минимум name и description)." -ForegroundColor Red
    exit 2
}

# --- Карточка запуска: состав фаз ДО первого потраченного токена ---
Write-Host ""
Write-Host "  ГРАФ: $($Meta.name)" -ForegroundColor Cyan
Write-Host "  $($Meta.description)"
if ($Meta.phases) {
    Write-Host ""
    foreach ($p in @($Meta.phases)) { Write-Host ("    {0,-16} {1}" -f $p.title, $p.detail) -ForegroundColor Gray }
}
Write-Host ""
if ($DryPlan)         { Write-Host "  режим: СУХОЙ ПЛАН — ни один агент не запускается." -ForegroundColor Yellow }
if ($ResumeFromRunId) { Write-Host "  возобновление с прогона: $ResumeFromRunId" -ForegroundColor Yellow }
if ($Budget -gt 0)    { Write-Host "  потолок: $([int]$Budget) токенов" -ForegroundColor Yellow }
Write-Host ""

if (-not $Yes -and -not $DryPlan) {
    # Рой агентов тратит на порядок больше одного агента. Подтверждение здесь —
    # не формальность: это единственная точка, где решение ещё ничего не стоит.
    $ans = Read-Host "Запускать? [y/N]"
    if ($ans -notmatch '^(y|yes|д|да)$') { Write-Host "Отменено." -ForegroundColor DarkGray; exit 130 }
}

# --- Рантайм и его зависимости ---
. (Join-Path $PSScriptRoot 'lib\agent-sandbox.ps1')
. (Join-Path $PSScriptRoot 'lib\fleet.ps1')
. (Join-Path $PSScriptRoot 'lib\claims.ps1')
. (Join-Path $PSScriptRoot 'lib\worktree.ps1')
. (Join-Path $PSScriptRoot 'lib\graph-runtime.ps1')
    . (Join-Path $PSScriptRoot 'lib\graph-memory.ps1')

# --- ПРЕФЛАЙТ ОКРУЖЕНИЯ ---
#
# Граф зависит от внешнего софта, который сам себя не поднимает: демон Docker, контейнер
# pgvector, сервер LM Studio и загруженная в него модель эмбеддингов. Без них память
# недоступна, и прогон идёт БЕЗ уроков — молча теряя ровно то, ради чего память заводилась.
#
# Логика подъёма давно есть и проверена в loop.ps1 (Ensure-M13Memory: старт Docker Desktop,
# ожидание демона, docker start / compose up, ожидание healthy, затем lms server start и
# lms load модели). Граф её просто не звал — отсюда наблюдавшееся «память недоступна» при
# полностью исправной установке: узел работы поднимал память САМ, а узлы графа шли без неё.
#
# Префлайт НЕ блокирует прогон: память вспомогательна, и её отсутствие не повод не работать.
if (-not $DryPlan) {
    . (Join-Path $PSScriptRoot 'lib\m13-bridge.ps1')
    Write-Host "`n  окружение:" -ForegroundColor Cyan
    $memReady = $false
    try { $memReady = Ensure-M13Memory } catch { $memReady = $false }
    if (-not $memReady) {
        Write-Host "  ⚠ память не поднялась — прогон пойдёт БЕЗ уроков (обучение выключено)." -ForegroundColor Yellow
    }
}

$parsedArgs = $null
if ($ArgsJson) {
    try { $parsedArgs = $ArgsJson | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Host "-ArgsJson не разобрался как JSON: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
}
# Скрипт графа подключается точкой, то есть видит ЭТУ область. Переменная нетипизирована
# намеренно — она обязана донести до графа объект, а не его строковое представление.
$GraphArgs = $parsedArgs

$ctx = Initialize-GraphRun -Root $root -Meta $Meta -GraphArgs $parsedArgs `
    -ResumeFromRunId $ResumeFromRunId -MaxConcurrency $Concurrency -TokenBudget $Budget -DryPlan:$DryPlan

Write-Host "  runId: $($ctx.RunId)   параллельно до $($ctx.MaxConcurrency)" -ForegroundColor DarkGray

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$GraphMetaOnly = $false
$result = $null
$failed = $false
try {
    $result = . $scriptPath
} catch {
    $failed = $true
    Write-Host "`nГРАФ УПАЛ: $($_.Exception.Message)" -ForegroundColor Red
    Write-GraphLog "граф упал: $($_.Exception.Message)"
}
$sw.Stop()

Complete-GraphRun -Result $result | Out-Null

Write-Host ""
Write-Host ("  итог: {0}, за {1:mm\:ss}" -f $(if ($failed) { 'ПРОВАЛ' } else { 'ок' }), $sw.Elapsed) `
    -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
Write-Host "  журнал: .bcf/graph/$($ctx.RunId)/journal.jsonl"
Write-Host ""

if ($failed) { exit 1 }
exit 0

