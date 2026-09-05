# all.ps1 — все сюиты одной командой.
#
#   pwsh tests/all.ps1
#
# До этого четыре набора запускались руками по памяти: сюита, о которой забыли,
# краснеет только тогда, когда кто-то случайно её откроет. Здесь порядок не важен,
# важен факт: каждый набор либо отработал зелёным, либо команда уходит ненулевым
# кодом — CI и человек читают один и тот же вердикт.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$suites = @(
    @{ Name = 'CLI';              File = Join-Path $PSScriptRoot 'cli.tests.ps1' },
    @{ Name = 'граф-рантайм';     File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'graph-runtime.tests.ps1' },
    @{ Name = 'слияние worktree'; File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'merge-integration.tests.ps1' },
    @{ Name = 'journey-gate';     File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'journey-gate.tests.ps1' },
    @{ Name = 'раннер maven';     File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'maven-runner.tests.ps1' },
    @{ Name = 'java-хуки';        File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'java-hooks.tests.ps1' },
    @{ Name = 'исполнитель';      File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'executor-field.tests.ps1' },
    @{ Name = 'честность вердикта'; File = Join-Path $PSScriptRoot '..', 'harness', 'tests', 'verdict-honesty.tests.ps1' },
    @{ Name = 'фабрика в команде'; File = Join-Path $PSScriptRoot 'team-claims.tests.ps1' },
    @{ Name = 'шина команды';      File = Join-Path $PSScriptRoot 'team-bus.tests.ps1' }
)

$results = @()
foreach ($s in $suites) {
    Write-Host ""
    Write-Host "=== $($s.Name): $(Split-Path $s.File -Leaf)" -ForegroundColor White
    & pwsh -NoProfile -File $s.File
    $results += [pscustomobject]@{ Name = $s.Name; Code = $LASTEXITCODE }
}

Write-Host ''
$failed = @($results | Where-Object { $_.Code -ne 0 })
foreach ($r in $results) {
    $mark = if ($r.Code -eq 0) { 'зелёная' } else { "ПРОВАЛ (exit $($r.Code))" }
    Write-Host ("  {0,-18} {1}" -f $r.Name, $mark)
}
if ($failed.Count) { exit 1 }
exit 0
