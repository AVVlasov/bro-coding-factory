# fleet.ps1 — что происходит во флоте прямо сейчас.
#
#   pwsh harness/fleet.ps1                 состояние: воркеры, заявки на файлы, worktree
#   pwsh harness/fleet.ps1 -Kill w3        убить воркера и вернуть слот
#   pwsh harness/fleet.ps1 -Json           машиночитаемо
#   pwsh harness/fleet.ps1 -Reindex        пересобрать индекс co-change из истории git

param(
    [string]$Kill = '',
    [switch]$Json,
    [switch]$Reindex,
    [int]$StaleSec = 300,
  [string]$ProjectRoot = ''         # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
. (Join-Path $PSScriptRoot 'lib\fleet.ps1')
. (Join-Path $PSScriptRoot 'lib\claims.ps1')
. (Join-Path $PSScriptRoot 'lib\worktree.ps1')

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if ($Reindex) {
    $idx = Update-CoChangeIndex -Root $root
    Write-Host "co-change индекс пересобран: $($idx.Keys.Count) файлов со связями." -ForegroundColor Green
    return
}

if ($Kill) {
    if (Stop-FleetWorker -Id $Kill -Project $root) { Write-Host "воркер $Kill остановлен." -ForegroundColor Yellow }
    else { Write-Host "воркер $Kill не найден." -ForegroundColor Red }
    return
}

# Реестр общий на установку фабрики, поэтому здесь видно и воркеров соседних проектов.
# Это не шум: они съедают тот же потолок агентов, и без них число «работает трое» —
# неправда, из-за которой прогон упирается в rate-limit без объяснения.
$workers   = Get-FleetWorkers -StaleSec $StaleSec -Project $root
$claims    = Get-ActiveClaims
$worktrees = Get-TaskWorktrees -Root $root
$conflicts = Get-KnownConflicts

if ($Json) {
    [pscustomobject]@{
        workers   = $workers
        claims    = $claims
        worktrees = $worktrees
        conflicts = $conflicts
    } | ConvertTo-Json -Depth 8
    return
}

$mineCount = @($workers | Where-Object { $_.mine }).Count
Write-Host "`n=== ВОРКЕРЫ ($($workers.Count), из них здесь $mineCount) ===" -ForegroundColor Cyan
if ($workers.Count -eq 0) { Write-Host "  (никто не работает)" -ForegroundColor DarkGray }
foreach ($w in $workers) {
    $mark = if ($w.stalled) { '  ЗАВИС' } else { '' }
    $color = if ($w.stalled) { 'Red' } elseif (-not $w.mine) { 'DarkGray' } else { 'Gray' }
    $where = if ($w.mine) { '' } else { "  [$(Split-Path $w.project -Leaf)]" }
    Write-Host ("  {0,-10} {1,-8} {2,-10} pid {3,-7} простой {4,4}s{5}{6}  {7}" -f `
        $w.id, $w.role, $w.task, $w.pid, $w.idle_sec, $mark, $where, $w.detail) -ForegroundColor $color
}

Write-Host "`n=== ЗАЯВКИ НА ФАЙЛЫ ($($claims.Count)) ===" -ForegroundColor Cyan
if ($claims.Count -eq 0) { Write-Host "  (нет)" -ForegroundColor DarkGray }
foreach ($c in $claims) {
    Write-Host ("  {0,-10} pid {1,-7} файлов {2}" -f $c.task, $c.pid, @($c.files).Count) -ForegroundColor Gray
    foreach ($f in @($c.declared)) { Write-Host "      $f" -ForegroundColor DarkGray }
}

Write-Host "`n=== WORKTREE ($($worktrees.Count)) ===" -ForegroundColor Cyan
if ($worktrees.Count -eq 0) { Write-Host "  (нет)" -ForegroundColor DarkGray }
foreach ($w in $worktrees) { Write-Host ("  {0,-24} {1}" -f $w.branch, $w.path) -ForegroundColor Gray }

Write-Host "`n=== ПАМЯТЬ О КОНФЛИКТАХ ($($conflicts.Count)) ===" -ForegroundColor Cyan
if ($conflicts.Count -eq 0) { Write-Host "  (пока не было)" -ForegroundColor DarkGray }
foreach ($cf in $conflicts) {
    Write-Host ("  {0} — {1} ({2})" -f (@($cf.pair) -join ' + '), (@($cf.files) -join ', '), $cf.kind) -ForegroundColor DarkYellow
}
Write-Host ""
