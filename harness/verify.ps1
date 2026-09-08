# harness/verify.ps1 — Фазы C–E для одной TASK-задачи. План верификации задаёт АГЕНТ
# (в маркере .bcf/VERIFY-REQUEST), обвязка его исполняет.
#
# Каждый LLM-шаг — ОТДЕЛЬНЫЙ прогон со СВЕЖИМ контекстом; судья не видел ход реализации.
#   - тестеры (Фаза C)        — <model> (выровнены с код-агентом, 2026-06-05);
#   - детерминированные checks — команды из плана (npm run ...), как есть;
#   - визуальная Фаза D        — `npm run test:vision:all` (SSIM + pixelmatch + <model>
#                                vision через MCP <model>_understand_image)
#                                + LLM-критик ux-vision на <model> M2.7;
#   - судья   (Фаза E)        — <model> (изолированный прогон).
#
# Транспорт тестеров/судьи задаётся в config/harness.json (agent.command, models.*).
# Ключ и хост бэкенда — из окружения (.env: BCF_API_KEY / BCF_API_HOST); в коде их нет.
# Результат — tasks/.verdicts/<TASK>.md.  exit 0 = verdict PASS, иначе exit 1.
#
# Маркер .bcf/VERIFY-REQUEST (пишет агент), формат:
#   task: TASK-NN
#   testers: architecture api
#   checks: npm run test:electron:smoke
#   visual: no
# Полей может не быть — тогда дефолты (architecture + api по слоям, без checks, visual:no).
#
# Запуск:
#   pwsh harness/verify.ps1 TASK-01
#   pwsh harness/verify.ps1 TASK-01 -DryRun                       # обвязка без вызовов LLM
#   pwsh harness/verify.ps1 TASK-01 -JudgeModel claude-opus-4-7   # сильнее судья

