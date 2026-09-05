# harness/run-all.ps1 — ОВЕРНАЙТ-оркестратор: прогоняет ВСЕ задачи подряд, автономно.
#
# Для каждой задачи в числовом порядке: если уже verdict: PASS — пропуск; иначе запускает
# обычный однозадачный loop.ps1 <task> -AutoAdvance (синхронно, в этом же окне). После выхода
# проверяет вердикт: PASS → следующая; не-PASS (затык/гейт/лимит) → ЗАПИСЫВАЕТ и идёт дальше
# (ночью не блокируемся на одной задаче). Гейты зависимостей соблюдаются самим loop.ps1
# (если предшественник не PASS — задача-наследник заблокируется и попадёт в «не сделано»).
#
# Подавляет per-task попапы Windows (в loop.ps1 через -AutoAdvance); в конце — ОДИН итоговый
# REVIEW.md, машиночитаемый run-all.status.json, код возврата и короткий звук. Модальных
# окон не показывает: окно держит процесс до нажатия ОК, то есть прогон по расписанию не
# заканчивается, а висит.
#
# Модель и task-id префикс берутся из config/harness.json (models.code, taskIdPrefix) —
# не хардкодятся. loop.ps1 запускается через $PSScriptRoot.
#
# Запуск: pwsh harness/run-all.ps1   (обычно через harness/start.ps1 без аргумента → start.ps1)
#   pwsh harness/run-all.ps1 -PerTaskMax 30
# Досрочно остановить — создать файл .bcf/STOP (проверяется между задачами).

