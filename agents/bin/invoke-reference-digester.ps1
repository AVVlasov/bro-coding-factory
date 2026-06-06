# invoke-reference-digester.ps1 — synchronous call to the reference-digester agent.
# stdin:  JSON {task_id, screen_name, reference_file, scope_slug}
# stdout: JSON digest (strict schema from agents/reference-digester.md)
# exit:   0 on a valid JSON object, 1 otherwise.
#
# Backend: any OpenAI-compatible /v1/chat/completions endpoint. Falls back to the
# retrospector endpoint/model/key when digester-specific ones are unset.
#   - endpoint : BCF_DIGESTER_ENDPOINT -> BCF_RETROSPECTOR_ENDPOINT -> BCF_API_HOST + /v1/chat/completions
#   - model    : BCF_DIGESTER_MODEL    -> BCF_RETROSPECTOR_MODEL    -> BCF_MODEL (empty = backend default <model>)
#   - api key  : BCF_DIGESTER_API_KEY  -> BCF_RETROSPECTOR_API_KEY  -> BCF_API_KEY

$ErrorActionPreference = 'Stop'

# Resolve project root: env override, else two levels up from this script (agents/bin -> repo root).
$projectRoot = if ($env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# .env fallback: the loop is often launched by a process whose env does not contain the
# API key/host. Direct REST scripts do not read .env on their own; without the key the
# backend returns 401 -> "digester failed". Pull missing values from the project .env.
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

# Robust JSON extraction from an LLM response. Some models wrap the answer in
# <think>...</think> that itself contains braces — a greedy `(\{.*\})` would grab a brace
# inside <think> and yield invalid JSON ("gave up", intermittently). Strip <think>, then
# do balanced brace-counting (string-aware) from the first '{'.
function Extract-JsonObject([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = [regex]::Replace($Text, '(?s)<think>.*?</think>', '')
    $start = $t.IndexOf('{'); if ($start -lt 0) { return $null }
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $start; $i -lt $t.Length; $i++) {
        $ch = $t[$i]
        if ($inStr) {
            if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { return $t.Substring($start, $i - $start + 1) } }
    }
    return $null
}

$apiHost  = if ($env:BCF_API_HOST) { $env:BCF_API_HOST.TrimEnd('/') } else { 'http://localhost:1234' }
$endpoint = if ($env:BCF_DIGESTER_ENDPOINT) { $env:BCF_DIGESTER_ENDPOINT } elseif ($env:BCF_RETROSPECTOR_ENDPOINT) { $env:BCF_RETROSPECTOR_ENDPOINT } else { "$apiHost/v1/chat/completions" }
$model    = if ($env:BCF_DIGESTER_MODEL)    { $env:BCF_DIGESTER_MODEL }    elseif ($env:BCF_RETROSPECTOR_MODEL)    { $env:BCF_RETROSPECTOR_MODEL }    else { $env:BCF_MODEL }
$apiKey   = if ($env:BCF_DIGESTER_API_KEY)  { $env:BCF_DIGESTER_API_KEY }  elseif ($env:BCF_RETROSPECTOR_API_KEY) { $env:BCF_RETROSPECTOR_API_KEY } else { $env:BCF_API_KEY }

$agentPath = if ($env:BCF_AGENT_PATH_REFERENCE_DIGESTER) {
    $env:BCF_AGENT_PATH_REFERENCE_DIGESTER
} elseif ($env:BCF_AGENT_DIR) {
    Join-Path $env:BCF_AGENT_DIR 'reference-digester.md'
} else {
    Join-Path $projectRoot 'agents/reference-digester.md'
}
$systemPrompt = ((Get-Content $agentPath -Raw) -replace '(?s)^---.*?---\s*', '').Trim()
$stdin = [Console]::In.ReadToEnd()
if (-not $stdin) { Write-Error 'invoke-reference-digester: empty stdin'; exit 1 }

# Parse input — we must feed the reference file's content to the model (it cannot Read on
# its own over the chat API).
try { $req = $stdin | ConvertFrom-Json } catch { Write-Error 'invoke-reference-digester: invalid stdin JSON'; exit 1 }
$refAbs = if ([System.IO.Path]::IsPathRooted($req.reference_file)) { $req.reference_file } else { Join-Path $projectRoot $req.reference_file }
$refBody = if (Test-Path $refAbs) { Get-Content -Raw -LiteralPath $refAbs } else { '' }
# Take only the Screen<Name> section via regex — otherwise 10K+ lines.
$screenSection = ''
if ($refBody -and $req.screen_name) {
    $rx = '(?ms)(?:function|const)\s+' + [regex]::Escape($req.screen_name) + '\b.*?(?=(?:\n(?:function|const|export)\s+\w+)|\z)'
    $m = [regex]::Match($refBody, $rx)
    if ($m.Success) { $screenSection = $m.Value }
}
if (-not $screenSection) { $screenSection = ($refBody -split "`r?`n" | Select-Object -First 600) -join "`n" }

$userMsg = @"
$stdin

===== CONTENT OF Screen$($req.screen_name) FROM $($req.reference_file) =====
$screenSection
"@

$body = @{
    temperature = 0.0
    messages    = @(
        @{ role = 'system'; content = $systemPrompt }
        @{ role = 'user';   content = $userMsg }
    )
}
if ($model) { $body['model'] = $model }
$body = $body | ConvertTo-Json -Depth 10 -Compress

$headers = @{ 'Content-Type' = 'application/json' }
if ($apiKey) { $headers['Authorization'] = "Bearer $apiKey" }

$maxAttempts = 3
$parsed = $null
for ($a=1; $a -le $maxAttempts; $a++) {
    try { $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body -TimeoutSec 600 } catch { Start-Sleep -Seconds 3; continue }
    $content = $resp.choices[0].message.content
    if (-not $content) { continue }
    $json = Extract-JsonObject $content
    if (-not $json) { continue }
    try { $candidate = $json | ConvertFrom-Json } catch { continue }
    if (-not $candidate.structure) { continue }
    $parsed = $candidate; break
}
if (-not $parsed) { Write-Error "invoke-reference-digester: gave up"; exit 1 }
$parsed | ConvertTo-Json -Depth 10
exit 0
