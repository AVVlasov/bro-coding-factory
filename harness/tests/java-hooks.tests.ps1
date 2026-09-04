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
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

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

foreach ($p in $cleanup) { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Fail) { Write-Host "ИТОГ: $($script:Pass) прошло, $($script:Fail) провалено" -ForegroundColor Red; exit 1 }
Write-Host "ИТОГ: $($script:Pass) прошло, 0 провалено" -ForegroundColor Green
exit 0
