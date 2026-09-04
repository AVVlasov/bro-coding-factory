# executor-field.tests.ps1 — «Исполнитель:» в файле задачи выключает её для фабрики.
#
#   pwsh harness/tests/executor-field.tests.ps1
#
# ЧТО ЛОВЯТ ЭТИ ТЕСТЫ. До появления поля в очередь run-all попадал ЛЮБОЙ файл
# tasks/<PREFIX>-NN-*.md с номером не 0. Задачу, которую ведёт человек, приходилось
# прятать сентинелом «**Gate-вход:** TASK-00»: она навсегда оставалась в gate-block, то
# есть в отчёте выглядела сломанной, а не занятой. Здесь проверяется другое: фабрика
# такую задачу не берёт и говорит почему, а человек продолжает видеть её в бэклоге.
#
# Второй класс — тихая порча старого: разборщик исполнителя не должен ни отбирать файлы
# у Get-TaskDeclaredFiles, ни выдумывать предшественников, ни считать человеческой
# задачу, созданную по шаблону с подсказкой в комментарии.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # корень фабрики
$bcf  = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-executor-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ok   $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ПРОВАЛ  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Assert-True { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-Eq {
    param($Actual, $Expected, [string]$Msg = '')
    if ("$Actual" -ne "$Expected") { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "ждал «$Expected», получил «$Actual»") }
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" + (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 20) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

# Разборщик грузим напрямую: он же работает и в run-all, и в CLI, и подменять его
# копией регекспа в тесте значит проверять копию.
$env:BCF_PROJECT_ROOT = $sandboxRoot
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
. (Join-Path $root 'harness\lib\claims.ps1')

Write-Host ''
Write-Host "  ИСПОЛНИТЕЛЬ ЗАДАЧИ   песочница: $sandboxRoot" -ForegroundColor Cyan

# --- 1. Разбор строки -------------------------------------------------------------------
Write-Host ''
Write-Host '1. Разбор строки «Исполнитель:»' -ForegroundColor White

It 'простая строка читается' {
    Assert-Eq (Get-BcfExecutorFromText -Body "# TASK-01`n`nИсполнитель: Иван`n") 'Иван'
}

It 'строчная буква и жирное начертание читаются так же' {
    Assert-Eq (Get-BcfExecutorFromText -Body "исполнитель: Иван") 'Иван'
    Assert-Eq (Get-BcfExecutorFromText -Body "**Исполнитель:** Иван") 'Иван'
    Assert-Eq (Get-BcfExecutorFromText -Body "Исполнитель: **Иван Петров**") 'Иван Петров'
}

It 'подсказка в HTML-комментарии исполнителем не считается' {
    # Иначе КАЖДАЯ созданная по шаблону задача оказалась бы человеческой и очередь
    # опустела бы молча — самый дорогой отказ из возможных здесь.
    $body = "# TASK-01`n`n<!-- Исполнитель: <имя человека> — фабрика не возьмёт -->`n`nИсполнитель: фабрика`n"
    Assert-Eq (Get-BcfExecutorFromText -Body $body) 'фабрика'
    Assert-True (Test-BcfExecutorIsFactory (Get-BcfExecutorFromText -Body $body)) 'шаблонная задача уехала к человеку'
}

It 'пустое поле и синонимы фабрики означают фабрику' {
    foreach ($v in @('', 'фабрика', 'Фабрика', 'factory', 'агент', 'bcf', '—', 'нет')) {
        Assert-True (Test-BcfExecutorIsFactory $v) "«$v» должно означать фабрику"
    }
    Assert-True (-not (Test-BcfExecutorIsFactory 'Иван')) 'имя человека принято за фабрику'
}

# --- 2. Новое поле не ломает старые разборщики ------------------------------------------
Write-Host ''
Write-Host '2. Старые разборщики не задеты' -ForegroundColor White

$fx = Join-Path $sandboxRoot 'parsers'
New-Item -ItemType Directory -Force -Path (Join-Path $fx 'tasks') | Out-Null
Set-Content -Encoding UTF8 -LiteralPath (Join-Path $fx 'tasks\TASK-07-mixed.md') -Value @"
# TASK-07 — смешанная

## Кто ведёт

Исполнитель: Иван Петров
Блокер: ждём доступ к боевой базе

## Файлы

- ``src/a.rs``

## Вход

TASK-06
"@

It 'декларация файлов читается как раньше' {
    $f = @(Get-TaskDeclaredFiles -TaskId 'TASK-07' -Root $fx)
    Assert-Eq $f.Count 1 "лишние или потерянные файлы: $($f -join ', ')"
    Assert-Eq $f[0] 'src/a.rs'
}

It 'предшественники читаются как раньше' {
    $p = @(Get-TaskPredecessors -TaskId 'TASK-07' -Root $fx)
    Assert-Eq $p.Count 1 "предшественники разъехались: $($p -join ', ')"
    Assert-Eq $p[0] 'TASK-06'
}

It 'исполнитель и признак человека берутся из файла' {
    Assert-Eq (Get-TaskExecutor -TaskId 'TASK-07' -Root $fx) 'Иван Петров'
    Assert-True (Test-TaskIsHuman -TaskId 'TASK-07' -Root $fx)
}

It 'задача без строки принадлежит фабрике' {
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $fx 'tasks\TASK-08-plain.md') -Value "# TASK-08 — обычная`n`n## Файлы`n`n- ``src/b.rs```n"
    Assert-Eq (Get-TaskExecutor -TaskId 'TASK-08' -Root $fx) ''
    Assert-True (-not (Test-TaskIsHuman -TaskId 'TASK-08' -Root $fx))
}

