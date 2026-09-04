# require-tests.ps1 — гейт «фича доказана тестами, а не тем, что проект собрался».
#
# ЗАЧЕМ. Наблюдение 2026-07-26: три задачи подряд получили verdict: PASS, хотя в коде не
# появилось НИ СТРОЧКИ по их теме. Так вышло потому, что обязательные проверки были
# общими — «прогнать весь набор тестов» плюс линтер. Они зелёные и на пустом месте:
# сборка проходит, старые тесты проходят, новых нет.
#
# Второй слой проблемы — тихий ноль. У большинства раннеров запуск по фильтру, которому
# ничего не соответствует, завершается кодом 0 («0 tests»): `cargo test несуществующий`,
# `pytest -k несуществующий`, `go test -run НетТакого`. То есть проверка «прогони тест
# фичи» сама по себе НЕ ловит отсутствие фичи. Ловит только требование МИНИМАЛЬНОГО
# ЧИСЛА реально прошедших тестов — им этот скрипт и занят.
#
# Раннер и разбор его вывода берутся из config/harness.json → tests. Ничего
# специфичного для языка в самом скрипте нет:
#
#   "tests": {
#     "runner": "cargo",                       // cargo|vitest|jest|pytest|go|maven|custom
#     "command": "cargo test {package} {filter} -- --nocapture",
#     "packageFlag": "-p {package}",
#     "passedPattern": "test result: ok\\.\\s+(\\d+) passed",
#     "failedPattern": "(\\d+) failed"
#   }
#
# ДВА СПОСОБА СЧЁТА, И ВТОРОЙ ПОЯВИЛСЯ НЕ ОТ ХОРОШЕЙ ЖИЗНИ. Регулярное выражение по
# stdout умеет ровно одно: сложить группу 1 по всем совпадениям. Вывод Maven Surefire
# так считать нельзя. «Tests run: N» — это ЗАПУЩЕННЫЕ тесты, прошедшие = N минус
# Failures, Errors и Skipped, а вычитать движок не умеет. Та же строка печатается и на
# каждый тестовый класс, и ещё раз в итоговом блоке, поэтому сложение даёт двойной счёт.
# Оба перекоса тянут в одну сторону — завышают число прошедших, то есть красят гейт
# зелёным на пустом месте. Поэтому у пресета есть второй режим: reportFormat
# = "junit-xml" и reportGlob — читаем отчёты JUnit XML и считаем
# passed = tests − failures − errors − skipped.
#
# Отчёты берутся ТОЛЬКО свежее момента запуска. Surefire не чистит target/surefire-reports
# сам: без фильтра по времени гейт посчитал бы прошлый полный прогон и выдал бы PASS
# задаче, которая не запустила ни одного теста.
#
# Использование (в config/checks.json как обязательная проверка задачи):
#   pwsh harness/require-tests.ps1 -Filter session:: -Min 3
#   pwsh harness/require-tests.ps1 -Filter filters   -Min 4 -Package core
#
# Exit: 0 — прошло не меньше -Min тестов; 1 — меньше (или тесты упали); 2 — раннер
# не настроен (это дефект конфигурации, а не провал фичи, и вердикт им красить нечестно).

