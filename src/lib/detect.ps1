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

    # ХАРНЕСС — НЕ ПРОДУКТ. Считая его вместе с проектом, разбор врёт о том, на чём проект
    # написан: у Rust-проекта с обвязкой на PowerShell первым языком выходил PowerShell
    # (43% против 22% у Rust), и по этому чтению дальше выбирались продуктовые пути и
    # раннер тестов. Список каталогов печатается на экране — чтобы человек мог возразить.
    $harness = '(^|[\\/])(loop|harness|\.claude|meta|tasks|docs|memory)([\\/]|$)'

    $counts = @{}
    $total = 0
    $harnessFiles = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        if ($rel -match $skip) { continue }
        if ($rel -match $harness) { $harnessFiles++; continue }
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
    return [pscustomobject]@{ Total = $total; Languages = $out; HarnessFiles = $harnessFiles }
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
    # Maven. Продуктовые пути названы точно, а не одним 'src': в раскладке Maven под src
    # лежат и тесты (src/test/java), и правка теста засчиталась бы продуктовым прогрессом.
    # typecheck взят test-compile, а не compile: фаза compile пропускает src/test/java,
    # и сломанный тестовый исходник доехал бы до верификации, потратив целый круг.
    # target — вывод сборки: он обязан быть в generated, иначе грязный target заблокирует
    # слияние ровно так же, как однажды заблокировал лок-файл.
    @{ key = 'maven';  manifest = 'pom.xml'
       product = @('src/main/java', 'src/main/resources'); typecheck = '.\mvnw.cmd -B -q -DskipTests test-compile'
       tests = @{ runner = 'maven' }; generated = @('target') }
)

# Члены cargo-воркспейса. Разбирать их обязательно: в воркспейсе крейт может лежать где
# угодно, и захардкоженные 'src'/'crates' его не найдут. Пропущенный продуктовый каталог
# означает, что итерация, правившая ТОЛЬКО его, будет засчитана как «прогресса нет».
function Get-BcfCargoMembers {
    param([Parameter(Mandatory)][string]$Root)

    $manifest = Join-Path $Root 'Cargo.toml'
    if (-not (Test-Path $manifest)) { return @() }
    $raw = Get-Content -Raw -LiteralPath $manifest -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }

    $m = [regex]::Match($raw, '(?ms)^\[workspace\](.*?)(?=^\[|\z)')
    if (-not $m.Success) { return @() }
    $mm = [regex]::Match($m.Groups[1].Value, '(?ms)members\s*=\s*\[(.*?)\]')
    if (-not $mm.Success) { return @() }

    $out = @()
    foreach ($q in [regex]::Matches($mm.Groups[1].Value, '"([^"]+)"')) {
        $path = $q.Groups[1].Value.Trim()
        if (-not $path -or $path -match '[*?]') { continue }   # глобы не разворачиваем
        $src = Join-Path $Root (($path + '/src') -replace '/', '\')
        if (Test-Path $src) { $out += "$path/src" }
    }
    return @($out | Select-Object -Unique)
}

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
                # @() обязательна. Where-Object на одном совпадении отдаёт САМ объект, и
                # [0] на хеш-таблице — это не «первый элемент», а поиск по ключу 0: он
                # даёт $null, и .Clone() падает. Ломалось только на монорепах, то есть
                # ровно там, где эта ветка и нужна.
                $n = @($script:BcfEcosystems | Where-Object { $_.key -eq 'node' })[0].Clone()
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

