# bcf run — запуск работы. Два движка, разная экономика.
#
#   bcf run loop <TASK>     ЦИКЛ по одной задаче: свежий контекст каждую итерацию
#   bcf run night           ЦИКЛ по всей очереди, автономно (ночной прогон)
#   bcf run queue           ГРАФ: очередь волнами по зависимостям, слияния арбитром
#   bcf run review          ГРАФ: разноракурсная приёмка по слитому дереву
#
# ЧЕМ ОНИ ОТЛИЧАЮТСЯ. Цикл — многопроходный: «работа задачи» и «её интеграция» это один
# неделимый шаг, задачи идут по очереди. Граф разносит их по разным узлам и убирает
# барьер: одна задача сливается и проверяется, пока другая ещё пишет код. Цикл дешевле и
# предсказуемее на ночь; граф быстрее по стенным часам и дороже, потому что зовёт
# арбитра и критиков.
#
# Общие флаги:
#   --dry-plan          показать план, не запуская ни одного агента
#   --yes               не спрашивать подтверждения (граф спрашивает: рой стоит денег)
#   --budget <токены>   потолок на прогон — ТОЛЬКО граф (loop и night отказывают вслух)
#   --concurrency <N>   сколько узлов/задач одновременно
#   --resume <runId>    доиграть оборванный прогон — ТОЛЬКО граф (у цикла нет runId)
#   --max-iterations N  потолок итераций на задачу (цикл)

# bcf.ps1 подключает только paths.ps1 и ui.ps1 — остальное каждая команда берёт сама.
# tui.ps1 нужен здесь ради Test-BcfInteractive: без него `bcf run` падал на выборе
# режима отрисовки уже ПОСЛЕ того, как показал карточку и принял выбор задач, — то есть
# ровно в момент запуска, когда человек уже считает, что прогон начался.
. (Join-Path $BcfRoot 'src\lib\tui.ps1')

$project = $script:BcfProject
$harness = Get-BcfHarness

$mode = ''
$task = ''
$passthru = @()
$dryPlan = $false
$budget = 0
$conc = 0
$resume = ''
$maxIter = 0

# Флаг со значением в конце строки теряется молча: индекс за границей массива в
# PowerShell не ошибка, а $null. Для --budget это тихое отключение потолка расходов —
# прогон уходит без предохранителя, и человек узнаёт об этом по счёту.
function Get-BcfFlagValue {
    param([string]$Flag, [int]$Index)
    if ($Index -ge $script:BcfArgs.Count -or [string]::IsNullOrWhiteSpace([string]$script:BcfArgs[$Index])) {
        Write-BcfFail "$($Flag) указан без значения"
        Write-Host ''
        exit 2
    }
    return [string]$script:BcfArgs[$Index]
}
function Get-BcfFlagNumber {
    param([string]$Flag, [int]$Index, [type]$T)
    # Приведение через -as, а не TryParse: каст в PowerShell идёт по инвариантной
    # культуре, TryParse — по текущей, и «12.5» на русской локали отвалился бы.
    # Отказ молчаливому нулю здесь и был дефект: 0 у бюджета означает «без лимита».
    $raw = Get-BcfFlagValue -Flag $Flag -Index $Index
    $n = $raw -as $T
    if ($null -eq $n) {
        Write-BcfFail "$($Flag): «$raw» не число"
        Write-Host ''
        exit 2
    }
    return $n
}

for ($i = 0; $i -lt $script:BcfArgs.Count; $i++) {
    $a = [string]$script:BcfArgs[$i]
    # break обязателен в каждой ветке: PowerShell-switch без него проверяет ОСТАЛЬНЫЕ
    # условия тоже, и `--dry-plan` уходил ещё и в общую ветку '^-', то есть попадал в
    # аргументы харнесса как неизвестный флаг.
    switch -Regex ($a) {
        '^--dry-plan$'       { $dryPlan = $true; break }
        '^--budget$'         { $budget = Get-BcfFlagNumber -Flag '--budget' -Index ($i + 1) -T ([double]); break }
        '^--concurrency$'    { $conc = Get-BcfFlagNumber -Flag '--concurrency' -Index ($i + 1) -T ([int]); break }
        '^--resume$'         { $resume = Get-BcfFlagValue -Flag '--resume' -Index ($i + 1); break }
        '^--max-iterations$' { $maxIter = Get-BcfFlagNumber -Flag '--max-iterations' -Index ($i + 1) -T ([int]); break }
        '^-'                 { $passthru += $a; break }
        default {
            if (-not $mode) { $mode = $a } elseif (-not $task) { $task = $a } else { $passthru += $a }
        }
    }
}

