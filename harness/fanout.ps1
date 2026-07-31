# fanout.ps1 — несколько агентов на ОДНУ задачу.
#
#   pwsh harness/fanout.ps1 TASK-05            прогнать срезы задачи параллельно
#   pwsh harness/fanout.ps1 TASK-05 -DryPlan   только показать разбиение
#
# ИДЕЯ. Срезы объявляются в task-файле секцией «## Срезы» и обязаны быть
# НЕПЕРЕСЕКАЮЩИМИСЯ по файлам. Тогда агентам не нужен ни отдельный worktree, ни
# слияние: они правят разные файлы одного дерева, и конфликт невозможен по построению.
#
# ГРАНИЦА. Если срезы пересекаются — фан-аут не запускается. Два агента на связанных
# файлах дороже последовательной работы: каждый строит свою модель происходящего, и
# на выходе получается зелёная сборка с несовместимой логикой (семантический конфликт,
# по внешним замерам 5–10% случаев). См. wiki/research/2026-07-26-parallel-agents-file-conflicts.md.
#
# После прогона проверяется, что каждый агент тронул ТОЛЬКО свои файлы; выход за срез
# откатывается, а сам факт попадает в память конфликтов.

param(
    [Parameter(Mandatory, Position = 0)][string]$Task,
    [string]$Model = '',
    [int]$Concurrency = 0,
    [int]$StepTimeoutSec = 1800,
    [int]$SilentTimeoutSec = 300,
    [switch]$DryPlan,
  [string]$ProjectRoot = ''         # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

. (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
Assert-HarnessCaller -ScriptName 'fanout.ps1'
. (Join-Path $PSScriptRoot 'lib\agent-sandbox.ps1')
. (Join-Path $PSScriptRoot 'lib\fleet.ps1')
. (Join-Path $PSScriptRoot 'lib\claims.ps1')

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$logFile = Join-Path $PSScriptRoot 'loop.log'
function Log($m) {
    $line = "[{0}] [fanout] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line -ForegroundColor Magenta
    Add-Content -Path $logFile -Value $line
}

$cfg = $null
try { $cfg = Get-Content -Raw (Join-Path $root 'config\harness.json') | ConvertFrom-Json } catch { }
if (-not $Model -and $cfg.models.code) { $Model = [string]$cfg.models.code }
if ($Concurrency -le 0) { $Concurrency = if ($cfg.limits.fanoutConcurrency) { [int]$cfg.limits.fanoutConcurrency } else { 2 } }
$maxAgents = if ($cfg.limits.agentConcurrency) { [int]$cfg.limits.agentConcurrency } else { 6 }

# --- Разбор секции «## Срезы» ---
# Формат строки:  - <имя>: <файл>[, <файл>...] — <что сделать>
function Get-TaskSlices {
    param([string]$TaskId)
    $tf = Get-ChildItem (Join-Path $root 'tasks') -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return @() }
    $body = Get-Content -Raw -LiteralPath $tf.FullName
    $m = [regex]::Match($body, '(?ms)^##[^\r\n]*Срезы.*?(?=^##\s|\z)')
    if (-not $m.Success) { return @() }
    $slices = @()
    foreach ($line in ($m.Value -split "`r?`n")) {
        # Разделитель цели — именно длинное тире: обычный дефис встречается внутри
        # путей (src/core/…), и по нему список файлов резался на середине.
        $lm = [regex]::Match($line, '^\s*-\s*([^:]+):\s*([^—]+?)(?:\s*—\s*(.*))?$')
        if (-not $lm.Success) { continue }
        $files = @($lm.Groups[2].Value -split '[,\s]+' | ForEach-Object { ($_ -replace '`', '').Trim() } | Where-Object { $_ -match '\.[A-Za-z0-9]+$' })
        if ($files.Count -eq 0) { continue }
        $slices += [pscustomobject]@{
            Name  = $lm.Groups[1].Value.Trim()
            Files = @($files | ForEach-Object { $_ -replace '\\', '/' })
            Goal  = $lm.Groups[3].Value.Trim()
        }
    }
    return $slices
}

$slices = Get-TaskSlices -TaskId $Task
if ($slices.Count -lt 2) {
    Log "$Task — срезов меньше двух, фан-аут не нужен."
    exit 2
}

# Пересечение = отказ. Это главная граница метода.
$seen = @{}
$overlap = @()
foreach ($s in $slices) {
    foreach ($f in $s.Files) {
        if ($seen.ContainsKey($f)) { $overlap += "$f ($($seen[$f]) / $($s.Name))" }
        $seen[$f] = $s.Name
    }
}
if ($overlap.Count) {
    Log "$Task — ФАН-АУТ ОТКЛОНЁН: срезы пересекаются по файлам: $($overlap -join '; '). Задача выполняется одним агентом."
    exit 3
}

Log "$Task — срезов: $($slices.Count), параллельно до $Concurrency."
foreach ($s in $slices) { Log "  срез «$($s.Name)»: $($s.Files -join ', ') — $($s.Goal)" }
if ($DryPlan) { exit 0 }

$taskFile = Get-ChildItem (Join-Path $root 'tasks') -Filter "$Task-*.md" | Select-Object -First 1
$taskBody = Get-Content -Raw -LiteralPath $taskFile.FullName
$workDir = Join-Path $PSScriptRoot '.fanout'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Force -Path $workDir | Out-Null }

