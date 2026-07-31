# reference-digest.ps1 — обёртка над reference-digester.
# Lazy-cache: digest пишется в tasks/<task>/reference-digest.{md,json} один раз
# и переиспользуется. Перегенерация — если эталон newer.

# Repo root + digester invoker: env override, иначе repo-relative default.
. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:RepoRoot = Get-BcfProjectRoot
$script:Digester = if ($env:BCF_INVOKE_REFERENCE_DIGESTER) { $env:BCF_INVOKE_REFERENCE_DIGESTER } else { Join-Path $script:RepoRoot '.claude/agents/bin/invoke-reference-digester.ps1' }

function Get-OrCreate-ReferenceDigest {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ScreenName,
        # Путь к reference design file приходит из task/config; дефолт — env или пусто.
        [string]$ReferenceFile = '',
        [string]$ScopeSlug = ''
    )
    if (-not $ReferenceFile) { $ReferenceFile = if ($env:BCF_REFERENCE_FILE) { $env:BCF_REFERENCE_FILE } else { '' } }
    if (-not $ReferenceFile) {
        Write-Host "[reference-digest] reference file not configured (pass -ReferenceFile or set BCF_REFERENCE_FILE)" -ForegroundColor DarkYellow
        return $null
    }
    $digestDir = Join-Path $Repo "tasks\$TaskId"
    if (-not (Test-Path $digestDir)) { New-Item -ItemType Directory -Force -Path $digestDir | Out-Null }
    $digestFile = Join-Path $digestDir "reference-digest.json"
    $digestMd   = Join-Path $digestDir "reference-digest.md"

    $refAbs = if ([System.IO.Path]::IsPathRooted($ReferenceFile)) { $ReferenceFile } else { Join-Path $Repo $ReferenceFile }
    if ((Test-Path $digestFile) -and (Test-Path $refAbs)) {
        $refMtime = (Get-Item $refAbs).LastWriteTimeUtc
        $dgMtime  = (Get-Item $digestFile).LastWriteTimeUtc
        if ($dgMtime -ge $refMtime) { return $digestMd }
    }
    if (-not (Test-Path $script:Digester)) { return $null }
    if (-not (Test-Path $refAbs)) {
        Write-Host "[reference-digest] reference file not found: $refAbs" -ForegroundColor DarkYellow
        return $null
    }

    Write-Host "[reference-digest] regenerating digest for $TaskId / $ScreenName ..." -ForegroundColor DarkCyan
    $input = @{
        task_id        = $TaskId
        screen_name    = $ScreenName
        reference_file = $ReferenceFile
        scope_slug     = $ScopeSlug
    } | ConvertTo-Json
    $tmp = Join-Path $env:TEMP "digester-$TaskId.json"
    Set-Content -LiteralPath $tmp -Value $input -Encoding UTF8
    $out = Get-Content -Raw -LiteralPath $tmp | & pwsh -NoProfile -File $script:Digester 2>$null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $out) {
        Write-Host "[reference-digest] digester failed for $TaskId" -ForegroundColor DarkYellow
        return $null
    }
    Set-Content -LiteralPath $digestFile -Value $out -Encoding UTF8
    Set-Content -LiteralPath $digestMd   -Value (_Digest-To-Markdown $out) -Encoding UTF8
    return $digestMd
}

function _Digest-To-Markdown {
    param([Parameter(Mandatory)][string]$JsonText)
    try { $d = $JsonText | ConvertFrom-Json } catch { return "# digest (raw)`n`n``````json`n$JsonText`n``````" }
    $lines = @("# Reference digest — $($d.screen_name) ($($d.task_id))", '',
               "**Root:** ``$($d.structure.root_element)`` | **Layout:** $($d.structure.layout)", '',
               "## Структура (блоки)")
    foreach ($b in @($d.structure.blocks)) {
        $lines += ''
        $lines += "### $($b.name) — ``$($b.element)``"
        if ($b.columns)     { $lines += "  - **Columns:** $($b.columns -join ', ')" }
        if ($b.rows_source) { $lines += "  - **Rows from:** ``$($b.rows_source)``" }
        if ($b.row_actions) { $lines += "  - **Row actions:** $($b.row_actions -join ', ')" }
        if ($b.layout)      { $lines += "  - **Layout:** $($b.layout)" }
        if ($b.cards)       { foreach ($c in $b.cards)    { $lines += "  - **Card $($c.name):** fields=$($c.fields -join ', ')" } }
        if ($b.children)    { foreach ($c in $b.children) { $lines += "  - $($c.name) (``$($c.element)``)$(if($c.content){ ' — "' + $c.content + '"' })$(if($c.items){ ': ' + ($c.items -join ', ') })" } }
        if ($b.actions)     { $lines += "  - **Actions:** $($b.actions -join ', ')" }
    }
    if ($d.absent -and $d.absent.Count -gt 0) {
        $lines += '', '## Отсутствует в эталоне (НЕ добавляй)'
        foreach ($a in $d.absent) { $lines += "- $a" }
    }
    if ($d.invariants -and $d.invariants.Count -gt 0) {
        $lines += '', '## Invariants (non-negotiable)'
        foreach ($i in $d.invariants) { $lines += "- $i" }
    }
    if ($d.tokens_used -and $d.tokens_used.Count -gt 0) {
        $lines += '', '## Design tokens'
        $lines += "- " + ($d.tokens_used -join ', ')
    }
    return ($lines -join "`n")
}

function Inject-ReferenceDigest {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$DigestMdFile
    )
    if (-not (Test-Path $DigestMdFile)) { return }
    $body = Get-Content -Raw -LiteralPath $DigestMdFile
    $block = "<reference-digest source='reference-digester' note='Canonical structural digest эталона. Это фиксированная истина: если здесь сказано table — это table, не grid-fake. Сверяй свой компонент с invariants.'>`n$body`n</reference-digest>`n`n"
    $original = if (Test-Path $StateFile) { Get-Content -Raw -LiteralPath $StateFile } else { '' }
    if (-not $original) { $original = '' }
    $original = [regex]::Replace($original, '(?s)<reference-digest[^>]*>.*?</reference-digest>\r?\n?', '')
    Set-Content -LiteralPath $StateFile -Value ($block + $original) -Encoding UTF8
    Write-Host "[reference-digest] injected into STATE.md" -ForegroundColor DarkCyan
}
