# smoke-test-client.ps1 — exercises the full memory_client cycle:
#   embed -> upsert -> recall with the correct top-1 match by cosine similarity.
# Run:  pwsh smoke-test-client.ps1

$ErrorActionPreference = 'Stop'
$py = 'python'
$client = Join-Path $PSScriptRoot 'memory_client.py'
$cfgPath = Join-Path $PSScriptRoot '..\..\config\memory.config.json'

$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$container = $env:BCF_MEM_CONTAINER ?? 'bcf-agent-memory'

# 0. Embed sanity
$probe = "endpoint returns hardcoded JSON instead of querying repository"
$emb = & $py $client embed --text $probe
$len = ($emb | ConvertFrom-Json).Count
if ($len -ne $cfg.embedding_dim) {
    throw "embedding dim mismatch: got=$len expected=$($cfg.embedding_dim). Is $($cfg.embedding_model) loaded in your embedding server?"
}
Write-Host "embed: dim=$len OK" -ForegroundColor Green

# 1. Clean previous smoke entries and upsert three anti-patterns
$entries = @(
    @{ agent_scope='code'; trigger_summary='handler returns hardcoded literal instead of repository call';
       what_went_wrong='Endpoint body was a literal dict; tests asserted the same literal; nothing real exercised';
       correct_alternative='skills/source-of-truth-endpoints';
       evidence=@{ iteration_id='smoke-001'; source='smoke-test' } }
    @{ agent_scope='code'; trigger_summary='renderer importing better-sqlite3 directly, bypassing IPC';
       what_went_wrong='UI process touched DB without going through main-process IPC channel';
       correct_alternative='skills/renderer-data-access-via-ipc';
       evidence=@{ iteration_id='smoke-002'; source='smoke-test' } }
    @{ agent_scope='code'; trigger_summary='hover and disabled states visually indistinguishable, fails WCAG contrast';
       what_went_wrong='CSS used near-identical colors for :hover and :disabled';
       correct_alternative='skills/ui-state-contrast';
       evidence=@{ iteration_id='smoke-003'; source='smoke-test' } }
)
$jsonBatch = $entries | ConvertTo-Json -Depth 5
$inserted = $jsonBatch | & $py $client upsert
Write-Host "upsert: $inserted" -ForegroundColor Green

# 2. Recall — a query about a hardcoded endpoint should match #1, not the others.
$q = "API returns static fixture not from database"
$top = & $py $client recall --text $q --k 1 --threshold 0.4 | ConvertFrom-Json
if (-not $top -or $top.Count -lt 1) { throw "recall returned empty" }
$summary = $top[0].trigger_summary
Write-Host "recall top1: [sim=$($top[0].similarity)] $summary" -ForegroundColor Green
if ($summary -notlike '*hardcoded*' -and $summary -notlike '*repository*') {
    throw "recall matched wrong entry: $summary"
}

# 3. Recall for the IPC query
$q2 = "electron renderer accessing sqlite database"
$top2 = & $py $client recall --text $q2 --k 1 --threshold 0.4 | ConvertFrom-Json
$s2 = $top2[0].trigger_summary
Write-Host "recall top1 (ipc): [sim=$($top2[0].similarity)] $s2" -ForegroundColor Green
if ($s2 -notlike '*renderer*' -and $s2 -notlike '*IPC*' -and $s2 -notlike '*sqlite*') {
    throw "recall matched wrong entry for IPC query: $s2"
}

# 4. Cleanup smoke-test entries
& docker exec -e PGPASSWORD=$($env:BCF_PG_PASSWORD ?? 'bcf_local_dev') $container `
    psql -U bcf -d bcf_agent_memory -tAc `
    "DELETE FROM agent_memory.anti_patterns WHERE evidence->>'source' = 'smoke-test'" | Out-Null

Write-Host "memory-client smoke OK" -ForegroundColor Green
