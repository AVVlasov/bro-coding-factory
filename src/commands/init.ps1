# bcf init — настройка фабрики под проект. Восемь шагов, всё в текстовые файлы.
#
#   bcf init                настроить (интерактивно)
#   bcf init --yes          без вопросов: везде значение по умолчанию, но каждое названо
#   bcf init --dry          показать решения, ничего не записав
#
# ПРАВИЛА ЭТОГО МАСТЕРА:
#   · каждый шаг заканчивается текстовым файлом, который можно открыть и поправить руками;
#   · у каждого предложения виден источник — «проверено», «уверенно» или «догадка»;
#   · цены не показываются: init настраивает, а не продаёт. Смета — отдельной командой;
#   · агентов не зовём. Ни один токен здесь не тратится, кроме живой пробы в шаге 3.

. (Join-Path $BcfRoot 'src\lib\detect.ps1')
. (Join-Path $BcfRoot 'src\lib\backends.ps1')

$dry = $script:BcfArgs -contains '--dry'
$project = $script:BcfProject
$projName = Split-Path $project -Leaf
$templates = Get-BcfTemplates
$state = if ($dry) { Join-Path $project '.bcf' } else { Get-BcfProjectState -Project $project }

$blocking = @()
$later = @()
$writtenFiles = @()

Write-Host ''
Write-BcfLine "  BRO CODING FACTORY v$(Get-BcfVersion) · инициализация" 'Cyan'
Write-BcfLine '  настроим фабрику под проект. восемь шагов, всё пишется в текстовые файлы,' 'DarkGray'
Write-BcfLine '  выйти можно на любом — записанное остаётся под git, откат: git checkout .' 'DarkGray'

# =====================================================================================
Write-BcfTitle 'ШАГ 1 / 8 — ГДЕ ПРОЕКТ' $project
# =====================================================================================

$git = Get-BcfGitState -Root $project
if ($git.IsGit) {
    Write-BcfOk 'git-репозиторий — значит слияния пойдут через worktree, а не поверх дерева'
} else {
    Write-BcfFail 'НЕ git-репозиторий'
    $blocking += @{ what = 'проект не под git'
                    why  = 'слияния идут через worktree, а снапшоты работы — через git-refs. Без репозитория ни то, ни другое невозможно: потерянную итерацию восстановить будет нечем.'
                    fix  = 'git init && git add -A && git commit -m "initial"' }
}

$card = Get-BcfProjectCard -Project $project
if ($card) {
    Write-BcfWarn "инициализация уже проходила ($($card.installedAt)) — существующие файлы не перезапишем"
} else {
    Write-BcfOk 'папки .bcf нет — инициализация первая, ничего не перезапишем'
}

if ($git.IsGit -and $git.Dirty.Count) {
    Write-BcfWarn "$($git.Dirty.Count) файлов не закоммичено — фабрика начнёт с грязного дерева"
    Write-BcfNote (($git.Dirty | Select-Object -First 6) -join '   ')
    $blocking += @{ what = "$($git.Dirty.Count) файлов не закоммичено"
                    why  = 'первое же слияние затянет эти правки в чужую задачу, и разбираться будешь ты, а не арбитр.'
                    fix  = 'git commit -am "wip"   или   git stash' }
}

# =====================================================================================
Write-BcfTitle 'ШАГ 2 / 8 — РАЗБОР ПРОЕКТА' 'читаем файлы, ничего не пишем'
# =====================================================================================

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-BcfDetect -Root $project -Probe
$sw.Stop()

