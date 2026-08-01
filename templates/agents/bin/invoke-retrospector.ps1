# invoke-retrospector.ps1 — synchronous call to the retrospector agent over an
# OpenAI-compatible API.
# Contract:
#   stdin:  JSON {iteration_id, transcript, diff?, verdicts?, findings?, prior_memory?}
#   stdout: JSON per the retrospector schema (agents/retrospector.md), no markdown fences.
#   exit:   0 on a valid JSON object, 1 otherwise.
#
# Backend: any OpenAI-compatible /v1/chat/completions endpoint.
#   - endpoint : $env:BCF_RETROSPECTOR_ENDPOINT, else $env:BCF_API_HOST + /v1/chat/completions
#   - model    : $env:BCF_RETROSPECTOR_MODEL,    else $env:BCF_MODEL (empty = backend default <model>)
#   - api key  : $env:BCF_RETROSPECTOR_API_KEY,  else $env:BCF_API_KEY (read from env or project .env)

$ErrorActionPreference = 'Stop'

# Resolve project root: env override, else two levels up from this script (agents/bin -> repo root).
$projectRoot = if ($env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# .env fallback: the loop is often launched by a process whose env does not contain the
# API key/host (e.g. they were added after the parent started). Direct REST scripts do not
# read .env on their own, so pull missing values from the project .env here.
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
# ВСЕ переменные ретроспектора, а не только ключ и хост.
#
# Модель тоже обязана подтягиваться из .env: без неё тело запроса уходит без поля "model",
# провайдер отвечает 400, и ретроспектор молча перестаёт работать — при этом цикл обучения
# снаружи выглядит включённым. Ровно на это напоролись в bro-game-cheat и правили там
# локально; правка возвращена в шаблон, чтобы её не пришлось повторять в каждом проекте.
foreach ($__name in @('BCF_API_KEY', 'BCF_API_HOST', 'BCF_RETROSPECTOR_MODEL', 'BCF_MODEL',
                      'BCF_RETROSPECTOR_ENDPOINT', 'BCF_RETROSPECTOR_API_KEY')) {
    if (-not (Get-Item "env:$__name" -ErrorAction SilentlyContinue)) {
        $v = Get-DotEnvValue $dotenv $__name
        if ($v) { Set-Item "env:$__name" $v }
    }
}

# Robust JSON extraction from an LLM response. Some models wrap the answer in
# <think>...</think> that itself contains braces — a greedy `(\{.*\})` breaks intermittently.
# Strip <think>, then do balanced brace-counting (string-aware) from the first '{'.
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
$endpoint = if ($env:BCF_RETROSPECTOR_ENDPOINT) { $env:BCF_RETROSPECTOR_ENDPOINT } else { "$apiHost/v1/chat/completions" }
$model    = if ($env:BCF_RETROSPECTOR_MODEL)    { $env:BCF_RETROSPECTOR_MODEL }    else { $env:BCF_MODEL }
$apiKey   = if ($env:BCF_RETROSPECTOR_API_KEY)  { $env:BCF_RETROSPECTOR_API_KEY }  else { $env:BCF_API_KEY }

# 1. System prompt = agent .md body without frontmatter.
$agentPath = if ($env:BCF_AGENT_PATH_RETROSPECTOR) {
    $env:BCF_AGENT_PATH_RETROSPECTOR
} elseif ($env:BCF_AGENT_DIR) {
    Join-Path $env:BCF_AGENT_DIR 'retrospector.md'
} else {
    Join-Path $projectRoot 'agents/retrospector.md'
}
$raw = Get-Content $agentPath -Raw
$systemPrompt = ($raw -replace '(?s)^---.*?---\s*', '').Trim()

# 2. Input comes from stdin.
$stdin = [Console]::In.ReadToEnd()
if (-not $stdin) { Write-Error 'invoke-retrospector: empty stdin'; exit 1 }

# 3. Build payload.
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

# 4. Request with retry (models occasionally return invalid/incomplete JSON).
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

    $json = Extract-JsonObject $content
    if (-not $json) { $lastErr = 'no JSON object in content'; continue }

    try { $candidate = $json | ConvertFrom-Json } catch { $lastErr = "invalid JSON: $($_.Exception.Message)"; continue }
    if (-not $candidate.iteration_id) { $lastErr = 'missing iteration_id'; continue }
    $parsed = $candidate; break
}
if (-not $parsed) {
    Write-Error "invoke-retrospector: gave up after $maxAttempts attempts ($lastErr)"
    exit 1
}

# 5. Canonicalize (stable JSON out).
$parsed | ConvertTo-Json -Depth 10
exit 0