param(
  [Parameter(Position = 0)] [string]$Task = "",
  [string]$Model = "",          # тестеры (Фаза C); пусто = из config/harness.json models.tester (иначе дефолт бэкенда)
  [string]$VisionModel = "",    # vision-критик (Фаза D); пусто = из config models.vision
  [string]$JudgeModel = "",     # финальный судья (Фаза E); пусто = из config models.judge
  [string]$JudgeEffort = "medium",                            # legacy parameter
  [int]$StepTimeoutSec = 1800,
  # Silent-timeout: kill дерева, если в stdout не было НИКАКИХ новых строк за это
  # время. Защита от двух классов подвисов:
  #   1) opencode-стрим обрывается без exit (incident 2026-05-26 12:41 — kimi-k2.6
  #      встал на 13+ мин после Read tool-call).
  #   2) npm/playwright/electron-зомби не отпускают stdin после `process.exit()`
  #      (incident 2026-05-26 11:45 — vision-suite сидел 19 мин после "Run → FAIL").
  # 600s (10 мин) — щедро для самого долгого fetch/thinking; короче — режет легитимно.
  [int]$SilentTimeoutSec = 600,
  [switch]$DryRun,
  [string]$ProjectRoot = '',        # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
  # База дифа для приёмки УЖЕ ПРИЗЕМЛИВШЕЙСЯ работы (ревизия git: sha, тег, HEAD~5).
  #
  # По умолчанию verify считает работу задачи как diff её файлов против HEAD, а если пусто —
  # против HEAD~1: он рассчитан на запуск сразу после итерации кодового агента, когда работа
  # либо в дереве, либо в последнем коммите. Если задачи закрывали раньше и их работа лежит
  # в глубине истории, обе базы дают пустоту, и гейт пустого дифа валит вердикт словами
  # «задача не изменила ни строки» — хотя изменила, просто десять коммитов назад.
  #
  # Параметр НЕ ослабляет гейт: диф считается против указанной ревизии, и если файлы задачи
  # с тех пор не тронуты — гейт падает ровно как раньше. Он лишь даёт человеку сказать,
  # относительно чего мерить работу.
  [string]$DiffBase = ''
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

# Обязательные проверки (config/checks.json) запускаются В КОРНЕ ПРОЕКТА, а обвязка лежит
# снаружи него. Проверке, которой нужен гейт харнесса, сослаться было не на что: путь
# harness/... в проекте не существует, а абсолютный — машинно-зависим. Отдаём корень
# обвязки и корень проекта через окружение: Start-Process наследует переменные процесса.
# Без этого проверка TASK-46 падала не по делу — pwsh печатал usage-баннер вместо запуска.
$env:BCF_HARNESS_ROOT = Get-BcfHarnessRoot

# Версия фабрики и хэш файла графа — печатаются в КАЖДЫЙ вердикт (factory_version:,
# graph_hash:), чтобы разбор дефекта видел, каким движком и по какому графу задача была
# проверена, не поднимая журнал прогона (он живёт в .bcf/ и не переживает уборку
# состояния — коммит с вердиктом переживает). Для прогонов вне графа (`bcf run
# loop`/`night`) graph_hash так и говорит: гейт применялся не к файлу графа, а к циклу.
# Считает обе строки одна функция на всю обвязку — Get-BcfProvenanceLines ниже, там же,
# где собирается тело вердикта; её же зовут run-all.ps1 и отчёт прогона.
if (-not $env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT = $root }

# --- Harness config (config/harness.json + config/agents.json) — источник специфики. ---
$Cfg = $null; $AgentsCfg = $null
$cfgF = Join-Path $root 'config\harness.json'
$agF  = Join-Path $root 'config\agents.json'
if (Test-Path $cfgF) { try { $Cfg = Get-Content -Raw $cfgF | ConvertFrom-Json } catch { Write-Warning "config/harness.json parse: $_" } }
if (Test-Path $agF)  { try { $AgentsCfg = Get-Content -Raw $agF | ConvertFrom-Json } catch { Write-Warning "config/agents.json parse: $_" } }
if ($Cfg) {
  if (-not $PSBoundParameters.ContainsKey('Model')          -and $Cfg.models.tester) { $Model = [string]$Cfg.models.tester }
  if (-not $PSBoundParameters.ContainsKey('VisionModel')    -and $Cfg.models.vision) { $VisionModel = [string]$Cfg.models.vision }
  if (-not $PSBoundParameters.ContainsKey('JudgeModel')     -and $Cfg.models.judge)  { $JudgeModel = [string]$Cfg.models.judge }
  if (-not $PSBoundParameters.ContainsKey('StepTimeoutSec') -and $Cfg.timeouts.stepSec)   { $StepTimeoutSec = [int]$Cfg.timeouts.stepSec }
  if (-not $PSBoundParameters.ContainsKey('SilentTimeoutSec') -and $Cfg.timeouts.silentSec){ $SilentTimeoutSec = [int]$Cfg.timeouts.silentSec }
}
$JudgeName     = if ($Cfg -and $Cfg.judge.name)      { [string]$Cfg.judge.name }     else { 'judge' }
$JudgeAgentFile= if ($AgentsCfg -and $AgentsCfg.judge.file) { [string]$AgentsCfg.judge.file } else { '.claude/agents/judge.md' }
$DefaultTesters= if ($AgentsCfg -and $AgentsCfg.testers) { @($AgentsCfg.testers | ForEach-Object { $_.name }) } else { @('architecture') }
$FeatVision    = [bool]($Cfg -and $Cfg.features.vision)
# Конфигурируемые vision-команды (Фаза D активна только при features.vision).
$VisionBuildCmd    = if ($env:BCF_VISION_BUILD_CMD)    { $env:BCF_VISION_BUILD_CMD }    else { 'npm run build' }
$VisionContractCmd = if ($env:BCF_VISION_CONTRACT_CMD) { $env:BCF_VISION_CONTRACT_CMD } else { 'npm run test:vision:contract:nobuild' }
$VisionContractDir = if ($env:BCF_VISION_CONTRACT_DIR) { $env:BCF_VISION_CONTRACT_DIR } else { 'tests/electron' }

# UTF-8 везде (см. loop.ps1 коммент 2026-05-25).
try {
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding           = [System.Text.Encoding]::UTF8
  chcp 65001 | Out-Null
} catch { }

# W3: подключаем event-bus.
. (Join-Path $PSScriptRoot 'lib\event-bus.ps1')
Initialize-EventBus -RalphRoot (Get-BcfStateDir $root)

# W2: подключаем evidence collector.
. (Join-Path $PSScriptRoot 'lib\evidence.ps1')

# M-09 D: блокируем запуск из агентской opencode-сессии.
. (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
Assert-HarnessCaller -ScriptName 'verify.ps1'

# Чистим унаследованные от opencode desktop OPENCODE_* env-переменные — иначе дочерний
# `opencode run` пытается подключиться к чужой сессии → "Error: Session not found".
Get-ChildItem env: | Where-Object { $_.Name -like 'OPENCODE_*' } | ForEach-Object {
  Remove-Item "env:$($_.Name)" -ErrorAction SilentlyContinue
}

# W5 (2026-05-24): claude -p больше не используется (судья перенесён на <model>).
# ANTHROPIC_*-чистка снята как ненужная. Если кто-то вернёт claude в pipeline — добавить обратно.

# Роли живут в .claude/agents: там их читает и Claude Code как субагентов, и обвязка
# при верификации. Вторая копия в agents/ означала бы, что однажды поправят не ту.
$agentsDir  = Join-Path $root (Join-Path ".claude" "agents")
$verdictDir = Join-Path $root "tasks\.verdicts"
$workDir    = Join-Path $root ".bcf\verify"
$logFile    = Join-Path $root ".bcf\loop.log"
$planFile   = Join-Path $root ".bcf\VERIFY-REQUEST"

function Log($m) {
  $line = "[{0}] [verify] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  $color = 'Magenta'   # verify-фаза в целом — magenta
  if ($m -match 'ОШИБКА|TIMEOUT|FAILED|провален|HARD-FLOOR') { $color = 'Red' }
  elseif ($m -match 'ПРЕДУПРЕЖДЕНИЕ|ОТКАЗ|rejected') { $color = 'Yellow' }
  elseif ($m -match 'PASS|завершён|Вердикт записан.*PASS') { $color = 'Green' }
  elseif ($m -match 'Запуск|План|Файлы задачи') { $color = 'Cyan' }
  Write-Host $line -ForegroundColor $color
  Add-Content -Path $logFile -Value $line
}

# === Heartbeat-IO helpers (Bug B fix 2026-05-26) =============================
# Старая схема (FS-open-close на каждый тик с FileShare.ReadWrite) теряла дельту
# stdout при batched-flush npm-child: writer держит handle с FileShare.Read, наш
# повторный Open ловил IOException, пустой catch{} проглатывал → $lastShownBytes
# не двигался → heartbeat слеп. Решение: один open ПОСЛЕ Start-Process,
# FileShare.ReadWrite|Delete, держим handle до завершения процесса, читаем дельту
# инкрементально через Stream.Position. Catch — логируем, не глотаем.

function _OpenStdoutReader([string]$Path) {
  if (-not (Test-Path $Path)) {
    try { New-Item -ItemType File -Path $Path -Force -ErrorAction Stop | Out-Null } catch { }
  }
  $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
  for ($i = 0; $i -lt 50; $i++) {
    try {
      return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
  Log "ПРЕДУПРЕЖДЕНИЕ: не удалось открыть stdout-reader для $Path — heartbeat будет слеп."
  return $null
}

function _Drain-Reader {
  param(
    [System.IO.FileStream]$Stream,
    [ref]$PendingTail,
    [ref]$LastOutputAt,
    [string]$Label
  )
  if (-not $Stream) { return }
  try {
    $avail = $Stream.Length - $Stream.Position
    if ($avail -le 0) { return }
    if ($avail -gt 1048576) { $avail = 1048576 }    # cap 1 MB/тик
    $buf = New-Object byte[] $avail
    $totalRead = 0
    while ($totalRead -lt $avail) {
      $n = $Stream.Read($buf, $totalRead, [int]($avail - $totalRead))
      if ($n -le 0) { break }
      $totalRead += $n
    }
    if ($totalRead -le 0) { return }
    $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $totalRead)
    $combined = $PendingTail.Value + $chunk
    $split = $combined -split "`r?`n"
    if ($combined.EndsWith("`n")) {
      $PendingTail.Value = ''
      $emit = if ($split.Count -gt 0 -and $split[-1] -eq '') { $split[0..($split.Count - 2)] } else { $split }
    } else {
      $PendingTail.Value = $split[-1]
      $emit = if ($split.Count -gt 1) { $split[0..($split.Count - 2)] } else { @() }
    }
    $ts = Get-Date -Format 'HH:mm:ss'
    foreach ($ln in $emit) {
      if ([string]::IsNullOrWhiteSpace($ln)) { continue }
      Write-Host "[$ts] $Label | $ln" -ForegroundColor DarkGray
      $LastOutputAt.Value = Get-Date
    }
  } catch {
    Write-Host ("[{0}] {1} | [reader WARN: {2}]" -f (Get-Date -Format 'HH:mm:ss'), $Label, $_.Exception.Message) -ForegroundColor Yellow
  }
}

function _Final-Drain {
  param(
    [System.IO.FileStream]$Stream,
    [ref]$PendingTail,
    [ref]$LastOutputAt,
    [string]$Label
  )
  if (-not $Stream) { return }
  # Несколько проходов на случай если файл ещё чуть дописывается во время kill cleanup.
  for ($i = 0; $i -lt 20; $i++) {
    $before = $Stream.Position
    _Drain-Reader -Stream $Stream -PendingTail $PendingTail -LastOutputAt $LastOutputAt -Label $Label
    if ($Stream.Position -eq $before) { break }
  }
  if ($PendingTail.Value) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Label | $($PendingTail.Value)" -ForegroundColor DarkGray
    $PendingTail.Value = ''
  }
  try { $Stream.Dispose() } catch { }
}

# === Orphan reaper (Bug C/D fix 2026-05-26) =================================
# Между итерациями Ralph-loop накапливаются процессы, оставшиеся от прошлых
# verify-прогонов: opencode.exe (с флагами --dangerously-skip-permissions /
# --format json — характерно для скриптовой обвязки), electron.exe из
# the project (playwright spawn'ит их в test:vision:capture). Снимаем
# ТОЛЬКО точно идентифицируемые orphan'ы — НЕ трогаем VSCode/Discord/прочие
# electron-приложения и интерактивный opencode. Критерий orphan:
#   1) name + cmdline/exepath матчат whitelist;
#   2) старше MinAgeMinutes (свежие могут быть нашими, ещё не привязанными);
#   3) ни один предок не равен $PID и не равен нашему родителю (loop.ps1).

function _Get-ProcessAncestors([int]$ProcId) {
  $list = @()
  $cur = $ProcId
  for ($hops = 0; $cur -gt 4 -and $hops -lt 30; $hops++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $parent = [int]$p.ParentProcessId
    $list += $parent
    $cur = $parent
  }
  return $list
}

function Reap-Orphans {
  param([int]$MinAgeMinutes = 2)
  $myRoots = @($PID)
  try {
    $myParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
    if ($myParent) { $myRoots += [int]$myParent }
  } catch { }
  $now = Get-Date
  $reaped = @()
  # Прибиваем только зомби, связанные С ЭТИМ репозиторием — матч по пути репо в exe/cmdline.
  # Доп. процессы можно задать через $env:BCF_ORPHAN_EXTRA_PATTERN (regex по cmdline).
  $repoEsc = [regex]::Escape($root)
  $extraPat = [string]$env:BCF_ORPHAN_EXTRA_PATTERN
  $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
  foreach ($p in $all) {
    $cmdLine = [string]$p.CommandLine
    $exePath = [string]$p.ExecutablePath
    $isCandidate = $false
    $kind = ''
    if ($p.Name -eq 'opencode.exe' -and ($cmdLine -match '--dangerously-skip-permissions' -or $cmdLine -match '--format json')) {
      $isCandidate = $true; $kind = 'agent-cli'
    }
    elseif ($p.Name -eq 'electron.exe' -and ($exePath -match $repoEsc -or $cmdLine -match "$repoEsc|playwright")) {
      $isCandidate = $true; $kind = 'electron-playwright'
    }
    elseif ($p.Name -eq 'node.exe' -and ($exePath -match $repoEsc -or $cmdLine -match "$repoEsc.*(vite|playwright|electron-builder)")) {
      $isCandidate = $true; $kind = 'repo-node-tool'
    }
    elseif ($extraPat -and $cmdLine -match $extraPat) {
      $isCandidate = $true; $kind = 'extra-pattern'
    }
    if (-not $isCandidate) { continue }
    try {
      $start = [datetime]$p.CreationDate
      $ageMin = ($now - $start).TotalMinutes
    } catch { $ageMin = 999 }
    if ($ageMin -lt $MinAgeMinutes) { continue }
    $ancestors = _Get-ProcessAncestors -ProcId ([int]$p.ProcessId)
    $isMine = $false
    foreach ($a in $ancestors) { if ($myRoots -contains $a) { $isMine = $true; break } }
    if ($isMine) { continue }
    try {
      Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
      $reaped += [PSCustomObject]@{ Kind = $kind; Name = $p.Name; ProcessId = [int]$p.ProcessId; AgeMin = [math]::Round($ageMin, 1) }
    } catch {
      Log "  reap miss: $($p.Name) PID $($p.ProcessId) — $($_.Exception.Message)"
    }
  }
  return ,$reaped
}

if (-not $Task) { Log "ОШИБКА: не указана задача."; exit 2 }
$Task = $Task.ToUpper().Trim()
$tf = Get-ChildItem (Join-Path $root "tasks") -Filter "$Task-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $tf) { Log "ОШИБКА: task-файл $Task не найден в tasks/."; exit 2 }

# M-09 F (2026-05-25): отказ при конкурентной loop-сессии. На TASK-03 iter=1 параллельная
# сессия 46924fa33924 прогнала судью в обход loop-гейтов → нужно гасить такие race'ы.
# F-fix: loop.ps1 пробрасывает свой session_id через $env:RALPH_PARENT_SESSION_ID;
# verify считает её «своей» (это его loop-родитель), а конкурент — любой ДРУГОЙ session_id.
$myBus = Get-EventBusSession
$parentSession = if ($env:RALPH_PARENT_SESSION_ID) { [string]$env:RALPH_PARENT_SESSION_ID } else { '' }
# Тот же адрес, куда пишет шина (Initialize-EventBus выше получает тот же корень).
# Прежде гард читал harness\events.jsonl из каталога фабрики — файл, который шина
# не писала годами: конкуренция становилась невидимой, и два verify по одной задаче
# расходились, оба считая себя единственными.
$eventsFile = Join-Path (Get-BcfStateDir $root) 'events.jsonl'
if (Test-Path $eventsFile) {
  $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-90)
  $concurrentSession = $null
  $tail = Get-Content -LiteralPath $eventsFile -Tail 200 -ErrorAction SilentlyContinue
  foreach ($line in $tail) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $ev = $line | ConvertFrom-Json -ErrorAction Stop
      if ($ev.task_id -ne $Task) { continue }
      if ($ev.event_type -ne 'iter-started' -and $ev.event_type -ne 'opencode-run') { continue }
      if ($ev.session_id -eq $myBus) { continue }
      if ($parentSession -and $ev.session_id -eq $parentSession) { continue }
      $evTs = [DateTime]::Parse($ev.ts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
      if ($evTs -gt $cutoff) { $concurrentSession = $ev.session_id; break }
    } catch { }
  }
  if ($concurrentSession) {
    Log "ОТКАЗ: за последние 90s сессия $concurrentSession уже работает с $Task. verify пропущен."
    Append-Event -EventType 'verify-rejected' -TaskId $Task -Phase 'C-E' `
      -Payload @{ reason = 'concurrent-loop'; concurrent_session = $concurrentSession; my_session = $myBus; parent_session = $parentSession }
    exit 2
  }
}

New-Item -ItemType Directory -Force -Path $verdictDir, $workDir | Out-Null

# Bug C/D (2026-05-26): orphan-reaper. До фазы C валим opencode.exe от прошлых
# verify-итераций и electron.exe из the project, которые не принадлежат нашему
# дереву (parent ≠ $PID и не loop.ps1). VSCode/Discord/прочие electron — не трогаем
# (фильтр по ExecutablePath/CommandLine). Свежие (< 2 мин) пропускаем.
if (-not $DryRun) {
  $reapedNow = Reap-Orphans -MinAgeMinutes 2
  if ($reapedNow.Count -gt 0) {
    $listStr = ($reapedNow | ForEach-Object { "$($_.Kind)#$($_.ProcessId)($($_.AgeMin)m)" }) -join ', '
    Log "ORPHAN-REAP: убито $($reapedNow.Count) процессов — $listStr"
    Append-Event -EventType 'orphan-reap' -TaskId $Task -Phase 'pre-C' `
      -Payload @{ count = $reapedNow.Count; killed = @($reapedNow | ForEach-Object { @{ kind=$_.Kind; pid=$_.ProcessId; age_min=$_.AgeMin } }) }
  } else {
    Log "ORPHAN-REAP: чисто (нет agent-CLI/electron/repo-node процессов от прошлых прогонов вне нашего дерева)."
  }
}

