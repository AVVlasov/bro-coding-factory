# loop/run-all.ps1 — ОВЕРНАЙТ-оркестратор: прогоняет ВСЕ задачи подряд, автономно.
#
# Для каждой задачи в числовом порядке: если уже verdict: PASS — пропуск; иначе запускает
# обычный однозадачный loop.ps1 <task> -AutoAdvance (синхронно, в этом же окне). После выхода
# проверяет вердикт: PASS → следующая; не-PASS (затык/гейт/лимит) → ЗАПИСЫВАЕТ и идёт дальше
# (ночью не блокируемся на одной задаче). Гейты зависимостей соблюдаются самим loop.ps1
# (если предшественник не PASS — задача-наследник заблокируется и попадёт в «не сделано»).
#
# Подавляет per-task попапы Windows (в loop.ps1 через -AutoAdvance); в конце — ОДИН итоговый
# REVIEW.md + одно окно + звук.
#
# Модель и task-id префикс берутся из config/harness.json (models.code, taskIdPrefix) —
# не хардкодятся. loop.ps1 запускается через $PSScriptRoot.
#
# Запуск: pwsh loop/run-all.ps1   (обычно через loop/start.ps1 без аргумента → start.ps1)
#   pwsh loop/run-all.ps1 -PerTaskMax 30
# Досрочно остановить — создать файл loop/STOP (проверяется между задачами).

param(
  [int]$PerTaskMax = 40,                                  # потолок итераций НА ОДНУ задачу
  [string]$Model = "",                                    # пусто → из config/harness.json (models.code)
  [switch]$NoAutoRollback
)

$ErrorActionPreference = "Continue"
$root    = Split-Path $PSScriptRoot -Parent
$loopPs1 = Join-Path $PSScriptRoot "loop.ps1"
$logFile = Join-Path $PSScriptRoot "loop.log"
$stopFile= Join-Path $PSScriptRoot "STOP"
$reviewFile = Join-Path $PSScriptRoot "REVIEW.md"
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

function Verdict-Pass($t) {
  $vf = Join-Path $root "tasks\.verdicts\$t.md"
  if (!(Test-Path $vf)) { return $false }
  return [bool](Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
}

# Префикс-предшественники из «**Gate-вход:**» (как в loop.ps1: только <PREFIX>-\d+; иные
# гейты вроде decision-record игнорируются — loop.ps1 на них тоже не блокирует).
$predRegex = [regex]::Escape($taskIdPrefix) + '-\d+'
function Get-GatePreds($t) {
  $tf = Get-ChildItem (Join-Path $root "tasks") -Filter "$t-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $tf) { return @() }
  $line = Select-String -Path $tf.FullName -Pattern '^\*\*Gate-вход' | Select-Object -First 1
  if (-not $line) { return @() }
  if ($line.Line -match 'Gate-вход[^:]*:\**\s*(.+)$') {
    $val = $Matches[1]
    if ($val -match '^\s*нет\b') { return @() }
    return @([regex]::Matches($val, $predRegex) | ForEach-Object { $_.Value } | Select-Object -Unique | Where-Object { $_ -ne $t })
  }
  return @()
}

# --- Очередь: top-level <PREFIX>-NN (без подзадач <PREFIX>-NN.M, без <PREFIX>-00 overview), по номеру ---
$queue = Get-ChildItem (Join-Path $root "tasks") -Filter "$taskIdPrefix-*.md" -ErrorAction SilentlyContinue |
  ForEach-Object {
    if ($_.Name -match "^$([regex]::Escape($taskIdPrefix))-(\d+)-") { [pscustomobject]@{ Task = "$taskIdPrefix-$($Matches[1])"; Num = [int]$Matches[1]; File = $_.Name } }
  } |
  Where-Object { $_.Num -ne 0 } |
  Sort-Object Num -Unique

if (-not $queue -or $queue.Count -eq 0) { Log "Очередь пуста — нет задач $taskIdPrefix-NN в tasks/."; exit 1 }

Log "=== ОВЕРНАЙТ run-all старт. Задач в очереди: $($queue.Count) (PerTaskMax=$PerTaskMax, model=$modelLabel). ==="
Log "Очередь: $((($queue | ForEach-Object { $_.Task }) -join ', '))"

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
      [void]$stuckSet.Add($task); [void]$doneSet.Add($task)
      continue
    }
    # Предшественник ещё не PASS, но и не stuck (просто ещё не дошла очередь) → ждём след. прохода.
    $pending = @($preds | Where-Object { -not (Verdict-Pass $_) })
    if ($pending.Count -gt 0) { continue }

    # Все предшественники PASS (или их нет) → запускаем.
    Log ">>> Задача $task — запуск loop.ps1 -AutoAdvance (потолок $PerTaskMax итераций) ..."

    # M-17: ИЗОЛЯЦИЯ ЗАДАЧ. Всё некоммиченное копится на ОДНОМ working-tree → правки
    # незакрытой задачи протекают в следующую и контаминируют её гейты (напр. layout-contract
    # флипал PASS/FAIL по чужому состоянию). Снимаем pre-task снимок; если задача
    # НЕ закроется — откатим ТОЛЬКО её собственную дельту (tracked→snapshot + удалим добавленные ею
    # untracked), сохранив работу прежних PASS-задач. Работа незакрытой — в refs/loop/wip/$task.
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
    } else {
      # Реальная причина остановки из STATE.md (gate-block здесь исключён — преды уже PASS).
      $reason = 'не достиг PASS (лимит/затык)'
      $sf = Join-Path $PSScriptRoot "STATE.md"
      if (Test-Path $sf) {
        $h = Select-String -Path $sf -Pattern '##\s*Итерация.*—\s*(.+)$' | Select-Object -Last 1
        if ($h) { $reason = $h.Matches[0].Groups[1].Value.Trim() }
      }
      Log "<<< $task → НЕ закрыта ($reason)."
      $stuck += [pscustomobject]@{ Task = $task; Reason = $reason }
      [void]$stuckSet.Add($task)

      # M-17: изоляция — откатываем собственную дельту незакрытой задачи (tracked → pre-task snapshot,
      # удаляем добавленные ею untracked), чтобы её мусор не протёк в следующую задачу. Работа уже
      # в refs/loop/wip/$task (loop.ps1 Save-WipSnapshot) — восстановимо.
      if ($preTaskSnap) {
        & git checkout $preTaskSnap -- . 2>&1 | Out-Null
        & git reset -q 2>$null   # снять с индекса (checkout стейджит) — оставить как unstaged
        $postUntracked = @(& git ls-files --others --exclude-standard 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $addedByTask = @($postUntracked | Where-Object { $preUntracked -notcontains $_ })
        foreach ($f in $addedByTask) {
          $full = Join-Path $root $f
          if (Test-Path $full) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
        }
        $snapShort = $preTaskSnap.Substring(0, [Math]::Min(8, $preTaskSnap.Length))
        Log "изоляция: откатил дельту незакрытой $task к pre-task snapshot $snapShort (untracked удалено: $($addedByTask.Count)); её работа — refs/loop/wip/$task."
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
      [void]$doneSet.Add($task)
    }
    break
  }
}

