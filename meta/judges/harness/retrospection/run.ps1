# run.ps1 — точка входа retrospection harness.
# Запускает env-check, прогоняет все фикстуры, пишет markdown-отчёт.

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$today = Get-Date -Format 'yyyy-MM-dd'
$reportDir  = Join-Path $env:BCF_PROJECT_ROOT '.bcf/retros'
$reportPath = Join-Path $reportDir "M-13-harness-run-$today.md"
$outDir     = Join-Path $here "out\$today"
New-Item -ItemType Directory -Force -Path $reportDir, $outDir | Out-Null

$lines = @("# M-13 retrospection harness — run $today", "")

Write-Host '=== env-check ===' -ForegroundColor Cyan
& "$here\runner\env-check.ps1"
$envCode = $LASTEXITCODE
$lines += "## env-check"
$lines += if ($envCode -eq 0) { "OK" } else { "**FAIL** (exit $envCode) — см. вывод выше. Ожидаемо до завершения C1/C2/C2.0/C4." }
$lines += ""

$fixtures = @(
    @{ name='F01'; dir='F01-ignored-vision-finding';   expected='F01.json' }
    @{ name='F02'; dir='F02-repeated-mock-as-real';    expected='F02.json' }
    @{ name='F03'; dir='F03-arch-violation';           expected='F03.json' }
)

$lines += "## fixtures"
$lines += ""
$lines += "| id | status | notes |"
$lines += "|----|--------|-------|"

$anyFail = $false
foreach ($f in $fixtures) {
    Write-Host "=== fixture $($f.name) ===" -ForegroundColor Cyan
    & "$here\runner\run-fixture.ps1" `
        -FixtureDir   (Join-Path $here "fixtures\$($f.dir)") `
        -ExpectedJson (Join-Path $here "expected\$($f.expected)") `
        -OutDir       $outDir
    $code = $LASTEXITCODE
    $status = switch ($code) {
        0 { 'PASS' }
        2 { 'BLOCKED (deps missing)' }
        default { 'FAIL' }
    }
    if ($code -ne 0) { $anyFail = $true }
    $lines += "| $($f.name) | $status | exit=$code |"
}

$lines += ""
$lines += "## overall"
$lines += if ($anyFail) { "**RED** — harness не зелёный. Это ожидаемое состояние пока C1/C2/C4 не закрыты." } else { "**GREEN**" }

$lines | Set-Content -Path $reportPath -Encoding utf8
Write-Host ""
Write-Host "report: $reportPath" -ForegroundColor Cyan
if ($anyFail) { exit 1 } else { exit 0 }
