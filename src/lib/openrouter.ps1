# openrouter.ps1 — бесплатные модели OpenRouter против локального воркера.
#
# Владелец 2026-09-10: «openrouter опциональный, при каждом запуске нужно чекать акции на
# бесплатные модели, если там есть что то достойнее qwen 3.8 27b то подключай ее как worker.
# сильные модели должны быть критиками и судьями». Список берётся с публичного
# https://openrouter.ai/api/v1/models (ключ не нужен), бесплатные это id с суффиксом «:free».
# «Достойнее» без замера не решается: команда называет кандидатов по размеру (число
# параметров из имени модели) и окну, а выбор воркера остаётся за владельцем или за
# прогоном-пробой на лёгкой задаче.

function Get-BcfModelParamsB {
    param([string]$Id)
    # Число параметров из имени: «550b-a55b» → 550 (всего) и 55 (активных), «31b» → 31.
    $s = $Id.ToLower()
    $total = 0.0; $active = 0.0
    $m = [regex]::Matches($s, '(\d+(?:\.\d+)?)b(?![a-z])')
    foreach ($x in $m) { $v = [double]$x.Groups[1].Value; if ($v -gt $total) { $total = $v } }
    $ma = [regex]::Match($s, '-a(\d+(?:\.\d+)?)b')
    if ($ma.Success) { $active = [double]$ma.Groups[1].Value }
    return @{ Total = $total; Active = $active }
}

function Get-BcfOpenRouterFree {
    param([string]$FromFile = '', [int]$TimeoutSec = 10)
    $data = $null
    if ($FromFile) {
        if (-not (Test-Path -LiteralPath $FromFile)) { throw "файл списка моделей не найден: $FromFile" }
        $data = (Get-Content -Raw -LiteralPath $FromFile | ConvertFrom-Json).data
    } else {
        try { $data = (Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -TimeoutSec $TimeoutSec).data }
        catch { return $null }
    }
    $rows = @()
    foreach ($m in @($data)) {
        $id = [string]$m.id
        if (-not $id.EndsWith(':free')) { continue }
        $p = Get-BcfModelParamsB $id
        $created = 0
        if ($m.PSObject.Properties['created'] -and $m.created) { $created = [long]$m.created }
        $rows += [pscustomobject]@{
            Id      = $id
            Name    = [string]$m.name
            Context = $(if ($m.PSObject.Properties['context_length'] -and $m.context_length) { [int]$m.context_length } else { 0 })
            ParamsB = $p.Total
            ActiveB = $p.Active
            Created = $(if ($created) { [DateTimeOffset]::FromUnixTimeSeconds($created).DateTime.ToString('yyyy-MM-dd') } else { '' })
        }
    }
    return @($rows | Sort-Object -Property @{ Expression = 'ParamsB'; Descending = $true }, @{ Expression = 'Created'; Descending = $true })
}

# Кандидаты сильнее локального воркера: больше параметров, чем у базы (по умолчанию 27,
# qwen 3.8 27b), и окно не меньше базового. MoE считаем по общему числу параметров, но
# показываем активные: у 120b-a12b активных меньше, чем у плотной 27b, и это надо видеть.
function Get-BcfFreeCandidates {
    param([array]$Rows, [double]$BaselineB = 27, [int]$BaselineContext = 98304)
    return @($Rows | Where-Object { $_.ParamsB -gt $BaselineB -and $_.Context -ge $BaselineContext })
}
