# claims.ps1 — общая память между параллельными агентами о том, кто какие файлы трогает.
#
# ЗАЧЕМ. git worktree изолирует рабочие деревья, но (документированное ограничение)
# НЕ предупреждает, что две ветки правят одни файлы: конфликт всплывает на слиянии,
# когда оба агента уже приняли несовместимые решения. Локи под работу агента —
# отдельно известный провал (у Cursor 20 агентов дали пропускную способность 2–3:
# держали лок слишком долго). Поэтому здесь НЕ лок на время работы, а
# **допуск на старте** плюс накопление фактов.
#
# Разбор подходов и цифры — wiki/research/2026-07-26-parallel-agents-file-conflicts.md.
#
# Три источника знания, и все три общие для всех процессов:
#   1. claims.json    — какие файлы держат прямо сейчас запущенные задачи;
#   2. co-change      — какие файлы исторически меняются вместе (git log), то есть
#                       связаны, даже если в декларации задачи их нет;
#   3. conflicts.json — какие пары задач реально столкнулись раньше. Планировщик
#                       больше не сводит их в параллель, даже если декларации чисты.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:FleetDir      = Join-Path (Get-BcfProjectRoot) '.bcf\fleet'
$script:ClaimsFile    = Join-Path $script:FleetDir 'claims.json'
$script:ConflictsFile = Join-Path $script:FleetDir 'conflicts.json'
$script:CoChangeFile  = Join-Path $script:FleetDir 'co-change.json'

function _Ensure-FleetDir {
    if (-not (Test-Path $script:FleetDir)) {
        New-Item -ItemType Directory -Force -Path $script:FleetDir | Out-Null
    }
}

# Все изменения реестра — под межпроцессной блокировкой: параллельные раннеры
# читают-модифицируют-пишут один и тот же файл.
function _With-ClaimsLock {
    param([Parameter(Mandatory)][scriptblock]$Body)
    _Ensure-FleetDir
    $lockPath = Join-Path $script:FleetDir 'claims.lock'
    $fs = $null
    for ($i = 0; $i -lt 100; $i++) {
        try { $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    try { return & $Body }
    finally { if ($fs) { try { $fs.Dispose() } catch { } } }
}

function _Read-Json($path, $default) {
    if (-not (Test-Path $path)) { return $default }
    try {
        $raw = Get-Content -Raw -LiteralPath $path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        return ($raw | ConvertFrom-Json)
    } catch { return $default }
}

function _Write-Json($path, $obj) {
    # Каталог берём из самого пути, а не из $script:FleetDir: кэш заявок пишется по корню
    # проекта, переданному вызывающим, и он не обязан совпадать с тем, что был при загрузке
    # библиотеки.
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # -InputObject, а не конвейер, и это не стиль. Пустой массив в конвейере не даёт
    # ConvertTo-Json НИ ОДНОЙ строки, Set-Content не получает входа и файл остаётся
    # прежним: снятая последняя заявка продолжала держать задачу, пока её не убирал
    # старый фильтр по pid. Заодно массив из одного элемента остаётся массивом, а не
    # схлопывается в объект.
    Set-Content -LiteralPath $path -Value (ConvertTo-Json -InputObject $obj -Depth 8) -Encoding UTF8
}

# Каталог задач берётся ИЗ КОНФИГА, а не из захардкоженного 'tasks'.
#
# paths.tasks — штатная настройка (её читают и bcf tasks, и bcf task, и карточка), но
# разборщики деклараций смотрели строго в <root>/tasks. На проекте с другим каталогом
# файл задачи просто не находился, и обе функции возвращали ПУСТО — то есть «файлов не
# объявлено» и «предшественников нет». Второе опаснее: задача с незакрытым гейтом
# объявлялась готовой и уходила в волну, а планировщик графа считал владение файлами по
# пустым декларациям, то есть не считал вовсе.
$script:TaskDirCache = @{}
function Get-BcfTasksDir {
    param([Parameter(Mandatory)][string]$Root)
    if ($script:TaskDirCache.ContainsKey($Root)) { return $script:TaskDirCache[$Root] }
    $rel = 'tasks'
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.paths -and $cfg.paths.tasks) { $rel = [string]$cfg.paths.tasks }
        }
    } catch { }
    $dir = Join-Path $Root ($rel -replace '/', '\')
    $script:TaskDirCache[$Root] = $dir
    return $dir
}

# --- Объявленные файлы задачи: секция «## Файлы» task-файла ---
function Get-TaskDeclaredFiles {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)

    # Пустой результат уходит вызывающему как $null (PowerShell разворачивает пустой
    # массив на выходе функции). Вызывающие обёрнуты в @(), поэтому у них он снова
    # становится пустым массивом; терпимость к $null нужна только тем, кто передаёт
    # результат дальше параметром — см. Get-CoupledFiles.
    $tasksDir = Get-BcfTasksDir -Root $Root
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return @() }
    $body = Get-Content -Raw -LiteralPath $tf.FullName
    $m = [regex]::Match($body, '(?ms)^##[^\r\n]*Файлы.*?(?=^##\s|\z)')
    if (-not $m.Success) { return @() }
    return @(Get-BcfFileBullets -Section $m.Value)
}

