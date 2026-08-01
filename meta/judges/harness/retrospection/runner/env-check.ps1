# env-check.ps1 — проверяет, что окружение для retrospection harness готово.
# Падает явным сообщением при отсутствии зависимости. Это ожидаемое красное
# состояние до C1/C2/C2.0/C4.

$ErrorActionPreference = 'Stop'
$problems = @()

# 1. LM Studio с bge-m3
try {
    $resp = Invoke-RestMethod -Uri 'http://localhost:1234/v1/models' -TimeoutSec 3
    $hasBge = $resp.data | Where-Object { $_.id -match 'bge-m3' }
    if (-not $hasBge) { $problems += 'LM Studio reachable, but bge-m3 not loaded (lms load text-embedding-bge-m3)' }
} catch {
    $problems += "LM Studio not reachable at http://localhost:1234/v1/models: $($_.Exception.Message)"
}

# 2. Postgres + pgvector (через контейнерный psql — host psql не требуется)
$container = 'bcf-agent-memory'
try {
    $health = & docker inspect -f '{{.State.Health.Status}}' $container 2>$null
    if ($LASTEXITCODE -ne 0)      { $problems += "Container '$container' not found (run: docker compose -f D:\<проект>\.claude\memory\docker-compose.yml up -d)" }
    elseif ($health -ne 'healthy') { $problems += "Container '$container' not healthy: $health" }
    else {
        $pw = if ($env:BCF_PG_PASSWORD) { $env:BCF_PG_PASSWORD } else { 'bcf_local_dev' }
        $out = & docker exec -e PGPASSWORD=$pw $container psql -U bcf -d bcf_agent_memory -tAc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $out) { $problems += "pgvector check failed: $out" }
    }
} catch {
    $problems += "docker check failed: $($_.Exception.Message)"
}

# 3. Retrospector subagent
$retroPath = Join-Path $env:BCF_PROJECT_ROOT '.claude/agents/retrospector.md'
$retroPath = Join-Path $env:BCF_PROJECT_ROOT '.claude/agents/retrospector.md'

# 4. Subagent finding gate hook
$gatePath = Join-Path $env:BCF_PROJECT_ROOT '.claude/hooks/subagent-finding-gate.sh'
$gatePath = Join-Path $env:BCF_PROJECT_ROOT '.claude/hooks/subagent-finding-gate.sh'

# 5. Memory inject hook
$injectPath = Join-Path $env:BCF_PROJECT_ROOT '.claude/hooks/pre-task-memory-inject.sh'
$injectPath = Join-Path $env:BCF_PROJECT_ROOT '.claude/hooks/pre-task-memory-inject.sh'

if ($problems.Count -gt 0) {
    Write-Host 'env-check FAILED:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'env-check OK' -ForegroundColor Green
exit 0
