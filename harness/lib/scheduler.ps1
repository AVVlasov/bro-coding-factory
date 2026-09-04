# scheduler.ps1 — параллельное выполнение задач очереди.
#
# Включается только при limits.taskConcurrency > 1; при 1 run-all работает старым
# последовательным путём (его не трогаем — он проверен).
#
# Схема координации (обоснование и цифры — wiki/research/2026-07-26-parallel-agents-file-conflicts.md):
#   1. Задача стартует, если все её гейт-предшественники PASS.
#   2. И если её файлы не пересекаются с уже запущенными (claims.ps1). Это допуск на
#      старте, а НЕ лок на время работы: долгие локи — известный провал (20 агентов →
#      пропускная способность 2–3).
#   3. Каждая задача работает в своём git worktree: изоляция редактирования.
#   4. По PASS — слияние в основную ветку. Конфликт → задача уходит человеку, а пара
#      запоминается: планировщик больше не сведёт её в параллель.
#   5. Обязательные проверки уже прогнаны в worktree, но семантику ловит только
#      слитое дерево — поэтому после слияния гоняем их ещё раз.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')

# ---------------------------------------------------------------------------
# ПРОВЕРКА НА СЛИТОМ ДЕРЕВЕ: ТРИ ИСХОДА, А НЕ ДВА
# ---------------------------------------------------------------------------
#
# Здесь стояло `Invoke-Expression "$cmd 2>&1" | Out-Null; if ($LASTEXITCODE -ne 0)`.
# В pwsh 7 несуществующая команда печатает ошибку и НЕ трогает $LASTEXITCODE: там
# остаётся ноль от предыдущего вызова git. Замер 2026-09-02 на этой машине, дословный
# кусок того цикла — первая проверка зелёная, вторая `mvn -q -DskipTests verify` (maven
# не установлен):
#
#     mergeOk = True  (LASTEXITCODE=0)
#     VERDICT: merged into main and counted as PASS -- the gate never ran
#
# То есть гейт, который не смог запуститься, читался как зелёный, задача уезжала
# в основную ветку и попадала в PASS. Хуже того, код липкий в обе стороны: после
# красной проверки следующая наследовала её ненулевой код и краснела без причины.
#
# Лечится двумя вещами сразу.
#   1. Команда исполняется дочерним процессом pwsh — у процесса код возврата есть всегда,
#      наследовать чужой ему неоткуда. Так это и сделано в графе (Invoke-CommandNode).
#   2. Перед запуском смотрим Get-Command: «команды нет» — это отдельный исход, не
#      «проверка красная». Провал одинаковый, а чинят их по-разному: красную проверку
#      чинит агент, ненайденную команду — тот, кто ставил окружение.
#
# Исходов четыре: green, red, not-runnable, timeout. Зелёный — только первый.

# Имя программы = первый токен команды. В кавычках — до закрывающей кавычки: путь со
# пробелами это норма для Windows. Пустая строка означает «разобрать не удалось»
# (конвейер, подстановка, вызов через &) — тогда пробы не будет, а код вернёт процесс.
function Get-MergeCheckExecutable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    $c = $Command.Trim()
    if (-not $c) { return '' }
    if ($c[0] -eq '"' -or $c[0] -eq "'") {
        $q = $c[0]
        $end = $c.IndexOf($q, 1)
        if ($end -lt 0) { return '' }
        return $c.Substring(1, $end - 1)
    }
    $first = ($c -split '\s+')[0]
    # Всё, что начинается со служебного символа, разбору не поддаётся: это уже язык,
    # а не имя программы.
    if ($first -match '^[&|$(){}@;]') { return '' }
    # Ключевое слово языка — тоже не программа. Без этой строки проверка вида
    # `if (Test-Path ./gradlew) { ... }` объявлялась «не запустилась: if не найдена» и
    # проваливала задачу, ни разу не запустившись: ложный красный вместо ложного зелёного,
    # то есть тот же дефект с другого конца.
    if ($first -in @('if', 'else', 'elseif', 'switch', 'for', 'foreach', 'while', 'do',
                     'try', 'catch', 'finally', 'throw', 'return', 'exit', 'param',
                     'function', 'begin', 'process', 'end', 'trap', 'break', 'continue')) { return '' }
    return $first
}

