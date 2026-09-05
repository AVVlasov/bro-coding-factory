# bcf init — настройка фабрики под проект. Восемь экранов.
#
#   bcf init                мастер: восемь шагов, выйти можно на любом
#   bcf init --yes          без вопросов: везде значение по умолчанию, но каждое названо
#   bcf init --dry          показать решения, ничего не записав
#   bcf init --reconfigure  заменить уже заполненные значения своими догадками
#
# ПРАВИЛА, КОТОРЫЕ ЗДЕСЬ ДЕЙСТВУЮТ:
#   · каждый шаг заканчивается текстовым файлом, который можно открыть и поправить руками;
#   · у каждого предложения виден источник — «проверено», «уверенно» или «догадка»;
#   · цены не показываются: init настраивает, а не продаёт. Смета — отдельной командой;
#   · агентов не зовём. Ни один токен здесь не тратится;
#   · init ЗАПОЛНЯЕТ ПУСТОЕ, а не переписывает заполненное;
#   · выйти можно на любом шаге — состояние лежит в .bcf/init.json. Это не удобство:
#     настройка живого проекта упирается в вопрос, ответ на который надо пойти
#     посмотреть, и мастер, теряющий прогресс при выходе, второй раз не запускают.

. (Join-Path $BcfRoot 'src\lib\detect.ps1')
. (Join-Path $BcfRoot 'src\lib\backends.ps1')
. (Join-Path $BcfRoot 'src\lib\tui.ps1')
. (Join-Path $BcfRoot 'src\lib\mascot.ps1')
. (Join-Path $BcfRoot 'src\lib\wizard.ps1')
. (Join-Path $BcfRoot 'src\lib\queue.ps1')

$dry         = $script:BcfArgs -contains '--dry'
$reconfigure = $script:BcfArgs -contains '--reconfigure'
$project     = $script:BcfProject
$templates   = Get-BcfTemplates
$TOTAL       = 8

$blocking = @()
$later = @()
$writtenFiles = @()
$kept = @()

$interactive = (Test-BcfInteractive) -and -not (Get-BcfAssumeYes)

# ======================================================================================
#  ШАГ 1 — ГДЕ ПРОЕКТ
# ======================================================================================
function Show-Step1 {
    Write-BcfStepHeader -Step 1 -Total $TOTAL -Title 'где проект'
    Write-Host ''
    Write-BcfMascotHeader -Mood 'ok' -Text @(
        @{ t = "BRO CODING FACTORY  $(Ink "v$(Get-BcfVersion)" 'DarkGray') $(Ink '· инициализация' 'DarkGray')"; c = 'White' }
        @{ t = 'настроим фабрику под проект. восемь шагов, всё пишется в текстовые файлы,'; c = 'DarkGray' }
        @{ t = 'выйти можно на любом — состояние сохраняется в .bcf/init.json'; c = 'DarkGray' }
    )
    Write-Host ''

    $recent = @(Get-BcfRecentProjects -Current $project -Limit 5)
    $items = @()
    foreach ($r in $recent) {
        $git = if ($r.IsGit) { "git · $($r.Branch) · " + $(if ($r.Dirty) { "$($r.Dirty) файла грязных" } else { 'чисто' }) }
               else { 'не git' }
        $items += @{ main = ("{0,-42} {1,-32} {2}" -f $r.Path, $git, (Format-BcfAgo $r.Last)); note = ''; dim = $false }
    }
    $items += @{ main = '─────'; note = ''; dim = $true }
    $items += @{ main = 'ввести путь вручную'; note = ''; dim = $false }

    $chosen = $project
    if ($interactive) {
        $hdr = { @(@{ t = '  ' + (Ink 'ГДЕ ПРОЕКТ' 'Cyan') + '  ' + (Ink 'недавние из истории оболочки' 'DarkGray'); c = '' }, '') }
        $idx = Read-BcfListChoice -Items $items -Selected 0 -Header $hdr -Hints @(
            @('↑↓', 'выбрать'), @('enter', 'дальше'), @('e', 'ввести путь'), @('q', 'выход'))
        if ($idx -lt 0) { return $null }
        if ($idx -eq $items.Count - 1) {
            $typed = Read-Host '  путь'
            if ($typed) { $chosen = $typed.Trim().Trim('"') }
        } elseif ($idx -lt $recent.Count) {
            $chosen = $recent[$idx].Path
        }
    } else {
        Write-Host ('  ' + (Ink 'ГДЕ ПРОЕКТ' 'Cyan'))
        foreach ($i in $items) { Write-BcfDim $i.main }
    }

    try { $chosen = (Resolve-Path -LiteralPath $chosen -ErrorAction Stop).Path } catch {
        Write-BcfFail "каталог не найден: $chosen"; return $null
    }

    Write-Host ''
    Write-Host ('  ' + (Ink $chosen 'White'))
    $git = Get-BcfGitState -Root $chosen
    if ($git.IsGit) { Write-BcfOk 'git-репозиторий — значит слияния пойдут через worktree, а не поверх дерева' }
    else {
        Write-BcfFail 'НЕ git-репозиторий'
        $script:blocking += @{ what = 'проект не под git'
                        why  = 'слияния идут через worktree, а снапшоты работы — через git-refs. Без репозитория ни то, ни другое невозможно: потерянную итерацию восстановить будет нечем.'
                        fix  = 'git init && git add -A && git commit -m "initial"' }
    }
    if (Test-Path (Join-Path $chosen '.bcf\project.json')) {
        Write-BcfWarn 'инициализация уже проходила — существующие файлы не перезапишем'
    } else {
        Write-BcfOk 'папки .bcf нет — инициализация первая, ничего не перезапишем'
    }
    if ($git.IsGit -and $git.Dirty.Count) {
        Write-BcfWarn "$($git.Dirty.Count) файла не закоммичены — фабрика начнёт с грязного дерева"
        Write-BcfNote (($git.Dirty | Select-Object -First 6) -join '   ')
        Write-BcfNote 'руками: закоммить или отложить (git stash). иначе первое же слияние'
        Write-BcfNote 'затянет эти правки в чужую задачу и разбираться будешь ты, а не арбитр.'
        $script:blocking += @{ what = "$($git.Dirty.Count) файлов не закоммичено"
                        why  = 'первое же слияние затянет эти правки в чужую задачу, и разбираться будешь ты, а не арбитр.'
                        fix  = 'git commit -am "wip"   или   git stash' }
    }
    return $chosen
}

