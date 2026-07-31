# run-fixture.ps1 — прогоняет одну фикстуру через ретроспектор и сравнивает с expected.

param(
    [Parameter(Mandatory)][string]$FixtureDir,
    [Parameter(Mandatory)][string]$ExpectedJson,
    [Parameter(Mandatory)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
$name = Split-Path -Leaf $FixtureDir
Write-Host "[$name] running" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$actualPath = Join-Path $OutDir "$name.actual.json"

$invoker = '$(Join-Path $env:BCF_PROJECT_ROOT '.claudegentsin\invoke-retrospector.ps1')'
if (-not (Test-Path $invoker)) {
    Write-Host "  SKIP-FAIL: invoker not found: $invoker (C1 not done)" -ForegroundColor Yellow
    exit 2
}

# Структурированный input — приоритетно input.json; иначе минимальный fallback из transcript.md.
$inputJsonPath = Join-Path $FixtureDir 'input.json'
if (Test-Path $inputJsonPath) {
    $payload = Get-Content $inputJsonPath -Raw
    # обогащаем transcript'ом, если есть, чтобы модель видела и нарратив
    $transcriptPath = Join-Path $FixtureDir 'transcript.md'
    if (Test-Path $transcriptPath) {
        $obj = $payload | ConvertFrom-Json
        $obj | Add-Member -NotePropertyName transcript -NotePropertyValue (Get-Content $transcriptPath -Raw) -Force
        $payload = $obj | ConvertTo-Json -Depth 20
    }
} else {
    $payload = @{
        transcript   = Get-Content (Join-Path $FixtureDir 'transcript.md') -Raw
        prior_memory = @()
    } | ConvertTo-Json -Depth 10
}

# ВАЖНО: $input — автоматическая переменная PowerShell (pipeline input).
# Используем $payload и явный pipe через Write-Output.
$payload | & pwsh -NoProfile -File $invoker | Out-File -FilePath $actualPath -Encoding utf8
if ($LASTEXITCODE -ne 0) {
    Write-Host "  FAIL: retrospector invocation exited $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

& "$PSScriptRoot\compare-json.ps1" -ActualPath $actualPath -ExpectedPath $ExpectedJson
exit $LASTEXITCODE