# Пути из секции «## Файлы» — ОДИН разборщик на задачу и на заявку. Читают эту секцию
# двое: декларация задачи и файл заявки, и разъехавшись, они дали бы допуск по одному
# списку, а проверку границ по другому.
#
# Только элементы списка. Раньше выкусывались любые «похожие на файл» токены из всей
# секции — и пояснение вида «не трогай `lib.rs`» попадало в декларацию как заявка на
# файл. В результате все задачи «сталкивались» на lib.rs и параллелизм выключался целиком.
function Get-BcfFileBullets {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Section)
    if ([string]::IsNullOrWhiteSpace($Section)) { return @() }
    $files = @()
    foreach ($line in ($Section -split "`r?`n")) {
        if ($line -notmatch '^\s*[-*]\s') { continue }
        foreach ($pm in [regex]::Matches($line, '([A-Za-z0-9_][A-Za-z0-9_./-]+\.[A-Za-z0-9]+)')) {
            $files += ($pm.Groups[1].Value -replace '\\', '/')
        }
    }
    return @($files | Select-Object -Unique)
}

# --- Предшественники задачи ------------------------------------------------------------
#
# ОДИН разборщик на всех, и это не вкусовщина. Пока их было два — CLI читал секцию
# «## Вход», а планировщик строку «**Gate-вход:**» — на реальном проекте `bcf tasks`
# показал 11 задач «готова» при пяти заблокированных и предложил «запустить готовые».
# Совет запустить задачу, у которой не сделан ни один из шести входов, стоит целого
# прогона. Расхождение двух парсеров молчаливо по построению: каждый по отдельности
# работает, и увидеть его можно только сравнив вывод с вердиктами вручную.
#
# Поддерживаются ОБА формата, потому что оба живут в реальных проектах:
#   **Gate-вход:** TASK-02 TASK-03      (как пишет харнесс и старые проекты)
#   ## Вход \n TASK-02, TASK-03         (как в шаблоне задачи фабрики)
# «нет» / «—» / «-» означают отсутствие предшественников.
function Get-TaskPredecessors {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Root,
        [string]$Prefix = 'TASK'
    )

    $tasksDir = Get-BcfTasksDir -Root $Root
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return @() }
    $body = Get-Content -Raw -LiteralPath $tf.FullName -ErrorAction SilentlyContinue
    if (-not $body) { return @() }

    $rx = [regex]::Escape($Prefix) + '-\d+'
    $value = ''

    $gate = [regex]::Match($body, '(?m)^\*\*Gate-вход[^:]*:\**\s*(.+)$')
    if ($gate.Success) { $value = $gate.Groups[1].Value }
    else {
        $sec = [regex]::Match($body, '(?ms)^##[^\r\n]*Вход.*?(?=^##\s|\z)')
        if ($sec.Success) { $value = $sec.Value }
    }
    if (-not $value) { return @() }
    if ($value -match '^\s*(нет|—|-|–)\s*$') { return @() }

    return @([regex]::Matches($value, $rx) | ForEach-Object { $_.Value } |
             Select-Object -Unique | Where-Object { $_ -ne $TaskId })
}

# --- Исполнитель задачи: человек или фабрика -------------------------------------------
#
# ЗАЧЕМ. Задачу, которую ведёт человек, до сих пор нечем было выразить: в очередь
# run-all попадал ЛЮБОЙ файл tasks/<PREFIX>-NN-*.md с номером не 0. Единственный обход —
# сентинел «**Gate-вход:** TASK-00»: задача навсегда висела в gate-block, то есть в
# отчёте выглядела сломанной, а не занятой. Отличить «фабрика не может» от «фабрику
# сюда не звали» было нечем ни человеку, ни экрану.
#
# Формат — одна строка «Исполнитель: <имя>» в ШАПКЕ задачи: между заголовком «# TASK-NN»
# и первой секцией «## ». Рядом с ней живёт «Блокер: <причина>» — свободный текст для
# человека, харнесс его не читает.
#
# ЗОНА ЧТЕНИЯ СУЖЕНА НАМЕРЕННО, и это не косметика. Во-первых, поле читает не только
# фабрика: разборщики пула читают шапку до первой секции, и строка под «## Кто ведёт»
# для них не существует — задача человека выглядела бы у них ничьей. Во-вторых, чтение
# «где угодно в теле» ловит собственный хвост: в секции «## Проверки» лежит блок команд,
# и строка «Исполнитель: Иван» внутри примера кода отправляла бы задачу человеку.
#
# Строки внутри тройных кавычек игнорируются отдельно — на случай, когда блок кода попал
# в саму шапку.
#
# Старым задачам это ничего не ломает: строка в шапке не видна ни одному из трёх
# существующих разборщиков (Get-TaskDeclaredFiles берёт только буллеты своей секции,
# Get-TaskPredecessors — только токены <PREFIX>-NN своей, hook-валидаторы — только
# чекбоксы и заголовки).
#
# Имя «Исполнитель», а не «Owner»: «Owner: <agent-type>» уже занят шаблонами подзадач
# (templates/agents/task-decomposer.md) и означает ТИП агента фабрики, а не человека.

