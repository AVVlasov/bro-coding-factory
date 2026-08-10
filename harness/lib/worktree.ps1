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

    # ПЕРЕИСПОЛЬЗУЕМ ТОЛЬКО ТО, ЧТО ПРИЗНАЁТ GIT.
    #
    # Наличие файла `.git` — не доказательство: после снятого прогона каталог остаётся на
    # диске, `git worktree prune` убирает лишь учётную запись, а ветку удаляет слияние. Со
    # стороны это выглядит рабочим деревом, но git о нём не знает. Наблюдалось живьём
    # 2026-08-08: задача «переиспользовала» такой каталог вместе с ЧУЖИМ вердиктом внутри
    # (.bcf в git не попадает и потому пережил всё), цикл прочитал PASS от прошлого прогона
    # и вышел за семь секунд, не сделав ничего, — а слияние потом не нашло ветки.
    if (Test-Path (Join-Path $path '.git')) {
        $known = $false
        try {
            $reg = (& git -C $Root worktree list --porcelain 2>$null | Out-String)
            $needle = ($path -replace '\\', '/')
            $known = ($reg -split "`r?`n" | Where-Object { $_ -like "worktree *" } |
                      ForEach-Object { ($_ -replace '^worktree\s+', '') -replace '\\', '/' }) -contains $needle
        } catch { }
        $branchAlive = [bool]((& git -C $Root branch --list $branch 2>$null | Out-String).Trim())

        if ($known -and $branchAlive) { return $path }   # настоящее дерево задачи

        Write-Host "  ⚠ каталог $path остался от снятого прогона (git его не знает) — пересоздаю" -ForegroundColor Yellow
        & git -C $Root worktree remove --force $path 2>&1 | Out-Null
        Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
        & git -C $Root worktree prune 2>&1 | Out-Null
    }

    $exists = (& git -C $Root branch --list $branch 2>$null | Out-String).Trim()
    if ($exists) {
        & git -C $Root worktree add $path $branch 2>&1 | Out-Null
    } else {
        & git -C $Root worktree add -b $branch $path HEAD 2>&1 | Out-Null
    }
    if (-not (Test-Path (Join-Path $path '.git'))) { return $null }

    # ПЕРЕИСПОЛЬЗОВАННАЯ ВЕТКА ДОГОНЯЕТ ОСНОВНУЮ.
    #
    # Ветка задачи заводится один раз, а прогонов бывает несколько: между ними в основную
    # ветку попадают и другие задачи, и правки владельца. Задача, продолжающая работать на
    # старой базе, проверяется не тем деревом, в которое её потом сольют, и это не
    # теоретическое расхождение. Наблюдалось 2026-08-06: package.json ветки не знал про
    # объявленный в main `typescript`; агент запустил `npm install` — и npm ВЫЧИСТИЛ
    # typescript из общего node_modules как лишний. Гейт `tsc` после этого падал у всех
    # задач волны сразу, включая уже готовые.
    #
    # Слияние, а не rebase: работа агента уже закоммичена, переписывать ей историю нельзя.
    # Конфликт здесь не чиним — задача поедет на своей базе, а сведёт конфликт арбитр на
    # интеграции, у которого для этого есть и роль, и промпт.
    $mainBranch = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($mainBranch -and $mainBranch -ne 'HEAD' -and $mainBranch -ne $branch) {
        $behind = (& git -C $path rev-list --count "HEAD..$mainBranch" 2>$null | Out-String).Trim()
        if ($behind -match '^\d+$' -and [int]$behind -gt 0) {
            $mo = (& git -C $path -c user.name=bcf -c user.email=bcf@local merge --no-edit $mainBranch 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                & git -C $path merge --abort 2>&1 | Out-Null
                Write-Host "  ⚠ ветка $branch не догнала $mainBranch (конфликт) — задача идёт на своей базе, сведение останется арбитру" -ForegroundColor Yellow
            } else {
                Write-Host "  · ветка $branch догнала $mainBranch (+$behind)" -ForegroundColor DarkGray
            }
        }
    }

    Connect-WorktreeDeps -Root $Root -Worktree $path
    Copy-WorktreeVerdicts -Root $Root -Worktree $path
    return $path
}