$top = @($d.Languages.Languages | Select-Object -First 4)
Write-BcfField 'языки' $(if ($top.Count) { ($top | ForEach-Object { "$($_.Language) $($_.Percent)%" }) -join '   ' } else { '(исходников не найдено)' })
Write-BcfField 'сборка' $(if ($d.Ecosystems.Count) { $d.Ecosystems -join ', ' } else { '(манифестов не найдено)' })
Write-BcfField 'файлов' "$($d.Languages.Total) прочитано за $([math]::Round($sw.Elapsed.TotalSeconds,1)) с"
Write-Host ''
Write-BcfLine '  ПРЕДЛАГАЕМ ЗАПИСАТЬ В config/harness.json' 'White'
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
        Write-BcfField 'backpressure' "$t   ← $why" 'догадка' 18
        if ($p) {
            $blocking += @{ what = "быстрая проверка падает: $t"
                            why  = 'она вызывается КАЖДУЮ итерацию — гейт будет красным всегда, и агент начнёт чинить несуществующее.'
                            fix  = "последние строки вывода:`n     " + ($p.Output -replace "`n", "`n     ") }
        }
    }
}
if (-not $d.Typechecks.Count) { Write-BcfField 'backpressure' '(быстрой проверки не нашлось)' 'догадка' 18 }

Write-BcfField 'generatedFiles' $(if ($d.Generated.Count) { $d.Generated -join ', ' } else { '(нет)' }) `
               $(if ($d.Generated.Count) { 'уверенно' } else { 'догадка' }) 18
$runnerVal = if (-not $d.Tests.runner) { '(не определился)' }
             elseif ($d.Runners.Count -gt 1) { "$($d.Tests.runner)   ← найдено $($d.Runners.Count): $((($d.Runners | ForEach-Object { "$($_.Runner)$(if ($_.Scope) { " в $($_.Scope)" })" }) -join ', '))" }
             else { $d.Tests.runner }
Write-BcfField 'tests.runner' $runnerVal `
               $(if (-not $d.Tests.runner) { 'догадка' } elseif ($d.Runners.Count -gt 1) { 'догадка' } else { 'уверенно' }) 18

Write-Host ''
Write-BcfNote 'productPaths решает, где искать «прогресса нет» и расползание скоупа.'
Write-BcfNote 'generatedFiles — что не блокирует слияние: один лок-файл уже валил семь задач подряд.'

if (-not $d.Tests.runner) {
    $later += 'раннер тестов не определился (config/harness.json → tests.runner): пока он пуст, задача может получить PASS без единого нового теста.'
}
if ($d.Runners.Count -gt 1) {
    $later += "раннеров тестов найдено $($d.Runners.Count) ($((($d.Runners | ForEach-Object { $_.Runner }) -join ', '))), а гейт «фича доказана тестами» одноместный: задачи второго стека будут проверяться чужим раннером. Выбери основной в config/harness.json → tests.runner и закрой второй стек явными командами в config/checks.json."
}

# =====================================================================================
Write-BcfTitle 'ШАГ 3 / 8 — КОДОВЫЕ АГЕНТЫ' 'опрашиваем установленные CLI, авторизации проверяем живьём'
# =====================================================================================

$survey = Invoke-BcfBackendSurvey
$avail = @($survey | Where-Object { $_.Installed -and $_.AuthOk })

foreach ($r in $survey) {
    if (-not $r.Installed) { Write-BcfDim ("{0,-11} не установлен" -f $r.Name); continue }
    if (-not $r.AuthOk) {
        Write-BcfFail ("{0,-11} НЕ АВТОРИЗОВАН" -f $r.Name)
        if ($r.AuthDetail) { Write-BcfNote $r.AuthDetail }
        continue
    }
    $flags = @()
    if ((Get-BcfKnownBackends)[$r.Name].ro) { $flags += 'песочница ro' }
    if (-not $r.Tokens) { $flags += 'расход токенов НЕ виден' }
    Write-BcfOk ("{0,-11} {1,-10} {2}" -f $r.Name, $(if ($r.Version) { "v$($r.Version)" } else { '' }), ($flags -join ' · '))
    if (-not $r.OnPath) { Write-BcfNote "не на PATH, закрепим путь: $($r.Path)" }
    if (-not $r.Tokens) { Write-BcfNote 'бюджетный ограничитель на этой роли будет слеп: узлы выглядят нулевыми.' }
}

