# java-hooks.tests.ps1 — обвязка на Java-проекте: хуки и быстрая проверка цикла.
#
#   pwsh harness/tests/java-hooks.tests.ps1
#
# ЗАЧЕМ. Разбор фабрики на Maven-проекте показал класс дефекта, который зелёные гейты
# не ловят по устройству: гейт не молчит из-за ошибки, он молчит потому, что не знает
# расширения файла. done-gate строил список интересных файлов только из .ts и .py, и
# сессия, правившая один лишь *.java, выходила нулём, не проверив ничего. Быстрая
# проверка после итерации была захардкожена на npx tsc и для Java не выполнялась вовсе,
# хотя документация обещала, что вызывается массив из config/harness.json.
#
# Поэтому проверяем не «скрипт запускается», а ровно те три перехода, на которых гейт
# раньше отдавал зелёный: .java попадает в набор проверяемых файлов; changeset Liquibase
# без include в мастер-журнале блокируется; провал команды быстрой проверки доезжает до
# STATE.md, откуда его читает агент.
#
# Хуки — bash-скрипты; зовём их Git Bash (не WSL: на неинициализированном дистрибутиве
# он уходит в интерактивную настройку и вешает прогон).

$ErrorActionPreference = 'Continue'
# $OutputEncoding — это кодировка, которой PowerShell пишет в стандартный ВХОД внешней
# команды. [System.Text.Encoding]::UTF8 несёт с собой BOM, и хук, читающий со входа JSON,
# получал перед скобкой три невидимых байта: разбор падал, хук выходил нулём и молчал —
# то есть выглядел как «нарушений нет».
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$harnessDir  = Split-Path $PSScriptRoot -Parent
$repoRoot    = Split-Path $harnessDir -Parent
$doneGate    = Join-Path $repoRoot 'templates\claude\hooks\done-gate.sh'
$hooksCfgTpl = Join-Path $repoRoot 'templates\claude\hooks\hooks-config.json'
$loopFile    = Join-Path $harnessDir 'loop.ps1'
. (Join-Path $harnessDir 'lib\backpressure.ps1')

