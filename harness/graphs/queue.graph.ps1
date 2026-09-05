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

    # Разбор предшественников — общей функцией (harness/lib/claims.ps1), той же, что у
    # цикла и у CLI. Собственная копия регекспа здесь однажды разъедется с ними, и
    # разъедется молча: каждый разборщик по отдельности работает.
    $preds = @(Get-TaskPredecessors -TaskId $id -Root $root -Prefix $prefix)
    $files = @(Get-TaskDeclaredFiles -TaskId $id -Root $root)
    $tasks += [pscustomobject]@{ Id = $id; Num = $num; Preds = $preds; Files = $files; Pass = (Get-Verdict $id) }
}

# --- Задачи человека в граф не входят ---
#
# Тот же вопрос и той же функцией, что у цикла (harness/run-all.ps1): строка
# «Исполнитель: <имя>» — решение, а не пометка для глаз. Граф собирает очередь сам, и
# пока он этой функции не звал, `bcf run queue` брал в работу задачу, которую цикл уже
# не брал: одна и та же задача была занята человеком и одновременно уезжала агенту.
#
# Отсев стоит ДО сужения по -GraphArgs: явно названная в аргументах задача человека —
# такая же задача человека, и запускать её вручную через граф было бы обходом поля.
$humanHeld = @()
$tasks = @($tasks | Where-Object {
    $ex = Get-TaskExecutor -TaskId $_.Id -Root $root
    if ($ex -and -not (Test-BcfExecutorIsFactory $ex)) {
        $humanHeld += [pscustomobject]@{ Task = $_.Id; Executor = $ex }
        $false
    } else { $true }
})
foreach ($h in $humanHeld) { Write-GraphLog "$($h.Task) — пропущена: исполнитель $($h.Executor)." }