# Состояние файлов до прогона — чтобы поймать выход за срез.
$before = @{}
foreach ($f in ($slices | ForEach-Object { $_.Files })) { $before[$f] = $true }
$treeBefore = (& git -C $root status --porcelain | Out-String)

$pending = [System.Collections.ArrayList]::new()
foreach ($s in $slices) { [void]$pending.Add($s) }
$running = [System.Collections.ArrayList]::new()

while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Concurrency -and $pending.Count -gt 0) {
        if (-not (Test-FleetCapacity -MaxAgents $maxAgents)) { break }
        $lease = Acquire-AgentSlot
        if (-not $lease) { break }
        $s = $pending[0]; $pending.RemoveAt(0)

        $prompt = @"
Ты — агент одного среза задачи $Task. Работай ТОЛЬКО в своих файлах.

===== ТВОИ ФАЙЛЫ (менять можно только их) =====
$($s.Files -join "`n")

===== ЦЕЛЬ СРЕЗА =====
$($s.Goal)

===== ЗАДАЧА ЦЕЛИКОМ (для контекста; остальные срезы делают другие агенты) =====
$taskBody

Правила:
- НЕ трогай файлы вне списка выше — их прямо сейчас правят другие агенты,
  твоя правка будет откачена, а срез засчитан как нарушивший границу.
- Не создавай новых файлов вне своего среза.
- Доведи свой срез до компилируемого состояния.
"@
        $pf = Join-Path $workDir "$Task-$($s.Name).prompt.txt"
        $of = Join-Path $workDir "$Task-$($s.Name).out.txt"
        $ef = Join-Path $workDir "$Task-$($s.Name).err.txt"
        Set-Content -LiteralPath $pf -Value $prompt -Encoding UTF8

        $sandbox = $lease.Path
        $modelArg = if ($Model) { "--model '$Model'" } else { '' }
        $inner = "[Console]::OutputEncoding=[Text.Encoding]::UTF8;`$OutputEncoding=[Text.Encoding]::UTF8;" +
                 "try{chcp 65001|Out-Null}catch{};`$env:LANG='C.UTF-8';`$env:XDG_DATA_HOME='$sandbox';" +
                 "Get-Content -Raw -LiteralPath '$pf' | & opencode run --dangerously-skip-permissions --thinking $modelArg"
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $inner) `
            -WorkingDirectory $root -NoNewWindow -PassThru -RedirectStandardOutput $of -RedirectStandardError $ef
        Register-FleetWorker -Id "fanout-$($s.Name)" -Role 'code' -Task $Task -Model $Model -ProcessId $proc.Id -Detail "срез $($s.Name)"
        Log "срез «$($s.Name)» запущен (воркер w$($lease.Slot), pid $($proc.Id))."
        [void]$running.Add(@{ Slice = $s; Proc = $proc; Lease = $lease; Started = (Get-Date); Out = $of })
    }

    Start-Sleep -Seconds 3
    foreach ($r in @($running)) {
        $elapsed = [int]((Get-Date) - $r.Started).TotalSeconds
        if (-not $r.Proc.HasExited -and $elapsed -lt $StepTimeoutSec) { continue }
        if (-not $r.Proc.HasExited) {
            Log "срез «$($r.Slice.Name)» — таймаут ${StepTimeoutSec}s, kill."
            try { $r.Proc.Kill($true) } catch { }
        }
        $running.Remove($r)
        Release-AgentSlot $r.Lease
        Unregister-FleetWorker -Id "fanout-$($r.Slice.Name)"
        Log "срез «$($r.Slice.Name)» завершён за ${elapsed}s."
    }
}

# --- Проверка границ среза ---
$changed = @(& git -C $root status --porcelain | ForEach-Object { ($_ -replace '^...', '').Trim() -replace '\\', '/' } | Where-Object { $_ })
$allowed = @($slices | ForEach-Object { $_.Files })
$outside = @($changed | Where-Object { $allowed -notcontains $_ })

if ($outside.Count) {
    Log "ВЫХОД ЗА СРЕЗ: изменены файлы вне объявленных срезов — $($outside -join ', '). Откатываю их."
    foreach ($f in $outside) { & git -C $root checkout -- $f 2>&1 | Out-Null }
    Register-TaskConflict -Pair @($Task, 'fanout') -Files $outside -Kind 'slice-violation'
    Log "Границы восстановлены; факт записан в память конфликтов."
}

Log "$Task — фан-аут завершён: срезов $($slices.Count), выходов за границу $($outside.Count)."
exit 0
