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

# --- 5. Зона чтения: только шапка задачи ------------------------------------------------
#
# Поле читают двое: фабрика и разборщик пула, который берёт строки до первой секции «## ».
# Пока фабрика читала «где угодно в теле», эти двое видели разное: строка под «## Кто ведёт»
# выключала задачу для фабрики и оставалась невидимой для пула, а строка «Исполнитель: Иван»
# внутри примера команд в «## Проверки» выключала задачу вообще без чьего-либо решения.
Write-Host ''
Write-Host '5. Зона чтения: шапка задачи, без секций и без блоков кода' -ForegroundColor White

It 'строка ниже первой секции исполнителем не считается' {
    $body = @"
# TASK-09 — под секцией

## Кто ведёт

Исполнитель: Иван

## Файлы

- ``src/a.rs``
"@
    Assert-Eq (Get-BcfExecutorFromText -Body $body) '' 'строка из секции прочитана как исполнитель'
}

It 'исполнитель и блокер читаются из шапки' {
    $body = @"
# TASK-10 — с шапкой

Исполнитель: Иван Петров
Блокер: доступ к боевой базе даёт только администратор

## Файлы

- ``src/a.rs``
"@
    Assert-Eq (Get-BcfExecutorFromText -Body $body) 'Иван Петров'
    Assert-Eq (Get-BcfBlockerFromText -Body $body) 'доступ к боевой базе даёт только администратор'
}

It 'пример команды в «## Проверки» задачу человеку не отдаёт' {
    $body = @"
# TASK-11 — с примером в проверках

## Проверки

``````
grep -n '^Исполнитель:' tasks/*.md
Исполнитель: Иван
``````
"@
    Assert-Eq (Get-BcfExecutorFromText -Body $body) '' 'строка из блока кода прочитана как исполнитель'
}

It 'блок кода в самой шапке тоже игнорируется' {
    # Забор проверяется раньше заголовка: «## » внутри блока — текст примера, и обрывать
    # по нему шапку нельзя, иначе настоящая строка ниже блока потеряется.
    $body = @"
# TASK-12 — с блоком в шапке

``````
Исполнитель: Пётр
## Файлы
``````

Исполнитель: Иван

## Файлы

- ``src/a.rs``
"@
    Assert-Eq (Get-BcfExecutorFromText -Body $body) 'Иван' 'исполнитель взят из блока кода, а не из шапки'
}

It 'шаблон кладёт обе строки в шапку, до первой секции' {
    $tpl = Get-Content -Raw -LiteralPath (Join-Path $root 'templates\project\task.md')
    $lines = @($tpl -split "`r?`n")
    $iSection = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^##\s' })
    $iExec    = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^Исполнитель:' })
    $iBlock   = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^Блокер:' })
    Assert-True ($iExec -ge 0) 'в шаблоне нет строки «Исполнитель:»'
    Assert-True ($iBlock -ge 0) 'в шаблоне нет строки «Блокер:»'
    Assert-True ($iSection -ge 0) 'в шаблоне нет ни одной секции'
    Assert-True ($iExec -lt $iSection) 'строка «Исполнитель:» уехала под секцию — разборщик пула её не увидит'
    Assert-True ($iBlock -lt $iSection) 'строка «Блокер:» уехала под секцию'
}

# --- 6. Граф очереди: bcf run queue ------------------------------------------------------
#
# Отдельный ярус, потому что очередь у графа СВОЯ: он не зовёт run-all, а собирает список
# задач сам. Пока он не спрашивал исполнителя, `bcf run queue` брал в работу ровно ту
# задачу, которую `bcf run night` уже пропускал, — и тексты CLI про «ни в night, ни в
# queue» были неправдой.
Write-Host ''
Write-Host '6. Граф очереди не берёт задачу человека' -ForegroundColor White

It 'в сухом плане графа две задачи из трёх, причина пропуска в журнале' {
    $out = & pwsh -NoProfile -File (Join-Path $root 'harness\graph.ps1') queue -DryPlan -ProjectRoot $proj -Yes 2>&1 | Out-String
    Assert-Match $out 'TASK-02 — пропущена: исполнитель Иван' "в журнале графа нет причины пропуска:`n$out"
    Assert-Match $out 'к работе: 2' 'граф взял в работу не две задачи'
    Assert-Match $out 'волна 1: 2 задач параллельно — TASK-01, TASK-03' 'состав волны не тот'
    Assert-NoMatch $out 'работа-TASK-02' 'узел задачи человека попал в план графа'
}

# --- Итог -------------------------------------------------------------------------------
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