# W5: judge-settings file больше не нужен — opencode не использует claude hooks.

if (-not $DryRun) {
  if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Log "ОШИБКА: 'opencode' не найден в PATH (нужен для всех фаз C/D/E)."; exit 2
  }
  # W5: claude CLI больше не требуется — судья тоже через opencode.
}

# --- План верификации: задаёт АГЕНТ в маркере .bcf/VERIFY-REQUEST ---
$planTesters = @()
$planChecks  = @()
$planVisual  = $false
$planVisionSlugs  = @()
$planVisionThemes = @()
$planRegression   = 'incremental'  # M-13/H: default — scope-aware; 'full' — финальный регресс
$staleVerdictIgnored = $false
if (Test-Path $planFile) {
  foreach ($line in (Get-Content -LiteralPath $planFile)) {
    if     ($line -match '^\s*testers:\s*(.+)$') { $planTesters += ($Matches[1] -split '[,\s]+' | Where-Object { $_ }) }
    elseif ($line -match '^\s*checks:\s*(.+)$')  { $planChecks  += $Matches[1].Trim() }
    elseif ($line -match '^\s*visual:\s*(yes|true|1)\s*$') { $planVisual = $true }
    elseif ($line -match '^\s*vision_slugs:\s*(.+)$')  { $planVisionSlugs  += ($Matches[1] -split '[,\s]+' | Where-Object { $_ }) }
    elseif ($line -match '^\s*vision_themes:\s*(.+)$') { $planVisionThemes += ($Matches[1] -split '[,\s]+' | Where-Object { $_ }) }
    elseif ($line -match '^\s*regression:\s*(full|incremental|release)\s*$') { $planRegression = $Matches[1].ToLower() }
    elseif ($line -match '^\s*#\s*stale-verdict-ignored\b') { $staleVerdictIgnored = $true }
  }
  $planTesters      = @($planTesters      | Select-Object -Unique)
  $planVisionSlugs  = @($planVisionSlugs  | Select-Object -Unique)
  $planVisionThemes = @($planVisionThemes | Select-Object -Unique)
}
else {
  Log "ПРЕДУПРЕЖДЕНИЕ: маркер .bcf/VERIFY-REQUEST не найден — план по умолчанию."
}

