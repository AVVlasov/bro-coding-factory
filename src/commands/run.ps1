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
#   --budget <токены>   потолок на прогон (граф)
#   --concurrency <N>   сколько узлов/задач одновременно
#   --resume <runId>    доиграть оборванный прогон графа
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

for ($i = 0; $i -lt $script:BcfArgs.Count; $i++) {
    $a = [string]$script:BcfArgs[$i]
    # break обязателен в каждой ветке: PowerShell-switch без него проверяет ОСТАЛЬНЫЕ
    # условия тоже, и `--dry-plan` уходил ещё и в общую ветку '^-', то есть попадал в
    # аргументы харнесса как неизвестный флаг.
    switch -Regex ($a) {
        '^--dry-plan$'       { $dryPlan = $true; break }
        '^--budget$'         { $i++; $budget = [double]$script:BcfArgs[$i]; break }
        '^--concurrency$'    { $i++; $conc = [int]$script:BcfArgs[$i]; break }
        '^--resume$'         { $i++; $resume = [string]$script:BcfArgs[$i]; break }
        '^--max-iterations$' { $i++; $maxIter = [int]$script:BcfArgs[$i]; break }
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
