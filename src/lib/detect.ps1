# detect.ps1 — разбор проекта. Ничего не пишет, только читает.
#
# Смысл шага не в том, чтобы «определить стек» — это интересно только на демонстрации.
# Смысл в четырёх значениях, без которых харнесс работает вхолостую:
#
#   productPaths     где искать «прогресса нет» и расползание скоупа. Ошибка здесь
#                    означает, что правки в доках считаются работой над задачей.
#   backpressure     быстрая проверка после каждой итерации. Если команда не существует,
#                    гейт красный ВСЕГДА — и агент чинит несуществующее.
#   generatedFiles   что не блокирует слияние. Один лок-файл однажды завалил слияние
#                    семи задач подряд, каждая из которых уже дошла до PASS.
#   tests.runner     чем доказывается закрытая задача. Без него общий прогон тестов
#                    зелен и на пустом месте.
#
# Поэтому каждое предложение помечено источником: «проверено» — команду запускали и она
# отработала; «уверенно» — следует из файлов, которые есть на диске; «догадка» — вывели
# по косвенным признакам, стоит посмотреть глазами.

function Get-BcfLanguageStats {
    param([Parameter(Mandatory)][string]$Root)

    $map = @{
        '.rs' = 'Rust'; '.ts' = 'TypeScript'; '.tsx' = 'TypeScript'; '.js' = 'JavaScript'
        '.jsx' = 'JavaScript'; '.py' = 'Python'; '.go' = 'Go'; '.java' = 'Java'
        '.kt' = 'Kotlin'; '.cs' = 'C#'; '.cpp' = 'C++'; '.cc' = 'C++'; '.c' = 'C'
        '.h' = 'C/C++'; '.hpp' = 'C++'; '.rb' = 'Ruby'; '.php' = 'PHP'; '.swift' = 'Swift'
        '.ps1' = 'PowerShell'; '.sh' = 'Shell'; '.sql' = 'SQL'; '.vue' = 'Vue'; '.svelte' = 'Svelte'
    }
    $skip = '(^|[\\/])(\.git|node_modules|target|dist|build|out|vendor|__pycache__|\.venv|venv|\.bcf|\.next|coverage)([\\/]|$)'

    $counts = @{}
    $total = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        if ($rel -match $skip) { continue }
        $lang = $map[$f.Extension.ToLower()]
        if (-not $lang) { continue }
        if (-not $counts.ContainsKey($lang)) { $counts[$lang] = 0 }
        $counts[$lang]++
        $total++
    }
    $out = @()
    foreach ($k in ($counts.Keys | Sort-Object { -$counts[$_] })) {
        $out += [pscustomobject]@{ Language = $k; Files = $counts[$k]
                                   Percent = if ($total) { [math]::Round(100.0 * $counts[$k] / $total) } else { 0 } }
    }
    return [pscustomobject]@{ Total = $total; Languages = $out }
}

# --- Экосистемы -----------------------------------------------------------------------
#
# Каждая запись — не «язык», а связка: манифест → продуктовые каталоги → быстрая
# проверка → раннер тестов → воспроизводимые сборкой файлы. Ровно то, что нужно
# харнессу, и ничего сверх.
$script:BcfEcosystems = @(
    @{ key = 'cargo';  manifest = 'Cargo.toml'
       product = @('src', 'crates'); typecheck = 'cargo check --workspace --quiet'
       tests = @{ runner = 'cargo' }; generated = @('Cargo.lock') }
    @{ key = 'node';   manifest = 'package.json'
       product = @('src', 'app/src', 'lib'); typecheck = ''
       tests = @{ runner = '' }; generated = @('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock') }
    @{ key = 'python'; manifest = 'pyproject.toml'
       product = @('src'); typecheck = ''
       tests = @{ runner = 'pytest' }; generated = @('poetry.lock', 'uv.lock') }
    @{ key = 'go';     manifest = 'go.mod'
       product = @('cmd', 'internal', 'pkg'); typecheck = 'go build ./...'
       tests = @{ runner = 'go' }; generated = @('go.sum') }
    @{ key = 'dotnet'; manifest = '*.sln'
       product = @('src'); typecheck = 'dotnet build --nologo -v q'
       tests = @{ runner = '' }; generated = @() }
)