if (-not $mode) {
    Write-BcfTitle 'ЧТО ЗАПУСКАЕМ' 'у движков разная экономика — выбор не косметический'
    Write-BcfLine '    loop <TASK>   цикл по одной задаче: свежий контекст каждую итерацию' 'White'
    Write-BcfNote 'дешевле и предсказуемее; работа и интеграция — один неделимый шаг'
    Write-BcfLine '    night         цикл по всей очереди, автономно (ночной прогон)' 'White'
    Write-BcfNote 'останов между задачами — файл .bcf/STOP; итог — .bcf/REVIEW.md'
    Write-BcfLine '    queue         граф: волны по зависимостям, слияния арбитром' 'White'
    Write-BcfNote 'быстрее по стенным часам, дороже: добавляются арбитр и критики'
    Write-BcfLine '    review        граф: разноракурсная приёмка по слитому дереву' 'White'
    Write-BcfNote 'каждая находка обязана пережить попытку её опровергнуть'
    Write-Host ''
    exit 2
}

# Прогон без настройки — самая дорогая из возможных ошибок: он поедет и упрётся на
# первом узле, потратив время и часть бюджета. Поэтому проверка есть.
#
# Но проверять надо ТО, ЧТО НУЖНО ПРОГОНУ, а не то, проходил ли мастер настройки.
# Наличие .bcf/project.json как условие отвергало проект с полностью рабочим боевым
# конфигом только потому, что его настраивали не через `bcf init` — то есть требовало
# переделать заново уже сделанное. Карточка — метаданные, а не допуск.
$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { Write-BcfFail $_.Exception.Message; exit 2 }
if (-not $cfg) {
    Write-BcfFail 'config/harness.json не найден — харнесс не настроен под этот проект'
    Write-BcfNote 'настроить: bcf init   ·   поставить обвязку без опроса: bcf install'
    exit 2
}

# У движков разные требования, и назвать надо именно недостающее.
$missing = @()
if ($mode -in @('queue', 'review')) {
    $needed = if ($mode -eq 'review') { @('critic') } else { @('planner', 'worker', 'arbiter', 'critic') }
    foreach ($r in $needed) {
        $role = if ($cfg.graph -and $cfg.graph.roles) { $cfg.graph.roles.PSObject.Properties[$r] } else { $null }
        if (-not $role -or -not $role.Value.backend) { $missing += "graph.roles.$r.backend" }
        elseif (-not $cfg.graph.backends.PSObject.Properties[[string]$role.Value.backend]) {
            $missing += "graph.backends.$([string]$role.Value.backend) (на него ссылается роль $r)"
        }
    }
} else {
    if (-not $cfg.agent -or -not $cfg.agent.command) { $missing += 'agent.command' }
}
if ($missing.Count) {
    Write-BcfFail "в config/harness.json не заполнено: $($missing -join ', ')"
    Write-BcfNote 'без этого прогон упрётся на первом же узле, потратив время и часть бюджета.'
    Write-BcfNote 'заполнить опросом установленных CLI: bcf init   ·   проверить: bcf doctor'
    exit 2
}

# Карточки может не быть — это не блокер, но сказать стоит: часть команд (например
# сведения о том, когда и чем проект настраивали) опирается на неё.
if (-not (Get-BcfProjectCard -Project $project)) {
    Write-BcfDim 'карточки .bcf/project.json нет — проект настраивали не через bcf init. Прогон это не блокирует.'
}