function Invoke-MergeCheck {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Command,
        [Parameter(Mandatory)][string]$WorkDir,
        [int]$TimeoutSec = 1800
    )

    $exe = Get-MergeCheckExecutable $Command
    if ($exe) {
        # Относительный путь («./gradlew») обязан резолвиться от дерева, где идёт
        # проверка, а не от каталога, в котором случайно стоит процесс планировщика.
        $found = $false
        Push-Location -LiteralPath $WorkDir
        try {
            $found = [bool](Get-Command -Name $exe -ErrorAction SilentlyContinue)
            if (-not $found -and (Test-Path -LiteralPath $exe)) { $found = $true }
        } finally { Pop-Location }
        if (-not $found) {
            return @{
                Ok       = $false
                Kind     = 'not-runnable'
                ExitCode = -2
                Reason   = "проверка не запустилась: «$exe» не найдена ни в PATH, ни в дереве"
                Output   = ''
            }
        }
    }

    # Код возврата дочернего pwsh сам по себе врёт в обе стороны, и обе замерены
    # 2026-09-04 на pwsh 7.6.5 (`pwsh -NoProfile -NonInteractive -Command <строка>`):
    #
    #   cmd /c exit 7   → 1     настоящий код теряется, в отчёте «код 1»
    #   Write-Error     → 1     верно
    #   no-such-cmd     → 1     верно
    #
    # Наивное лечение первой строки — дописать `; exit $LASTEXITCODE` — чинит семёрку и
    # ЛОМАЕТ две нижние: там $LASTEXITCODE остаётся $null, `exit $null` даёт 0, и мы
    # возвращаемся ровно к тому fail-open, ради которого всё это писалось (замерено там же:
    # no-such-cmd → 0, Write-Error → 0). Поэтому хвост смотрит на $? первым и падает
    # в 1 всюду, где судить не по чему. Восемь случаев после правки: exit 7 → 7,
    # exit 0 → 0, throw → 1, Write-Error → 1, неизвестная команда → 1, чистый cmdlet → 0,
    # «ок, потом падение» → 3, «падение, потом ок» → 0.
    $tailCode = '; exit $(if ($? -and ($null -eq $LASTEXITCODE -or $LASTEXITCODE -eq 0)) ' +
                '{ 0 } elseif ($LASTEXITCODE) { $LASTEXITCODE } else { 1 })'

    # Кодировка потоков задаётся с обеих сторон: дочерний pwsh пишет в UTF-8, родитель в
    # UTF-8 читает. Иначе русский текст сборки приезжает вопросительными знаками.
    $encPrefix = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; ' +
                 '$OutputEncoding = [System.Text.Encoding]::UTF8; '

    # ПОЧЕМУ НЕ Start-Process -NoNewWindow.
    #
    # Дочерний процесс наследовал бы консоль вызывающего, и вывод проверки возвращался бы
    # порченым дважды. Замерено 2026-09-04: строка «сборка упала на модуле auth» приехала
    # из такого процесса пятью строками по одному слову (перенос по ширине консоли,
    # в которой шёл прогон) и в кодировке консоли, то есть кириллица — вопросительными
    # знаками. Причина отката слияния — это то немногое, что человек читает утром; в таком
    # виде она бесполезна. Без консоли PowerShell берёт свою ширину по умолчанию, а
    # кодировку потоков задаём мы сами.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    foreach ($a in @('-NoProfile', '-NonInteractive', '-Command', ($encPrefix + $Command + $tailCode))) {
        [void]$psi.ArgumentList.Add($a)
    }
    $psi.WorkingDirectory         = $WorkDir
    $psi.UseShellExecute          = $false
    $psi.CreateNoWindow           = $true
    $psi.RedirectStandardOutput   = $true
    $psi.RedirectStandardError    = $true
    $psi.StandardOutputEncoding   = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding    = [System.Text.Encoding]::UTF8

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Оба потока читаются одновременно: последовательное чтение вешает пару намертво,
        # как только один из буферов заполнится.
        $tOut = $proc.StandardOutput.ReadToEndAsync()
        $tErr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit(5000) | Out-Null
            return @{ Ok = $false; Kind = 'timeout'; ExitCode = -1; Reason = "проверка не уложилась в ${TimeoutSec}с"; Output = '' }
        }
        $out = ''
        foreach ($t in @($tOut, $tErr)) {
            try { $out += [string]$t.GetAwaiter().GetResult() } catch { }
        }
        $code = $proc.ExitCode
        if ($code -eq 0) { return @{ Ok = $true; Kind = 'green'; ExitCode = 0; Reason = ''; Output = [string]$out } }
        # Хвост вывода в причине: раньше он уходил в Out-Null целиком, и «проверки
        # красные» было всё, что человек узнавал о причине отката слияния.
        $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
        return @{ Ok = $false; Kind = 'red'; ExitCode = $code; Reason = "код $code$(if ($tail) { ": $tail" })"; Output = [string]$out }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