param(
  [int]$PerTaskMax = 40,                                  # потолок итераций НА ОДНУ задачу
  [string]$Model = "",                                    # пусто → из config/harness.json (models.code)
  [switch]$NoAutoRollback,
  [int]$TaskConcurrency = 0,                              # 0 → из config; 1 = последовательно (старое поведение)
  [switch]$DryPlan,                                       # только показать план параллелизма, ничего не запускать
  [string]$ProjectRoot = ''                               # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root     = Get-BcfProjectRoot -Explicit $ProjectRoot
$stateDir = Get-BcfStateDir $root
$loopPs1  = Join-Path $PSScriptRoot "loop.ps1"
$logFile  = Join-Path $stateDir "loop.log"
$stopFile = Join-Path $stateDir "STOP"
$reviewFile = Join-Path $stateDir "REVIEW.md"
Set-Location $root

# --- Config (config/harness.json): code-agent model + task-id префикс ---
$harnessCfg = $null
$cfgFile = Join-Path $root 'config\harness.json'
if (Test-Path $cfgFile) {
  try { $harnessCfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json } catch { $harnessCfg = $null }
}
if (-not $Model -and $harnessCfg -and $harnessCfg.models -and $harnessCfg.models.code) {
  $Model = [string]$harnessCfg.models.code
}
$taskIdPrefix = if ($harnessCfg -and $harnessCfg.taskIdPrefix) { [string]$harnessCfg.taskIdPrefix } else { 'TASK' }
$modelLabel   = if ($Model) { $Model } else { '(backend default)' }

try {
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding           = [System.Text.Encoding]::UTF8
  chcp 65001 | Out-Null
} catch { }

function Log($msg) {
  $line = "[{0}] [run-all] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Write-Host $line -ForegroundColor Cyan
  Add-Content -Path $logFile -Value $line
}

function Verdict-Pass($t, $atRoot) {
  # $atRoot — корень, где искать вердикт. У параллельной задачи это её worktree:
  # loop.ps1 внутри worktree пишет вердикт туда, а не в основное дерево.
  $base = if ($atRoot) { $atRoot } else { $root }
  $vf = Join-Path $base "tasks\.verdicts\$t.md"
  if (!(Test-Path $vf)) { return $false }
  return [bool](Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
}

# Предшественники разбирает ОДНА функция на весь проект (harness/lib/claims.ps1).
# Второй разборщик рядом означает, что однажды они разойдутся — и разойдутся молча:
# каждый по отдельности работает, а увидеть расхождение можно только сверив вывод с
# вердиктами руками.
. (Join-Path $PSScriptRoot 'lib\claims.ps1')
$predRegex = [regex]::Escape($taskIdPrefix) + '-\d+'
function Get-GatePreds($t) {
  return @(Get-TaskPredecessors -TaskId $t -Root $root -Prefix $taskIdPrefix)
}

# --- Транзитивное сведе́ние каскад-гейта к КОРНЮ (задаче, которая реально требует человека).
# Причина gate-block содержит «предшественник <PREFIX>-NN …». Идём по цепочке причин, пока не
# упрёмся в задачу, чья причина НЕ начинается с «gate-block» — это и есть корневой блокер. ---
function Resolve-Root([string]$task, [hashtable]$map) {
  $seen = @{}; $cur = $task
  while ($true) {
    if ($seen.ContainsKey($cur)) { return $cur }   # защита от цикла
    $seen[$cur] = $true
    $r = $map[$cur]
    if (-not $r -or ($r -notlike 'gate-block*')) { return $cur }
    $mm = [regex]::Match($r, $predRegex)
    if (-not $mm.Success) { return $cur }
    $cur = $mm.Value
  }
}

# --- ЕДИНЫЙ ЧЕСТНЫЙ ИТОГ.
#
# Зачем: раньше прогон всегда заканчивался попапом «готово» и exit 0 — даже когда закрыто
# 13 задач из 19. И человек, и вызывающий агент принимали неполный прогон за успешный.
# Теперь «готово» звучит ТОЛЬКО при полностью закрытой очереди, иначе INCOMPLETE + exit 1.
#
# Незакрытые категоризируются: «требуют человека» (сама задача застряла/упала) vs
# «каскад-гейт» (заблокирована незакрытым предшественником) — чинить надо корни, а не список.
#
# Пишет REVIEW.md + run-all.status.json (+ harvest), возвращает объект статуса.
# НЕ показывает попап и НЕ делает exit — это делает вызывающий код, чтобы функцию
# можно было прогнать headless в тесте:
#   $env:BCF_REPORT_LIB_ONLY=1 ; . harness/run-all.ps1 ; Emit-RunAllReport ... ---
function Emit-RunAllReport {
  # $StatusFile переопределяется ради сухих прогонов: у них «не закрыто» — артефакт
  # режима, а не факт, и записывать его в боевой статус нельзя.
  param([array]$Passed, [array]$Stuck, [int]$Total, [string]$Root, [string]$ReviewFile, [string]$Ts,
        [string]$StatusFile = '',
        # Число P1, найденных приёмкой на слитом дереве. Граф уже их считает, а отчёт о
        # них не знал: круг приёмки печатал «COMPLETE» и следом список из трёх P1.
        # Находка уровня «пользователь видит неверные данные» — это не примечание к
        # готовности, это её отсутствие.
        [int]$AcceptanceP1 = 0)

  $gateBlocked = @($Stuck | Where-Object { $_.Reason -like 'gate-block*' })
  $needsHuman  = @($Stuck | Where-Object { $_.Reason -notlike 'gate-block*' })
  $queueClosed = (@($Stuck).Count -eq 0)

  # СКВОЗНЫЕ СЦЕНАРИИ — условие уровня ПРОДУКТА, а не суммы задач.
  #
  # 2026-08-09, clinic-scheduler: этот отчёт напечатал «COMPLETE — все 35 задач закрыты
  # (PASS)» ровно в тот момент, когда в продукте не работал ни один клиентский путь.
  # Отчёт не соврал про задачи — он соврал тем, что молча приравнял закрытую очередь к
  # готовому продукту. Закрытая очередь означает только, что каждая задача доказала себя
  # своими тестами; она ничего не говорит о стыках между ними и об отсутствующих кусках.
  # Поэтому COMPLETE теперь требует ДВУХ условий, и каждое называется отдельно.
  $journeyState   = 'not-configured'
  $journeySummary = ''
  try {
    $jgScript = Join-Path $PSScriptRoot 'journey-gate.ps1'
    if (Test-Path -LiteralPath $jgScript) {
      $jgOut  = (& pwsh -NoProfile -NonInteractive -File $jgScript -ProjectRoot $Root -Json 2>&1 | Out-String)
      $jgCode = $LASTEXITCODE
      try {
        $jg = $jgOut | ConvertFrom-Json
        if ($jg.state) { $journeyState = [string]$jg.state }
        $journeySummary = [string]$jg.summary
      } catch {
        $journeyState = switch ($jgCode) { 0 { 'ok' } 3 { 'not-configured' } 4 { 'partial' } default { 'fail' } }
      }
    }
  } catch { $journeyState = 'unknown'; $journeySummary = $_.Exception.Message }

  $complete = $queueClosed -and ($journeyState -eq 'ok') -and ($AcceptanceP1 -eq 0)

  $reasonOf = @{}
  foreach ($s in $Stuck) { $reasonOf[$s.Task] = $s.Reason }
  $blocksByRoot = @{}
  foreach ($g in $gateBlocked) {
    $rt = Resolve-Root $g.Task $reasonOf
    if (-not $blocksByRoot.ContainsKey($rt)) { $blocksByRoot[$rt] = @() }
    $blocksByRoot[$rt] += $g.Task
  }

  # run-all.status.json — машиночитаемый сигнал для вызывающего агента/автоматизации.
  $statusObj = [ordered]@{
    complete       = $complete
    queue_closed   = $queueClosed
    journeys       = $journeyState
    acceptance_p1  = $AcceptanceP1
    when         = $Ts
    total        = $Total
    passed       = @($Passed).Count
    stuck        = @($Stuck).Count
    # @($hash[отсутствующий ключ]) даёт массив ИЗ ОДНОГО null, и в статусе появлялось
    # "blocks": [null] — то есть «блокирует 1» там, где не блокирует никого.
    needs_human  = @($needsHuman  | ForEach-Object { [ordered]@{ task = $_.Task; reason = $_.Reason; blocks = @(@($blocksByRoot[$_.Task]) | Where-Object { $_ }) } })
    gate_blocked = @($gateBlocked | ForEach-Object { [ordered]@{ task = $_.Task; reason = $_.Reason } })
  }
  $statusPath = if ($StatusFile) { $StatusFile } else { Join-Path $Root '.bcf\run-all.status.json' }
  try { ($statusObj | ConvertTo-Json -Depth 6) | Set-Content -Path $statusPath -Encoding UTF8 } catch { }

  # REVIEW.md.
  $passLines = if (@($Passed).Count) { (@($Passed) | ForEach-Object { "- $_" }) -join "`n" } else { "- (нет)" }
  $humanLines = if ($needsHuman.Count) {
    ($needsHuman | ForEach-Object {
      $b = @(@($blocksByRoot[$_.Task]) | Where-Object { $_ }); $suff = if ($b.Count) { " — блокирует $($b.Count): $($b -join ', ')" } else { "" }
      "- **$($_.Task)** — $($_.Reason)$suff"
    }) -join "`n"
  } else { "- (нет)" }
  $gateLines = if ($gateBlocked.Count) { ($gateBlocked | ForEach-Object { "- **$($_.Task)** — $($_.Reason)" }) -join "`n" } else { "- (нет)" }
  $statusLine = if ($complete) {
    "**Статус:** COMPLETE — все $Total задач закрыты (PASS) И сквозные сценарии продукта зелёные."
  } elseif ($queueClosed -and $journeyState -eq 'not-configured') {
    "**Статус:** ОЧЕРЕДЬ ЗАКРЫТА, ПРОДУКТ НЕ ПРОВЕРЕН — все $Total задач закрыты (PASS), " +
    "но сквозные сценарии не заведены (config/journeys.json). Это НЕ «готово»: закрытая очередь " +
    "означает, что каждая задача доказала себя своими тестами, и ничего не говорит о том, может ли " +
    "человек выполнить работу. Заведи реестр сценариев — иначе следующий такой отчёт снова будет " +
    "прочитан как «продукт готов»."
  } elseif ($queueClosed -and $journeyState -eq 'ok' -and $AcceptanceP1 -gt 0) {
    "**Статус:** ОЧЕРЕДЬ ЗАКРЫТА, ЕСТЬ P1 ПРИЁМКИ — все $Total задач закрыты (PASS) и сценарии зелёные, " +
    "но приёмка на слитом дереве нашла P1: $AcceptanceP1. P1 — это «пользователь видит неверные данные» " +
    "или «путь не проходится»; такие находки не бывают примечанием к готовности. НЕ принимать за «готово»."
  } elseif ($queueClosed -and $journeyState -eq 'partial') {
    "**Статус:** ОЧЕРЕДЬ ЗАКРЫТА, ПРОДУКТ ДОКАЗАН ЧАСТИЧНО — все $Total задач закрыты (PASS), " +
    "доказанные пути зелёные, но часть путей в config/journeys.json ещё объявлена planned " +
    "($journeySummary). Готовность продукта равна доле доказанных путей, а не доле закрытых задач."
  } elseif ($queueClosed) {
    "**Статус:** ОЧЕРЕДЬ ЗАКРЫТА, СЦЕНАРИИ КРАСНЫЕ — все $Total задач закрыты (PASS), но сквозные " +
    "сценарии продукта не проходят ($journeySummary). Пользоваться продуктом нельзя. НЕ принимать за «готово»."
  } else {
    "**Статус:** INCOMPLETE — не закрыто $(@($Stuck).Count) из $Total (требуют человека: $($needsHuman.Count), каскад-гейт: $($gateBlocked.Count)). НЕ принимать за «готово»."
  }
  $journeyBlock = switch ($journeyState) {
    'ok'             { "## Сквозные сценарии продукта`nЗелёные — $journeySummary`n`n" }
    'partial'        { "## Сквозные сценарии продукта`n**Доказана часть** — $journeySummary`n" +
                       "Остальные пути объявлены в config/journeys.json как planned: они названы, но ещё не доказаны.`n`n" }
    'fail'           { "## Сквозные сценарии продукта`n**КРАСНЫЕ** — $journeySummary`nПодробности: ``pwsh harness/journey-gate.ps1```n`n" }
    'not-configured' { "## Сквозные сценарии продукта`n**Не заведены** (config/journeys.json). Ни один гейт этого прогона не запускал приложение: " +
                       "проверено состояние дерева, а не работа пользователя.`n`n" }
    default          { "## Сквозные сценарии продукта`nСостояние неизвестно: $journeySummary`n`n" }
  }
  $rootHint = if ($needsHuman.Count) {
    "## Корень: почини это первым`n" +
    (($needsHuman | ForEach-Object {
      $b = @(@($blocksByRoot[$_.Task]) | Where-Object { $_ })
      "- **$($_.Task)** ($($_.Reason))$(if ($b.Count) { " -> разблокирует $($b.Count): $($b -join ', ')" })"
    }) -join "`n") +
    "`n`nПосле фикса перезапусти прогон — закрытые PASS пропустятся, каскад-гейт подтянется.`n`n"
  } else { "" }

  Set-Content -Path $ReviewFile -Encoding UTF8 -Value (
    "# Ralph overnight run-all — итог`n`n" +
    "**Когда:** $Ts`n$statusLine`n**Закрыто (PASS):** $(@($Passed).Count) / $Total`n`n" +
    $rootHint +
    $journeyBlock +
    "## PASS`n$passLines`n`n" +
    "## Требуют вмешательства (сама задача застряла/упала)`n$humanLines`n`n" +
    "## Заблокированы каскад-гейтом (закроются после фикса предшественника)`n$gateLines`n`n" +
    "## Что дальше`n" +
    "- Детали: .bcf/loop.log, tasks/.verdicts/<id>.md, pwsh harness/inspect.ps1 --task <NN> --last 20.`n" +
    "- Машиночитаемый статус: .bcf/run-all.status.json (complete=$($complete.ToString().ToLower())).`n" +
    "- Незакрытые: почини «требуют вмешательства», перезапусти точечно или прогон целиком.")

  # Эволюционный harvest — топ-предложения ретроспектора (по частоте).
  try {
    # Клиент памяти — часть фабрики (одна установка pgvector на все проекты), поэтому
    # путь считается от BCF_HOME, а не от корня проекта. Ошибка в этом месте молчалива:
    # Test-Path не выполняется, блок пропускается, и раздел «Эволюция» в REVIEW.md
    # оказывается пуст всегда — при полностью рабочем ретроспекторе.
    $memClient = Join-Path (Get-BcfHomeRoot) 'memory\pgvector\memory_client.py'
    if (Test-Path $memClient) {
      $propJson = & python $memClient harvest-proposals --status new --limit 10 2>$null
      $props = if ($propJson) { try { $propJson | ConvertFrom-Json } catch { @() } } else { @() }
      $propLines = if (@($props).Count) {
        (@($props) | ForEach-Object { "- $($_.count)x [$($_.kind)] $($_.target) — $($_.rationale)" }) -join "`n"
      } else { "- (пока нет — ретроспектор накопит за прогоны)" }
      Add-Content -Path $ReviewFile -Encoding UTF8 -Value "`n## Эволюция: топ-предложения ретроспектора (по частоте)`n$propLines`n`nТриаж: python memory/pgvector/memory_client.py harvest-proposals."
    }
  } catch { }

  $rootList = if ($needsHuman.Count) {
    ($needsHuman | ForEach-Object { $b = @(@($blocksByRoot[$_.Task]) | Where-Object { $_ }); "$($_.Task)$(if ($b.Count) { " (блокирует $($b.Count))" })" }) -join ', '
  } elseif (-not $complete) { '(каскад-гейт; см. REVIEW.md)' } else { '' }

  return [pscustomobject]@{
    complete    = $complete
    passed      = @($Passed).Count
    total       = $Total
    stuck       = @($Stuck).Count
    needsHuman  = $needsHuman.Count
    gateBlocked = $gateBlocked.Count
    rootList    = $rootList
  }
}

# Тест-режим: загрузить только определения функций (headless-проверка Emit-RunAllReport),
# не запуская реальную оркестрацию очереди.
if ($env:BCF_REPORT_LIB_ONLY) { return }

# --- Очередь: top-level <PREFIX>-NN (без подзадач <PREFIX>-NN.M, без <PREFIX>-00 overview), по номеру ---
$queue = Get-ChildItem (Join-Path $root "tasks") -Filter "$taskIdPrefix-*.md" -ErrorAction SilentlyContinue |
  ForEach-Object {
    if ($_.Name -match "^$([regex]::Escape($taskIdPrefix))-(\d+)-") { [pscustomobject]@{ Task = "$taskIdPrefix-$($Matches[1])"; Num = [int]$Matches[1]; File = $_.Name } }
  } |
  Where-Object { $_.Num -ne 0 } |
  Sort-Object Num -Unique

# --- Задачи человека из очереди вон ---
#
# Строка «Исполнитель: <имя>» в файле задачи — не пометка для глаз, а решение: фабрика
# на эту задачу агента не запускает. Раньше того же добивались сентинелом
# «**Gate-вход:** TASK-00», и задача попадала в отчёт как заблокированная — то есть
# как сломанная. Здесь она просто не входит в очередь, и в журнале сказано почему.
$humanHeld = @()
$queue = @($queue | Where-Object {
  $ex = Get-TaskExecutor -TaskId $_.Task -Root $root
  if ($ex -and -not (Test-BcfExecutorIsFactory $ex)) {
    $humanHeld += [pscustomobject]@{ Task = $_.Task; Executor = $ex }
    $false
  } else { $true }
})
foreach ($h in $humanHeld) { Log "$($h.Task) — пропущена: исполнитель $($h.Executor)." }

if (-not $queue -or $queue.Count -eq 0) {
  $tail = if ($humanHeld.Count) { " Задач у людей: $($humanHeld.Count) ($(($humanHeld | ForEach-Object { $_.Task }) -join ', '))." } else { '' }
  Log "Очередь пуста — нет задач $taskIdPrefix-NN в tasks/, которые ведёт фабрика.$tail"
  exit 1
}

Log "=== ОВЕРНАЙТ run-all старт. Задач в очереди: $($queue.Count) (PerTaskMax=$PerTaskMax, model=$modelLabel). ==="
Log "Очередь: $((($queue | ForEach-Object { $_.Task }) -join ', '))"

# --- ШИНА КОМАНДЫ: чем прогон начинается ------------------------------------------------
#
# Пока publish.remote пуст, здесь не происходит ничего: ни сетевого вызова, ни новой ветки.
# Заполнен — прогон обязан начаться с чужой работы, а не со своей: fetch и перемотка ветки
# интеграции. Разошедшиеся линии работы прогон НЕ сводит и не стартует вовсе — свести их
# имеет право человек, и лучше он сделает это утром, чем фабрика ночью и молча.
. (Join-Path $PSScriptRoot 'lib\team-bus.ps1')
$runId = 'run_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$team = Start-TeamRun -Root $root
if (-not $team.Ok) {
  Log "ПРОГОН НЕ СТАРТОВАЛ: $($team.Reason)"
  exit 2
}
Log $team.Reason

# Доска задач заводится ДО первого запуска и показывает очередь целиком: наблюдателю
# нужна разница между «остальные ждут» и «остальных нет».
Reset-TaskStatusBoard -Root $root -Run $runId `
  -Queued @($queue | Where-Object { -not (Verdict-Pass $_.Task) } | ForEach-Object { $_.Task }) `
  -Closed @($queue | Where-Object {      (Verdict-Pass $_.Task) } | ForEach-Object { $_.Task }) | Out-Null
# Коммитим сразу: доска меняется весь прогон, и некоммиченной она делает дерево грязным —
# то есть отменяет и слияние задачи, и перемотку на старте следующего прогона.
Publish-TaskStatus -Root $root -Message "фабрика: доска задач ($runId)" | Out-Null

# --- Параллельный режим (MX-04). При TaskConcurrency <= 1 работает старый
# последовательный путь ниже — он проверен, его не трогаем. ---
if ($TaskConcurrency -le 0) {
  $TaskConcurrency = if ($harnessCfg -and $harnessCfg.limits.taskConcurrency) { [int]$harnessCfg.limits.taskConcurrency } else { 1 }
}
$maxAgents = if ($harnessCfg -and $harnessCfg.limits.agentConcurrency) { [int]$harnessCfg.limits.agentConcurrency } else { 6 }

if ($TaskConcurrency -gt 1 -or $DryPlan) {
  . (Join-Path $PSScriptRoot 'lib\claims.ps1')
  . (Join-Path $PSScriptRoot 'lib\fleet.ps1')
  . (Join-Path $PSScriptRoot 'lib\worktree.ps1')
  . (Join-Path $PSScriptRoot 'lib\scheduler.ps1')

  # Индекс связности пересобираем на входе: он и есть «память» о том, какие файлы
  # ходят вместе, и без свежей истории допуск слепнет.
  Update-CoChangeIndex -Root $root | Out-Null

  $mergeChecks = @()
  try {
    $cf = Join-Path $root 'config\checks.json'
    if (Test-Path $cf) {
      $cj = Get-Content -Raw -LiteralPath $cf | ConvertFrom-Json
      if ($cj._default) { $mergeChecks = @($cj._default | Where-Object { $_ -is [string] -and $_.Trim() }) }
    }
  } catch { }

  Log "Параллельный режим: до $TaskConcurrency задач одновременно, потолок агентов $maxAgents$(if ($DryPlan) { ' (DRY-PLAN — ничего не запускается)' })."

  $res = Invoke-ParallelQueue -Root $root -Tasks @($queue | ForEach-Object { $_.Task }) `
    -IsPass { param($t, $wt) Verdict-Pass $t $wt } `
    -GatePreds { param($t) Get-GatePreds $t } `
    -LogFn { param($m) Log $m } `
    -Run $runId `
    -Concurrency $TaskConcurrency -MaxAgents $maxAgents -PerTaskMax $PerTaskMax `
    -Model $Model -MergeChecks $mergeChecks -DryPlan:$DryPlan `
    -GeneratedFiles @(if ($harnessCfg -and $harnessCfg.generatedFiles) { $harnessCfg.generatedFiles } else { @() })

  foreach ($p in $res.Plan) {
    Log ("план: {0,-10} {1}" -f $p.task, $(if ($p.admitted) { 'допущена' } else { "отклонена — $($p.reason)" }))
  }

  if ($DryPlan) {
    Log "=== DRY-PLAN завершён: допущено $(@($res.Plan | Where-Object { $_.admitted }).Count), отклонено $(@($res.Plan | Where-Object { -not $_.admitted }).Count). ==="
    exit 0
  }

  # Доска закрывается и уезжает вместе с волной ДО отчёта: отказ отправки обязан попасть
  # в сам отчёт затыком, а не остаться строкой в журнале.
  $fin = Complete-TeamRun -Root $root -Run $runId -Team $team -Stuck @($res.Stuck)
  if (-not $fin.Publish.Ok) { Log "ВОЛНА НЕ ОПУБЛИКОВАНА: $($fin.Publish.Reason)" }
  elseif ($fin.Publish.Kind -eq 'pushed') { Log $fin.Publish.Reason }

  $rep = Emit-RunAllReport -Passed $res.Passed -Stuck @($fin.Stuck) -Total $queue.Count -Root $root `
    -ReviewFile $reviewFile -Ts (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Log "=== run-all (параллельно) завершён: PASS $($rep.passed)/$($rep.total), не закрыто $($rep.stuck). ==="
  if ($rep.complete) { exit 0 } else { exit 1 }
}

$passed = @(); $stuck = @()
$stuckSet = [System.Collections.Generic.HashSet[string]]::new()
$doneSet  = [System.Collections.Generic.HashSet[string]]::new()
$tasks = @($queue | ForEach-Object { $_.Task })

# Уже закрытые — сразу в passed.
foreach ($t in $tasks) {
  if (Verdict-Pass $t) { Log "$t — уже verdict: PASS, пропуск."; $passed += $t; [void]$doneSet.Add($t) }
}

# Зависимостно-аккуратный планировщик: МУЛЬТИПРОХОД. Запускаем задачу только когда все её
# TASK-предшественники = PASS. Это чинит баг порядка: TASK-04/05 (Gate-вход=TASK-06, бо́льший
# номер) ранее терялись при одном числовом проходе — теперь они запустятся в следующем проходе
# после того как TASK-06 закрылся.
$stopped = $false
while (-not $stopped) {
  if (Test-Path $stopFile) { Log "STOP-файл найден — оркестратор остановлен."; $stopped = $true; break }
  $ranThisRound = $false
  foreach ($task in $tasks) {
    if ($doneSet.Contains($task)) { continue }
    if (Test-Path $stopFile) { $stopped = $true; break }

    $preds = Get-GatePreds $task
    # Предшественник уже признан НЕ закрытым (stuck) → задача навсегда заблокирована.
    $blockedBy = @($preds | Where-Object { $stuckSet.Contains($_) })
    if ($blockedBy.Count -gt 0) {
      $reason = "gate-block: предшественник $($blockedBy -join ', ') не закрыт"
      Log "<<< $task → пропуск ($reason)."
      $stuck += [pscustomobject]@{ Task = $task; Reason = $reason }
      Update-TaskStatus -Root $root -Run $runId -Task $task -State 'заблокирована' -Node 'gate' | Out-Null
      [void]$stuckSet.Add($task); [void]$doneSet.Add($task)
      continue
    }
    # Предшественник ещё не PASS, но и не stuck (просто ещё не дошла очередь) → ждём след. прохода.
    $pending = @($preds | Where-Object { -not (Verdict-Pass $_) })
    if ($pending.Count -gt 0) { continue }

    # Все предшественники PASS (или их нет) → запускаем.
    Log ">>> Задача $task — запуск loop.ps1 -AutoAdvance (потолок $PerTaskMax итераций) ..."
    Update-TaskStatus -Root $root -Run $runId -Task $task -State 'у фабрики' -Node "работа-$task" | Out-Null

    # M-17: ИЗОЛЯЦИЯ ЗАДАЧ. Всё некоммиченное копится на ОДНОМ working-tree → правки
    # незакрытой задачи протекают в следующую и контаминируют её гейты (напр. layout-contract
    # флипал PASS/FAIL по чужому состоянию). Снимаем pre-task снимок; если задача
    # НЕ закроется — откатим ТОЛЬКО её собственную дельту (tracked→snapshot + удалим добавленные ею
    # untracked), сохранив работу прежних PASS-задач. Работа незакрытой — в refs/bcf/wip/$task.
    $preTaskSnap = (& git stash create 2>$null | Out-String).Trim()
    if (-not $preTaskSnap) { $preTaskSnap = (& git rev-parse HEAD 2>$null | Out-String).Trim() }
    $preUntracked = @(& git ls-files --others --exclude-standard 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $loopArgs = @('-NoProfile', '-File', $loopPs1, $task, '-MaxIterations', $PerTaskMax, '-AutoAdvance', '-Model', $Model)
    if ($NoAutoRollback) { $loopArgs += '-NoAutoRollback' }
    & pwsh @loopArgs
    $ranThisRound = $true
    [void]$doneSet.Add($task)

    if (Verdict-Pass $task) {
      Log "<<< $task → PASS."
      $passed += $task
      Update-TaskStatus -Root $root -Run $runId -Task $task -State 'закрыта' -Node "работа-$task" | Out-Null
    } else {
      # Реальная причина остановки из STATE.md (gate-block здесь исключён — преды уже PASS).
      $reason = 'не достиг PASS (лимит/затык)'
      $sf = Join-Path $stateDir "STATE.md"
      if (Test-Path $sf) {
        $h = Select-String -Path $sf -Pattern '##\s*Итерация.*—\s*(.+)$' | Select-Object -Last 1
        if ($h) { $reason = $h.Matches[0].Groups[1].Value.Trim() }
      }
      Log "<<< $task → НЕ закрыта ($reason)."
      $stuck += [pscustomobject]@{ Task = $task; Reason = $reason }
      Update-TaskStatus -Root $root -Run $runId -Task $task -State 'заблокирована' -Node "работа-$task" | Out-Null
      [void]$stuckSet.Add($task)

      # M-17: изоляция — откатываем собственную дельту незакрытой задачи (tracked → pre-task snapshot,
      # удаляем добавленные ею untracked), чтобы её мусор не протёк в следующую задачу. Работа уже
      # в refs/bcf/wip/$task (loop.ps1 Save-WipSnapshot) — восстановимо.
      if ($preTaskSnap) {
        # Изоляция — только по продуктовым путям. Полный откат `-- .` сносил и то,
        # что снаружи правил человек/мета-слой параллельно с прогоном (инцидент
        # 2026-07-26: удалён новый файл харнесса, откачены конфиги).
        $isoPaths = if ($harnessCfg -and $harnessCfg.productPaths) { @($harnessCfg.productPaths) } else { @('.') }
        & git checkout $preTaskSnap -- @isoPaths 2>&1 | Out-Null
        & git reset -q 2>$null   # снять с индекса (checkout стейджит) — оставить как unstaged
        $postUntracked = @(& git ls-files --others --exclude-standard 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $addedByTask = @($postUntracked | Where-Object { $preUntracked -notcontains $_ })
        # Удаляем только то, что лежит внутри продуктовых путей: новый файл обвязки,
        # созданный снаружи, петля удалять не имеет права.
        $addedByTask = @($addedByTask | Where-Object { $p = $_; @($isoPaths | Where-Object { $p -like "$_*" }).Count -gt 0 })
        foreach ($f in $addedByTask) {
          $full = Join-Path $root $f
          if (Test-Path $full) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
        }
        $snapShort = $preTaskSnap.Substring(0, [Math]::Min(8, $preTaskSnap.Length))
        Log "изоляция: откатил дельту незакрытой $task к pre-task snapshot $snapShort (untracked удалено: $($addedByTask.Count)); её работа — refs/bcf/wip/$task."
      }
    }
  }
  if ($stopped) { break }
  if (-not $ranThisRound) {
    # Ничего не запустилось и ничего не помечено — остаток заблокирован незакрытыми предами
    # (циклические/недостижимые гейты). Закрываем их как gate-block и выходим.
    foreach ($task in $tasks) {
      if ($doneSet.Contains($task)) { continue }
      $preds = Get-GatePreds $task
      $pend = @($preds | Where-Object { -not (Verdict-Pass $_) })
      $stuck += [pscustomobject]@{ Task = $task; Reason = "gate-block: предшественник $($pend -join ', ') не закрыт (не запускался)" }
      Update-TaskStatus -Root $root -Run $runId -Task $task -State 'заблокирована' -Node 'gate' | Out-Null
      [void]$doneSet.Add($task)
    }
    break
  }
}

# --- Итоговый отчёт (ОДИН на всю ночь).
# «Готово» звучит ТОЛЬКО при полностью закрытой очереди; иначе INCOMPLETE + exit 1,
# чтобы неполный прогон не был принят за успешный ни человеком, ни вызывающим агентом. ---
$fin = Complete-TeamRun -Root $root -Run $runId -Team $team -Stuck @($stuck)
if (-not $fin.Publish.Ok) { Log "ВОЛНА НЕ ОПУБЛИКОВАНА: $($fin.Publish.Reason)" }
elseif ($fin.Publish.Kind -eq 'pushed') { Log $fin.Publish.Reason }
$stuck = @($fin.Stuck)

$rep = Emit-RunAllReport -Passed $passed -Stuck $stuck -Total $queue.Count -Root $root `
  -ReviewFile $reviewFile -Ts (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

if ($rep.complete) {
  Log "=== run-all завершён: ВСЕ задачи закрыты (PASS $($rep.passed)/$($rep.total)). Итог — .bcf/REVIEW.md. ==="
  try { [console]::beep(740, 180); Start-Sleep -Milliseconds 90; [console]::beep(988, 260) } catch { }   # восходящий = успех
} else {
  Log "=== run-all завершён НЕПОЛНО: PASS $($rep.passed)/$($rep.total); НЕ закрыто $($rep.stuck) (человек: $($rep.needsHuman), каскад-гейт: $($rep.gateBlocked)). Итог — .bcf/REVIEW.md. ==="
  try { [console]::beep(660, 200); Start-Sleep -Milliseconds 110; [console]::beep(440, 450) } catch { }   # нисходящий = внимание
}
# ИТОГ ГОВОРИТСЯ В КОНСОЛЬ И В ФАЙЛЫ, А НЕ ОКНОМ.
#
# Здесь стоял [System.Windows.Forms.MessageBox]::Show в обеих ветках. Модальное окно
# держит процесс до нажатия ОК: прогон по расписанию не завершался вовсе, а висел до
# утра — и код возврата, ради которого всё это писалось, никто не получал. Для машины,
# за которой работает человек, это ещё и окно поверх чужой работы среди ночи, а когда
# фабрику ведут несколько человек — окно на чужом экране.
#
# Итог уже лежит в трёх местах, каждое читается без нажатия: .bcf/run-all.status.json,
# .bcf/REVIEW.md и код возврата этой команды. Звук выше остаётся: он ничего не блокирует.
if ($rep.complete) {
  Log "Итог в .bcf/REVIEW.md, машиночитаемо в .bcf/run-all.status.json (complete=true), код возврата 0."
  exit 0
}
Log "Итог в .bcf/REVIEW.md, машиночитаемо в .bcf/run-all.status.json (complete=false), код возврата 1."
if ($rep.rootList) { Log "Чинить первым: $($rep.rootList)" }
exit 1