param(
    [Parameter(Mandatory)][string]$Filter,
    [int]$Min = 1,
    [string]$Package = '',
    [string]$ProjectRoot = ''         # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot
Set-Location $root

# --- Пресеты раннеров ---------------------------------------------------------------
#
# Пресет — ровно три вещи: как позвать, как посчитать прошедшие, как посчитать упавшие.
# Проект, который не попадает ни в один, задаёт их вручную (runner: custom).
$PRESETS = @{
    cargo  = @{ command = 'cargo test {package} {filter} -- --nocapture'
                packageFlag = '-p {package}'
                passedPattern = 'test result: ok\.\s+(\d+) passed'
                failedPattern = '(\d+) failed' }
    vitest = @{ command = 'npx --no-install vitest run {filter} --reporter=basic'
                packageFlag = ''
                passedPattern = 'Tests\s+(\d+) passed'
                failedPattern = 'Tests[^\r\n]*?(\d+) failed' }
    jest   = @{ command = 'npx --no-install jest {filter} --ci'
                packageFlag = ''
                passedPattern = 'Tests:[^\r\n]*?(\d+) passed'
                failedPattern = 'Tests:[^\r\n]*?(\d+) failed' }
    pytest = @{ command = 'python -m pytest -k "{filter}" -q'
                packageFlag = ''
                passedPattern = '(\d+) passed'
                failedPattern = '(\d+) failed' }
    go     = @{ command = 'go test {package} -run {filter} -v'
                packageFlag = '{package}'
                passedPattern = '(?m)^--- PASS'
                failedPattern = '(?m)^--- FAIL'
                countByMatch  = $true }
    # Maven, юнит-тесты на surefire. Флага -Dsurefire.failIfNoSpecifiedTests=false здесь
    # НЕТ, и это не упущение. Проверено живьём 2026-09-02 на clinic-scheduler-core
    # (surefire 3.5.6): без него `-Dtest=НетТакого` даёт BUILD FAILURE «No tests matching
    # pattern … were executed!» и код 1, то есть Maven сам ловит пустой фильтр. С этим
    # флагом появляется тот самый тихий ноль, ради которого весь скрипт и написан.
    # -q ставить нельзя даже ради тишины: он гасит вывод, по которому потом различают
    # класс провала. -ntp убирает только шкалу закачки.
    maven  = @{ command = '.\mvnw.cmd -B -ntp test {package} -Dtest="{filter}"'
                packageFlag = '-pl {package} -am'
                reportFormat = 'junit-xml'
                reportGlob = @('target/surefire-reports/TEST-*.xml') }
    # Интеграционные тесты (Testcontainers) у Spring Boot висят на failsafe: имена *IT,
    # фаза verify, свой каталог отчётов. Одним пресетом с surefire их не покрыть.
    'maven-it' = @{ command = '.\mvnw.cmd -B -ntp verify {package} -Dit.test="{filter}"'
                packageFlag = '-pl {package} -am'
                reportFormat = 'junit-xml'
                reportGlob = @('target/failsafe-reports/TEST-*.xml') }
}

$cfg = $null
$cfgFile = Join-Path $root 'config\harness.json'
if (Test-Path $cfgFile) {
    try { $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json } catch { }
}

$tcfg   = if ($cfg -and $cfg.tests) { $cfg.tests } else { $null }
$runner = if ($tcfg -and $tcfg.runner) { [string]$tcfg.runner } else { '' }

if (-not $runner) {
    Write-Host "require-tests: раннер тестов не настроен (config/harness.json → tests.runner)." -ForegroundColor Yellow
    Write-Host "Пока он не задан, гейт «фича доказана тестами» не работает: задача может получить PASS без единого нового теста." -ForegroundColor Yellow
    exit 2
}

$preset = if ($PRESETS.ContainsKey($runner)) { $PRESETS[$runner] } else { @{} }
function _pick([string]$key, $fallback) {
    if ($tcfg -and $tcfg.PSObject.Properties[$key] -and $tcfg.$key) { return $tcfg.$key }
    if ($preset.ContainsKey($key)) { return $preset[$key] }
    return $fallback
}

$cmdTpl        = [string](_pick 'command' '')
$packageTpl    = [string](_pick 'packageFlag' '')
$passedPattern = [string](_pick 'passedPattern' '')
$failedPattern = [string](_pick 'failedPattern' '')
$countByMatch  = [bool](_pick 'countByMatch' $false)
$reportFormat  = [string](_pick 'reportFormat' '')
$reportGlobs   = @(_pick 'reportGlob' @())

if (-not $cmdTpl -or (-not $passedPattern -and -not $reportFormat)) {
    Write-Host "require-tests: для раннера '$runner' нет команды или способа счёта — задай tests.command и либо tests.passedPattern, либо tests.reportFormat + tests.reportGlob в config/harness.json." -ForegroundColor Red
    Write-Host "Готовые пресеты: $(($PRESETS.Keys | Sort-Object) -join ', ')." -ForegroundColor Yellow
    exit 2
}

$pkgPart = if ($Package -and $packageTpl) { $packageTpl -replace '\{package\}', $Package } else { '' }
$cmd = $cmdTpl -replace '\{package\}', $pkgPart -replace '\{filter\}', $Filter
$cmd = ($cmd -replace '\s+', ' ').Trim()

# Обёртка Maven на Windows зовётся mvnw.cmd, и её может не быть в проекте вовсе. Молча
# упасть на «команда не найдена» здесь нельзя: это выглядит как красный гейт, а на деле
# гейту нечем выполниться — другой класс провала и другой ремонт.
if ($cmd -match '^\.\\mvnw\.cmd\b' -and -not (Test-Path (Join-Path $root 'mvnw.cmd'))) {
    $cmd = $cmd -replace '^\.\\mvnw\.cmd', 'mvn'
    Write-Host "require-tests: обёртки mvnw.cmd в корне нет — зову mvn из PATH." -ForegroundColor Yellow
}

Write-Host "require-tests: $cmd"
# Момент запуска нужен для отбора свежих отчётов. Две секунды назад — запас на
# разрешение времени файловой системы, не больше.
$since = (Get-Date).AddSeconds(-2)
$out  = (& pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String)
$code = $LASTEXITCODE

# Складываем ВСЕ совпадения: у cargo/go каждый тестовый бинарь печатает свой итог,
# и взять только первый — значит недосчитать.
function _count([string]$pattern) {
    if (-not $pattern) { return 0 }
    $n = 0
    foreach ($m in [regex]::Matches($out, $pattern)) {
        if ($countByMatch -or $m.Groups.Count -lt 2 -or -not $m.Groups[1].Success) { $n++ }
        else { $n += [int]$m.Groups[1].Value }
    }
    return $n
}

# Счёт по отчётам JUnit XML. Складываются ВСЕ файлы: Maven кладёт по одному на тестовый
# класс, и «взять первый» показало бы один класс из сотни.
function _CountReports([string[]]$Globs, [datetime]$Since) {
    $r = [pscustomobject]@{ Total = 0; Failures = 0; Errors = 0; Skipped = 0; Files = 0; Stale = 0 }
    foreach ($g in @($Globs | Where-Object { $_ })) {
        $rel     = ([string]$g) -replace '/', '\'
        $dirPart = Split-Path $rel -Parent
        $mask    = Split-Path $rel -Leaf
        $atRoot  = Join-Path $root $dirPart
        # Многомодульный проект держит свой target в каждом модуле, и каталога отчётов в
        # корне у него нет вовсе. Тогда ищем каталог по имени — иначе гейт увидел бы ноль
        # отчётов на полностью зелёном прогоне.
        $dirs = if (Test-Path $atRoot) { @($atRoot) } else {
            @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter (Split-Path $dirPart -Leaf) -ErrorAction SilentlyContinue |
              ForEach-Object { $_.FullName })
        }
        foreach ($f in (@($dirs) | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter $mask -File -ErrorAction SilentlyContinue })) {
            if ($f.LastWriteTime -lt $Since) { $r.Stale++; continue }
            $x = $null
            try { $x = [xml](Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop) } catch { continue }
            $suites = @()
            if ($x.testsuite)  { $suites += @($x.testsuite) }
            if ($x.testsuites) { $suites += @($x.testsuites.testsuite) }
            foreach ($s in @($suites | Where-Object { $_ })) {
                $r.Files++
                if ($s.tests)    { $r.Total    += [int]$s.tests }
                if ($s.failures) { $r.Failures += [int]$s.failures }
                if ($s.errors)   { $r.Errors   += [int]$s.errors }
                if ($s.skipped)  { $r.Skipped  += [int]$s.skipped }
            }
        }
    }
    return $r
}

