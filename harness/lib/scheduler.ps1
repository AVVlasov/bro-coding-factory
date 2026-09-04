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
            foreach ($cmd in $MergeChecks) {
                & $log "$task — проверка на слитом дереве: $cmd"
                Invoke-Expression "$cmd 2>&1" | Out-Null
                if ($LASTEXITCODE -ne 0) { $mergeOk = $false; break }
            }
            if (-not $mergeOk) {
                & git -C $Root reset --hard HEAD~1 2>&1 | Out-Null
                & $log "$task — слияние откатано: обязательные проверки на слитом дереве красные."
                $stuck += [pscustomobject]@{ Task = $task; Reason = 'семантический конфликт: проверки на слитом дереве красные' }
                Register-TaskConflict -Pair @($task, '(слитое дерево)') -Files @() -Kind 'semantic'
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