# Значения, означающие «работает фабрика». Пустое поле — тоже фабрика: задача без
# строки обязана вести себя ровно как до появления поля.
$script:BcfFactoryExecutors = @('фабрика', 'factory', 'агент', 'agent', 'bcf', 'робот', 'нет', 'none', '—', '–', '-')

# Шапка задачи: строки от начала файла до первой секции «## », без HTML-комментариев и
# без содержимого блоков кода. Отсюда читаются и «Исполнитель:», и «Блокер:».
function Get-BcfTaskHeader {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    # Комментарии шаблона выкидываем ПЕРВЫМИ. Подсказка «Исполнитель: <имя человека>»
    # живёт в templates/project/task.md; если её читать наравне с телом, каждая созданная
    # по шаблону задача окажется человеческой и очередь опустеет молча.
    $clean = [regex]::Replace($Body, '(?s)<!--.*?-->', '')
    $out = New-Object System.Collections.Generic.List[string]
    $inFence = $false
    foreach ($line in ($clean -split "`r?`n")) {
        # Забор проверяется ДО заголовка: «## » внутри блока кода — это текст примера,
        # а не начало секции, и обрывать шапку по нему нельзя.
        if ($line -match '^[ \t]*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^[ \t]*##[ \t]') { break }
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Get-BcfExecutorFromText {
    param([string]$Body)
    $header = Get-BcfTaskHeader -Body $Body
    if (-not $header) { return '' }
    $m = [regex]::Match($header, '(?im)^[ \t]*(?:[-*][ \t]+)?\*{0,2}[ \t]*Исполнитель[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.Trim().Trim('*').Trim().Trim('`').Trim()
}

function Get-BcfBlockerFromText {
    param([string]$Body)
    $header = Get-BcfTaskHeader -Body $Body
    if (-not $header) { return '' }
    $m = [regex]::Match($header, '(?im)^[ \t]*(?:[-*][ \t]+)?\*{0,2}[ \t]*Блокер[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.Trim().Trim('*').Trim().Trim('`').Trim()
}

function Test-BcfExecutorIsFactory {
    param([string]$Executor)
    if ([string]::IsNullOrWhiteSpace($Executor)) { return $true }
    return ($script:BcfFactoryExecutors -contains $Executor.Trim().ToLower())
}

function Get-TaskExecutor {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)

    $tasksDir = Get-BcfTasksDir -Root $Root
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return '' }
    $body = Get-Content -Raw -LiteralPath $tf.FullName -ErrorAction SilentlyContinue
    return (Get-BcfExecutorFromText -Body ([string]$body))
}

# Единственный вопрос, который задают очередь и планировщик: трогать ли эту задачу.
function Test-TaskIsHuman {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)

    $ex = Get-TaskExecutor -TaskId $TaskId -Root $Root
    return [bool]($ex -and -not (Test-BcfExecutorIsFactory $ex))
}

# --- Класс задачи и приёмка лидером направления -----------------------------------------
#
# ЗАЧЕМ. verdict: PASS доказывает только то, что гейты задачи зелёные — то же самое, что
# уже написано у Get-BcfExecutorFromText про исполнителя, только уровнем выше: не «фабрика
# или человек ведёт задачу», а «может ли задача уехать в integration.branch сама, доказав
# себя тестами, или нужен человек, который посмотрит на неё глазами». CORE (продуктовая
# логика) и NFR (нефункциональные требования — безопасность, миграции, инфраструктура)
# без такого взгляда не продвигаются: тесты доказывают то, что написано в них, а не то,
# что задача решает нужную проблему правильным способом. GEN (генерируемое: доки, шаблоны,
# перенос) минует приёмку — там сама природа работы такая, что смотреть особо не на что.
#
# Формат — строка «Класс: CORE|NFR|GEN» В ШАПКЕ задачи, тем же способом, что и
# «Исполнитель:»/«Блокер:»: между заголовком «# TASK-NN» и первой секцией «## ». Без
# строки класс — CORE: молчание не означает «эта работа не важна», это означало бы
# обратное тому, что нужно, — задача без объявленного класса получила бы самый мягкий
# режим по умолчанию.
$script:BcfTaskClasses = @('CORE', 'NFR', 'GEN')

function Get-BcfTaskClassFromText {
    param([string]$Body)
    $header = Get-BcfTaskHeader -Body $Body
    if (-not $header) { return 'CORE' }
    $m = [regex]::Match($header, '(?im)^[ \t]*(?:[-*][ \t]+)?\*{0,2}[ \t]*Класс[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if (-not $m.Success) { return 'CORE' }
    $v = $m.Groups[1].Value.Trim().Trim('*').Trim().Trim('`').Trim().ToUpperInvariant()
    if ($script:BcfTaskClasses -contains $v) { return $v }
    return 'CORE'
}

# $null, если у задачи вообще нет файла — отличие важно: гейт приёмки ниже обязан молчать
# про задачу, которой не существует, а не объявлять её CORE и требовать приёмку на пустом
# месте (это сломало бы каждый юнит-тест Merge-TaskWorktree, который зовёт её без единого
# файла задачи в фикстуре).
function Get-BcfTaskClass {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)
    $tasksDir = Get-BcfTasksDir -Root $Root
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return $null }
    $body = Get-Content -Raw -LiteralPath $tf.FullName -ErrorAction SilentlyContinue
    return (Get-BcfTaskClassFromText -Body ([string]$body))
}