if (-not $avail.Count) {
    Write-Host ''
    Write-BcfFail 'ни одного авторизованного кодового агента — исполнять узлы нечем'
    $blocking += @{ what = 'нет ни одного авторизованного кодового CLI'
                    why  = 'граф и цикл исполняют работу через внешний CLI-агент. Без него настройка запишется, но ни один прогон не поедет.'
                    fix  = 'поставь и авторизуй хотя бы один: claude / opencode / codex / cursor-agent' }
}

# Песочница «только чтение» есть не у всех. Роль, которая обязана лишь смотреть, на
# бэкенде без неё получает право писать — и однажды что-нибудь поправит «по пути».
$roBackends = @((Get-BcfKnownBackends).Keys | Where-Object {
    $b = (Get-BcfKnownBackends)[$_]
    $b.ro -and ($avail | Where-Object { $_.Name -eq $b.aliasOf -or $_.Name -eq $_ })
})
Write-Host ''
if ($roBackends.Count) {
    Write-BcfNote "песочница «только чтение» доступна: $($roBackends -join ', ') — туда пойдут критик и ресёрчер."
} else {
    Write-BcfNote 'песочницы «только чтение» нет ни у одного установленного CLI: роли-наблюдатели получат право писать.'
    $later += 'ни один установленный CLI не даёт песочницу «только чтение»: критик и ресёрчер смогут править файлы, и однажды что-нибудь поправят «по пути».'
}

# =====================================================================================
Write-BcfTitle 'ШАГ 4 / 8 — РОЛИ ГРАФА' 'шаблон «рой, 4 роли»'
# =====================================================================================

$phaseRows = New-BcfRows
Add-BcfRow $phaseRows @('Разметка', 'planner',          '1 — дорогой, решает рамку')
Add-BcfRow $phaseRows @('Работа',   'worker → arbiter', '6 + слияния — дешёвые, их много')
Add-BcfRow $phaseRows @('Приёмка',  'critic ×N',        'N — читают слитое дерево')
Add-BcfRow $phaseRows @('Итог',     '(скрипт)',         '0 — без модели')
Write-BcfTable -Headers @('фаза', 'роли', 'узлов на очередь из 6 задач') -Widths @(12, 22, 40) -Rows $phaseRows
Write-Host ''
Write-BcfOk 'planner   рамка: DAG по зависимостям, коллизии владения файлами, вердикт'
Write-BcfOk 'worker    исполнение: одна задача — один агент — один файл-владелец'
Write-BcfOk 'arbiter   слияние: снимает конфликты, решает, чей вариант остаётся'
Write-BcfOk 'critic    приёмка разными ракурсами по слитому дереву'
Write-Host ''
Write-BcfNote 'правила, которые init не даст нарушить:'
Write-BcfNote '· critic не сидит на модели worker — одна модель на одном контексте приходит к одной'
Write-BcfNote '  ошибке и потом сама себе её подтверждает;'
Write-BcfNote '· planner и critic из разных семейств — критик не защищает решение своего планировщика;'
Write-BcfNote '· кто только смотрит — живёт на песочнице «только чтение».'

# =====================================================================================
Write-BcfTitle 'ШАГ 5 / 8 — МОДЕЛИ НА РОЛИ' 'выбираем ярус, а не цену. сколько это стоит — bcf cost, отдельно'
# =====================================================================================

# Ярус, а не цена: рамочных решений мало и они дорогие, исполнения много и оно дешёвое.
# Одна модель на всё = планировочная цена за каждый токен исполнения.
$TIERS = @{
    claude   = @{ frame = 'opus';  exec = 'sonnet' }
    codex    = @{ frame = '';      exec = '' }
    'codex-ro' = @{ frame = '';    exec = '' }
    cursor   = @{ frame = '';      exec = '' }
    opencode = @{ frame = '';      exec = '' }
    gemini   = @{ frame = '';      exec = '' }
    aider    = @{ frame = '';      exec = '' }
}