# M-09 (2026-05-25): агент может явно объявить «прошлый verdict с устаревшей
# инфраструктурной remediation, выкинь его». Архивируем — не зачисляем как failure.
if ($staleVerdictIgnored) {
  $existingVerdict = Join-Path $verdictDir "$Task.md"
  if (Test-Path $existingVerdict) {
    $archive = "$existingVerdict.stale-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Move-Item -LiteralPath $existingVerdict -Destination $archive -Force
    Log "STALE-VERDICT: $Task.md перемещён в $(Split-Path $archive -Leaf) по запросу агента."
    Append-Event -EventType 'verdict-archived-stale' -TaskId $Task -Phase 'C-E' `
      -Payload @{ archive = (Split-Path $archive -Leaf) }
  }
}

# --- Входы для верификации: task-файл целиком (в нём DoD) + diff ---
$taskBody = Get-Content -Raw -LiteralPath $tf.FullName

# Диф ограничиваем файлами из секции «Файлы» task-файла. Иначе `git diff HEAD` отдаёт
# весь working-tree (сотни файлов незакоммиченного ребилда): релевантное тонет, а обрезка
# по лимиту строк выкидывает нужные хунки — судья достраивает содержимое по воображению.
$taskFiles = @()
$mFiles = [regex]::Match($taskBody, '(?ms)^##[^\r\n]*Файлы.*?(?=^##\s|\z)')
if ($mFiles.Success) {
  foreach ($pm in [regex]::Matches($mFiles.Value, '([A-Za-z0-9_][A-Za-z0-9_./-]+\.[A-Za-z0-9]+)')) {
    $p = $pm.Groups[1].Value
    if (Test-Path (Join-Path $root $p)) { $taskFiles += $p }
  }
  $taskFiles = @($taskFiles | Select-Object -Unique)
}

# ВНИМАНИЕ: имена переменных в PowerShell НЕЧУВСТВИТЕЛЬНЫ К РЕГИСТРУ — $diffBase и $DiffBase
# это одна переменная. Параметр забираем в отдельное имя ДО присваивания рабочей базы,
# иначе строка ниже затирает аргумент: явная база молча становится HEAD, а у обычного
# прогона навсегда пропадает откат на HEAD~1.
$explicitBase = $DiffBase
$diffBase = 'HEAD'
# База задана человеком — автоподбор не работает: он и нужен затем, чтобы мерить работу,
# приземлившуюся раньше последнего коммита. Ревизию проверяем сразу: опечатка в sha иначе
# даст пустой диф и вердикт FAIL «задача ничего не изменила», то есть соврёт про задачу
# вместо того, чтобы пожаловаться на аргумент.
if ($explicitBase) {
  git rev-parse --verify --quiet "$explicitBase^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    Log "ОШИБКА: -DiffBase '$explicitBase' не разрешается в коммит этого репозитория."
    exit 2
  }
  $diffBase = $explicitBase
}

if ($taskFiles.Count -gt 0) {
  Log "Файлы задачи ($($taskFiles.Count)): $($taskFiles -join ', ')"
  if ($explicitBase) {
    $diffFull = (git diff $diffBase -- $taskFiles 2>$null | Out-String)
    Log "База дифа задана явно: $diffBase (приёмка уже приземлившейся работы)."
  }
  else {
    $diffFull = (git diff HEAD -- $taskFiles 2>$null | Out-String)
    if ([string]::IsNullOrWhiteSpace($diffFull)) {
      # diff против HEAD пуст — работа уже закоммичена. Сначала пробуем точку расхождения
      # с веткой интеграции (integration.branch, по умолчанию main): в ветке задачи может
      # лежать несколько коммитов (работа агента, слияние main, служебные правки), и HEAD~1
      # тогда указывает не на работу, а на служебный коммит. Живой случай 2026-09-09,
      # eye-of-god TASK-05: работа в 0a7329c, сверху merge main и снятый вердикт, HEAD~1
      # дал пустой диф и FAIL «задача не изменила ни строки» при готовой ветке.
      $intBranch = 'main'
      if ($Cfg -and $Cfg.integration -and $Cfg.integration.branch -and "$($Cfg.integration.branch)".Trim()) {
        $intBranch = "$($Cfg.integration.branch)".Trim()
      }
      $mergeBase = ''
      git rev-parse --verify --quiet "$intBranch^{commit}" *> $null
      if ($LASTEXITCODE -eq 0) {
        $mergeBase = (git merge-base HEAD $intBranch 2>$null | Out-String).Trim()
        $headSha = (git rev-parse HEAD 2>$null | Out-String).Trim()
        if ($mergeBase -and $mergeBase -eq $headSha) { $mergeBase = '' }
      }
      if ($mergeBase) {
        $diffBase = $mergeBase
        $diffFull = (git diff $mergeBase -- $taskFiles 2>$null | Out-String)
        Log "diff против HEAD пуст (работа закоммичена) — база дифа: точка расхождения с $intBranch ($($mergeBase.Substring(0,8)))."
      }
      if ([string]::IsNullOrWhiteSpace($diffFull)) {
        # Ветка не расходится с интеграционной (или расхождение не трогает файлы задачи):
        # показываем, что сделал последний коммит (+ незакоммиченное).
        $diffBase = 'HEAD~1'
        $diffFull = (git diff HEAD~1 -- $taskFiles 2>$null | Out-String)
        Log "diff против HEAD пуст (работа закоммичена) — база дифа переключена на HEAD~1."
      }
    }
  }
  $diffStat = (git diff --stat $diffBase -- $taskFiles 2>$null | Out-String)
}
else {
  Log "ПРЕДУПРЕЖДЕНИЕ: файлы задачи из task-файла не определены — diff по всему дереву."
  $diffStat = (git diff --stat HEAD 2>$null | Out-String)
  $diffFull = (git diff HEAD 2>$null | Out-String)
}
# ПУСТОЙ DIFF — ЭТО ПРОВАЛ, А НЕ ПРЕДУПРЕЖДЕНИЕ.
#
# Гейты проверяют СОСТОЯНИЕ ДЕРЕВА, а не работу задачи. Если задача не тронула ни строки,
# её собственные проверки всё равно зелены — они проходили и до неё. Пока это было
# предупреждением, случалось вот что (прогон g_20260808-120927): четыре задачи подряд не
# изменили ничего, получили PASS «все гейты зелёные», слились вхолостую, их ветки удалили
# как отработанные, а бэклог отчитался «PASS 19/19, итог: ок». Дефекты P1, ради которых
# задачи и заводились, остались в коде — и теперь считались закрытыми.
#
# Задача, которой нечего делать, — это решение человека, а не автоматики: он либо закроет
# её руками, либо перепишет условие. Автоматика обязана сказать «работы нет».
#
# -DiffBase гейт не отменяет: при явной базе диф считается против неё, и пустота против
# неё означает ровно то же самое — файлы задачи не тронуты с той точки.
$emptyDiff = [string]::IsNullOrWhiteSpace($diffFull)
if ($emptyDiff) {
  if ($explicitBase) {
    Log "diff ПУСТ против заданной базы $diffBase — файлы задачи не менялись с этой точки."
  }
  else {
    Log "diff ПУСТ и против HEAD, и против HEAD~1 — задача не изменила ни строки в своих файлах."
  }
}
$diffLines = $diffFull -split "`n"
if ($diffLines.Count -gt 1500) {
  $diffFull = (($diffLines | Select-Object -First 1500) -join "`n") +
              "`n... [diff обрезан на 1500 строк — судья читает реальные файлы Read/Grep по необходимости]"
}

# --- Какие тестеры запускать ---
# Берём из плана агента. Если план явно стрипнут (testers: __none__ — sentinel от
# loop.ps1 M-13/L/M, когда все testers стрипнуты iter-level scope'ом) — пропускаем
# Фазу C полностью. Если план не задан вовсе — дефолт: architecture + api по слоям.
$planNoneSentinel = ($planTesters.Count -eq 1 -and $planTesters[0] -eq '__none__')
if ($planNoneSentinel) {
  $testers = @()
  Log "Фаза C: testers=__none__ sentinel — loop.ps1 стрипнул весь набор по scope. Тестеры пропущены."
}
elseif ($planTesters.Count -gt 0) {
  $testers = $planTesters
}
else {
  # Дефолтный набор тестеров — из config/agents.json (релевантность по diff отбирает loop.ps1/scope-map).
  $testers = @($DefaultTesters)
}
$checksLine = if ($planChecks.Count) { $planChecks -join ' | ' } else { '(нет)' }
Log "План: тестеры=[$($testers -join ', ')] checks=[$checksLine] visual=$planVisual"

# --- Хелпер: один изолированный opencode run, возврат — захваченный stdout ---
function Invoke-Opencode($promptText, $label) {
  $pf = Join-Path $workDir "$Task-$label.prompt.txt"
  $of = Join-Path $workDir "$Task-$label.out.txt"
  $ef = Join-Path $workDir "$Task-$label.err.txt"
  Set-Content -LiteralPath $pf -Value $promptText -Encoding UTF8
  $modelArg = if ($Model) { "--model '$Model'" } else { "" }
  # Промпт — через stdin, НЕ аргументом: он ~150-200 КБ, лимит командной строки ~32 КБ.
  # --format json + lib/oc-pretty.ps1 для читаемого вывода.
  # UTF-8 setup ОБЯЗАТЕЛЕН на старте inner-pwsh: иначе outer pwsh пишет в $of в системной
  # codepage, и Russian text→mojibake (см. инцидент 2026-05-25 с verify/api).
  $ocPretty = Join-Path $PSScriptRoot 'lib\adapters\oc-pretty.ps1'
  $utf8Prefix = "[Console]::InputEncoding=[Text.Encoding]::UTF8;[Console]::OutputEncoding=[Text.Encoding]::UTF8;`$OutputEncoding=[Text.Encoding]::UTF8;"
  $inner = "$utf8Prefix Get-Content -Raw -LiteralPath '$pf' | & opencode run --dangerously-skip-permissions --thinking --format json $modelArg 2>&1 | & pwsh -NoProfile -File '$ocPretty'"
  $startedAt = Get-Date
  try {
    $proc = Start-Process -FilePath 'pwsh' `
      -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $inner) `
      -WorkingDirectory $root -NoNewWindow -PassThru `
      -RedirectStandardOutput $of -RedirectStandardError $ef
    # Heartbeat: open-once FileStream (FileShare.ReadWrite|Delete) дренирует дельту
    # stdout каждый тик через Stream.Position. Старая FS-open-close теряла данные при
    # batched-flush npm-child (Bug B — heartbeat пропустил 37 мин stdout в инциденте
    # 2026-05-26 vision-suite). WaitForExit(2000) — снапнее чем 5s.
    $stdoutReader = _OpenStdoutReader $of
    $pendingTail  = ''
    $lastOutputAt = Get-Date
    $nextPing     = 60
    try {
      while (-not $proc.WaitForExit(2000)) {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        if ($elapsed -ge $StepTimeoutSec) {
          Log "${label}: opencode run TIMEOUT ${StepTimeoutSec}s — принудительный kill."
          try { $proc.Kill($true) } catch { }
          $proc.WaitForExit(5000) | Out-Null
          _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
          return "[${label}: TIMEOUT после ${StepTimeoutSec}s — отчёт неполный, считать недостаточным доказательством]"
        }
        $silentForSec = [int]((Get-Date) - $lastOutputAt).TotalSeconds
        if ($silentForSec -ge $SilentTimeoutSec) {
          Log "${label}: SILENT-TIMEOUT ${SilentTimeoutSec}s (нет новых строк stdout) — принудительный kill."
          try { $proc.Kill($true) } catch { }
          $proc.WaitForExit(5000) | Out-Null
          _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
          return "[${label}: SILENT-TIMEOUT после ${SilentTimeoutSec}s тишины — стрим завис без exit, отчёт неполный]"
        }
        _Drain-Reader -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
        $silentFor = [int]((Get-Date) - $lastOutputAt).TotalSeconds
        if ($silentFor -ge $nextPing) {
          Write-Host ("[{0}] {1} — молчит {2}s" -f (Get-Date -Format 'HH:mm:ss'), $label, $silentFor) -ForegroundColor DarkGray
          $nextPing += 60
        }
      }
      _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
    } catch {
      Log "${label}: ошибка в heartbeat-цикле — $($_.Exception.Message)"
      try { if ($stdoutReader) { $stdoutReader.Dispose() } } catch { }
    }
  } catch {
    Log "${label}: не удалось запустить opencode — $($_.Exception.Message)"
    return "[${label}: запуск opencode провален — $($_.Exception.Message)]"
  }
  if (Test-Path $of) { return (Get-Content -Raw -LiteralPath $of) }
  return "[${label}: пустой вывод opencode]"
}

# --- Хелпер: детерминированная команда (npm run ...), возврат — @{exit; output} ---
function Invoke-Shell($command, $label) {
  $of = Join-Path $workDir "$Task-$label.out.txt"
  $ef = Join-Path $workDir "$Task-$label.err.txt"
  $startedAt = Get-Date
  try {
    $proc = Start-Process -FilePath 'pwsh' `
      -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) `
      -WorkingDirectory $root -NoNewWindow -PassThru `
      -RedirectStandardOutput $of -RedirectStandardError $ef
    # Heartbeat: open-once FileStream через _Drain-Reader. См. комментарий в
    # Invoke-Opencode + Bug B (2026-05-26 vision-suite — heartbeat пропустил 37 мин).
    $stdoutReader = _OpenStdoutReader $of
    $pendingTail  = ''
    $lastOutputAt = Get-Date
    $nextPing     = 60
    try {
      while (-not $proc.WaitForExit(2000)) {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        if ($elapsed -ge $StepTimeoutSec) {
          Log "${label}: команда TIMEOUT ${StepTimeoutSec}s — принудительный kill."
          try { $proc.Kill($true) } catch { }
          $proc.WaitForExit(5000) | Out-Null
          _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
          return @{ exit = -1; output = "[TIMEOUT после ${StepTimeoutSec}s]" }
        }
        $silentForSec = [int]((Get-Date) - $lastOutputAt).TotalSeconds
        if ($silentForSec -ge $SilentTimeoutSec) {
          Log "${label}: SILENT-TIMEOUT ${SilentTimeoutSec}s (нет новых строк stdout) — принудительный kill (zombie после exit / завис stream)."
          try { $proc.Kill($true) } catch { }
          $proc.WaitForExit(5000) | Out-Null
          _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
          return @{ exit = -1; output = "[SILENT-TIMEOUT после ${SilentTimeoutSec}s тишины — процесс жив, но не пишет stdout (zombie/hung stream)]" }
        }
        _Drain-Reader -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
        $silentFor = [int]((Get-Date) - $lastOutputAt).TotalSeconds
        if ($silentFor -ge $nextPing) {
          Write-Host ("[{0}] {1} — молчит {2}s" -f (Get-Date -Format 'HH:mm:ss'), $label, $silentFor) -ForegroundColor DarkGray
          $nextPing += 60
        }
      }
      _Final-Drain -Stream $stdoutReader -PendingTail ([ref]$pendingTail) -LastOutputAt ([ref]$lastOutputAt) -Label $label
    } catch {
      Log "${label}: ошибка в heartbeat-цикле — $($_.Exception.Message)"
      try { if ($stdoutReader) { $stdoutReader.Dispose() } } catch { }
    }
    $ec = $proc.ExitCode
  } catch {
    return @{ exit = -1; output = "[запуск провален: $($_.Exception.Message)]" }
  }
  $out = if (Test-Path $of) { Get-Content -Raw -LiteralPath $of } else { "" }
  if ((Test-Path $ef) -and ((Get-Item $ef).Length -gt 0)) {
    $out += "`n--- stderr ---`n" + (Get-Content -Raw -LiteralPath $ef)
  }
  $ol = $out -split "`n"
  if ($ol.Count -gt 200) { $out = "...[вывод обрезан до последних 200 строк]`n" + (($ol | Select-Object -Last 200) -join "`n") }
  return @{ exit = $ec; output = $out }
}

# M-15 (2026-06-05): компактный хвост РЕАЛЬНОГО провала детерминированного гейта для ИНЛАЙНА
# в промпт судьи. Раньше судья получал лишь ссылку «Вывод — .bcf/verify/...» и пытался
# прочитать файл сам → glob/cwd промахивался → «file not found» → галлюцинация BLOCKED
# (кейс TASK-16: судья не увидел rendered-nav diff и выдал «найди файл» вместо «удали кнопку»).
# Сигнальные строки: упавшие спеки, Expected/Received, rendered nav, unknown=[...].
function Get-DetFailTail($text, [int]$maxLines = 30) {
  if (-not $text) { return '' }
  $signal = '(^\s*(?:x|✘|\d+\))\s)|(\bError:)|(\bExpected:)|(\bReceived:)|(rendered nav)|(^\s*expected:)|(\bunknown\b)|(НЕИЗВЕСТНЫЕ)|(разошлась)|(\.spec\.ts:\d+:\d+)|(\bfailed\b)'
  $hits = @()
  foreach ($ln in ($text -split "`r?`n")) {
    $clean = ($ln -replace '\x1b\[[0-9;]*m', '').TrimEnd()
    if ($clean -and ($clean -match $signal)) { $hits += $clean }
  }
  if ($hits.Count -eq 0) { return '' }
  return (($hits | Select-Object -First $maxLines) -join "`n")
}

# --- Фаза C: тестеры ---
$reports = [ordered]@{}

# M-13/M (2026-05-28): impact-mode. Передаём тестеру `changed_files` этого iter
# и инструктируем проверять ТОЛЬКО релевантные инварианты. Полный аудит —
# только при regression: release (полный сьют всё равно прогоняется отдельно).
# Логика: parent_ref = preIterTreeRef (через env RALPH_PRE_ITER_REF, loop.ps1
# его проставляет перед вызовом verify). Если нет — fallback на HEAD~1..HEAD.
$preIterRef = $env:RALPH_PRE_ITER_REF
$iterChangedFiles = @()
if ($preIterRef) {
  $iterChangedFiles = @((& git -C $root diff --name-only $preIterRef HEAD 2>$null | Where-Object { $_ -and $_.Trim() }))
  if (-not $iterChangedFiles -or $iterChangedFiles.Count -eq 0) {
    $iterChangedFiles = @((& git -C $root diff --name-only $preIterRef 2>$null | Where-Object { $_ -and $_.Trim() }))
  }
}
if (-not $iterChangedFiles -or $iterChangedFiles.Count -eq 0) {
  $iterChangedFiles = @((& git -C $root diff --name-only HEAD~1 HEAD 2>$null | Where-Object { $_ -and $_.Trim() }))
}
$impactMode = ($planRegression -ne 'release')

# Тестеры, которых не нашлось. Держим отдельно: пропущенная роль — это НЕ выполненная
# Фаза C, и вердикт обязан это учитывать, иначе PASS выдаётся за проверку, которой не было.
$missingTesters = @()

foreach ($t in $testers) {
  # Путь берём из config/agents.json (testers[].file), а собираем сами только если там
  # его нет. Схема объявляет это поле, и игнорировать его — значит требовать, чтобы
  # роли лежали ровно там, где угадывает код: переименовал файл в конфиге, а тестер
  # молча пропал.
  $agentFile = ''
  if ($AgentsCfg -and $AgentsCfg.testers) {
    $entry = @($AgentsCfg.testers | Where-Object { $_.name -eq $t -and $_.file }) | Select-Object -First 1
    if ($entry) { $agentFile = Join-Path $root ([string]$entry.file -replace '/', [IO.Path]::DirectorySeparatorChar) }
  }
  if (-not $agentFile) { $agentFile = Join-Path $agentsDir "$t.md" }

  if (-not (Test-Path $agentFile)) {
    # ЭТО НЕ ПРЕДУПРЕЖДЕНИЕ. Пропущенный тестер означает, что Фаза C не выполнялась, а
    # вердикт при этом считается по оставшимся зелёным гейтам — то есть PASS выдаётся
    # за проверку, которой не было. Отсутствие файла роли — дефект конфигурации, и он
    # обязан красить вердикт, а не теряться строкой в логе.
    Log "ОШИБКА: файл роли не найден: $agentFile — тестер '$t' исполнить нечем."
    $missingTesters += $t
    continue
  }
  $agentSpec = Get-Content -Raw -LiteralPath $agentFile
  $impactBlock = if ($impactMode -and $iterChangedFiles.Count -gt 0) {
    $cfList = ($iterChangedFiles | ForEach-Object { "  - $_" }) -join "`n"
    @"
===== IMPACT MODE (M-13/M 2026-05-28) =====
Эта итерация — НЕ release-регресс. Проверяй ТОЛЬКО те инварианты твоей спецификации,
которые могут быть нарушены ПРАВКАМИ ЭТОГО iter (см. список ниже). Игнорируй
проверки, не имеющие отношения к этим файлам.

Изменённые файлы этого iter ($($iterChangedFiles.Count) шт.):
$cfList

Если правки тривиальны (CSS-only, контент строки, переименование локальной
переменной) — отчёт может быть компактным: «нарушений в области правок не
найдено, остальные инварианты не проверялись (impact-mode)».

Полный аудит — только при regression: release в VERIFY-REQUEST.
=========================================
"@
  } else {
    "===== FULL MODE (regression: release или нет данных о iter) =====`nПроверяй все инварианты твоей спецификации.`n"
  }
  $prompt = @"
Действуй строго как субагент-тестер «$t». Спецификация роли — ниже.
Режим: верификация Фазы C задачи $Task. Контекст свежий — ход реализации ты не видел.
Изучи рабочее дерево сам (доступны Read/Grep/Bash/git), сверь с DoD из task-файла и с diff,
выдай отчёт строго в формате, который требует твоя спецификация. Не доверяй формулировкам
агента — проверяй фактами. Не правь код — только верифицируй.

$impactBlock

===== СПЕЦИФИКАЦИЯ РОЛИ ($t) =====
$agentSpec

===== TASK-ФАЙЛ $Task (DoD — раздел «Критерии приёмки») =====
$taskBody

===== git diff --stat HEAD =====
$diffStat

===== git diff HEAD =====
$diffFull
"@
  if ($DryRun) {
    Log "[DryRun] тестер $t — вызов opencode пропущен."
    $reports[$t] = "[DryRun — тестер $t не запускался]"
  }
  else {
    Log "Запуск тестера $t ..."
    $reports[$t] = Invoke-Opencode $prompt $t
    Log "Тестер $t завершён."
  }
}

# --- ОБЯЗАТЕЛЬНЫЕ checks из config/checks.json (авторитет вердикта, ВНЕ агента) ---
# Дыра: checks в VERIFY-REQUEST пишет сам агент → может сузить проверку до tsc и получить
# тривиальный PASS (инцидент: тест на гонку в отправке сообщения НЕ попал в план). Фикс
# (решение 2026-05-30): обязательные проверки задаём МЫ в config/checks.json проекта и
# объединяем с планом — агент не может их убрать. Файл лежит в проекте, а не в движке:
# «что доказывает закрытую задачу» — свойство продукта, а не харнесса.
try {
  $rcFile = Join-Path $root 'config\checks.json'
  if (Test-Path $rcFile) {
    $rc = Get-Content -Raw -LiteralPath $rcFile | ConvertFrom-Json
    $required = @()
    if ($rc.$Task) { $required += @($rc.$Task) }
    elseif ($rc._default) { $required += @($rc._default) }
    foreach ($rcmd in $required) {
      if ($rcmd -and ($planChecks -notcontains $rcmd)) { $planChecks += $rcmd }
    }
    if ($required.Count) { Log "Required-checks ($Task): + $($required.Count) обязательных проверок из config/checks.json (агент не может убрать)." }
  }
} catch { Log "ПРЕДУПРЕЖДЕНИЕ: config/checks.json не разобран ($($_.Exception.Message))." }

# --- Детерминированные checks (план агента ∪ обязательные) ---
$checkReports = [ordered]@{}
$checksFailed = $false   # любой ненулевой exit детерминированной проверки → блок PASS
$ci = 0
foreach ($cmd in $planChecks) {
  $ci++
  if ($DryRun) {
    Log "[DryRun] check #${ci}: $cmd — пропуск."
    $checkReports[$cmd] = "[DryRun]"
    continue
  }
  Log "Проверка #${ci}: $cmd ..."
  $r = Invoke-Shell $cmd "check$ci"
  $checkReports[$cmd] = "exit=$($r.exit)`n$($r.output)"
  if ($r.exit -ne 0) { $checksFailed = $true }
  Log "Проверка #${ci} завершена → exit $($r.exit)"
}

# --- Фаза J: сквозные сценарии продукта ---
#
# Стоит ОТДЕЛЬНО от checks и раньше визуальной фазы, потому что отвечает на другой вопрос.
# checks доказывают задачу: «её тест зелёный». Фаза J доказывает продукт: «человек может
# выполнить работу, ради которой продукт существует». Прогон clinic-scheduler 2026-08-09
# показал, что первое не влечёт второго: 35 задач закрылись PASS при нуле работающих
# клиентских путей — каждый экран проверялся против МОКА собственного API, и ни один
# гейт не поднимал приложение.
#
# Гейт БЛОКИРУЮЩИЙ, когда реестр заведён, и МОЛЧАЛИВО-ЧЕСТНЫЙ, когда нет: отсутствие
# реестра — дефект настройки проекта, а не провал конкретной задачи, и красить им вердикт
# нечестно. Но и промолчать нельзя — иначе PASS снова будет читаться как «продукт готов».
# Поэтому факт «сценарии не заведены» уезжает в вердикт текстом.
$journeyFailed  = $false
$journeyReport  = ''
$journeyState   = 'not-configured'
if ($DryRun) {
  $journeyReport = '[DryRun] Фаза J (сквозные сценарии) — пропуск.'
  Log $journeyReport
} else {
  $jg = Invoke-Shell "pwsh -NoProfile -File `"$PSScriptRoot\journey-gate.ps1`" -ProjectRoot `"$root`"" 'journeys'
  switch ($jg.exit) {
    0 {
      $journeyState  = 'ok'
      $journeyReport = "Фаза J: сквозные сценарии продукта — PASS (config/journeys.json).`n$(($jg.output -split "`r?`n" | Select-Object -Last 12) -join "`n")"
    }
    3 {
      $journeyState  = 'not-configured'
      $journeyReport = "Фаза J: реестр сквозных сценариев НЕ ЗАВЕДЁН либо все пути ещё в статусе planned. " +
                       "Вердикт PASS доказывает только гейты уровня задачи; утверждать, что продуктом можно " +
                       "пользоваться, этим прогоном НЕЛЬЗЯ.`n$(($jg.output -split "`r?`n" | Select-Object -Last 10) -join "`n")"
    }
    4 {
      # Частичная доказанность — это НЕ провал задачи: она не обязана доказывать чужие
      # пути. Но и молчать нельзя, иначе PASS снова прочитают как «продукт работает».
      $journeyState  = 'partial'
      $journeyReport = "Фаза J: доказанные пути зелёные, но часть путей ещё объявлена planned — продукт " +
                       "доказан ЧАСТИЧНО.`n$(($jg.output -split "`r?`n" | Select-Object -Last 12) -join "`n")"
    }
    default {
      $journeyState  = 'fail'
      # ЗАДАЧА ОТВЕЧАЕТ ЗА СВОЙ ПУТЬ, А НЕ ЗА ЧУЖОЙ ДОЛГ.
      #
      # Прямолинейный вариант «любой красный сценарий = FAIL» останавливает очередь на
      # первой же задаче: пока волна не доехала до конца, часть путей красная по
      # определению, и задача, которая к ним не имеет отношения, не может их починить.
      # Ровно эта ошибка уже была допущена в визуальной фазе и лечилась там же (M-16):
      # чужой предсуществующий долг чинит его владелец, не блокируя всех.
      #
      # Владение берётся из данных, а не из догадки: у сценария в config/journeys.json
      # есть поле task. Задача блокируется, если КРАСЕН СЦЕНАРИЙ, КОТОРЫЙ ОНА ОБЕЩАЛА
      # ЗАКРЫТЬ. Остальные красные едут в вердикт текстом — их видно, но они не врут
      # про эту задачу.
      $ownJourneys = @()
      try {
        $jr = Join-Path $root 'config\journeys.json'
        if (Test-Path -LiteralPath $jr) {
          $reg = Get-Content -Raw -LiteralPath $jr | ConvertFrom-Json
          $ownJourneys = @($reg.journeys | Where-Object { $_.id -and $_.task -and ($_.task -match [regex]::Escape($Task)) } |
                           ForEach-Object { [string]$_.id })
        }
      } catch { }

      $ownRed = @()
      foreach ($jid in $ownJourneys) {
        $one = Invoke-Shell "pwsh -NoProfile -File `"$PSScriptRoot\journey-gate.ps1`" -ProjectRoot `"$root`" -Only $jid" "journey-$jid"
        if ($one.exit -ne 0) { $ownRed += $jid }
      }
      $journeyFailed = ($ownRed.Count -gt 0)
      Log "Фаза J: своих сценариев у задачи — $($ownJourneys.Count) ($($ownJourneys -join ', ')); из них красных — $($ownRed.Count)"

      $jt = Get-DetFailTail $jg.output
      if (-not $jt) { $jt = (($jg.output -split "`r?`n") | Select-Object -Last 25) -join "`n" }
      $verdictWordJ = if ($journeyFailed) { 'FAIL (свой сценарий красный)' } else { 'ADVISORY (красны только чужие сценарии)' }
      $journeyReport = "Фаза J: сквозные сценарии продукта — $verdictWordJ." +
        "`nСвои сценарии задачи (config/journeys.json → task): $(if ($ownJourneys.Count) { $ownJourneys -join ', ' } else { '(нет — задача не обещала закрыть ни один путь)' })" +
        "$(if ($ownRed.Count) { "`nИз них КРАСНЫЕ: $($ownRed -join ', ')" })" +
        "`nФАКТ ПРОВАЛА (машинный вывод, инлайн):`n$jt"
    }
  }
  Log "Фаза J завершена → $journeyState (блокирует: $journeyFailed)"
}

# --- Фаза D: визуальная (детерминированный вижн-сьют + LLM-критик) ---
$visualReport = "(визуальная Фаза D не запрашивалась планом)"
$visualFailed = $false   # детерминированный контракт-gate (Фаза D) — hard-floor для PASS
# M-13/H: спец-маркер __none__ из auto-detect означает «правки не маппятся ни на
# один vision-slug» — пропускаем Фазу D полностью, экономим ~10 мин.
$visionNone = ($planVisionSlugs.Count -eq 1 -and $planVisionSlugs[0] -eq '__none__')
if ($visionNone) {
  $visualReport = "(страничный vision: __none__ — но глобальный layout-contract (shell) гоняется всегда)"
  Log $visualReport
}
# Layout-contract — ГЛОБАЛЬНЫЙ shell-gate (root-cause 2026-05-30): запускается в КАЖДОМ verify,
# даже при __none__ и без планового страничного vision. Закрывает additive-галлюцинации
# оболочки (фантомный пункт «Чат», рельс «Саманта рядом»), которые раньше маппились в __none__
# → Фаза D пропускалась целиком → проходили зелёными.
$hasLayoutSpec = Test-Path (Join-Path $root (Join-Path $VisionContractDir "layout-contract.spec.ts"))
if ($planVisual -or $hasLayoutSpec) {
  if ($DryRun) {
    Log "[DryRun] Фаза D (visual contract) — пропуск."
    $visualReport = "[DryRun]"
  }
  else {
    # Фаза D — ДЕТЕРМИНИРОВАННЫЙ контракт-gate (2026-05-29, решение): DOM/токен/layout-
    # ассерты дизайна your design reference против ЖИВОГО приложения (tests/electron/<slug>-contract.spec.ts).
    # Заменил недетерминированного LLM-судью (<model>) + пиксельный golden, требовавший
    # одобрения человеком. Полностью автономно: без человека, без <model>, нулевой расход
    # токенов, воспроизводимо. PASS/FAIL берётся из exit-кода playwright.
    # Страничный scope считаем ТОЛЬКО когда план реально просил vision; иначе — layout-only.
    $effectivePages = @()
    if ($planVisual -and -not $visionNone) {
      $effectivePages = $planVisionSlugs
      if ($effectivePages.Count -eq 0 -and $env:BCF_VISION_PAGES) {
        $effectivePages = @(($env:BCF_VISION_PAGES -split '[,\s]+') | Where-Object { $_ })
      }
    }
    # Маппинг slug → файл контракта tests/electron/<safe>-contract.spec.ts. Берём только заведённые.
    $contractSpecs    = @()
    $missingContracts = @()
    $scopeBySlug = ($effectivePages.Count -gt 0 -and $planRegression -ne 'release')
    if ($scopeBySlug) {
      foreach ($slug in $effectivePages) {
        if ($slug -eq '__none__') { continue }
        $safe = ($slug -replace '[\\/]+','-')
        if (Test-Path (Join-Path $root (Join-Path $VisionContractDir "$safe-contract.spec.ts"))) { $contractSpecs += "$safe-contract" }
        else { $missingContracts += $slug }
      }
    } elseif ($planVisual -and -not $visionNone) {
      # full / release / no-scope (но vision запрошен) → все контракт-спеки
      $contractSpecs += '-contract'
    }

    # M-16 (2026-05-30): layout-contract (shell) — БЛОКИРУЮЩИЙ только когда задача РЕАЛЬНО трогает
    # shell (slug 'layout' в scope) или при полном регрессе. Иначе — ADVISORY: гоняем и репортим,
    # но НЕ валим вердикт. Причина: глобальный hard-shell-gate ронял задачи на ЧУЖОМ/pre-existing
    # shell-долге (TASK-04: «Чат»/«Саманта рядом» от другой работы валили несвязанные задачи, и
    # результат флипал по общему working-tree). Anti-hallucination сохранён: задача, которая сама
    # меняет shell, гейтится жёстко; pre-existing долг чинит его owner (TASK-16), не блокируя всех.
    $isFullRun    = ($contractSpecs -contains '-contract')
    $shellInScope = $isFullRun -or ($effectivePages -contains 'layout')

    # HARD FAIL для in-scope экрана без контракт-спека (M-15) сохраняется.
    $missingHardFail = ($missingContracts.Count -gt 0)
    # Страничные спеки = всё, кроме отдельного layout-contract (его гоняем ниже своим прогоном).
    $pageSpecs = @($contractSpecs | Where-Object { $_ -ne 'layout-contract' } | Select-Object -Unique)

    if ($pageSpecs.Count -eq 0 -and -not $hasLayoutSpec) {
      $visualFailed = $missingHardFail
      $verdictWord = if ($visualFailed) { 'FAIL' } else { 'PASS' }
      $visualReport = "Фаза D: контракт-gate отсутствует для in-scope экранов [$($missingContracts -join ', ')] → $verdictWord (hard-floor). Заведи tests/electron/<slug>-contract.spec.ts."
      Log $visualReport
    } else {
      $builtOnce = $false
      # 1) Страничные/полные контракты — ВСЕГДА блокирующие (это собственные экраны задачи).
      $pageFailed = $false; $pageReport = ''
      if ($pageSpecs.Count -gt 0) {
        $pageFilter = ($pageSpecs -join ' ')
        Log "Фаза D: контракт-gate (build + playwright [$pageFilter]) ..."
        $null = Invoke-Shell $VisionBuildCmd "vision-contract-build"; $builtOnce = $true
        $cr = Invoke-Shell "$VisionContractCmd -- $pageFilter" "vision-contract"
        $pageFailed = ($cr.exit -ne 0)
        $pageReport = "страничный контракт [$pageFilter]: $(if ($pageFailed) { 'FAIL' } else { 'PASS' }) (exit=$($cr.exit))"
        if ($pageFailed) {
          $pt = Get-DetFailTail $cr.output
          if ($pt) { $pageReport += "`n  ФАКТ ПРОВАЛА (машинный вывод, инлайн — файл читать НЕ нужно):`n$pt" }
        }
      }
      # 2) Layout-contract (shell) — отдельный прогон. В full-режиме он уже в pageSpecs ('-contract'),
      #    отдельно не гоняем. В scoped — гоняем, но блокирует ТОЛЬКО при $shellInScope.
      $layoutFailed = $false; $layoutReport = ''
      if ($hasLayoutSpec -and -not $isFullRun) {
        if (-not $builtOnce) { $null = Invoke-Shell $VisionBuildCmd "vision-contract-build" }
        $lr = Invoke-Shell "$VisionContractCmd -- layout-contract" "vision-contract-layout"
        $layoutFailed = ($lr.exit -ne 0)
        $mode = if ($shellInScope) { 'БЛОКИРУЮЩИЙ (задача трогает shell)' } else { 'ADVISORY (shell не в scope задачи)' }
        $layoutReport = "shell layout-contract: $(if ($layoutFailed) { 'FAIL' } else { 'PASS' }) (exit=$($lr.exit); $mode)"
        if ($layoutFailed) {
          $lt = Get-DetFailTail $lr.output
          if ($lt) { $layoutReport += "`n  ФАКТ ПРОВАЛА (машинный вывод, инлайн — файл читать НЕ нужно):`n$lt" }
        }
        if ($layoutFailed -and -not $shellInScope) {
          $layoutReport += " [shell нарушает your design reference, но НЕ этой задачей — чинить в TASK-16/owner, не блокирует]"
        }
      }
      $visualFailed = ($pageFailed -or $missingHardFail -or ($shellInScope -and $layoutFailed))
      $verdictWord = if ($visualFailed) { 'FAIL' } else { 'PASS' }
      $parts = @($pageReport, $layoutReport) | Where-Object { $_ }
      if ($missingHardFail) { $parts += "[HARD-FAIL] in-scope экран(ы) без контракт-спека: $($missingContracts -join ', ')" }
      $visualReport = "Контракт-gate Фаза D (DOM/токены/layout your design reference) → $verdictWord. " + ($parts -join '; ') + ".`n(ФАКТ провала инлайнится выше — НЕ нужно читать файлы; полный вывод при желании: .bcf/verify/$Task-vision-contract*.out.txt.)"
      Log "Фаза D завершена → $verdictWord (page=$pageFailed, layout=$layoutFailed, shellInScope=$shellInScope, missing=$missingHardFail)"
    }
  }
}

