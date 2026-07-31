# invoke-supervisor.ps1 — synchronous call to the iteration supervisor agent.
# stdin:  JSON (see agents/supervisor.md `## Inputs`)
# stdout: JSON (see `## Outputs`)
# exit:   0 on a valid JSON object, 1 otherwise.
#
# Backend: any OpenAI-compatible /v1/chat/completions endpoint.
#   - endpoint : $env:BCF_SUPERVISOR_ENDPOINT, else $env:BCF_API_HOST + /v1/chat/completions
#   - model    : $env:BCF_SUPERVISOR_MODEL,    else $env:BCF_MODEL (empty = backend default <model>)
#   - api key  : $env:BCF_SUPERVISOR_API_KEY,  else $env:BCF_API_KEY (read from env or project .env)
# Some backends wrap a textual chain-of-thought in <think>…</think>; it is stripped below
# by extracting the JSON object.

$ErrorActionPreference = 'Stop'

# Resolve project root: env override, else two levels up from this script (agents/bin -> repo root).
$projectRoot = if ($env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# Read .env from the project root as a fallback so the key/host are available regardless of
# how the parent process was launched (e.g. an env var added after the parent started).
function Get-DotEnvValue([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.+?)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}
$dotenv = Join-Path $projectRoot '.env'
if (-not $env:BCF_API_KEY)  { $v = Get-DotEnvValue $dotenv 'BCF_API_KEY';  if ($v) { $env:BCF_API_KEY  = $v } }
if (-not $env:BCF_API_HOST) { $v = Get-DotEnvValue $dotenv 'BCF_API_HOST'; if ($v) { $env:BCF_API_HOST = $v } }

$apiHost  = if ($env:BCF_API_HOST) { $env:BCF_API_HOST.TrimEnd('/') } else { 'http://localhost:1234' }

$endpoint = if ($env:BCF_SUPERVISOR_ENDPOINT) { $env:BCF_SUPERVISOR_ENDPOINT } else { "$apiHost/v1/chat/completions" }
$model    = if ($env:BCF_SUPERVISOR_MODEL)    { $env:BCF_SUPERVISOR_MODEL }    else { $env:BCF_MODEL }
$apiKey   = if ($env:BCF_SUPERVISOR_API_KEY)  { $env:BCF_SUPERVISOR_API_KEY }  else { $env:BCF_API_KEY }

# Agent definition path: env override, else repo-relative default under agents/.
$agentPath = if ($env:BCF_AGENT_PATH_SUPERVISOR) {
    $env:BCF_AGENT_PATH_SUPERVISOR
} elseif ($env:BCF_AGENT_DIR) {
    Join-Path $env:BCF_AGENT_DIR 'supervisor.md'
} else {
    Join-Path $projectRoot 'agents/supervisor.md'
}
$raw = Get-Content $agentPath -Raw
$systemPrompt = ($raw -replace '(?s)^---.*?---\s*', '').Trim()

$stdin = [Console]::In.ReadToEnd()
if (-not $stdin) { Write-Error 'invoke-supervisor: empty stdin'; exit 1 }

$body = @{
    temperature = 0.0
    messages    = @(
        @{ role = 'system'; content = $systemPrompt }
        @{ role = 'user';   content = $stdin }
    )
}
if ($model) { $body['model'] = $model }
$body = $body | ConvertTo-Json -Depth 10 -Compress

$headers = @{ 'Content-Type' = 'application/json' }
if ($apiKey) { $headers['Authorization'] = "Bearer $apiKey" }

$maxAttempts = 3
$parsed = $null
$lastErr = ''
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec 300
    } catch {
        $lastErr = "HTTP failure: $($_.Exception.Message)"
        Start-Sleep -Seconds 2; continue
    }
    $content = $resp.choices[0].message.content
    if (-not $content) { $lastErr = 'empty content'; continue }
    $json = $content
    if ($json -match '(?s)```(?:json)?\s*(\{.*?\})\s*```') { $json = $Matches[1] }
    elseif ($json -match '(?s)(\{.*\})') { $json = $Matches[1] }
    try { $candidate = $json | ConvertFrom-Json } catch { $lastErr = "invalid JSON: $($_.Exception.Message)"; continue }
    if (-not $candidate.iteration) { $lastErr = 'missing iteration field'; continue }
    $parsed = $candidate; break
}
if (-not $parsed) {
    Write-Error "invoke-supervisor: gave up after $maxAttempts attempts ($lastErr)"
    exit 1
}
$parsed | ConvertTo-Json -Depth 10
exit 0
