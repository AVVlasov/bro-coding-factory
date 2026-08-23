# queue.ps1 — очередь задач глазами планировщика. Один проход на всех.
#
# ЗАЧЕМ ОТДЕЛЬНЫМ ФАЙЛОМ. «Сколько задач в очереди, что готово и что с чем сталкивается»
# считают уже несколько экранов: карточка состояния, `bcf tasks`, четвёртый шаг мастера.
# Пока у каждого был свой цикл по tasks/, они расходились МОЛЧА: по отдельности работал
# каждый, а числа на соседних экранах называли разное. Здесь один проход, и он повторяет
# тот, по которому граф строит волны (harness/graphs/queue.graph.ps1).
#
# ГРАНИЦА ЧЕСТНОСТИ. Волны считаются в предположении, что все задачи закроются: это ПЛАН,
# а не прогноз. Задача, чей предшественник не закроется, в волну не попадёт — такие
# перечислены отдельно (Blocked), а не растворены в общем числе.

# Декларации разбираем ТЕМИ ЖЕ функциями, что и планировщик: собственная копия регекспа
# однажды разъедется с ним, и разъедется тихо.
. (Join-Path (Get-BcfHarness) 'lib\claims.ps1')

function Get-BcfQueue {
    param([Parameter(Mandatory)][string]$Project, $Config = $null)

    $cfg = $Config
    if (-not $cfg) { try { $cfg = Get-BcfHarnessConfig -Project $Project } catch { } }

    # Каталоги и префикс — из настройки проекта, а не из умолчания: проект,
    # переопределивший paths, иначе получает ложное «задач нет».
    $prefix      = if ($cfg -and $cfg.taskIdPrefix) { [string]$cfg.taskIdPrefix } else { 'TASK' }
    $tasksRel    = if ($cfg -and $cfg.paths -and $cfg.paths.tasks) { [string]$cfg.paths.tasks } else { 'tasks' }
    $verdictsRel = if ($cfg -and $cfg.paths -and $cfg.paths.verdicts) { [string]$cfg.paths.verdicts } else { "$tasksRel/.verdicts" }
    $tasksDir    = Join-Path $Project ($tasksRel -replace '/', '\')
    $verdictsDir = Join-Path $Project ($verdictsRel -replace '/', '\')

    $tasks = @()
    $exists = Test-Path $tasksDir
    if ($exists) {
        foreach ($f in (Get-ChildItem $tasksDir -Filter "$prefix-*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            # Подзадачи (<PREFIX>-NN.M) в очередь не входят: они срезы родителя, а не
            # самостоятельные единицы планирования.
            if ($f.BaseName -match "^$([regex]::Escape($prefix))-\d+\.\d+") { continue }
            $id = ($f.BaseName -split '-')[0..1] -join '-'
            $body = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue

            $title = ''
            $m = [regex]::Match([string]$body, '(?m)^#\s*(.+)$')
            if ($m.Success) { $title = $m.Groups[1].Value.Trim() }

            $vf = Join-Path $verdictsDir "$id.md"
            $tasks += [pscustomobject]@{
                Id    = $id
                Title = $title
                File  = $f.Name
                Slug  = ($f.BaseName -replace "^$([regex]::Escape($prefix))-\d+-?", '')
                Files = @(Get-TaskDeclaredFiles -TaskId $id -Root $Project)
                Preds = @(Get-TaskPredecessors -TaskId $id -Root $Project -Prefix $prefix)
                Pass  = ((Test-Path $vf) -and (Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet))
                Ready = $false
                # ДВА РАЗНЫХ УСЛОВИЯ, КОТОРЫЕ НЕЛЬЗЯ СКЛЕИВАТЬ В ОДНО СЛОВО.
                #
                # Ready — «предшественники закрыты». Admitted — «владение объявлено», без
                # него граф задачу в волну не берёт. Пока состояние считалось одним только
                # Ready, `bcf tasks` печатал «готова» и советовал `bcf run queue` о задаче,
                # которую тот же самый разбор строкой ниже называл недопущенной, а мастер
                # на шаге 4 — «не допущено: 1». Три экрана об одной задаче говорили разное.
                Admitted = $false
                Runnable = $false
            }
        }
    }

    $passSet = @{}
    foreach ($t in $tasks) { if ($t.Pass) { $passSet[$t.Id] = $true } }
    foreach ($t in $tasks) {
        $t.Ready    = -not $t.Pass -and (@($t.Preds | Where-Object { -not $passSet.ContainsKey($_) }).Count -eq 0)
        $t.Admitted = -not $t.Pass -and [bool]$t.Files.Count
        $t.Runnable = $t.Ready -and $t.Admitted
    }

    # Владение файлами — та самая мина, которую граф ловит ДО запуска. Считается здесь тем
    # же способом: первый объявивший файл им и владеет, остальные — коллизия.
    $owner = @{}
    $collisions = @()
    foreach ($t in $tasks) {
        if ($t.Pass) { continue }
        foreach ($fl in $t.Files) {
            if ($owner.ContainsKey($fl)) { $collisions += "$fl — $($owner[$fl]) и $($t.Id)" }
            else { $owner[$fl] = $t.Id }
        }
    }
    # Задача без объявленных файлов к работе НЕ допускается: владение неизвестно, и
    # проверить, что она не залезет в чужой файл, нечем.
    $undeclared = @($tasks | Where-Object { -not $_.Pass -and -not $_.Files.Count } | ForEach-Object { $_.Id })

    # Волны: те же уровни, что построит граф, — задача идёт, когда все её предшественники
    # закрыты. Допущенными считаются только задачи с объявленными файлами.
    $closed = @{}
    foreach ($t in $tasks) { if ($t.Pass) { $closed[$t.Id] = $true } }
    $pending = @($tasks | Where-Object { -not $_.Pass -and $_.Files.Count })
    $waves = @()
    while ($pending.Count) {
        $wave = @($pending | Where-Object { @($_.Preds | Where-Object { -not $closed.ContainsKey($_) }).Count -eq 0 })
        if (-not $wave.Count) { break }
        $waves += , @($wave | ForEach-Object { $_.Id })
        foreach ($w in $wave) { $closed[$w.Id] = $true }
        $pending = @($pending | Where-Object { -not $closed.ContainsKey($_.Id) })
    }

    return [pscustomobject]@{
        Project     = $Project
        Prefix      = $prefix
        TasksRel    = $tasksRel
        TasksDir    = $tasksDir
        VerdictsDir = $verdictsDir
        Exists      = $exists
        Tasks       = $tasks
        Total       = @($tasks).Count
        Closed      = @($tasks | Where-Object { $_.Pass }).Count
        Open        = @($tasks | Where-Object { -not $_.Pass }).Count
        # «Готово к работе» = поедет прямо сейчас. Задача с закрытыми предшественниками, но
        # без объявленных файлов сюда НЕ попадает: она не поедет, и считать её готовой
        # значит обещать прогон, которого не будет.
        Ready       = @($tasks | Where-Object { $_.Runnable }).Count
        NotAdmitted = @($tasks | Where-Object { $_.Ready -and -not $_.Admitted } | ForEach-Object { $_.Id })
        Admitted    = @($tasks | Where-Object { -not $_.Pass -and $_.Files.Count }).Count
        Collisions  = @($collisions)
        Undeclared  = @($undeclared)
        Waves       = @($waves)
        Blocked     = @($pending | ForEach-Object { $_.Id })
    }
}

# Ракурсы приёмки читаются ИЗ ГРАФА, а не переписываются сюда числом.
#
# «critic ×3» — свойство harness/graphs/queue.graph.ps1, а не мастера. Записанное в
# init константой, оно останется тройкой и после того, как в граф добавят четвёртый
# ракурс: экран настройки будет уверенно называть цифру, которой уже нет.
function Get-BcfCriticAngles {
    $g = Join-Path (Get-BcfHarness) 'graphs\queue.graph.ps1'
    if (-not (Test-Path $g)) { return @() }
    $src = Get-Content -Raw -LiteralPath $g -ErrorAction SilentlyContinue
    if (-not $src) { return @() }
    return @([regex]::Matches([string]$src, "-Label\s+'приёмка-([^']+)'") |
             ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}
