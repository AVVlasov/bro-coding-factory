# compare-json.ps1 — семантическое сравнение actual vs expected JSON.
#
# Expected-поля поддерживают OR-семантику для робастности к лексической вариативности
# LLM-вывода (модель может выбрать skill_new vs skill_update, разные слова в slug'е):
#
#   root_causes:               [{category_any: [str, ...]}, ...]   # старый формат {category: str} тоже понимается
#   ignored_subagent_findings: [{agent: str, finding_id?: str|'auto'}, ...]
#   proposals:                 [{kinds: [str, ...], targets: [str, ...]}, ...]   # старый {kind,target} тоже работает
#
# Match-правила:
#   - root_cause: actual.root_causes содержит элемент с category ∈ category_any
#   - finding: actual содержит match по agent (+ finding_id если не 'auto')
#   - proposal: actual содержит элемент с kind ∈ kinds AND ∃ t ∈ targets такой что actual.target включает t (case-insensitive)

param(
    [Parameter(Mandatory)][string]$ActualPath,
    [Parameter(Mandatory)][string]$ExpectedPath
)

$ErrorActionPreference = 'Stop'

$actual   = Get-Content $ActualPath   -Raw | ConvertFrom-Json
$expected = Get-Content $ExpectedPath -Raw | ConvertFrom-Json

$errors = @()

if ($actual.iteration_id -ne $expected.iteration_id) {
    $errors += "iteration_id mismatch: expected '$($expected.iteration_id)', actual '$($actual.iteration_id)'"
}

function Get-Any($obj, [string]$primary, [string]$any) {
    if ($obj.PSObject.Properties.Name -contains $any) { return @($obj.$any) }
    if ($obj.PSObject.Properties.Name -contains $primary) { return @($obj.$primary) }
    return @()
}

# root_causes
foreach ($rc in $expected.root_causes) {
    $cats = Get-Any $rc 'category' 'category_any'
    $hit = $actual.root_causes | Where-Object { $cats -contains $_.category }
    if (-not $hit) { $errors += "missing root_cause.category ∈ [$($cats -join ', ')]" }
}

# ignored_subagent_findings
foreach ($f in $expected.ignored_subagent_findings) {
    $fid = if ($f.PSObject.Properties.Name -contains 'finding_id') { $f.finding_id } else { 'auto' }
    $hit = $actual.ignored_subagent_findings | Where-Object {
        $_.agent -eq $f.agent -and ($fid -eq 'auto' -or $_.finding_id -eq $fid)
    }
    if (-not $hit) { $errors += "missing ignored finding agent=$($f.agent) id=$fid" }
}

# proposals
foreach ($p in $expected.proposals) {
    $kinds   = Get-Any $p 'kind'   'kinds'
    $targets = Get-Any $p 'target' 'targets'
    $hit = $null
    foreach ($prop in @($actual.proposals)) {
        if ($kinds -notcontains $prop.kind) { continue }
        $tgt = if ($prop.target) { $prop.target.ToLowerInvariant() } else { '' }
        $matchedTarget = $false
        foreach ($t in $targets) {
            if ($tgt -like "*$($t.ToLowerInvariant())*") { $matchedTarget = $true; break }
        }
        if ($matchedTarget) { $hit = $prop; break }
    }
    if (-not $hit) {
        $errors += "missing proposal kind ∈ [$($kinds -join ', ')] target ~ [$($targets -join ', ')]"
    }
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-Host "  FAIL: $e" -ForegroundColor Red }
    exit 1
}
Write-Host "  match: $(Split-Path -Leaf $ExpectedPath)" -ForegroundColor Green
exit 0