# M-09 G (2026-05-25): lint-gate как hard-evidence для судьи.
# Раньше: судья не видел lint-violations, выбирал failing_criterion из других гипотез
# (TASK-03 iter=1 → "GPU vram/name/driver" при 21 console.log в services). Теперь:
# гоняем lint-gate, кладём JSON в prompt судьи; если LINT-FAIL — после парсинга вердикта
# применяем hard-floor: PASS → NEEDS-MORE-EVIDENCE с criterion `lint:<rule>`.
$lintEvidence = ""
$lintFailed   = $false
$lintViolations = @()
$lintGateScript = Join-Path $PSScriptRoot 'lint-gate.ps1'
if (Test-Path $lintGateScript) {
  $lintJson = & pwsh -NoProfile -File $lintGateScript -Repo $root -JsonOutput 2>&1 | Out-String
  $lintExit = $LASTEXITCODE
  if ($lintExit -eq 1) {
    $lintFailed = $true
    try {
      $lintParsed = $lintJson | ConvertFrom-Json -ErrorAction Stop
      foreach ($v in @($lintParsed.findings)) {
        $lintViolations += [ordered]@{
          rule     = $v.check
          count    = $v.count
          severity = $v.severity
        }
      }
    } catch {
      Log "ПРЕДУПРЕЖДЕНИЕ: lint-gate JSON не распарсен — передаём текст."
    }
  }
  $lintEvidence = "exit=$lintExit`n" + $lintJson.Trim()
}
else {
  $lintEvidence = "(lint-gate.ps1 не найден)"
}