$script:AcceptanceDirCache = @{}

# Каталог приёмок — из конфига, как каталог задач и заявок: проект вправе назвать его
# иначе. Файл `tasks/.acceptance/<TASK>.md` едет в git тем же способом, что вердикт и
# заявка — приёмку лидера обязана видеть вся команда, а не только тот, у кого она стояла
# перед глазами.
function Get-BcfAcceptanceDir {
    param([string]$Root = '')
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    if ($script:AcceptanceDirCache.ContainsKey($Root)) { return $script:AcceptanceDirCache[$Root] }
    $rel = 'tasks/.acceptance'
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.paths -and $cfg.paths.acceptance) { $rel = [string]$cfg.paths.acceptance }
        }
    } catch { }
    $dir = Join-Path $Root ($rel -replace '/', '\')
    $script:AcceptanceDirCache[$Root] = $dir
    return $dir
}

function Get-BcfAcceptancePath {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)
    return (Join-Path (Get-BcfAcceptanceDir -Root $Root) "$TaskId.md")
}

function Test-BcfTaskAccepted {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)
    return (Test-Path -LiteralPath (Get-BcfAcceptancePath -TaskId $TaskId -Root $Root))
}

function Test-BcfTaskNeedsAcceptance {
    param([string]$Class)
    return ($Class -eq 'CORE' -or $Class -eq 'NFR')
}

# ГЕЙТ ПРОДВИЖЕНИЯ. Возвращает @{ Ok; Class; Required; Reason }. Ok=$false ровно тогда,
# когда класс требует приёмки и файла приёмки нет — это единственный отказ, вызывающий
# (Merge-TaskWorktree) обязан читать как «сливать нельзя».
#
# БЕЗ ФАЙЛА ЗАДАЧИ ГЕЙТ НЕ ПРИМЕНИМ, И ЭТО НЕ ТО ЖЕ САМОЕ, ЧТО «КЛАСС CORE». Юнит-тесты
# git-механики слияния (merge-integration.tests.ps1) зовут Merge-TaskWorktree по имени
# ветки без единого файла задачи в фикстуре — если бы отсутствие файла тоже читалось как
# CORE без приёмки, слияние перестало бы проходить везде, где сейчас проходит, и тесты
# газовой механики стали бы тестами совсем другого гейта.
function Test-BcfTaskAcceptanceGate {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)
    $class = Get-BcfTaskClass -TaskId $TaskId -Root $Root
    if ($null -eq $class) {
        return @{ Ok = $true; Class = ''; Required = $false; Reason = 'файла задачи нет — гейт приёмки неприменим' }
    }
    if (-not (Test-BcfTaskNeedsAcceptance -Class $class)) {
        return @{ Ok = $true; Class = $class; Required = $false; Reason = "класс $class приёмки не требует" }
    }
    if (Test-BcfTaskAccepted -TaskId $TaskId -Root $Root) {
        return @{ Ok = $true; Class = $class; Required = $true; Reason = "класс $class принят лидером" }
    }
    return @{ Ok = $false; Class = $class; Required = $true; Reason = 'ждёт приёмки лидера' }
}

function ConvertTo-BcfAcceptanceText {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Leader,
        [string]$Lens = '',
        [string]$Note = '',
        [Parameter(Mandatory)][string]$VerdictSha,
        [string]$When = ''
    )
    if (-not $When) { $When = (Get-Date -Format 'o') }
    $lines = @(
        "# Приёмка $TaskId",
        '',
        "Лидер: $Leader",
        "Когда: $When",
        "Ракурс: $Lens",
        "Заметка: $Note",
        '',
        "Вердикт: $VerdictSha",
        ''
    )
    return ($lines -join "`n")
}

function ConvertFrom-BcfAcceptanceText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $leader = ''; $when = ''; $lens = ''; $note = ''; $sha = ''
    $ml = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Лидер[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($ml.Success) { $leader = $ml.Groups[1].Value.Trim() }
    $mw = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Когда[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mw.Success) { $when = $mw.Groups[1].Value.Trim() }
    $mr = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Ракурс[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mr.Success) { $lens = $mr.Groups[1].Value.Trim() }
    $mn = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Заметка[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mn.Success) { $note = $mn.Groups[1].Value.Trim() }
    $mv = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Вердикт[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mv.Success) { $sha = $mv.Groups[1].Value.Trim() }
    return [pscustomobject]@{ Leader = $leader; When = $when; Lens = $lens; Note = $note; VerdictSha = $sha }
}