# Сузить очередь до переданных на вход задач (если их передали).
$only = @($GraphArgs)
if ($only.Count -and $only[0]) {
    $tasks = @($tasks | Where-Object { $only -contains $_.Id })
    Write-GraphLog "очередь сужена до: $($only -join ', ')"
}
if (-not $tasks.Count) {
    $tail = if ($humanHeld.Count) { " Задач у людей: $($humanHeld.Count) ($(($humanHeld | ForEach-Object { $_.Task }) -join ', '))." } else { '' }
    Write-GraphLog "очередь пуста — задач $prefix-NN в tasks/, которые ведёт фабрика, нет.$tail"
    return @{ complete = $false; reason = 'пустая очередь' }
}

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
#
# ЗАКРЫТЫЕ ЗАДАЧИ В АНАЛИЗЕ НЕ УЧАСТВУЮТ. Они не поедут, значит столкнуться ни с кем не
# могут. Пока они считались наравне со всеми, повторный прогон по бэклогу с исправлениями
# звал ПЛАНИРОВЩИКА (рамочная модель, дорогая) ради разведения задачи с той, что закрыта
# неделю назад: «строго последовательно: TASK-06 → TASK-11» — сериализация, не меняющая
# ничего. То же и с необъявленными файлами: закрытая задача без секции «## Файлы» тянула
# за собой ревизию плана на каждом прогоне.
$owner = @{}
$collisions = @()
foreach ($t in $tasks) {
    if ($t.Pass) { continue }
    foreach ($fl in $t.Files) {
        if ($owner.ContainsKey($fl)) { $collisions += "$fl — $($owner[$fl]) и $($t.Id)" }
        else { $owner[$fl] = $t.Id }
    }
}
$undeclared = @($tasks | Where-Object { -not $_.Pass -and -not $_.Files.Count } | ForEach-Object { $_.Id })

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

            # ВЕРДИКТ ОБЯЗАН ПЕРЕЖИТЬ WORKTREE.
            #
            # Он пишется в дерево задачи (только там проверки честные — там лежит её
            # работа), а каталог вердиктов в .gitignore, то есть слиянием он не переносится
            # и умирает вместе с worktree. Между тем именно по нему считается готовность
            # СЛЕДУЮЩЕЙ волны (Get-Verdict читает корень) и состояние бэклога в `bcf tasks`.
            # Пока копии не было, прогон закрывал первую волну и вставал: остальные задачи
            # навсегда оставались «ждёт», а отчёт называл это «не закрыто» — при том что
            # работа была сделана и слита. Наблюдалось живьём 2026-08-06, прогон
            # g_20260806-141305: TASK-01 слита за 7 минут, восемь задач не поехали.
            #
            # НО PASS ПЕРЕНОСИТСЯ ТОЛЬКО ПОСЛЕ УДАЧНОГО СЛИЯНИЯ.
            #
            # Закрытие — это «работа в основном дереве», а не «в своей ветке всё зелёное».
            # Пока PASS копировался здесь, задача с провалившейся интеграцией объявлялась
            # закрытой: 2026-08-06 TASK-02 и TASK-03 получили PASS в основном дереве, их
            # код туда не попал (слияние упало на красных проверках), и следующая волна
            # честно взялась строить TASK-04 поверх несуществующих стабов.
            #
            # FAIL переносим сразу: он ничего не закрывает, а список ремедиации нужен
            # человеку и следующей попытке. PASS — ниже, после Merge-TaskWorktree.
            $vdirRoot = Join-Path $root 'tasks\.verdicts'
            if ((Test-Path $vf) -and -not $isPass) {
                New-Item -ItemType Directory -Force -Path $vdirRoot | Out-Null
                Copy-Item -LiteralPath $vf -Destination (Join-Path $vdirRoot "$task.md") -Force -ErrorAction SilentlyContinue
            }

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
                # ЗАПИСКА ЧЕЛОВЕКУ ПЕРЕЖИВАЕТ WORKTREE — иначе позвали и промолчали.
                #
                # Цикл встаёт на friction-триггере (необратимая правка: зависимости, CI,
                # авторизация, крупное удаление) и пишет, ЧТО именно требует ревью. Записка
                # лежит в .bcf задачи, а он удаляется вместе с деревом: человек видит
                # «не достиг PASS» и идёт искать причину по логам. Наблюдалось 2026-08-08 —
                # две готовые задачи встали, причину пришлось восстанавливать вручную.
                $reason = 'не достиг PASS (лимит/затык)'
                $co = Join-Path $wt ".bcf\callouts\$task.md"
                if (Test-Path $co) {
                    $codir = Join-Path $root '.bcf\callouts'
                    New-Item -ItemType Directory -Force -Path $codir | Out-Null
                    Copy-Item -LiteralPath $co -Destination (Join-Path $codir "$task.md") -Force -ErrorAction SilentlyContinue
                    $reason = "требует ревью человека — .bcf/callouts/$task.md (правка попала под friction-триггер)"
                }
                Remove-TaskClaim -TaskId $task
                Remove-TaskWorktree -Root $root -Task $task -KeepBranch
                return @{ Task = $task; Ok = $false; Reason = $reason }
            }

            # Работа уже закоммичена выше, до проверки вердикта — здесь коммитить нечего.
            $outcome = Invoke-WithGraphLock 'merge' {
                # Замер «до»: какие сквозные пути работали на основном дереве ДО этого
                # слияния. Ниже он сравнивается с замером «после» — так гейт отличает
                # поломку от предсуществующего долга. Замер снимается ВНУТРИ замка мержа,
                # иначе соседняя задача успеет изменить дерево между замерами.
                $greenBefore = @()
                $jgPre = Join-Path (Get-BcfHarnessRoot) 'journey-gate.ps1'
                if (Test-Path -LiteralPath $jgPre) {
                    $pre = Invoke-CommandNode "pwsh -NoProfile -File `"$jgPre`" -ProjectRoot `"$root`" -Json" `
                              -Label "сценарии-до-$task" -WorkDir $root -TimeoutSec 1800 -OkExitCodes @(0,1,3,4)
                    try {
                        $pj = $pre.Output | ConvertFrom-Json
                        $greenBefore = @($pj.journeys | Where-Object { $_.status -eq 'ok' } | ForEach-Object { [string]$_.id })
                    } catch { }
                }

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

                # СКВОЗНЫЕ СЦЕНАРИИ — ТОЖЕ ГЕЙТ СЛИЯНИЯ, И САМЫЙ ВАЖНЫЙ ИЗ НИХ.
                #
                # Проверки выше — это `_default` задачи: типы и стиль. Они ничего не
                # говорят о том, не сломала ли эта задача чужой путь. Разбор
                # clinic-scheduler показал, чем это кончается: задачи вливались по одной,
                # каждая со своими зелёными гейтами, а сложенные вместе давали продукт,
                # в котором не работал ни один сценарий. Красный сценарий здесь означает
                # ОТКАТ слияния, а не строчку в отчёте в конце прогона: строчку в отчёте
                # читают, когда всё уже слито и разбирать поздно.
                #
                # ГЕЙТ ЛОВИТ РЕГРЕССИЮ, А НЕ ПРЕДСУЩЕСТВУЮЩИЙ ДОЛГ.
                #
                # «Любой красный сценарий = откат» останавливает волну на первой задаче:
                # пока волна не доехала, часть путей красная по определению, и задача,
                # которая к ним не относится, починить их не может. Поэтому сравниваются
                # ДВА замера: какие пути были зелёными до слияния и какие после. Ушедший
                # из зелёных путь — это поломка ИМЕННО этим слиянием, и она откатывается.
                # Красный до и красный после — чужой долг, он не блокирует.
                #
                # Замер «до» снимается на дереве ДО мержа, поэтому обе точки сравнимы.
                $jgScript = Join-Path (Get-BcfHarnessRoot) 'journey-gate.ps1'
                if (Test-Path -LiteralPath $jgScript) {
                    $greenAfter = @()
                    $post = Invoke-CommandNode "pwsh -NoProfile -File `"$jgScript`" -ProjectRoot `"$root`" -Json" `
                                -Label "сценарии-после-$task" -WorkDir $root -TimeoutSec 1800 -OkExitCodes @(0,1,3,4)
                    try {
                        $aj = $post.Output | ConvertFrom-Json
                        $greenAfter = @($aj.journeys | Where-Object { $_.status -eq 'ok' } | ForEach-Object { [string]$_.id })
                    } catch { }
                    $lost = @($greenBefore | Where-Object { $_ -and ($_ -notin $greenAfter) })
                    if ($lost.Count) {
                        & git -C $root reset --hard HEAD~1 2>&1 | Out-Null
                        return @{ Task = $task; Ok = $false
                                  Reason = "слияние сломало работавший сквозной путь: $($lost -join ', ')" }
                    }
                    $gained = @($greenAfter | Where-Object { $_ -and ($_ -notin $greenBefore) })
                    if ($gained.Count) { Write-GraphLog "задача $task закрыла сквозной путь: $($gained -join ', ')" }
                }
                return @{ Task = $task; Ok = $true; Arbitrated = ($m.Kind -eq 'arbitrated') }
            }

            # ВОТ ЗДЕСЬ задача действительно закрыта: её работа в основном дереве и прошла
            # проверки на слитом. Только теперь PASS-вердикт становится фактом проекта —
            # по нему следующая волна считает готовность, а `bcf tasks` показывает закрытое.
            if ($outcome.Ok -and (Test-Path $vf)) {
                New-Item -ItemType Directory -Force -Path $vdirRoot | Out-Null
                Copy-Item -LiteralPath $vf -Destination (Join-Path $vdirRoot "$task.md") -Force -ErrorAction SilentlyContinue
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

            # СОВЕТ ВЫБИРАЕТСЯ ОДИН, И ЭТО НЕ КОСМЕТИКА.
            #
            # `switch -Regex` без break возвращает ВСЕ совпавшие ветки, то есть массив. У
            # причины «семантический конфликт: проверки на слитом дереве красные» совпадают
            # сразу две — и привязка к [string]$Alternative падает с «Cannot convert value
            # to type System.String». Падает не запись урока, а ВЕСЬ граф: прогон
            # g_20260806-143941 умер на этой строке, потеряв обе задачи волны, обе уже
            # сделанные. Побочная запись в память не имеет права ронять прогон.
            $altAll = @(switch -Regex ($r.Reason) {
                'дерев[оa] грязн'      { 'Перед слиянием убирать из основного дерева воспроизводимые файлы (локи, сгенерированные манифесты) — они не несут работы человека и не должны блокировать интеграцию.' }
                'провер(ки|ка).*красн' { 'Задача обязана проходить обязательные проверки на СЛИТОМ дереве, а не только в своей ветке: текстово чистый мерж семантику не гарантирует.' }
                'конфликт'             { 'Файл, объявленный в «## Файлы» другой задачи, не трогать: правку туда вносит владелец файла, иначе слияние встаёт.' }
            })
            # Порядок веток задаёт приоритет: красные проверки конкретнее слова «конфликт»,
            # которое встречается и в их формулировке.
            $alt = [string](@($altAll) | Select-Object -First 1)

            $res = ''
            try {
                $res = Add-GraphLesson -Scope 'code' `
                    -Trigger "Задача $($r.Task) ($($tf.Files -join ', ')) не закрылась: $($r.Reason)" `
                    -WentWrong $r.Reason `
                    -Alternative $alt `
                    -Evidence @{ task = $r.Task; run = (Get-GraphRunId); files = @($tf.Files); reason = $r.Reason }
            } catch {
                # Память — вспомогательная подсистема. Её отказ обязан выглядеть строкой в
                # журнале, а не падением прогона: работа задач уже сделана и лежит в ветках.
                Write-GraphLog "  ⚠ урок в память не записан: $($_.Exception.Message)"
            }
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
#
# ОТВЕТ КРИТИКА — СТРУКТУРА, А НЕ ТОЛЬКО ПРОЗА.
#
# Пока критики отдавали свободный текст, их работа не влияла ни на что: прогон
# g_20260806-195014 напечатал «итог: ок» и вернул ноль, имея в приёмке восемь
# семантических конфликтов, четыре из них P1 — включая «оператор может записать пациента
# в отсутствие врача». Человек читает последнюю строку, а не приложение к ней. Схема даёт
# число, которое можно вынести в вердикт; проза остаётся — она в поле summary.
$criticSchema = @{
    type = 'object'; required = @('summary', 'findings')
    properties = @{
        summary  = @{ type = 'string' }
        findings = @{ type = 'array'; items = @{
            type = 'object'; required = @('severity', 'what', 'file')
            properties = @{
                severity = @{ type = 'string'; enum = @('P1', 'P2', 'P3') }
                what     = @{ type = 'string' }
                file     = @{ type = 'string' }
                line     = @{ type = 'integer' }
            } } }
    }
}
$criticTail = @"

ОТВЕТ — JSON по схеме: summary (проза: что проверял, чем ограничен, вывод) и findings
(массив находок; каждая — severity P1/P2/P3, what, file, line). Ничего не нашёл —
findings пустой массив. P1 — то, из-за чего система работает неверно у пользователя.
"@

#
# ФАКТЫ О ДЕРЕВЕ КРИТИКАМ ДАЁТ ОБВЯЗКА, А НЕ ОНИ САМИ.
#
# Критик живёт на песочнице «только чтение» — это осознанно: роль, обязанная лишь смотреть,
# не должна иметь права править. Но тестовый раннер пишет во временный каталог, поэтому у
# критика он падает с EPERM. Дважды подряд (прогоны g_20260806-151836 и -195014) все три
# критика потратили часть работы на попытки запустить vitest и завершили отчёт оговоркой
# «судил по исходникам». Проверки на слитом дереве обвязка и так умеет запускать — значит
# отдаём результат готовым, а не заставляем добывать.
$gateFacts = ''
if ($passed.Count -and -not $script:GraphCtx.DryPlan) {
    # КАЖДАЯ КОМАНДА ВЫПОЛНЯЕТСЯ ОДИН РАЗ.
    #
    # Проверки разных задач в основном совпадают («vitest run src/pages/operator» стоит у
    # четырёх), а дерево одно — второй запуск той же команды не приносит нового знания и
    # стоит столько же. На бэклоге из 32 задач фаза фактов разрослась до шестидесяти с
    # лишним прогонов и обогнала по времени саму приёмку. Собираем множество команд, а
    # потом выполняем.
    $factCmds = [ordered]@{}
    foreach ($cmd in @(Get-GraphVar mergeChecks)) { if ($cmd) { $factCmds[$cmd] = @() } }
    if ($cj) {
        foreach ($t in $passed) {
            foreach ($cmd in @($cj.$t | Where-Object { $_ -is [string] -and $_.Trim() })) {
                if (-not $factCmds.Contains($cmd)) { $factCmds[$cmd] = @() }
                $factCmds[$cmd] += $t
            }
        }
    }

    $lines = @()
    $i = 0
    foreach ($cmd in @($factCmds.Keys)) {
        $i++
        $owners = @($factCmds[$cmd])
        $r = Invoke-CommandNode $cmd -Label "факты-$i" -WorkDir $root -TimeoutSec 1800
        $who = if ($owners.Count -eq 1) { " ($($owners[0]))" }
               elseif ($owners.Count -gt 1) { " ($($owners.Count) задач)" } else { '' }
        $lines += "- ``$cmd``$who → $(if ($r.Ok) { 'PASS' } else { 'FAIL' })"
    }
    if ($lines.Count) {
        $gateFacts = "`nПРОВЕРКИ НА ЭТОМ ЖЕ ДЕРЕВЕ УЖЕ ВЫПОЛНЕНЫ ОБВЯЗКОЙ (запускать их не нужно,`nу тебя песочница только на чтение):`n" + ($lines -join "`n") + "`n"
        Write-GraphLog "факты для приёмки: $($lines.Count) проверок"
    }

    # СОСТОЯНИЕ СКВОЗНЫХ СЦЕНАРИЕВ — ТОЖЕ ФАКТ, И САМЫЙ ДОРОГОЙ ИЗ НИХ.
    # Все проверки выше говорят о дереве. Эта — о том, может ли человек работать.
    # Критик с песочницей на чтение сам её не выполнит, поэтому отдаём готовой.
    $jgScript = Join-Path (Get-BcfHarnessRoot) 'journey-gate.ps1'
    if (Test-Path -LiteralPath $jgScript) {
        $jgRes = Invoke-CommandNode "pwsh -NoProfile -File `"$jgScript`" -ProjectRoot `"$root`"" -Label 'факты-сценарии' -WorkDir $root -TimeoutSec 1800
        $jgWord = if ($jgRes.Ok) { 'ЗЕЛЁНЫЕ' } else { 'КРАСНЫЕ ИЛИ НЕ ЗАВЕДЕНЫ' }
        $gateFacts += "`nСКВОЗНЫЕ СЦЕНАРИИ ПРОДУКТА (harness/journey-gate.ps1): $jgWord`n"
        Write-GraphLog "факты для приёмки: сквозные сценарии → $jgWord"
    }
}

# Свод приёмки. $null здесь значит «приёмка не запускалась» (сливать было нечего либо
# ни у одного ракурса не нашлось текста), и итог ниже читает именно это, а не ноль находок.
$measure = $null
if ($passed.Count) {
    # РАКУРСЫ — ДАННЫЕ ПРОЕКТА, А НЕ КОД ДВИЖКА.
    #
    # Здесь стояли четыре критика, зашитые строками. Поправить хоть один вопрос можно было
    # только правкой движка, то есть сразу всем проектам; у ракурса не было владельца, и по
    # находке было некого спросить; провал ракурса, заведённого «посмотреть», ронял вердикт
    # наравне с ракурсом, за которым стоит требование заказчика. Теперь состав ракурсов
    # читается из config/review-lenses.json, а текст каждого — из .claude/agents/critics/.
    $lensSet = Get-BcfLenses -Root $root -Kind acceptance
    foreach ($n in @($lensSet.Notes)) { Write-GraphLog "! ракурсы: $n" }
    $lenses = @($lensSet.Lenses)
    Write-GraphLog ("ракурсы приёмки: $($lenses.Count) из $(if ($lensSet.FromProject) { 'config/review-lenses.json' } else { 'умолчания фабрики' })" +
                    ", блокирующих $(@($lenses | Where-Object { $_.Blocking }).Count)")

    # Откуда критику брать инварианты — свойство проекта. Перечисляем реально
    # существующие у него файлы: ссылка на отсутствующий документ читается агентом как
    # «требование есть, но я его не вижу», и он начинает додумывать.
    $invSources = @()
    foreach ($cand in @(
        @{ p = 'config\invariants.json'; d = 'config/invariants.json — если есть, это главный и закрытый список' }
        @{ p = 'CLAUDE.md';              d = 'CLAUDE.md — раздел про правила, которые дороже всего нарушить' }
        @{ p = 'docs\PRD.md';            d = 'docs/PRD.md — границы MVP: то, что объявлено не входящим, не должно появиться в коде' }
        @{ p = 'config\journeys.json';   d = 'config/journeys.json — сквозные сценарии: их поведение тоже инвариант' }
    )) {
        if (Test-Path -LiteralPath (Join-Path $root $cand.p)) { $invSources += "- $($cand.d)" }
    }
    if (-not $invSources.Count) {
        $invSources += '- (ни одного документа с инвариантами в проекте нет — так и скажи в summary и верни пустой список находок: выдумывать инварианты нельзя)'
    }
    # Значения, которые знает прогон, а не файл критика: список документов проекта с
    # инвариантами и перечень закрытых задач. Подставляются в текст ракурса по имени.
    $lensValues = @{
        INVARIANT_SOURCES = ($invSources -join "`n")
        MERGED            = ($passed -join ', ')
    }

    # Текст ракурса берётся из проекта; нет файла — из шаблона фабрики, и об этом строка в
    # журнале. Собирает промпты общая функция (harness/lib/critics.ps1) — та же, что у
    # ревью: две копии сборки разошлись бы молча.
    $built = Build-BcfCriticPrompts -Lenses $lenses -Root $root -Values $lensValues `
                -Header "На слитом дереве закрыты задачи: $($passed -join ', ')." `
                -Tail "$gateFacts$criticTail"
    $lensUsed = @($built.Lenses)
    $prompts = @($built.Prompts)

    if ($lensUsed.Count) {
        # ВЕТКИ БАРЬЕРА ЖИВУТ В ОТДЕЛЬНЫХ ПРОСТРАНСТВАХ И ВИДЯТ ТОЛЬКО GraphVars.
        #
        # Invoke-Barrier пересоздаёт thunk ИЗ ТЕКСТА в другом runspace, поэтому обычные
        # переменные скрипта там просто не существуют: `-Schema $criticSchema` превращался
        # в `-Schema $null` (узел молча возвращал прозу вместо структуры), а блок фактов —
        # в пустую строку. Наблюдалось 2026-08-08: журнал печатал «критик: находок 1»,
        # отчёт — «Находок нет», итог — «ок». Промпт и схему в общее состояние графа
        # кладёт Invoke-BcfCriticBarrier — одним местом на оба графа.
        $acceptance = @(Invoke-BcfCriticBarrier -Lenses $lensUsed -Prompts $prompts -LabelPrefix 'приёмка' -Schema $criticSchema)
        $measure = Measure-BcfAcceptance -Lenses $lensUsed -Answers $acceptance
        foreach ($r in @($measure.Rows)) {
            $kind = if ($r.Lens.Blocking) { 'блокирующий' } else { 'совещательный' }
            if ($r.Ok) {
                Write-GraphLog ("критик $($r.Lens.Id) ($kind): находок $(@($r.Findings).Count)" +
                                $(if ($r.P1) { " (P1: $($r.P1))" } else { '' }))
            } else {
                Write-GraphLog "✗ критик $($r.Lens.Id) ($kind) не ответил"
            }
        }
    } else {
        Write-GraphLog "! приёмка не запускалась: ни у одного ракурса нет текста — ни в проекте, ни в шаблонах фабрики"
    }
}

# КРИТИК, КОТОРЫЙ НЕ ОТВЕТИЛ, — ЭТО НЕ «НАХОДОК НЕТ».
#
# Узел роли возвращает $null, когда агент не дал текста: протух путь к CLI, кончилась
# квота, оборвался поток. Пока это не считалось, отчёт печатал «Находок нет» и итог «ок»
# — при том что приёмка не выполнялась вовсе. Наблюдалось живьём 2026-08-08: у codex
# сменился хэш сборки в пути, все три критика упали по три попытки, а прогон отчитался
# «PASS 19/19, ок». Отсутствие ответа обязано выглядеть отсутствием ответа.
#
# СТРАХОВКА ОТ ПРОЗЫ. Узел со схемой обязан вернуть ОБЪЕКТ; строка означает, что схема до
# него не доехала (например, переменная не пережила границу runspace) и никакой валидации
# не было. Считать такой ответ находками нельзя: `.findings` у строки пусто, и «Находок
# нет» получится из ничего — ровно это и случилось 2026-08-08.
#
# ВЕРДИКТ СЧИТАЕТСЯ ПО БЛОКИРУЮЩИМ РАКУРСАМ. Совещательный ракурс печатается целиком, но
# ни его находки, ни его молчание прогон не роняют: иначе ракурс, заведённый «посмотреть»,
# стоит столько же, сколько требование заказчика, и его перестают заводить.
$findAll = if ($measure) { @($measure.Findings) } else { @() }
$findP1   = @($findAll | Where-Object { $_.severity -eq 'P1' })
$blockP1  = if ($measure) { [int]$measure.BlockingP1 } else { 0 }
$blockAll = if ($measure) { @($measure.Blocking) } else { @() }
$criticsRun    = if ($measure) { [int]$measure.Run } else { 0 }
$criticsFailed = if ($measure) { [int]$measure.BlockingFailed } else { 0 }
$advisoryFailed = if ($measure) { [int]$measure.AdvisoryFailed } else { 0 }
if ($criticsFailed) { Write-GraphLog "⚠ приёмка неполна: не ответило блокирующих ракурсов — $criticsFailed из $criticsRun" }
if ($advisoryFailed) { Write-GraphLog "· не ответило совещательных ракурсов — $advisoryFailed (на вердикт не влияет)" }

# ПРИЁМКА, КОТОРОЙ НЕ БЫЛО, — ЭТО НЕ «ПРИЁМКА БЕЗ НАХОДОК».
#
# У не ответившего критика сигнал есть ($criticsFailed выше). У случая «ни у одного ракурса
# нет текста» его не было: $measure оставался $null, criticsRun и criticsFailed становились
# нулями, в отчёт уезжало «P1 приёмки: 0», и прогон объявлял COMPLETE — при том что смотреть
# было некому. Пока тексты лежали строками в этом файле, случай был невозможен; с переездом
# текстов в проект он появился и выглядит исправным с обоих концов цепочки.
#
# Путь не выдуманный: запись внешней рассылки правил
# {"id":"java","owner":"лидер java","blocking":true,"file":".claude/agents/testers/java.md"}
# при отсутствующем файле тестера даёт ровно ноль промптов — и ни одной строки о том, что
# приёмка не выполнялась.
$acceptanceExpected = [bool]($passed.Count -and -not $script:GraphCtx.DryPlan)
$acceptanceSkipped  = ($acceptanceExpected -and $criticsRun -eq 0)
if ($acceptanceSkipped) {
    Write-GraphLog ("⚠ приёмка НЕ ВЫПОЛНЯЛАСЬ: в дерево слито задач $($passed.Count), " +
                    'а ракурсов с текстом ноль — смотреть было некому')
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
    -ReviewFile $reviewFile -StatusFile $statusFile -Ts (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') `
    -AcceptanceP1 $blockP1 -AcceptanceSkipped:$acceptanceSkipped

# Раздел приёмки пишет общая функция (harness/lib/critics.ps1): тот же раздел собирает
# ревью, и две реализации «как показать находки» разъехались бы на первом же изменении.
if ($measure -and $measure.Run) {
    Add-Content -Path $reviewFile -Value (Format-BcfAcceptanceReport -Measure $measure -Merged ($passed -join ', ')) -Encoding UTF8
}

# НАХОДКА, ОСТАВШАЯСЯ В ОТЧЁТЕ, — ЭТО НЕ ЗАКРЫТАЯ НАХОДКА.
#
# Пять кругов приёмки clinic-scheduler дописали в REVIEW.md 30+ находок, включая P1.
# Каждый круг заканчивался тем, что ЧЕЛОВЕК читал отчёт и руками заводил задачи — и
# каждый следующий прогон начинался с чистого REVIEW.md, затирая то, что не успели
# перенести. Отчёт — это конец жизни находки, а не начало. Дальше P1 уезжают в
# tasks/.inbox/ готовыми черновиками: перенести их в бэклог — одно движение, а
# потерять молча уже нельзя.
#
# Именно ЧЕРНОВИКИ, а не задачи: очередь берёт только tasks/TASK-*.md, и графу не
# отдано право самому назначать себе работу. Решение «это в работу» остаётся за
# человеком; автоматизируется перенос, а не решение.
if ($findP1.Count -and -not $script:GraphCtx.DryPlan) {
    $inbox = Join-Path $root 'tasks\.inbox'
    New-Item -ItemType Directory -Force -Path $inbox | Out-Null
    $runId = Get-GraphRunId
    $i = 0
    $written = @()
    foreach ($f in $findP1) {
        $i++
        $slug = ((([string]$f.what) -replace '[^\p{L}\p{Nd}]+', '-').Trim('-').ToLower())
        if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).Trim('-') }
        if (-not $slug) { $slug = "p1-$i" }
        $file = Join-Path $inbox "$runId-$('{0:d2}' -f $i)-$slug.md"
        $where = "$($f.file)$(if ($f.line) { ":$($f.line)" })"
        $lensWord = if ($f.blocking) { 'блокирующий' } else { 'совещательный' }
        $ownerWord = if ($f.owner) { $f.owner } else { 'владелец не назначен' }
        Set-Content -LiteralPath $file -Encoding UTF8 -Value @"
# Черновик задачи — P1 приёмки $runId

Находка приёмки на слитом дереве. Черновик: перенеси в ``tasks/TASK-<NN>-<slug>.md``,
допиши «Готовность» и «Проверки», добавь id в ``config/checks.json`` — и только тогда
очередь возьмёт её в работу.

Ракурс: $($f.lens) ($lensWord), отвечает $ownerWord.

## Что не так

$($f.what)

## Где

``$where``

## Готовность

1. (дополнить: что должно стать возможным для пользователя)
2. Тест доказывает исправление и падает при возврате прежнего поведения.

## Проверки

``````
(дополнить: команда, доказывающая именно это поведение)
``````
"@
        $written += (Split-Path $file -Leaf)
    }
    Write-GraphLog "черновики задач по P1: $($written.Count) → tasks/.inbox/"
    Add-Content -Path $reviewFile -Encoding UTF8 -Value (
        "`n## P1 переведены в черновики задач`n`n" +
        "Находки P1 не остались в этом отчёте — они лежат готовыми черновиками в ``tasks/.inbox/``:`n`n" +
        (($written | ForEach-Object { "- ``tasks/.inbox/$_``" }) -join "`n") + "`n`n" +
        "Перенеси нужные в ``tasks/TASK-<NN>-<slug>.md`` и добавь их id в ``config/checks.json``.`n")
}

Write-GraphLog ("итог: PASS $($rep.passed)/$($rep.total), не закрыто $($rep.stuck) (человек: $($rep.needsHuman), каскад: $($rep.gateBlocked))" +
                $(if ($findAll.Count) { "; приёмка: находок $($findAll.Count) (блокирующих $($blockAll.Count), P1 $blockP1)" } else { '' }))
# В вердикт прогона уезжают ТОЛЬКО блокирующие ракурсы: `findings` читает graph.ps1 и
# по ним решает, звучит ли слово «ок». Совещательные едут отдельными полями — они видны
# в отчёте и в журнале, но зелёный прогон не краснеет от ракурса, заведённого «посмотреть».
return @{ complete = $rep.complete; passed = $rep.passed; total = $rep.total; stuck = $rep.stuck; waves = $wave
          findings = $blockAll.Count; findingsP1 = $blockP1
          advisory = $(if ($measure) { @($measure.Advisory).Count } else { 0 })
          advisoryP1 = $(if ($measure) { [int]$measure.AdvisoryP1 } else { 0 })
          criticsRun = $criticsRun; criticsFailed = $criticsFailed; advisoryFailed = $advisoryFailed
          # criticsExpected отвечает на вопрос, который ноль в criticsRun сам по себе не
          # различает: приёмка не запускалась потому, что сливать было нечего, или потому,
          # что смотреть было некому. Второе — не зелёный прогон.
          criticsExpected = $acceptanceExpected
          criticsReason = $(if ($acceptanceSkipped) {
              'слито задач ' + $passed.Count + ', а ракурсов с текстом ноль: ни в .claude/agents/critics/, ни в шаблонах фабрики'
          } else { '' }) }

