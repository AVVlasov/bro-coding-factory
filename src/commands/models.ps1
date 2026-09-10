# bcf models — ярусы моделей и их лимиты для opencode.
#
#   bcf models list                 известные модели по ярусам, что из них загружено в LM Studio
#   bcf models sync                 записать opencode.json проекта: провайдер lmstudio с лимитами
#                                   каждой загруженной модели; лимиты для моделей ролей из ярусов
#   bcf models sync --from-file f   то же, но список моделей LM Studio взять из JSON-файла (тесты)
#   bcf models list --json          машинный вывод
#
# ЗАЧЕМ. opencode не знает окна кастомной модели: без объявленного limit он не сжимает историю,
# диалог одной итерации растёт, пока сервер не ответит «context size, try increasing it»
# (LM Studio, 2026-09-09, n_tokens = 64422 на окне 64k), а ответы обрываются по max_tokens.
# Лимиты живут в config/model-tiers.json фабрики (ярус, окно, вывод, reasoning, рекомендуемое
# окно загрузки). Команда пишет их в opencode.json проекта — файл читает opencode из корня
# проекта и из его worktree через git, поэтому он попадает в git.

$project  = $script:BcfProject
$argsList = @($script:BcfArgs)
$sub      = @($argsList | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1
if (-not $sub) { $sub = 'list' }
$asJson   = $argsList -contains '--json'
$fromFile = ''
for ($i = 0; $i -lt $argsList.Count; $i++) {
    if ($argsList[$i] -eq '--from-file' -and $i + 1 -lt $argsList.Count) { $fromFile = $argsList[$i + 1] }
}

$tiersPath = Join-Path (Get-BcfHome) 'config\model-tiers.json'
$tiers = Get-Content -Raw -LiteralPath $tiersPath | ConvertFrom-Json
$known = @{}
foreach ($p in $tiers.models.PSObject.Properties) { $known[$p.Name] = $p.Value }

function Get-LmStudioModels {
    param([string]$FromFile)
    if ($FromFile) {
        if (-not (Test-Path -LiteralPath $FromFile)) { throw "файл списка моделей не найден: $FromFile" }
        $raw = Get-Content -Raw -LiteralPath $FromFile | ConvertFrom-Json
        return @($raw.data)
    }
    $base = if ($env:BCF_LMSTUDIO_URL) { $env:BCF_LMSTUDIO_URL.TrimEnd('/') } else { 'http://127.0.0.1:1234' }
    try {
        $r = Invoke-RestMethod -Uri "$base/api/v0/models" -TimeoutSec 5
        return @($r.data)
    } catch {
        try {
            $r = Invoke-RestMethod -Uri "$base/v1/models" -TimeoutSec 5
            return @($r.data)
        } catch { return @() }
    }
}

# LM Studio отдаёт по /api/v0/models поля id, state (loaded|not-loaded), loaded_context_length,
# max_context_length, type (llm|embeddings). По /v1/models только id. Берём, что есть.
function Get-ModelRow {
    param($m)
    $id = [string]$m.id
    $k = $known[$id]
    $loaded = $null
    if ($m.PSObject.Properties['state']) { $loaded = ([string]$m.state -eq 'loaded') }
    $ctxLoaded = if ($m.PSObject.Properties['loaded_context_length']) { [int]$m.loaded_context_length } else { 0 }
    $ctxMax    = if ($m.PSObject.Properties['max_context_length'])    { [int]$m.max_context_length }    else { 0 }
    $isEmb = ($m.PSObject.Properties['type'] -and [string]$m.type -eq 'embeddings') -or ($k -and $k.PSObject.Properties['embedding'] -and $k.embedding)
    [pscustomobject]@{
        id        = $id
        known     = [bool]$k
        tier      = if ($k) { [string]$k.tier } else { 'local' }
        loaded    = $loaded
        ctxLoaded = $ctxLoaded
        ctxMax    = $ctxMax
        embedding = $isEmb
        limit     = if ($k -and $k.limit) { $k.limit } else { $null }
        reasoning = if ($k -and $k.PSObject.Properties['reasoning']) { [bool]$k.reasoning } else { $false }
        local     = if ($k -and $k.PSObject.Properties['local']) { $k.local } else { $null }
    }
}

$lms = @(Get-LmStudioModels -FromFile $fromFile | ForEach-Object { Get-ModelRow $_ })

if ($sub -eq 'list') {
    if ($asJson) {
        [pscustomobject]@{ tiers = $tiers.models; lmstudio = $lms } | ConvertTo-Json -Depth 8
        return
    }
    Write-Host ''
    Write-BcfTitle 'МОДЕЛИ' "ярусы из config/model-tiers.json, обновлено $($tiers.updated)"
    foreach ($tier in @('local', 'free', 'paid', 'subscription')) {
        $rows = New-BcfRows
        foreach ($p in $tiers.models.PSObject.Properties) {
            if ([string]$p.Value.tier -ne $tier) { continue }
            $lim = if ($p.Value.limit) { "$($p.Value.limit.context) / $($p.Value.limit.output)" } else { 'у CLI' }
            $st = ''
            $live = $lms | Where-Object { $_.id -eq $p.Name } | Select-Object -First 1
            if ($live) { $st = if ($live.loaded -eq $true) { "загружена, окно $($live.ctxLoaded)" } elseif ($live.loaded -eq $false) { 'на диске' } else { 'есть' } }
            Add-BcfRow $rows @($p.Name, $lim, $(if ($p.Value.reasoning) { 'да' } else { 'нет' }), (($p.Value.roles) -join ', '), $st)
        }
        if ($rows.Count -eq 0) { continue }
        Write-BcfLine "  $tier" 'White'
        Write-BcfTable -Headers @('модель', 'окно / вывод', 'reasoning', 'роли', 'LM Studio') -Widths @(42, 18, 9, 24, 24) -Rows $rows
        Write-Host ''
    }
    $unknown = @($lms | Where-Object { -not $_.known })
    if ($unknown.Count) {
        Write-BcfWarn "в LM Studio есть модели без яруса: $(($unknown | ForEach-Object { $_.id }) -join ', ') — sync объявит их с окном загрузки, без reasoning"
    }
    if ($lms.Count -eq 0) { Write-BcfDim 'LM Studio не отвечает на 127.0.0.1:1234 — локальные модели не показаны' }
    return
}

if ($sub -eq 'sync') {
    $cfg = $null
    try { $cfg = Get-BcfHarnessConfig -Project $project } catch { Write-BcfWarn "config/harness.json: $($_.Exception.Message)" }
    $roleModels = @()
    if ($cfg -and $cfg.graph -and $cfg.graph.roles) {
        foreach ($r in $cfg.graph.roles.PSObject.Properties) {
            if ($r.Name -like '$*') { continue }
            if ($r.Value.model) { $roleModels += [string]$r.Value.model }
        }
    }
    if ($cfg -and $cfg.models) {
        foreach ($mp in $cfg.models.PSObject.Properties) { if ($mp.Name -notlike '$*' -and $mp.Value) { $roleModels += [string]$mp.Value } }
    }
    $roleModels = @($roleModels | Select-Object -Unique)

    $out = [ordered]@{ '$schema' = 'https://opencode.ai/config.json' }
    $providers = [ordered]@{}

    # 1. LM Studio: каждая модель на диске, лимиты по ярусу, окно по загрузке.
    $lmModels = [ordered]@{}
    foreach ($m in $lms) {
        if ($m.embedding) { continue }
        $ctx = 0
        if ($m.limit -and $m.limit.context) { $ctx = [int]$m.limit.context }
        if ($m.ctxLoaded -gt 0) { $ctx = $m.ctxLoaded }
        elseif ($m.local -and $m.local.context) { $ctx = [int]$m.local.context }
        elseif ($ctx -eq 0 -and $m.ctxMax -gt 0) { $ctx = $m.ctxMax }
        $outTok = if ($m.limit -and $m.limit.output) { [int]$m.limit.output } else { [Math]::Max(4096, [int]($ctx / 4)) }
        $entry = [ordered]@{ name = "$($m.id) (LM Studio)" }
        if ($ctx -gt 0) { $entry.limit = [ordered]@{ context = $ctx; output = $outTok } }
        if ($m.reasoning) { $entry.reasoning = $true; $entry.interleaved = [ordered]@{ field = 'reasoning_content' } }
        $lmModels[$m.id] = $entry
    }
    if ($lmModels.Count) {
        $lmBase = if ($env:BCF_LMSTUDIO_URL) { $env:BCF_LMSTUDIO_URL.TrimEnd('/') + '/v1' } else { 'http://127.0.0.1:1234/v1' }
        $providers['lmstudio'] = [ordered]@{
            npm = '@ai-sdk/openai-compatible'
            name = 'LM Studio (local)'
            options = [ordered]@{ baseURL = $lmBase }
            models = $lmModels
        }
    }

    # 2. Модели ролей у сетевых провайдеров: лимиты из ярусов, если модель известна.
    $netModels = @{}
    foreach ($rm in $roleModels) {
        $parts = $rm -split '/', 2
        if ($parts.Count -lt 2) { continue }
        $prov = $parts[0]; $mid = $parts[1]
        if ($prov -eq 'lmstudio') { continue }
        $k = $known[$mid]
        if (-not $k -or -not $k.limit) { continue }
        if (-not $netModels[$prov]) { $netModels[$prov] = [ordered]@{} }
        $e = [ordered]@{ limit = [ordered]@{ context = [int]$k.limit.context; output = [int]$k.limit.output } }
        $netModels[$prov][$mid] = $e
    }
    foreach ($prov in $netModels.Keys) {
        if (-not $providers[$prov]) { $providers[$prov] = [ordered]@{ models = [ordered]@{} } }
        foreach ($mid in $netModels[$prov].Keys) { $providers[$prov].models[$mid] = $netModels[$prov][$mid] }
    }
    if ($providers.Count) { $out.provider = $providers }

    $target = Join-Path $project 'opencode.json'
    $json = ($out | ConvertTo-Json -Depth 8)
    Set-Content -LiteralPath $target -Value $json -Encoding UTF8
    if ($asJson) { $json; return }
    Write-Host ''
    Write-BcfTitle 'МОДЕЛИ: SYNC' $target
    foreach ($prov in $providers.Keys) {
        foreach ($mid in $providers[$prov].models.Keys) {
            $e = $providers[$prov].models[$mid]
            $lim = if ($e.limit) { "окно $($e.limit.context), вывод $($e.limit.output)" } else { 'без лимита' }
            Write-BcfOk "$prov/$mid — $lim$(if ($e.reasoning) { ', reasoning' })"
        }
    }
    foreach ($rm in $roleModels) {
        $parts = $rm -split '/', 2
        if ($parts.Count -lt 2) { continue }
        if ($parts[0] -eq 'lmstudio' -and -not $lmModels[$parts[1]]) { Write-BcfWarn "роль ждёт $rm, а в LM Studio такой модели нет" }
        if ($parts[0] -ne 'lmstudio' -and -not $known[$parts[1]]) { Write-BcfDim "$rm — яруса нет в model-tiers.json, лимиты возьмёт сам провайдер" }
    }
    # Рекомендация по загрузке: локальная модель роли с окном меньше рекомендованного.
    foreach ($m in $lms) {
        if (-not $m.local -or -not $m.local.context) { continue }
        if ($roleModels -notcontains "lmstudio/$($m.id)") { continue }
        if ($m.loaded -eq $true -and $m.ctxLoaded -gt 0 -and $m.ctxLoaded -ne [int]$m.local.context) {
            Write-BcfNote "окно $($m.id) сейчас $($m.ctxLoaded), рекомендовано $($m.local.context) ($($m.local.note)):`n    lms unload $($m.id); lms load $($m.id) --gpu max --context-length $($m.local.context) --parallel $($m.local.parallel) -y"
        }
    }
    return
}

if ($sub -eq 'free') {
    . (Join-Path $BcfRoot 'src\lib\openrouter.ps1')
    $rows = Get-BcfOpenRouterFree -FromFile $fromFile
    if ($null -eq $rows) { Write-BcfFail 'OpenRouter не ответил за 10 с — список бесплатных моделей недоступен'; exit 3 }
    $cands = Get-BcfFreeCandidates -Rows $rows
    if ($asJson) { @{ free = $rows; candidates = $cands } | ConvertTo-Json -Depth 5; return }
    Write-Host ''
    Write-BcfTitle 'БЕСПЛАТНЫЕ МОДЕЛИ OPENROUTER' "всего $($rows.Count); база сравнения qwen 3.8 27b, окно 98304"
    foreach ($r in $rows) {
        $sz = if ($r.ParamsB) { "$($r.ParamsB)B$(if ($r.ActiveB) { " (активных $($r.ActiveB)B)" })" } else { 'размер не в имени' }
        Write-BcfLine ("    {0,-52} {1,-28} окно {2,-8} {3}" -f $r.Id, $sz, $r.Context, $r.Created) 'Gray'
    }
    Write-Host ''
    if ($cands.Count) {
        Write-BcfOk "кандидаты в воркеры (параметров больше 27B, окно не меньше 98304): $(@($cands | ForEach-Object { $_.Id }) -join ', ')"
        Write-BcfNote 'размер это не качество: перед сменой воркера прогнать кандидата на одной лёгкой задаче и сравнить итерации до PASS'
    } else {
        Write-BcfDim 'кандидатов сильнее локального воркера по размеру нет'
    }
    return
}

Write-BcfFail "неизвестная подкоманда: $sub"
Write-BcfNote 'доступно: list | sync [--from-file <json>] | free [--from-file <json>] [--json]'
exit 2