# --- Связность из истории: какие файлы ходят в коммитах вместе с данными ---
#
# Декларация врёт: агент правит scan.rs, а ломает main.rs, который его зовёт.
# Co-change — дешёвый суррогат графа зависимостей: если два файла попадали в один
# коммит чаще порога, считаем их связанными и держим занятыми вместе.
function Update-CoChangeIndex {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxCommits = 300,
        [int]$MinPairCount = 2,
        # Файлы-хабы (lib.rs, mod.rs, index.ts, package.json) меняются вместе со ВСЕМ,
        # поэтому как сигнал связности бесполезны: попав в индекс, они склеивают весь
        # бэклог в одну неразделимую массу и параллелизм становится невозможен.
        # Отбрасываем всё, у чего степень связей выше порога.
        [int]$MaxDegree = 8
    )

    $log = & git -C $Root log --pretty=format:'@@' --name-only -n $MaxCommits 2>$null
    if (-not $log) { return @{} }

    $pairs = @{}
    $current = @()
    $flush = {
        if ($current.Count -gt 1 -and $current.Count -le 25) {   # мега-коммиты (рефакторинг всего) шумят
            for ($a = 0; $a -lt $current.Count; $a++) {
                for ($b = $a + 1; $b -lt $current.Count; $b++) {
                    $k1 = $current[$a]; $k2 = $current[$b]
                    $key = if ($k1 -lt $k2) { "$k1`t$k2" } else { "$k2`t$k1" }
                    if ($pairs.ContainsKey($key)) { $pairs[$key]++ } else { $pairs[$key] = 1 }
                }
            }
        }
        $current = @()
    }
    foreach ($line in $log) {
        $t = "$line".Trim()
        if ($t -eq '@@') { & $flush; continue }
        if ($t) { $current += ($t -replace '\\', '/') }
    }
    & $flush

    $index = @{}
    foreach ($key in $pairs.Keys) {
        if ($pairs[$key] -lt $MinPairCount) { continue }
        $parts = $key -split "`t"
        foreach ($side in 0, 1) {
            $from = $parts[$side]; $to = $parts[1 - $side]
            if (-not $index.ContainsKey($from)) { $index[$from] = @() }
            if ($index[$from] -notcontains $to) { $index[$from] += $to }
        }
    }
    # Убираем хабы: и как ключи, и из списков соседей.
    $hubs = @($index.Keys | Where-Object { @($index[$_]).Count -gt $MaxDegree })
    foreach ($h in $hubs) { $index.Remove($h) }
    if ($hubs.Count) {
        foreach ($k in @($index.Keys)) {
            $index[$k] = @($index[$k] | Where-Object { $hubs -notcontains $_ })
        }
    }

    _Write-Json $script:CoChangeFile @{
        built_at = (Get-Date -Format 'o'); commits = $MaxCommits
        max_degree = $MaxDegree; hubs_dropped = @($hubs)
        index = $index
    }
    return $index
}

function Get-CoupledFiles {
    # Не Mandatory: задача без объявленных файлов — законное состояние на входе, и
    # отказывать ей должен планировщик с внятной причиной, а не привязка параметра.
    param([string[]]$Files = @())

    if (-not $Files -or -not $Files.Count) { return @() }
    $data = _Read-Json $script:CoChangeFile $null
    if (-not $data -or -not $data.index) { return @() }
    $out = @()
    foreach ($f in $Files) {
        $linked = $data.index.$f
        if ($linked) { $out += @($linked) }
    }
    return @($out | Select-Object -Unique | Where-Object { $Files -notcontains $_ })
}

# --- ЗАЯВКА НА ЗАДАЧУ: ФАЙЛ В GIT -------------------------------------------------------
#
# Пока фабрику вела одна машина, заявка была строкой в `.bcf/fleet/claims.json`, а живость
# проверялась по pid: процесса нет — заявки нет. В команде оба допущения ложны.
#
# Файл в `.bcf/` не выезжает за пределы своего диска. Второй участник его не видит, берёт
# ту же задачу, и узнают об этом двое на слиянии, когда каждый уже написал свою версию.
# А pid чужой машины на своей либо не находится вовсе (заявка снимается под работающим
# человеком), либо находится, но принадлежит постороннему процессу: номера коротки и
# переиспользуются. То есть живость чужой заявки решалась угадыванием.
#
# Источник правды — файл `tasks/.claims/<TASK>.md`, который едет в git вместе с задачей:
# кто взял, в какой ветке, какие файлы объявлены, когда сделана заявка. Живость считается
# по СВЕЖЕСТИ записи: заявка старше порога (`team.claimTtlHours`, по умолчанию 12 часов)
# задачу не держит — участник, у которого погас ноутбук, не блокирует команду до утра.
#
# `.bcf/fleet/claims.json` остаётся ЛОКАЛЬНЫМ КЭШЕМ: по нему живёт сухой план (он не имеет
# права коммитить) и экран флота. Спор между кэшем и файлом решается в пользу файла.

$script:ClaimsDirCache = @{}

# Каталог заявок — из конфига, как и каталог задач: проект вправе назвать его иначе.
function Get-BcfClaimsDir {
    param([string]$Root = '')
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    if ($script:ClaimsDirCache.ContainsKey($Root)) { return $script:ClaimsDirCache[$Root] }
    $rel = 'tasks/.claims'
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.paths -and $cfg.paths.claims) { $rel = [string]$cfg.paths.claims }
        }
    } catch { }
    $dir = Join-Path $Root ($rel -replace '/', '\')
    $script:ClaimsDirCache[$Root] = $dir
    return $dir
}