# КОНФИГ ПРОВЕРОК — НЕ ЗОНА АГЕНТА, И ЭТО НЕ ЗАВИСИТ ОТ ДЕКЛАРАЦИИ.
#
# config/checks.json — авторитетный источник вердикта: агент, сузивший его до тривиально
# зелёного списка, проходит собственный гейт. Откат по декларации «## Файлы» здесь не
# помогает дважды. Он работает только для файлов, заявленных ДРУГОЙ задачей, а config/ не
# заявлен никем и проезжал проверку целиком; заявить его в своей же секции «## Файлы» тоже
# не выход — тогда он вообще перестаёт считаться чужим. Поэтому откат безусловный.
#
# docs/WORKFLOW.md обещает ровно это: «здесь их задаёт владелец, и агент не может сузить их
# до тривиально зелёных». До сих пор обещание жило только в тексте, и по этому файлу его
# читали как гарантию.
#
# Возвращает список откатанных путей — вызывающий пишет их в отчёт как нарушение скоупа,
# а не как строчку в журнале.
function Undo-AgentConfigEdits {
    param([Parameter(Mandatory)][string]$Worktree)

    $touched = @(& git -C $Worktree status --porcelain 2>$null |
                 ForEach-Object { ($_ -replace '^...', '').Trim() -replace '\\', '/' } |
                 Where-Object { $_ -like 'config/*' })
    foreach ($f in $touched) {
        & git -C $Worktree checkout -- $f 2>&1 | Out-Null
        # Новый файл в config/ откатывать нечем — его удаляем.
        $full = Join-Path $Worktree ($f -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $full) {
            $tracked = (& git -C $Worktree ls-files --error-unmatch $f 2>$null)
            if (-not $tracked) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
        }
    }
    # Запятая обязательна: PowerShell разворачивает массив из одного элемента в строку, и
    # у вызывающего `$undone[0]` вернуло бы первую БУКВУ пути вместо самого пути.
    return , @($touched)
}