# --- 3. Живая фикстура: три задачи, одна у человека -------------------------------------
#
# Здесь уже не функции, а команды целиком: очередь строит run-all, таблицу печатает
# bcf tasks. Проверка «функция вернула правильное» проходила бы и в том случае, если
# очередь эту функцию не зовёт.
Write-Host ''
Write-Host '3. Три задачи, одна у человека: очередь и бэклог' -ForegroundColor White

$proj = Join-Path $sandboxRoot 'project'
New-Item -ItemType Directory -Force -Path (Join-Path $proj 'src') | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
& git -C $proj init -q 2>&1 | Out-Null
& git -C $proj add -A 2>&1 | Out-Null
& git -C $proj -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null

& pwsh -NoProfile -File $bcf install --project $proj 2>&1 | Out-Null

Set-Content -Encoding UTF8 -LiteralPath (Join-Path $proj 'tasks\TASK-01-first.md') -Value @"
# TASK-01 — первая

## Файлы

- ``src/a.rs``

**Gate-вход:** нет
"@
Set-Content -Encoding UTF8 -LiteralPath (Join-Path $proj 'tasks\TASK-02-human.md') -Value @"
# TASK-02 — договориться о доступе

## Кто ведёт

Исполнитель: Иван
Блокер: доступ к боевой базе даёт только администратор

## Файлы

- ``src/b.rs``

**Gate-вход:** нет
"@
Set-Content -Encoding UTF8 -LiteralPath (Join-Path $proj 'tasks\TASK-03-third.md') -Value @"
# TASK-03 — третья

## Файлы

- ``src/c.rs``

**Gate-вход:** нет
"@