# --- ВЕРДИКТЫ ЗАКРЫТЫХ ЗАДАЧ В WORKTREE -------------------------------------------------
#
# Каталог вердиктов лежит в .gitignore — значит в чистом чекауте его нет. А цикл читает его
# у СЕБЯ, чтобы проверить допуск: «предшественник TASK-01 не имеет verdict: PASS» — и задача
# умирает через секунду после старта, хотя предшественник закрыт и слит. Наблюдалось живьём
# 2026-08-06 (прогон g_20260806-143112): волна 2 целиком не поехала сразу после того, как
# волна 1 успешно закрылась.
#
# Копируем только вердикты — состояние прогонов (.bcf) у каждой задачи своё, и делить его
# между ветками нельзя.
function Copy-WorktreeVerdicts {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Worktree
    )

    $rel = 'tasks\.verdicts'
    try {
        $cfgFile = Join-Path $Root 'config\harness.json'
        if (Test-Path $cfgFile) {
            $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($cfg.paths -and $cfg.paths.verdicts) { $rel = ([string]$cfg.paths.verdicts) -replace '/', '\' }
        }
    } catch { }

    $src = Join-Path $Root $rel
    if (-not (Test-Path $src -PathType Container)) { return }
    $dst = Join-Path $Worktree $rel
    try {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        foreach ($f in @(Get-ChildItem $src -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  ⚠ не удалось перенести вердикты в worktree ($($_.Exception.Message)) — задача не увидит закрытых предшественников" -ForegroundColor Yellow
    }
}

# --- ЗАВИСИМОСТИ В WORKTREE -------------------------------------------------------------
#
# worktree — это ЧИСТЫЙ чекаут: всё, что в .gitignore, туда не попадает. Для JS-проекта это
# значит отсутствие node_modules, а значит `npx --no-install tsc`, eslint и vitest падают
# там ВСЕГДА — не потому, что код плох, а потому что инструментов нет. Гейт, красный
# независимо от работы, хуже отсутствующего: агент видит красную быструю проверку каждую
# итерацию и начинает чинить несуществующее, пока не упрётся в потолок итераций.
#
# Ставим соединение (junction/symlink) на каталог зависимостей основного дерева, а не
# копируем: копия node_modules — это сотни мегабайт и минуты на КАЖДУЮ задачу волны.
# Разделяемый каталог безопасен на чтение; установка новых пакетов внутри задачи пишет в
# общий каталог — это осознанный размен, поскольку установленное всё равно нужно всем
# ветвям волны и в основном дереве после слияния.
# ЗАВИСИМОСТИ КОПИРУЮТСЯ ИЛИ СТАВЯТСЯ ЗАНОВО, НО НЕ СВЯЗЫВАЮТСЯ ССЫЛКОЙ.
#
# Первая версия ставила junction на node_modules основного дерева. Это экономило минуты и
# гигабайты — и стоило трёх прогонов подряд, потому что общий каталог зависимостей ломает
# изоляцию сразу тремя способами:
#
#   · `npm install` в одной задаче ВЫЧИЩАЕТ из общего каталога пакеты, которых нет в её
#     package.json, — гейт падает у всех задач волны разом, включая уже готовые;
#   · проверки слитого дерева идут в основном каталоге, пока агент соседней задачи правит
#     тот же node_modules: инструмент исчезает на секунды, и падение выглядит поломкой
#     компилятора;
#   · и главное: `git worktree remove --force` идёт по junction ВНУТРЬ и вычищает
#     настоящий каталог проекта. Наблюдалось живьём 2026-08-06 — node_modules проекта
#     оказался пуст целиком после удаления рабочего дерева задачи.
#
# Поэтому: ставим зависимости в дерево задачи её собственным менеджером по её же
# lock-файлу (быстро — кэш пакетов общий и тёплый), а если менеджер не опознан, копируем.
# Обе стратегии дают ИЗОЛЯЦИЮ: что бы задача ни сделала со своими зависимостями, соседей
# и проект это не касается.
function Connect-WorktreeDeps {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Worktree,
        [string[]]$Dirs = @('node_modules', '.venv', 'venv', 'vendor')
    )

    # npm: ставим по lock-файлу. `npm ci` детерминирован и берёт пакеты из общего кэша, то
    # есть сети не требует и идёт секунды, а не минуты.
    $lock = Join-Path $Worktree 'package-lock.json'
    if ((Test-Path $lock) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Host "  · ставлю зависимости задачи (npm ci, кэш общий)…" -ForegroundColor DarkGray
        $prev = Get-Location
        try {
            Set-Location $Worktree
            & npm ci --prefer-offline --no-audit --no-fund 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                # ci строг к рассинхрону lock и package.json; install мягче и тоже
                # изолирован — лучше поставить не по локу, чем оставить ветку без гейтов.
                & npm install --prefer-offline --no-audit --no-fund 2>&1 | Out-Null
            }
        } catch {
            Write-Host "  ⚠ установка зависимостей в worktree не удалась: $($_.Exception.Message)" -ForegroundColor Yellow
        } finally { Set-Location $prev }
        if (Test-Path (Join-Path $Worktree 'node_modules')) { return }
    }

    # Прочие каталоги (питоновские окружения, vendor) — копией. Дороже ссылки, но задача,
    # испортившая копию, портит только себя.
    foreach ($d in $Dirs) {
        $src = Join-Path $Root $d
        if (-not (Test-Path $src -PathType Container)) { continue }
        $dst = Join-Path $Worktree $d
        if (Test-Path $dst) { continue }
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "  ⚠ не удалось скопировать $d в worktree ($($_.Exception.Message)) — проверки в ветке задачи будут падать на отсутствии инструментов" -ForegroundColor Yellow
        }
    }
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

    # СНАЧАЛА СНЯТЬ ССЫЛКИ, ПОТОМ УДАЛЯТЬ.
    #
    # Рекурсивное удаление идёт по junction/symlink ВНУТРЬ и вычищает цель, а не ссылку:
    # 2026-08-06 удаление рабочего дерева задачи опустошило node_modules самого проекта.
    # Ссылок мы больше не ставим (см. Connect-WorktreeDeps), но они остаются в деревьях,
    # созданных прежней версией, и один такой каталог стоит всей установки зависимостей.
    # `cmd /c rmdir` снимает точку повторного разбора, не трогая цель.
    if (Test-Path $path) {
        foreach ($e in @(Get-ChildItem -LiteralPath $path -Force -Directory -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($IsWindows -or $env:OS -eq 'Windows_NT') { & cmd /c rmdir "`"$($e.FullName)`"" 2>&1 | Out-Null }
                else { & rm -f -- "$($e.FullName)" 2>&1 | Out-Null }
            }
        }
    }

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
