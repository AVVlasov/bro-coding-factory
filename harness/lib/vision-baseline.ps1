# vision-baseline.ps1 — снимок aggregate.json на PASS + проверка регресса.
#
# Save-VisionBaseline: при verdict=PASS копирует последний aggregate.json в
#                     tests/vision/baseline/<task>.json (per-task snapshot).
# Check-VisionRegression: до vision-run сравнивает текущий aggregate с baseline
#                     для пересечения slug'ов; если хоть один ухудшился — reopen
#                     соответствующий bug через bug_tracker.py open.

# Repo root + bug_tracker.py: env override, иначе repo-relative default.
. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:RepoRoot   = Get-BcfProjectRoot
$script:BugTracker = if ($env:BCF_BUG_TRACKER) { $env:BCF_BUG_TRACKER } else { Join-Path $script:RepoRoot 'memory/pgvector/bug_tracker.py' }

function _Resolve-VisionDir {
    param([string]$Repo, [string]$EnvVar, [string]$Default)
    $rel = if ((Get-Item "env:$EnvVar" -ErrorAction SilentlyContinue).Value) { (Get-Item "env:$EnvVar").Value } else { $Default }
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel } else { return (Join-Path $Repo $rel) }
}

function _Latest-AggregatePath {
    param([string]$Repo)
    $resultsRoot = _Resolve-VisionDir -Repo $Repo -EnvVar 'BCF_VISION_RESULTS_DIR' -Default 'tests/vision/results'
    if (-not (Test-Path $resultsRoot)) { return $null }
    $latest = Get-ChildItem $resultsRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $f = Join-Path $latest.FullName 'aggregate.json'
    if (Test-Path $f) { return $f } else { return $null }
}

function Save-VisionBaseline {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$TaskId
    )
    $agg = _Latest-AggregatePath -Repo $Repo
    if (-not $agg) { return $null }
    $baselineDir = _Resolve-VisionDir -Repo $Repo -EnvVar 'BCF_VISION_BASELINE_DIR' -Default 'tests/vision/baseline'
    if (-not (Test-Path $baselineDir)) { New-Item -ItemType Directory -Force -Path $baselineDir | Out-Null }
    $dst = Join-Path $baselineDir "$TaskId.json"
    Copy-Item -LiteralPath $agg -Destination $dst -Force
    Write-Host "[vision-baseline] saved → $dst" -ForegroundColor DarkCyan
    return $dst
}

# Возвращает: @{ regressed = @(@{slug,theme,prev_total,curr_total,prev_severity,curr_severity}); ok = $true/false }
function Check-VisionRegression {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$TaskId
    )
    $baselineDir = _Resolve-VisionDir -Repo $Repo -EnvVar 'BCF_VISION_BASELINE_DIR' -Default 'tests/vision/baseline'
    $baselineFile = Join-Path $baselineDir "$TaskId.json"
    if (-not (Test-Path $baselineFile)) { return @{ regressed = @(); ok = $true; reason = 'no-baseline' } }
    $aggFile = _Latest-AggregatePath -Repo $Repo
    if (-not $aggFile) { return @{ regressed = @(); ok = $true; reason = 'no-current' } }

    try {
        $base = Get-Content -Raw -LiteralPath $baselineFile | ConvertFrom-Json
        $curr = Get-Content -Raw -LiteralPath $aggFile | ConvertFrom-Json
    } catch { return @{ regressed = @(); ok = $true; reason = 'parse-fail' } }

    # aggregate.json формата: @{results: [{page,theme,vision:{total},severity,ssim}, ...]}
    $baseMap = @{}
    foreach ($r in $base.results) { $baseMap["$($r.page)|$($r.theme)"] = $r }

    $sevOrder = @{ 'PASS'=0; 'OK'=0; 'LOW'=1; 'MEDIUM'=2; 'HIGH'=3; 'CRITICAL'=4; 'UNKNOWN'=2 }
    $regressed = @()
    foreach ($r in $curr.results) {
        $key = "$($r.page)|$($r.theme)"
        $b = $baseMap[$key]
        if (-not $b) { continue }
        $prevTotal = if ($b.vision.total) { [int]$b.vision.total } else { 0 }
        $currTotal = if ($r.vision.total) { [int]$r.vision.total } else { 0 }
        $prevSev = if ($b.severity) { "$($b.severity)".ToUpper() } else { 'PASS' }
        $currSev = if ($r.severity) { "$($r.severity)".ToUpper() } else { 'PASS' }
        $sevWorse = ($sevOrder[$currSev] -gt $sevOrder[$prevSev])
        # Регресс: severity ухудшилась ИЛИ total упал на >= 5 пунктов.
        if ($sevWorse -or ($prevTotal - $currTotal -ge 5)) {
            $regressed += @{
                slug = $r.page; theme = $r.theme
                prev_total = $prevTotal; curr_total = $currTotal
                prev_severity = $prevSev; curr_severity = $currSev
            }
        }
    }
    return @{ regressed = $regressed; ok = ($regressed.Count -eq 0); reason = 'compared' }
}

function Reopen-RegressedAsBugs {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][array]$Regressed
    )
    if (-not $Regressed -or $Regressed.Count -eq 0) { return }
    $items = @()
    foreach ($r in $Regressed) {
        $items += @{
            task        = $TaskId
            summary     = "vision regression $($r.slug)/$($r.theme): severity $($r.prev_severity) → $($r.curr_severity), total $($r.prev_total) → $($r.curr_total)"
            verification = "vision aggregate $($r.slug)/$($r.theme): severity ≤ $($r.prev_severity) AND total ≥ $($r.prev_total)"
            severity    = if ($r.curr_severity -eq 'CRITICAL') { 'critical' } elseif ($r.curr_severity -eq 'HIGH') { 'high' } else { 'medium' }
            opened_by   = 'vision-baseline-checker'
            iteration   = $Iteration
        }
    }
    $payload = $items | ConvertTo-Json -Depth 6 -AsArray
    $out = $payload | & python $script:BugTracker open 2>$null
    if ($out) { Write-Host "[vision-baseline] regression → $out" -ForegroundColor Yellow }
}