$names = @($avail | ForEach-Object { $_.Name })
$hasRo = @($names | Where-Object { (Get-BcfKnownBackends)["$_-ro"] }) | Select-Object -First 1

function _pickBackend([string[]]$Prefer, [string]$Fallback) {
    foreach ($p in $Prefer) { if ($names -contains $p) { return $p } }
    return $Fallback
}

$frameBackend = _pickBackend @('claude', 'codex', 'cursor') ($names | Select-Object -First 1)
$execBackend  = _pickBackend @('opencode', 'codex', 'claude') ($names | Select-Object -First 1)
$criticBackend = @($names | Where-Object { $_ -ne $execBackend -and $_ -ne $frameBackend }) | Select-Object -First 1
if (-not $criticBackend) { $criticBackend = @($names | Where-Object { $_ -ne $execBackend }) | Select-Object -First 1 }
if (-not $criticBackend) { $criticBackend = $frameBackend }
if ($hasRo -and $criticBackend -eq $hasRo) { $criticBackend = "$hasRo-ro" }

$roles = [ordered]@{
    planner = @{ backend = $frameBackend;  model = $TIERS[$frameBackend].frame }
    arbiter = @{ backend = $frameBackend;  model = $TIERS[$frameBackend].frame }
    critic  = @{ backend = $criticBackend; model = $TIERS[($criticBackend -replace '-ro$', '')].frame }
    worker  = @{ backend = $execBackend;   model = $TIERS[$execBackend].exec }
}

$rows = New-BcfRows
$colors = @()
foreach ($k in $roles.Keys) {
    $b = $roles[$k].backend
    $m = if ($roles[$k].model) { $roles[$k].model } else { '(задать вручную)' }
    $tier = if ($k -eq 'worker') { 'исполнение' } else { 'рамочный' }
    Add-BcfRow $rows @($k, $(if ($b) { $b } else { '—' }), $m, $tier)
    $colors += $(if ($b -and $roles[$k].model) { '' } else { 'Yellow' })
}
Write-BcfTable -Headers @('роль', 'бэкенд', 'модель', 'ярус') -Widths @(10, 14, 26, 14) -Rows $rows -RowColors $colors
Write-Host ''
Write-BcfNote 'рамочных решений мало и они дорогие; исполнения много и оно дешёвое. одна модель'
Write-BcfNote 'на всё = планировочная цена за каждый токен исполнения.'

# Проверяем те самые три правила и НАЗЫВАЕМ цену нарушения, а не просто «нельзя».
if ($roles.critic.backend -eq $roles.worker.backend -and $roles.critic.backend) {
    Write-Host ''
    Write-BcfWarn 'critic и worker на одном бэкенде'
    Write-BcfNote 'несколько агентов одной модели на одном контексте приходят к одной ошибке и подтверждают её друг другу: приёмка станет формальностью.'
    $later += 'critic и worker сидят на одном бэкенде — приёмка не независима. Разнести: config/harness.json → graph.roles.'
}
$unset = @($roles.Keys | Where-Object { -not $roles[$_].backend -or -not $roles[$_].model })
if ($unset.Count) {
    Write-Host ''
    Write-BcfWarn "модель не выбрана для ролей: $($unset -join ', ')"
    Write-BcfNote 'у этих бэкендов нет общепринятого имени модели по умолчанию — его задаёт подписка.'
    $blocking += @{ what = "модели не заданы для ролей: $($unset -join ', ')"
                    why  = 'узел без модели падает на старте, и волна встаёт: worktree остаётся заклеймлённым, следующие задачи не берут те же файлы.'
                    fix  = 'вписать имена моделей в config/harness.json → graph.roles.<роль>.model, затем bcf doctor' }
}