# ======================================================================================
#  ШАГ 2 — РАЗБОР ПРОЕКТА
# ======================================================================================
function Show-Step2 {
    param([string]$Root)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $d = Invoke-BcfDetect -Root $Root -Probe
    $sw.Stop()

    Write-BcfStepHeader -Step 2 -Total $TOTAL -Title 'разбор проекта'
    Write-Host ('  ' + (Ink (Split-Path $Root -Leaf) 'White') + ' ' +
                (Ink ("· {0:N1} с · прочитано {1} файлов, не записано ничего" -f $sw.Elapsed.TotalSeconds, $d.Languages.Total) 'DarkGray'))
    Write-Host ''

    $top = @($d.Languages.Languages | Select-Object -First 4)
    Write-BcfField 'языки' $(if ($top.Count) { ($top | ForEach-Object { "$($_.Language) $($_.Percent)%" }) -join '   ' } else { '(исходников не найдено)' })
    Write-BcfField 'сборка' $(if ($d.Ecosystems.Count) { $d.Ecosystems -join ', ' } else { '(манифестов не найдено)' })

    # ТЕСТЫ ЧИСЛОМ, а не фактом наличия раннера: гейт «фича доказана тестами» держится на
    # том, что тесты есть. Пустой набор при живом раннере — это задача, закрывшаяся ничего
    # не доказав, и увидеть это надо здесь, а не после прогона.
    $tc = $d.TestCounts
    $tcTxt = if ($tc -and $tc.Keys.Count) {
        (@($tc.Keys | Sort-Object | ForEach-Object { "$_ найдено $($tc[$_])" }) -join ' · ')
    } else { '(тестов не нашлось — гейт «доказано тестами» держаться не на чем)' }
    Write-BcfField 'тесты' $tcTxt '' 16 $(if ($tc -and $tc.Keys.Count) { 'White' } else { 'Yellow' })

    if ($d.Git.IsGit) {
        $dirty = if ($d.Git.Dirty.Count) { "$($d.Git.Dirty.Count) грязных" } else { 'чисто' }
        $wt = if ($d.Git.Worktree) { 'worktree работает' } else { 'worktree НЕ отвечает' }
        $hk = if (@($d.Git.Hooks).Count) { "git-хуков $(@($d.Git.Hooks).Count)" } else { 'git-хуков нет' }
        Write-BcfField 'git' "$($d.Git.Branch) · $dirty · $wt · $hk"
    } else {
        Write-BcfField 'git' 'НЕ репозиторий' '' 16 'Red'
    }

    $docsFound = @($d.Docs.Files | Where-Object { $_.Exists })
    $docsTxt = if ($docsFound.Count) { (($docsFound | ForEach-Object { $_.Path }) -join ', ') } else { '(README/CLAUDE.md/PRD не найдены)' }
    if ($d.Docs.DocsMdCount -gt 0) { $docsTxt += "  ·  docs/ — $($d.Docs.DocsMdCount) файлов" }
    Write-BcfField 'доки' $docsTxt

    Write-Host ''
    Write-Host ('  ' + (Ink 'ПРЕДЛАГАЕМ ЗАПИСАТЬ В config/harness.json' 'Cyan'))
    Write-Host ''

    $productPaths = @($d.ProductPaths)
    if (-not $productPaths.Count) { $productPaths = @('src') }
    Write-BcfField 'productPaths' ($productPaths -join ', ') $(if ($d.ProductPaths.Count) { 'уверенно' } else { 'догадка' }) 18

    $typechecks = @()
    foreach ($t in $d.Typechecks) {
        $p = @($d.Probes | Where-Object { $_.Command -eq $t }) | Select-Object -First 1
        if ($p -and $p.Ok) {
            $typechecks += $t
            Write-BcfField 'backpressure' $t 'проверено' 18
        } else {
            $why = if ($p) { "упало (exit $($p.ExitCode))" } else { 'не проверялось' }
            Write-BcfField 'backpressure' "$t   ← $why" 'догадка' 18 'Yellow'
            if ($p) {
                $script:blocking += @{ step = 2; what = "быстрая проверка падает: $t"
                                why  = 'она вызывается КАЖДУЮ итерацию — гейт будет красным всегда, и агент начнёт чинить несуществующее.'
                                fix  = "последние строки вывода:`n     " + ($p.Output -replace "`n", "`n     ") }
            }
        }
    }
    if (-not $d.Typechecks.Count) { Write-BcfField 'backpressure' '(быстрой проверки не нашлось)' 'догадка' 18 'Yellow' }

    Write-BcfField 'generatedFiles' $(if ($d.Generated.Count) { $d.Generated -join ', ' } else { '(нет)' }) `
                   $(if ($d.Generated.Count) { 'уверенно' } else { 'догадка' }) 18
    $runnerVal = if (-not $d.Tests.runner) { '(не определился)' }
                 elseif ($d.Runners.Count -gt 1) { "$($d.Tests.runner)   ← найдено $($d.Runners.Count): $((($d.Runners | ForEach-Object { "$($_.Runner)$(if ($_.Scope) { " в $($_.Scope)" })" }) -join ', '))" }
                 else { $d.Tests.runner }
    Write-BcfField 'tests.runner' $runnerVal `
                   $(if (-not $d.Tests.runner -or $d.Runners.Count -gt 1) { 'догадка' } else { 'уверенно' }) 18

    Write-BcfField 'taskIdPattern' 'TASK-\d+' 'уверенно' 18

    # ЧТО СЧИТАЕТСЯ НЕ ПРОДУКТОМ — печатаем явно. Разбор исключает обвязку из подсчёта
    # языков и продуктовых путей; молча это делать нельзя: человек должен иметь
    # возможность возразить, если у него код лежит там, где мы ждём харнесс.
    if ($d.Languages.HarnessFiles -gt 0) {
        Write-BcfField 'вне продукта' ("loop/ .claude/ tasks/ docs/ meta/ memory/ — обвязка, $($d.Languages.HarnessFiles) файлов") 'уверенно' 18
    }

    Write-Host ''
    Write-BcfNote 'productPaths решает, где искать «прогресса нет» и расползание скоупа.'
    Write-BcfNote 'generatedFiles — что не блокирует слияние: один лок-файл уже валил семь задач подряд.'

    if (-not $d.Tests.runner) {
        $script:later += 'раннер тестов не определился (config/harness.json → tests.runner): пока он пуст, задача может получить PASS без единого нового теста.'
    }
    if ($d.Runners.Count -gt 1) {
        $script:later += "раннеров тестов найдено $($d.Runners.Count) ($((($d.Runners | ForEach-Object { $_.Runner }) -join ', '))), а гейт «фича доказана тестами» одноместный: задачи второго стека будут проверяться чужим раннером."
    }

    # РЕШИТЬ РУКАМИ — здесь, а не только в итоге.
    #
    # Список в конце восьми шагов человек читает уже уставшим и «потом посмотрю» ставит
    # ровно на том, что ломает первый же прогон. Поэтому то, что нашёл ЭТОТ шаг,
    # показывается на ЭТОМ шаге — с последствием и готовой командой.
    $mine = @($script:blocking | Where-Object { $_.step -eq 2 -or -not $_.step })
    if ($mine.Count) {
        Write-Host ''
        Write-BcfLine "  ⚠ РЕШИТЬ РУКАМИ  $($mine.Count)" 'Red'
        $n = 0
        foreach ($b in $mine) {
            $n++
            Write-BcfLine ("  $n  " + $b.what) 'White'
            if ($b.why) { Write-BcfNote $b.why }
            if ($b.fix) { Write-BcfLine ('     ' + $b.fix) 'Cyan' }
        }
    }

    if ($interactive) {
        Write-BcfKeyHints -Pairs @(@('enter', 'принять всё'), @('e', 'править'), @('x', 'пропустить и разобраться потом'), @('q', 'выход'))
        $k = Read-BcfKey
        if ($k -and $k.Key -in @('Q', 'Escape')) { return $null }
    }
    return [pscustomobject]@{ Detect = $d; ProductPaths = $productPaths; Typechecks = $typechecks }
}

