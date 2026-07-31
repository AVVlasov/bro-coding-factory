# cli.tests.ps1 — дымовые тесты CLI. Без сети и без единого вызова модели.
#
#   pwsh tests/cli.tests.ps1
#
# ЧТО ЭТИ ТЕСТЫ ЛОВЯТ И ПОЧЕМУ ИМЕННО ЭТО. Все проверки здесь — про класс дефектов
# «команда отработала и соврала»: разбор аргументов, который молча роняет флаг в чужой
# список; таблица, которая падает на пустых данных; отчёт, который называет сухой план
# результатом; установка, которая перезаписывает правки владельца. Ошибки компиляции
# ловит парсер, а вот эти — только запуск.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent
$bcf = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ✓ $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ✗ $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Assert-True { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" + (($Text -split "`r?`n" | Select-Object -First 12) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

function Bcf {
    param([string[]]$CliArgs)
    $all = @('-NoProfile', '-File', $bcf) + $CliArgs
    $out = & pwsh @all 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

function New-Sandbox {
    param([string]$Name, [switch]$NoGit)
    $p = Join-Path $sandboxRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p 'Cargo.toml') -Value "[package]`nname=`"t`"`nversion=`"0.1.0`"`nedition=`"2021`"" -Encoding UTF8
    if (-not $NoGit) {
        & git -C $p init -q 2>&1 | Out-Null
        & git -C $p add -A 2>&1 | Out-Null
        & git -C $p -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    }
    return $p
}

Write-Host ''
Write-Host "  ДЫМОВЫЕ ТЕСТЫ CLI   песочница: $sandboxRoot" -ForegroundColor Cyan
Write-Host ''

# --- Диспетчер -----------------------------------------------------------------------
Write-Host '  диспетчер' -ForegroundColor White

It 'help перечисляет команды' {
    $r = Bcf @('--help')
    Assert-Match $r.Out 'bcf <команда>'
    foreach ($c in @('init', 'install', 'doctor', 'run', 'memory', 'meta')) { Assert-Match $r.Out "\b$c\b" }
}

It 'неизвестная команда — код 2, а не тихий успех' {
    $r = Bcf @('nosuchcommand')
    Assert-True ($r.Code -eq 2) "ожидал код 2, получил $($r.Code)"
    Assert-Match $r.Out 'Неизвестная команда'
}

It 'version печатает версию из VERSION' {
    $r = Bcf @('--version')
    $v = (Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim()
    Assert-Match $r.Out ([regex]::Escape($v))
}

# Регрессия: switch без break проверял и общее правило '^-', и флаг уезжал дальше
# как неизвестный аргумент харнесса.
It 'общий флаг не утекает в подкоманду' {
    $p = New-Sandbox 'flags'
    $r = Bcf @('detect', '--project', $p, '--no-color')
    Assert-NoMatch $r.Out 'no-color'
    Assert-Match $r.Out 'РАЗБОР ПРОЕКТА'
}

# --- detect --------------------------------------------------------------------------
Write-Host ''
Write-Host '  detect' -ForegroundColor White

It 'узнаёт стек и помечает источник вывода' {
    $p = New-Sandbox 'detect'
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'Rust'
    Assert-Match $r.Out 'cargo'
    Assert-Match $r.Out '(уверенно|догадка|проверено)' 'у предложений должен быть виден источник'
}

It 'проект без git назван блокером с последствием, а не статусом' {
    $p = New-Sandbox 'nogit' -NoGit
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'НЕ ПОЕДЕТ'
    Assert-Match $r.Out 'восстановить'  'блокер обязан называть цену, а не только факт'
}

It '--json отдаёт разбираемый JSON' {
    $p = New-Sandbox 'detectjson'
    $r = Bcf @('detect', '--project', $p, '--json')
    $j = $r.Out | ConvertFrom-Json
    Assert-True ($j.Root) 'в JSON нет Root'
}

# --- install -------------------------------------------------------------------------
Write-Host ''
Write-Host '  install' -ForegroundColor White

It 'ставит .claude, config и CLAUDE.md' {
    $p = New-Sandbox 'install'
    $r = Bcf @('install', '--project', $p)
    foreach ($f in @('.claude\settings.json', '.claude\hooks\done-gate.sh', 'config\harness.json', 'CLAUDE.md')) {
        Assert-True (Test-Path (Join-Path $p $f)) "не поставлен: $f"
    }
    Assert-True (@(Get-ChildItem (Join-Path $p '.claude\agents') -Filter '*.md' -Recurse).Count -gt 0) 'нет ролей'
}

It 'подстановки не оставляют шаблонных плейсхолдеров' {
    $p = New-Sandbox 'install-subst'
    Bcf @('install', '--project', $p) | Out-Null
    $left = @(Get-ChildItem (Join-Path $p '.claude') -Recurse -File |
              Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match '\{\{[A-Z_]+\}\}' })
    Assert-True ($left.Count -eq 0) "остались плейсхолдеры в: $(($left | ForEach-Object { $_.Name }) -join ', ')"
}

# Регрессия: обвязка — это файлы, которые владелец правит под себя. Молчаливая
# перезапись при обновлении фабрики теряет его правки, и замечает он это на прогоне.
It 'повторный install не затирает правки владельца' {
    $p = New-Sandbox 'install-twice'
    Bcf @('install', '--project', $p) | Out-Null
    $mine = Join-Path $p '.claude\settings.json'
    Set-Content -LiteralPath $mine -Value '{"mine":true}' -Encoding UTF8
    $r = Bcf @('install', '--project', $p)
    Assert-Match (Get-Content -Raw -LiteralPath $mine) 'mine'
    Assert-Match $r.Out 'НЕ ТРОНУТО'
}

It '--dry ничего не пишет' {
    $p = New-Sandbox 'install-dry'
    $r = Bcf @('install', '--project', $p, '--dry')
    Assert-True (-not (Test-Path (Join-Path $p '.claude'))) 'сухой прогон создал .claude'
    Assert-Match $r.Out 'ничего не записано'
}

It '.gitignore получает каталог состояния' {
    $p = New-Sandbox 'install-gitignore'
    Bcf @('install', '--project', $p) | Out-Null
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $p '.gitignore')) '\.bcf/'
}

# --- tasks ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  tasks' -ForegroundColor White

It 'пустой бэклог не роняет таблицу' {
    $p = New-Sandbox 'tasks-empty'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'БЭКЛОГ'
    Assert-NoMatch $r.Out 'Exception|не удалось привязать|Cannot bind'
}

It 'коллизия владения названа последствием' {
    $p = New-Sandbox 'tasks-collide'
    Bcf @('install', '--project', $p) | Out-Null
    foreach ($id in @('01', '02')) {
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p "tasks\TASK-$id-x.md") -Value @"
# TASK-$id — тест

## Файлы
- ``src/main.rs``

## Вход
—
"@
    }
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'КОЛЛИЗИИ ВЛАДЕНИЯ'
    Assert-Match $r.Out 'арбитр'  'коллизия обязана объяснять, чем она обернётся'
}

It 'задача без секции Файлы отмечена как непроверяемая' {
    $p = New-Sandbox 'tasks-nofiles'
    Bcf @('install', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-09-x.md') -Value "# TASK-09 — без файлов`n"
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'без объявленных файлов'
}

# --- отчётность ----------------------------------------------------------------------
Write-Host ''
Write-Host '  отчётность' -ForegroundColor White

It 'на пустом проекте report и cost честно говорят «прогонов не было»' {
    $p = New-Sandbox 'reports'
    Bcf @('install', '--project', $p) | Out-Null
    foreach ($cmd in @('report', 'cost', 'runs', 'board')) {
        $r = Bcf @($cmd, '--project', $p)
        Assert-NoMatch $r.Out 'ГОТОВО' "$cmd не имеет права говорить «готово» без прогона"
    }
}

# Регрессия: узлы отработали → отчёт печатал «ГОТОВО», хотя очередь закрылась не вся.
It 'вердикт берётся из итога графа, а не из числа узлов' {
    $p = New-Sandbox 'report-verdict'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_test01'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $j = Join-Path $dir 'journal.jsonl'
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"node-start","key":"n1","label":"работа-TASK-01","phase":"Работа","role":"worker","model":"m","ts":"2026-01-01T00:00:01.0000000+00:00"}'
        '{"event":"node-finish","key":"n1","label":"работа-TASK-01","phase":"Работа","ok":true,"tokens":1234,"ts":"2026-01-01T00:00:09.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":1234,"result":"{\"passed\":0,\"stuck\":1,\"complete\":false,\"total\":1}","ts":"2026-01-01T00:00:10.0000000+00:00"}'
    ) | Set-Content -LiteralPath $j -Encoding UTF8

    $r = Bcf @('report', '--project', $p)
    Assert-Match $r.Out 'НЕПОЛНО' 'узлы зелёные, но очередь не закрыта — это не «готово»'
    Assert-Match $r.Out 'закрыто 0 из 1'
    Assert-True ($r.Code -eq 1) "неполный прогон обязан давать ненулевой код, получил $($r.Code)"
}

