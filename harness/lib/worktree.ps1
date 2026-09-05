# worktree.ps1 — изолированное рабочее дерево на задачу.
#
# Параллельные задачи не могут делить одно рабочее дерево: авто-откат регрессии
# (`git checkout <snap> -- <productPaths>`) вернёт файлы соседа, а два агента,
# правящие один файл, просто затрут друг друга без всякого предупреждения.
#
# ВАЖНО: worktree — это гигиена, а не координация. Он изолирует редактирование, но
# ничего не знает про то, что две ветки правят одни файлы; за это отвечает
# claims.ps1 (допуск на старте). См. wiki/research/2026-07-26-parallel-agents-file-conflicts.md.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
# Гейт приёмки (Test-BcfTaskAcceptanceGate) и класс задачи живут в claims.ps1 — тот же
# файл, что уже определяет «Исполнитель:»/«Блокер:» тем же способом чтения шапки задачи.
# Подключаем здесь, а не полагаемся на порядок дот-сорсинга у вызывающего: тесты этого
# файла (harness/tests/merge-integration.tests.ps1) дот-сорсят ТОЛЬКО worktree.ps1.
. (Join-Path $PSScriptRoot 'claims.ps1')

# --- ТРЕЙЛЕРЫ КОММИТОВ ПРОГОНА -----------------------------------------------------------
#
# ЗАЧЕМ. Коммит «TASK-07: работа агента» сам по себе не говорит, КАКОЙ прогон его сделал,
# какой ролью узла и на какой модели/бэкенде: журнал прогона (.bcf/graph/<runId>/) живёт
# рядом с состоянием и не переживает уборку `.bcf/`, а коммит в git остаётся навсегда.
# Пять полей — минимум, достаточный чтобы восстановить обстоятельства коммита БЕЗ
# журнала, когда разбор дефекта идёт спустя месяцы по одному только `git log`.
function Format-BcfCommitTrailers {
    param(
        [string]$Task = '', [string]$RunId = '', [string]$Role = '',
        [string]$Model = '', [string]$Backend = ''
    )
    return @(
        "Task: $Task"
        "Run-Id: $RunId"
        "Role: $Role"
        "Model: $Model"
        "Backend: $Backend"
    ) -join "`n"
}

function New-BcfCommitMessage {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Task = '', [string]$RunId = '', [string]$Role = '',
        [string]$Model = '', [string]$Backend = ''
    )
    $trailers = Format-BcfCommitTrailers -Task $Task -RunId $RunId -Role $Role -Model $Model -Backend $Backend
    return "$Subject`n`n$trailers"
}

# Проверка ОБРАТНАЯ построению: сообщение обязано нести все пять трейлеров строкой
# «Ключ: значение» — значение может быть пустым (бэкенд без роли, модель не сообщена),
# важно само наличие ключа. Разбор дефекта, идущий по `git log`, не имеет права
# наткнуться на коммит прогона без опознавательных полей — тогда узнать, чем он сделан,
# можно только гадая.
function Test-BcfCommitTrailers {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    $required = @('Task', 'Run-Id', 'Role', 'Model', 'Backend')
    $missing = @()
    foreach ($k in $required) {
        if ($Message -notmatch "(?m)^$([regex]::Escape($k)):[ \t]?") { $missing += $k }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

# То же самое, но на НАСТОЯЩЕМ коммите git, по sha — доказывает, что конкретный коммит
# прогона несёт трейлеры, а не только что билдер их умеет строить.
function Test-BcfCommitHasTrailers {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sha)
    $msg = (& git -C $Root log -1 --format=%B $Sha 2>$null | Out-String)
    return (Test-BcfCommitTrailers -Message $msg)
}

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
    return $path
}