# ======================================================================================
#  ШАГ 3 — КОДОВЫЕ АГЕНТЫ
# ======================================================================================
function Show-Step3 {
    $survey = Invoke-BcfBackendSurvey

    Write-BcfStepHeader -Step 3 -Total $TOTAL -Title 'что из кодовых агентов стоит в системе'
    Write-Host ('  ' + (Ink 'КОДОВЫЕ АГЕНТЫ' 'Cyan') + '  ' +
                (Ink "опрошено $($survey.Count) известных CLI · авторизации проверены живьём" 'DarkGray'))
    Write-Host ''
    Write-Host ('  ' + (Ink ("{0,-11} {1,-10} {2,-16} {3,-11} {4}" -f 'агент', 'версия', 'авторизация', 'песочница ro', 'токены в потоке') 'DarkGray'))
    Write-BcfRule 78

    foreach ($r in $survey) {
        $b = (Get-BcfKnownBackends)[$r.Name]
        if (-not $r.Installed) {
            Write-Host ('  ' + (Ink ("· {0,-9} не установлен" -f $r.Name) 'DarkGray'))
            continue
        }
        $sym = if ($r.AuthOk) { Ink '✓' 'Green' } else { Ink '✗' 'Red' }
        $auth = if ($r.AuthOk) { $r.Auth } else { 'НЕ АВТОРИЗОВАН' }
        $ro = if ($b.ro) { 'да' } else { 'нет' }
        $tok = if ($r.Tokens) { 'да' } else { 'НЕТ' }
        $col = if ($r.AuthOk) { '' } else { 'Red' }
        Write-Host ('  ' + $sym + ' ' + (Ink ("{0,-9} {1,-10} {2,-16} {3,-11} {4}" -f $r.Name, $(if ($r.Version) { "v$($r.Version)" } else { '' }), $auth, $ro, $tok) $col))
        if (-not $r.OnPath) {
            Write-BcfNote "не на PATH, найден внутри установки приложения:"
            Write-BcfNote "$($r.Path)"
            Write-BcfNote 'хэш сборки в пути меняется после каждого обновления приложения.'
        }
        if (-not $r.Tokens) {
            Write-BcfNote '⚠ в потоке нет события о расходе токенов. узлы этого бэкенда для бюджета'
            Write-BcfNote '  выглядят нулевыми: ставить его на цикл «до исчерпания» нельзя.'
        }
    }

    $avail = @($survey | Where-Object { $_.Installed -and $_.AuthOk })
    Write-Host ''
    Write-Host ('  ' + (Ink 'ЧТО ЭТО ЗНАЧИТ ДЛЯ РОЛЕЙ' 'Cyan'))
    $roNames = @((Get-BcfKnownBackends).Keys | Where-Object {
        $bb = (Get-BcfKnownBackends)[$_]
        $bb.ro -and ($avail | Where-Object { $_.Name -eq $bb.aliasOf })
    })
    if ($roNames.Count) {
        Write-BcfNote "песочница «только чтение» есть у: $($roNames -join ', '). Роль, которая обязана только"
        Write-BcfNote 'смотреть (критик, ресёрчер), пойдёт туда — иначе она однажды что-нибудь поправит «по пути».'
    } else {
        Write-BcfNote 'песочницы «только чтение» нет ни у одного установленного CLI: роли-наблюдатели'
        Write-BcfNote 'получат право писать.'
        $script:later += 'ни один установленный CLI не даёт песочницу «только чтение»: критик и ресёрчер смогут править файлы.'
    }

    if (-not $avail.Count) {
        Write-Host ''
        Write-BcfFail 'ни одного авторизованного кодового агента — исполнять узлы нечем'
        $script:blocking += @{ what = 'нет ни одного авторизованного кодового CLI'
                        why  = 'граф и цикл исполняют работу через внешний CLI-агент. Без него настройка запишется, но ни один прогон не поедет.'
                        fix  = 'поставь и авторизуй хотя бы один: claude / opencode / codex / cursor-agent' }
    }

    if ($interactive) {
        Write-BcfKeyHints -Pairs @(@('enter', 'дальше'), @('r', 'повторить опрос'), @('q', 'выход'))
        $k = Read-BcfKey
        if ($k -and $k.Key -in @('Q', 'Escape')) { return $null }
        if ($k -and ([string]$k.KeyChar).ToUpper() -eq 'R') { return (Show-Step3) }
    }
    return $survey
}