It 'сухой план не выдаётся за результат' {
    $p = New-Sandbox 'report-dry'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_dry001'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","dryPlan":true,"ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":0,"result":"{\"passed\":0,\"stuck\":1,\"complete\":false,\"total\":1}","ts":"2026-01-01T00:00:02.0000000+00:00"}'
    ) | Set-Content -LiteralPath (Join-Path $dir 'journal.jsonl') -Encoding UTF8

    $r = Bcf @('report', '--project', $p)
    Assert-Match $r.Out 'СУХОЙ ПЛАН'
    Assert-Match $r.Out 'не говорит ничего'
    Assert-True ($r.Code -eq 0) 'сухой план не провал'
}

It 'cost не печатает ноль там, где тарифа нет' {
    $p = New-Sandbox 'cost-unknown'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_cost01'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"node-start","key":"n1","label":"a","phase":"Работа","role":"worker","model":"unknown-model","ts":"2026-01-01T00:00:01.0000000+00:00"}'
        '{"event":"node-finish","key":"n1","label":"a","phase":"Работа","ok":true,"tokens":5000,"ts":"2026-01-01T00:00:05.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":5000,"ts":"2026-01-01T00:00:06.0000000+00:00"}'
    ) | Set-Content -LiteralPath (Join-Path $dir 'journal.jsonl') -Encoding UTF8

    $r = Bcf @('cost', '--project', $p)
    Assert-Match $r.Out '5000'
    Assert-Match $r.Out '—'  'неизвестная цена показывается прочерком, а не нулём'
}

