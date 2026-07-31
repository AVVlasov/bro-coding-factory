# harness/loop.ps1 — Ralph loop runner для the project (bounded-режим).
#
# Каждая итерация: opencode выполняет ОДИН шаг задачи в свежем контексте → раннер гоняет
# backpressure (tsc + done-gate) → пишет результат в .bcf/STATE.md (legacy compat) +
# .bcf/events.jsonl (W3, append-only) → следующая итерация видит ошибки и исправляет.
# Останавливается на verdict-гейте для ревью оператора.
#
# Защиты от зависания:
#   - таймаут на итерацию (-IterTimeoutSec): зависший opencode run убивается;
#   - детектор «нет прогресса»: N итераций без изменений кода → стоп;
#   - loop-detection: 3 итерации с одной ошибкой → стоп;
#   - потолок -MaxIterations; файл .bcf/STOP; стоп на verdict: PASS.
#
# W3 (2026-05-24): event-sourced harness.
#   - .bcf/events.jsonl  — append-only журнал событий
#   - .bcf/state/STATE.json — derived projection (пересчитывается inspect.ps1 --replay)
#   - .bcf/STATE.md остался для legacy compat (агент его читает); удалим в W6 cleanup
#
# Запуск:
#   pwsh harness/loop.ps1 TASK-01
#   pwsh harness/loop.ps1 TASK-02 -Model "<model>" -IterTimeoutSec 1200
#   pwsh harness/loop.ps1 TASK-03 -Force
# Обычно — через тонкий лаунчер harness/start.ps1 <TASK-ID> (или эквивалентную команду вашего CLI).

param(
  [Parameter(Position = 0)] [string]$Task = "",
  [int]$MaxIterations = 40,
  [string]$Model = "",
  [int]$IterTimeoutSec = 900,       # таймаут одной итерации opencode run
  [int]$NoProgressLimit = 3,        # стоп после N итераций без изменений кода
  [int]$StreamStallSec = 150,       # стрим молчит N сек И эндпоинт недоступен → обрыв связи (не ждём IterTimeoutSec)
  [int]$NetWaitMaxSec = 0,          # сколько ждать восстановления интернета, 0 = без лимита (overnight)
  [string]$NetProbeHost = "",        # хост для проверки связи (= API-эндпоинт модели). Пусто = net-watchdog выключен. Берётся из config/harness.json net.probeHost.
  [int]$NetProbePort = 443,
  [int]$NetStallRetryMax = 8,       # макс. подряд retry одной итерации из-за обрывов сети (защита от флаппинга)
  [switch]$AutoAdvance,
  [switch]$NoAutoRollback,          # M-09 E: отключить авто-откат регрессий tsc (default on)
  [switch]$Force,
  [string]$ProjectRoot = ''         # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

# --- Harness config (config/harness.json) — единственный источник специфики проекта. ---
# Все ранее захардкоженные значения (модель, пути, productPaths, net-probe, фичи) живут тут.
$ConfigFile = Join-Path $root 'config\harness.json'
$Cfg = $null
if (Test-Path $ConfigFile) {
  try { $Cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json } catch { Write-Warning "config/harness.json: parse failed ($_) — используются дефолты" }
}
# Явно переданные CLI-параметры всегда побеждают; иначе берём значение из конфига; иначе — дефолт param().
if ($Cfg) {
  if (-not $PSBoundParameters.ContainsKey('Model')            -and $Cfg.models.code)               { $Model = [string]$Cfg.models.code }
  if (-not $PSBoundParameters.ContainsKey('MaxIterations')    -and $Cfg.limits.maxIterations)       { $MaxIterations = [int]$Cfg.limits.maxIterations }
  if (-not $PSBoundParameters.ContainsKey('IterTimeoutSec')   -and $Cfg.timeouts.iterSec)           { $IterTimeoutSec = [int]$Cfg.timeouts.iterSec }
  if (-not $PSBoundParameters.ContainsKey('NoProgressLimit')  -and $Cfg.limits.noProgressLimit)     { $NoProgressLimit = [int]$Cfg.limits.noProgressLimit }
  if (-not $PSBoundParameters.ContainsKey('StreamStallSec')   -and $Cfg.timeouts.streamStallSec)    { $StreamStallSec = [int]$Cfg.timeouts.streamStallSec }
  if (-not $PSBoundParameters.ContainsKey('NetWaitMaxSec')    -and $null -ne $Cfg.timeouts.netWaitMaxSec)  { $NetWaitMaxSec = [int]$Cfg.timeouts.netWaitMaxSec }
  if (-not $PSBoundParameters.ContainsKey('NetProbeHost')     -and $null -ne $Cfg.net.probeHost)     { $NetProbeHost = [string]$Cfg.net.probeHost }
  if (-not $PSBoundParameters.ContainsKey('NetProbePort')     -and $Cfg.net.probePort)              { $NetProbePort = [int]$Cfg.net.probePort }
  if (-not $PSBoundParameters.ContainsKey('NetStallRetryMax') -and $Cfg.timeouts.netStallRetryMax)  { $NetStallRetryMax = [int]$Cfg.timeouts.netStallRetryMax }
}
# Производные настройки из конфига (с дефолтами).
$ProductPaths     = if ($Cfg -and $Cfg.productPaths)        { @($Cfg.productPaths) }        else { @('src') }
$TaskIdPattern    = if ($Cfg -and $Cfg.taskIdPattern)       { [string]$Cfg.taskIdPattern }  else { '[A-Za-z][A-Za-z0-9]*-\d+' }
$TaskIdPrefix     = if ($Cfg -and $Cfg.taskIdPrefix)        { [string]$Cfg.taskIdPrefix }   else { 'TASK' }
$JudgeName        = if ($Cfg -and $Cfg.judge.name)          { [string]$Cfg.judge.name }     else { 'judge' }
$NetWatchdogOn    = [bool]$NetProbeHost
# Фичи → env-тумблеры, которые уважают lib-модули (по умолчанию выключены = ноль внешних зависимостей).
$FeatMemory       = [bool]($Cfg -and $Cfg.features.memory)
if (-not $FeatMemory) { $env:BCF_MEMORY_DISABLED = '1' }
# Команда бэкенд-агента — шаблон из конфига ({model} подставляется в момент запуска).
$AgentCmdTpl = if ($Cfg -and $Cfg.agent.command) { [string]$Cfg.agent.command } else { 'opencode run --dangerously-skip-permissions --thinking --format json --model {model}' }
$AgentBin    = ($AgentCmdTpl -split '\s+')[0]

# Консоль в UTF-8 — иначе кириллица в выводе/логе превращается в мусор (mojibake).
# Три отдельные настройки нужны все (фикс 2026-05-25):
#   - InputEncoding  — как PS декодит stdin (subprocess.ReadLine);
#   - OutputEncoding — как PS энкодит stdout (Write-Host/Write-Output);
#   - chcp 65001     — как conhost рендерит UTF-8 байты в окне.
# Без chcp UTF-8 байты cyrillic (0xD0 0xA2 = «Т») интерпретируются conhost'ом как
# cp866 → «╨в». Без InputEncoding PS читает stdin как cp866, ломая исходные строки.
try {
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding           = [System.Text.Encoding]::UTF8
  chcp 65001 | Out-Null
} catch { }

# W3: подключаем event-bus.
. (Join-Path $PSScriptRoot 'lib\event-bus.ps1')
Initialize-EventBus -RalphRoot (Get-BcfStateDir $root)

# Рендер JSON-событий бэкенд-агента → live в loop-окно (адаптер бэкенда, default opencode).
. (Join-Path $PSScriptRoot 'lib\adapters\oc-render.ps1')

# Memory bridge: vector-memory recall + retrospector + finding-gate.
# Loop вызывает агента subprocess'ом → хуки IDE не срабатывают; мостик вшивает их явно.
# Включается feature-флагом features.memory (config/harness.json); иначе no-op ($env:BCF_MEMORY_DISABLED=1).
. (Join-Path $PSScriptRoot 'lib\m13-bridge.ps1')

# M-13/Phase1 (2026-05-28): bug-tracker supervisor — после verdict собирает
# findings в bug-ledger, в начале iter инжектит <open-bugs> блок в STATE.md.
. (Join-Path $PSScriptRoot 'lib\bug-supervisor.ps1')

# M-13/Phase3 (2026-05-28): vision baseline — на PASS снимаем aggregate, на FAIL
# проверяем регресс vs baseline и автоматически reopen в bug-ledger.
. (Join-Path $PSScriptRoot 'lib\vision-baseline.ps1')

# M-13/Phase4 (2026-05-28): adaptive hard-cap — severity-weighted iter limit.
. (Join-Path $PSScriptRoot 'lib\hard-cap.ps1')

# M-13/N (2026-05-28): visual context — base64 reference+current в STATE.md
# для <model> multimodal. Закрывает visual-cognitive gap text-only loop'а.
. (Join-Path $PSScriptRoot 'lib\visual-context.ps1')

# M-13/O (2026-05-28): reference structural digest — canonical reference,
# не зависящий от того как агент трактует JSX каждую итерацию.
. (Join-Path $PSScriptRoot 'lib\reference-digest.ps1')

# M-13/P (2026-05-28): structural breakdown detector — SSIM<0.5 в любой паре
# slug/theme = переделать с нуля, не подкручивать. Спираль 11+ iter лечится.
. (Join-Path $PSScriptRoot 'lib\redo-trigger.ps1')

# Счётчик iter без PASS — для hard-cap (сбрасывается на PASS).
$script:itersWithoutPass = 0
# M-20 (2026-05-31): детерминированный детектор sprawl. Anti-pattern #1 (176 хитов): задача
# копит >N файлов за >M итераций без PASS → фокус расплывается, ни один аспект не закрывается.
# Форсим Phase-0 reset (single-aspect subtask) ОДИН раз, рано — не дожидаясь severity-hard-cap.
$sprawlForced    = $false
$SprawlFileLimit = 40   # >40 файлов в HEAD-диффе (без .bcf/)
$SprawlIterLimit = 5    # и >5 итераций без PASS

$promptFile = Join-Path $root ".bcf\PROMPT.md"
if (-not (Test-Path $promptFile)) { $promptFile = Join-Path $PSScriptRoot "PROMPT.md" }
$stateFile  = Join-Path $root ".bcf\STATE.md"
$logFile    = Join-Path $root ".bcf\loop.log"
$stopFile   = Join-Path $root ".bcf\STOP"
$focusFile  = Join-Path $root "tasks\CURRENT-FOCUS.md"

function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  # Цвет по семантике (M-09 UX): красный — критика/таймаут, жёлтый — паузы/блок,
  # зелёный — PASS/готово, голубой — старт итерации, magenta — verify-фаза.
  $color = 'Gray'
  if ($msg -match 'ОШИБКА|FAILED|TIMEOUT|REGRESSION|BLOCK|launch-failed') { $color = 'Red' }
  elseif ($msg -match 'STOP|HUMAN CALLOUT|FRICTION|остановк|пауза|Нет прогресса|снят|Loop-detection') { $color = 'Yellow' }
  elseif ($msg -match 'PASS|готов|verdict: PASS|завершён') { $color = 'Green' }
  elseif ($msg -match '--- Итерация |=== Ralph loop старт') { $color = 'Cyan' }
  elseif ($msg -match '\[verify\]|VERIFY-REQUEST|Маркер') { $color = 'Magenta' }
  Write-Host $line -ForegroundColor $color
  Add-Content -Path $logFile -Value $line
}

function Get-Focus {
  if (!(Test-Path $focusFile)) { return $null }
  $m = Select-String -Path $focusFile -Pattern $TaskIdPattern | Select-Object -First 1
  if ($m) { return $m.Matches[0].Value }
  return $null
}

function Verdict-Pass($t) {
  $vf = Join-Path $root "tasks\.verdicts\$t.md"
  if (!(Test-Path $vf)) { return $false }
  return [bool](Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
}

# Отпечаток рабочего дерева БЕЗ .bcf/ (раннер сам пишет в .bcf/ — это не «прогресс»).
function Get-TreeHash {
  $d  = (git diff HEAD -- ':!loop' 2>$null | Out-String)
  $d += (git status --porcelain -- ':!loop' 2>$null | Out-String)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($d))
  return ([BitConverter]::ToString($h) -replace '-', '')
}

# M-16 (2026-05-31): СТАБИЛЬНАЯ сигнатура набора падающих тестов из вывода verify.
# Берём id'шники упавших спеков (path.spec.ts:LINE:COL) из .bcf/verify/<task>-*.out.txt —
# они не зависят от тайминга/формулировок (в отличие от bp-строки, по которой loop-detection
# слеп: причины «плавают», а набор тестов тот же). Пусто = не смогли извлечь / нет падений.
function Get-FailingTestSignature {
  param([string]$Repo, [string]$Task)
  $verifyDir = Join-Path $Repo '.bcf\verify'
  if (-not (Test-Path $verifyDir)) { return '' }
  $ids = New-Object System.Collections.Generic.HashSet[string]
  Get-ChildItem $verifyDir -Filter "$Task-*.out.txt" -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($ln in (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)) {
      # строки-провалы list-reporter'а playwright: "  x  N … spec.ts:NN:CC …" или "  N) … spec.ts:NN:CC"
      if ($ln -match '^\s*(?:x|✘|\d+\))\s') {
        $m = [regex]::Match($ln, '([^\s›]+\.spec\.ts:\d+:\d+)')
        if ($m.Success) { [void]$ids.Add($m.Groups[1].Value) }
      }
    }
  }
  if ($ids.Count -eq 0) { return '' }
  return (($ids | Sort-Object) -join '|')
}