# Порог протухания. Ноль и отрицательное значение в конфиге читаются как «оставь как было»:
# заявка, которая не протухает никогда, — это тот самый долгий лок, ради ухода от которого
# всё и затевалось.
function Get-BcfClaimTtlHours {
    param([string]$Root = '')
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    $h = 12.0
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.team -and $cfg.team.claimTtlHours) { $h = [double]$cfg.team.claimTtlHours }
        }
    } catch { }
    if ($h -le 0) { $h = 12.0 }
    return $h
}

# Кто я для команды. Имя человека, а не машины: в отказе второму претенденту должно стоять
# то же имя, что он видит в списке участников и в истории git.
function Get-BcfClaimOwner {
    param([string]$Root = '')
    if ($env:BCF_CLAIM_OWNER) { return $env:BCF_CLAIM_OWNER.Trim() }
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.team -and $cfg.team.member -and "$($cfg.team.member)".Trim()) { return "$($cfg.team.member)".Trim() }
        }
    } catch { }
    $gitName = ''
    try { $gitName = (& git -C $Root config user.name 2>$null | Out-String).Trim() } catch { }
    if ($gitName) { return $gitName }
    if ($env:USERNAME) { return $env:USERNAME }
    return 'без имени'
}

function Get-BcfClaimsCacheFile {
    param([string]$Root = '')
    if (-not $Root) { return $script:ClaimsFile }
    return (Join-Path $Root '.bcf\fleet\claims.json')
}

function ConvertTo-BcfClaimText {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Who = '',
        [string]$Branch = '',
        [string[]]$Files = @(),
        [string]$Since = ''
    )
    $lines = @(
        "# Заявка на $TaskId",
        '',
        "Кто: $Who",
        "Ветка: $Branch",
        "Когда: $Since",
        '',
        '## Файлы',
        ''
    )
    foreach ($f in @($Files)) { $lines += "- $f" }
    $lines += ''
    return ($lines -join "`n")
}

function ConvertFrom-BcfClaimText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [string]$TaskId = ''
    )
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $task = $TaskId
    if (-not $task) {
        $mt = [regex]::Match($Body, '(?m)^#\s*Заявка на\s+(\S+)\s*$')
        if ($mt.Success) { $task = $mt.Groups[1].Value }
    }
    $who    = ''; $branch = ''; $since = ''
    $mw = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Кто[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mw.Success) { $who = $mw.Groups[1].Value.Trim() }
    $mb = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Ветка[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($mb.Success) { $branch = $mb.Groups[1].Value.Trim() }
    $ms = [regex]::Match($Body, '(?im)^[ \t]*\*{0,2}[ \t]*Когда[ \t]*\*{0,2}[ \t]*:[ \t]*(.*?)[ \t]*$')
    if ($ms.Success) { $since = $ms.Groups[1].Value.Trim() }

    # Секция файлов разбирается ТОЙ ЖЕ функцией, что и «## Файлы» задачи. Второй разборщик
    # рядом с первым — это расхождение, которое молчит: обе половины по отдельности
    # работают, а видно его только сличением деклараций вручную.
    $files = @()
    $mf = [regex]::Match($Body, '(?ms)^##[^\r\n]*Файлы.*?(?=^##\s|\z)')
    if ($mf.Success) { $files = @(Get-BcfFileBullets -Section $mf.Value) }

    return [pscustomobject]@{
        task     = $task
        who      = $who
        branch   = $branch
        since    = $since
        files    = @($files)
        declared = @($files)
        pid      = 0
        source   = 'file'
    }
}

function Get-BcfClaimAgeHours {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Since, [datetime]$Now = (Get-Date))
    if ([string]::IsNullOrWhiteSpace($Since)) { return -1 }
    try {
        $dt = [datetimeoffset]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture)
        return ([datetimeoffset]$Now - $dt).TotalHours
    } catch { return -1 }
}

# Время заявки человеку: не ISO, а то, что читается с экрана рядом с именем.
function Format-BcfClaimSince {
    param([AllowEmptyString()][string]$Since)
    if ([string]::IsNullOrWhiteSpace($Since)) { return 'время не указано' }
    try {
        $dt = [datetimeoffset]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture)
        return $dt.LocalDateTime.ToString('yyyy-MM-dd HH:mm')
    } catch { return $Since }
}

