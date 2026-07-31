# queue.graph.ps1 — очередь задач как ГРАФ.
#
#   pwsh harness/graph.ps1 queue -DryPlan     план: волны, узлы, роли — без запуска
#   pwsh harness/graph.ps1 queue              боевой прогон
#   pwsh harness/graph.ps1 queue -GraphArgs '["TASK-06","TASK-07"]'   только эти задачи
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ run-all.ps1. run-all — ЦИКЛ: он идёт по очереди многопроходно, и
# «работа задачи» и «её интеграция» — один неделимый шаг. Здесь это разные узлы, и
# между ними нет барьера: TASK-11 сливается и проверяется, пока TASK-06 ещё пишет код.
# Кроме того, тут появляются два узла, которых в цикле не было вовсе:
#
#   · АРБИТР слияния. Конфликт больше не равен «задача уходит человеку»: маркеры
#     остаются в дереве, и их сводит отдельный агент. Прежний путь — merge --abort —
#     стирал единственный контекст, по которому конфликт вообще разрешим.
#   · РАЗНОРАКУРСНАЯ ПРИЁМКА. Несколько критиков на ОДНОМ слитом дереве, у каждого
#     свой угол. Одинаковые критики на одной модели дают согласованную чушь
#     промышленного масштаба, поэтому ракурсы разные, а не количество больше.
#
# ГРАНИЦА ЧЕСТНОСТИ. Волна — это барьер, и он тут осознанный: готовность задачи зависит
# от того, КАКИЕ предшественники только что закрылись, то есть от перекрёстного
# состояния всей предыдущей волны. Внутри волны барьеров нет.

$Meta = @{
    name        = 'queue'
    description = 'Очередь задач как граф: волны по зависимостям, конвейер «работа → интеграция → приёмка»'
    phases      = @(
        @{ title = 'Разметка';  detail = 'детерминированный DAG + ревизия владения файлами' }
        @{ title = 'Работа';    detail = 'конвейер: агент задачи → слияние (с арбитром) → проверки на слитом дереве' }
        @{ title = 'Приёмка';   detail = 'разноракурсные критики по слитому дереву' }
        @{ title = 'Итог';      detail = 'единый честный отчёт' }
    )
}
if ($GraphMetaOnly) { return }

$root = $script:GraphCtx.Root
$cfg = Get-Content -Raw -LiteralPath (Join-Path $root 'config\harness.json') | ConvertFrom-Json
$prefix = if ($cfg.taskIdPrefix) { [string]$cfg.taskIdPrefix } else { 'TASK' }
$generated = @($cfg.generatedFiles)
$perTaskMax = if ($cfg.limits.maxIterations) { [int]$cfg.limits.maxIterations } else { 40 }
$mergeChecks = @()
try {
    $cj = Get-Content -Raw -LiteralPath (Join-Path $root 'config\checks.json') | ConvertFrom-Json
    if ($cj._default) { $mergeChecks = @($cj._default | Where-Object { $_ -is [string] -and $_.Trim() }) }
} catch { }

# ---------------------------------------------------------------------------
Set-Phase 'Разметка'
# ---------------------------------------------------------------------------
# Всё, что вычислимо, вычисляется кодом. Модель зовут ровно там, где нужна
# интерпретация, — иначе граф платит за угадывание уже известного.