# --- Сборка блоков для судьи ---
# Тестеры outputят килобайты рассуждений; судье нужен только финальный вердикт-блок.
# Стратегия: если есть явный маркер "### Verdict" / "## Tester verdict" — режем от него
# до конца. Иначе — последние 80 строк (там обычно verdict-таблица).
# Полный отчёт остаётся в .bcf/verify/$Task-$tester.out.txt — судья читает Read'ом
# при сомнении.
function Compress-TesterReport($text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return $text }
  $m = [regex]::Match($text, '(?ims)^(#{1,3}\s*(Tester verdict|Verdict|Итог|Заключение)\b.*)$')
  if ($m.Success) {
    return $text.Substring($m.Index)
  }
  $lines = $text -split "`n"
  if ($lines.Count -le 80) { return $text }
  return "...[начало отчёта обрезано — последние 80 строк; полный текст в .bcf/verify/]`n" +
         (($lines | Select-Object -Last 80) -join "`n")
}

$reportsBlock = ""
foreach ($k in $reports.Keys) {
  $compact = Compress-TesterReport $reports[$k]
  $reportsBlock += "`n===== ОТЧЁТ ТЕСТЕРА: $k (см. .bcf/verify/$Task-$k.out.txt — полный) =====`n" + $compact + "`n"
}
if (-not $reportsBlock) { $reportsBlock = "(тестеры не запускались)" }