function Get-BcfEcosystems {
    param([Parameter(Mandatory)][string]$Root)
    $found = @()
    foreach ($e in $script:BcfEcosystems) {
        $hit = if ($e.manifest -like '*`**') {
            [bool](Get-ChildItem -LiteralPath $Root -Filter $e.manifest -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        } else {
            Test-Path (Join-Path $Root $e.manifest)
        }
        if ($hit) { $found += $e }
    }
    # Монорепа: package.json часто лежит не в корне, а в app/ или web/.
    if (-not ($found | Where-Object { $_.key -eq 'node' })) {
        foreach ($sub in @('app', 'web', 'frontend', 'client', 'ui')) {
            if (Test-Path (Join-Path $Root "$sub\package.json")) {
                $n = ($script:BcfEcosystems | Where-Object { $_.key -eq 'node' })[0].Clone()
                $n.manifest = "$sub/package.json"
                $n.product = @("$sub/src")
                $n.generated = @("$sub/package-lock.json")
                $n.prefix = $sub
                $found += $n
                break
            }
        }
    }
    return $found
}

function Get-BcfNodeScripts {
    param([Parameter(Mandatory)][string]$Root, [string]$Prefix = '')
    $pkg = if ($Prefix) { Join-Path $Root "$Prefix\package.json" } else { Join-Path $Root 'package.json' }
    if (-not (Test-Path $pkg)) { return $null }
    try { $j = Get-Content -Raw -LiteralPath $pkg | ConvertFrom-Json } catch { return $null }
    return $j.scripts
}

function Get-BcfGitState {
    param([Parameter(Mandatory)][string]$Root)
    $isGit = Test-Path (Join-Path $Root '.git')
    if (-not $isGit) {
        # worktree: .git — файл, а не каталог; обычный Test-Path это покрывает,
        # но репозиторий может быть и выше по дереву.
        $top = ''
        try { $top = (& git -C $Root rev-parse --show-toplevel 2>$null | Out-String).Trim() } catch { }
        $isGit = [bool]$top
    }
    if (-not $isGit) { return [pscustomobject]@{ IsGit = $false; Branch = ''; Dirty = @(); Worktree = $false } }

    $branch = ''
    try { $branch = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim() } catch { }
    $dirty = @()
    try {
        $dirty = @(& git -C $Root status --porcelain 2>$null |
                   ForEach-Object { ($_ -replace '^...', '').Trim() } | Where-Object { $_ })
    } catch { }
    $wt = $false
    try { $wt = [bool](& git -C $Root worktree list 2>$null) } catch { }
    $hooks = @()
    $hd = Join-Path $Root '.git\hooks'
    if (Test-Path $hd) {
        $hooks = @(Get-ChildItem $hd -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -ne '.sample' } | ForEach-Object { $_.Name })
    }
    return [pscustomobject]@{ IsGit = $true; Branch = $branch; Dirty = $dirty; Worktree = $wt; Hooks = $hooks }
}

function Get-BcfDocs {
    param([Parameter(Mandatory)][string]$Root)
    $out = @()
    foreach ($p in @('README.md', 'CLAUDE.md', 'AGENTS.md', 'docs/PRD.md', 'CONTRIBUTING.md')) {
        $f = Join-Path $Root ($p -replace '/', '\')
        if (Test-Path $f) {
            $lines = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue).Count
            $out += [pscustomobject]@{ Path = $p; Lines = $lines; Exists = $true }
        } else {
            $out += [pscustomobject]@{ Path = $p; Lines = 0; Exists = $false }
        }
    }
    $archDir = Join-Path $Root 'docs'
    $archCount = 0
    if (Test-Path $archDir) {
        $archCount = @(Get-ChildItem $archDir -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue).Count
    }
    return [pscustomobject]@{ Files = $out; DocsMdCount = $archCount }
}

