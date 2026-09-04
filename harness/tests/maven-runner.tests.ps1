# maven-runner.tests.ps1 — гейт «фича доказана тестами» на Maven.
#
#   pwsh harness/tests/maven-runner.tests.ps1
#
# ЗАЧЕМ ОТДЕЛЬНАЯ СЮИТА. У остальных раннеров число прошедших тестов читается из stdout
# одним регулярным выражением, и это работает. У Maven так нельзя: «Tests run: N» — это
# ЗАПУЩЕННЫЕ тесты, а прошедшие получаются вычитанием Failures, Errors и Skipped, да ещё
# и печатается эта строка дважды — на класс и в итоговом блоке. Оба перекоса завышают
# счёт, то есть красят гейт зелёным на пустом месте. Здесь проверяется второй режим
# счёта — по отчётам JUnit XML — и ровно те способы соврать, ради которых он заведён:
#
#   1. арифметика: прошедшие = tests − failures − errors − skipped, а не tests;
#   2. тихий ноль: команда вернула 0, отчётов нет — это ПРОВАЛ, а не «тестов не нашлось»;
#   3. чужая работа: отчёты от прошлого прогона не засчитываются, Maven их не чистит;
#   4. атрибуция: пустой фильтр и упавшая сборка называются своими именами, а не
#      «тесты по фильтру падают» — иначе агент чинит не то.
#
# Maven здесь не запускается ни разу: командой раннера подставлен стенд, который пишет
# те же XML. Сюита обязана быть быстрой, иначе её перестанут гонять.

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$gate = Join-Path (Split-Path $PSScriptRoot -Parent) 'require-tests.ps1'