# ФЛАГ, КОТОРЫЙ НЕ ДЕЙСТВУЕТ, ОБЯЗАН ОТКАЗАТЬ ВСЛУХ.
#
# --budget и --resume разбирались общим кодом выше и в ветки цикла просто не передавались:
# `bcf run night --budget 500000` проглатывал потолок молча, и самый длинный прогон из трёх
# шёл вообще без предохранителя расходов. Это тот же класс, что `--budget` без значения,
# убранный раньше: человек узнаёт о неработающем потолке по счёту.
#
# Почему отказ, а не проброс. Считать расход нечем: счётчик токенов живёт в адаптерах графа
# (harness/lib/graph-runtime.ps1 разбирает usage из потока бэкенда), а цикл зовёт CLI агента
# напрямую — в harness/loop.ps1 нет ни одного упоминания токенов. Принять флаг и не считать
# было бы предохранителем на картинке: это хуже молчаливого игнорирования, потому что
# выглядит работающим.
if ($mode -in @('loop', 'night')) {
    if ($budget -gt 0) {
        Write-BcfFail "--budget в режиме $mode не действует"
        Write-BcfNote 'потолок токенов считает только граф: расход виден в потоке бэкенда, а цикл зовёт CLI агента напрямую и токены не считает.'
        Write-BcfNote "потолок для цикла считается в итерациях: bcf run $mode --max-iterations N"
        Write-BcfNote 'потолок в токенах есть у графа: bcf run queue --budget N'
        Write-Host ''
        exit 2
    }
    # --resume циклу подделывать нечем: у него нет runId, по которому доигрывают. Но повтор
    # запуска и есть возобновление — задачи с verdict: PASS пропускаются на входе. Сказать
    # это прямо дешевле, чем проглотить флаг и оставить человека в уверенности, что он
    # доигрывает оборванный прогон, пока очередь идёт с начала.
    if ($resume) {
        Write-BcfFail "--resume в режиме $mode не действует"
        Write-BcfNote "возобновление здесь и не нужно: запусти bcf run $mode снова — задачи с verdict: PASS пропускаются, очередь продолжится с незакрытых."
        Write-BcfNote 'доигрывание по runId есть у графа: bcf run queue --resume <runId>'
        Write-Host ''
        exit 2
    }
}

# СОСТОЯНИЕ РЕПОЗИТОРИЯ — до первого агента, а не после ночи впустую.
#
# Оборванный прогон оставляет основное дерево в MERGING. Стартовать поверх такого дерева
# можно, и в этом вся беда: прогон поедет, а слияние отвалится у КАЖДОЙ задачи подряд с
# причиной «основное дерево грязное». Ночь уходит на очередь, в которой ни одна задача не
# могла закрыться по причине, к ней не относящейся.
#
# --dry-plan не запускает ни одного агента и ничего не сливает — ему это не мешает.
if (-not $dryPlan) {
    . (Join-Path $BcfRoot 'src\lib\git-readiness.ps1')
    $gitState = Get-BcfGitReadiness -Root $project
    if ($gitState.Blocking.Count) {
        Write-Host ''
        Write-BcfFail 'репозиторий проекта не в том состоянии, чтобы принимать работу'
        Write-BcfGitReadiness -State $gitState -Quiet
        Write-BcfNote 'почини перечисленное и запусти снова — закрытые PASS пропустятся.'
        Write-Host ''
        exit 2
    }
    if ($gitState.Warnings.Count) { Write-BcfGitReadiness -State $gitState -Quiet }
}

$env:BCF_PROJECT_ROOT = $project
$env:BCF_HOME = Get-BcfHome

# Код возврата уходит в переменную, а НЕ возвращается функцией.
#
# `exit (Invoke-Harness …)` выглядит естественно и молча ломает главное: PowerShell
# считает весь вывод функции её результатом, поэтому всё, что печатал прогон — лента
# графа, ход итераций, причины провалов — уходило в возвращаемое значение и не
# показывалось вовсе. Снаружи это выглядело как «команда отработала мгновенно и молча».
$script:HarnessExit = 0