# Запасная модель. Шаг необязательный, но цена отказа называется.
foreach ($k in @('arbiter')) {
    if (-not $roles[$k].fallback) {
        $later += "у роли $k не задана запасная модель (graph.roles.$k.fallback): при 429 или зависшем стриме узел падает, волна встаёт и ждёт рук."
    }
}

# =====================================================================================
Write-BcfTitle 'ШАГ 6 / 8 — ЧТО ФАБРИКА ЗНАЕТ О ПРОДУКТЕ' 'источники замысла'
# =====================================================================================

foreach ($f in $d.Docs.Files) {
    if ($f.Exists) { Write-BcfOk ("{0,-16} {1} строк" -f $f.Path, $f.Lines) }
    else { Write-BcfDim ("{0,-16} нет" -f $f.Path) }
}

$prdPath = Join-Path $project 'docs\PRD.md'
$hasPrd = Test-Path $prdPath
if (-not $hasPrd) {
    Write-Host ''
    Write-BcfWarn 'docs/PRD.md нет — для нарезки задач не хватает четырёх ответов:'
    Write-BcfNote '· кто пользователь и что для него «работает»'
    Write-BcfNote '· границы MVP: что обязано быть в первой рабочей версии'
    Write-BcfNote '· что явно НЕ делаем в первой версии'
    Write-BcfNote '· чем доказывается закрытая задача'
    Write-Host ''
    Write-BcfNote 'без этого планировщик нарежет задачи по коду, а не по продукту — и первая же'
    Write-BcfNote 'приёмка будет спорить с ним о смысле, за твои деньги.'
    $later += 'docs/PRD.md нет: границы MVP не заданы, и приёмка будет спорить с планировщиком о смысле. Заполнить: bcf prd.'
}

# =====================================================================================
Write-BcfTitle 'ШАГ 7 / 8 — БЭКЛОГ' 'папка tasks/'
# =====================================================================================

$prefix = 'TASK'
$tasksDir = Join-Path $project 'tasks'
$existing = @()
if (Test-Path $tasksDir) {
    $existing = @(Get-ChildItem $tasksDir -Filter "$prefix-*.md" -File -ErrorAction SilentlyContinue)
}
if ($existing.Count) {
    Write-BcfOk "задач в бэклоге: $($existing.Count) — не трогаем"
    foreach ($t in ($existing | Select-Object -First 6)) { Write-BcfDim $t.Name }
} else {
    Write-BcfDim 'бэклога нет — создадим каркас и шаблон одной задачи'
    Write-BcfNote 'нарезку по продукту делает не init: он не зовёт агентов и не выдумывает задачи'
    Write-BcfNote 'за тебя. Нарезать — /feature в кодовом агенте либо руками по шаблону.'
}
Write-Host ''
Write-BcfNote 'чем держится бэклог:'
Write-BcfNote '· один файл — один владелец: задачи с непересекающимися файлами идут в одну волну;'
Write-BcfNote '· не больше трёх условий готовности на задачу и одна связная фича на задачу;'
Write-BcfNote '· задача = markdown с секциями Файлы / Готовность / Проверки, правится в редакторе.'

# =====================================================================================
Write-BcfTitle 'ШАГ 8 / 8 — ЗАПИСЬ' $(if ($dry) { 'сухой прогон: на диск ничего не пойдёт' } else { 'всё записанное — текстовые файлы под git' })
# =====================================================================================