$rep = $null
if ($reportFormat -eq 'junit-xml') {
    $rep = _CountReports $reportGlobs $since
    $passed = $rep.Total - $rep.Failures - $rep.Errors - $rep.Skipped
    $failed = $rep.Failures + $rep.Errors
} else {
    $passed = _count $passedPattern
    $failed = _count $failedPattern
}

Write-Host "require-tests: фильтр «$Filter» → прошло $passed, упало $failed (нужно минимум $Min)"
if ($rep) {
    Write-Host "require-tests: отчётов свежих $($rep.Files), пропущено устаревших $($rep.Stale); всего $($rep.Total), упало $($rep.Failures), ошибок $($rep.Errors), пропущено $($rep.Skipped)"
}

# ТЕСТЫ НЕ ЗАПУСКАЛИСЬ — ЭТО НЕ «ТЕСТЫ ПАДАЮТ». У Maven ненулевой код приходит от ошибки
# компиляции, от недоступной зависимости, от неподнятого Docker и от пустого фильтра.
# Назвав всё это «тесты по фильтру падают», гейт отправляет агента чинить не то.
if ($rep -and $rep.Files -eq 0) {
    $why = if ($out -match 'No tests matching pattern|No tests were executed') {
        "фильтр «$Filter» не нашёл ни одного теста: теста с таким именем нет — фича не написана либо класс называется иначе."
    } elseif ($out -match 'BUILD FAILURE|COMPILATION ERROR|BUILD ERROR') {
        'сборка упала ДО фазы тестов (компиляция, зависимости или инфраструктура). Тесты не запускались, о фиче это не говорит ничего.'
    } else {
        'фаза тестов не оставила ни одного свежего отчёта.'
    }
    Write-Host "ПРОВАЛ: $why" -ForegroundColor Red
    if ($rep.Stale -gt 0) {
        Write-Host "Отчётов от прошлых прогонов было $($rep.Stale) — они НЕ засчитаны: иначе гейт зеленел бы на чужой работе." -ForegroundColor Yellow
    }
    Write-Host ($out -split "`r?`n" | Select-Object -Last 25 | Out-String)
    exit 1
}

if ($code -ne 0 -or $failed -gt 0) {
    Write-Host "ПРОВАЛ: тесты по фильтру «$Filter» падают." -ForegroundColor Red
    Write-Host ($out -split "`r?`n" | Select-Object -Last 25 | Out-String)
    exit 1
}
if ($passed -lt $Min) {
    Write-Host "ПРОВАЛ: по фильтру «$Filter» прошло $passed тестов, требуется минимум $Min." -ForegroundColor Red
    Write-Host "Это значит, что фича не покрыта тестами — «проект собирается» доказательством не является." -ForegroundColor Red
    exit 1
}
Write-Host "OK: фича доказана $passed тестами." -ForegroundColor Green
exit 0