function Invoke-Harness {
    param([Parameter(Mandatory)][string]$Script, [string[]]$HarnessArgs, [switch]$Live, [int]$Concurrency = 0)
    $full = Join-Path $harness $Script
    if (-not (Test-Path $full)) { Write-BcfFail "нет скрипта харнесса: $full"; exit 3 }
    $all = @($HarnessArgs) + @('-ProjectRoot', $project)

    # ЖИВОЙ ЭКРАН — только в консоли и только для графа.
    #
    # Без консоли (пайп, CI, планировщик) перерисовка на месте превращается в кашу из
    # управляющих последовательностей, а лог прогона нужен именно в сыром виде. Поэтому
    # там honest pass-through: тот же вывод, что и раньше.
    if ($Live -and (Test-BcfInteractive)) {
        . (Join-Path $BcfRoot 'src\lib\runview.ps1')
        $script:HarnessExit = Invoke-BcfRunLive -ScriptPath $full -HarnessArgs $all -Project $project -Concurrency $Concurrency
        return
    }

    & pwsh @('-NoProfile', '-File', $full) @all
    $script:HarnessExit = $LASTEXITCODE
}

switch ($mode) {

    'loop' {
        if (-not $task) { Write-BcfFail 'нужен id задачи: bcf run loop TASK-01'; exit 2 }
        $a = @($task)
        if ($maxIter) { $a += @('-MaxIterations', $maxIter) }
        $a += $passthru
        Invoke-Harness -Script 'loop.ps1' -HarnessArgs $a
        exit $script:HarnessExit
    }

    'night' {
        $a = @()
        if ($maxIter) { $a += @('-PerTaskMax', $maxIter) }
        if ($conc)    { $a += @('-TaskConcurrency', $conc) }
        if ($dryPlan) { $a += '-DryPlan' }
        $a += $passthru
        if (-not $dryPlan) {
            Write-BcfTitle 'НОЧНОЙ ПРОГОН' 'идём по всей очереди, пока не закроется или не упрёмся'
            Write-BcfNote 'остановить между задачами — создать файл .bcf/STOP'
            Write-BcfNote 'итог — .bcf/REVIEW.md, машиночитаемо — .bcf/run-all.status.json'
        }
        Invoke-Harness -Script 'run-all.ps1' -HarnessArgs $a
        exit $script:HarnessExit
    }

    { $_ -in @('queue', 'review') } {
        $a = @($mode)
        if ($dryPlan)          { $a += '-DryPlan' }

        # Живой экран рисуем сами, а значит подтверждение обязано спроситься ЗДЕСЬ:
        # вопрос движка ушёл бы в перенаправленный поток, и прогон встал бы молча,
        # ожидая ответа, которого никто не увидит.
        $live = (-not $dryPlan) -and (Test-BcfInteractive)
        if ($live -and -not (Get-BcfAssumeYes)) {
            Write-Host ''
            if (-not (Read-BcfConfirm "запустить граф $mode?" $true)) {
                Write-BcfDim 'отменено — ни один агент не вызван'
                Write-Host ''
                exit 130
            }
        }
        # РЕШЕНИЕ ПРИНЯТО ЗДЕСЬ — ЗНАЧИТ ДВИЖОК НЕ СПРАШИВАЕТ.
        #
        # Досюда доходят три случая, и во всех вопрос уже решён: человек подтвердил
        # (интерактивный запуск), стоит --yes, либо спрашивать некого вовсе. Пока `-Yes`
        # добавлялся только в первых двух, третий кончался тем, от чего предостерегает
        # комментарий выше: graph.ps1 печатал «Запускать? [y/N]» и ЖДАЛ ответа со stdin,
        # которого никто не видит. Наблюдалось живьём 2026-08-07: прогон, запущенный
        # отдельным процессом, простоял 2 ч 20 мин на этом вопросе — ни строки в журнале,
        # ни одного агента, ни одной ошибки. Молчаливое ожидание неотличимо от работы.
        $a += '-Yes'
        if ($budget -gt 0)     { $a += @('-Budget', $budget) }
        if ($conc -gt 0)       { $a += @('-Concurrency', $conc) }
        if ($resume)           { $a += @('-ResumeFromRunId', $resume) }
        if ($task)             { $a += @('-ArgsJson', $task) }   # граф читает вход как JSON
        $a += $passthru
        Invoke-Harness -Script 'graph.ps1' -HarnessArgs $a -Live:$live -Concurrency $conc
        exit $script:HarnessExit
    }

    default {
        Write-BcfFail "неизвестный режим: $mode"
        Write-BcfNote 'доступно: loop <TASK> | night | queue | review'
        exit 2
    }
}