# ======================================================================================
#  ШАГ 4 — РОЛИ ГРАФА
# ======================================================================================
#
# ЧИСЛА ЗДЕСЬ — ИЗ НАСТОЯЩЕЙ ОЧЕРЕДИ, А НЕ ИЗ ПРИМЕРА.
#
# Экран объясняет, за что человек будет платить, и «по задаче + слияния» на этот вопрос
# не отвечает: разница между очередью из двух задач и из двадцати — это разница между
# прогоном за пять минут и прогоном на ночь. Всё, что тут названо, вычислимо без единого
# токена: задачи лежат в tasks/, ракурсы приёмки — в config/review-lenses.json проекта.
#
# Ракурсы спрашиваются ПРО ТОТ ЖЕ КОРЕНЬ, что и очередь. Функция умеет брать проект из
# состояния CLI, но экран рисуется для $Root: два источника корня однажды разойдутся на
# `--project`, и человек увидит ракурсы чужого проекта рядом со своей очередью.
function Show-Step4 {
    param([string]$Root)

    $q = $null
    try { $q = Get-BcfQueue -Project $Root } catch { }
    $angles = @(Get-BcfCriticAngles -Project $Root)
    $nCritic = $angles.Count

    Write-BcfStepHeader -Step 4 -Total $TOTAL -Title 'роли графа'
    $queueNote = if (-not $q -or -not $q.Exists) { "папки $(if ($q) { $q.TasksRel } else { 'tasks' })/ нет — очередь пустая" }
                 elseif (-not $q.Open) { 'открытых задач нет — очередь пустая' }
                 else { "очередь: $(Format-BcfCount $q.Open @('задача','задачи','задач')) · $(Format-BcfCount $q.Waves.Count @('волна','волны','волн'))" }
    Write-Host ('  ' + (Ink 'РОЛИ ГРАФА' 'Cyan') + '  ' + (Ink "шаблон «рой, 4 роли» · $queueNote" 'DarkGray'))
    Write-Host ''

    $live = [bool]($q -and $q.Open)
    $rows = New-BcfRows
    if ($live) {
        # planner зовут ТОЛЬКО при коллизии владения или задаче без объявленных файлов:
        # при чистых декларациях граф этот узел не запускает вовсе.
        $needPlan = [bool]($q.Collisions.Count -or $q.Undeclared.Count)
        $planCell = if ($needPlan) { '1 — ревизия владения, разбор ниже' }
                    else { '0 — владение непротиворечиво, узел не запускается' }
        $workCell = if ($q.Admitted -eq $q.Open) { "$($q.Admitted) + слияния — дешёвые, их много" }
                    else { "$($q.Admitted) + слияния — не допущено: $($q.Open - $q.Admitted)" }
        Add-BcfRow $rows @('Разметка', 'planner',          $planCell)
        Add-BcfRow $rows @('Работа',   'worker → arbiter', $workCell)
        Add-BcfRow $rows @('Приёмка',  "critic ×$nCritic", "$nCritic — читают слитое дерево")
        Add-BcfRow $rows @('Итог',     '(скрипт)',         '0 — без модели')
        Write-BcfTable -Headers @('фаза', 'роли', "узлов на очередь из $(Format-BcfCount $q.Open @('задачи','задач','задач'))") -Widths @(12, 20, 46) -Rows $rows

        # ЧЕМ ЗАНЯТ ЛИШНИЙ УЗЕЛ. Строка таблицы называет число, но не причину, а причина
        # здесь — единственное, с чем человек может что-то сделать до прогона: развести
        # владение руками дешевле, чем платить планировщику за то же решение.
        if ($needPlan) {
            Write-Host ''
            foreach ($c in @($q.Collisions | Select-Object -First 4)) { Write-BcfWarn "владение пересекается: $c" }
            if ($q.Collisions.Count -gt 4) { Write-BcfNote "… ещё $($q.Collisions.Count - 4)" }
            if ($q.Undeclared.Count) {
                Write-BcfWarn "файлы не объявлены: $($q.Undeclared -join ', ') — к работе не допустят"
                Write-BcfNote 'секция «## Файлы» — это допуск: без неё проверить, что задача не залезет в чужой'
                Write-BcfNote 'файл, нечем, и расползание скоупа обнаружится только на слиянии.'
            }
        }
        if ($q.Blocked.Count) {
            Write-BcfWarn "не попадут ни в одну волну: $($q.Blocked -join ', ') — предшественник не закроется"
        }
    } else {
        Add-BcfRow $rows @('Разметка', 'planner',          '1, и только при коллизии владения')
        Add-BcfRow $rows @('Работа',   'worker → arbiter', 'по задаче + слияния — дешёвые, их много')
        Add-BcfRow $rows @('Приёмка',  "critic ×$nCritic", "$nCritic — читают слитое дерево")
        Add-BcfRow $rows @('Итог',     '(скрипт)',         '0 — без модели')
        Write-BcfTable -Headers @('фаза', 'роли', 'узлов на очередь') -Widths @(12, 20, 46) -Rows $rows
        Write-Host ''
        Write-BcfNote 'числа появятся, когда в tasks/ лягут задачи: узлы считаются по очереди, а не по шаблону.'
    }

    Write-Host ''
    Write-BcfOk 'planner   рамка: DAG по зависимостям, коллизии владения файлами, вердикт'
    Write-BcfOk 'worker    исполнение: одна задача — один агент — один файл-владелец'
    Write-BcfOk 'arbiter   слияние: снимает конфликты, решает, чей вариант остаётся'
    $angleTxt = if ($nCritic) { "приёмка, ракурсы: $($angles -join ' · ')" } else { 'приёмка по слитому дереву' }
    Write-BcfOk "critic    $angleTxt"

    # ОПЦИОНАЛЬНЫЕ РОЛИ. Их здесь не включают галочкой — включать пока некуда: в графе
    # очереди нет узла, на который они бы встали. Промолчать нельзя: роль, у которой есть
    # файл в agents/ и строка в config/agents.json, выглядит подключённой.
    Write-Host ''
    Write-Host ('  ' + (Ink 'ОСТАЛЬНЫЕ РОЛИ — НЕ УЗЛЫ ЭТОГО ГРАФА' 'White'))
    Write-BcfNote '· researcher     отдельной командой до работы: bcf research TASK-NN'
    Write-BcfNote '· retrospector   внутри цикла задачи, после вердикта — если подключена память'
    Write-BcfNote '· test-author · judge · ux-vision   описания есть, узлов в графе нет'
    Write-BcfNote 'поставить их в очередь галочкой нельзя — это правка графа, а не настройки.'

    Write-Host ''
    Write-Host ('  ' + (Ink 'правила, которые init не даст нарушить' 'White'))
    Write-BcfNote '· critic не сидит на модели worker: одна модель на одном контексте приходит к одной'
    Write-BcfNote '  ошибке и потом сама себе её подтверждает;'
    Write-BcfNote '· planner и critic — разные семейства: критик не защищает решение своего планировщика;'
    Write-BcfNote '· кто только смотрит — живёт на песочнице «только чтение».'
    Write-Host ''
    Write-BcfNote 'роль — это файл .claude/agents/*.md. переименовать, переписать, добавить свою — можно;'
    Write-BcfNote 'связь «роль → файл» лежит в config/agents.json одной строкой.'

    if ($interactive) {
        Write-BcfKeyHints -Pairs @(@('enter', 'дальше'), @('q', 'выход'))
        $k = Read-BcfKey
        if ($k -and $k.Key -in @('Q', 'Escape')) { return $false }
    }
    return $true
}

