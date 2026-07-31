# redo-trigger.ps1: structural breakdown detector.
# Если SSIM < 0.5 хотя бы в одной паре slug/theme — это не CSS-drift, а
# структурный breakdown (table vs cards, missing block). Подкрутки не помогут.
# Триггерим режим redo-from-scratch: специальный блок в STATE.md, инструктирующий
# агента снести компонент и пересоздать по reference-digest.

function Get-VisionStructuralStatus {
    param([Parameter(Mandatory)][string]$Repo)
    $visionResultsRel = if ($env:BCF_VISION_RESULTS_DIR) { $env:BCF_VISION_RESULTS_DIR } else { 'tests/vision/results' }
    $resultsRoot = if ([System.IO.Path]::IsPathRooted($visionResultsRel)) { $visionResultsRel } else { Join-Path $Repo $visionResultsRel }
    if (-not (Test-Path $resultsRoot)) { return $null }
    $latest = Get-ChildItem $resultsRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $aggFile = Join-Path $latest.FullName 'aggregate.json'
    if (-not (Test-Path $aggFile)) { return $null }
    try { $agg = Get-Content -Raw -LiteralPath $aggFile | ConvertFrom-Json } catch { return $null }
    $worstSsim = 1.0
    $breakdowns = @()
    foreach ($r in @($agg.results)) {
        # Stale-capture guard: пропускаем темы с устаревшим/missing скриншотом
        # (playwright-воркер крашнулся) — их SSIM посчитан против старой картинки
        # и НЕ является настоящим structural breakdown. Иначе ложный redo-from-scratch.
        if ($r.stale -or $r.error -or "$($r.severity)" -eq 'UNKNOWN') { continue }
        $ssim = if ($r.ssim) { [double]$r.ssim } else { 1.0 }
        if ($ssim -lt $worstSsim) { $worstSsim = $ssim }
        if ($ssim -lt 0.5) {
            $breakdowns += @{ slug = $r.page; theme = $r.theme; ssim = $ssim; severity = "$($r.severity)" }
        }
    }
    return @{
        worst_ssim = $worstSsim
        breakdowns = $breakdowns
        has_breakdown = ($breakdowns.Count -gt 0)
    }
}

function Inject-RedoFromScratch {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][array]$Breakdowns,
        [int]$ItersWithoutPass = 0
    )
    if (-not $Breakdowns -or $Breakdowns.Count -eq 0) { return }

    $worst = ($Breakdowns | Sort-Object { [double]$_.ssim } | Select-Object -First 1)
    $list = ($Breakdowns | ForEach-Object { "$($_.slug)/$($_.theme) SSIM=$([math]::Round([double]$_.ssim,3))" }) -join ', '

    $lines = @()
    $lines += "<redo-from-scratch trigger='structural-breakdown' worst='$($worst.slug)/$($worst.theme) SSIM=$([math]::Round([double]$worst.ssim,3))' iters_without_pass='$ItersWithoutPass'>"
    $lines += "⚠️ STRUCTURAL BREAKDOWN — SSIM ниже 0.5 значит **картинки структурно разные**, не просто цвета."
    $lines += "Breakdowns: $list"
    $lines += ""
    $lines += "За $ItersWithoutPass итераций ты пытаешься подкрутить существующий компонент — это не работает."
    $lines += "Подкрутки CSS не закроют разницу между ``<div>``-карточками и ``<table>``-строками."
    $lines += ""
    $lines += "**Инструкция этой итерации (не подкручивай — переделай):**"
    $lines += "1. Открой ``<reference-digest>`` блок выше. Это canonical структура эталона."
    $lines += "2. Открой картинки в ``<visual-context>`` блоке. REFERENCE = цель; CURRENT = что у тебя."
    $lines += "3. Сравни **на уровне DOM**: какие HTML-элементы должны быть, каких сейчас нет, что лишнее."
    $lines += "4. Удали проблемный компонент **целиком** и **пересоздай с нуля** по reference-digest."
    $lines += "   Не правь старый код — он structurally wrong."
    $lines += "5. Используй только compose-элементы из digest'а: если там ``<table>`` — пиши ``<table>``,"
    $lines += "   не ``<div className='grid'>``. Если там написано ``element: table`` — это table."
    $lines += "6. Удали всё что в digest помечено как ``absent`` (компоненты, которых нет в эталоне)."
    $lines += ""
    $lines += "**Что НЕ делать:**"
    $lines += "- Менять цвета, тени, отступы у существующего компонента — это пятый-десятый круг ада."
    $lines += "- Добавлять wrapper-элементы вокруг проблемного — это ещё больше карточек."
    $lines += "- Объявлять «теперь это table» через CSS ``display: table-row`` — это всё ещё ``<div>``."
    $lines += "</redo-from-scratch>"
    $lines += ""

    $original = if (Test-Path $StateFile) { Get-Content -Raw -LiteralPath $StateFile } else { '' }
    if (-not $original) { $original = '' }
    $original = [regex]::Replace($original, '(?s)<redo-from-scratch[^>]*>.*?</redo-from-scratch>\r?\n?', '')
    Set-Content -LiteralPath $StateFile -Value (($lines -join "`n") + $original) -Encoding UTF8
    Write-Host "[redo-trigger] STATE.md: redo-from-scratch injected (worst SSIM=$([math]::Round([double]$worst.ssim,3)))" -ForegroundColor Yellow
}