# Все заявки-файлы, включая протухшие: у каждой проставлены ageHours и stale. Протухшие
# возвращаются НАМЕРЕННО — их надо показывать («заявку держит Пётр, но ей 30 часов»),
# а не делать вид, что их нет.
function Get-BcfFileClaims {
    param([string]$Root = '', [double]$TtlHours = 0)
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    if ($TtlHours -le 0) { $TtlHours = Get-BcfClaimTtlHours -Root $Root }
    $dir = Get-BcfClaimsDir -Root $Root
    if (-not (Test-Path $dir -PathType Container)) { return @() }
    $now = Get-Date
    $out = @()
    foreach ($f in @(Get-ChildItem $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $body = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $c = ConvertFrom-BcfClaimText -Body ([string]$body) -TaskId $f.BaseName
        if (-not $c) { continue }
        $age = Get-BcfClaimAgeHours -Since $c.since -Now $now
        # Время, которого нет или которое не разобралось, считается протухшим. Иначе битая
        # строка держала бы задачу вечно, и никто бы не догадался почему.
        $c | Add-Member -NotePropertyName ageHours -NotePropertyValue $age -Force
        $c | Add-Member -NotePropertyName stale -NotePropertyValue ([bool]($age -lt 0 -or $age -gt $TtlHours)) -Force
        $c | Add-Member -NotePropertyName path -NotePropertyValue $f.FullName -Force
        $out += $c
    }
    return @($out)
}

function Get-ActiveClaims {
    param([string]$Root = '', [double]$TtlHours = 0)
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    if ($TtlHours -le 0) { $TtlHours = Get-BcfClaimTtlHours -Root $Root }

    $alive = @(Get-BcfFileClaims -Root $Root -TtlHours $TtlHours | Where-Object { -not $_.stale })
    $seen  = @($alive | ForEach-Object { $_.task })

    # Кэш добирает только то, чего в файлах нет: сухой план ничего не коммитит, а проверять
    # его допуск чем-то надо. Живость и здесь по свежести, а не по pid.
    $now = Get-Date
    foreach ($c in @(_Read-Json (Get-BcfClaimsCacheFile -Root $Root) @())) {
        if (-not $c.task -or ($seen -contains $c.task)) { continue }
        if ((Get-BcfClaimAgeHours -Since ([string]$c.since) -Now $now) -gt $TtlHours) { continue }
        $alive += [pscustomobject]@{
            task = $c.task; who = [string]$c.who; branch = [string]$c.branch
            since = [string]$c.since; files = @($c.files); declared = @($c.declared)
            pid = $c.pid; source = 'cache'; ageHours = 0; stale = $false; path = ''
        }
    }
    return @($alive)
}

# Проверка допуска. Возвращает @{ Ok; Reason; Blocking; Holder }.
function Test-TaskAdmission {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Root,
        [switch]$UseCoupling,
        [string]$Who = ''
    )

    $me = if ($Who) { $Who } else { Get-BcfClaimOwner -Root $Root }
    $active = @(Get-ActiveClaims -Root $Root)

    # 0. ЗАДАЧУ УЖЕ ВЗЯЛИ. Это первый вопрос, а не следствие пересечения файлов: двое на
    # двух машинах берут ОДНУ задачу, и отказ обязан назвать, кого именно ждать и с каких
    # пор. «Пересечение файлов с TASK-07» на этот вопрос не отвечает.
    foreach ($c in $active) {
        if ($c.task -ne $TaskId) { continue }
        if ($c.who -and $c.who -ne $me) {
            return @{ Ok = $false; Holder = $c.who; Blocking = @()
                      Reason = "задачу уже взял $($c.who), заявка от $(Format-BcfClaimSince $c.since)" }
        }
    }

    $declared = Get-TaskDeclaredFiles -TaskId $TaskId -Root $Root
    if ($declared.Count -eq 0) {
        # Без декларации мы не знаем, что задача тронет — параллелить вслепую нельзя.
        return @{ Ok = $false; Reason = "нет секции «## Файлы» — параллельный запуск запрещён"; Blocking = @(); Holder = '' }
    }

    $mine = @($declared)
    if ($UseCoupling) { $mine += Get-CoupledFiles -Files $declared }
    $mine = @($mine | Select-Object -Unique)

    foreach ($c in $active) {
        if ($c.task -eq $TaskId) { continue }
        $theirs = @($c.files)
        $overlap = @($mine | Where-Object { $theirs -contains $_ })
        if ($overlap.Count) {
            $whose = if ($c.who) { " ($($c.who), заявка от $(Format-BcfClaimSince $c.since))" } else { '' }
            return @{ Ok = $false; Holder = [string]$c.who; Blocking = @($c.task)
                      Reason = "пересечение файлов с $($c.task)$($whose): $($overlap -join ', ')" }
        }
    }

    # Память о прошлых столкновениях: пара, которая уже конфликтовала, в параллель не идёт,
    # даже если декларации сейчас чисты (связь могла быть не объявлена).
    $conflicts = _Read-Json $script:ConflictsFile @()
    $runningTasks = @($active | ForEach-Object { $_.task })
    foreach ($cf in @($conflicts)) {
        $pair = @($cf.pair)
        if ($pair -contains $TaskId) {
            $other = @($pair | Where-Object { $_ -ne $TaskId })
            $hit = @($other | Where-Object { $runningTasks -contains $_ })
            if ($hit.Count) {
                return @{ Ok = $false; Holder = ''; Blocking = @($hit)
                          Reason = "пара уже конфликтовала раньше ($($cf.files -join ', '))" }
            }
        }
    }

    return @{ Ok = $true; Reason = 'нет пересечений'; Blocking = @(); Holder = '' }
}