# ======================================================================================
#  ШАГ 5 — МОДЕЛИ НА РОЛИ
# ======================================================================================
function Get-DefaultRoles {
    param([object[]]$Survey)
    $TIERS = @{ claude = @{ frame = 'opus'; exec = 'sonnet' } }
    $names = @($Survey | Where-Object { $_.Installed -and $_.AuthOk } | ForEach-Object { $_.Name })
    function _pick([string[]]$Prefer) {
        foreach ($p in $Prefer) { if ($names -contains $p) { return $p } }
        return (@($names) | Select-Object -First 1)
    }
    $frame = _pick @('claude', 'codex', 'cursor')
    $exec  = _pick @('opencode', 'codex', 'claude')
    $critic = @($names | Where-Object { $_ -ne $exec -and $_ -ne $frame }) | Select-Object -First 1
    if (-not $critic) { $critic = @($names | Where-Object { $_ -ne $exec }) | Select-Object -First 1 }
    if (-not $critic) { $critic = $frame }
    if ($names -contains 'codex' -and $critic -eq 'codex') { $critic = 'codex-ro' }

    $roles = [ordered]@{
        planner = @{ backend = $frame;  model = $(if ($TIERS[$frame]) { $TIERS[$frame].frame } else { '' }); tier = 'рамочный' }
        arbiter = @{ backend = $frame;  model = $(if ($TIERS[$frame]) { $TIERS[$frame].frame } else { '' }); tier = 'рамочный' }
        critic  = @{ backend = $critic; model = ''; tier = 'рамочный' }
        worker  = @{ backend = $exec;   model = $(if ($TIERS[$exec]) { $TIERS[$exec].exec } else { '' }); tier = 'исполнение' }
    }

    # ЧЕГО НЕ ЗНАЕТ ЯРУС — СПРАШИВАЕМ У САМОГО БЭКЕНДА, А НЕ У ЧЕЛОВЕКА.
    #
    # Ярусы («рамочный»/«исполнение») заданы только для claude: у остальных CLI имя модели
    # решает подписка, и выдумывать его нельзя. Но оно и не выдумывается — оно записано в
    # настройках самого CLI. Пока мы туда не смотрели, init оставлял модель пустой и сам же
    # объявлял это стопором прогона, а человек вписывал руками то, что лежало у него на
    # диске.
    foreach ($k in @($roles.Keys)) {
        if ($roles[$k].model) { continue }
        $d = Get-BcfBackendDefaultModel -Name $roles[$k].backend
        if ($d.Model) {
            $roles[$k].model = $d.Model
            $roles[$k].modelSource = $d.Source
        }
    }
    return $roles
}