function Invoke-ParallelQueue {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Tasks,
        [Parameter(Mandatory)][scriptblock]$IsPass,        # { param($task, $wtPath) } → bool
        [Parameter(Mandatory)][scriptblock]$GatePreds,     # { param($task) } → string[]
        [Parameter(Mandatory)][scriptblock]$LogFn,
        [int]$Concurrency = 2,
        [int]$MaxAgents = 6,
        [int]$PerTaskMax = 40,
        [string]$Model = '',
        [string[]]$MergeChecks = @(),
        # Воспроизводимые сборкой файлы: их грязность в основном дереве не имеет права
        # блокировать слияние (см. Merge-TaskWorktree).
        [string[]]$GeneratedFiles = @(),
        # Сколько задача может не подавать признаков жизни (не писать в свой loop.log)
        # прежде чем её убьют. Должно быть заметно больше самой долгой легитимной паузы
        # (итерация агента + verify), иначе сторож начнёт резать работающие задачи.
        [int]$TaskIdleKillSec = 2400,
        [switch]$DryPlan
    )

    $log = { param($m) & $LogFn $m }

    $pending = [System.Collections.ArrayList]::new()
    foreach ($t in $Tasks) { [void]$pending.Add($t) }
    $running  = [System.Collections.ArrayList]::new()
    $passed   = @()
    $stuck    = @()
    $skipped  = @()   # задачи с исполнителем-человеком: не наши, но и не затык
    $doneSet  = [System.Collections.Generic.HashSet[string]]::new()
    $plan     = @()   # для -DryPlan: решения планировщика без запуска

    # Уже закрытые — сразу в passed.
    foreach ($t in @($pending)) {
        if (& $IsPass $t $Root) {
            & $log "$t — уже verdict: PASS, пропуск."
            $passed += $t; [void]$doneSet.Add($t); $pending.Remove($t)
        }
    }

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        # --- Наполняем до потолка ---
        $launchedThisRound = $false
        foreach ($task in @($pending)) {
            if ($running.Count -ge $Concurrency) { break }
            if (-not (Test-FleetCapacity -MaxAgents $MaxAgents)) {
                & $log "потолок агентов ($MaxAgents) — жду освобождения."
                break
            }

            # 0. Задача человека. Проверяется ЗДЕСЬ, а не только в run-all: планировщик
            # зовут и другие входы (граф очереди, свои обвязки), и они передают список
            # задач напрямую. Пропуск не есть затык: задача не попадает ни в stuck, ни
            # в passed, иначе отчёт назовёт её либо сломанной, либо сделанной.
            $exec = Get-TaskExecutor -TaskId $task -Root $Root
            if ($exec -and -not (Test-BcfExecutorIsFactory $exec)) {
                & $log "$task — пропущена: исполнитель $exec."
                $plan += [pscustomobject]@{ task = $task; admitted = $false; reason = "исполнитель $exec" }
                $skipped += [pscustomobject]@{ Task = $task; Executor = $exec }
                $pending.Remove($task)
                [void]$doneSet.Add($task)
                continue
            }

            # 1. Гейты зависимостей.
            $preds = @(& $GatePreds $task)
            $pendingPreds = @($preds | Where-Object { -not (& $IsPass $_ $Root) })
            if ($pendingPreds.Count) { continue }

            # 2. Допуск по файлам.
            $adm = Test-TaskAdmission -TaskId $task -Root $Root -UseCoupling
            if (-not $adm.Ok) {
                if ($running.Count -eq 0 -and $pending.Count -eq 1) {
                    # Единственная оставшаяся задача, блокировать некому — пускаем.
                    & $log "$task — допуск не нужен (одна в очереди)."
                } else {
                    $plan += [pscustomobject]@{ task = $task; admitted = $false; reason = $adm.Reason }
                    continue
                }
            }
            $plan += [pscustomobject]@{ task = $task; admitted = $true; reason = 'ok' }
            $pending.Remove($task)
            $launchedThisRound = $true

            if ($DryPlan) {
                # В режиме плана «запускаем» мгновенно: занимаем заявку, чтобы
                # следующие задачи проверялись против неё, и сразу освобождаем.
                Add-TaskClaim -TaskId $task -Root $Root -UseCoupling
                [void]$running.Add(@{ Task = $task; Dry = $true })
                continue
            }

            # 3. Worktree + запуск.
            $wt = New-TaskWorktree -Root $Root -Task $task
            if (-not $wt) {
                & $log "$task — не удалось создать worktree, задача пропущена."
                $stuck += [pscustomobject]@{ Task = $task; Reason = 'worktree не создан' }
                [void]$doneSet.Add($task)
                continue
            }
            Add-TaskClaim -TaskId $task -Root $Root -UseCoupling

            $loopPs1 = Join-Path (Get-BcfHarnessRoot) 'loop.ps1'
            $args = @('-NoProfile', '-File', $loopPs1, $task, '-AutoAdvance', '-ProjectRoot', $wt)
            if ($Model) { $args += @('-Model', $Model) }
            $proc = Start-Process -FilePath 'pwsh' -ArgumentList $args `
                -WorkingDirectory $wt -PassThru -WindowStyle Minimized
            Register-FleetWorker -Id "task-$task" -Role 'runner' -Task $task -Model $Model `
                -ProcessId $proc.Id -Detail "worktree $wt"
            & $log "$task — запущена в worktree (pid $($proc.Id)); параллельно сейчас $($running.Count + 1)."
            [void]$running.Add(@{ Task = $task; Proc = $proc; Worktree = $wt })
        }

        if ($DryPlan) {
            foreach ($r in @($running)) {
                Remove-TaskClaim -TaskId $r.Task
                $running.Remove($r)
                [void]$doneSet.Add($r.Task)
                $passed += $r.Task
            }
            if (-not $launchedThisRound -and $pending.Count -gt 0) {
                foreach ($t in @($pending)) {
                    $stuck += [pscustomobject]@{ Task = $t; Reason = 'не допущена к параллельному запуску' }
                    $pending.Remove($t)
                }
            }
            continue
        }

        if ($running.Count -eq 0 -and -not $launchedThisRound -and $pending.Count -gt 0) {
            # Никто не бежит и никого нельзя запустить — тупик по гейтам.
            # Имя предшественника обязано быть В ПРИЧИНЕ: по ней Resolve-Root сводит
            # каскад к корню. Без имени каждая заблокированная задача выглядела
            # собственным корнем, и отчёт предлагал чинить следствия вместо причины.
            foreach ($t in @($pending)) {
                $pend = @(& $GatePreds $t | Where-Object { -not (& $IsPass $_ $Root) })
                $stuck += [pscustomobject]@{ Task = $t; Reason = "gate-block: предшественник $($pend -join ', ') не закрыт (не запускался)" }
                $pending.Remove($t)
            }
            break
        }

        Start-Sleep -Seconds 3

        # --- Сторож зависших задач ---
        #
        # Таймауты внутри loop.ps1 стерегут АГЕНТА, а не сам цикл. Наблюдалось живьём:
        # TASK-06 простояла 1.5 часа с нулевым CPU, без единого дочернего процесса и без
        # новых строк в своём логе — цикл заблокировался сам (скрытое модальное окно либо
        # аналогичное ожидание), и убить его было некому. Здесь сторож смотрит на признак
        # жизни задачи снаружи: растёт ли её loop.log.
        foreach ($r in @($running)) {
            if ($r.Proc.HasExited) { continue }
            $taskLog = Join-Path $r.Worktree '.bcf\loop.log'
            $stampNow = if (Test-Path $taskLog) { (Get-Item $taskLog).LastWriteTimeUtc } else { $r.Started }
            if (-not $r.ContainsKey('LastLogStamp') -or $stampNow -gt $r.LastLogStamp) {
                $r.LastLogStamp = $stampNow
                continue
            }
            $idle = [int]((Get-Date).ToUniversalTime() - $r.LastLogStamp).TotalSeconds
            if ($idle -ge $TaskIdleKillSec) {
                & $log "$($r.Task) — ЗАВИСЛА: нет активности в её логе $idle с. Убиваю (порог $TaskIdleKillSec с)."
                try { $r.Proc.Kill($true) } catch { }
                $r.Proc.WaitForExit(5000) | Out-Null
            }
        }

        # --- Собираем завершившихся ---
        foreach ($r in @($running)) {
            if (-not $r.Proc.HasExited) { continue }
            $running.Remove($r)
            $task = $r.Task
            Unregister-FleetWorker -Id "task-$task"
            Update-FleetHeartbeat -Id "task-$task"

            $isPass = & $IsPass $task $r.Worktree
            if (-not $isPass) {
                & $log "$task — не закрыта в worktree, слияния не будет."
                $stuck += [pscustomobject]@{ Task = $task; Reason = 'не достиг PASS (лимит/затык)' }
                Remove-TaskClaim -TaskId $task
                Remove-TaskWorktree -Root $Root -Task $task -KeepBranch
                [void]$doneSet.Add($task)
                continue
            }

            # Проверка границ: агент обязан править только объявленные файлы. Наблюдалось
            # живьём — задача с единственным файлом `probe.rs` полезла в общий `lib.rs`,
            # который параллельная задача может править в тот же момент. Ловим до слияния.
            $declared = Get-TaskDeclaredFiles -TaskId $task -Root $Root
            $touched = @(& git -C $r.Worktree status --porcelain |
                         ForEach-Object { ($_ -replace '^...', '').Trim() -replace '\\', '/' } |
                         Where-Object { $_ -and $_ -notlike 'tasks/*' -and $_ -notlike '.bcf/*' })
            $outside = @($touched | Where-Object { $declared -notcontains $_ })
            if ($outside.Count) {
                & $log "$task — ВЫХОД ЗА ДЕКЛАРАЦИЮ: тронуты файлы вне «## Файлы» — $($outside -join ', ')."
                Register-TaskConflict -Pair @($task, '(декларация)') -Files $outside -Kind 'scope-violation'

                # Манифесты и локи трогать законно (добавили зависимость), а вот файл,
                # закреплённый за ДРУГОЙ задачей, — нет: именно так три UI-задачи подряд
                # залезли в main.rs, который зарезервирован за задачей CLI-обвязки,
                # и все их слияния встали. Такие правки откатываем в ветке задачи.
                $manifestLike = '(Cargo\.lock|Cargo\.toml|package(-lock)?\.json|tsconfig[^/]*\.json|vitest\.config\.[a-z]+)$'
                $ownedByOthers = @()
                foreach ($f in $outside) {
                    if ($f -match $manifestLike) { continue }
                    foreach ($otherTask in $Tasks) {
                        if ($otherTask -eq $task) { continue }
                        if (@(Get-TaskDeclaredFiles -TaskId $otherTask -Root $Root) -contains $f) {
                            $ownedByOthers += $f; break
                        }
                    }
                }
                if ($ownedByOthers.Count) {
                    & $log "$task — откатываю правки в чужих файлах: $($ownedByOthers -join ', ')."
                    foreach ($f in $ownedByOthers) { & git -C $r.Worktree checkout -- $f 2>&1 | Out-Null }
                }
            }

            $cfgTouched = Undo-AgentConfigEdits -Worktree $r.Worktree
            if ($cfgTouched.Count) {
                & $log "$task — ПРАВКА КОНФИГА ОТКАТАНА: $($cfgTouched -join ', ') — config/ правит владелец, не агент."
                Register-TaskConflict -Pair @($task, '(config)') -Files $cfgTouched -Kind 'config-violation'
            }

            # Коммитим работу задачи в её ветке — без этого сливать нечего.
            & git -C $r.Worktree add -A 2>&1 | Out-Null
            & git -C $r.Worktree -c user.name=ralph -c user.email=ralph@local `
                commit -m "${task}: работа агента (авто-коммит перед слиянием)" 2>&1 | Out-Null

            $merge = Merge-TaskWorktree -Root $Root -Task $task -GeneratedFiles $GeneratedFiles
            if (-not $merge.Ok) {
                # Причина важнее факта: «конфликт файлов», «git отверг слияние» и
                # «дерево грязное» чинятся совершенно по-разному.
                $why = if ($merge.Conflicts.Count) { "конфликт файлов: $($merge.Conflicts -join ', ')" }
                       elseif ($merge.Kind -eq 'dirty-tree') { $merge.Message }
                       else { "git отверг слияние: $(($merge.Message -split "`r?`n" | Select-Object -First 2) -join ' ')" }
                if ($merge.Conflicts.Count) {
                    $others = @((Get-ActiveClaims) | ForEach-Object { $_.task } | Where-Object { $_ -ne $task })
                    foreach ($o in $others) { Register-TaskConflict -Pair @($task, $o) -Files $merge.Conflicts }
                }
                & $log "$task — СЛИЯНИЕ НЕ УДАЛОСЬ: $why. Ветка сохранена."
                $stuck += [pscustomobject]@{ Task = $task; Reason = "слияние не удалось — $why" }
                Remove-TaskClaim -TaskId $task
                Remove-TaskWorktree -Root $Root -Task $task -KeepBranch
                [void]$doneSet.Add($task)
                continue
            }

            # Семантика ловится только на слитом дереве: текстово чистый мерж ничего
            # не гарантирует (по внешним замерам 5–10% конфликтов именно такие).
            $mergeOk = $true
            $checkFail = $null
            foreach ($cmd in $MergeChecks) {
                & $log "$task — проверка на слитом дереве: $cmd"
                $chk = Invoke-MergeCheck $cmd -WorkDir $Root
                if (-not $chk.Ok) { $mergeOk = $false; $checkFail = @{ Cmd = $cmd; Result = $chk }; break }
            }
            if (-not $mergeOk) {
                & git -C $Root reset --hard HEAD~1 2>&1 | Out-Null
                # Причина названа по исходу: «не запустилась» и «красная» чинят разные люди.
                $reason = if ($checkFail.Result.Kind -eq 'not-runnable') {
                    "гейт не смог запуститься: $($checkFail.Cmd) — $($checkFail.Result.Reason)"
                } elseif ($checkFail.Result.Kind -eq 'timeout') {
                    "гейт не завершился: $($checkFail.Cmd) — $($checkFail.Result.Reason)"
                } else {
                    "семантический конфликт: проверки на слитом дереве красные ($($checkFail.Cmd) — $($checkFail.Result.Reason))"
                }
                & $log "$task — слияние откатано: $reason."
                $stuck += [pscustomobject]@{ Task = $task; Reason = $reason }
                $kind = if ($checkFail.Result.Kind -eq 'red') { 'semantic' } else { 'gate-not-runnable' }
                Register-TaskConflict -Pair @($task, '(слитое дерево)') -Files @() -Kind $kind
            } else {
                & $log "$task — слита в основную ветку."
                $passed += $task
            }
            Remove-TaskClaim -TaskId $task
            Remove-TaskWorktree -Root $Root -Task $task
            [void]$doneSet.Add($task)
        }
    }

    return @{ Passed = $passed; Stuck = $stuck; Plan = $plan; Skipped = $skipped }
}
