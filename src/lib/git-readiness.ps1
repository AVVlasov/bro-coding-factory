# git-readiness.ps1 — готов ли репозиторий проекта принимать работу ПЕРЕД прогоном.
#
# ЗАЧЕМ. Арбитр слияния устроен так, что оставляет конфликтное дерево незавершённым
# намеренно: Merge-TaskWorktree возвращает conflict-open, маркеры остаются на месте, а
# закончить обязан вызывающий код. Пока процесс жив, это верно. Если он умер между этими
# двумя шагами — а ночной прогон умирает от чего угодно, от разрыва сети до перезагрузки, —
# основное дерево остаётся в MERGING навсегда.
#
# Дальше происходит самое неприятное. Следующий прогон стартует как ни в чём не бывало,
# и у КАЖДОЙ задачи подряд слияние отваливается с причиной «основное дерево грязное».
# Ночь уходит на очередь, где ни одна задача не могла закрыться по причине, не имеющей
# отношения ни к одной из них. Ни doctor, ни старт прогона git-состояние не смотрели:
# в src/commands/doctor.ps1 слово git не встречалось ни разу.
#
# Здесь только замер и словарь причин. Печать и решение «пускать или нет» — у вызывающего:
# так эту функцию можно прогнать в тесте на пустом репозитории, не поднимая CLI.

