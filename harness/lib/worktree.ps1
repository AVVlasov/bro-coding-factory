# worktree.ps1 — изолированное рабочее дерево на задачу.
#
# Параллельные задачи не могут делить одно рабочее дерево: авто-откат регрессии
# (`git checkout <snap> -- <productPaths>`) вернёт файлы соседа, а два агента,
# правящие один файл, просто затрут друг друга без всякого предупреждения.
#
# ВАЖНО: worktree — это гигиена, а не координация. Он изолирует редактирование, но
# ничего не знает про то, что две ветки правят одни файлы; за это отвечает
# claims.ps1 (допуск на старте). См. wiki/research/2026-07-26-parallel-agents-file-conflicts.md.

function Get-WorktreeRoot {
    param([Parameter(Mandatory)][string]$Root)
    # Рядом с репозиторием, а не внутри: иначе worktree попадёт в собственный git status.
    return (Join-Path (Split-Path $Root -Parent) ((Split-Path $Root -Leaf) + '.wt'))
}

function New-TaskWorktree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task
    )
    $wtRoot = Get-WorktreeRoot -Root $Root
    if (-not (Test-Path $wtRoot)) { New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null }
    $path   = Join-Path $wtRoot $Task
    $branch = "bcf/task/$Task"

    if (Test-Path (Join-Path $path '.git')) { return $path }   # переиспользуем

    $exists = (& git -C $Root branch --list $branch 2>$null | Out-String).Trim()
    if ($exists) {
        & git -C $Root worktree add $path $branch 2>&1 | Out-Null
    } else {
        & git -C $Root worktree add -b $branch $path HEAD 2>&1 | Out-Null
    }
    if (-not (Test-Path (Join-Path $path '.git'))) { return $null }
    return $path
}

# Слить ветку задачи в текущую. Возвращает @{ Ok; Conflicts[]; Message }.
#
# STORM-lite: перед слиянием смотрим, менялись ли в основной ветке те файлы, которые
# трогала задача. Если менялись — не сливаем вслепую, а сообщаем: пусть проверки
# пройдут на СЛИТОМ дереве (текстово чистый мерж не значит семантически корректный —
# по внешним замерам таких конфликтов 5–10%).
function Merge-TaskWorktree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task,
        # Файлы, которые машина восстанавливает сама (локи, сгенерированные манифесты).
        # Их «грязность» не несёт работы человека, поэтому она не имеет права
        # блокировать слияние. Пустой список = старое поведение (отказ на любую грязь).
        [string[]]$GeneratedFiles = @(),
        # Не откатывать конфликтное слияние: оставить маркеры в дереве, чтобы их свёл
        # агент-арбитр. Вызывающий обязан затем позвать Complete-ArbitratedMerge
        # либо Undo-ArbitratedMerge — иначе дерево останется в состоянии MERGING.
        [switch]$KeepConflictForArbiter
    )
    $branch = "bcf/task/$Task"

    # Слияние в ГРЯЗНОЕ дерево git отвергает целиком: «Your local changes … would be
    # overwritten by merge». Конфликтных файлов при этом НЕТ (нет состояния U), и
    # наивный отчёт выглядел как «КОНФЛИКТ СЛИЯНИЯ: » с пустым списком — самая
    # бесполезная диагностика из возможных. Проверяем заранее и называем виновника.
    #
    # ИНЦИДЕНТ 2026-07-26, ради которого появился $GeneratedFiles: единственный
    # изменённый `Cargo.lock` в основном дереве завалил слияние СЕМИ задач подряд.
    # Каждая из них к тому моменту прошла весь путь до PASS в своём worktree — то
    # есть весь бюджет прогона (12 из 14 задач) сгорел из-за лок-файла, который
    # `cargo` перегенерирует за секунду. Отказ на такой грязи — не осторожность, а
    # потеря работы: лок восстанавливается из дерева, работа агента — нет.
    $dirty = @(& git -C $Root status --porcelain 2>$null |
               Where-Object { $_ -notmatch '^\?\?' } |
               ForEach-Object { ($_ -replace '^..\s*', '').Trim() } |
               Where-Object { $_ })
    if ($dirty.Count -and $GeneratedFiles.Count) {
        $parked = @($dirty | Where-Object { $f = $_; @($GeneratedFiles | Where-Object { $f -like $_ }).Count -gt 0 })
        if ($parked.Count) {
            # Откатываем к HEAD именно их: содержимое воспроизводимо сборкой, а
            # держать его дороже, чем потерять.
            foreach ($f in $parked) { & git -C $Root checkout -- $f 2>&1 | Out-Null }
            $dirty = @($dirty | Where-Object { $parked -notcontains $_ })
        }
    }
    if ($dirty.Count) {
        return @{
            Ok = $false; Conflicts = @(); Kind = 'dirty-tree'
            Message = "основное дерево грязное — слияние невозможно: $($dirty -join ', '). Закоммить или отложи эти правки."
        }
    }

    $out = (& git -C $Root merge --no-ff --no-edit $branch 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        return @{ Ok = $true; Conflicts = @(); Kind = 'ok'; Message = $out.Trim() }
    }
    $conflicts = @(& git -C $Root diff --name-only --diff-filter=U 2>$null |
                   ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # Конфликт больше не равен «задача уходит человеку». Если вызывающий готов
    # позвать арбитра, мы ОСТАВЛЯЕМ дерево в конфликтном состоянии: маркеры на
    # месте, обе стороны видны, и агент-арбитр может их свести. Прежний
    # безусловный `merge --abort` стирал единственный контекст, по которому
    # конфликт вообще можно разрешить.
    if ($conflicts.Count -and $KeepConflictForArbiter) {
        return @{ Ok = $false; Conflicts = $conflicts; Kind = 'conflict-open'; Message = $out.Trim() }
    }

    & git -C $Root merge --abort 2>&1 | Out-Null
    $kind = if ($conflicts.Count) { 'conflict' } else { 'refused' }
    return @{ Ok = $false; Conflicts = $conflicts; Kind = $kind; Message = $out.Trim() }
}

