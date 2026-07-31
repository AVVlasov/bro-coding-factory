# hard-cap.ps1 — adaptive iter cap для предотвращения буксования.
#
# Severity-weight: critical=4, high=3, medium=2, low=1.
# severity_score = sum(open + chronic bugs weight).
# Adaptive cap (iter без PASS):
#   score >= 12    →  5 iter   (массивный набор серьёзных багов, дробить рано)
#   score >= 6     →  7 iter
#   score >= 3     → 10 iter
#   score <  3     → 15 iter   (мелочёвка, можно подольше)
# Cap (учитываем только iter БЕЗ verdict=PASS подряд).
# При срабатывании — loop-paused event с reason='hard-cap-decomposition-required',
# loop останавливается и зовёт оператора.

# Repo root: env override, иначе два уровня вверх от этого lib-каталога
# (REPO\harness\lib\hard-cap.ps1 → REPO).
. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:RepoRoot = Get-BcfProjectRoot
# bug_tracker.py: env override, иначе repo-relative default.
$script:BugTracker = if ($env:BCF_BUG_TRACKER) { $env:BCF_BUG_TRACKER } else { Join-Path $script:RepoRoot 'memory/pgvector/bug_tracker.py' }

function Get-SeverityScore {
    param([Parameter(Mandatory)][string]$TaskId)
    $list = & python $script:BugTracker list --task $TaskId --status all 2>$null
    if (-not $list) { return @{ score = 0; open = 0; chronic = 0; critical = 0 } }
    try { $bugs = $list | ConvertFrom-Json } catch { return @{ score = 0; open = 0; chronic = 0; critical = 0 } }
    $w = @{ 'critical' = 4; 'high' = 3; 'medium' = 2; 'low' = 1 }
    $score = 0; $open = 0; $chronic = 0; $crit = 0
    foreach ($b in @($bugs)) {
        if ($b.status -notin @('open','chronic')) { continue }
        $sev = "$($b.severity)".ToLower()
        $score += ($w[$sev] ?? 2)
        if ($b.status -eq 'chronic') { $chronic++; $score += 2 } else { $open++ }   # chronic-penalty +2
        if ($sev -eq 'critical') { $crit++ }
    }
    return @{ score = $score; open = $open; chronic = $chronic; critical = $crit }
}

function Get-AdaptiveCap {
    param([int]$Score)
    if ($Score -ge 12) { return 5 }
    if ($Score -ge 6)  { return 7 }
    if ($Score -ge 3)  { return 10 }
    return 15
}

function Test-HardCap {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$ItersWithoutPass
    )
    $score = Get-SeverityScore -TaskId $TaskId
    $cap   = Get-AdaptiveCap -Score $score.score
    $hit   = ($ItersWithoutPass -ge $cap)
    return @{
        hit               = $hit
        cap               = $cap
        iters_without_pass = $ItersWithoutPass
        severity          = $score
        reason            = "severity_score=$($score.score) (open=$($score.open) chronic=$($score.chronic) critical=$($score.critical)) → cap=$cap; iters_without_pass=$ItersWithoutPass"
    }
}