function Show-Step5 {
    param([object[]]$Survey, $Roles)

    while ($true) {
        Write-BcfStepHeader -Step 5 -Total $TOTAL -Title 'модели на роли и запасные модели'
        Write-Host ('  ' + (Ink 'МОДЕЛИ НА РОЛИ' 'Cyan') + '  ' +
                    (Ink 'выбираем ярус, а не цену. сколько это стоит — bcf cost, отдельно' 'DarkGray'))
        Write-Host ''

        $keys = @($Roles.Keys)
        $items = @()
        foreach ($k in $keys) {
            $m = if ($Roles[$k].model) { $Roles[$k].model } else { '(задать вручную)' }
            $fb = if ($Roles[$k].fallback) { $Roles[$k].fallback } else { 'не задана' }
            $items += @{ main = ("{0,-9} {1,-12} {2,-26} {3,-12} {4}" -f $k, $Roles[$k].backend, $m, $Roles[$k].tier, $fb)
                         note = ''; dim = (-not $Roles[$k].model) }
        }

        $hdr = { @(@{ t = '  ' + (Ink ("  {0,-9} {1,-12} {2,-26} {3,-12} {4}" -f 'роль', 'бэкенд', 'модель', 'ярус', 'запасная') 'DarkGray'); c = '' }) }
        Write-Host ''
        Write-BcfNote 'рамочных решений мало и они дорогие; исполнения много и оно дешёвое. одна'
        Write-BcfNote 'модель на всё = планировочная цена за каждый токен исполнения.'

        # ИСТОЧНИК КАЖДОЙ ПОДСТАВЛЕННОЙ МОДЕЛИ НАЗЫВАЕТСЯ ВСЛУХ. Модель, взятая из истории
        # сессий, — догадка о намерении, а не настройка: человек обязан увидеть, что её
        # выбрали за него, иначе он узнает об этом по счёту за прогон.
        $found = @($keys | Where-Object { $Roles[$_].modelSource })
        if ($found.Count) {
            Write-Host ''
            foreach ($k in $found) {
                Write-BcfField $k "$($Roles[$k].model)   ← $($Roles[$k].modelSource)" 'проверено' 12
            }
            Write-BcfNote 'это НЕ спрашивалось: значения лежат в настройках самих CLI. заменить — enter на строке.'
        }

        # ЗАПАСНАЯ — шаг необязательный, но цена отказа называется здесь, а не после того,
        # как волна встала ночью. Сразу говорим и то, на что запасная НЕ помогает: иначе
        # её ставят как оберег и удивляются, что узел всё равно упал на схеме ответа.
        $noFb = @($keys | Where-Object { -not $Roles[$_].fallback })
        if ($noFb.Count) {
            Write-Host ''
            Write-Host ('  ' + (Ink "запасная модель не задана: $($noFb -join ', ')" 'Yellow'))
            Write-BcfNote 'когда она включается — отказал ПРОВАЙДЕР, а не задача:'
            Write-BcfNote '  · 429 или исчерпан лимит плана;'
            Write-BcfNote '  · поток завис и снят по тишине;'
            Write-BcfNote '  · авторизация отвалилась на ходу;'
            Write-BcfNote '  · агент не вернул текста (молча умер).'
            Write-BcfNote 'не помогает и не включается: ответ не прошёл схему, проверки красные —'
            Write-BcfNote 'вторая модель упадёт на том же, а бюджет спишется дважды.'
            Write-BcfNote 'без запасной узел падает, волна встаёт и ждёт рук. на слиянии это больно:'
            Write-BcfNote 'worktree остаётся заклеймлённым, следующие задачи не берут те же файлы.'
        }

        if (-not $interactive) {
            foreach ($i in $items) { Write-BcfDim $i.main }
            break
        }

        $edited = $false
        $idx = Read-BcfListChoice -Items $items -Selected 0 -Header $hdr -Hints @(
            @('↑↓', 'роль'), @('enter', 'сменить модель'), @('f', 'запасная'), @('d', 'проверить живьём'), @('n', 'дальше'), @('q', 'выход')
        ) -ExtraKeys @{
            'F' = { param($i) $r = Read-Host "  запасная модель для '$($keys[$i])'"; if ($r) { $Roles[$keys[$i]].fallback = $r.Trim() }; $script:stepEdited = $true; return 'edit' }
            'N' = { param($i) return 'next' }
            'D' = { param($i) return 'doctor' }
        }
        if ($idx -eq -1) { return $null }
        if ($idx -eq 'next') { break }
        if ($idx -eq 'doctor') {
            Write-Host ''
            Write-BcfNote 'живая проба ролей тратит токены — она в отдельной команде: bcf doctor'
            continue
        }
        if ($idx -eq 'edit') { continue }
        if ($idx -is [int]) {
            $r = Read-Host "  модель для роли '$($keys[$idx])' (бэкенд $($Roles[$keys[$idx]].backend))"
            if ($r) { $Roles[$keys[$idx]].model = $r.Trim() }
            continue
        }
        break
    }

    if ($Roles.critic.backend -eq $Roles.worker.backend -and $Roles.critic.backend) {
        Write-Host ''
        Write-BcfWarn 'critic и worker на одном бэкенде'
        Write-BcfNote 'несколько агентов одной модели на одном контексте приходят к одной ошибке и'
        Write-BcfNote 'подтверждают её друг другу: приёмка станет формальностью.'
        $script:later += 'critic и worker сидят на одном бэкенде — приёмка не независима (config/harness.json → graph.roles).'
    }
    $unset = @($Roles.Keys | Where-Object { -not $Roles[$_].backend -or -not $Roles[$_].model })
    if ($unset.Count) {
        $script:blocking += @{ what = "модели не заданы для ролей: $($unset -join ', ')"
                        why  = 'узел без модели падает на старте, и волна встаёт: worktree остаётся заклеймлённым, следующие задачи не берут те же файлы.'
                        fix  = 'вписать имена моделей в config/harness.json → graph.roles.<роль>.model, затем bcf doctor' }
    }
    if (-not $Roles.arbiter.fallback) {
        $script:later += 'у роли arbiter не задана запасная модель: при 429 или зависшем стриме узел падает, волна встаёт и ждёт рук.'
    }
    return $Roles
}