# Завершить слияние, которое арбитр свёл вручную. Возвращает $false, если в дереве
# остались неразрешённые маркеры: коммитить полурешённый конфликт — худший исход из
# возможных, потому что он выглядит как успех.
function Complete-ArbitratedMerge {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task
    )
    $left = @(& git -C $Root diff --name-only --diff-filter=U 2>$null |
              ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($left.Count) {
        return @{ Ok = $false; Message = "арбитр не свёл конфликт: осталось $($left -join ', ')" }
    }
    # Маркер конфликта, оставленный в тексте, git-ом не ловится — он ловится только
    # поиском по содержимому. Без этой проверки '<<<<<<<' уезжает в основную ветку.
    $tracked = @(& git -C $Root diff --name-only --cached 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $withMarkers = @()
    foreach ($f in $tracked) {
        $full = Join-Path $Root $f
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if (Select-String -LiteralPath $full -Pattern '^(<<<<<<< |>>>>>>> |=======$)' -Quiet -ErrorAction SilentlyContinue) {
            $withMarkers += $f
        }
    }
    if ($withMarkers.Count) {
        return @{ Ok = $false; Message = "в сведённых файлах остались маркеры конфликта: $($withMarkers -join ', ')" }
    }
    & git -C $Root add -A 2>&1 | Out-Null
    $out = (& git -C $Root -c user.name=ralph -c user.email=ralph@local commit --no-edit 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Message = $out.Trim() } }
    return @{ Ok = $true; Message = $out.Trim() }
}

function Undo-ArbitratedMerge {
    param([Parameter(Mandatory)][string]$Root)
    & git -C $Root merge --abort 2>&1 | Out-Null
}

function Remove-TaskWorktree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task,
        [switch]$KeepBranch
    )
    $wtRoot = Get-WorktreeRoot -Root $Root
    $path = Join-Path $wtRoot $Task
    if (Test-Path $path) { & git -C $Root worktree remove $path --force 2>&1 | Out-Null }
    & git -C $Root worktree prune 2>&1 | Out-Null
    if (-not $KeepBranch) { & git -C $Root branch -D "bcf/task/$Task" 2>&1 | Out-Null }
}

function Get-TaskWorktrees {
    param([Parameter(Mandatory)][string]$Root)
    $raw = (& git -C $Root worktree list --porcelain 2>$null | Out-String) -split "`r?`n"
    $out = @(); $cur = $null
    foreach ($line in $raw) {
        if ($line -match '^worktree (.+)$') { $cur = @{ path = $Matches[1]; branch = '' } }
        elseif ($line -match '^branch refs/heads/(.+)$' -and $cur) { $cur.branch = $Matches[1] }
        elseif ([string]::IsNullOrWhiteSpace($line) -and $cur) { $out += [pscustomobject]$cur; $cur = $null }
    }
    if ($cur) { $out += [pscustomobject]$cur }
    return @($out | Where-Object { $_.branch -like 'bcf/task/*' })
}