if (-not $dry) {
    # 1. Ставим обвязку тем же кодом, что и `bcf install` — двух реализаций «что положить
    #    в проект» быть не должно, они разъедутся на первом же изменении шаблонов.
    $installOut = & pwsh -NoProfile -File (Join-Path $BcfRoot 'bin\bcf.ps1') install `
                        --project $project $(if (Get-BcfAssumeYes) { '--yes' }) 2>&1 | Out-String

    # 2. Дописываем в конфиг то, что выяснили разбором и опросом.
    #
    # ПРАВИЛО: init ЗАПОЛНЯЕТ ПУСТОЕ, а не переписывает заполненное.
    #
    # Проект мог настраиваться руками или прошлой версией фабрики, и там уже стоят
    # выверенные бэкенды с моделями — включая те, которые init угадать не может (имя
    # модели задаёт подписка). Молча заменить их своими догадками значит сломать рабочую
    # конфигурацию мастером, который человек запустил «просто посмотреть». Замена делается
    # только по явной просьбе: bcf init --reconfigure.
    $reconfigure = $script:BcfArgs -contains '--reconfigure'
    $cfgPath = Join-Path $project 'config\harness.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $kept = @()

    function _SetIfEmpty([string]$Name, $Current, $New, [scriptblock]$Apply) {
        $isEmpty = ($null -eq $Current) -or ($Current -is [string] -and -not $Current) -or
                   ($Current -is [array] -and -not @($Current).Count)
        if ($isEmpty -or $reconfigure) { & $Apply; return $true }
        $script:kept += $Name
        return $false
    }

    _SetIfEmpty 'productPaths' $cfg.productPaths @($productPaths) { $cfg.productPaths = @($productPaths) } | Out-Null
    _SetIfEmpty 'generatedFiles' $cfg.generatedFiles @($d.Generated) { $cfg.generatedFiles = @($d.Generated) } | Out-Null
    _SetIfEmpty 'backpressure.typecheck' $cfg.backpressure.typecheck @($typechecks) { $cfg.backpressure.typecheck = @($typechecks) } | Out-Null
    if ($d.Tests.runner) { _SetIfEmpty 'tests.runner' $cfg.tests.runner $d.Tests.runner { $cfg.tests.runner = $d.Tests.runner } | Out-Null }

    # Бэкенды дополняем, а не заменяем: у проекта может быть свой, которого нет в
    # каталоге фабрики (собственная обёртка, локальная модель).
    $surveyed = New-BcfBackendConfig -Survey $survey
    foreach ($bk in $surveyed.Keys) {
        if ($cfg.graph.backends.PSObject.Properties[$bk] -and -not $reconfigure) { continue }
        $cfg.graph.backends | Add-Member -NotePropertyName $bk -NotePropertyValue ([pscustomobject]$surveyed[$bk]) -Force
    }

    foreach ($k in $roles.Keys) {
        $cur = $cfg.graph.roles.PSObject.Properties[$k]
        if ($cur -and $cur.Value.backend -and -not $reconfigure) { $kept += "graph.roles.$k"; continue }
        $cfg.graph.roles | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{ backend = $roles[$k].backend; model = $roles[$k].model }) -Force
    }

    # Цикл (одна задача, много итераций) исполняется тем же бэкендом, что и worker графа:
    # два разных исполнителя означали бы, что задача ведёт себя по-разному в зависимости
    # от того, как её запустили.
    $workerBackend = [string]$cfg.graph.roles.worker.backend
    if ($workerBackend -and $cfg.graph.backends.PSObject.Properties[$workerBackend]) {
        _SetIfEmpty 'agent.command' $cfg.agent.command $cfg.graph.backends.$workerBackend.command {
            $cfg.agent.command = $cfg.graph.backends.$workerBackend.command
            $cfg.agent.adapter = $cfg.graph.backends.$workerBackend.format
        } | Out-Null
    }
    $workerModel = [string]$cfg.graph.roles.worker.model
    $criticModel = [string]$cfg.graph.roles.critic.model
    if ($workerModel) { _SetIfEmpty 'models.code' $cfg.models.code $workerModel { $cfg.models.code = $workerModel } | Out-Null }
    if ($criticModel) {
        _SetIfEmpty 'models.tester' $cfg.models.tester $criticModel { $cfg.models.tester = $criticModel } | Out-Null
        _SetIfEmpty 'models.judge'  $cfg.models.judge  $criticModel { $cfg.models.judge  = $criticModel } | Out-Null
    }

    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $writtenFiles += 'config/harness.json'

    # 3. Каркас бэклога.
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    $indexPath = Join-Path $tasksDir 'index.md'
    if (-not (Test-Path $indexPath)) {
        Set-Content -LiteralPath $indexPath -Encoding UTF8 -Value @"
# Бэклог — $projName

Задачи именуются ``$prefix-<NN>-<slug>.md``. Планировщик строит волны по секциям
«Вход» (предшествования) и «Файлы» (владение): задачи без общих файлов и без общего
входа идут одновременно.

| id | что | владеет файлами | вход |
|----|-----|-----------------|------|
|    |     |                 |      |
"@
        $writtenFiles += 'tasks/index.md'
    }
    $samplePath = Join-Path $tasksDir "$prefix-01-example.md"
    if (-not $existing.Count -and -not (Test-Path $samplePath)) {
        $tpl = Get-Content -Raw -LiteralPath (Join-Path $templates 'project\task.md')
        $tpl = $tpl -replace '\{\{TASK_ID\}\}', "$prefix-01" -replace '\{\{TASK_TITLE\}\}', 'первая задача (шаблон — переписать)'
        Set-Content -LiteralPath $samplePath -Value $tpl -Encoding UTF8
        $writtenFiles += "tasks/$prefix-01-example.md"
    }

    # 4. Карточка проекта.
    $card = Get-BcfProjectCard -Project $project
    if (-not $card) { $card = [pscustomobject]@{} }
    $card | Add-Member -NotePropertyName 'name'        -NotePropertyValue $projName -Force
    $card | Add-Member -NotePropertyName 'initAt'      -NotePropertyValue (Get-Date -Format 'o') -Force
    $card | Add-Member -NotePropertyName 'bcfVersion'  -NotePropertyValue (Get-BcfVersion) -Force
    $card | Add-Member -NotePropertyName 'bcfHome'     -NotePropertyValue (Get-BcfHome) -Force
    $card | Add-Member -NotePropertyName 'ecosystems'  -NotePropertyValue @($d.Ecosystems) -Force
    Save-BcfProjectCard -Project $project -Card $card

    Write-BcfLine '  ЗАПИСАНО НА ДИСК' 'White'
    Write-Host ''
    foreach ($line in ($installOut -split "`r?`n")) {
        if ($line -match '^\s+A\s+') { Write-BcfLine $line 'Green' }
    }
    foreach ($w in $writtenFiles) { Write-BcfLine "    M  $w" 'Cyan' }
    Write-BcfLine '    A  .bcf/  (прогоны, заявки на файлы, журналы — в git не попадает)' 'Green'

    if ($kept.Count) {
        Write-Host ''
        Write-BcfLine "  ОСТАВЛЕНО КАК БЫЛО  $($kept.Count)" 'DarkCyan'
        Write-BcfNote 'эти значения уже были заполнены — init их не трогает:'
        foreach ($k in ($kept | Sort-Object -Unique)) { Write-BcfDim $k }
        Write-BcfNote 'заменить своими догадками: bcf init --reconfigure (существующее будет потеряно).'
    }
} else {
    Write-BcfWarn 'сухой прогон: на диск ничего не записано.'
}

Write-BcfManualActions -Blocking $blocking -Later $later

Write-Host ''
Write-BcfLine '  ДАЛЬШЕ' 'White'
Write-Host '    bcf doctor           живая проба всех ролей, без работы'
Write-Host '    bcf prd              четыре вопроса о продукте → docs/PRD.md'
Write-Host '    bcf memory init      подключить память: без неё прогоны не учатся'
Write-Host '    bcf cost --estimate  смета очереди — отдельная команда, по желанию'
Write-Host '    bcf run queue        первая волна'
Write-Host ''
exit $(if ($blocking.Count) { 1 } else { 0 })