# --- ВЕРДИКТ ЕДЕТ В GIT, А НЕ КОПИЕЙ МИМО НЕГО ------------------------------------------
#
# Здесь стояла Copy-WorktreeVerdicts: каталог вердиктов лежал в .gitignore, поэтому в
# чистом чекауте его не было, и вердикты закрытых предшественников приходилось руками
# копировать в дерево каждой новой задачи. Иначе цикл проверял допуск у себя, не находил
# «verdict: PASS» и убивал задачу через секунду после старта — так 2026-08-06 не поехала
# целая волна.
#
# Копия чинила симптом и создавала ту же болезнь на ярус выше: вердикт существовал ровно
# на одной машине. Второй участник команды не видел ни одного закрытого гейта, и его
# фабрика считала бэклог пустым по построению.
#
# Теперь вердикт — обычный файл в git: его пишет обвязка в дерево задачи, он попадает в
# коммит ветки и приезжает к остальным слиянием. Вердикт незакрытой задачи, которую не
# слили, публикует Publish-TaskVerdict.

# Положить вердикт задачи в общее дерево и закоммитить ОДИН этот файл.
#
# Нужен там, где слияния не будет: задача не достигла PASS, её ветка остаётся жить, а
# список ремедиации нужен и человеку, и следующей попытке. Коммит именно один файл: иначе
# вердикт остаётся грязью в tasks/, а грязный tasks/ отменяет слияние следующей задачи.
function Publish-TaskVerdict {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$VerdictFile,
        [string]$RelDir = 'tasks/.verdicts'
    )
    if (-not (Test-Path -LiteralPath $VerdictFile)) { return @{ Ok = $false; Reason = 'вердикта нет' } }
    $relDirWin = $RelDir -replace '/', '\'
    $dstDir = Join-Path $Root $relDirWin
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    $dst = Join-Path $dstDir "$Task.md"
    Copy-Item -LiteralPath $VerdictFile -Destination $dst -Force -ErrorAction SilentlyContinue

    $rel = "$RelDir/$Task.md"
    $inside = (& git -C $Root rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
    if ($inside -ne 'true') { return @{ Ok = $true; Reason = 'не git-репозиторий, вердикт положен файлом' } }
    $id = Get-BcfGitIdentityArgs -Root $Root
    & git -C $Root add -A -- $rel 2>&1 | Out-Null
    $staged = @(& git -C $Root diff --cached --name-only -- $rel 2>$null | Where-Object { $_ })
    if (-not $staged.Count) { return @{ Ok = $true; Reason = 'вердикт уже в дереве' } }
    $out = (& git -C $Root @id commit -q -m "${Task}: вердикт" -- $rel 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = $out.Trim() } }
    return @{ Ok = $true; Reason = 'закоммичен' }
}

# --- ПРАВКИ ВЛАДЕЛЬЦА ПАРКУЮТСЯ, А НЕ ОТКАТЫВАЮТСЯ --------------------------------------
#
# Слияние ломает ЛЮБАЯ грязь в основном дереве, включая правку человека, сделанную во
# время прогона. Прежний код звал `git checkout --` и писал предупреждение: работа
# человека исчезала без следа, а узнавал он об этом из строки в логе ночного прогона.
#
# Теперь она уезжает коммитом в ветку `bcf/parked/<дата>`. Ветка стоит ничего, восстановить
# из неё можно всё, и человек забирает свою правку `git checkout bcf/parked/<дата> -- <файл>`.
# Коммит собирается через ВРЕМЕННЫЙ индекс: настоящий индекс дерева трогать нельзя, там
# идёт слияние задачи.
function Save-OwnerEditsToParkedBranch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Files,
        [string]$Reason = 'правки владельца, найденные во время прогона'
    )
    $files = @($Files | Where-Object { $_ })
    if (-not $files.Count) { return @{ Ok = $true; Branch = ''; Commit = ''; Files = @(); Message = 'парковать нечего' } }

    $branch = 'bcf/parked/' + (Get-Date -Format 'yyyy-MM-dd')
    $tmpIndex = Join-Path ([IO.Path]::GetTempPath()) ('bcf-park-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.index')
    $prevIndex = $env:GIT_INDEX_FILE
    $commit = ''
    try {
        # Родитель — вчерашняя парковка того же дня, если она есть: иначе вторая правка за
        # день затирала бы первую, и «сохранено» означало бы «сохранено последнее».
        $parent = (& git -C $Root rev-parse --verify --quiet "refs/heads/$branch" 2>$null | Out-String).Trim()
        if (-not $parent) { $parent = (& git -C $Root rev-parse HEAD 2>$null | Out-String).Trim() }
        if (-not $parent) { return @{ Ok = $false; Branch = $branch; Commit = ''; Files = $files; Message = 'в репозитории нет ни одного коммита' } }

        $env:GIT_INDEX_FILE = $tmpIndex
        & git -C $Root read-tree $parent 2>&1 | Out-Null
        & git -C $Root add -A -- @files 2>&1 | Out-Null
        $tree = (& git -C $Root write-tree 2>$null | Out-String).Trim()
        if (-not $tree) { return @{ Ok = $false; Branch = $branch; Commit = ''; Files = $files; Message = 'git write-tree ничего не вернул' } }
        $id = Get-BcfGitIdentityArgs -Root $Root
        $msg = "припарковано: $Reason — $($files -join ', ')"
        $commit = (& git -C $Root @id commit-tree $tree -p $parent -m $msg 2>$null | Out-String).Trim()
        if (-not $commit) { return @{ Ok = $false; Branch = $branch; Commit = ''; Files = $files; Message = 'git commit-tree ничего не вернул' } }
        & git -C $Root update-ref "refs/heads/$branch" $commit 2>&1 | Out-Null
    } finally {
        if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        else { $env:GIT_INDEX_FILE = $prevIndex }
        Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
    }

    # Дерево возвращаем к HEAD явно: правка уже лежит в ветке, а слияние идёт только на
    # чистом дереве.
    foreach ($f in $files) { & git -C $Root checkout HEAD -- $f 2>&1 | Out-Null }
    return @{ Ok = $true; Branch = $branch; Commit = $commit; Files = $files
              Message = "правки $($files -join ', ') сохранены в ветке $branch (забрать: git checkout $branch -- <файл>)" }
}

