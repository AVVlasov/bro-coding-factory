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
#     "runner": "cargo",                       // cargo|vitest|jest|pytest|go|custom
#     "command": "cargo test {package} {filter} -- --nocapture",
#     "packageFlag": "-p {package}",
#     "passedPattern": "test result: ok\\.\\s+(\\d+) passed",
#     "failedPattern": "(\\d+) failed"
#   }
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

if (-not $cmdTpl -or -not $passedPattern) {
    Write-Host "require-tests: для раннера '$runner' нет команды или шаблона разбора — задай tests.command и tests.passedPattern в config/harness.json." -ForegroundColor Red
    exit 2
}

$pkgPart = if ($Package -and $packageTpl) { $packageTpl -replace '\{package\}', $Package } else { '' }
$cmd = $cmdTpl -replace '\{package\}', $pkgPart -replace '\{filter\}', $Filter
$cmd = ($cmd -replace '\s+', ' ').Trim()

Write-Host "require-tests: $cmd"
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

$passed = _count $passedPattern
$failed = _count $failedPattern

Write-Host "require-tests: фильтр «$Filter» → прошло $passed, упало $failed (нужно минимум $Min)"

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