# M-15 (2026-06-05): ДЕТЕРМИНИРОВАННЫЙ дайджест провалов из .bcf/verify/<task>-*.out.txt.
# Зачем: раньше в backpressure уходил только вердикт LLM-судьи (который галлюцинирует ИЛИ не
# может прочитать файл вывода — кейс TASK-16: судья выдал «найди файл» вместо «удали кнопку»).
# Точный машинный вывод гейта (rendered vs expected, Expected/Received, unknown=[...]) —
# авторитетнее судьи. Прокидываем его агенту напрямую, чтобы петля чинила ФАКТ, а не туман.
function Get-DeterministicFailureDigest {
  param([string]$Repo, [string]$Task, [int]$MaxLines = 40, [int]$PerFile = 12)
  $verifyDir = Join-Path $Repo '.bcf\verify'
  if (-not (Test-Path $verifyDir)) { return '' }
  # Сигнальные строки: заголовки упавших спеков, assert-диффы, контракт-диагностика навигации.
  $signal = '(^\s*(?:x|✘|\d+\))\s)|(\bError:)|(\bExpected:)|(\bReceived:)|(rendered nav)|(^\s*expected:)|(\bunknown\b)|(НЕИЗВЕСТНЫЕ)|(разошлась)|(\.spec\.ts:\d+:\d+)|(\bfailed\b)'
  $out = New-Object System.Collections.Generic.List[string]
  Get-ChildItem $verifyDir -Filter "$Task-*.out.txt" -ErrorAction SilentlyContinue |
    # ТОЛЬКО детерминированные выводы (check*/vision-contract*/vision-suite*); LLM-файлы
    # тестеров/судьи ($Task-<role>.out.txt) исключаем — это проза, ровно тот туман,
    # который дайджест и призван обойти.
    Where-Object { $_.Name -match "-(check|vision-contract|vision-suite)" } |
    Sort-Object LastWriteTime | ForEach-Object {
      $hits = @()
      foreach ($ln in (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)) {
        $clean = ($ln -replace '\x1b\[[0-9;]*m', '').TrimEnd()   # снять ANSI-цвета
        if ($clean -and ($clean -match $signal)) { $hits += $clean }
      }
      if ($hits.Count -gt 0) {
        $out.Add("--- $($_.Name) ---")
        foreach ($h in ($hits | Select-Object -First $PerFile)) { $out.Add($h) }
      }
    }
  if ($out.Count -eq 0) { return '' }
  return (($out | Select-Object -First $MaxLines) -join "`n")
}

function Get-LastOpencodeCommand {
  try {
    $logDir = Join-Path $env:USERPROFILE ".local\share\opencode\log"
    $latest = Get-ChildItem $logDir -Filter '*.log' -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return "" }
    $hits = Select-String -Path $latest.FullName -Pattern 'permission=bash pattern=(.+?) (ruleset|action)=' -AllMatches
    if ($hits) {
      $last = $hits[-1].Matches
      return $last[$last.Count - 1].Groups[1].Value.Trim()
    }
  } catch { }
  return ""
}

# ── Сетевой watchdog: обрывы интернета на стороне юзера рвут SSE-стрим модели
# посреди итерации; CLI-агент часто не имеет idle-таймаута на стрим и виснет до
# грубого wall-kill (мёртвый эфир). Хелперы дают (1) дешёвую TCP-пробу до
# API-эндпоинта модели и (2) блокирующее ожидание восстановления связи.
# Пустой $NetHost (config net.probeHost не задан) → watchdog выключен (всегда «online»).
function Test-Connectivity {
  param([string]$NetHost = '', [int]$Port = 443, [int]$TimeoutMs = 4000)
  if ([string]::IsNullOrWhiteSpace($NetHost)) { return $true }
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($NetHost, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
    if ($ok -and $client.Connected) { $client.EndConnect($iar); return $true }
    return $false
  } catch { return $false }
  finally { if ($client) { try { $client.Close() } catch { } } }
}

function Wait-ForConnectivity {
  param([string]$NetHost, [int]$Port, [int]$MaxWaitSec = 0, [int]$ProbeEverySec = 15, [int]$Iteration = 0, [string]$FocusTask = '')
  if (Test-Connectivity -NetHost $NetHost -Port $Port) { return $true }
  $lim = if ($MaxWaitSec -le 0) { '∞' } else { "${MaxWaitSec}s" }
  Log "🌐 Нет связи с ${NetHost}:${Port} — жду восстановления интернета (проба каждые ${ProbeEverySec}s; лимит $lim)…"
  Append-Event -EventType 'network-down' -TaskId $FocusTask -Phase 'A/B' -Iteration $Iteration -Payload @{ host = $NetHost; port = $Port }
  $waited = 0
  while ($true) {
    Start-Sleep -Seconds $ProbeEverySec
    $waited += $ProbeEverySec
    if (Test-Connectivity -NetHost $NetHost -Port $Port) {
      Log "🌐 Интернет восстановлен после ${waited}s — продолжаю."
      Append-Event -EventType 'network-restored' -TaskId $FocusTask -Phase 'A/B' -Iteration $Iteration -Payload @{ waited_sec = $waited }
      return $true
    }
    if ($MaxWaitSec -gt 0 -and $waited -ge $MaxWaitSec) {
      Log "🌐 Связь не восстановилась за ${MaxWaitSec}s — выхожу из ожидания."
      Append-Event -EventType 'network-wait-timeout' -TaskId $FocusTask -Phase 'A/B' -Iteration $Iteration -Payload @{ waited_sec = $waited }
      return $false
    }
    if (($waited % 60) -eq 0) { Log "🌐 …всё ещё нет связи (${waited}s)…" }
  }
}

# Чем закончился оборванный стрим: 'model' (последнее событие — генерация модели:
# step_start/reasoning/text → виновата модель/сеть, НЕ shell-команда) или 'tool'.
function Get-IterStallKind {
  param([string]$JsonlPath)
  try {
    if (-not (Test-Path $JsonlPath)) { return 'unknown' }
    $tail = @(Get-Content -LiteralPath $JsonlPath -Tail 6 -ErrorAction SilentlyContinue)
    for ($k = $tail.Count - 1; $k -ge 0; $k--) {
      if ([string]::IsNullOrWhiteSpace($tail[$k])) { continue }
      try {
        $t = [string](($tail[$k] | ConvertFrom-Json).type)
        if ($t -in 'step_start', 'step_finish', 'reasoning', 'text') { return 'model' }
        if ($t -eq 'tool_use') { return 'tool' }
      } catch { }
    }
  } catch { }
  return 'unknown'
}

function Notify-Stop($kind, $title, $detail) {
  # AutoAdvance (overnight run-all): per-task попапы/REVIEW подавляем — оркестратор run-all.ps1
  # сводит ОДИН итоговый отчёт в конце. Иначе за ночь — шторм окон Windows.
  if ($AutoAdvance) { Log "[auto-advance] стоп текущей задачи ($title) — оркестратор перейдёт к следующей."; return }
  $rf = Join-Path $root ".bcf\REVIEW.md"
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Set-Content -Path $rf -Encoding UTF8 -Value (
    "# Ralph loop остановлен — нужно твоё внимание`n`n" +
    "**Когда:** $ts`n**Причина:** $title`n`n$detail`n`n" +
    "## Что дальше`n" +
    "- Открой .bcf/loop.log, .bcf/state/STATE.json и (legacy) .bcf/STATE.md.`n" +
    "- inspect событий: pwsh harness/inspect.ps1 --task <TASK-NN> --last 20`n" +
    "- Если verdict PASS — посмотри tasks/.verdicts/, сделай ревью, затем harness/start.ps1 для следующей задачи.`n" +
    "- Если застряло — разберись с причиной, поправь, перезапусти harness/start.ps1.")
  try { [console]::beep(880, 250); Start-Sleep -Milliseconds 120; [console]::beep(660, 300) } catch { }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($kind -eq 'ok') { 'Information' } else { 'Warning' }
    [System.Windows.Forms.MessageBox]::Show(
      "$detail`n`nПодробности — .bcf/REVIEW.md, .bcf/loop.log, .bcf/state/STATE.json",
      "Ralph loop: $title", 'OK', $icon) | Out-Null
  } catch { }
}

# --- M-13/J (2026-05-27): three-level scope (iter / task / release) ---
# Task-scope живёт в секции «## 3.1. Scope» task-файла и формализует bounded box:
# module / vision_slugs / testers / paths. Если секция есть — она авторитетна.
# Без секции — фолбэк на auto-detect через vision-slug-map.json и tester-scope-map.json.
function Read-TaskScope {
    param([Parameter(Mandatory)][string]$TaskFile)
    if (-not (Test-Path $TaskFile)) { return $null }
    $body = Get-Content -Raw -LiteralPath $TaskFile
    $m = [regex]::Match($body, '(?ims)^##\s*3\.1\.?\s*Scope\b.*?(?=^##\s|\z)')
    if (-not $m.Success) { return $null }
    $section = $m.Value
    $scope = @{ module = ''; vision_slugs = @(); testers = @(); paths = @() }
    if ($section -match '(?im)^\s*[-*]?\s*\*\*?module:\*\*?\s*([^\r\n]+)') { $scope.module = $Matches[1].Trim() }
    if ($section -match '(?im)^\s*[-*]?\s*\*\*?vision_slugs:\*\*?\s*([^\r\n]+)') {
        $scope.vision_slugs = @(($Matches[1] -split '[,\s]+') | Where-Object { $_ -and $_ -ne '`' })
    }
    if ($section -match '(?im)^\s*[-*]?\s*\*\*?testers:\*\*?\s*([^\r\n]+)') {
        $scope.testers = @(($Matches[1] -split '[,\s]+') | Where-Object { $_ -and $_ -ne '`' })
    }
    # paths — multi-line bullet list под «- **paths:**».
    $pm = [regex]::Match($section, '(?ims)^\s*[-*]?\s*\*\*?paths:\*\*?\s*\r?\n((?:\s*[-*`].+\r?\n?)+)')
    if ($pm.Success) {
        foreach ($pl in ($pm.Groups[1].Value -split "`r?`n")) {
            if ($pl -match '^\s*[-*]\s*[`"]?([^`"\s]+)') { $scope.paths += $Matches[1] }
        }
    }
    return $scope
}
function ScopePath-Matches {
    param([string]$File, [string[]]$Globs)
    if (-not $Globs -or $Globs.Count -eq 0) { return $false }
    $f = $File -replace '\\','/'
    foreach ($g in $Globs) {
        $glob = $g -replace '\\','/'
        # Простой glob → regex: ** = .*, * = [^/]*, остальное литералом.
        $rx = '^' + ([regex]::Escape($glob) -replace '\\\*\\\*','.*' -replace '\\\*','[^/]*') + '$'
        if ($f -match $rx) { return $true }
    }
    return $false
}

