# harness/start.ps1 — thin launcher: spawns loop.ps1 in the background for one task.
# Usage:
#   pwsh harness/start.ps1 <TASK>     # run a single task
#   pwsh harness/start.ps1            # no arg → overnight run-all (all tasks in order)

param(
  [Parameter(Position = 0)] [string]$Task = "",
  [string]$Model = "",                    # empty → resolved from config/harness.json (models.code)
  [switch]$NoAutoRollback                  # disable auto-rollback of tsc regressions (default on),
  [string]$ProjectRoot = '',        # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
$loopPs1 = Join-Path $PSScriptRoot "loop.ps1"

# Console in UTF-8 — otherwise the launch message renders as mojibake when the
# parent captures this command's stdout.
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# --- Config (config/harness.json): code-agent model + task-id pattern/prefix ---
$harnessCfg = $null
$cfgFile = Join-Path $root 'config\harness.json'
if (Test-Path $cfgFile) {
  try { $harnessCfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json } catch { $harnessCfg = $null }
}
if (-not $Model -and $harnessCfg -and $harnessCfg.models -and $harnessCfg.models.code) {
  $Model = [string]$harnessCfg.models.code
}
# Task-id matching: a regex pattern (taskIdPattern) plus a default prefix.
$taskIdPattern = if ($harnessCfg -and $harnessCfg.taskIdPattern) { [string]$harnessCfg.taskIdPattern } else { '[A-Za-z][A-Za-z0-9]*-\d+' }
$taskIdPrefix  = if ($harnessCfg -and $harnessCfg.taskIdPrefix)  { [string]$harnessCfg.taskIdPrefix }  else { 'TASK' }
$modelLabel = if ($Model) { $Model } else { '(backend default)' }

$Task = $Task.ToUpper().Trim()
# Empty arg or ALL/<PREFIX>-ALL/* → OVERNIGHT mode: run every task in order.
$allAliases = @('ALL', '*', "$taskIdPrefix-ALL".ToUpper())
$runAll = (-not $Task) -or ($Task -in $allAliases)

# Don't start a second loop on top of a running one (loop.ps1 or run-all.ps1 orchestrator).
$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match '(loop|run-all)\.ps1' -and $_.CommandLine -notmatch 'Win32_Process' })
if ($running.Count -gt 0) {
  Write-Host "Loop already running (PID $($running.ProcessId -join ', '))."
  Write-Host "Stop it (create the file .bcf/STOP) before starting a new run."
  exit 1
}

if ($runAll) {
  $runAllPs1 = Join-Path $PSScriptRoot "run-all.ps1"
  $raArgs = @('-NoProfile', '-File', $runAllPs1)
  if ($Model) { $raArgs += @('-Model', $Model) }
  if ($NoAutoRollback) { $raArgs += '-NoAutoRollback' }
  Start-Process -FilePath 'pwsh' -ArgumentList $raArgs -WorkingDirectory $root -WindowStyle Minimized
  Write-Host "Overnight run-all started: will run every task in order (model $modelLabel)."
  Write-Host "Progress — .bcf/loop.log. When the whole queue finishes — one window + .bcf/REVIEW.md (summary)."
  Write-Host "Stop early — create the file .bcf/STOP."
  exit 0
}

# Sanity-check the task id against the configured pattern (accept any generic id).
if ($Task -and ($Task -notmatch "^$taskIdPattern$")) {
  Write-Host "Warning: task id '$Task' does not match taskIdPattern '$taskIdPattern' — launching anyway."
}

$loopArgs = @('-NoProfile', '-File', $loopPs1, $Task)
if ($Model) { $loopArgs += @('-Model', $Model) }
if ($NoAutoRollback) { $loopArgs += '-NoAutoRollback' }

Start-Process -FilePath 'pwsh' `
  -ArgumentList $loopArgs `
  -WorkingDirectory $root -WindowStyle Minimized

$rollbackNote = if ($NoAutoRollback) { ', auto-rollback OFF' } else { '' }
Write-Host "Loop started for $Task (model $modelLabel$rollbackNote)."
Write-Host "Progress — .bcf/loop.log. On stop a window pops up + .bcf/REVIEW.md."