# Сколько тестов НА САМОМ ДЕЛЕ. «Раннер найден» и «тесты есть» — разные утверждения, и
# гейт «фича доказана тестами» держится на втором. Пустой набор при живом раннере означает,
# что первая же задача закроется, ничего не доказав, — и это надо видеть до прогона.
function Get-BcfTestCounts {
    param([Parameter(Mandatory)][string]$Root, [string[]]$ProductPaths = @())

    # ExtraDirs — каталоги вне продуктовых путей, где раннер держит свои тесты. У cargo,
    # vitest, pytest и go тесты лежат рядом с кодом, а Maven уносит их в src/test/java,
    # который в productPaths не входит намеренно. Без этой добавки полный набор JUnit 5
    # был бы посчитан как ноль, и владелец решил бы, что тестов нет.
    $pats = @(
        @{ Runner = 'cargo';  Ext = @('.rs');            Rx = '#\[(tokio::)?test\]' }
        @{ Runner = 'vitest'; Ext = @('.ts', '.tsx', '.js', '.jsx'); Rx = '(?m)^\s*(it|test)\s*\(' }
        @{ Runner = 'pytest'; Ext = @('.py');            Rx = '(?m)^\s*def\s+test_' }
        @{ Runner = 'go';     Ext = @('.go');            Rx = '(?m)^func\s+Test\w+\(' }
        @{ Runner = 'maven';  Ext = @('.java');          Rx = '(?m)^\s*@(Test|ParameterizedTest|RepeatedTest)\b'
           ExtraDirs = @('src/test/java', 'src/it/java') }
    )
    $dirs = @($ProductPaths | ForEach-Object { Join-Path $Root ($_ -replace '/', '\') } | Where-Object { Test-Path $_ })
    if (-not $dirs.Count) { $dirs = @($Root) }

    $out = @{}
    foreach ($p in $pats) {
        $n = 0
        $scan = @($dirs)
        if ($p.ContainsKey('ExtraDirs')) {
            $scan += @($p.ExtraDirs | ForEach-Object { Join-Path $Root ($_ -replace '/', '\') } | Where-Object { Test-Path $_ })
        }
        foreach ($dir in @($scan | Select-Object -Unique)) {
            foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                            Where-Object { $p.Ext -contains $_.Extension.ToLower() })) {
                try { $n += ([regex]::Matches((Get-Content -Raw -LiteralPath $f.FullName -EA SilentlyContinue), $p.Rx)).Count } catch { }
            }
        }
        if ($n -gt 0) { $out[$p.Runner] = $n }
    }
    return $out
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

function _BcfDropNested {
    param([string[]]$Paths)
    $norm = @($Paths | ForEach-Object { ($_ -replace '\\', '/').Trim('/') } | Where-Object { $_ } | Select-Object -Unique)
    return @($norm | Where-Object {
        $me = $_
        -not ($norm | Where-Object { $_ -ne $me -and $me.StartsWith("$_/") })
    })
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
    # Раннеров может быть НЕСКОЛЬКО, и молча брать первый нельзя: в полиглот-репозитории
    # это значит, что половина задач доказывается чужим раннером. Собираем все, а решение
    # «какой основной» принимает вызывающий — уже зная, что их больше одного.
    $runners = @()

    foreach ($e in $eco) {
        foreach ($p in $e.product) { if (Test-Path (Join-Path $Root ($p -replace '/', '\'))) { $product += $p } }
        $generated += @($e.generated | Where-Object { Test-Path (Join-Path $Root ($_ -replace '/', '\')) })
        if ($e.typecheck) { $typechecks += $e.typecheck }
        if ($e.tests.runner) { $runners += [pscustomobject]@{ Runner = $e.tests.runner; Scope = '' } }
    }

    # Крейты воркспейса вне 'src'/'crates' — например app/src-tauri в Tauri-проекте.
    $product += @(Get-BcfCargoMembers -Root $Root)

    # Обёртка Maven на Windows зовётся mvnw.cmd, и форма ./mvnw в PowerShell не разрешится.
    # Обёртки может не быть вовсе — тогда предложенная команда не существует, а гейт на
    # несуществующей команде красный всегда, и агент чинит несуществующее. Падаем на mvn.
    if (@($eco | Where-Object { $_.key -eq 'maven' }).Count -and -not (Test-Path (Join-Path $Root 'mvnw.cmd'))) {
        $typechecks = @($typechecks | ForEach-Object { $_ -replace '^\.\\mvnw\.cmd', 'mvn' })
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
        if ($tname) {
            $raw = [string]$scripts.$tname
            $r = if ($raw -match 'vitest') { 'vitest' } elseif ($raw -match 'jest') { 'jest' } else { '' }
            if ($r) { $runners += [pscustomobject]@{ Runner = $r; Scope = $(if ($prefix) { "$prefix/" } else { '' }) } }
        }
    }

    $runners = @($runners | Sort-Object Runner -Unique)
    $tests = @{ runner = $(if ($runners.Count) { $runners[0].Runner } else { '' }) }

    $probes = @()
    if ($Probe) {
        foreach ($c in ($typechecks | Select-Object -Unique)) { $probes += (Test-BcfCommand -Command $c -Root $Root) }

        # Пересобираем список воспроизводимых файлов ПОСЛЕ проб: пробный `cargo check` /
        # `npm run typecheck` сам создаёт лок-файл, которого до него не было. Если считать
        # список до проб, самый важный кандидат — тот, что породила сборка, — в него не
        # попадёт, и однажды завалит слияние ровно потому, что харнесс о нём не знает.
        $generated = @()
        foreach ($e in $eco) {
            $generated += @($e.generated | Where-Object { Test-Path (Join-Path $Root ($_ -replace '/', '\')) })
        }
    }

    return [pscustomobject]@{
        Root        = $Root
        Languages   = $langs
        Ecosystems  = @($eco | ForEach-Object { $_.key })
        Git         = $git
        Docs        = $docs
        # Вложенные пути выбрасываем: `crates` уже покрывает `crates/bgc-core/src`, а
        # список из шести строк вместо двух человек не проверяет — он его пролистывает.
        ProductPaths= @(_BcfDropNested @($product | Select-Object -Unique))
        Generated   = @($generated | Select-Object -Unique)
        Typechecks  = @($typechecks | Select-Object -Unique)
        Tests       = $tests
        TestCounts  = (Get-BcfTestCounts -Root $Root -ProductPaths @(_BcfDropNested @($product | Select-Object -Unique)))
        Runners     = @($runners)
        Probes      = $probes
    }
}
