# smoke-test.ps1 — checks that Postgres+pgvector is up and the schema is created.
# Run:  pwsh smoke-test.ps1
# Uses the in-container psql so no host-side client install is required.

$ErrorActionPreference = 'Stop'
$container = $env:BCF_MEM_CONTAINER ?? 'bcf-agent-memory'

function In-Psql([string]$sql) {
    & docker exec -e PGPASSWORD=$($env:BCF_PG_PASSWORD ?? 'bcf_local_dev') `
        $container psql -U bcf -d bcf_agent_memory -tAc $sql
}

# 1. Container is alive
$state = & docker inspect -f '{{.State.Health.Status}}' $container 2>$null
if ($LASTEXITCODE -ne 0) { throw "Container '$container' not found. Run: docker compose -f $PSScriptRoot/docker-compose.yml up -d" }
if ($state -ne 'healthy') { throw "Container state: $state (waiting for healthy)" }
Write-Host "container: healthy" -ForegroundColor Green

# 2. vector extension
$ext = In-Psql "SELECT extversion FROM pg_extension WHERE extname='vector'"
if (-not $ext) { throw "pgvector extension missing" }
Write-Host "pgvector: $ext" -ForegroundColor Green

# 3. anti_patterns table
$cols = In-Psql "SELECT count(*) FROM information_schema.columns WHERE table_schema='agent_memory' AND table_name='anti_patterns'"
if ([int]$cols -lt 8) { throw "anti_patterns schema not initialized (cols=$cols)" }
Write-Host "anti_patterns cols: $cols" -ForegroundColor Green

# 4. bugs table (schema fix — must exist for the bug ledger)
$bugCols = In-Psql "SELECT count(*) FROM information_schema.columns WHERE table_schema='agent_memory' AND table_name='bugs'"
if ([int]$bugCols -lt 15) { throw "bugs schema not initialized (cols=$bugCols)" }
Write-Host "bugs cols: $bugCols" -ForegroundColor Green

# 5. Round-trip insert/select with a vector
$probe = 'array_fill(0.01::real,ARRAY[1024])::vector'
$insertedRaw = In-Psql "INSERT INTO agent_memory.anti_patterns(agent_scope,trigger_summary,what_went_wrong,embedding) VALUES ('smoke','probe','probe',$probe) RETURNING id"
# psql -tA with INSERT..RETURNING emits the uuid then a status line — take the first non-empty.
$inserted = ($insertedRaw -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1)
if (-not $inserted) { throw "insert failed (raw=$insertedRaw)" }
$sim = (In-Psql "SELECT 1 - (embedding <=> $probe) FROM agent_memory.anti_patterns WHERE id='$inserted'") -split "`r?`n" | Select-Object -First 1
$simNum = [double]$sim
if ($simNum -lt 0.999) { throw "self-similarity too low: $sim" }
In-Psql "DELETE FROM agent_memory.anti_patterns WHERE id='$inserted'" | Out-Null
Write-Host "round-trip similarity: $sim" -ForegroundColor Green

Write-Host "smoke-test OK" -ForegroundColor Green