function Bcf { param([string[]]$CliArgs)
    $out = & pwsh -NoProfile -File $bcf @CliArgs 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

It 'в сухую очередь run-all попадают две задачи из трёх' {
    $r = Bcf @('run', 'night', '--dry-plan', '--project', $proj)
    Assert-Match $r.Out 'Задач в очереди: 2' "в очередь взято не две задачи:`n$($r.Out)"
    Assert-Match $r.Out 'TASK-02 — пропущена: исполнитель Иван' 'в журнале нет причины пропуска'
    Assert-Match $r.Out 'Очередь: TASK-01, TASK-03' 'состав очереди не тот'
    Assert-NoMatch $r.Out 'план:\s+TASK-02\s+допущена' 'задача человека допущена планировщиком'
}

It 'bcf tasks показывает все три и колонку исполнителя' {
    $r = Bcf @('tasks', '--project', $proj)
    Assert-Match $r.Out 'всего 3' "в бэклоге не три задачи:`n$($r.Out)"
    Assert-Match $r.Out 'исполнитель' 'нет колонки исполнителя'
    Assert-Match $r.Out 'TASK-02\s+у человека.+Иван' 'задача человека не помечена в таблице'
    Assert-Match $r.Out 'TASK-01\s+готова.+фабрика' 'обычная задача перестала быть готовой'
    Assert-Match $r.Out 'готово к работе 2' 'задача человека сосчитана готовой к работе'
    Assert-Match $r.Out 'у людей 1' 'задачи у людей не сосчитаны отдельно'
}

It 'в JSON у задачи есть исполнитель и признак человека' {
    $j = (Bcf @('tasks', '--project', $proj, '--json')).Out | ConvertFrom-Json
    $t2 = @($j | Where-Object { $_.Id -eq 'TASK-02' })[0]
    Assert-Eq $t2.Executor 'Иван'
    Assert-True $t2.IsHuman 'IsHuman не выставлен'
    Assert-True (-not $t2.Runnable) 'задача человека объявлена запускаемой'
    $t1 = @($j | Where-Object { $_.Id -eq 'TASK-01' })[0]
    Assert-True $t1.Runnable 'обычная задача перестала быть запускаемой'
}

It 'task why у задачи человека называет исполнителя, а не гейты' {
    $r = Bcf @('task', 'why', 'TASK-02', '--project', $proj)
    Assert-Match $r.Out 'ведёт человек: Иван'
    Assert-NoMatch $r.Out 'ГОТОВА К РАБОТЕ' 'задача человека объявлена готовой к работе'
}

# --- 4. bcf task new --for ---------------------------------------------------------------
Write-Host ''
Write-Host '4. bcf task new --for' -ForegroundColor White

It '--for заполняет строку и не попадает в название' {
    $p2 = Join-Path $sandboxRoot 'newfor'
    New-Item -ItemType Directory -Force -Path $p2 | Out-Null
    & git -C $p2 init -q 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $p2 'README.md') -Value 'x' -Encoding UTF8
    & git -C $p2 add -A 2>&1 | Out-Null
    & git -C $p2 -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    Bcf @('install', '--project', $p2) | Out-Null

    $r = Bcf @('task', 'new', 'договориться о доступе', '--for', 'Иван', '--project', $p2)
    Assert-Match $r.Out 'исполнитель: Иван'
    $f = @(Get-ChildItem (Join-Path $p2 'tasks') -Filter 'TASK-01-*.md')[0]
    $body = Get-Content -Raw -LiteralPath $f.FullName
    Assert-Match $body '(?m)^Исполнитель: Иван$' 'строка исполнителя не проставлена в файле'
    Assert-NoMatch $f.Name 'ivan' 'значение флага уехало в название задачи'
    Assert-True (Test-TaskIsHuman -TaskId 'TASK-01' -Root $p2) 'созданная задача не считается человеческой'
}

It 'без --for созданная по шаблону задача остаётся у фабрики' {
    $p3 = Join-Path $sandboxRoot 'newplain'
    New-Item -ItemType Directory -Force -Path $p3 | Out-Null
    & git -C $p3 init -q 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $p3 'README.md') -Value 'x' -Encoding UTF8
    & git -C $p3 add -A 2>&1 | Out-Null
    & git -C $p3 -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    Bcf @('install', '--project', $p3) | Out-Null

    Bcf @('task', 'new', 'обычная задача', '--project', $p3) | Out-Null
    Assert-True (-not (Test-TaskIsHuman -TaskId 'TASK-01' -Root $p3)) `
        'шаблонная задача без --for оказалась человеческой — очередь опустеет молча'
}

It '--for без значения отвергается, а не проглатывается' {
    $p4 = Join-Path $sandboxRoot 'newempty'
    New-Item -ItemType Directory -Force -Path $p4 | Out-Null
    & git -C $p4 init -q 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $p4 'README.md') -Value 'x' -Encoding UTF8
    & git -C $p4 add -A 2>&1 | Out-Null
    & git -C $p4 -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    Bcf @('install', '--project', $p4) | Out-Null

    $r = Bcf @('task', 'new', 'что-то', '--for', '--project', $p4)
    Assert-True ($r.Code -eq 2) "ждал код 2, получил $($r.Code)"
    Assert-Match $r.Out 'нет значения'
}

# --- Итог -------------------------------------------------------------------------------
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