$script:Pass = 0; $script:Fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $name $(if ($detail) { "— $detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

function Get-GitBash {
    foreach ($c in @($env:BCF_BASH, 'C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}
$bash = Get-GitBash
if (-not $bash) {
    Write-Host 'Git Bash не найден — хуковые случаи прогнать нечем.' -ForegroundColor Red
    Write-Host 'Пропуск считался бы зелёным прогоном при непроверенных хуках, поэтому это ПРОВАЛ.' -ForegroundColor Red
    exit 1
}

$cleanup = @()
function New-JavaFixture {
    <#
      Maven-проект-пустышка: git-репозиторий (done-gate считает изменения через git),
      pom.xml, .claude/hooks/hooks-config.json из шаблона.
    #>
    param([hashtable]$CfgOverride = @{})
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-java-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $d '.claude\hooks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\main\java\app') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t; & git -C $d config user.name t
    '<project><modelVersion>4.0.0</modelVersion></project>' |
        Set-Content -LiteralPath (Join-Path $d 'pom.xml') -Encoding UTF8
    $cfg = Get-Content -Raw -LiteralPath $hooksCfgTpl | ConvertFrom-Json
    foreach ($k in $CfgOverride.Keys) {
        $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $CfgOverride[$k] -Force
    }
    ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $d '.claude\hooks\hooks-config.json') -Encoding UTF8
    return $d
}
function Set-FakeMvnw {
    # Обёртка Maven, которой можно задать код выхода: настоящий Maven в тесте поднимать
    # нельзя (минуты на скачивание дистрибутива), а ветку компиляции проверить надо.
    param([string]$Dir, [int]$ExitCode)
    $body = "#!/usr/bin/env bash`necho '[ERROR] /src/main/java/app/Api.java:[3,1] cannot find symbol'`nexit $ExitCode`n"
    [IO.File]::WriteAllText((Join-Path $Dir 'mvnw'), $body)
}
function Invoke-DoneGate {
    # Скрипт зовём из шаблона, а конфиг подсовываем фикстурный: по умолчанию хук читает
    # hooks-config.json рядом с собой, то есть шаблонный, где все проектные ключи пусты.
    param([string]$Dir)
    $prevDir = $env:CLAUDE_PROJECT_DIR
    $prevCfg = $env:BCF_HOOKS_CONFIG
    $env:CLAUDE_PROJECT_DIR = $Dir
    $env:BCF_HOOKS_CONFIG = (Join-Path $Dir '.claude\hooks\hooks-config.json')
    $out = & $bash ($doneGate -replace '\\', '/') 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($null -eq $prevDir) { Remove-Item env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevDir }
    if ($null -eq $prevCfg) { Remove-Item env:BCF_HOOKS_CONFIG   -ErrorAction SilentlyContinue } else { $env:BCF_HOOKS_CONFIG = $prevCfg }
    return @{ Code = $code; Out = $out }
}

# ---------------------------------------------------------------------------
Section "1. done-gate видит .java (java_targets), а не только .ts и .py"
# ---------------------------------------------------------------------------
# Наблюдаемый признак — проверка «в код внесли ссылку на ключ API». Она работает только
# по файлам, попавшим в набор relevant. Раньше .java туда не попадал, и сессия, которая
# внесла ключ в Java-константу, закрывалась нулём.
$d = New-JavaFixture; $cleanup += $d
Set-FakeMvnw -Dir $d -ExitCode 0
$apiFile = Join-Path $d 'src\main\java\app\Api.java'
"package app;`npublic class Api { }`n" | Set-Content -LiteralPath $apiFile -Encoding UTF8
& git -C $d add -A 2>&1 | Out-Null
& git -C $d commit -qm base 2>&1 | Out-Null
# Проверка смотрит на ДОБАВЛЕННЫЕ строки этой сессии, поэтому ключ вносится правкой
# уже существующего файла, а не созданием нового.
@'
package app;
public class Api {
    static final String KEY = System.getenv("OPENAI_API_KEY");
}
'@ | Set-Content -LiteralPath $apiFile -Encoding UTF8
$r = Invoke-DoneGate $d
Check "гейт заблокировал (exit 2), а не вышел нулём" ($r.Code -eq 2) "код=$($r.Code)"
Check "названа причина: ключ API внесён в код" ($r.Out -match 'API-key reference newly INTRODUCED')
Check "назван сам файл .java" ($r.Out -match 'Api\.java')

# ---------------------------------------------------------------------------
Section "2. done-gate компилирует Java, когда есть pom.xml"
# ---------------------------------------------------------------------------
# Ветка компиляции — то, ради чего гейт вообще нужен на Java: несобирающийся код иначе
# доезжает до верификации и сжигает круг целиком.
$d = New-JavaFixture; $cleanup += $d
Set-FakeMvnw -Dir $d -ExitCode 1
'package app; public class Ok { }' | Set-Content -LiteralPath (Join-Path $d 'src\main\java\app\Ok.java') -Encoding UTF8
$r = Invoke-DoneGate $d
Check "провал компиляции блокирует (exit 2)" ($r.Code -eq 2) "код=$($r.Code)"
Check "названа команда test-compile" ($r.Out -match 'test-compile failed')
Check "показана строка ошибки компилятора" ($r.Out -match 'cannot find symbol')

# Зеркальный случай: та же правка при успешной компиляции гейт не трогает.
$d = New-JavaFixture; $cleanup += $d
Set-FakeMvnw -Dir $d -ExitCode 0
'package app; public class Ok { }' | Set-Content -LiteralPath (Join-Path $d 'src\main\java\app\Ok.java') -Encoding UTF8
$r = Invoke-DoneGate $d
Check "зелёная компиляция гейт не блокирует" ($r.Code -eq 0) "код=$($r.Code), вывод=$($r.Out)"

# ---------------------------------------------------------------------------
Section "3. Liquibase: changeset без include в мастер-журнале не проходит"
# ---------------------------------------------------------------------------
# Незарегистрированный changeset не выполняется никогда. Все гейты при этом зелёные,
# а схема базы остаётся прежней — дефект виден только в проде.
function New-LiquibaseFixture {
    param([bool]$WithInclude, [string]$Style = 'include')
    $chDir = 'src/main/resources/db/changelog'
    $d = New-JavaFixture @{
        migration_dir        = $chDir
        migration_index_file = "$chDir/db.changelog-master.xml"
        migration_version_fn = ''
    }
    $chAbs = Join-Path $d ($chDir -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Join-Path $chAbs 'changes') | Out-Null
    $inc = ''
    if ($WithInclude) {
        $inc = if ($Style -eq 'includeAll') { '  <includeAll path="db/changelog/changes"/>' }
               else { '  <include file="db/changelog/changes/001_add_visit.xml"/>' }
    }
    "<databaseChangeLog>`n$inc`n</databaseChangeLog>" |
        Set-Content -LiteralPath (Join-Path $chAbs 'db.changelog-master.xml') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -qm base 2>&1 | Out-Null
    # Новый changeset появляется ПОСЛЕ базового коммита: проверка регистрации смотрит
    # только на неотслеживаемые файлы — на то, что добавила эта сессия.
    '<changeSet id="001" author="t"><createTable tableName="visit"/></changeSet>' |
        Set-Content -LiteralPath (Join-Path $chAbs 'changes\001_add_visit.xml') -Encoding UTF8
    return $d
}

$d = New-LiquibaseFixture -WithInclude $false; $cleanup += $d
$r = Invoke-DoneGate $d
Check "без include — блок (exit 2)" ($r.Code -eq 2) "код=$($r.Code)"
Check "сказано, что changeset не достижим из мастер-журнала" ($r.Out -match 'not reached from|includeAll')
Check "назван сам файл changeset" ($r.Out -match '001_add_visit\.xml')

$d = New-LiquibaseFixture -WithInclude $true; $cleanup += $d
$r = Invoke-DoneGate $d
Check "с include — проходит (exit 0)" ($r.Code -eq 0) "код=$($r.Code), вывод=$($r.Out)"

$d = New-LiquibaseFixture -WithInclude $true -Style 'includeAll'; $cleanup += $d
$r = Invoke-DoneGate $d
Check "includeAll на каталог тоже считается регистрацией" ($r.Code -eq 0) "код=$($r.Code), вывод=$($r.Out)"

# ---------------------------------------------------------------------------
Section "4. Быстрая проверка цикла: команды из конфига, а не из кода"
# ---------------------------------------------------------------------------
# Ключ backpressure.typecheck не читался циклом ни разу, хотя документация обещала вызов
# каждую итерацию. Проверяем разбор конфига и исполнение массива для любого стека.
$cfgTwo = @{ backpressure = @{ typecheck = @('pwsh -NoProfile -Command "exit 0"', 'pwsh -NoProfile -Command "Write-Output ''cannot find symbol''; exit 1"') } } |
          ConvertTo-Json -Depth 6 | ConvertFrom-Json
$cmds = Get-BcfBackpressureCommands -Config $cfgTwo
Check "из конфига прочитаны обе команды" ($cmds.Count -eq 2) "прочитано: $($cmds.Count)"

$res = Invoke-BcfBackpressure -Root $repoRoot -Commands $cmds
Check "исполнены обе команды" (@($res.Ran).Count -eq 2) "исполнено: $(@($res.Ran).Count)"
Check "провал ровно один" (@($res.Failures).Count -eq 1) "провалов: $(@($res.Failures).Count)"
Check "набор не считается чистым" (-not $res.Clean)
Check "назван код выхода упавшей команды" (@($res.Failures)[0].ExitCode -eq 1) "код=$(@($res.Failures)[0].ExitCode)"
Check "в отчёт попал хвост вывода" (@($res.Failures)[0].Tail -match 'cannot find symbol') "хвост=$(@($res.Failures)[0].Tail)"

# STATE.md — единственное место, где агент видит результат: он запускается подпроцессом
# и вывода гейтов не наблюдает. Провал обязан доехать именно туда.
$state = Format-BcfStateBlock -Iteration 7 -TaskId 'TASK-01' -Backpressure @(@($res.Failures) | ForEach-Object { $_.Message })
Check "в STATE есть раздел BACKPRESSURE" ($state -match 'BACKPRESSURE')
Check "в STATE названа упавшая команда" ($state -match 'exit 1')
Check "в STATE есть текст ошибки" ($state -match 'cannot find symbol')
$stateClean = Format-BcfStateBlock -Iteration 8 -TaskId 'TASK-01' -Backpressure @()
Check "чистая итерация не зовёт чинить" ($stateClean -notmatch 'исправь это первым шагом')

# Пустой массив: это «не проверялось», а не «чисто». Молчаливый ноль здесь и был дефектом.
$resEmpty = Invoke-BcfBackpressure -Root $repoRoot -Commands @()
Check "пустой массив = пропуск, а не чистый прогон" ($resEmpty.Skipped -and -not $resEmpty.Clean)
Check "у пропуска названа причина" ($resEmpty.Reason -match 'backpressure.typecheck')

# Проводка в цикле: гейт исполняет набор и кладёт провал в тот же $bp, который уходит
# в STATE.md. Прогнать loop.ps1 целиком тест не может — ему нужен живой кодовый агент.
$loopSrc = Get-Content -Raw -LiteralPath $loopFile
Check "loop.ps1 читает набор команд из конфига" ($loopSrc -match 'Get-BcfBackpressureCommands\s+-Config\s+\$Cfg')
Check "loop.ps1 исполняет набор каждую итерацию" ($loopSrc -match 'Invoke-BcfBackpressure\s+-Root\s+\$root')
Check "провал уходит в backpressure агента" ($loopSrc -match '\$bp \+= \$bpf\.Message')
Check "STATE.md собирается той же функцией" ($loopSrc -match 'Format-BcfStateBlock\s+-Iteration')
Check "захардкоженного вызова npx tsc в цикле не осталось" ($loopSrc -notmatch '&\s*npx --no-install tsc')

# ---------------------------------------------------------------------------
Section "5. lint-gate: пустой catch и часы в Java"
# ---------------------------------------------------------------------------
# Оба правила существовали и до Java, и оба на Java молчали: список расширений для
# пустого catch состоял из одного '.ts', а правило про часы искало тесты внутри
# productPaths — в раскладке Maven тесты лежат снаружи, в src/test/java, и маски
# *Test / *Tests / *IT не проверяли ни одного файла.
$lintGate = Join-Path $harnessDir 'lint-gate.ps1'
function New-LintFixture {
    param([hashtable]$CfgOverride = @{})
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-lint-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $d '.claude\hooks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\main\java\app') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\test\java\app') | Out-Null
    '<project><modelVersion>4.0.0</modelVersion></project>' |
        Set-Content -LiteralPath (Join-Path $d 'pom.xml') -Encoding UTF8
    # productPaths ровно такой, как рекомендует документация для Maven: тестов в нём нет.
    (@{ productPaths = @('src/main/java', 'src/main/resources') } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $d 'config\harness.json') -Encoding UTF8
    $cfg = Get-Content -Raw -LiteralPath $hooksCfgTpl | ConvertFrom-Json
    $cfg.time_dependent_tests = $true
    foreach ($k in $CfgOverride.Keys) {
        $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $CfgOverride[$k] -Force
    }
    ($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $d '.claude\hooks\hooks-config.json') -Encoding UTF8
    return $d
}
function Invoke-LintGate([string]$Dir) {
    $prev = $env:RALPH_GUARD_BYPASS
    $env:RALPH_GUARD_BYPASS = '1'
    $out = & pwsh -NoProfile -NonInteractive -File $lintGate -Repo $Dir -JsonOutput 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($null -eq $prev) { Remove-Item env:RALPH_GUARD_BYPASS -ErrorAction SilentlyContinue } else { $env:RALPH_GUARD_BYPASS = $prev }
    return @{ Code = $code; Out = $out }
}

$d = New-LintFixture; $cleanup += $d
@'
package app;
public class Svc {
    void run() {
        try { work(); } catch (IllegalStateException e) { }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $d 'src\main\java\app\Svc.java') -Encoding UTF8
@'
package app;
class VisitTest {
    void t() { var d = java.time.LocalDate.now(); }
}
'@ | Set-Content -LiteralPath (Join-Path $d 'src\test\java\app\VisitTest.java') -Encoding UTF8
@'
package app;
class BookingIT {
    void t() { var i = java.time.Instant.now(); }
}
'@ | Set-Content -LiteralPath (Join-Path $d 'src\test\java\app\BookingIT.java') -Encoding UTF8
@'
package app;
class PinnedTest {
    java.time.Clock c = java.time.Clock.fixed(java.time.Instant.EPOCH, java.time.ZoneOffset.UTC);
    void t() { var d = java.time.LocalDate.now(c); }
}
'@ | Set-Content -LiteralPath (Join-Path $d 'src\test\java\app\PinnedTest.java') -Encoding UTF8
$r = Invoke-LintGate $d
Check "гейт красный (exit 1)" ($r.Code -eq 1) "код=$($r.Code)"
Check "пустой catch в .java назван" (($r.Out -match 'no-bare-catch') -and ($r.Out -match 'Svc\.java')) "вывод=$($r.Out)"
Check "часы без пиновки в *Test.java названы" (($r.Out -match 'time-dependent-test') -and ($r.Out -match 'VisitTest\.java'))
Check "маска *IT.java тоже считается тестом" ($r.Out -match 'BookingIT\.java')
Check "Clock.fixed — это пиновка, а не нарушение" ($r.Out -notmatch 'PinnedTest\.java')

# ---------------------------------------------------------------------------
Section "6. journey-gate: без commandOne гейт отказывается, а не красит путь"
# ---------------------------------------------------------------------------
# Фолбэк поштучного прогона добавлял к общей команде флаг -t. Его понимают vitest и jest;
# Maven на нём падает разбором аргументов, и гейт объявлял «сквозной путь сломан» —
# проект шёл чинить продукт вместо конфига.
$journeyGate = Join-Path $harnessDir 'journey-gate.ps1'
$mvnLike = 'pwsh -NoProfile -Command "Write-Output ''operator-book''; exit 1"'
function New-JourneyFixture {
    param($Registry)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-jgj-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t; & git -C $d config user.name t
    ($Registry | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $d 'config\journeys.json') -Encoding UTF8
    'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
    return $d
}
function Invoke-JourneyGate {
    param([string]$Dir, [switch]$AsJson, [string]$Only = '')
    $psArgs = @('-NoProfile', '-NonInteractive', '-File', $journeyGate, '-ProjectRoot', $Dir)
    if ($AsJson) { $psArgs += '-Json' }
    if ($Only)   { $psArgs += @('-Only', $Only) }
    $out = & pwsh @psArgs 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

$d = New-JourneyFixture @{
    command  = $mvnLike
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
$r = Invoke-JourneyGate -Dir $d -AsJson
Check "гейт красный (exit 1)" ($r.Code -eq 1) "код=$($r.Code)"
Check "статус пути — no-command, а не red" ($r.Out -match 'no-command') "вывод=$($r.Out)"
Check "назван ключ, которого не хватает" ($r.Out -match 'commandOne')
Check "сказано, чей это флаг" ($r.Out -match 'vitest')

$r = Invoke-JourneyGate -Dir $d
Check "человекочитаемый отчёт тоже называет commandOne" ($r.Out -match 'commandOne') "вывод=$($r.Out)"

$r = Invoke-JourneyGate -Dir $d -Only 'operator-book'
Check "одиночный прогон отказывается, а не объявляет путь красным" (($r.Code -eq 1) -and ($r.Out -match 'commandOne')) "код=$($r.Code)"

$d = New-JourneyFixture @{
    command    = $mvnLike
    commandOne = 'pwsh -NoProfile -Command "Write-Output ''{id}''; exit 0"'
    journeys   = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
$r = Invoke-JourneyGate -Dir $d -AsJson
Check "с commandOne поштучная атрибуция делается" ($r.Out -match '"status"\s*:\s*"ok"') "вывод=$($r.Out)"
Check "отказа при заданном commandOne нет" ($r.Out -notmatch 'no-command')

# Зеркальный случай: у vitest флаг -t есть, и фолбэк остаётся законным.
$d = New-JourneyFixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book''; exit 1" # vitest run'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
$r = Invoke-JourneyGate -Dir $d -AsJson
Check "для vitest фолбэк не отменён" ($r.Out -notmatch 'no-command') "вывод=$($r.Out)"

# ---------------------------------------------------------------------------
Section "7. Хуки правки: Java-файл больше не проходит мимо"
# ---------------------------------------------------------------------------
function Invoke-Hook {
    param([string]$Script, [string]$Stdin = '', [string[]]$HookArgs = @(), [string]$WorkDir = '')
    $path = $Script -replace '\\', '/'
    $prevLoc = (Get-Location).Path
    if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
    try {
        if ($Stdin) { $out = ($Stdin | & $bash $path @HookArgs 2>&1 | Out-String) }
        else        { $out = (& $bash $path @HookArgs 2>&1 | Out-String) }
        $code = $LASTEXITCODE
    } finally { Set-Location -LiteralPath $prevLoc }
    return @{ Code = $code; Out = $out }
}

# 7a. post-write-check: правка .java раньше не разбиралась вовсе.
$d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-pwc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $d | Out-Null
$cleanup += $d
@'
package app;
public class Bad {
    void r() {
        System.out.println("x");
        try { work(); } catch (Exception e) { }
        try { work(); } catch (Exception e) { e.printStackTrace(); }
        String q = "SELECT * FROM visit WHERE id=" + id;
    }
}
'@ | Set-Content -LiteralPath (Join-Path $d 'Bad.java') -Encoding UTF8
'package app; public class Good { }' | Set-Content -LiteralPath (Join-Path $d 'Good.java') -Encoding UTF8
$pwcScript = Join-Path $repoRoot 'templates\claude\hooks\post-write-check.sh'
$payload = (@{ tool_name = 'Write'; tool_input = @{ file_path = ((Join-Path $d 'Bad.java') -replace '\\', '/') } } | ConvertTo-Json -Compress)
$r = Invoke-Hook -Script $pwcScript -Stdin $payload
Check "печать в stdout названа" ($r.Out -match 'System\.out\.print') "вывод=$($r.Out)"
Check "printStackTrace назван" ($r.Out -match 'printStackTrace')
Check "пустой catch назван" ($r.Out -match 'empty catch')
Check "склейка SQL строкой названа" ($r.Out -match 'SQL/JPQL')
$payload = (@{ tool_name = 'Write'; tool_input = @{ file_path = ((Join-Path $d 'Good.java') -replace '\\', '/') } } | ConvertTo-Json -Compress)
$r = Invoke-Hook -Script $pwcScript -Stdin $payload
Check "на чистом Java-файле хук молчит" ($r.Out.Trim() -eq '') "вывод=$($r.Out)"

# 7b. stop-verify: правка .java в рабочем дереве.
$d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-sv-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $d | Out-Null
$cleanup += $d
& git -C $d init -q -b main 2>&1 | Out-Null
& git -C $d config user.email t@t; & git -C $d config user.name t
'package app; public class Ok { }' | Set-Content -LiteralPath (Join-Path $d 'Ok.java') -Encoding UTF8
& git -C $d add -A 2>&1 | Out-Null
& git -C $d commit -qm base 2>&1 | Out-Null
$svScript = Join-Path $repoRoot 'templates\claude\hooks\stop-verify.sh'
$prevProj = $env:CLAUDE_PROJECT_DIR
$env:CLAUDE_PROJECT_DIR = $d
'package app; public class Ok { void r() { System.out.println("x"); } }' |
    Set-Content -LiteralPath (Join-Path $d 'Ok.java') -Encoding UTF8
$r = Invoke-Hook -Script $svScript
Check "stop-verify видит печать в stdout в изменённом .java" ($r.Out -match 'System\.out\.print') "вывод=$($r.Out)"
# Хук читал пути от git и грепал от текущего каталога, а счёт собирал конвейером,
# который под pipefail печатает два нуля: пользователь получал ошибки bash вместо замечаний.
Check "хук не сыплет ошибками bash" ($r.Out -notmatch 'integer expression expected|bad substitution|syntax error')
& git -C $d checkout -- . 2>&1 | Out-Null
$r = Invoke-Hook -Script $svScript
Check "на чистом дереве замечаний по Java нет" ($r.Out -notmatch 'Java files') "вывод=$($r.Out)"
if ($null -eq $prevProj) { Remove-Item env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevProj }

# 7c. mock-as-real-detector: продуктовые каталоги и расширения из конфига.
$d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-mock-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $d '.claude\hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\main\java\app') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\main\resources') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $d 'src\test\java\app') | Out-Null
$cleanup += $d
$cfg = Get-Content -Raw -LiteralPath $hooksCfgTpl | ConvertFrom-Json
$cfg.product_paths = @('src/main/java', 'src/main/resources')
($cfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $d '.claude\hooks\hooks-config.json') -Encoding UTF8
Copy-Item (Join-Path $repoRoot 'templates\claude\hooks\mock-as-real-detector.sh')    (Join-Path $d '.claude\hooks\')
Copy-Item (Join-Path $repoRoot 'templates\claude\hooks\non-target-script-detector.sh') (Join-Path $d '.claude\hooks\')
"package app;`nimport org.mockito.Mockito;`npublic class Svc { }`n" |
    Set-Content -LiteralPath (Join-Path $d 'src\main\java\app\Svc.java') -Encoding UTF8
"package app;`nimport org.mockito.Mockito;`nclass SvcTest { }`n" |
    Set-Content -LiteralPath (Join-Path $d 'src\test\java\app\SvcTest.java') -Encoding UTF8
$r = Invoke-Hook -Script (Join-Path $d '.claude\hooks\mock-as-real-detector.sh') -WorkDir $d
Check "мок в продуктовом Java-коде блокирует (exit 2)" ($r.Code -eq 2) "код=$($r.Code), вывод=$($r.Out)"
Check "назван продуктовый файл" ($r.Out -match 'Svc\.java')
Check "тестовое дерево под запрет не попадает" ($r.Out -notmatch 'SvcTest\.java')

# 7d. non-target-script-detector: ресурсы Java и экранирование \uXXXX.
# В .properties не-ASCII традиционно хранится как \uXXXX, то есть шестью ASCII-символами;
# без разэкранирования иероглиф проходит мимо регулярного выражения.
$propPath = Join-Path $d 'src\main\resources\messages.properties'
'greeting=Vot chto izmenilos s 昨晚' | Set-Content -LiteralPath $propPath -Encoding UTF8
$r = Invoke-Hook -Script (Join-Path $d '.claude\hooks\non-target-script-detector.sh') `
                 -HookArgs @(($propPath -replace '\\', '/')) -WorkDir $d
Check "иероглиф в .properties за экранированием пойман (exit 2)" ($r.Code -eq 2) "код=$($r.Code), вывод=$($r.Out)"
Check "назван сам файл ресурсов" ($r.Out -match 'messages\.properties')

# ---------------------------------------------------------------------------
Section "8. Шаблон и документация называют то, чего гейт теперь требует"
# ---------------------------------------------------------------------------
# Гейт, требующий ключ, которого нет ни в шаблоне, ни в документации, читается как
# поломка инструмента: проект видит отказ и не знает, где написать ответ.
$journeysTpl = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'templates\config\journeys.json')
Check "шаблон реестра сценариев знает про commandOne" ($journeysTpl -match 'commandOne')
$cfgDoc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs\CONFIG.md')
Check "CONFIG.md объясняет, когда commandOne обязателен" ($cfgDoc -match 'commandOne')
Check "CONFIG.md называет test_paths" ($cfgDoc -match 'test_paths')
$hooksTpl = Get-Content -Raw -LiteralPath $hooksCfgTpl
Check "шаблон hooks-config объявляет java_targets" ($hooksTpl -match 'java_targets')
Check "шаблон hooks-config объявляет test_paths" ($hooksTpl -match 'test_paths')

foreach ($p in $cleanup) { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Fail) { Write-Host "ИТОГ: $($script:Pass) прошло, $($script:Fail) провалено" -ForegroundColor Red; exit 1 }
Write-Host "ИТОГ: $($script:Pass) прошло, 0 провалено" -ForegroundColor Green
exit 0