$checksBlock = ""
foreach ($k in $checkReports.Keys) {
  $checksBlock += "`n--- КОМАНДА: $k ---`n" + $checkReports[$k] + "`n"
}
if (-not $checksBlock) { $checksBlock = "(детерминированные проверки планом не запрашивались)" }

# --- Фаза E: судья ---
$judgeFile = Join-Path $root $JudgeAgentFile
if (-not (Test-Path $judgeFile)) { Log "ОШИБКА: $judgeFile не найден."; exit 2 }
# Полную судейскую спеку в промпт НЕ заталкиваем — это лишний input на каждый прогон,
# и она и так живёт в файле определения агента (бэкенд подхватит её как subagent
# definition). В промпте — компактная директива.

$judgePrompt = @"
Ты — субагент-судья ($JudgeName). Полная спека (rubric PROVEN/CLAIMED/BLOCKED/CONTRADICTED,
cross-check-правила, антипаттерны) — в $JudgeAgentFile. Если сомневаешься
в правиле — открой Read'ом этот файл.

Вынеси вердикт по задаче $Task. Реализацию ты не видел — суди по DoD из task-файла, diff,
отчётам тестеров (компактные хвосты — полные в .bcf/verify/), checks и визуальной Фазы D.
При сомнении в строке диффа / содержимом файла — ЧИТАЙ файл инструментом Read; не
достраивай по памяти. Файл tasks/.verdicts/$Task.md пишет обвязка ПОСЛЕ тебя — его
отсутствие сейчас не дефект.

ФОРМАТ ОТВЕТА — строго:

