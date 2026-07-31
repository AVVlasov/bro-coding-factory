# invoke-test-author.ps1 — synchronous call to the test-author agent for chronic bugs.
# stdin:  JSON (see agents/test-author.md `## Inputs`)
# stdout: JSON per the test-author schema, no markdown fences.
# exit:   0 on a valid JSON object, 1 otherwise.
#
# Backend: any OpenAI-compatible /v1/chat/completions endpoint. Falls back to the
# retrospector endpoint/model/key when test-author-specific ones are unset.
#   - endpoint : BCF_TEST_AUTHOR_ENDPOINT -> BCF_RETROSPECTOR_ENDPOINT -> BCF_API_HOST + /v1/chat/completions
#   - model    : BCF_TEST_AUTHOR_MODEL    -> BCF_RETROSPECTOR_MODEL    -> BCF_MODEL (empty = backend default <model>)
#   - api key  : BCF_TEST_AUTHOR_API_KEY  -> BCF_RETROSPECTOR_API_KEY  -> BCF_API_KEY

$ErrorActionPreference = 'Stop'

# Resolve project root: env override, else two levels up from this script (agents/bin -> repo root).
$projectRoot = if ($env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# .env fallback so the key/host are available regardless of how the parent was launched.
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
$endpoint = if ($env:BCF_TEST_AUTHOR_ENDPOINT) { $env:BCF_TEST_AUTHOR_ENDPOINT } elseif ($env:BCF_RETROSPECTOR_ENDPOINT) { $env:BCF_RETROSPECTOR_ENDPOINT } else { "$apiHost/v1/chat/completions" }
$model    = if ($env:BCF_TEST_AUTHOR_MODEL)    { $env:BCF_TEST_AUTHOR_MODEL }    elseif ($env:BCF_RETROSPECTOR_MODEL)    { $env:BCF_RETROSPECTOR_MODEL }    else { $env:BCF_MODEL }
$apiKey   = if ($env:BCF_TEST_AUTHOR_API_KEY)  { $env:BCF_TEST_AUTHOR_API_KEY }  elseif ($env:BCF_RETROSPECTOR_API_KEY) { $env:BCF_RETROSPECTOR_API_KEY } else { $env:BCF_API_KEY }

$agentPath = if ($env:BCF_AGENT_PATH_TEST_AUTHOR) {
    $env:BCF_AGENT_PATH_TEST_AUTHOR
} elseif ($env:BCF_AGENT_DIR) {
    Join-Path $env:BCF_AGENT_DIR 'test-author.md'
} else {
    Join-Path $projectRoot 'agents/test-author.md'
}
$systemPrompt = ((Get-Content $agentPath -Raw) -replace '(?s)^---.*?---\s*', '').Trim()
$stdin = [Console]::In.ReadToEnd()
if (-not $stdin) { Write-Error 'invoke-test-author: empty stdin'; exit 1 }

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

$maxAttempts = 2
$parsed = $null
for ($a=1; $a -le $maxAttempts; $a++) {
    try { $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec 600 } catch { Start-Sleep -Seconds 3; continue }
    $content = $resp.choices[0].message.content
    if (-not $content) { continue }
    $json = $content
    if ($json -match '(?s)```(?:json)?\s*(\{.*?\})\s*```') { $json = $Matches[1] }
    elseif ($json -match '(?s)(\{.*\})') { $json = $Matches[1] }
    try { $candidate = $json | ConvertFrom-Json } catch { continue }
    if (-not $candidate.short_id) { continue }
    $parsed = $candidate; break
}
if (-not $parsed) { Write-Error "invoke-test-author: gave up"; exit 1 }
$parsed | ConvertTo-Json -Depth 10
exit 0