# ======================================================================================
#  ШАГ 6 — ЧТО ФАБРИКА ЗНАЕТ О ПРОДУКТЕ
# ======================================================================================
function Show-Step6 {
    param([string]$Root, $Detect)

    Write-BcfStepHeader -Step 6 -Total $TOTAL -Title 'что фабрика знает о продукте'
    Write-Host ('  ' + (Ink 'ИСТОЧНИКИ ЗАМЫСЛА' 'Cyan'))
    Write-Host ''
    foreach ($f in $Detect.Docs.Files) {
        if ($f.Exists) { Write-BcfOk ("{0,-18} {1} строк · разобран" -f $f.Path, $f.Lines) }
        else { Write-BcfDim ("{0,-18} нет" -f $f.Path) }
    }

    $prdPath = Join-Path $Root 'docs\PRD.md'
    if (Test-Path $prdPath) {
        Write-Host ''
        Write-BcfOk 'docs/PRD.md есть — границы продукта заданы'
        if ($interactive) {
            Write-BcfKeyHints -Pairs @(@('enter', 'дальше'), @('q', 'выход'))
            $k = Read-BcfKey
            if ($k -and $k.Key -in @('Q', 'Escape')) { return $false }
        }
        return $true
    }

    Write-Host ''
    Write-BcfWarn 'чего для нарезки задач не хватает   4'
    Write-BcfNote '⚠ кто пользователь и что для него «работает»'
    Write-BcfNote '⚠ границы MVP: что обязано быть в первой рабочей версии'
    Write-BcfNote '⚠ что явно НЕ делаем в первой версии'
    Write-BcfNote '⚠ чем доказывается закрытая задача'
    Write-Host ''
    Write-BcfNote 'без этого планировщик нарежет задачи по коду, а не по продукту —'
    Write-BcfNote 'и первая же приёмка будет спорить с ним о смысле, за твои деньги.'
    Write-Host ''

    $script:later += 'docs/PRD.md нет: границы MVP не заданы, и приёмка будет спорить с планировщиком о смысле. Заполнить: bcf prd.'

    if (-not $interactive) { return $true }

    $items = @(
        @{ main = 'ответить сейчас 4 вопроса, ~3 минуты → docs/PRD.md'; note = ''; dim = $false }
        @{ main = 'пропустить — работаем по README, вернуться: bcf prd'; note = ''; dim = $true }
    )
    $idx = Read-BcfListChoice -Items $items -Selected 0 -Hints @(@('↑↓', 'выбрать'), @('enter', 'дальше'), @('q', 'выход'))
    if ($idx -lt 0) { return $false }
    if ($idx -eq 0) {
        & pwsh -NoProfile -File (Join-Path $BcfRoot 'bin\bcf.ps1') prd --project $Root
    }
    return $true
}