function Get-Verdict([string]$t, [string]$at) {
    $vf = Join-Path $(if ($at) { $at } else { $root }) "tasks\.verdicts\$t.md"
    if (-not (Test-Path $vf)) { return $false }
    return [bool](Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
}

$predRx = [regex]::Escape($prefix) + '-\d+'
$tasks = @()
foreach ($f in (Get-ChildItem (Join-Path $root 'tasks') -Filter "$prefix-*.md" -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($f.Name -notmatch "^$([regex]::Escape($prefix))-(\d+)-") { continue }
    $num = [int]$Matches[1]
    if ($num -eq 0) { continue }
    $id = "$prefix-$($Matches[1])"
    $body = Get-Content -Raw -LiteralPath $f.FullName

    $preds = @()
    $gm = [regex]::Match($body, '(?m)^\*\*Gate-вход[^:]*:\**\s*(.+)$')
    if ($gm.Success -and $gm.Groups[1].Value -notmatch '^\s*нет\b') {
        $preds = @([regex]::Matches($gm.Groups[1].Value, $predRx) | ForEach-Object { $_.Value } | Select-Object -Unique | Where-Object { $_ -ne $id })
    }
    $files = @(Get-TaskDeclaredFiles -TaskId $id -Root $root)
    $tasks += [pscustomobject]@{ Id = $id; Num = $num; Preds = $preds; Files = $files; Pass = (Get-Verdict $id) }
}

# Сузить очередь до переданных на вход задач (если их передали).
$only = @($GraphArgs)
if ($only.Count -and $only[0]) {
    $tasks = @($tasks | Where-Object { $only -contains $_.Id })
    Write-GraphLog "очередь сужена до: $($only -join ', ')"
}
if (-not $tasks.Count) { Write-GraphLog "очередь пуста — задач $prefix-NN в tasks/ нет"; return @{ complete = $false; reason = 'пустая очередь' } }

# Показываем САМ ПЛАН, а не факт того, что он вычислен. «Задач: 1, уже закрыто: 0» —
# отчёт о работе счётчика: он верен всегда и не говорит ничего о том, что сейчас
# произойдёт. Полезно другое — что каждая задача собирается тронуть и чего ждёт.
$closed = @($tasks | Where-Object { $_.Pass }).Count
Write-GraphLog ("к работе: {0}{1}" -f ($tasks.Count - $closed), $(if ($closed) { " (ещё $closed уже закрыто, пропускаю)" } else { '' }))
foreach ($t in ($tasks | Sort-Object Num)) {
    if ($t.Pass) { continue }
    $p = if ($t.Preds.Count) { "ждёт $($t.Preds -join ', ')" } else { 'готова' }
    $f = if ($t.Files.Count) { $t.Files -join ', ' } else { 'ФАЙЛЫ НЕ ОБЪЯВЛЕНЫ' }
    Write-GraphLog ("  {0}  {1}; правит {2}" -f $t.Id, $p, $f)
}

# Владение файлами — та самая мина, которая ломала прогоны: три UI-задачи подряд
# лезли в файл, закреплённый за четвёртой. Ловим ДО запуска, а не по факту слияния.
$owner = @{}
$collisions = @()
foreach ($t in $tasks) {
    foreach ($fl in $t.Files) {
        if ($owner.ContainsKey($fl)) { $collisions += "$fl — $($owner[$fl]) и $($t.Id)" }
        else { $owner[$fl] = $t.Id }
    }
}
$undeclared = @($tasks | Where-Object { -not $_.Files.Count } | ForEach-Object { $_.Id })

if ($collisions.Count -or $undeclared.Count) {
    $planPrompt = @"
Ты — планировщик очереди. Твоя работа — НЕ писать код, а решить, безопасно ли пускать
эти задачи параллельно, и если нет — как их развести.

Разметка очереди (вычислена детерминированно, ей можно верить):
$($tasks | ForEach-Object { "  $($_.Id): предшественники [$($_.Preds -join ' ')]; файлы [$($_.Files -join ' ')]" } | Out-String)

Обнаружено:
- Пересечения владения файлами: $(if ($collisions.Count) { $collisions -join '; ' } else { 'нет' })
- Задачи без объявленных файлов (их нельзя допустить к параллели, владение неизвестно): $(if ($undeclared.Count) { $undeclared -join ', ' } else { 'нет' })

Верни решение: какие задачи ОБЯЗАНЫ идти строго последовательно и почему.
Учитывай смысл файлов, а не только совпадение имён.
"@
    $schema = @{
        type = 'object'; required = @('serialize', 'verdict')
        properties = @{
            verdict   = @{ type = 'string'; enum = @('ok', 'risky') }
            serialize = @{ type = 'array'; items = @{ type = 'object'; required = @('tasks', 'why')
                           properties = @{ tasks = @{ type = 'array'; items = @{ type = 'string' } }; why = @{ type = 'string' } } } }
        }
    }
    $plan = Invoke-Node -Prompt $planPrompt -Label 'ревизия-плана' -Role planner -Schema $schema -Recall
    if ($plan) {
        Write-GraphLog "планировщик: вердикт '$($plan.verdict)', групп на последовательный прогон — $(@($plan.serialize).Count)"
        foreach ($g in @($plan.serialize)) { Write-GraphLog "  строго последовательно: $($g.tasks -join ' → ') — $($g.why)" }
        Set-GraphVar serialize @($plan.serialize)
    }
} elseif ($tasks.Count -gt 1) {
    Write-GraphLog "владение файлами непротиворечиво — ревизия плана не нужна, узел не запускается"
}
# При одной задаче пересекаться не с чем, и сообщать об этом нечего: строка
# «непротиворечиво» звучала бы как результат проверки, которой не было.

# ---------------------------------------------------------------------------
Set-Phase 'Работа'
# ---------------------------------------------------------------------------
Set-GraphVar generated   $generated
Set-GraphVar mergeChecks $mergeChecks
Set-GraphVar perTaskMax  $perTaskMax
Set-GraphVar root        $root

$done = @{}
$passed = @()
$stuck = @()
foreach ($t in $tasks) { if ($t.Pass) { $done[$t.Id] = $true; $passed += $t.Id } }

# Задача без объявленных файлов к работе НЕ допускается — и отказ выдаётся здесь, до
# первого потраченного токена. Допуск на старте держится на декларации владения: без неё
# проверить, что задача не залезет в чужой файл, нечем, и расползание скоупа обнаружится
# только на слиянии, когда работа уже сделана и её придётся выбрасывать. Раньше такая
# задача проходила дальше и роняла ветку конвейера привязкой параметра — то есть тем же
# отказом, но без причины и посреди волны.
foreach ($t in $tasks) {
    if ($done.ContainsKey($t.Id) -or $t.Files.Count) { continue }
    $done[$t.Id] = $true
    $stuck += [pscustomobject]@{ Task = $t.Id
        Reason = 'файлы не объявлены: в задаче нет списка в секции «## Файлы», поэтому владение неизвестно и допуск не работает' }
    Write-GraphLog "✗ $($t.Id): файлы не объявлены — к работе не допущена"
}

$wave = 0
while ($true) {
    $ready = @($tasks | Where-Object {
        -not $done.ContainsKey($_.Id) -and
        @($_.Preds | Where-Object { -not (Get-Verdict $_) }).Count -eq 0
    })
    if (-not $ready.Count) { break }

    # Задачи, которые планировщик развёл по разным волнам, режем до одной за волну.
    $ser = @(Get-GraphVar serialize)
    if ($ser.Count) {
        foreach ($g in $ser) {
            $inWave = @($ready | Where-Object { @($g.tasks) -contains $_.Id })
            if ($inWave.Count -gt 1) {
                $keep = $inWave[0].Id
                $ready = @($ready | Where-Object { $_.Id -eq $keep -or @($g.tasks) -notcontains $_.Id })
                Write-GraphLog "волна $($wave + 1): из группы [$($g.tasks -join ' ')] пускаю только $keep"
            }
        }
    }

    $wave++
    Write-GraphLog "волна ${wave}: $($ready.Count) задач параллельно — $(@($ready | ForEach-Object { $_.Id }) -join ', ')"

    # Конвейер: работа → интеграция. Барьера МЕЖДУ стадиями нет — задача, закончившая
    # писать код, идёт сливаться, не дожидаясь соседок по волне.
    $results = Invoke-Pipeline -Items @($ready | ForEach-Object { $_.Id }) -Stages @(
        # --- Стадия 1: сама задача, в своём рабочем дереве ---
        {
            param($prev, $task)
            $root = Get-GraphVar root

            # СУХОЙ ПЛАН НЕ ИМЕЕТ ПРАВА НИЧЕГО СОЗДАВАТЬ.
            #
            # Проверка стоит ЗДЕСЬ, а не только внутри исполнителя узла: worktree и заявка
            # на файлы делаются ДО вызова агента, и no-op внутри Invoke-CommandNode их не
            # отменяет. Наблюдалось живьём: `--dry-plan` на чужом проекте создал каталог
            # worktree рядом с репозиторием и записал claims.json с pid — то есть сухой
            # план заявил файлы, которые потом мешают настоящему прогону. План, меняющий
            # состояние, планом не является.
            if ($script:GraphCtx.DryPlan) {
                $files = @(Get-TaskDeclaredFiles -TaskId $task -Root $root)
                Write-GraphNodePlan -Label "работа-$task" -Phase 'Работа' `
                    -Detail "worktree и заявка на $($files.Count) файлов — в сухом плане не создаются"
                return @{ Task = $task; Ok = $false; Dry = $true; Reason = 'сухой план: узел не исполнялся' }
            }

            $wt = New-TaskWorktree -Root $root -Task $task
            if (-not $wt) { return @{ Task = $task; Ok = $false; Reason = 'worktree не создан' } }
            Add-TaskClaim -TaskId $task -Root $root -UseCoupling
            $max = Get-GraphVar perTaskMax
            # -ProjectRoot ОБЯЗАТЕЛЕН и указывает на worktree задачи.
            #
            # Без него цикл вычисляет корень сам — по текущему каталогу или git-верхушке —
            # и задача расщепляется надвое: агент правит файлы в worktree, а цикл считает
            # своим корнем ОСНОВНОЕ дерево, куда пишет вердикт и STATE.md и куда направляет
            # git-операции и авто-откат, пока это дерево принадлежит другой задаче.
            #
            # Наблюдалось живьём (2026-07-30): задача отработала и получила verdict PASS,
            # но вердикт лёг в основное дерево, граф искал его в worktree, не нашёл и
            # объявил «не достиг PASS» — готовая работа выброшена бухгалтерией.
            $loopPs1 = Join-Path (Get-BcfHarnessRoot) 'loop.ps1'
            $r = Invoke-CommandNode "& '$loopPs1' $task -MaxIterations $max -AutoAdvance -ProjectRoot '$wt'" `
                    -Label "работа-$task" -WorkDir $wt -TimeoutSec 14400 -OkExitCodes @(0, 1)
            return @{ Task = $task; Ok = $true; Worktree = $wt; Ran = $r.Ok }
        },

        # --- Стадия 2: интеграция. Ресурс один — основное дерево, поэтому под замком ---
        {
            param($prev, $task)
            $root = Get-GraphVar root
            if (-not $prev.Ok) { return $prev }
            $wt = $prev.Worktree

            # СНАЧАЛА СОХРАНИТЬ, ПОТОМ СУДИТЬ.
            #
            # Коммит делается ДО проверки вердикта, а не после. Иначе незакрытая задача
            # теряет всё: её правки лежат в рабочем каталоге worktree некоммиченными, а
            # ветка сохраняется пустой — и `Remove-TaskWorktree` уносит часы работы агента.
            # Ветка с коммитом стоит ничего, а восстановить из неё можно всё; обратное
            # неверно. Слияние по-прежнему делается только по PASS.
            & git -C $wt add -A 2>&1 | Out-Null
            & git -C $wt -c user.name=ralph -c user.email=ralph@local commit -m "${task}: работа агента" 2>&1 | Out-Null

            $vf = Join-Path $wt "tasks\.verdicts\$task.md"
            $isPass = (Test-Path $vf) -and (Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)

            # Диагностика расщеплённого прогона. Если вердикта в worktree нет, а в
            # основном дереве он есть и он PASS — значит цикл считал своим корнем не то
            # дерево, и «не достиг PASS» будет ЛОЖЬЮ: задача отработала. Молчаливая
            # форма этого стоила полного прогона TASK-11 (2026-07-30), поэтому случай
            # называется явно, а не сваливается в общую причину.
            if (-not $isPass) {
                $vfRoot = Join-Path $root "tasks\.verdicts\$task.md"
                if ((Test-Path $vfRoot) -and (Select-String -Path $vfRoot -Pattern '^verdict:\s*PASS' -Quiet)) {
                    Remove-TaskClaim -TaskId $task
                    Remove-TaskWorktree -Root $root -Task $task -KeepBranch
                    return @{ Task = $task; Ok = $false
                              Reason = "РАСЩЕПЛЁННЫЙ ПРОГОН: вердикт PASS лёг в основное дерево вместо worktree — цикл запущен не из своей копии. Работа задачи не потеряна (ветка bcf/task/$task), но слить её автоматически нельзя." }
                }
            }

            if (-not $isPass) {
                Remove-TaskClaim -TaskId $task
                Remove-TaskWorktree -Root $root -Task $task -KeepBranch
                return @{ Task = $task; Ok = $false; Reason = 'не достиг PASS (лимит/затык)' }
            }

            # Работа уже закоммичена выше, до проверки вердикта — здесь коммитить нечего.
            $outcome = Invoke-WithGraphLock 'merge' {
                $m = Merge-TaskWorktree -Root $root -Task $task -GeneratedFiles (Get-GraphVar generated) -KeepConflictForArbiter

                if (-not $m.Ok -and $m.Kind -eq 'conflict-open') {
                    # АРБИТР. Ему намеренно не дают роль автора ни одной из сторон:
                    # его работа — свести две правки, а не выбрать «свою».
                    Write-GraphLog "$task — конфликт в $($m.Conflicts -join ', '), зову арбитра"
                    $ap = @"
В рабочем дереве идёт слияние ветки задачи $task, и оно встало на конфликте.
Конфликтующие файлы: $($m.Conflicts -join ', ')

Твоя работа — СВЕСТИ обе стороны, а не выбрать одну. Ты не автор ни одной из них.

- Открой каждый файл, найди маркеры <<<<<<< ======= >>>>>>>.
- Пойми НАМЕРЕНИЕ обеих сторон и напиши версию, сохраняющую оба.
- Удали все маркеры. Ничего не коммить и не запускать git — это сделает харнесс.
- Если намерения сторон действительно несовместимы, оставь сторону основной ветки
  и напиши в конце ответа строку: НЕСОВМЕСТИМО: <в чём именно>.
"@
                    Invoke-Node -Prompt $ap -Label "арбитр-$task" -Role arbiter -Recall -RecallScope 'merge' -WorkDir $root -TimeoutSec 1800 | Out-Null
                    $c = Complete-ArbitratedMerge -Root $root -Task $task
                    if ($c.Ok) { $m = @{ Ok = $true; Kind = 'arbitrated'; Conflicts = @(); Message = $c.Message } }
                    else {
                        Undo-ArbitratedMerge -Root $root
                        $m = @{ Ok = $false; Kind = 'conflict'; Conflicts = $m.Conflicts; Message = $c.Message }
                    }
                }

                if (-not $m.Ok) {
                    $why = if ($m.Conflicts.Count) { "конфликт не сведён: $($m.Conflicts -join ', ')" }
                           elseif ($m.Kind -eq 'dirty-tree') { $m.Message }
                           else { "git отверг слияние: $((($m.Message -split "`r?`n") | Select-Object -First 2) -join ' ')" }
                    return @{ Task = $task; Ok = $false; Reason = "слияние не удалось — $why" }
                }

                # Текстово чистый мерж не значит семантически корректный: семантику
                # ловит только СЛИТОЕ дерево, поэтому обязательные проверки — здесь.
                foreach ($cmd in @(Get-GraphVar mergeChecks)) {
                    $chk = Invoke-CommandNode $cmd -Label "слитое-$task-$([Math]::Abs($cmd.GetHashCode()) % 1000)" -WorkDir $root -TimeoutSec 1800
                    if (-not $chk.Ok) {
                        & git -C $root reset --hard HEAD~1 2>&1 | Out-Null
                        return @{ Task = $task; Ok = $false; Reason = 'семантический конфликт: проверки на слитом дереве красные' }
                    }
                }
                return @{ Task = $task; Ok = $true; Arbitrated = ($m.Kind -eq 'arbitrated') }
            }

            Remove-TaskClaim -TaskId $task
            Remove-TaskWorktree -Root $root -Task $task -KeepBranch:(-not $outcome.Ok)
            return $outcome
        }
    )

    # Упавшая ветка конвейера возвращает $null. Раньше такой результат просто
    # пропускался, задача не отмечалась завершённой — и следующая итерация while бралась
    # за неё снова, бесконечно. Прогон при этом выглядел живым: волны шли, счётчик рос.
    # Ветка, которая ничего не вернула, — это ПРОВАЛ, и записывается он как провал.
    $answered = @{}
    foreach ($r in @($results)) {
        if ($null -eq $r) { continue }
        $answered[$r.Task] = $true
        $done[$r.Task] = $true
        if ($r.Ok) {
            $passed += $r.Task
            Write-GraphLog "✓ $($r.Task) слита$(if ($r.Arbitrated) { ' (через арбитра)' })"
        } else {
            $stuck += [pscustomobject]@{ Task = $r.Task; Reason = $r.Reason }
            Write-GraphLog "✗ $($r.Task): $($r.Reason)"

            # ПРОВАЛ — САМЫЙ ЦЕННЫЙ МАТЕРИАЛ, И ИМЕННО ОН РАНЬШЕ ПРОПАДАЛ. Цикл писал
            # уроки только из ретроспектора после вердикта, а до вердикта доходили
            # единицы: на прогоне 2026-07-26 из 14 задач не закрылись 12, и память не
            # выучила из этого ничего. Здесь урок пишется в момент провала.
            $tf = @($tasks | Where-Object { $_.Id -eq $r.Task })[0]
            $res = Add-GraphLesson -Scope 'code' `
                -Trigger "Задача $($r.Task) ($($tf.Files -join ', ')) не закрылась: $($r.Reason)" `
                -WentWrong $r.Reason `
                -Alternative $(switch -Regex ($r.Reason) {
                    'дерев[оa] грязн'   { 'Перед слиянием убирать из основного дерева воспроизводимые файлы (локи, сгенерированные манифесты) — они не несут работы человека и не должны блокировать интеграцию.' }
                    'конфликт'          { 'Файл, объявленный в «## Файлы» другой задачи, не трогать: правку туда вносит владелец файла, иначе слияние встаёт.' }
                    'провер(ки|ка).*красн' { 'Задача обязана проходить обязательные проверки на СЛИТОМ дереве, а не только в своей ветке: текстово чистый мерж семантику не гарантирует.' }
                    default             { '' }
                }) `
                -Evidence @{ task = $r.Task; run = (Get-GraphRunId); files = @($tf.Files); reason = $r.Reason }
            if ($res -eq 'new') { Write-GraphLog "  урок записан в память" }
        }
    }

    foreach ($t in $ready) {
        if ($answered.ContainsKey($t.Id)) { continue }
        $done[$t.Id] = $true
        $stuck += [pscustomobject]@{ Task = $t.Id
            Reason = 'ветка конвейера упала и ничего не вернула — см. журнал прогона (событие «ветка упала»)' }
        Write-GraphLog "✗ $($t.Id): ветка конвейера упала без результата"
    }
}

# Всё, что осталось незакрытым и не запускалось, — заблокировано предшественником.
foreach ($t in $tasks) {
    if ($done.ContainsKey($t.Id)) { continue }
    $pend = @($t.Preds | Where-Object { -not (Get-Verdict $_) })
    $stuck += [pscustomobject]@{ Task = $t.Id; Reason = "gate-block: предшественник $($pend -join ', ') не закрыт (не запускался)" }
}

# ---------------------------------------------------------------------------
Set-Phase 'Приёмка'
# ---------------------------------------------------------------------------
# Барьер здесь ОПРАВДАН: сведение отчёта требует всех ракурсов разом.
# Ракурсы разные намеренно — избыточность ловит меньше, чем непохожесть.
$acceptance = @()
if ($passed.Count) {
    Set-GraphVar merged ($passed -join ', ')
    $acceptance = @(Invoke-Barrier -Thunks @(
        {
            Invoke-Node -Role critic -Recall -Label 'приёмка-инварианты' -Prompt @"
На слитом дереве закрыты задачи: $(Get-GraphVar merged).
Ракурс: ИНВАРИАНТЫ ПРОЕКТА из CLAUDE.md (границы ядра, один JSON в stdout, hex-адреса,
запись только по явному подтверждению, нефатальность ошибок чтения памяти).
Найди нарушения В СЛИТОМ КОДЕ. Каждое — с файлом и строкой. Нет нарушений — так и скажи.
"@
        },
        {
            Invoke-Node -Role critic -Recall -Label 'приёмка-склейка' -Prompt @"
На слитом дереве закрыты задачи: $(Get-GraphVar merged).
Ракурс: СЕМАНТИКА СКЛЕЙКИ. Задачи писались параллельно и разными агентами. Ищи места,
где куски по отдельности верны, а вместе — нет: рассогласованные сигнатуры, дублирующие
реализации одного и того же, несогласованные имена ошибок, мёртвые ветки после слияния.
Каждое — с файлом и строкой. Нет находок — так и скажи.
"@
        },
        {
            Invoke-Node -Role critic -Recall -Label 'приёмка-гейты' -Prompt @"
На слитом дереве закрыты задачи: $(Get-GraphVar merged).
Ракурс: ЧЕСТНОСТЬ ГЕЙТОВ. Проверь тесты этих задач: есть ли среди них такие, что
проходят, ничего не проверяя (ассерт на константу, замоканный объект проверки, тест без
ассертов, `assert!(true)`). Тест, который не проверяет поведение, хуже отсутствующего.
Каждое — с файлом и строкой. Нет находок — так и скажи.
"@
        }
    ))
    foreach ($a in @($acceptance | Where-Object { $_ })) { Write-GraphLog "критик: $((($a -split "`r?`n") | Select-Object -First 1))" }
}

# ---------------------------------------------------------------------------
Set-Phase 'Итог'
# ---------------------------------------------------------------------------
# Отчёт пишет ТА ЖЕ функция, что и у последовательного прогона: две реализации
# «честного итога» разъезжаются, и одна из них начинает врать.
$env:BCF_REPORT_LIB_ONLY = '1'
. (Join-Path (Get-BcfHarnessRoot) 'run-all.ps1')
Remove-Item Env:\BCF_REPORT_LIB_ONLY -ErrorAction SilentlyContinue

# Сухой план не имеет права трогать итог настоящего прогона: в нём НИ ОДНА задача не
# исполнялась, поэтому его «не достиг PASS» — артефакт режима, а не факт. Затерев им
# REVIEW.md, мы бы получили ровно то, против чего весь этот отчёт и сделан, — документ,
# который выглядит как результат работы, не будучи им.
$reviewFile = if ($script:GraphCtx.DryPlan) {
    Join-Path $script:GraphCtx.Dir 'REVIEW.dry.md'
} else {
    Join-Path $root '.bcf\REVIEW.md'
}
$statusFile = if ($script:GraphCtx.DryPlan) { Join-Path $script:GraphCtx.Dir 'run-all.status.dry.json' } else { '' }
$rep = Emit-RunAllReport -Passed $passed -Stuck $stuck -Total $tasks.Count -Root $root `
    -ReviewFile $reviewFile -StatusFile $statusFile -Ts (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

if ($acceptance.Count) {
    $body = "`n## Приёмка графа (разные ракурсы, слитое дерево)`n`n" +
            (@($acceptance | Where-Object { $_ }) -join "`n`n---`n`n")
    Add-Content -Path $reviewFile -Value $body -Encoding UTF8
}

Write-GraphLog "итог: PASS $($rep.passed)/$($rep.total), не закрыто $($rep.stuck) (человек: $($rep.needsHuman), каскад: $($rep.gateBlocked))"
return @{ complete = $rep.complete; passed = $rep.passed; total = $rep.total; stuck = $rep.stuck; waves = $wave }