# --- ОТКАТ СЛИЯНИЯ, У КОТОРОГО ПРОВЕРКИ КРАСНЫЕ -----------------------------------------
#
# Здесь стоял `git reset --hard HEAD~1` на общем дереве, и это тихая потеря чужой работы.
# Между слиянием и проверками на слитом дереве проходят минуты: за это время в ту же ветку
# успевает попасть коммит соседней задачи или коммит человека, работающего рядом. `HEAD~1`
# ничего не знает про содержимое — он снимает ПОСЛЕДНИЙ коммит, каким бы он ни был. В
# команде это уже не гипотеза: сливаются несколько участников в одну ветку.
#
# Правило простое: жёсткий сброс на запомненный SHA допустим только внутри ветки задачи,
# где кроме этой задачи никого нет. На общей ветке — `git revert`, который отменяет ровно
# то слияние и оставляет всё, что приехало после.
function Undo-FailedMerge {
    param(
        [Parameter(Mandatory)][string]$Root,
        # AllowEmptyString, потому что sha приходит из `git rev-parse`, а он умеет вернуть
        # пустоту. Без этого вызывающий получал бы исключение привязки параметра вместо
        # внятного «откатывать нечего» — и падал бы посреди отката.
        [Parameter(Mandatory)][AllowEmptyString()][string]$MergeSha,
        [string]$BeforeSha = ''
    )
    if (-not $MergeSha) { return @{ Ok = $false; Kind = 'no-sha'; Message = 'sha слияния не запомнен — откатывать нечего' } }

    $branch = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    $head   = (& git -C $Root rev-parse HEAD 2>$null | Out-String).Trim()
    $short  = $MergeSha.Substring(0, [Math]::Min(8, $MergeSha.Length))

    if (($branch -like 'bcf/task/*') -and $BeforeSha -and ($head -eq $MergeSha)) {
        & git -C $Root reset --hard $BeforeSha 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return @{ Ok = $true; Kind = 'reset'; Branch = $branch
                      Message = "ветка задачи $branch возвращена на $($BeforeSha.Substring(0, [Math]::Min(8, $BeforeSha.Length)))" }
        }
    }

    # Коммит слияния имеет двух родителей, и revert требует сказать, какую сторону считать
    # основной. У обычного коммита родитель один, и -m его сломает.
    $parents = @((& git -C $Root rev-list --parents -n 1 $MergeSha 2>$null | Out-String).Trim() -split '\s+' | Where-Object { $_ })
    $id = Get-BcfGitIdentityArgs -Root $Root
    # Имя не $args: так зовётся автоматическая переменная функции, и присваивание в неё
    # читается как ошибка ровно до того момента, когда ею станет.
    $revertArgs = @('-C', $Root) + $id + @('revert', '--no-edit')
    if ($parents.Count -ge 3) { $revertArgs += @('-m', '1') }
    $revertArgs += $MergeSha
    $out = (& git @revertArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        return @{ Ok = $true; Kind = 'revert'; Branch = $branch
                  Message = "слияние $short отменено коммитом revert — коммиты, приехавшие после него, на месте" }
    }
    & git -C $Root revert --abort 2>&1 | Out-Null
    return @{ Ok = $false; Kind = 'revert-failed'; Branch = $branch
              Message = "слияние $short не отменяется автоматически (revert конфликтует) — нужен человек: $($out.Trim())" }
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
        [switch]$KeepConflictForArbiter,
        # Метаданные прогона — только для трейлеров коммита слияния. Пусто = коммит
        # прежним `--no-edit`, без трейлеров: юнит-тесты этой функции зовут её без
        # единого понятия о прогоне, и их поведение не должно от этого меняться.
        [string]$RunId = '', [string]$Role = '', [string]$Model = '', [string]$Backend = ''
    )
    $branch = "bcf/task/$Task"

    # ПРИЁМКА ЛИДЕРОМ — ПЕРЕД ЛЮБЫМ КАСАНИЕМ GIT. CORE и NFR без файла приёмки
    # (`tasks/.acceptance/<TASK>.md`) не продвигаются в текущую ветку интеграции: тесты
    # доказывают, что написано в них, а не то, что задача решает нужную проблему
    # правильным способом. GEN и задачи без класса (или вовсе без файла — гейт им не
    # писан, см. Test-BcfTaskAcceptanceGate) идут дальше как раньше.
    $gate = Test-BcfTaskAcceptanceGate -TaskId $Task -Root $Root
    if (-not $gate.Ok) {
        return @{ Ok = $false; Conflicts = @(); Kind = 'needs-acceptance'; Message = $gate.Reason }
    }

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
    # СОБСТВЕННЫЕ ФАЙЛЫ ОБВЯЗКИ В tasks/ КОММИТЯТСЯ, А НЕ ПАРКУЮТСЯ.
    #
    # Вердикт, заявка и доска задач лежат в git ради того, чтобы их видела вся команда. Их
    # пишет сама обвязка, и коммит рядом с ними иногда не проходит: параллельная задача
    # держит индекс, или дерево в этот момент занято чужим слиянием. Припарковать их значило
    # бы отобрать у задачи её собственную заявку прямо во время работы, а откатить — потерять
    # вердикт. Считаем отдельным вызовом с --untracked-files=all: вердикт, написанный
    # впервые, для git НОВЫЙ файл, а $dirty новых не содержит. Именно этот случай и есть
    # обычный — каталог вердиктов только что перестал быть скрытым.
    #
    # tasks/STATUS.json здесь по той же причине и по ещё одной, своей: доска меняется после
    # КАЖДОГО узла. Попади она в парковку — и каждое слияние волны отправляло бы в ветку
    # bcf/parked/<дата> собственную доску прогона, а сам прогон вставал бы на грязном дереве.
    $harnessDirty = @(& git -C $Root status --porcelain --untracked-files=all 2>$null |
                      ForEach-Object { ($_ -replace '^..\s*', '').Trim() } |
                      Where-Object { $_ -match '^tasks/(\.(verdicts|claims)/|STATUS\.json$)' })
    if ($harnessDirty.Count) {
        $hid = Get-BcfGitIdentityArgs -Root $Root
        & git -C $Root add -A -- @harnessDirty 2>&1 | Out-Null
        & git -C $Root @hid commit -q -m "обвязка: вердикты, заявки и доска задач перед слиянием $Task" -- @harnessDirty 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $dirty = @($dirty | Where-Object { $harnessDirty -notcontains $_ }) }
    }

    # ГРЯЗЬ В ОБВЯЗКЕ — НЕ ПОВОД ТЕРЯТЬ НИ РАБОТУ ЗАДАЧИ, НИ РАБОТУ ЧЕЛОВЕКА.
    #
    # ИНЦИДЕНТ 2026-08-10, тот же класс, что и с лок-файлом: узел ревизии плана работает
    # в ОСНОВНОМ дереве и с правом правки, зашёл в tasks/ и поменял в закрытой TASK-25
    # «- [x]» на «- [V]». Две изменённые строки в файле давно закрытой задачи отменили
    # слияние TASK-48, дошедшей до PASS.
    #
    # Каталоги задач и конфигов принадлежат ВЛАДЕЛЬЦУ: кодовому агенту они запрещены
    # правилами проекта, и в слиянии продуктового кода не участвуют. Поэтому грязь там
    # слияние не блокирует. Но и `git checkout --`, стоявший здесь раньше, не годится:
    # правку в tasks/ и config/ во время прогона делает не только узел, а ещё и человек,
    # сидящий рядом, — и его работа исчезала, а он узнавал об этом из строки в логе.
    #
    # Правки уезжают коммитом в ветку bcf/parked/<дата>, откуда их забирают обратно.
    $ownerDirty = @($dirty | Where-Object { $_ -match '^(tasks|config)/' })
    if ($ownerDirty.Count) {
        $park = Save-OwnerEditsToParkedBranch -Root $Root -Files $ownerDirty `
                    -Reason "правки в каталогах владельца во время слияния $Task"
        $dirty = @($dirty | Where-Object { $ownerDirty -notcontains $_ })
        if ($park.Ok) {
            Write-Warning ("слияние: правки в каталогах владельца припаркованы — $($ownerDirty -join ', '). " +
                           $park.Message)
        } else {
            Write-Warning ("слияние: правки в каталогах владельца не удалось припарковать — $($park.Message). " +
                           "Дерево оставлено как есть, слияние не пойдёт.")
            return @{
                Ok = $false; Conflicts = @(); Kind = 'dirty-tree'
                Message = "правки владельца в $($ownerDirty -join ', ') не удалось сохранить: $($park.Message)"
            }
        }
    }

    if ($dirty.Count) {
        return @{
            Ok = $false; Conflicts = @(); Kind = 'dirty-tree'
            Message = "основное дерево грязное — слияние невозможно: $($dirty -join ', '). Закоммить или отложи эти правки."
        }
    }

    if ($RunId) {
        $id = Get-BcfGitIdentityArgs -Root $Root
        $msg = New-BcfCommitMessage -Subject "${Task}: слияние работы задачи" `
                   -Task $Task -RunId $RunId -Role $Role -Model $Model -Backend $Backend
        $out = (& git -C $Root @id merge --no-ff -m $msg $branch 2>&1 | Out-String)
    } else {
        $out = (& git -C $Root merge --no-ff --no-edit $branch 2>&1 | Out-String)
    }
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
        [Parameter(Mandatory)][string]$Task,
        # Метаданные прогона — только для трейлеров коммита. Пусто = коммит принимает
        # готовое сообщение слияния (`--no-edit`) без трейлеров: сведение конфликта,
        # позванное не из графа (руками, из другого оркестратора), не обязано их знать.
        [string]$RunId = '', [string]$Role = '', [string]$Model = '', [string]$Backend = ''
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
    # Идентичность — из конфига проекта (author.*), иначе из git-конфига репозитория,
    # только на голой фикстуре — bcf/bcf@local. Раньше здесь стояло намертво вшитое
    # user.name=ralph — коммит арбитра подписывался ботом, даже когда владелец назвал
    # себя в config/harness.json.
    $id = Get-BcfGitIdentityArgs -Root $Root
    if ($RunId) {
        $msg = New-BcfCommitMessage -Subject "${Task}: слияние конфликта сведено арбитром" `
                   -Task $Task -RunId $RunId -Role $Role -Model $Model -Backend $Backend
        $out = (& git -C $Root @id commit -m $msg 2>&1 | Out-String)
    } else {
        $out = (& git -C $Root @id commit --no-edit 2>&1 | Out-String)
    }
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