1. Сначала JSON-блок (между тройными кавычками с языком json):
   ``\`json
   {
     "verdict": "PASS" | "FAIL" | "NEEDS-MORE-EVIDENCE",
     "assertions": [
       {"id": 1, "claim": "<коротко>", "status": "PROVEN|CLAIMED|BLOCKED|CONTRADICTED", "evidence": "<≤120 симв., ссылка на отчёт/diff/файл>"}
     ],
     "cross_checks": ["<коротко, какие из #1..#12 применил и результат>"],
     "remediation": ["<императивный пункт>", "..."]
   }
   ``\`

2. Затем короткий narrative ≤ 200 слов: главные обоснования + risk-if-overridden.

3. Финальная строка ровно: ``Verdict: **PASS**`` (или **FAIL** / **NEEDS-MORE-EVIDENCE**) —
   для надёжного парсинга обвязкой.

Не пиши длинных таблиц assertions в markdown — они в JSON. Не повторяй diff. Не пересказывай
отчёты тестеров — ссылайся.

===== TASK-ФАЙЛ $Task =====
$taskBody

===== git diff --stat HEAD =====
$diffStat

===== git diff HEAD (обрезан до 1500 строк) =====
$diffFull

===== ОТЧЁТЫ ТЕСТЕРОВ (Фаза C, компактные хвосты) =====
$reportsBlock

===== ДЕТЕРМИНИРОВАННЫЕ ПРОВЕРКИ =====
$checksBlock

===== СКВОЗНЫЕ СЦЕНАРИИ ПРОДУКТА (Фаза J) =====
$journeyReport

===== ВИЗУАЛЬНАЯ ФАЗА D =====
$visualReport

===== LINT-GATE (M-09 G — hard evidence; PASS-вердикт ЗАПРЕЩЁН если lint failed) =====
$lintEvidence
"@

if ($DryRun) {
  Log "[DryRun] судья не запускался. Обвязка проверена: тестеры=$($testers.Count), checks=$($planChecks.Count), visual=$planVisual."
  exit 0
}

Log "Запуск судьи $JudgeName (backend, model=$JudgeModel) ..."
# Invoke-Opencode не принимает $JudgeModel параметром (он берёт $Model глобал),
# поэтому временно подменяем $Model для этого вызова.
$_savedModel = $Model
$Model = $JudgeModel
$judgeOut = Invoke-Opencode $judgePrompt $JudgeName
$Model = $_savedModel
Log "Судья завершён."

# --- Вердикт судьи: СОВЕЩАТЕЛЬНЫЙ (2026-05-30, решение) ---
# LLM-судья недетерминирован и галлюцинирует (напр. ложно заявил TASK-02=FAIL при verdict:PASS
# в файле). Его вердикт больше НЕ авторитет — парсим только как мнение для notes/remediation.
$judgeVerdict = 'NEEDS-MORE-EVIDENCE'
$jsonBlock = [regex]::Match($judgeOut, '(?s)```json\s*(\{.*?\})\s*```')
if ($jsonBlock.Success) {
  try {
    $parsed = $jsonBlock.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    if ($parsed.verdict -and $parsed.verdict -match '^(PASS|FAIL|NEEDS-MORE-EVIDENCE)$') { $judgeVerdict = $parsed.verdict }
  } catch {
    Log "ПРЕДУПРЕЖДЕНИЕ: JSON-блок судьи не разобран ($($_.Exception.Message))."
  }
}
if ($judgeVerdict -eq 'NEEDS-MORE-EVIDENCE' -and -not $jsonBlock.Success) {
  $m = [regex]::Match($judgeOut, '(?im)^\s*Verdict:\s*\*\*(PASS|FAIL|NEEDS-MORE-EVIDENCE)\*\*')
  if ($m.Success) { $judgeVerdict = $m.Groups[1].Value }
  else {
    $m = [regex]::Match($judgeOut, '(?s)###\s*Verdict.*?\*\*(PASS|FAIL|NEEDS-MORE-EVIDENCE)\*\*')
    if ($m.Success) { $judgeVerdict = $m.Groups[1].Value }
    else {
      $m2 = [regex]::Match($judgeOut, '\*\*(PASS|FAIL|NEEDS-MORE-EVIDENCE)\*\*')
      if ($m2.Success) { $judgeVerdict = $m2.Groups[1].Value }
    }
  }
}
Log "Судья (совещательно, НЕ авторитет): $judgeVerdict"

# --- ДЕТЕРМИНИРОВАННЫЙ ВЕРДИКТ (авторитет) ---
# PASS ⟺ все детерминированные гейты зелёные: checks (tsc/electron, exit 0), lint-gate,
# контракт-gate (визуальный, если planVisual). LLM-судья и LLM-тестеры — совещательные, на
# вердикт НЕ влияют (решение 2026-05-30: обвязка автономна, флаки-LLM не решает).
$gateFailures = @()
# ПЕРВЫЙ ГЕЙТ — «РАБОТА ВООБЩЕ БЫЛА». Он стоит раньше остальных не для красоты: все
# прочие проверки говорят о состоянии дерева, и на нетронутом дереве они зелены по
# определению. Без этой строки задача, не сделавшая ничего, получает PASS «все гейты
# зелёные» — и закрывается вместе со своей причиной существования.
if ($emptyDiff) { $gateFailures += 'пустой diff: задача не изменила ни строки в своих файлах' }
if ($checksFailed) { $gateFailures += 'checks' }
if ($missingTesters.Count) { $gateFailures += 'testers-missing:' + ($missingTesters -join '|') }
if ($lintFailed)   { $gateFailures += 'lint:' + (($lintViolations | ForEach-Object { $_.rule }) -join '|') }
if ($visualFailed) { $gateFailures += 'visual-contract' }
if ($journeyFailed) { $gateFailures += 'journeys' }
if ($gateFailures.Count -eq 0) {
  $verdict = 'PASS'
  Log "ВЕРДИКТ (детерминированный): PASS — все гейты зелёные (checks+lint+contract). Судья совещательно: $judgeVerdict."
} else {
  $verdict = 'FAIL'
  $failingCriterionOverride = ($gateFailures -join ',')
  Log "ВЕРДИКТ (детерминированный): FAIL — провалены гейты: $($gateFailures -join ', '). Судья совещательно: $judgeVerdict."
}

$fp = (git diff HEAD 2>$null | git hash-object --stdin 2>$null)
if ([string]::IsNullOrWhiteSpace($fp)) { $fp = 'none' }
$today = Get-Date -Format 'yyyy-MM-dd'

# Раздел ремедиации судьи — попадёт в STATE.md как backpressure следующей итерации.
# Источник №1 — JSON-поле "remediation" (массив строк). Fallback — legacy "### To remediate".
$remediation = ""
if ($jsonBlock.Success -and $parsed -and $parsed.remediation) {
  $items = @($parsed.remediation)
  if ($items.Count -gt 0) {
    $remediation = (($items | ForEach-Object { "- $_" }) -join "`n")
  }
}
if ([string]::IsNullOrWhiteSpace($remediation)) {
  $rm = [regex]::Match($judgeOut, '(?s)###\s*To remediate(.*?)(\r?\n###|\z)')
  if ($rm.Success) { $remediation = $rm.Groups[1].Value.Trim() }
}
if ($lintFailed) {
  $lintRem = ($lintViolations | ForEach-Object { "- LINT-FAIL: $($_.rule) ($($_.count)× violations, severity=$($_.severity)) — исправь ДО следующего VERIFY-REQUEST" }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($remediation)) { $remediation = $lintRem }
  else { $remediation = $lintRem + "`n" + $remediation }
}
if ($journeyFailed) {
  $jRem = "- JOURNEY-FAIL: сквозной сценарий продукта красный — человек не может выполнить путь, ради которого продукт существует. " +
          "Это дороже любого другого гейта: тесты задачи могут остаться зелёными, а продуктом пользоваться нельзя. " +
          "Прогони `pwsh harness/journey-gate.ps1` и чини конкретный сценарий ДО следующего VERIFY-REQUEST"
  if ([string]::IsNullOrWhiteSpace($remediation)) { $remediation = $jRem }
  else { $remediation = $jRem + "`n" + $remediation }
}
if ($visualFailed) {
  $visRem = "- VISUAL-CONTRACT-FAIL: контракт дизайна your design reference нарушен (детерминированные DOM/токен/layout-ассерты) — открой .bcf/verify/$Task-vision-contract.out.txt, чини конкретные упавшие проверки ДО следующего VERIFY-REQUEST"
  if ([string]::IsNullOrWhiteSpace($remediation)) { $remediation = $visRem }
  else { $remediation = $visRem + "`n" + $remediation }
}
if ([string]::IsNullOrWhiteSpace($remediation)) {
  $remediationBlock = '  (судья не дал раздел ремедиации — см. полный вывод)'
}
else {
  $remediationBlock = (($remediation -split "`r?`n") | ForEach-Object { '  ' + $_ }) -join "`n"
}

$testerLines = ($reports.Keys | ForEach-Object { "  ${_}: .bcf/verify/$Task-$_.out.txt" }) -join "`n"
if ([string]::IsNullOrWhiteSpace($testerLines)) { $testerLines = "  (тестеры не запускались)" }

# W2: собираем machine-aggregated evidence (Tejas IBM — judge должен видеть tool-trace, не output).
$evidence = Collect-Evidence -Repo $root -TaskFiles $taskFiles -VerifyWorkDir $workDir
$evidenceMd = Format-EvidenceMd -Evidence $evidence

# Чем получен этот вердикт: версия фабрики и хэш файла графа, если задача шла графом.
# Без этих двух строк разбор чужого вердикта начинается с вопроса «на чём это гонялось»,
# и ответа нет ни в одном файле прогона.
$provenance = (Get-BcfProvenanceLines) -join "`n"

$verdictBody = @"
# Verdict — $Task
verdict: $verdict
date: $today
$provenance
diff_fingerprint: $fp
diff_base: $diffBase$(if ($explicitBase) { ' (задана человеком: приёмка уже приземлившейся работы)' })
verified_by: harness/verify.ps1 — Фазы C-E (всё через opencode; кодинг/тестеры/судья — $Model, vision — $VisionModel, судья — $JudgeModel)
plan:
  testers: $($testers -join ', ')
  checks: $checksLine
  visual: $planVisual
journeys: $journeyState
testers:
$testerLines
notes: |
  Вердикт ДЕТЕРМИНИРОВАННЫЙ: $verdict — функция гейтов (checks/lint/contract-gate/journeys).
  $(if ($journeyState -eq 'not-configured') {
    'ГРАНИЦА ЭТОГО ВЕРДИКТА: сквозные сценарии продукта не заведены (config/journeys.json).
  PASS означает «гейты задачи зелёные», а НЕ «продуктом можно пользоваться». Проверено
  состояние дерева; ни один гейт приложение не запускал.'
  } elseif ($journeyState -eq 'ok') {
    'Сквозные сценарии продукта (Фаза J) зелёные: путь пользователя проверен, а не только дерево.'
  } elseif ($journeyState -eq 'partial') {
    'ГРАНИЦА ЭТОГО ВЕРДИКТА: доказана только ЧАСТЬ путей продукта, остальные объявлены
  в config/journeys.json как planned. PASS относится к этой задаче, а не к продукту.'
  } else {
    'Сквозные сценарии продукта (Фаза J) КРАСНЫЕ — см. remediation.'
  })
  LLM-судья judge ($Model) — СОВЕЩАТЕЛЬНЫЙ (мнение: $judgeVerdict), на вердикт не влияет
  (недетерминирован/галлюцинирует). Полный вывод судьи: .bcf/verify/$Task-judge.out.txt
remediation: |
$remediationBlock

$evidenceMd
"@
$verdictFile = Join-Path $verdictDir "$Task.md"
New-Item -ItemType Directory -Force -Path $verdictDir | Out-Null
Set-Content -LiteralPath $verdictFile -Value $verdictBody -Encoding UTF8
# «Записан» — утверждение о ФАКТЕ, поэтому оно проверяется. При $ErrorActionPreference =
# 'Continue' неудачная запись не роняет скрипт, и строка «Вердикт записан» печаталась
# независимо от того, появился файл или нет: цикл потом искал его и не находил, а на
# экране всё выглядело нормально.
if (Test-Path $verdictFile) {
  Log "Вердикт записан: $verdictFile → $verdict"
} else {
  Log "ОШИБКА: вердикт НЕ записан ($verdictFile) — цикл не увидит результат верификации и будет считать, что её не было."
}

# W3: emit verdict-recorded event для harness памяти + state projection.
$remediationItems = @()
if ($jsonBlock.Success -and $parsed -and $parsed.remediation) {
  $remediationItems = @($parsed.remediation)
}
$failingCriterion = ''
if ($parsed -and $parsed.assertions) {
  $contradicted = @($parsed.assertions | Where-Object { $_.status -eq 'CONTRADICTED' -or $_.status -eq 'CLAIMED' } | Select-Object -First 1)
  if ($contradicted) { $failingCriterion = $contradicted.claim }
}
if ($failingCriterionOverride) { $failingCriterion = $failingCriterionOverride }
Append-Event -EventType 'verdict-recorded' -TaskId $Task -Phase 'E' `
  -Payload @{
    verdict             = $verdict
    diff_fingerprint    = $fp
    judge_model         = $JudgeModel
    judge_effort        = $JudgeEffort
    testers             = $testers
    plan_checks         = $planChecks
    visual              = $planVisual
    remediation_count   = $remediationItems.Count
    failing_criterion   = $failingCriterion
  } `
  -IdempotencyKey "verdict:$($Task):$fp"
Compute-State | Out-Null

# Маркер плана отработан — убираем (verify.ps1 владеет им, не loop.ps1).
Remove-Item $planFile -Force -ErrorAction SilentlyContinue

if ($verdict -eq 'PASS') { exit 0 } else { exit 1 }