# --- Итоговый отчёт (ОДИН на всю ночь) ---
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$stuckLines = if ($stuck.Count) { ($stuck | ForEach-Object { "- **$($_.Task)** — $($_.Reason)" }) -join "`n" } else { "- (нет)" }
$passLines  = if ($passed.Count) { ($passed | ForEach-Object { "- $_" }) -join "`n" } else { "- (нет)" }
Set-Content -Path $reviewFile -Encoding UTF8 -Value (
  "# Ralph overnight run-all — итог`n`n" +
  "**Когда:** $ts`n**Закрыто (PASS):** $($passed.Count) / $($queue.Count)`n`n" +
  "## ✅ PASS`n$passLines`n`n" +
  "## ⛔ Не закрыты — нужно ревью`n$stuckLines`n`n" +
  "## Что дальше`n" +
  "- Детали по каждой: loop/loop.log, tasks/.verdicts/<$taskIdPrefix-NN>.md, `pwsh loop/inspect.ps1 --task <NN> --last 20`.`n" +
  "- Незакрытые: разберись с причиной (затык/гейт/лимит), поправь, перезапусти `loop/start.ps1 $taskIdPrefix-NN` точечно или `loop/start.ps1` снова.")

# M-19 (2026-05-31): эволюционный harvest. Ретроспектор копит proposals (skill/subagent) с частотой;
# выводим топ в REVIEW.md, чтобы Глаз бога превращал самые частые в реальные skill/subagent/мета-задачи.
try {
  $memClient = Join-Path $root '.claude\memory\memory_client.py'
  if (Test-Path $memClient) {
    $propJson = & python $memClient harvest-proposals --status new --limit 10 2>$null
    $props = if ($propJson) { try { $propJson | ConvertFrom-Json } catch { @() } } else { @() }
    $propLines = if (@($props).Count) {
      (@($props) | ForEach-Object { "- $($_.count)x [$($_.kind)] $($_.target) — $($_.rationale)" }) -join "`n"
    } else { "- (пока нет — ретроспектор накопит за прогоны)" }
    Add-Content -Path $reviewFile -Encoding UTF8 -Value "`n## Эволюция: топ-предложения ретроспектора (по частоте)`n$propLines`n`nТриаж: python .claude/memory/memory_client.py harvest-proposals. Реализовать частые в skill/subagent/мета-задачу."
  }
} catch { }

Log "=== run-all завершён. PASS: $($passed.Count), не закрыто: $($stuck.Count). Итог — loop/REVIEW.md. ==="
try { [console]::beep(880, 250); Start-Sleep -Milliseconds 120; [console]::beep(660, 300) } catch { }
try {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "Overnight run-all завершён.`nЗакрыто PASS: $($passed.Count) из $($queue.Count).`nНе закрыто: $($stuck.Count).`n`nИтог — loop/REVIEW.md",
    "Ralph run-all: готово", 'OK', 'Information') | Out-Null
} catch { }