# --- meta ----------------------------------------------------------------------------
Write-Host ''
Write-Host '  meta' -ForegroundColor White

It 'audit находит незаполненный CLAUDE.md' {
    $p = New-Sandbox 'meta-audit'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('meta', 'audit', '--project', $p)
    Assert-Match $r.Out 'заготовка'
    Assert-True ($r.Code -eq 1) 'аудит с находками обязан давать ненулевой код'
}

# Регрессия: ссылка на фабрику внутри проекта — утечка, после которой агент туда идёт.
It 'audit ловит утечку пути фабрики в проект' {
    $p = New-Sandbox 'meta-leak'
    Bcf @('install', '--project', $p) | Out-Null
    Add-Content -LiteralPath (Join-Path $p 'CLAUDE.md') -Value "`nСм. также $root" -Encoding UTF8
    $r = Bcf @('meta', 'audit', '--project', $p)
    Assert-Match $r.Out 'ссылки на фабрику'
}

It 'wiki перечисляет статьи' {
    $p = New-Sandbox 'meta-wiki'
    $r = Bcf @('meta', 'wiki', '--project', $p)
    Assert-Match $r.Out 'common-errors'
}

# --- run -----------------------------------------------------------------------------
Write-Host ''
Write-Host '  run' -ForegroundColor White

It 'run без режима объясняет разницу движков' {
    $p = New-Sandbox 'run-help'
    $r = Bcf @('run', '--project', $p)
    Assert-Match $r.Out 'queue'
    Assert-Match $r.Out 'дороже|дешевле' 'выбор движка — про экономику, это должно быть видно'
    Assert-True ($r.Code -eq 2) 'без режима это не успех'
}

It 'ненастроенный проект не пускается в прогон' {
    $p = New-Sandbox 'run-unconfigured'
    $r = Bcf @('run', 'queue', '--project', $p)
    Assert-Match $r.Out 'bcf init'
    Assert-True ($r.Code -eq 2) 'прогон без настройки обязан отказать до первого токена'
}

# Регрессия: `exit (Invoke-Harness …)` съедал весь вывод прогона — PowerShell считает
# вывод функции её результатом. Снаружи это выглядело как «отработало мгновенно и молча»,
# то есть ход работы, ради которого прогон и запускают, не было видно вообще.
It 'вывод прогона доходит до консоли, а не в возвращаемое значение' {
    $p = New-Sandbox 'run-output'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-x.md') -Value @"
# TASK-01 — тест

## Файлы
- ``src/main.rs``

## Вход
—
"@
    $r = Bcf @('run', 'night', '--dry-plan', '--project', $p)
    Assert-Match $r.Out 'run-all' 'прогон отработал молча — его вывод потерян'
    Assert-Match $r.Out 'DRY-PLAN'
}

# --- Итог ----------------------------------------------------------------------------
Write-Host ''
if ($script:fail) {
    Write-Host "  ПРОВАЛ: $($script:fail) из $($script:pass + $script:fail)" -ForegroundColor Red
} else {
    Write-Host "  ВСЁ ЗЕЛЁНОЕ: $($script:pass) тестов" -ForegroundColor Green
}
Write-Host ''

# Песочницу убираем только на зелёном: на красном она — единственный способ посмотреть,
# что именно записалось.
if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