$script:Pass = 0; $script:Fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $name $(if ($detail) { "— $detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

$cleanup = @()

# Проект-пустышка: корень + config/harness.json с раннером maven. Команда подменяется,
# чтобы сюита не зависела от установленного Maven и от сети.
function New-Fixture {
    param([string]$Command = 'exit 0', [hashtable]$Extra = @{})
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-mvn-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    $tests = @{ runner = 'maven'; command = $Command }
    foreach ($k in $Extra.Keys) { $tests[$k] = $Extra[$k] }
    (@{ tests = $tests } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path $d 'config\harness.json') -Encoding UTF8
    $script:cleanup += $d
    return $d
}

# Отчёт surefire: корневой элемент testsuite с атрибутами счёта.
function New-Report {
    param([string]$Dir, [string]$Class, [int]$Tests, [int]$Failures = 0, [int]$Errors = 0, [int]$Skipped = 0,
          [datetime]$Written = [datetime]::MinValue)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $f = Join-Path $Dir "TEST-$Class.xml"
    @"
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="$Class" tests="$Tests" failures="$Failures" errors="$Errors" skipped="$Skipped" time="0.4">
</testsuite>
"@ | Set-Content -LiteralPath $f -Encoding UTF8
    if ($Written -ne [datetime]::MinValue) { (Get-Item -LiteralPath $f).LastWriteTime = $Written }
    return $f
}

function Invoke-Gate {
    param([string]$Dir, [string]$Filter, [int]$Min = 1)
    $out = & pwsh -NoProfile -NonInteractive -File $gate -Filter $Filter -Min $Min -ProjectRoot $Dir 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# ---------------------------------------------------------------------------
Section '1. Счёт идёт по отчётам, а прошедшие получаются вычитанием'
# ---------------------------------------------------------------------------
# Пять запущенных, из них один упал, один сломался, два пропущены. Прошедший ровно один.
# Регулярное выражение по «Tests run: 5» показало бы пять — и задача без работающей фичи
# получила бы PASS.
$d = New-Fixture
New-Report -Dir (Join-Path $d 'target\surefire-reports') -Class 'ru.clinic.ModularityTests' -Tests 5 -Failures 1 -Errors 1 -Skipped 2 | Out-Null
$r = Invoke-Gate -Dir $d -Filter 'ModularityTests' -Min 1
Check 'прошедшие посчитаны как 1, а не 5' ($r.Out -match 'прошло 1,') $r.Out
Check 'упавшие названы (1 упал + 1 ошибка = 2)' ($r.Out -match 'упало 2') $r.Out
Check 'вердикт ПРОВАЛ: в наборе есть красные' ($r.Code -eq 1) "код=$($r.Code)"

# ---------------------------------------------------------------------------
Section '2. Два зелёных класса складываются, а не берётся первый'
# ---------------------------------------------------------------------------
# Maven кладёт по XML на тестовый класс. Прежний код брал Select-Object -First 1 и показал
# бы один класс из сотни.
$d = New-Fixture
New-Report -Dir (Join-Path $d 'target\surefire-reports') -Class 'ru.clinic.AlphaTest' -Tests 2 | Out-Null
New-Report -Dir (Join-Path $d 'target\surefire-reports') -Class 'ru.clinic.BetaTest'  -Tests 3 | Out-Null
$r = Invoke-Gate -Dir $d -Filter 'Alpha*' -Min 5
Check 'сложены оба отчёта: прошло 5' ($r.Out -match 'прошло 5,') $r.Out
Check 'гейт зелёный' ($r.Code -eq 0) "код=$($r.Code); $($r.Out)"

# ---------------------------------------------------------------------------
Section '3. Тихий ноль: команда вернула 0, отчётов нет — это ПРОВАЛ'
# ---------------------------------------------------------------------------
# Ровно тот класс, ради которого написан весь скрипт: раннер отработал «успешно», а
# доказательства фичи не появилось ни одного.
$d = New-Fixture
$r = Invoke-Gate -Dir $d -Filter 'ModularityTests' -Min 1
Check 'exit 1, а не 0' ($r.Code -eq 1) "код=$($r.Code); $($r.Out)"
Check 'сказано, что отчётов не осталось' ($r.Out -match 'не оставила ни одного свежего отчёта|не нашёл ни одного теста') $r.Out
Check 'счёт прошедших равен нулю' ($r.Out -match 'прошло 0,') $r.Out

# ---------------------------------------------------------------------------
Section '4. Отчёты прошлого прогона не засчитываются'
# ---------------------------------------------------------------------------
# Surefire не чистит target/surefire-reports. Без фильтра по времени гейт посчитал бы
# вчерашний полный прогон и выдал бы PASS задаче, не запустившей ни одного теста.
$d = New-Fixture
New-Report -Dir (Join-Path $d 'target\surefire-reports') -Class 'ru.clinic.StaleTest' -Tests 7 -Written ((Get-Date).AddHours(-3)) | Out-Null
$r = Invoke-Gate -Dir $d -Filter 'ModularityTests' -Min 1
Check 'семь чужих тестов не превратились в PASS' ($r.Code -eq 1) "код=$($r.Code); $($r.Out)"
Check 'устаревшие отчёты названы вслух' ($r.Out -match 'устаревш') $r.Out
Check 'прошедших ноль' ($r.Out -match 'прошло 0,') $r.Out

# ---------------------------------------------------------------------------
Section '5. Пустой фильтр назван пустым фильтром, а не падением тестов'
# ---------------------------------------------------------------------------
# Maven при фильтре, которому ничего не соответствует, роняет сборку. Назвав это «тесты
# по фильтру падают», гейт отправил бы агента чинить работающий код.
$d = New-Fixture -Command "Write-Output 'No tests matching pattern NoSuchTest were executed!'; Write-Output 'BUILD FAILURE'; exit 1"
$r = Invoke-Gate -Dir $d -Filter 'NoSuchTest' -Min 1
Check 'exit 1' ($r.Code -eq 1) "код=$($r.Code)"
Check 'причина названа: теста с таким именем нет' ($r.Out -match 'не нашёл ни одного теста') $r.Out
Check 'не назван падением тестов' ($r.Out -notmatch 'тесты по фильтру «NoSuchTest» падают') $r.Out

# ---------------------------------------------------------------------------
Section '6. Сборка упала до фазы тестов — это другой класс провала'
# ---------------------------------------------------------------------------
$d = New-Fixture -Command "Write-Output 'COMPILATION ERROR'; Write-Output 'BUILD FAILURE'; exit 1"
$r = Invoke-Gate -Dir $d -Filter 'ModularityTests' -Min 1
Check 'exit 1' ($r.Code -eq 1) "код=$($r.Code)"
Check 'сказано, что тесты не запускались' ($r.Out -match 'до фазы тестов') $r.Out

# ---------------------------------------------------------------------------
Section '7. Отчёты многомодульного проекта находятся не только в корне'
# ---------------------------------------------------------------------------
# У многомодульной сборки target лежит в каждом модуле, а в корне каталога отчётов нет
# вовсе. Гейт, ищущий только корень, увидел бы ноль на полностью зелёном прогоне.
$d = New-Fixture
New-Report -Dir (Join-Path $d 'modules\core\target\surefire-reports') -Class 'ru.clinic.CoreTest' -Tests 4 | Out-Null
$r = Invoke-Gate -Dir $d -Filter 'CoreTest' -Min 4
Check 'найдены отчёты модуля' ($r.Out -match 'прошло 4,') $r.Out
Check 'гейт зелёный' ($r.Code -eq 0) "код=$($r.Code); $($r.Out)"

# ---------------------------------------------------------------------------
Section '8. Минимум по-прежнему работает'
# ---------------------------------------------------------------------------
$d = New-Fixture
New-Report -Dir (Join-Path $d 'target\surefire-reports') -Class 'ru.clinic.OneTest' -Tests 1 | Out-Null
$r = Invoke-Gate -Dir $d -Filter 'OneTest' -Min 3
Check 'одного теста мало, когда требуется три' ($r.Code -eq 1) "код=$($r.Code)"
Check 'сказано про непокрытую фичу' ($r.Out -match 'не покрыта тестами') $r.Out

# ---------------------------------------------------------------------------
Section '9. Команда пресета — та, что проверена живьём'
# ---------------------------------------------------------------------------
# Флаг -Dsurefire.failIfNoSpecifiedTests=false включает тихий ноль у самого Maven: пустой
# фильтр перестаёт быть провалом сборки. В пресете его быть не должно никогда.
$src = Get-Content -Raw -LiteralPath $gate
$mvnCmds = @([regex]::Matches($src, "(?m)^\s*'?maven(?:-it)?'?\s*=\s*@\{\s*command\s*=\s*'([^']*)'") |
             ForEach-Object { $_.Groups[1].Value })
Check 'пресетов maven два: юниты и интеграционные' ($mvnCmds.Count -eq 2) "нашёл $($mvnCmds.Count): $($mvnCmds -join ' | ')"
Check 'команда зовёт обёртку .\mvnw.cmd' ($mvnCmds[0] -like '.\mvnw.cmd -B -ntp test*') "команда: $($mvnCmds[0])"
Check 'флага failIfNoSpecifiedTests в командах нет' (-not @($mvnCmds | Where-Object { $_ -match 'failIfNoSpecifiedTests' }).Count) 'флаг тихого нуля вернулся в пресет'
Check 'счёт объявлен по junit-xml' ($src -match "reportFormat = 'junit-xml'") 'режим счёта по отчётам не объявлен'

foreach ($p in $cleanup) { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Fail) { Write-Host "ИТОГ: $($script:Pass) прошло, $($script:Fail) провалено" -ForegroundColor Red; exit 1 }
Write-Host "ИТОГ: $($script:Pass) прошло, 0 провалено" -ForegroundColor Green
exit 0