# Заявка едет в git отдельным коммитом, и это не педантизм. Она обязана быть у остальных
# ДО того, как задача начала писать код: заявка, лежащая некоммиченной, ничем не отличается
# от заявки в `.bcf/`. Заодно рабочее дерево остаётся чистым — грязный `tasks/` отменяет
# слияние следующей задачи.
function Publish-BcfClaimChange {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Message,
        # Метаданные прогона — трейлеры коммита (New-BcfCommitMessage, bcf-context.ps1).
        # Пусто = коммит остаётся литеральным $Message без трейлеров, как раньше: заявка
        # и её снятие идут во время прогона (RunId известен графу/планировщику), а
        # `bcf task accept` — действие лидера вне прогона, трейлеров не несёт.
        [string]$Task = '', [string]$RunId = '', [string]$Role = '', [string]$Model = '', [string]$Backend = ''
    )
    $inside = (& git -C $Root rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
    if ($inside -ne 'true') { return @{ Ok = $false; Reason = 'не git-репозиторий' } }
    $id = Get-BcfGitIdentityArgs -Root $Root
    & git -C $Root add -A -- @Paths 2>&1 | Out-Null
    $staged = @(& git -C $Root diff --cached --name-only -- @Paths 2>$null | Where-Object { $_ })
    if (-not $staged.Count) { return @{ Ok = $true; Reason = 'менять нечего' } }
    $msg = if ($RunId) {
        New-BcfCommitMessage -Subject $Message -Task $Task -RunId $RunId -Role $Role -Model $Model -Backend $Backend
    } else {
        $Message
    }
    $out = (& git -C $Root @id commit -q -m $msg -- @Paths 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = $out.Trim() } }
    return @{ Ok = $true; Reason = 'закоммичено' }
}

function Add-TaskClaim {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Root,
        [int]$ProcessId = $PID,
        [switch]$UseCoupling,
        # Сухой план занимает и освобождает заявки, чтобы проверить допуск остальных задач.
        # Коммитить при этом нечего: прогона не было.
        [switch]$Local,
        [string]$Who = '',
        [string]$Branch = '',
        # Метаданные прогона — трейлеры коммита заявки. См. Publish-BcfClaimChange.
        [string]$RunId = '', [string]$Role = '', [string]$Model = '', [string]$Backend = ''
    )
    _With-ClaimsLock {
        $declared = Get-TaskDeclaredFiles -TaskId $TaskId -Root $Root
        $files = @($declared)
        if ($UseCoupling) { $files += Get-CoupledFiles -Files $declared }
        $files = @($files | Select-Object -Unique)

        $who    = if ($Who) { $Who } else { Get-BcfClaimOwner -Root $Root }
        $branch = if ($Branch) { $Branch } else { "bcf/task/$TaskId" }
        $since  = (Get-Date -Format 'o')

        $cacheFile = Get-BcfClaimsCacheFile -Root $Root
        $claims = @(_Read-Json $cacheFile @()) | Where-Object { $_.task -ne $TaskId }
        $claims = @($claims) + @([pscustomobject]@{
            task     = $TaskId
            pid      = $ProcessId
            who      = $who
            branch   = $branch
            files    = @($files)
            declared = @($declared)
            since    = $since
        })
        _Write-Json $cacheFile $claims

        if ($Local) { return }

        $dir = Get-BcfClaimsDir -Root $Root
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $path = Join-Path $dir "$TaskId.md"
        $text = ConvertTo-BcfClaimText -TaskId $TaskId -Who $who -Branch $branch -Files $files -Since $since
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        $rel = ($path.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/'
        Publish-BcfClaimChange -Root $Root -Paths @($rel) -Message "$TaskId — заявка: $who" `
            -Task $TaskId -RunId $RunId -Role $Role -Model $Model -Backend $Backend | Out-Null
    }
}

function Remove-TaskClaim {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Root = '',
        [switch]$Local,
        # Метаданные прогона — трейлеры коммита снятия заявки. См. Publish-BcfClaimChange.
        [string]$RunId = '', [string]$Role = '', [string]$Model = '', [string]$Backend = ''
    )
    if (-not $Root) { $Root = Get-BcfProjectRoot }
    _With-ClaimsLock {
        $cacheFile = Get-BcfClaimsCacheFile -Root $Root
        $claims = @(_Read-Json $cacheFile @()) | Where-Object { $_.task -ne $TaskId }
        _Write-Json $cacheFile @($claims)

        if ($Local) { return }

        $path = Join-Path (Get-BcfClaimsDir -Root $Root) "$TaskId.md"
        if (-not (Test-Path -LiteralPath $path)) { return }
        $rel = ($path.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/'
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Publish-BcfClaimChange -Root $Root -Paths @($rel) -Message "$TaskId — заявка снята" `
            -Task $TaskId -RunId $RunId -Role $Role -Model $Model -Backend $Backend | Out-Null
    }
}

# Факт реального столкновения — в память. Это то, чего не даёт ни worktree, ни лок:
# схема учится на собственных конфликтах.
function Register-TaskConflict {
    param(
        [Parameter(Mandatory)][string[]]$Pair,
        [string[]]$Files = @(),
        [string]$Kind = 'merge'
    )
    _With-ClaimsLock {
        $conflicts = @(_Read-Json $script:ConflictsFile @())
        $conflicts += [pscustomobject]@{
            pair  = @($Pair | Sort-Object)
            files = @($Files)
            kind  = $Kind
            at    = (Get-Date -Format 'o')
        }
        _Write-Json $script:ConflictsFile @($conflicts)
    }
}

function Get-KnownConflicts { return @(_Read-Json $script:ConflictsFile @()) }