# ======================================================================================
#  ШАГ 7 — БЭКЛОГ
# ======================================================================================
function Show-Step7 {
    param([string]$Root, [string]$Prefix)

    $tasksDir = Join-Path $Root 'tasks'
    $existing = @()
    if (Test-Path $tasksDir) { $existing = @(Get-ChildItem $tasksDir -Filter "$Prefix-*.md" -File -ErrorAction SilentlyContinue) }

    Write-BcfStepHeader -Step 7 -Total $TOTAL -Title 'папка tasks: от MVP к полной версии'
    Write-Host ('  ' + (Ink 'БЭКЛОГ' 'Cyan') + '  ' +
                (Ink $(if ($existing.Count) { "задач: $($existing.Count) — не трогаем" } else { 'папки tasks/ нет' }) 'DarkGray'))
    Write-Host ''

    if ($existing.Count) {
        foreach ($t in ($existing | Select-Object -First 8)) { Write-BcfDim $t.Name }
        if ($existing.Count -gt 8) { Write-BcfDim "… ещё $($existing.Count - 8)" }
    } else {
        Write-BcfNote 'нарезку по продукту init не делает: он не зовёт агентов и не выдумывает задачи'
        Write-BcfNote 'за тебя. Создадим каркас и шаблон одной задачи; нарезать — /feature в кодовом'
        Write-BcfNote 'агенте либо руками по шаблону.'
    }

    Write-Host ''
    Write-Host ('  ' + (Ink 'чем это держится' 'White'))
    Write-BcfNote '· один файл — один владелец: задачи с непересекающимися файлами идут в одну волну'
    Write-BcfNote '· не больше 3 условий готовности на задачу и одна связная фича на задачу'
    Write-BcfNote '· задача = markdown с секциями Файлы / Готовность / Проверки, правится в редакторе'

    if ($interactive) {
        Write-BcfKeyHints -Pairs @(@('enter', 'принять'), @('q', 'выход'))
        $k = Read-BcfKey
        if ($k -and $k.Key -in @('Q', 'Escape')) { return $false }
    }
    return $true
}

# ======================================================================================
#  ХОД МАСТЕРА
# ======================================================================================
$state = Get-BcfWizardState -Project $project
if ($state -and $interactive -and $state.step -gt 1) {
    Write-Host ''
    Write-BcfWarn "инициализация прерывалась на шаге $($state.step) из $TOTAL — состояние сохранено"
    Write-BcfNote 'мастер начнёт заново, но всё уже записанное на диск останется как есть.'
}

$root = Show-Step1
if (-not $root) { Write-Host ''; Write-BcfDim 'выход — ничего не записано'; Write-Host ''; exit 130 }
$project = $root
$env:BCF_PROJECT_ROOT = $project
Save-BcfWizardState -Project $project -State @{ step = 1; root = $root }

$s2 = Show-Step2 -Root $root
if (-not $s2) { Write-Host ''; Write-BcfDim 'выход — ничего не записано'; Write-Host ''; exit 130 }
$d = $s2.Detect
Save-BcfWizardState -Project $project -State @{ step = 2; root = $root }

$survey = Show-Step3
if (-not $survey) { Write-Host ''; Write-BcfDim 'выход — ничего не записано'; Write-Host ''; exit 130 }
Save-BcfWizardState -Project $project -State @{ step = 3; root = $root }

# Префикс задач нужен уже четвёртому шагу (он считает очередь), а не только записи:
# проект мог переименовать TASK- во что-то своё, и очередь по чужому префиксу пуста.
$prefix = 'TASK'
try { $c0 = Get-BcfHarnessConfig -Project $root; if ($c0 -and $c0.taskIdPrefix) { $prefix = [string]$c0.taskIdPrefix } } catch { }

if (-not (Show-Step4 -Root $root)){ Write-Host ''; Write-BcfDim 'выход — ничего не записано'; Write-Host ''; exit 130 }
Save-BcfWizardState -Project $project -State @{ step = 4; root = $root }

$roles = Show-Step5 -Survey $survey -Roles (Get-DefaultRoles -Survey $survey)
if (-not $roles) { Write-Host ''; Write-BcfDim 'выход — ничего не записано'; Write-Host ''; exit 130 }
Save-BcfWizardState -Project $project -State @{ step = 5; root = $root; roles = $roles }

if (-not (Show-Step6 -Root $root -Detect $d)) { Write-Host ''; Write-BcfDim 'выход'; Write-Host ''; exit 130 }
Save-BcfWizardState -Project $project -State @{ step = 6; root = $root; roles = $roles }

if (-not (Show-Step7 -Root $root -Prefix $prefix)){ Write-Host ''; Write-BcfDim 'выход'; Write-Host ''; exit 130 }
Save-BcfWizardState -Project $project -State @{ step = 7; root = $root; roles = $roles }

# ======================================================================================
#  ШАГ 8 — ЗАПИСЬ
# ======================================================================================
Write-BcfStepHeader -Step 8 -Total $TOTAL -Title 'итог инициализации'
Write-Host ('  ' + (Ink 'ФАБРИКА НАСТРОЕНА' 'Cyan') + '  ' +
            (Ink "$(Split-Path $root -Leaf) · 8 шагов · агентов не звали" 'DarkGray'))
Write-Host ''
if ($dry) {
    Write-BcfWarn 'сухой прогон: на диск ничего не записано.'
} else {
    Write-BcfNote 'всё, что записано, — текстовые файлы под git. откатить: git checkout .'
}
Write-Host ''

. (Join-Path $BcfRoot 'src\commands\init-write.ps1')

Write-BcfManualActions -Blocking $blocking -Later $later

Write-Host ''
Write-Host ('  ' + (Ink 'ДАЛЬШЕ' 'White'))
Write-Host ('    ' + (Ink 'bcf doctor' 'Cyan')          + '           живая проба всех ролей, без работы')
Write-Host ('    ' + (Ink 'bcf prd' 'Cyan')             + '              четыре вопроса о продукте → docs/PRD.md')
Write-Host ('    ' + (Ink 'bcf memory init' 'Cyan')     + '      подключить память: без неё прогоны не учатся')
Write-Host ('    ' + (Ink 'bcf run queue' 'Cyan')       + '        первая волна')
Write-Host ''

if (-not $dry) { Clear-BcfWizardState -Project $project }
exit $(if ($blocking.Count) { 1 } else { 0 })