# --- Инициализация задачи (если передан аргумент) ---
if ($Task) {
  $Task = $Task.ToUpper().Trim()
  $tf = Get-ChildItem (Join-Path $root "tasks") -Filter "$Task-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $tf) { Log "ОШИБКА: задача $Task не найдена в tasks/."; exit 1 }

  # Разбор предшественников — общей функцией (harness/lib/claims.ps1). До этого их было
  # три копии — здесь, в run-all и в графе — плюс четвёртая в CLI, и та читала другое
  # поле: на реальном проекте `bcf tasks` показал одиннадцать задач «готова» при пяти
  # заблокированных. Один разборщик — единственный способ не повторить это.
  . (Join-Path $PSScriptRoot 'lib\claims.ps1')
  $preds = @(Get-TaskPredecessors -TaskId $Task -Root $root -Prefix $TaskIdPrefix)
  if ($preds.Count) {
    foreach ($p in $preds) {
      if (-not (Verdict-Pass $p)) {
        Log "БЛОК: предшественник $p не имеет verdict: PASS. Закрой $p или запусти с -Force."
        Append-Event -EventType 'loop-blocked' -TaskId $Task -Phase 'loop' `
          -Payload @{ predecessor = $p; reason = 'predecessor-not-pass'; force = [bool]$Force }
        if (-not $Force) { exit 1 }
        Log "-Force: продолжаю несмотря на незакрытый $p."
      }
    }
  }
  Set-Content -Path $focusFile -Value "**Task ID:** $Task`n**Task file:** tasks/$($tf.Name)`n**Status:** open`n" -Encoding UTF8
  Log "CURRENT-FOCUS установлен на $Task."
  Append-Event -EventType 'focus-set' -TaskId $Task -Phase 'loop' `
    -Payload @{ task_file = "tasks/$($tf.Name)"; forced = [bool]$Force }
}

if (!(Get-Command $AgentBin -ErrorAction SilentlyContinue)) {
  Log "ОШИБКА: агент '$AgentBin' (из config/harness.json agent.command) не найден в PATH."; exit 1
}
$hasBash = [bool](Get-Command bash -ErrorAction SilentlyContinue)
if (-not $hasBash) { Log "ПРЕДУПРЕЖДЕНИЕ: 'bash' не найден — done-gate.sh пропускается." }

# opencode desktop пробрасывает в дочерние процессы ссылку на свою сессию через OPENCODE_*
# env-переменные. Дочерний `opencode run` пытается подключиться к ней → "Error: Session
# not found", итерация завершается вхолостую. Чистим эти переменные в своём процессе —
# потомки (`opencode run`) их не унаследуют.
$ocEnvCleared = @()
Get-ChildItem env: | Where-Object { $_.Name -like 'OPENCODE_*' } | ForEach-Object {
  $ocEnvCleared += $_.Name
  Remove-Item "env:$($_.Name)" -ErrorAction SilentlyContinue
}
if ($ocEnvCleared.Count -gt 0) { Log "Очищены унаследованные env-переменные: $($ocEnvCleared -join ', ')" }

Log "=== Ralph loop старт. Task=$(if($Task){$Task}else{'(из CURRENT-FOCUS)'}) Model=$(if($Model){$Model}else{'(дефолт бэкенда)'}) Max=$MaxIterations Timeout=${IterTimeoutSec}s NoProgress=$NoProgressLimit ==="
Append-Event -EventType 'loop-started' -TaskId $Task -Phase 'loop' `
  -Payload @{ max_iterations = $MaxIterations; iter_timeout_sec = $IterTimeoutSec; no_progress_limit = $NoProgressLimit; model = $Model; session_id = (Get-EventBusSession) }

# M-13: автостарт векторной памяти + громкая диагностика (раньше отсутствие
# контейнера тихо отключало весь цикл обучения). Результат фиксируем в loop.log.
try {
  $m13ready = Ensure-M13Memory
  if ($m13ready) {
    Log "M-13: векторная память АКТИВНА — цикл обучения работает (recall/retrospector/finding-gate)."
  } else {
    Log "M-13: ВНИМАНИЕ — векторная память НЕДОСТУПНА, цикл обучения ВЫКЛЮЧЕН (recall/retrospector/finding-gate будут пропущены). См. вывод выше."
  }
  Append-Event -EventType 'm13-memory-status' -TaskId $Task -Phase 'loop' -Payload @{ ready = [bool]$m13ready }
} catch { Log "M-13: Ensure-M13Memory упал (non-fatal): $($_.Exception.Message)" }

# WIP-снапшот: durable, gc-safe снимок working-tree в конце итерации. НЕ двигает
# HEAD и НЕ трогает `git diff HEAD` — cumulative task-diff (на нём висят evidence,
# idempotency-fingerprint, triggers) остаётся прежним. Снимок пишется в ref
# (refs/bcf/wip/<task> + per-iter history), поэтому git gc его не соберёт, и
# любую итерацию можно восстановить: `git checkout refs/bcf/wip-history/<task>/iterN -- .`.
# Решает проблему: прогресс жил только в uncommitted working-tree (хрупко, дни работы).
function Save-WipSnapshot {
  param([string]$Repo, [string]$TaskId, [int]$Iteration)
  $snap = (& git -C $Repo stash create 2>$null | Out-String).Trim()
  if (-not $snap) { return $null }   # дерево чистое → снимать нечего
  & git -C $Repo update-ref "refs/bcf/wip/$TaskId" $snap 2>$null
  & git -C $Repo update-ref "refs/bcf/wip-history/$TaskId/iter$Iteration" $snap 2>$null
  return $snap
}

$lastError = ""
$sameErrorCount = 0
$lastHash = Get-TreeHash
$noProgressCount = 0
$netStallRetry = 0                 # подряд retry текущей итерации из-за обрывов сети (сброс на нормальной итерации)
$noProgressEscalated = $false      # M-15 (2026-05-30): unattended no-progress эскалируется один раз, потом стоп
$lastFailSig = ""                  # M-16 (2026-05-31): сигнатура набора падающих тестов прошлого verify
$sameFailSetCount = 0              # сколько verify подряд падает ОДИН И ТОТ ЖЕ набор тестов
$FailSetStall = 3                  # N verify подряд с тем же fail-set → гейт не сходится → callout
$launchFailCount = 0
$lastTscExit = 0                  # M-09 E: для детекции регрессии 0 → ≠0
$preIterTreeRef = ""              # M-09 E: SHA дерева ДО итерации (для git stash отката)

for ($i = 1; $i -le $MaxIterations; $i++) {

  if (Test-Path $stopFile) {
    Log "STOP-файл найден — остановка."
    Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ reason = 'stop-file' }
    break
  }

  $focus = Get-Focus
  if (-not $focus) {
    Log "tasks/CURRENT-FOCUS.md пуст или без TASK-NN — нечего делать."
    Append-Event -EventType 'loop-paused' -Phase 'loop' -Iteration $i `
      -Payload @{ reason = 'no-focus' }
    break
  }

  if (Verdict-Pass $focus) {
    Log "[$focus] verdict: PASS. Bounded-режим: СТОП на ревью оператора."
    Log "Проверь tasks/.verdicts/$focus.md, затем запусти harness/start.ps1 для следующей задачи."
    Append-Event -EventType 'task-closed' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ verdict = 'PASS'; pre_iter_check = $true }
    Notify-Stop 'ok' "$focus готова к ревью" "Задача $focus прошла судью (verdict: PASS). Цикл остановлен — нужно твоё ревью."
    break
  }

  Log "--- Итерация $i / $MaxIterations  (задача $focus) ---"
  Append-Event -EventType 'iter-started' -TaskId $focus -Phase 'loop' -Iteration $i `
    -Payload @{ tree_hash = $lastHash }

  # Boundary-sentinel: снимок sibling-папок рядом с репозиторием ДО итерации.
  # Цель — поймать запись агента за пределы проекта (напр. опечатка в абсолютном пути
  # foo→fooo молча создаёт мусорную папку-двойник). Инцидент 2026-05-30.
  $repoParent  = Split-Path $root -Parent
  $repoLeaf    = Split-Path $root -Leaf
  $siblingsBefore = @()
  try {
    $siblingsBefore = @(Get-ChildItem -LiteralPath $repoParent -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne $repoLeaf } | Select-Object -ExpandProperty Name)
  } catch { }

  # M-09 E: снимаем git-snapshot ДО итерации (для возможного rollback регрессии).
  # Используем stash create — не трогает working-tree, только создаёт commit-object.
  if ((-not $NoAutoRollback)) {
    $preIterTreeRef = (& git stash create 2>$null | Out-String).Trim()
    if (-not $preIterTreeRef) { $preIterTreeRef = (& git rev-parse HEAD 2>$null | Out-String).Trim() }
    # Persist pre-iter snapshot в ref → цель отката durable (git gc не тронет),
    # даже если итерация длинная. Не пишем, если свалились в fallback HEAD.
    $headNow = (& git rev-parse HEAD 2>$null | Out-String).Trim()
    if ($preIterTreeRef -and $preIterTreeRef -ne $headNow) {
      & git update-ref "refs/bcf/pre-iter/$focus" $preIterTreeRef 2>$null
    }
  }

  # M-13 B: recall граблей из векторной памяти → prepend в STATE.md перед opencode.
  try { Inject-AntiPatterns -StateFile $stateFile -TaskId $focus -Iteration $i } catch { Log "M-13 inject failed (non-fatal): $($_.Exception.Message)" }

  # M-13/Phase1: инжект <open-bugs> блока (priority-list) в STATE.md.
  try { Inject-OpenBugs -StateFile $stateFile -TaskId $focus } catch { Log "bug-supervisor inject failed (non-fatal): $($_.Exception.Message)" }

  # M-20 (2026-05-31): ФОРС-ДЕКОМПОЗИЦИЯ при sprawl (anti-pattern #1, 176 хитов). Детерминированно:
  # >SprawlFileLimit файлов в HEAD-диффе И >SprawlIterLimit итераций без PASS → фокус расплылся.
  # Препендим в STATE жёсткую директиву Phase-0 reset (single-aspect subtask). Один раз; дальше
  # держат hard-cap / failing-set / no-progress.
  if (-not $sprawlForced) {
    try {
      $changedCount = @(& git diff HEAD --name-only -- ':!loop' 2>$null | Where-Object { $_ }).Count
    } catch { $changedCount = 0 }
    if ($changedCount -gt $SprawlFileLimit -and $script:itersWithoutPass -ge $SprawlIterLimit) {
      $sprawlForced = $true
      $directive = @"
# PHASE-0 RESET — ФОРС-ДЕКОМПОЗИЦИЯ (раннер, M-20)

Задача ${focus}: **$changedCount файлов** изменено за **$($script:itersWithoutPass) итераций без PASS** —
фокус расплылся, ни один аспект не закрывается (anti-pattern #1, самый частый рецидив).

СТОП широкому фронту. Сделай Phase-0 reset ПРЯМО СЕЙЧАС:
1. Открой ТОП-1 пункт remediation последнего вердикта (tasks/.verdicts/$focus.md + inner judge JSON) —
   повторяющийся CRITICAL, не «верхнюю строку».
2. Заведи ОДНУ single-aspect подзадачу `tasks/$focus.<seq>-<slug>.md` с проверяемым observable
   (что увидим/прогоним, чтобы признать закрытой).
3. Делай ТОЛЬКО её, минимальным диффом. НЕ трогай прочие аспекты. НЕ откладывай словами
   («потом/отложу») — либо фикс в этой итерации, либо subtask с observable.

"@
      try {
        $existingState = if (Test-Path $stateFile) { Get-Content -Raw -LiteralPath $stateFile } else { '' }
        Set-Content -LiteralPath $stateFile -Value ($directive + "`n" + $existingState) -Encoding UTF8
      } catch { Log "M-20 sprawl-inject failed (non-fatal): $($_.Exception.Message)" }
      Append-Event -EventType 'sprawl-forced-decomposition' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ changed_files = $changedCount; iters_without_pass = $script:itersWithoutPass; file_limit = $SprawlFileLimit }
      Log "M-20 SPRAWL: $changedCount файлов / $($script:itersWithoutPass) iter без PASS → форс Phase-0 reset (single-aspect subtask) инжектнут в STATE."
    }
  }

  # M-13/O: lazy-cache reference-digest + инжект <reference-digest> блока.
  # Маппинг slug → screen name из task-scope: stack→ScreenServices, pulse/*→ScreenPulse, и т.д.
  $screenMap = @{
    'stack' = 'ScreenServices'; 'pulse/today' = 'ScreenPulse'; 'pulse/tomorrow' = 'ScreenPulse';
    'pulse/yesterday' = 'ScreenPulse'; 'spotlight' = 'ScreenSpotlight'; 'projects' = 'ScreenProjects';
    'tasks' = 'ScreenTasks'; 'settings' = 'ScreenSettings'
  }
  try {
    $tsForDigest = if ($tf) { Read-TaskScope -TaskFile $tf.FullName } else { $null }
    if ($tsForDigest -and $tsForDigest.vision_slugs.Count -gt 0 -and $tsForDigest.vision_slugs[0] -ne '__none__') {
      $primarySlug = $tsForDigest.vision_slugs[0]
      $screenName = $screenMap[$primarySlug]
      if ($screenName) {
        $digestMd = Get-OrCreate-ReferenceDigest -Repo $root -TaskId $focus -ScreenName $screenName -ScopeSlug $primarySlug
        if ($digestMd) { Inject-ReferenceDigest -StateFile $stateFile -DigestMdFile $digestMd }
      }
    }
  } catch { Log "reference-digest inject failed (non-fatal): $($_.Exception.Message)" }

  # M-13/N: инжект <visual-context> с reference + current скриншотами.
  # Берём slug'и из task-scope (если есть) или из всех TARGETS.
  try {
    $tsForVisual = if ($tf) { Read-TaskScope -TaskFile $tf.FullName } else { $null }
    $slugsForVisual = if ($tsForVisual -and $tsForVisual.vision_slugs.Count -gt 0 -and $tsForVisual.vision_slugs[0] -ne '__none__') {
      $tsForVisual.vision_slugs
    } else { @() }
    if ($slugsForVisual.Count -gt 0) {
      Inject-VisualContext -StateFile $stateFile -Repo $root -Slugs $slugsForVisual -MaxPairs 4
    }
  } catch { Log "visual-context inject failed (non-fatal): $($_.Exception.Message)" }

  # M-13/P: structural breakdown — SSIM<0.5 → redo-from-scratch инструкция.
  try {
    $vstatus = Get-VisionStructuralStatus -Repo $root
    if ($vstatus -and $vstatus.has_breakdown) {
      Inject-RedoFromScratch -StateFile $stateFile -TaskId $focus `
        -Breakdowns $vstatus.breakdowns -ItersWithoutPass $script:itersWithoutPass
      Append-Event -EventType 'redo-from-scratch-triggered' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ worst_ssim = $vstatus.worst_ssim; breakdowns_count = $vstatus.breakdowns.Count }
    }
  } catch { Log "redo-trigger failed (non-fatal): $($_.Exception.Message)" }

  # 1. Агент выполняет один шаг — с таймаутом на итерацию.
  $timedOut = $false
  $networkStall = $false
  $launchErr = ""
  # M-09 verbosity (2026-05-25, итерация #7): pipe→pwsh→oc-pretty не работал, потому
  # что opencode/node block-буферизует stdout, когда он не TTY — ReadLine получал 0
  # строк часами. Решение: opencode пишет stdout в файл через -RedirectStandardOutput
  # (kernel-level, без user-space pipe-буфера), а loop.ps1 в poll-loop читает дельту
  # байт каждые 3 сек, парсит JSON-события сам и печатает в окно цветом.
  # Команда агента из шаблона config (agent.command). {model} → $Model; если модель пуста,
  # выкидываем '--model {model}' целиком (бэкенд берёт дефолт). Промпт ($p) — позиционным арг.
  if ($Model) { $resolvedAgentCmd = $AgentCmdTpl -replace '\{model\}', $Model }
  else        { $resolvedAgentCmd = (($AgentCmdTpl -replace '--model\s+\{model\}', '') -replace '\{model\}', '').Trim() -replace '\s{2,}', ' ' }
  $runCmd      = "& $resolvedAgentCmd `$p"
  $utf8Prefix  = "[Console]::InputEncoding=[Text.Encoding]::UTF8;[Console]::OutputEncoding=[Text.Encoding]::UTF8;`$OutputEncoding=[Text.Encoding]::UTF8;"
  $inner       = "$utf8Prefix `$p = Get-Content -Raw -LiteralPath '$promptFile'; $runCmd"
  $ocOutFile   = Join-Path $root ".bcf\iter-$i.out.jsonl"
  $ocErrFile   = Join-Path $root ".bcf\iter-$i.err.log"
  Remove-Item $ocOutFile, $ocErrFile -ErrorAction SilentlyContinue
  # Префлайт связи: не запускаем opencode в мёртвую сеть — иначе SSE-стрим модели
  # сразу зависнет и сгорит в watchdog. Если интернета нет — ждём его здесь.
  if (-not (Test-Connectivity -NetHost $NetProbeHost -Port $NetProbePort)) {
    Wait-ForConnectivity -NetHost $NetProbeHost -Port $NetProbePort -MaxWaitSec $NetWaitMaxSec -Iteration $i -FocusTask $focus | Out-Null
  }
  $iterStartTs = (Get-Date).ToUniversalTime()
  try {
    $proc = Start-Process -FilePath 'pwsh' `
      -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $inner) `
      -WorkingDirectory $root -NoNewWindow -PassThru `
      -RedirectStandardOutput $ocOutFile -RedirectStandardError $ocErrFile
    if (-not $proc) { throw "Start-Process не вернул процесс" }
    # Live-парсер JSON-событий + heartbeat. Каждые 3s читаем дельту байт из $ocOutFile,
    # парсим построчно через Render-OcLine (из lib/oc-render.ps1). Каждые 30s — heartbeat
    # на случай если opencode молчит дольше нормы.
    $hbInterval     = 30
    $nextHb         = $hbInterval
    $nextNetProbe   = $StreamStallSec   # раньше этого момента стрим-молчание не проверяем
    $lastShownBytes = 0
    $eventsRendered = 0
    # Активность агента — из JSON-событий (а не из устаревшего permission-лога opencode).
    $lastActivity     = '(старт — модель загружает контекст)'
    $lastActivityTs   = (Get-Date).ToUniversalTime()
    $lastShownActivity = ''   # для дедупа heartbeat (не печатать одну и ту же фразу 5 раз подряд)
    while (-not $proc.WaitForExit(3000)) {
      $elapsed = [int]((Get-Date).ToUniversalTime() - $iterStartTs).TotalSeconds
      if ($elapsed -ge $IterTimeoutSec) {
        $timedOut = $true
        Log "Итерация ${i}: opencode run превысил ${IterTimeoutSec}s — принудительный kill."
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit(5000) | Out-Null
        Append-Event -EventType 'opencode-timeout' -TaskId $focus -Phase 'A/B' -Iteration $i `
          -Payload @{ timeout_sec = $IterTimeoutSec; last_bash_cmd = (Get-LastOpencodeCommand) }
        break
      }
      # Сетевой watchdog: стрим молчит дольше $StreamStallSec И эндпоинт модели недоступен →
      # обрыв связи. Не ждём весь IterTimeoutSec (мёртвый эфир): убиваем сразу, потом
      # дождёмся интернета и ПОВТОРИМ итерацию. Пробуем не чаще раза в 15s.
      $silentFor = [int]((Get-Date).ToUniversalTime() - $lastActivityTs).TotalSeconds
      if ($silentFor -ge $StreamStallSec -and $elapsed -ge $nextNetProbe) {
        $nextNetProbe = $elapsed + 15
        if (-not (Test-Connectivity -NetHost $NetProbeHost -Port $NetProbePort)) {
          $networkStall = $true
          Log "Итерация ${i}: стрим молчит ${silentFor}s И ${NetProbeHost}:${NetProbePort} недоступен — обрыв связи. Убиваю opencode, дождусь интернета и повторю итерацию."
          try { $proc.Kill($true) } catch { }
          $proc.WaitForExit(5000) | Out-Null
          Append-Event -EventType 'network-stall-kill' -TaskId $focus -Phase 'A/B' -Iteration $i `
            -Payload @{ silent_for_sec = $silentFor; elapsed_sec = $elapsed; host = $NetProbeHost }
          break
        }
      }
      # Дельта-чтение нового куска stdout opencode.
      if (Test-Path $ocOutFile) {
        $fi = Get-Item $ocOutFile -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt $lastShownBytes) {
          try {
            $fs = [System.IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite')
            $fs.Seek($lastShownBytes, 'Begin') | Out-Null
            $delta = $fi.Length - $lastShownBytes
            $buf = New-Object byte[] $delta
            [void]$fs.Read($buf, 0, $delta)
            $fs.Close()
            $chunk = [System.Text.Encoding]::UTF8.GetString($buf)
            # Если предыдущий tick оставил незавершённую строку — её начало в файле дальше;
            # для простоты: парсим все полные строки, остаток (без \n в конце) переносим
            # на следующий tick через корректировку $lastShownBytes.
            $lines = $chunk -split "`r?`n"
            $tailIncomplete = ''
            if (-not $chunk.EndsWith("`n")) {
              $tailIncomplete = $lines[-1]
              $lines = $lines[0..($lines.Count - 2)]
            }
            foreach ($ln in $lines) {
              if ([string]::IsNullOrWhiteSpace($ln)) { continue }
              # Параллельно с рендером — вытаскиваем «что делает агент» для heartbeat'а.
              try {
                $ev = $ln | ConvertFrom-Json -ErrorAction Stop
                switch ([string]$ev.type) {
                  'tool_use' {
                    $tn = [string]$ev.part.tool
                    $hint = ''
                    $inp = $ev.part.state.input
                    if ($tn -eq 'bash' -and $inp.description) { $hint = [string]$inp.description }
                    elseif ($inp.filePath)  { $hint = [string]$inp.filePath }      # camelCase (некоторые бэкенды)
                    elseif ($inp.file_path) { $hint = [string]$inp.file_path }
                    elseif ($inp.pattern)   { $hint = [string]$inp.pattern }
                    elseif ($inp.command)   { $hint = [string]$inp.command }
                    $lastActivity = "$tn — $hint"
                    $lastActivityTs = (Get-Date).ToUniversalTime()
                  }
                  'text'      { $lastActivity = "пишет ответ"; $lastActivityTs = (Get-Date).ToUniversalTime() }
                  'reasoning' { $lastActivity = "думает (reasoning)"; $lastActivityTs = (Get-Date).ToUniversalTime() }
                  'step_finish' { } # silent — sсам по себе не активность, активность это tool/text/reasoning
                  'step_start'  { } # silent
                }
              } catch { }
              Render-OcLine $ln -Color
              $eventsRendered++
            }
            $lastShownBytes = $fi.Length - [System.Text.Encoding]::UTF8.GetByteCount($tailIncomplete)
          } catch {
            # файл занят / гонка чтения — попробуем на следующем tick
          }
        }
      }
      if ($elapsed -ge $nextHb) {
        $sinceActivity = [int]((Get-Date).ToUniversalTime() - $lastActivityTs).TotalSeconds
        # Печатаем только если активность изменилась с прошлого heartbeat ИЛИ молчит >60s.
        $changed = ($lastActivity -ne $lastShownActivity)
        $silent  = ($sinceActivity -gt 60)
        if ($changed -or $silent) {
          $hint = if ($lastActivity.Length -gt 110) { $lastActivity.Substring(0, 110) + '…' } else { $lastActivity }
          $silentNote = if ($silent) { " (молчит ${sinceActivity}s)" } else { '' }
          Write-Host ("[{0}] {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $hint, $silentNote) -ForegroundColor DarkGray
          $lastShownActivity = $lastActivity
        }
        $nextHb += $hbInterval
      }
    }
    # Финальный drain: что осталось не прочитано после exit.
    if (Test-Path $ocOutFile) {
      $fi = Get-Item $ocOutFile -ErrorAction SilentlyContinue
      if ($fi -and $fi.Length -gt $lastShownBytes) {
        try {
          $fs = [System.IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite')
          $fs.Seek($lastShownBytes, 'Begin') | Out-Null
          $buf = New-Object byte[] ($fi.Length - $lastShownBytes)
          [void]$fs.Read($buf, 0, $buf.Length)
          $fs.Close()
          foreach ($ln in ([System.Text.Encoding]::UTF8.GetString($buf) -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($ln)) { Render-OcLine $ln -Color; $eventsRendered++ }
          }
        } catch { }
      }
    }
    Append-Event -EventType 'opencode-run' -TaskId $focus -Phase 'A/B' -Iteration $i `
      -Payload @{ duration_sec = ((Get-Date).ToUniversalTime() - $iterStartTs).TotalSeconds; timed_out = $timedOut; exit_code = $proc.ExitCode }
  } catch {
    $launchErr = $_.Exception.Message
    Log "Итерация ${i}: НЕ УДАЛОСЬ запустить opencode — $launchErr"
    Append-Event -EventType 'launch-failed' -TaskId $focus -Phase 'A/B' -Iteration $i `
      -Payload @{ error = $launchErr }
  }

  # Boundary-sentinel: новые sibling-папки = запись агента вне проекта → нарушение границы.
  try {
    $siblingsAfter = @(Get-ChildItem -LiteralPath $repoParent -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne $repoLeaf } | Select-Object -ExpandProperty Name)
    $newSiblings = @($siblingsAfter | Where-Object { $siblingsBefore -notcontains $_ })
    if ($newSiblings.Count -gt 0) {
      foreach ($ns in $newSiblings) {
        Log "⚠️ BOUNDARY-VIOLATION: итерация $i создала папку вне проекта: $repoParent\$ns"
      }
      Append-Event -EventType 'boundary-violation' -TaskId $focus -Phase 'A/B' -Iteration $i `
        -Payload @{ parent = $repoParent; new_dirs = $newSiblings }
    }
  } catch { }

  # ── Возобновление после обрыва связи. Watchdog убил зависший стрим: НЕ гоняем гейты
  # на частичной работе и НЕ тратим бюджет итераций. Ждём интернет и ПОВТОРЯЕМ ту же
  # итерацию — правки агента уже в working-tree, opencode-сессия stateless, следующий
  # прогон продолжит с того же состояния. Защита от флаппинга: после $NetStallRetryMax
  # обрывов подряд перестаём ретраить и засчитываем как обычный таймаут (бюджет ограничит).
  if ($networkStall) {
    Wait-ForConnectivity -NetHost $NetProbeHost -Port $NetProbePort -MaxWaitSec $NetWaitMaxSec -Iteration $i -FocusTask $focus | Out-Null
    if ($netStallRetry -lt $NetStallRetryMax) {
      $netStallRetry++
      Log "Итерация ${i}: обрыв связи — интернет восстановлен, повтор итерации (retry $netStallRetry/$NetStallRetryMax, бюджет не тратится)."
      Append-Event -EventType 'iter-net-retry' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ retry = $netStallRetry; max = $NetStallRetryMax }
      $i--   # for-loop сделает $i++ → тот же номер итерации → честный повтор
      continue
    }
    Log "Итерация ${i}: $NetStallRetryMax обрывов подряд (сеть флаппит) — не зацикливаюсь, засчитываю как таймаут."
    Append-Event -EventType 'net-retry-exhausted' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ max = $NetStallRetryMax }
    $timedOut = $true   # дальше обычная ветка (gates + advance); MaxIterations ограничит
  } else {
    $netStallRetry = 0  # нормальный прогон (не обрыв) — сбрасываем счётчик повторов
  }

  if ($launchErr -ne "") {
    $launchFailCount++
    if ($launchFailCount -ge 2) {
      Log "opencode не запускается 2 итерации подряд — ОСТАНОВКА."
      Set-Content $stateFile ("# Ralph STATE`n`n## Итерация $i — LAUNCH FAILED`n`n" +
        "opencode не запускается:`n$launchErr`n`n" +
        "Проверь вручную из корня репозитория:`n  pwsh -NoProfile -Command `"& opencode --version`"`n" +
        "Убедись, что opencode и pwsh в PATH. Раннер остановлен.") -Encoding UTF8
      Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ reason = 'launch-failed-twice'; error = $launchErr }
      Notify-Stop 'warn' "opencode не запускается" "opencode не стартует 2 итерации подряд. Цикл остановлен — нужно вмешательство."
      break
    }
  } else {
    $launchFailCount = 0
  }

  # 2. Backpressure
  $bp = @()
  if ($timedOut) {
    # Не вали вину на безобидную команду, если оборвался шаг ГЕНЕРАЦИИ модели
    # (последнее событие стрима — reasoning/step_start, без результата тула). Это
    # почти всегда обрыв связи/висящий SSE <model>, а не зависший shell-процесс.
    $stallKind = Get-IterStallKind -JsonlPath $ocOutFile
    if ($stallKind -eq 'model') {
      $bp += @"
opencode run TIMEOUT (${IterTimeoutSec}s) — итерация убита по таймауту.
Причина — НЕ shell-команда: стрим оборвался на шаге генерации модели (последнее событие — reasoning/step_start, без результата инструмента). Обычно это обрыв связи или висящий SSE-стрим <model>, а не зависший процесс.
Действия следующей итерации:
1. НЕ ищи «зависшую команду» — её нет. Продолжай задачу с текущего состояния working-tree.
2. Делай шаги короче (меньше тулзов за проход), чтобы итерация укладывалась в таймаут.
"@
    } else {
      $lastCmd = Get-LastOpencodeCommand
      $culprit = if ($lastCmd) { "Последняя запущенная команда (возможный виновник зависания): ``$lastCmd``." } else { "Команду-виновника определить не удалось — см. лог opencode." }
      $bp += @"
opencode run TIMEOUT (${IterTimeoutSec}s) — итерация убита по таймауту.
$culprit
Если это тяжёлая команда — НЕ запускай её вслепую снова.
Действия следующей итерации:
1. Определи, что именно зависает (команда выше).
2. Если это поломка инфраструктуры — это БЛОКЕР: заведи subtask на починку, не повторяй зависший шаг.
3. Для быстрой проверки пока используй лёгкие команды (``tsc --noEmit``), не тяжёлый прогон.
"@
    }
  }
  if ($launchErr -ne "") {
    $bp += "ЗАПУСК opencode ПРОВАЛЕН: $launchErr"
  }
  $tscOut = & npx --no-install tsc --noEmit 2>&1
  $tscExit = $LASTEXITCODE
  if ($tscExit -ne 0) {
    $bp += "tsc --noEmit FAILED (exit $tscExit):`n" + (($tscOut | Select-Object -Last 12) -join "`n")
    Append-Event -EventType 'tsc-failed' -TaskId $focus -Phase 'B' -Iteration $i `
      -Payload @{ exit_code = $tscExit; tail = (($tscOut | Select-Object -Last 5) -join "`n") }
  }

  # M-09 E: tsc-clean → tsc-broken = регрессия. Откатываем правки итерации к pre-iter snapshot.
  # Default on (M-09 E, опт-аут через -NoAutoRollback). Стэш-объект из stash create
  # содержит diff working-tree + index; checkout его дерева вернёт файлы в pre-iter состояние.
  # SAFETY: откатываемся ТОЛЬКО к свежему snapshot'у (stash-create объект),
  # который отличается от HEAD. Если stash create дал пусто и preIterTreeRef
  # свалился в fallback `rev-parse HEAD`, checkout вернул бы дерево к старому
  # HEAD и уничтожил все uncommitted-правки (дни работы). Тогда — не откатываем.
  $headSha = (& git -C $root rev-parse HEAD 2>$null | Out-String).Trim()
  if ((-not $NoAutoRollback) -and $tscExit -ne 0 -and $lastTscExit -eq 0 -and $preIterTreeRef -and ($preIterTreeRef -ne $headSha)) {
    Log "REGRESSION: tsc был чист на iter $($i-1), сломан на iter $i. Откат до $preIterTreeRef."
    $regrDiff = (& git diff $preIterTreeRef HEAD --stat 2>$null | Out-String).Trim()
    # checkout всех файлов из snapshot обратно в working-tree
    & git checkout $preIterTreeRef -- . 2>&1 | Out-Null
    Append-Event -EventType 'iter-rolled-back' -TaskId $focus -Phase 'B' -Iteration $i `
      -Payload @{ reason = 'tsc-regression'; pre_iter_ref = $preIterTreeRef; rolled_diff_stat = $regrDiff }
    $bp += "AUTO-ROLLBACK: твои правки сломали tsc (был exit=0, стал exit=$tscExit). Раннер откатил working-tree до состояния начала этой итерации. Diff отката:`n$regrDiff`nДействия: НЕ повторяй те же правки. Сначала reproduce проблему минимальным шагом, потом точечный фикс."
    # после отката пересчитываем tsc — для $lastTscExit на следующую итерацию
    $tscOut = & npx --no-install tsc --noEmit 2>&1
    $tscExit = $LASTEXITCODE
  }
  $lastTscExit = $tscExit
  if ($hasBash) {
    $dgOut = & bash ".claude/hooks/done-gate.sh" 2>&1
    if ($LASTEXITCODE -ne 0) {
      $bp += "done-gate.sh BLOCK (exit $LASTEXITCODE):`n" + (($dgOut | Select-Object -Last 10) -join "`n")
      Append-Event -EventType 'done-gate-blocked' -TaskId $focus -Phase 'B' -Iteration $i `
        -Payload @{ exit_code = $LASTEXITCODE }
    }
  }

  # W4: lint-gate (Ryan Lepo + Armin Ronacher — mechanical enforcement через lint).
  $lintOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'lint-gate.ps1') -Repo $root 2>&1 | Out-String
  if ($LASTEXITCODE -eq 1) {
    $bp += "LINT-GATE FAIL — исправь до VERIFY-REQUEST:`n" + (($lintOut -split "`n" | Select-Object -First 40) -join "`n")
    Append-Event -EventType 'lint-violation' -TaskId $focus -Phase 'B' -Iteration $i `
      -Payload @{ tail = ($lintOut.Substring(0, [Math]::Min(500, $lintOut.Length))) }
  }

  # M-13 C (2026-05-27): subagent-finding-gate. Берёт remediation из ПРЕДЫДУЩЕГО
  # verdict-файла (must_address), сверяет с diff текущей итерации. Если ни один из
  # remediation pp не покрыт правкой, и нет verifiable dismiss — блокируем verify.
  # Это ловит iter-5-style «Layout table fix deferred to next iteration».
  try {
    $gateCode = Invoke-FindingGate -TaskId $focus -Iteration $i -IterOutJsonl $ocOutFile
    if ($gateCode -ne 0) {
      $bp += "M-13 finding-gate BLOCK: предыдущая ремедиация не покрыта в diff и нет verifiable dismiss. Исправь по списку из tasks/.verdicts/$focus.md (remediation) либо добавь TODO с issue id и условием снятия."
      Append-Event -EventType 'finding-gate-blocked' -TaskId $focus -Phase 'B' -Iteration $i `
        -Payload @{ exit_code = $gateCode }
    }
  } catch { Log "M-13 finding-gate failed (non-fatal): $($_.Exception.Message)" }

  # M-09 (2026-05-25, фикс A+B): если backpressure не чист — не зовём человека и
  # не запускаем верификацию на заведомо плохом коде. Сначала агент чинит tsc/lint/done-gate,
  # потом — friction-trigger и verify. Раньше: human-callout прилетал на broken-syntax
  # коммит (TASK-03 iter=2), а judge крутился на dirty-bp коде (TASK-03 iter=1).
  $verifyMarker = Join-Path $root ".bcf\VERIFY-REQUEST"
  if ($bp.Count -gt 0) {
    if (Test-Path $verifyMarker) {
      Remove-Item $verifyMarker -Force -ErrorAction SilentlyContinue
      Log "VERIFY-REQUEST снят: backpressure не чист — сначала фикс tsc/lint/done-gate."
      Append-Event -EventType 'verify-suppressed' -TaskId $focus -Phase 'B' -Iteration $i `
        -Payload @{ reason = 'backpressure-not-clean'; bp_count = $bp.Count }
      $bp += "VERIFY-REQUEST снят раннером: backpressure не чист (см. ошибки выше). Исправь их, потом снова создавай маркер."
    }
    Log "Triggers/verify пропущены (backpressure не чист, $($bp.Count) ошибок) — сначала фикс."
  } else {
    # W4: friction-triggers (D9 — human-callout на DB migrations / auth / deps / configs).
    # Per-task allowlist + per-iter diff base (M-09 26-05): -BaseRef $preIterTreeRef ⇒
    # triggers видит только правки этой итерации, а не pre-existing uncommitted.
    $trigArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'triggers.ps1'), '-Repo', $root, '-TaskId', $focus, '-Iteration', $i)
    if ($preIterTreeRef) { $trigArgs += @('-BaseRef', $preIterTreeRef) }
    $trigOut = & pwsh @trigArgs 2>&1 | Out-String
    $trigExit = $LASTEXITCODE
    if ($trigExit -eq 2) {
      Log "FRICTION-TRIGGER — Ralph пауза. См. .bcf/human-callout.md."
      Set-Content $stateFile ("# Ralph STATE`n`n## Итерация $i — HUMAN CALLOUT`n`n" + $trigOut) -Encoding UTF8
      Notify-Stop 'warn' "$focus требует human-callout" "Изменения затронули критичные пути (migrations/auth/deps/configs). Ralph остановлен — нужно твоё ревью."
      break
    } elseif ($trigExit -ne 0) {
      Log "triggers.ps1 вернул код $trigExit (внутренняя ошибка) — продолжаем."
    }
  }

  # 2.5. Фазы C-E — агент попросил верификацию (маркер .bcf/VERIFY-REQUEST).
  if (Test-Path $verifyMarker) {
    # M-13/F (2026-05-27) idempotency-гейт: если diff vs HEAD не изменился с прошлой
    # !PASS-верификации — переиспользуем прошлый вердикт, не сжигаем 20 минут на
    # vision+judge для того же кода. Обход: `# stale-verdict-ignored` в маркере
    # (как уже было, см. verify.ps1 line 322).
    $vfPath = Join-Path $root "tasks\.verdicts\$focus.md"
    $markerText = (Get-Content -Raw -LiteralPath $verifyMarker -ErrorAction SilentlyContinue)
    $forceRerun = ($markerText -match '(?m)^\s*#\s*stale-verdict-ignored\b')
    $skipVerify = $false

    # M-13/G (2026-05-27, исправлено 23:00): product-code-changed гейт.
    # БЛОКИРУЕМ verify ТОЛЬКО если: (а) есть prev !PASS verdict (значит remediation
    # уже выдана и агент должен её закрыть), И (б) эта итерация не правила продуктовый
    # код. Если verdict отсутствует (после throw-out / первая верификация) или PASS —
    # verify должен пройти, даже без новых правок (легитимный «подтверди готовность»).
    $hasPrev = Test-Path $vfPath
    $prevIsNotPass = $false
    if ($hasPrev) {
      $pTxt = Get-Content -Raw -LiteralPath $vfPath
      $pV = ''
      if ($pTxt -match '(?m)^verdict:\s*(\S+)') { $pV = $Matches[1] }
      $jOutP = Join-Path $root ".bcf\verify\$focus-$($JudgeName).out.txt"
      if (Test-Path $jOutP) {
        $jtP = Get-Content -Raw -LiteralPath $jOutP
        $jmP = [regex]::Match($jtP, '(?s)\{(?:[^{}]|\{[^{}]*\})*"verdict"\s*:\s*"[^"]+"(?:[^{}]|\{[^{}]*\})*\}')
        if ($jmP.Success) { try { $pV = ($jmP.Value | ConvertFrom-Json).verdict } catch { } }
      }
      $prevIsNotPass = ($pV -and ($pV -notmatch '(?i)^PASS$'))
    }
    # prodChanges считаем всегда (нужно и для блока, и для vision auto-detect).
    $productPaths = $ProductPaths
    $prodChanges = @()
    if ($preIterTreeRef) {
      $prodDiffArgs = @('-C', $root, 'diff', '--name-only', $preIterTreeRef, '--') + $productPaths
      $prodChanges = @((& git @prodDiffArgs 2>$null | Where-Object { $_ -and $_.Trim() }))
    }
    # FIX (2026-05-31): git diff <snapshot> НЕ видит untracked-файлы. У TASK-задач продуктовый
    # код может быть untracked (напр. целиком src/pages/skills/), и правки в нём были невидимы
    # детектору → ложный «product-code-unchanged» → verify-skip → ложный failing-set stall.
    # Консервативно: если под product-paths есть ЛЮБЫЕ untracked-файлы, не можем доказать
    # «не менялось» → НЕ пропускаем verify (ошибаемся в сторону прогона, не в сторону stall).
    # Защита от stall сохраняется: реальный затык всё равно ловится failing-set/no-progress.
    $prodUntrackedArgs = @('-C', $root, 'ls-files', '--others', '--exclude-standard', '--') + $productPaths
    $prodUntracked = @((& git @prodUntrackedArgs 2>$null | Where-Object { $_ -and $_.Trim() }))
    if ($prodUntracked.Count -gt 0) { $prodChanges = @($prodChanges + $prodUntracked | Select-Object -Unique) }
    if ((-not $forceRerun) -and $preIterTreeRef -and $prevIsNotPass) {
      if (-not $prodChanges -or $prodChanges.Count -eq 0) {
        $skipVerify = $true
        Log "verify пропущен (product-code-unchanged + есть prev !PASS verdict): итерация не правила продуктовый код (src/, electron/, backend/ — tracked+untracked) относительно pre-iter snapshot $($preIterTreeRef.Substring(0,[Math]::Min(8,$preIterTreeRef.Length)))."
        Remove-Item $verifyMarker -Force -ErrorAction SilentlyContinue
        Append-Event -EventType 'verify-skipped-no-product-change' -TaskId $focus -Phase 'C-E' -Iteration $i `
          -Payload @{ pre_iter_ref = $preIterTreeRef }
        $bp += "VERIFY-REQUEST игнорирован раннером: есть прошлый !PASS вердикт, а эта итерация не правила продуктовый код (src/, electron/, backend/). " +
               "Verify бесполезен на тех же бинарниках. Сначала ПРАВЬ КОД по списку remediation в tasks/.verdicts/$focus.md, " +
               "затем создавай VERIFY-REQUEST заново. Если ремедиация уже невалидна — добавь '# stale-verdict-ignored' в VERIFY-REQUEST."
      }
      # M-13/J (2026-05-27): three-level scope. Task-scope из «## 3.1. Scope» —
      # авторитетный bounded box задачи. Если секция есть, её vision_slugs/testers
      # подставляем напрямую (вне зависимости от iter-diff). Также проверяем
      # scope-creep: правки агента в файлы вне task.paths → warning в backpressure.
      $taskScope = if ($tf) { Read-TaskScope -TaskFile $tf.FullName } else { $null }
      $isReleaseRegr = ($markerText -match '(?m)^\s*regression:\s*release\b')

      # Scope-creep detector — правки вне task.paths.
      if ($taskScope -and $taskScope.paths.Count -gt 0 -and $prodChanges.Count -gt 0) {
        $outOfScope = @()
        foreach ($f in $prodChanges) {
          if (-not (ScopePath-Matches -File $f -Globs $taskScope.paths)) { $outOfScope += $f }
        }
        if ($outOfScope.Count -gt 0) {
          $list = ($outOfScope | Select-Object -First 8) -join ', '
          Log "scope-creep: $($outOfScope.Count) файла(ов) вне task scope: $list"
          Append-Event -EventType 'scope-creep-warning' -TaskId $focus -Phase 'B' -Iteration $i `
            -Payload @{ out_of_scope = $outOfScope; task_paths = $taskScope.paths }
          $bp += "Scope-creep warning: эта итерация правит файлы вне scope задачи (см. ## 3.1. Scope в task-файле). " +
                 "Файлы вне scope: $list. Либо переформулируй цель iter ровно в scope, либо обнови ## 3.1. Scope (если границы реально расширились). " +
                 "Это warning, не блок."
        }
      }

      # Vision scope из task-scope (если есть). Без task-scope — fallback на auto-detect из diff.
      if (-not $skipVerify) {
        $hasSlugs   = ($markerText -match '(?m)^\s*vision_slugs:\s*\S')
        $isFullRegr = ($markerText -match '(?m)^\s*regression:\s*(full|release)\b')
        if (-not $hasSlugs -and -not $isFullRegr -and $taskScope -and $taskScope.vision_slugs.Count -gt 0) {
          $slugs = $taskScope.vision_slugs
          # __none__ как явное «не UI» — оставляем как есть.
          Log "vision scope: из task ## 3.1. Scope → slugs=[$($slugs -join ', ')] (module=$($taskScope.module))."
          Add-Content -LiteralPath $verifyMarker -Value ("vision_slugs: " + ($slugs -join ' '))
          Append-Event -EventType 'vision-scope-task' -TaskId $focus -Phase 'C-E' -Iteration $i `
            -Payload @{ source = 'task-scope'; module = $taskScope.module; slugs = $slugs }
          $hasSlugs = $true
        }
      }
      # Fallback auto-detect из diff — только если task-scope не задан И slugs/regr не указаны явно.
      if (-not $skipVerify -and -not $taskScope -and $prodChanges.Count -gt 0) {
        $hasSlugs   = ($markerText -match '(?m)^\s*vision_slugs:\s*\S')
        $isFullRegr = ($markerText -match '(?m)^\s*regression:\s*(full|release)\b')
        if (-not $hasSlugs -and -not $isFullRegr) {
          $mapFile = Join-Path $root 'config\scope-map.json'
          if (Test-Path $mapFile) {
            try {
              $map = (Get-Content -Raw -LiteralPath $mapFile | ConvertFrom-Json).vision
              $changed = $prodChanges -join "`n"
              $shared = $false
              foreach ($p in $map.shared.patterns) { if ($changed -match [regex]::Escape($p)) { $shared = $true; break } }
              $detected = @()
              if (-not $shared) {
                foreach ($rule in $map.rules) {
                  foreach ($p in $rule.patterns) {
                    if ($changed -match [regex]::Escape($p)) { $detected += $rule.slug; break }
                  }
                }
                $detected = @($detected | Select-Object -Unique)
              }
              if ($shared) {
                Log "vision scope: shared path в diff → полный регресс Фазы D."
                Add-Content -LiteralPath $verifyMarker -Value "regression: full"
              } elseif ($detected.Count -gt 0) {
                Log "vision scope: auto-detected slugs=[$($detected -join ', ')] (regression=incremental)."
                Add-Content -LiteralPath $verifyMarker -Value ("vision_slugs: " + ($detected -join ' '))
              } else {
                Log "vision scope: правки не маппятся на vision-slug-map → пропускаем Фазу D (vision_slugs: __none__)."
                # Спец-маркер: пустая выдача. verify.ps1 увидит vision_slugs: __none__ и не запустит сьют — экономит ~10 мин.
                Add-Content -LiteralPath $verifyMarker -Value "vision_slugs: __none__"
              }
              Append-Event -EventType 'vision-scope-auto' -TaskId $focus -Phase 'C-E' -Iteration $i `
                -Payload @{ shared = $shared; detected = $detected; changed_files = $prodChanges.Count }
            } catch {
              Log "vision-slug-map.json parse error (non-fatal): $($_.Exception.Message)"
            }
          }
        }
      }

      # M-13/J + L (2026-05-28): двухступенчатый tester scope.
      #   1) Потолок — task.testers из ## 3.1. Scope (max testers задачи).
      #   2) Iter-level фильтр — пересекаем с tester-scope-map.json по prodChanges.
      #      UI-only iter (только src/pages/**, src/components/**) → ни архитектор,
      #      ни api не нужны: они смотрят слой/IPC, ничего общего с вёрсткой.
      # Override: '# all-testers' или regression: release.
      if ($taskScope -and $taskScope.testers.Count -gt 0 -and -not $isReleaseRegr -and ($markerText -notmatch '(?m)^\s*#\s*all-testers\b')) {
        # Ступень 1: task ceiling.
        $relevantTesters = $taskScope.testers

        # Ступень 2: iter-level filter по prodChanges.
        if ($prodChanges.Count -gt 0) {
          $tMapFile = Join-Path $root 'config\scope-map.json'
          if (Test-Path $tMapFile) {
            try {
              $tMap = [pscustomobject]@{ rules = (Get-Content -Raw -LiteralPath $tMapFile | ConvertFrom-Json).testers }
              $changedStr = $prodChanges -join "`n"
              $iterRelevant = @()
              foreach ($rule in $tMap.rules) {
                foreach ($p in $rule.patterns) {
                  if ($changedStr -match [regex]::Escape($p)) { $iterRelevant += $rule.tester; break }
                }
              }
              # Пересекаем: tester должен быть И в task.testers, И релевантен iter.
              $relevantTesters = @($relevantTesters | Where-Object { $iterRelevant -contains $_ })
              if ($relevantTesters.Count -eq 0 -and $taskScope.testers.Count -gt 0) {
                Log "tester scope: iter-level filter оставил 0 тестеров из task.testers=[$($taskScope.testers -join ', ')] (iter правит только UI/non-tester-paths). Фаза C полностью пропущена."
              }
            } catch {
              Log "tester-scope-map.json parse error (non-fatal): $($_.Exception.Message)"
            }
          }
        }

        $currentTesters = @()
        foreach ($mline in ($markerText -split "`r?`n")) {
          if ($mline -match '^\s*testers:\s*(.+)$') { $currentTesters += ($Matches[1] -split '[,\s]+' | Where-Object { $_ }) }
        }
        $currentTesters = @($currentTesters | Select-Object -Unique)
        $keepTesters = @($currentTesters | Where-Object { $relevantTesters -contains $_ })
        $strippedTesters = @($currentTesters | Where-Object { $relevantTesters -notcontains $_ })
        if ($strippedTesters.Count -gt 0 -or $keepTesters.Count -ne $currentTesters.Count) {
          Log "tester scope: из task ## 3.1. Scope → kept=[$($keepTesters -join ', ')], stripped=[$($strippedTesters -join ', ')]."
          $newMarker = (($markerText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*testers:\s*' }) -join "`n"
          if ($keepTesters.Count -gt 0) {
            $newMarker += "`ntesters: " + ($keepTesters -join ' ')
          } else {
            # Все стрипнуты — явный sentinel, чтобы verify.ps1 не активировал дефолт-набор.
            $newMarker += "`ntesters: __none__"
          }
          Set-Content -LiteralPath $verifyMarker -Value $newMarker -Encoding UTF8
          $markerText = $newMarker
          Append-Event -EventType 'tester-scope-task' -TaskId $focus -Phase 'C-E' -Iteration $i `
            -Payload @{ source = 'task-scope'; kept = $keepTesters; stripped = $strippedTesters }
        }
      }
      # M-13/I (2026-05-27): fallback tester-scope-map (auto-detect из diff) — для задач без ## 3.1. Scope.
      elseif (-not $taskScope -and $prodChanges.Count -gt 0 -and ($markerText -notmatch '(?m)^\s*#\s*all-testers\b')) {
        $tMapFile = Join-Path $root 'config\tester-scope-map.json'
        if (Test-Path $tMapFile) {
          try {
            $tMap = Get-Content -Raw -LiteralPath $tMapFile | ConvertFrom-Json
            $changedStr = $prodChanges -join "`n"
            $relevantTesters = @()
            foreach ($rule in $tMap.rules) {
              foreach ($p in $rule.patterns) {
                if ($changedStr -match [regex]::Escape($p)) { $relevantTesters += $rule.tester; break }
              }
            }
            $relevantTesters = @($relevantTesters | Select-Object -Unique)
            # Парсим существующий testers: из маркера и пересекаем с relevant.
            $currentTesters = @()
            foreach ($mline in ($markerText -split "`r?`n")) {
              if ($mline -match '^\s*testers:\s*(.+)$') {
                $currentTesters += ($Matches[1] -split '[,\s]+' | Where-Object { $_ })
              }
            }
            $currentTesters = @($currentTesters | Select-Object -Unique)
            $keepTesters = @()
            $strippedTesters = @()
            foreach ($t in $currentTesters) {
              # Тестер из tester-scope-map → проверяем relevance. Тестер не в map → оставляем как есть (агент сам знает).
              $inMap = $tMap.rules | Where-Object { $_.tester -eq $t }
              if ($inMap) {
                if ($relevantTesters -contains $t) { $keepTesters += $t } else { $strippedTesters += $t }
              } else {
                $keepTesters += $t
              }
            }
            if ($strippedTesters.Count -gt 0) {
              Log "tester scope: стрипнуты [$($strippedTesters -join ', ')] (их paths не затронуты diff'ом). Оставлены: [$($keepTesters -join ', ')]. Override: '# all-testers' в VERIFY-REQUEST."
              # Переписываем маркер: убираем старые testers:, добавляем новый.
              $newMarker = (($markerText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*testers:\s*' }) -join "`n"
              if ($keepTesters.Count -gt 0) {
                $newMarker += "`ntesters: " + ($keepTesters -join ' ')
              }
              # Все стрипнули → не пишем строку testers: вовсе. verify.ps1 при пустом
              # planTesters просто пропустит Фазу C (циклы не выполняются на пустом массиве).
              Set-Content -LiteralPath $verifyMarker -Value $newMarker -Encoding UTF8
              $markerText = $newMarker
              Append-Event -EventType 'tester-scope-auto' -TaskId $focus -Phase 'C-E' -Iteration $i `
                -Payload @{ kept = $keepTesters; stripped = $strippedTesters }
            }
          } catch {
            Log "tester-scope-map.json parse error (non-fatal): $($_.Exception.Message)"
          }
        }
      }
    }
    if ((-not $forceRerun) -and (Test-Path $vfPath)) {
      $curFp = (& git -C $root diff HEAD 2>$null | git -C $root hash-object --stdin 2>$null | Out-String).Trim()
      $prevFp = ''; $prevV = ''
      $prevTxt = Get-Content -Raw -LiteralPath $vfPath
      if ($prevTxt -match '(?m)^diff_fingerprint:\s*(\S+)') { $prevFp = $Matches[1] }
      # Авторитетный verdict — inner judge JSON.
      $jOut = Join-Path $root ".bcf\verify\$focus-$($JudgeName).out.txt"
      if (Test-Path $jOut) {
        $jt = Get-Content -Raw -LiteralPath $jOut
        # Robust-экстракция (Extract-JudgeJson из m13-bridge.ps1) — старый
        # 1-уровневый regex не матчил вложенный JSON судьи, $prevV держался
        # только на fallback по 'verdict:' из .md ниже.
        $jj = Extract-JudgeJson -Text $jt
        if ($jj) { $prevV = $jj.verdict }
      }
      if (-not $prevV -and $prevTxt -match '(?m)^verdict:\s*(\S+)') { $prevV = $Matches[1] }
      if ($curFp -and $prevFp -and ($curFp -eq $prevFp) -and $prevV -and ($prevV -notmatch '(?i)^PASS$')) {
        $skipVerify = $true
        Log "verify пропущен (idempotency): diff_fingerprint==$($prevFp.Substring(0,[Math]::Min(8,$prevFp.Length))) и прошлый вердикт=$prevV. Чтобы форсировать — добавь '# stale-verdict-ignored' в VERIFY-REQUEST."
        Remove-Item $verifyMarker -Force -ErrorAction SilentlyContinue
        Append-Event -EventType 'verify-skipped-idempotent' -TaskId $focus -Phase 'C-E' -Iteration $i `
          -Payload @{ diff_fingerprint = $curFp; prev_verdict = $prevV }
        $bp += "VERIFY-REQUEST игнорирован раннером: diff не изменился с прошлой проверки (verdict=$prevV). " +
               "Сначала ПРАВЬ КОД по списку remediation из tasks/.verdicts/$focus.md, или добавь '# stale-verdict-ignored' в VERIFY-REQUEST если ремедиация устарела."
      }
    }
    if (-not $skipVerify) {
    Log "Маркер VERIFY-REQUEST — запуск Фаз C-E: harness/verify.ps1 $focus"
    Append-Event -EventType 'verify-requested' -TaskId $focus -Phase 'C-E' -Iteration $i `
      -Payload @{ marker_content = ((Get-Content $verifyMarker -Raw) -join "`n") }
    $verifyPs1 = Join-Path $PSScriptRoot "verify.ps1"
    $vArgs = @('-NoProfile', '-File', $verifyPs1, $focus)
    if ($Model) { $vArgs += @('-Model', $Model) }
    # M-09 F-fix (2026-05-25): пробрасываем свой session_id, чтобы verify не считал
    # эту loop-сессию «конкурентной» (см. verify.ps1 F-check).
    $env:RALPH_PARENT_SESSION_ID = (Get-EventBusSession)
    # M-13/M (2026-05-28): pre-iter ref для impact-mode тестеров.
    if ($preIterTreeRef) { $env:RALPH_PRE_ITER_REF = $preIterTreeRef }
    & pwsh @vArgs
    Remove-Item env:RALPH_PARENT_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item env:RALPH_PRE_ITER_REF      -ErrorAction SilentlyContinue
    Log "verify.ps1 завершён (exit $LASTEXITCODE)."
    } # /skipVerify
    $vf = Join-Path $root "tasks\.verdicts\$focus.md"
    if (Test-Path $vf) {
      $vtxt = Get-Content -Raw -LiteralPath $vf
      # M-13/A (2026-05-27): сначала ищем inner judge JSON ("verdict": "...", "remediation": [...]).
      # Outer YAML wrapper (`verdict: ...`) и парсер `remediation: |` часто рассинхронизированы:
      # 11 итераций TASK-03 показали wrapper=NEEDS-MORE-EVIDENCE при inner=FAIL.
      # Inner JSON — авторитетный источник; outer YAML — fallback.
      $vv = 'UNKNOWN'
      $rem = ''
      $innerJson = $null
      # Inner JSON судьи живёт в .bcf/verify/<TASK>-$($JudgeName).out.txt — это
      # авторитетный источник. Outer YAML wrapper в verdict.md часто рассинхронизирован.
      $judgeOut = Join-Path $root ".bcf\verify\$focus-$($JudgeName).out.txt"
      $candidateText = if (Test-Path $judgeOut) { Get-Content -Raw -LiteralPath $judgeOut } else { $vtxt }
      # Берём САМЫЙ ШИРОКИЙ JSON-блок (greedy), который содержит "verdict" — это будет
      # внешний JSON-объект ответа судьи, а не вложенный assertion.
      $jsonMatch = [regex]::Match($candidateText, '(?s)\{(?:[^{}]|\{[^{}]*\})*"verdict"\s*:\s*"[^"]+"(?:[^{}]|\{[^{}]*\})*\}')
      if ($jsonMatch.Success) {
        try { $innerJson = $jsonMatch.Value | ConvertFrom-Json -ErrorAction Stop } catch { $innerJson = $null }
      }
      if ($innerJson) {
        $vv = "$($innerJson.verdict)".ToUpper()
        if ($innerJson.remediation) {
          $remList = @($innerJson.remediation) | ForEach-Object {
            if ($_ -is [string]) { "  - $_" }
            elseif ($_.summary)  { "  - $($_.summary)" }
            else                 { "  - $($_ | ConvertTo-Json -Compress)" }
          }
          $rem = ($remList -join "`n")
        }
        if ($innerJson.failing_criterion -and -not $rem) {
          $rem = "  - failing_criterion: $($innerJson.failing_criterion)"
        }
      }
      # Fallback на outer YAML, если inner JSON не нашёлся / без verdict.
      if ($vv -eq 'UNKNOWN' -and $vtxt -match '(?m)^verdict:\s*(\S+)') { $vv = $Matches[1] }
      if (-not $rem -and $vtxt -match '(?s)remediation:\s*\|\r?\n(.*?)(?:\r?\n##|\r?\n```|\z)') { $rem = $Matches[1].TrimEnd() }
      # verdict-recorded event пишется уже из verify.ps1 — здесь не дублируем.
      if ($vv -ne 'PASS') {
        $src = if ($innerJson) { ' (inner judge JSON)' } else { ' (outer YAML fallback)' }
        $bp += "ВЕРДИКТ СУДЬИ: $vv$src (Фазы C-E, tasks/.verdicts/$focus.md).`n" +
               "Задача НЕ закрыта. Исправь код по списку ремедиации, затем снова создай`n" +
               "файл .bcf/VERIFY-REQUEST для повторной верификации:`n$rem"
        # M-15: точный машинный вывод детерминированных гейтов — авторитетнее судьи.
        # Если судья промахнулся/не прочитал файл, агент всё равно увидит ФАКТ провала.
        $detDigest = Get-DeterministicFailureDigest -Repo $root -Task $focus
        if ($detDigest) {
          $bp += "ДЕТЕРМИНИРОВАННЫЕ ГЕЙТЫ — машинный вывод (АВТОРИТЕТНЕЕ судьи; чини ИМЕННО эти ассерты, не пересказ судьи):`n$detDigest"
        }
      }

      # M-16 (2026-05-31): throwout по СТАБИЛЬНОМУ набору падающих тестов. loop-detection по
      # bp-строке слеп, когда формулировки «плавают», а падает один и тот же набор тестов (кейс
      # TASK-09: 20 итераций грайнда). Если N verify подряд = тот же fail-set, хотя код менялся —
      # гейт не сходится: вероятно невыполнимый/флаки-гейт или проблема ТЕСТ-ИНФРЫ. Зовём ревью.
      if ($vv -ne 'PASS') {
        $failSig = Get-FailingTestSignature -Repo $root -Task $focus
        if ($failSig -ne '') {
          if ($failSig -eq $lastFailSig) { $sameFailSetCount++ } else { $sameFailSetCount = 0 }
          $lastFailSig = $failSig
          if (($sameFailSetCount + 1) -ge $FailSetStall) {
            $consec = $sameFailSetCount + 1
            Log "FAILING-SET STALL: один и тот же набор падающих тестов $consec verify подряд → гейт не сходится. Set: $failSig"
            Set-Content $stateFile "# Ralph STATE`n`n## Итерация $i — FAILING-SET STALL`n`nОдин и тот же набор тестов падает $consec verify-итераций подряд, хотя код менялся:`n$failSig`n`nВероятно НЕВЫПОЛНИМЫЙ/флаки-гейт или проблема ТЕСТ-ИНФРЫ: проверь таймауты фикстур vs реальные времена интеграций (mock мгновенен, реальный сервис — нет), порядок/порт-контеншн, корректность предусловий. Нужно ревью человека/Глаза бога, а не дальнейший грайнд." -Encoding UTF8
            Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration $i `
              -Payload @{ reason = 'failing-set-stall'; fail_set = $failSig; consecutive = $consec }
            Notify-Stop 'warn' "${focus}: гейт не сходится (failing-set stall)" "Один и тот же набор тестов падает $consec verify подряд, хотя агент менял код. Вероятно невыполнимый/флаки-гейт или проблема тест-инфры (таймауты фикстур vs реальные времена, mock↔real, порт-контеншн). Нужно ревью, не грайнд."
            break
          }
        }
      } else {
        $sameFailSetCount = 0; $lastFailSig = ''
      }

      # M-13 B: ретроспектор → upsert root causes + proposals в agent_memory.
      # Не зависит от вердикта — даже PASS-итерации полезно ретроспектировать
      # (что сработало). Failure режим: тихий no-op, не блокируем loop.
      try {
        $judgeOutPath = Join-Path $root ".bcf\verify\$focus-$($JudgeName).out.txt"
        Run-Retrospector -TaskId $focus -Iteration $i `
          -IterOutJsonl $ocOutFile -VerdictFile $vf -JudgeOutFile $judgeOutPath | Out-Null
      } catch { Log "M-13 retrospector failed (non-fatal): $($_.Exception.Message)" }

      # M-13/Phase3: проверка vision-регресса vs baseline. ДО supervisor'а, чтобы
      # его reopen'ы оказались в open_bugs списке для текущего iter assessment.
      try {
        $regr = Check-VisionRegression -Repo $root -TaskId $focus
        if ($regr.regressed.Count -gt 0) {
          Log "[vision-baseline] регресс на $($regr.regressed.Count) slug/theme — reopen as bugs"
          Reopen-RegressedAsBugs -TaskId $focus -Iteration $i -Regressed $regr.regressed
          Append-Event -EventType 'vision-regression' -TaskId $focus -Phase 'D' -Iteration $i `
            -Payload @{ count = $regr.regressed.Count; items = $regr.regressed }
        }
        # На PASS — сохраняем baseline. Verdict читаем из inner JSON judge.
        if ($vv -match '(?i)^PASS$') {
          Save-VisionBaseline -Repo $root -TaskId $focus | Out-Null
        }
      } catch { Log "vision-baseline failed (non-fatal): $($_.Exception.Message)" }

      # M-13/Phase1: supervisor — собирает findings → bug-ledger.
      try {
        $judgeOutPath = Join-Path $root ".bcf\verify\$focus-$($JudgeName).out.txt"
        $curFp = (& git -C $root diff HEAD 2>$null | git -C $root hash-object --stdin 2>$null | Out-String).Trim()
        $diffFilesArr = @()
        if ($preIterTreeRef) {
          $diffFilesArr = @((& git -C $root diff --name-only $preIterTreeRef 2>$null | Where-Object { $_ -and $_.Trim() }))
        }
        $supervised = Run-IterationSupervisor -TaskId $focus -Iteration $i `
          -JudgeOutFile $judgeOutPath -VerdictFile $vf `
          -DiffFingerprint $curFp -DiffFiles $diffFilesArr
        if ($supervised) {
          $appl = $supervised._applied
          Log "[supervisor] applied: opened=$($appl.opened) closed=$($appl.closed) redetected=$($appl.redetected) reopened=$($appl.reopened)"
          Append-Event -EventType 'bug-supervisor-applied' -TaskId $focus -Phase 'E' -Iteration $i `
            -Payload @{ applied = $appl; verdict = $supervised.judge_verdict; iter_assessment = $supervised.iter_assessment }
        }
      } catch { Log "bug-supervisor failed (non-fatal): $($_.Exception.Message)" }
    } else {
      $bp += "verify.ps1 не создал tasks/.verdicts/$focus.md — верификация не дала вердикта. Проверь .bcf/loop.log."
      Append-Event -EventType 'verify-no-verdict' -TaskId $focus -Phase 'C-E' -Iteration $i
    }
  }

  # M-13/Phase4: adaptive hard-cap — проверка ПЕРЕД verdict-pass branch.
  # Если PASS — счётчик сбросится через секунду. M-13/U (2026-05-28): score=0 →
  # bug-tracker не накапливает (supervisor LLM-failure?), это НЕ декомпозиция-сигнал.
  $itersNoPass = $script:itersWithoutPass + 1
  $capCheck = Test-HardCap -TaskId $focus -ItersWithoutPass $itersNoPass
  if ($capCheck.hit -and -not (Verdict-Pass $focus)) {
    if ($capCheck.severity.score -eq 0) {
      # Trackerless cap: предупреждаем, но не останавливаем — продолжаем работать.
      # Сбрасываем счётчик чтобы не повторяться каждый iter.
      Log "[hard-cap/trackerless] $itersNoPass iter без PASS при severity_score=0 — bug-tracker пуст (supervisor LLM не вернул actions). Продолжаем; проверь invoke-supervisor.ps1 и LM Studio."
      Append-Event -EventType 'hard-cap-trackerless' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ iters_without_pass = $itersNoPass; note = 'bug-tracker empty — supervisor LLM не отрабатывает; deterministic fallback должен включиться следующий iter' }
      $script:itersWithoutPass = 0   # сброс — даём fallback'у шанс заполнить ledger
    } else {
      Log "HARD-CAP: $($capCheck.reason). Декомпозиция обязательна."
      Set-Content $stateFile ("# Ralph STATE`n`n## Итерация $i — HARD-CAP REACHED`n`n" +
        "Adaptive hard-cap сработал:`n  $($capCheck.reason)`n`n" +
        "Действия оператора:`n" +
        "  1. Декомпозиция: создать subtask'и tasks/$focus.1-<slug>.md ... под каждый chronic-bug.`n" +
        "  2. ИЛИ throw-out: переписать VERIFY-REQUEST с '# stale-verdict-ignored' если remediation устарела.`n" +
        "  3. Закрыть текущий $focus как 'pending decomposition', сменить CURRENT-FOCUS.`n`n" +
        "Открытые баги — в agent_memory.bugs (см. STATE.md <open-bugs>).") -Encoding UTF8
      Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ reason = 'hard-cap-decomposition-required'; severity_score = $capCheck.severity.score; cap = $capCheck.cap; iters_without_pass = $itersNoPass }
      Notify-Stop 'warn' "$focus hit hard-cap" "Adaptive hard-cap: $($capCheck.iters_without_pass) iter без PASS при severity_score=$($capCheck.severity.score). Декомпозиция обязательна."
      break
    }
  }

  # 3. Verdict получен?
  if (Verdict-Pass $focus) {
    $script:itersWithoutPass = 0   # сброс счётчика на PASS
    Log "[$focus] verdict: PASS получен на итерации $i. СТОП на ревью."
    Set-Content $stateFile "# Ralph STATE`n`n## Итерация $i — $focus`n`nverdict: PASS. Задача готова к ревью оператора." -Encoding UTF8
    Append-Event -EventType 'task-closed' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ verdict = 'PASS' }
    Notify-Stop 'ok' "$focus готова к ревью" "Задача $focus прошла судью (verdict: PASS) на итерации $i. Цикл остановлен — нужно твоё ревью."
    break
  }

  # Инкрементируем счётчик iter без PASS (для следующей итерации Test-HardCap).
  $script:itersWithoutPass++

  # 4. Loop-detection — 3 итерации с одной ошибкой
  $err = ($bp -join " || ")
  if ($err -ne "" -and $err -eq $lastError) { $sameErrorCount++ } else { $sameErrorCount = 0 }
  $lastError = $err
  if ($sameErrorCount -ge 2) {
    Log "Loop-detection: 3 итерации с одной ошибкой. Остановка — нужен оператор."
    Set-Content $stateFile "# Ralph STATE`n`n## Итерация $i — LOOP DETECTED`n`nТри итерации — одна ошибка:`n$err" -Encoding UTF8
    Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ reason = 'loop-detection'; error = ($err.Substring(0, [Math]::Min(500, $err.Length))) }
    Notify-Stop 'warn' "$focus застряла (одна ошибка)" "3 итерации подряд — одна и та же ошибка. Цикл остановлен — нужно вмешательство."
    break
  }

  # 5. Детектор «нет прогресса»
  $curHash = Get-TreeHash
  if ($curHash -eq $lastHash) { $noProgressCount++ } else { $noProgressCount = 0 }
  $lastHash = $curHash

  # M-09 (2026-05-25): «пустая итерация» — нет правок И нет verify-request И bp чист.
  # Это значит агент крутил тулзы, ничего не редактировал, не попросил судью. Без
  # явной backpressure-нотификации модель думает что всё нормально, повторяет. Гасим
  # в зачёт no-progress и говорим прямо: «либо правь, либо проси verify, либо завершай».
  if ($curHash -eq $lastHash -and $bp.Count -eq 0 -and -not (Test-Path $verifyMarker)) {
    $bp += @"
ПУСТАЯ ИТЕРАЦИЯ: ты не правил код И не создал .bcf/VERIFY-REQUEST.
Раннер не знает что ты сделал. Возможные причины и действия:
1. «Всё уже сделано» → создай .bcf/VERIFY-REQUEST для подтверждения PASS.
2. «Я только изучал» → следующая итерация должна делать meaningful edit
   (правь файлы из task DoD §3) или создавать subtask.
3. «Я застрял на инфра-проблеме» (стейл-вердикт про <model>_API_KEY и т.п.) →
   перепиши .bcf/VERIFY-REQUEST с пометкой `# stale-verdict-ignored` чтобы
   harness выкинул старый verdict и прогнал свежий.
Подряд 3 таких итерации → раннер остановит цикл (no-progress).
"@
    Append-Event -EventType 'iter-empty' -TaskId $focus -Phase 'loop' -Iteration $i `
      -Payload @{ tree_unchanged = $true; no_verify_request = $true }
  }
  if ($noProgressCount -ge $NoProgressLimit) {
    if ($AutoAdvance -and -not $noProgressEscalated) {
      # M-15 (2026-05-30): в unattended (run-all) режиме НЕ бросаем задачу на no-progress —
      # человека рядом нет, а в бюджете ещё итерации (стопы рано: 6-13/40). Эскалируем ОДИН раз:
      # отдаём агенту КОНКРЕТИКУ (remediation последнего вердикта; open-bugs уже в STATE) и жёстко
      # направляем на продуктовый код (.bcf/-правки не считаются прогрессом → агент крутил STATE.md).
      # Повторный no-progress после эскалации → честный стоп ниже. Потолок $MaxIterations + loop-detection
      # (3× одна ошибка) остаются — burst ограничен.
      $noProgressEscalated = $true
      $noProgressCount = 0
      $remBlock = ""
      $vf = Join-Path $root "tasks\.verdicts\$focus.md"
      if (Test-Path $vf) {
        $m = [regex]::Match((Get-Content $vf -Raw), '(?ms)^remediation:\s*\|(.*?)(?=^##\s|\z)')
        if ($m.Success) { $remBlock = $m.Groups[1].Value.Trim() }
      }
      $remaining = $MaxIterations - $i
      $escalation = @"
# Ralph STATE — ЭСКАЛАЦИЯ (no-progress)

## Итерация $i — ТЫ ЗАСТРЯЛ, НО ЗАДАЧА НЕ ЗАКРЫТА

$NoProgressLimit итерации подряд БЕЗ изменений продуктового кода (src/, electron/, backend/).
Правки в .bcf/ (STATE.md, human-callout.md и пр.) НЕ считаются прогрессом — раннер их игнорирует.

У тебя ещё $remaining итераций. НЕ останавливайся. Сделай СЛЕДУЮЩЕЕ:
1. Возьми КОНКРЕТНУЮ упавшую проверку из remediation последнего вердикта (ниже) и почини её
   минимальным точечным изменением ПРОДУКТОВОГО файла из DoD §3.
2. Если правка ломала tsc и откатывалась — НЕ повторяй её; воспроизведи минимально, потом фикс.
3. Если уверен, что всё сделано — создай .bcf/VERIFY-REQUEST (а не правь STATE.md).
4. ЗАПРЕЩЕНО: редактировать только .bcf/-файлы, «думать» без edit, повторять откатанную правку.

### Remediation последнего вердикта (чини ИМЕННО ЭТО):
$(if ($remBlock) { $remBlock } else { '(вердикта ещё нет — сделай meaningful edit продуктового файла из DoD §3 и создай .bcf/VERIFY-REQUEST)' })

### Открытые баги — блок <open-bugs> выше (priority 1 первым).
"@
      Set-Content $stateFile $escalation -Encoding UTF8
      Append-Event -EventType 'no-progress-escalated' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ remaining_iterations = $remaining; had_remediation = [bool]$remBlock }
      Log "NO-PROGRESS ЭСКАЛАЦИЯ (unattended): конкретика в STATE, счётчик сброшен, продолжаю (ещё $remaining итераций)."
      # НЕ break — продолжаем цикл
    }
    else {
      $why = if ($noProgressEscalated) { ' даже после эскалации' } else { '' }
      Log "Нет прогресса: $NoProgressLimit итераций подряд без изменений кода$why. Остановка."
      Set-Content $stateFile "# Ralph STATE`n`n## Итерация $i — NO PROGRESS`n`n$NoProgressLimit итераций подряд не изменили код$why. Раннер остановлен — нужен оператор." -Encoding UTF8
      Append-Event -EventType 'no-progress' -TaskId $focus -Phase 'loop' -Iteration $i `
        -Payload @{ no_progress_count = $noProgressCount; limit = $NoProgressLimit; escalated = $noProgressEscalated }
      Notify-Stop 'warn' "$focus застряла (нет прогресса)" "$NoProgressLimit итераций подряд без изменений кода$why. Цикл остановлен — нужно вмешательство."
      break
    }
  }

  # 6. STATE.md (legacy compat) + Compute-State JSON
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $block = "# Ralph STATE`n`n## Итерация $i — $ts — задача $focus`n`n"
  if ($bp.Count -gt 0) {
    $block += "BACKPRESSURE — исправь это первым шагом следующей итерации:`n`n" + ($bp -join "`n`n") + "`n"
  } else {
    $block += "Backpressure чист (tsc 0, done-gate ok). Переходи к следующей фазе активной задачи.`n"
  }
  Set-Content $stateFile $block -Encoding UTF8
  Append-Event -EventType 'iter-completed' -TaskId $focus -Phase 'loop' -Iteration $i `
    -Payload @{ backpressure = ($bp.Count -gt 0); bp_summary = (($bp -join " || ").Substring(0, [Math]::Min(300, ($bp -join " || ").Length))) }
  # пересчитываем state/STATE.json каждую итерацию (быстро для нашего объёма)
  Compute-State | Out-Null

  # Durable WIP-снапшот итерации (gc-safe ref, восстановимо, прогресс не теряется).
  try {
    $wip = Save-WipSnapshot -Repo $root -TaskId $focus -Iteration $i
    if ($wip) {
      Log "WIP-снапшот: refs/bcf/wip/$focus → $($wip.Substring(0,8)) (gc-safe; откат: git checkout refs/bcf/wip-history/$focus/iter$i -- .)"
      Append-Event -EventType 'wip-snapshot' -TaskId $focus -Phase 'loop' -Iteration $i -Payload @{ sha = $wip }
    }
  } catch { Log "WIP-снапшот не сохранён (non-fatal): $($_.Exception.Message)" }

  Log "Итерация $i завершена. Backpressure: $(if ($bp.Count -gt 0) {'ЕСТЬ ошибки'} else {'чисто'}). NoProgress=$noProgressCount."
}

if ($i -gt $MaxIterations) {
  Log "Достигнут лимит $MaxIterations итераций без verdict: PASS."
  Append-Event -EventType 'loop-paused' -TaskId $focus -Phase 'loop' -Iteration ($i - 1) `
    -Payload @{ reason = 'max-iterations'; limit = $MaxIterations }
  Notify-Stop 'warn' "лимит итераций ($MaxIterations)" "Цикл прошёл $MaxIterations итераций и не дошёл до verdict: PASS. Задача не закрыта — нужно вмешательство."
}

Append-Event -EventType 'loop-ended' -TaskId $focus -Phase 'loop' `
  -Payload @{ iterations_done = ($i - 1); session_id = (Get-EventBusSession) }
Compute-State | Out-Null

# W8 ingest hook: после окончания цикла подтягиваем новые verdict + events в память harness.
# Падение ingest не должно валить цикл — try/catch.
try {
  $venvPy = "$root\harness\.venv\Scripts\python.exe"
  if (Test-Path $venvPy) {
    & $venvPy "$root\harness\memory\ingest-events.py" --sources verdicts,events 2>&1 | Tee-Object -FilePath $logFile -Append | Out-Null
  }
} catch { Log "[memory ingest] предупреждение: $($_.Exception.Message)" }

Log "=== Ralph loop завершён ==="
