# visual-context.ps1: инжектит reference + current rendering в STATE.md как
# base64-images. Мультимодальная модель агента видит картинки прямо в markdown'е.
# Закрывает visual-cognitive gap (агент итерациями не видит разницы между своим
# выводом и эталоном, читая только прозу судьи).

$script:MaxImageBytes = 800000   # ~800KB на картинку, безопасно для 1280×800 PNG

function _Image-To-DataUri {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt $script:MaxImageBytes) {
        # Слишком большая — попробуем уменьшить через ImageMagick / Pillow, иначе skip.
        # Сейчас: просто skip с warning, чтобы не раздувать STATE.md.
        Write-Host "[visual-context] $Path too large ($($bytes.Length / 1KB)KB > $($script:MaxImageBytes / 1KB)KB) — skip" -ForegroundColor DarkYellow
        return $null
    }
    $b64 = [Convert]::ToBase64String($bytes)
    return "data:image/png;base64,$b64"
}

function _Resolve-VisualDir {
    param([string]$Repo, [string]$EnvVar, [string]$Default)
    $rel = if ((Get-Item "env:$EnvVar" -ErrorAction SilentlyContinue).Value) { (Get-Item "env:$EnvVar").Value } else { $Default }
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel } else { return (Join-Path $Repo $rel) }
}

function _Find-CapturePath {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Slug, [Parameter(Mandatory)][string]$Theme)
    # Capture spec нормализует slug: foo/bar → foo-bar
    $safe = $Slug -replace '/','-'
    $dir  = _Resolve-VisualDir -Repo $Repo -EnvVar 'BCF_VISION_SCREENSHOTS_DIR' -Default 'tests/vision/screenshots'
    $candidates = @(
        Join-Path $dir "$safe.$Theme.png"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function _Find-ReferencePath {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Slug, [Parameter(Mandatory)][string]$Theme)
    $safe = $Slug -replace '/','-'
    $dir  = _Resolve-VisualDir -Repo $Repo -EnvVar 'BCF_VISION_REFERENCE_DIR' -Default 'tests/vision/reference'
    $p = Join-Path $dir "$safe.$Theme.png"
    if (Test-Path $p) { return $p } else { return $null }
}

function Inject-VisualContext {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$Slugs,
        [string[]]$Themes = @('light','warm','cool','dark'),
        # Лимит: на iter не больше N pair'ов картинок в STATE.md (контекст-токены).
        [int]$MaxPairs = 4
    )
    if (-not $Slugs -or $Slugs.Count -eq 0) { return }

    $pairs = @()
    foreach ($slug in $Slugs) {
        foreach ($theme in $Themes) {
            $ref = _Find-ReferencePath -Repo $Repo -Slug $slug -Theme $theme
            $cur = _Find-CapturePath   -Repo $Repo -Slug $slug -Theme $theme
            if (-not $ref) { continue }
            $pairs += @{ slug = $slug; theme = $theme; ref = $ref; cur = $cur }
            if ($pairs.Count -ge $MaxPairs) { break }
        }
        if ($pairs.Count -ge $MaxPairs) { break }
    }
    if ($pairs.Count -eq 0) { return }

    $lines = @()
    $lines += "<visual-context source='vision-suite' note='reference vs current rendering. Если модель мультимодальна — смотри картинки и сравнивай структурно (table vs cards, расположение блоков, наличие/отсутствие компонентов).'>"
    $lines += ""
    foreach ($p in $pairs) {
        $lines += "### $($p.slug) @ $($p.theme)"
        $refUri = _Image-To-DataUri -Path $p.ref
        $curUri = if ($p.cur) { _Image-To-DataUri -Path $p.cur } else { $null }
        if ($refUri) {
            $lines += "**REFERENCE (как должно быть):**"
            $lines += ""
            $lines += "![reference $($p.slug)/$($p.theme)]($refUri)"
            $lines += ""
        } else {
            $lines += "_reference image too large to inline — открой Read'ом: $($p.ref -replace '\\','/')_"
            $lines += ""
        }
        if ($curUri) {
            $lines += "**CURRENT (как сейчас в проекте):**"
            $lines += ""
            $lines += "![current $($p.slug)/$($p.theme)]($curUri)"
            $lines += ""
        } elseif ($p.cur) {
            $lines += "_current image too large to inline — открой Read'ом: $($p.cur -replace '\\','/')_"
            $lines += ""
        } else {
            $lines += "_current image отсутствует — capture spec ещё не запускался для этой пары._"
            $lines += ""
        }
    }
    $lines += "**Что делать с картинками:** сравни структуру (DOM-уровень), не цвета. Если REFERENCE — таблица из строк, а CURRENT — карточки в grid, это **structural breakdown**: CSS-tweak не поможет, переписывай разметку от корня компонента."
    $lines += "**Если нужны детали** (расстояния, контраст): открой картинку через доступный image-understanding инструмент (пути — в каталогах reference/screenshots vision-suite)."
    $lines += "</visual-context>"
    $lines += ""

    $original = if (Test-Path $StateFile) { Get-Content -Raw -LiteralPath $StateFile } else { '' }
    if (-not $original) { $original = '' }
    $original = [regex]::Replace($original, '(?s)<visual-context[^>]*>.*?</visual-context>\r?\n?', '')
    Set-Content -LiteralPath $StateFile -Value (($lines -join "`n") + $original) -Encoding UTF8
    Write-Host "[visual-context] injected $($pairs.Count) image pairs into STATE.md" -ForegroundColor DarkCyan
}