# Живая проверка команды. Именно ЖИВАЯ: «скрипт typecheck прописан в package.json» и
# «typecheck отрабатывает» — разные утверждения, и харнесс ломает второе, а не первое.
function Test-BcfCommand {
    param([Parameter(Mandatory)][string]$Command, [string]$Root = '', [int]$TimeoutSec = 120)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = ''
    $code = -1
    try {
        $job = Start-Job -ScriptBlock {
            param($c, $r)
            if ($r) { Set-Location $r }
            $o = (& pwsh -NoProfile -NonInteractive -Command $c 2>&1 | Out-String)
            [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE }
        } -ArgumentList $Command, $Root
        if (Wait-Job $job -Timeout $TimeoutSec) {
            $r = Receive-Job $job
            $out = [string]$r.Out
            $code = [int]$r.Code
        } else {
            Stop-Job $job -ErrorAction SilentlyContinue
            $out = "(не уложилась в ${TimeoutSec}с)"
            $code = 124
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        $out = $_.Exception.Message
        $code = -1
    }
    $sw.Stop()
    return [pscustomobject]@{
        Command = $Command; ExitCode = $code; Ok = ($code -eq 0)
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Output  = (($out -split "`r?`n") | Select-Object -Last 6) -join "`n"
    }
}

# Сводный разбор. -Probe включает живой запуск кандидатов в backpressure: он занимает
# секунды и десятки секунд, зато отличает «команда есть» от «команда работает».
function Invoke-BcfDetect {
    param([Parameter(Mandatory)][string]$Root, [switch]$Probe)

    $langs = Get-BcfLanguageStats -Root $Root
    $eco   = Get-BcfEcosystems -Root $Root
    $git   = Get-BcfGitState -Root $Root
    $docs  = Get-BcfDocs -Root $Root

    $product = @()
    $generated = @()
    $typechecks = @()
    $tests = @{ runner = '' }

    foreach ($e in $eco) {
        foreach ($p in $e.product) { if (Test-Path (Join-Path $Root ($p -replace '/', '\'))) { $product += $p } }
        $generated += @($e.generated | Where-Object { Test-Path (Join-Path $Root ($_ -replace '/', '\')) })
        if ($e.typecheck) { $typechecks += $e.typecheck }
        if ($e.tests.runner -and -not $tests.runner) { $tests = @{ runner = $e.tests.runner } }
    }

    # Node: команда быстрой проверки существует, только если в package.json есть скрипт.
    # Придумывать её самим — прямой путь к вечно красному гейту.
    foreach ($e in ($eco | Where-Object { $_.key -eq 'node' })) {
        $prefix = if ($e.ContainsKey('prefix')) { [string]$e.prefix } else { '' }
        $scripts = Get-BcfNodeScripts -Root $Root -Prefix $prefix
        $pfx = if ($prefix) { "npm --prefix $prefix" } else { 'npm' }
        $name = @('typecheck', 'type-check', 'tsc', 'check') | Where-Object { $scripts -and $scripts.PSObject.Properties[$_] } | Select-Object -First 1
        if ($name) { $typechecks += "$pfx run $name --silent" }
        $tname = @('test', 'test:unit') | Where-Object { $scripts -and $scripts.PSObject.Properties[$_] } | Select-Object -First 1
        if ($tname -and -not $tests.runner) {
            $raw = [string]$scripts.$tname
            $tests = @{ runner = $(if ($raw -match 'vitest') { 'vitest' } elseif ($raw -match 'jest') { 'jest' } else { '' }) }
        }
    }

    $probes = @()
    if ($Probe) {
        foreach ($c in ($typechecks | Select-Object -Unique)) { $probes += (Test-BcfCommand -Command $c -Root $Root) }
    }

    return [pscustomobject]@{
        Root        = $Root
        Languages   = $langs
        Ecosystems  = @($eco | ForEach-Object { $_.key })
        Git         = $git
        Docs        = $docs
        ProductPaths= @($product | Select-Object -Unique)
        Generated   = @($generated | Select-Object -Unique)
        Typechecks  = @($typechecks | Select-Object -Unique)
        Tests       = $tests
        Probes      = $probes
    }
}