function Get-BcfGitReadiness {
    param([Parameter(Mandatory)][string]$Root)

    $st = [ordered]@{
        Root            = $Root
        IsRepo          = $false
        GitDir          = ''
        Branch          = ''
        Merging         = $false
        Rebasing        = $false
        Bisecting       = $false
        CherryPicking   = $false
        Conflicts       = @()
        Dirty           = @()
        Untracked       = @()
        TaskWorktrees   = @()
        OrphanWorktrees = @()   # git о дереве знает, каталога на диске нет
        OrphanBranches  = @()   # ветка bcf/task/* есть, рабочего дерева под неё нет
        Blocking        = @()   # прогон стартовать не должен
        Warnings        = @()   # поедет, но часть гарантий не работает
        Fix             = @()   # команды восстановления, по одной на причину
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        $st.Blocking += "каталога проекта нет: $Root"
        return [pscustomobject]$st
    }

    $gitDir = (& git -C $Root rev-parse --git-dir 2>$null | Out-String).Trim()
    if (-not $gitDir) {
        $st.Warnings += 'это не git-репозиторий — изоляция задач по веткам и откат работы недоступны'
        return [pscustomobject]$st
    }
    $st.IsRepo = $true
    # rev-parse отдаёт относительный путь, когда его зовут из корня репозитория.
    if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Root $gitDir }
    $st.GitDir = $gitDir
    $st.Branch = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()

    # Незавершённые операции. Каждая означает «дерево занято», и любая правка поверх
    # такого дерева уедет в чужой коммит.
    $st.Merging       = Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')
    $st.CherryPicking = Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')
    $st.Bisecting     = Test-Path -LiteralPath (Join-Path $gitDir 'BISECT_LOG')
    $st.Rebasing      = (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or
                        (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply'))

    if ($st.Merging) {
        $st.Blocking += 'прошлый прогон оборвался посреди слияния (.git/MERGE_HEAD на месте)'
        $st.Fix += "git -C `"$Root`" merge --abort"
    }
    if ($st.CherryPicking) {
        $st.Blocking += 'дерево занято незавершённым cherry-pick'
        $st.Fix += "git -C `"$Root`" cherry-pick --abort"
    }
    if ($st.Rebasing) {
        $st.Blocking += 'дерево занято незавершённым rebase'
        $st.Fix += "git -C `"$Root`" rebase --abort"
    }
    if ($st.Bisecting) {
        $st.Warnings += 'идёт git bisect — HEAD стоит не там, где думает прогон'
        $st.Fix += "git -C `"$Root`" bisect reset"
    }

    $st.Conflicts = @(& git -C $Root diff --name-only --diff-filter=U 2>$null |
                      ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($st.Conflicts.Count -and -not ($st.Merging -or $st.Rebasing -or $st.CherryPicking)) {
        $st.Blocking += "в дереве остались неразрешённые конфликты: $($st.Conflicts.Count) файл(ов)"
        $st.Fix += "git -C `"$Root`" checkout -- . ; git -C `"$Root`" reset --hard HEAD"
    }

    # Грязь. Это НЕ блокер: одиночный `bcf run loop` идёт прямо в рабочем дереве, и
    # правки человека там законны. Но для режимов, которые сливают ветки задач, грязное
    # дерево означает отказ слияния у каждой задачи подряд — поэтому сказано вслух.
    foreach ($line in @(& git -C $Root status --porcelain 2>$null)) {
        if (-not $line) { continue }
        $code = $line.Substring(0, [Math]::Min(2, $line.Length))
        $path = ($line.Substring([Math]::Min(3, $line.Length))).Trim()
        if ($code -eq '??') { $st.Untracked += $path } else { $st.Dirty += $path }
    }
    if ($st.Dirty.Count) {
        $st.Warnings += "в дереве $($st.Dirty.Count) незакоммиченных изменений — слияние веток задач их отклонит"
    }

    # Осиротевшие рабочие деревья задач.
    #
    # Два разных сиротства, и лечатся они по-разному. Первое: git помнит дерево, а каталога
    # нет — учётная запись мешает создать дерево заново под тем же именем. Второе: ветка
    # bcf/task/* жива, дерева под неё нет — там лежит незакрытая работа задачи, и удалять
    # её молча нельзя.
    $cur = $null; $wts = @()
    foreach ($line in @(& git -C $Root worktree list --porcelain 2>$null)) {
        if ($line -match '^worktree (.+)$')            { $cur = @{ Path = $Matches[1].Trim(); Branch = '' } }
        elseif ($line -match '^branch refs/heads/(.+)$' -and $cur) { $cur.Branch = $Matches[1].Trim() }
        elseif ([string]::IsNullOrWhiteSpace($line) -and $cur)     { $wts += [pscustomobject]$cur; $cur = $null }
    }
    if ($cur) { $wts += [pscustomobject]$cur }

    $st.TaskWorktrees = @($wts | Where-Object { $_.Branch -like 'bcf/task/*' })
    $st.OrphanWorktrees = @($st.TaskWorktrees | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
    if ($st.OrphanWorktrees.Count) {
        $st.Blocking += "git помнит $($st.OrphanWorktrees.Count) рабочих дерев(о) задач, которых нет на диске"
        $st.Fix += "git -C `"$Root`" worktree prune"
    }

    $wtBranches = @($st.TaskWorktrees | ForEach-Object { $_.Branch })
    $st.OrphanBranches = @(& git -C $Root branch --list 'bcf/task/*' --format='%(refname:short)' 2>$null |
                           ForEach-Object { $_.Trim() } |
                           Where-Object { $_ -and $wtBranches -notcontains $_ })
    if ($st.OrphanBranches.Count) {
        $st.Warnings += "веток задач без рабочего дерева: $($st.OrphanBranches.Count) ($($st.OrphanBranches -join ', ')) — там незакрытая работа прошлого прогона"
    }

    return [pscustomobject]$st
}

# Одна печать на две команды: doctor и старт прогона обязаны говорить об одном и том же
# одними и теми же словами, иначе человек чинит по одному тексту, а упирается в другой.
function Write-BcfGitReadiness {
    param([Parameter(Mandatory)]$State, [switch]$Quiet)

    if (-not $State.IsRepo) {
        foreach ($w in $State.Warnings) { Write-BcfWarn $w }
        return
    }
    foreach ($b in $State.Blocking) { Write-BcfFail $b }
    foreach ($w in $State.Warnings) { Write-BcfWarn $w }
    if ($State.Fix.Count) {
        Write-BcfNote 'восстановление:'
        foreach ($f in ($State.Fix | Select-Object -Unique)) { Write-BcfNote "  $f" }
    }
    if (-not $Quiet -and -not $State.Blocking.Count -and -not $State.Warnings.Count) {
        Write-BcfOk "git: ветка $($State.Branch), дерево чистое, осиротевших рабочих дерев нет"
    }
}
