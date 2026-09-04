# bcf task — работа с задачами: создать, объяснить, почему не идёт.
#
#   bcf task new "<что сделать>"   создать файл задачи по шаблону
#   bcf task new "<...>" --for Иван   то же, но задачу ведёт человек: фабрика её не берёт
#   bcf task why <ID>              почему эта задача не может пойти в работу
#   bcf task show <ID>             файл задачи, вердикт, разведка — одним экраном
#
# ЗАЧЕМ. Создание задачи — САМОЕ ЧАСТОЕ ежедневное действие: очередь не берётся из
# воздуха. Делать это руками значит каждый раз вспоминать формат имени, обязательные
# секции и то, что «Вход» читается двумя разными способами. Ошибка в любом из трёх мест
# обнаруживается не сразу, а на прогоне — задачей, которую планировщик не увидел или
# пустил в волну, где ей не место.
#
# `why` отвечает на второй по частоте вопрос. «Ждёт TASK-02» в списке — это ЧТО, а не
# ПОЧЕМУ: дальше человек идёт смотреть вердикты, файлы и коллизии руками.

. (Join-Path (Get-BcfHarness) 'lib\claims.ps1')

$project = $script:BcfProject

# --for <имя> вынимается ДО отбрасывания флагов. Общий фильтр `-notlike '-*'` убирает сам
# флаг, но не его значение: «bcf task new чинить связь --for Иван» без этого разбора
# создал бы задачу с названием «чинить связь Иван» и без исполнителя. Флаг, который
# молча уезжает в чужой список, — тот же класс дефектов, что уже ловил тест про --project.
$argv = @($script:BcfArgs)
$forWhom = ''
$clean = @()
for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = [string]$argv[$i]
    if ($a -match '^--for=(.+)$') { $forWhom = $Matches[1]; continue }
    if ($a -eq '--for') {
        $i++
        $v = if ($i -lt $argv.Count) { [string]$argv[$i] } else { '' }
        if (-not $v -or $v.StartsWith('-')) {
            Write-BcfFail 'у флага --for нет значения: bcf task new "название" --for Иван'
            exit 2
        }
        $forWhom = $v
        continue
    }
    $clean += $a
}

$sub = @($clean | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1
$rest = @($clean | Where-Object { $_ -notlike '-*' }) | Select-Object -Skip 1

$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { }
$prefix = if ($cfg -and $cfg.taskIdPrefix) { [string]$cfg.taskIdPrefix } else { 'TASK' }
$tasksRel = if ($cfg -and $cfg.paths -and $cfg.paths.tasks) { [string]$cfg.paths.tasks } else { 'tasks' }
$verdictsRel = if ($cfg -and $cfg.paths -and $cfg.paths.verdicts) { [string]$cfg.paths.verdicts } else { "$tasksRel/.verdicts" }
$tasksDir = Join-Path $project ($tasksRel -replace '/', '\')
$verdictsDir = Join-Path $project ($verdictsRel -replace '/', '\')

function Get-AllTasks {
    $out = @()
    if (-not (Test-Path $tasksDir)) { return $out }
    foreach ($f in (Get-ChildItem $tasksDir -Filter "$prefix-*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($f.BaseName -match "^$([regex]::Escape($prefix))-\d+\.\d+") { continue }
        $id = ($f.BaseName -split '-')[0..1] -join '-'
        $vf = Join-Path $verdictsDir "$id.md"
        $out += [pscustomobject]@{
            Id = $id; File = $f
            Files = @(Get-TaskDeclaredFiles -TaskId $id -Root $project)
            Preds = @(Get-TaskPredecessors -TaskId $id -Root $project -Prefix $prefix)
            Pass = (Test-Path $vf) -and (Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
            Verdict = $vf
        }
    }
    return $out
}

switch ($sub) {

'new' {
    $title = ($rest -join ' ').Trim()
    if (-not $title) {
        Write-BcfFail 'нужно название: bcf task new "фильтры последующих сканов"'
        exit 2
    }
    New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null

    # Номер берём следующий за максимальным, а не «количество + 1»: после удаления задачи
    # второе даёт занятый номер, и два файла начинают спорить за один id.
    $max = 0
    foreach ($t in (Get-AllTasks)) {
        if ($t.Id -match '-(\d+)$') { $max = [math]::Max($max, [int]$Matches[1]) }
    }
    $num = '{0:D2}' -f ($max + 1)
    $slug = ($title.ToLower() -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')
    # Транслитерация нужна для имени файла: кириллица в пути ломает часть инструментов,
    # которые харнесс зовёт снаружи, а имя файла задачи попадает в команды буквально.
    $map = @{ 'а'='a';'б'='b';'в'='v';'г'='g';'д'='d';'е'='e';'ё'='e';'ж'='zh';'з'='z';'и'='i';'й'='y';'к'='k';'л'='l';'м'='m';'н'='n';'о'='o';'п'='p';'р'='r';'с'='s';'т'='t';'у'='u';'ф'='f';'х'='h';'ц'='c';'ч'='ch';'ш'='sh';'щ'='sch';'ъ'='';'ы'='y';'ь'='';'э'='e';'ю'='yu';'я'='ya' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $slug.ToCharArray()) {
        $k = [string]$ch
        if ($map.ContainsKey($k)) { [void]$sb.Append($map[$k]) } else { [void]$sb.Append($k) }
    }
    $slug = ($sb.ToString() -replace '-+', '-').Trim('-')
    if (-not $slug) { $slug = 'task' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }

    $id = "$prefix-$num"
    $path = Join-Path $tasksDir "$id-$slug.md"
    if (Test-Path $path) { Write-BcfFail "файл уже есть: $path"; exit 1 }

    $tpl = Get-Content -Raw -LiteralPath (Join-Path (Get-BcfTemplates) 'project\task.md')
    $tpl = $tpl -replace '\{\{TASK_ID\}\}', $id -replace '\{\{TASK_TITLE\}\}', $title
    # Строку предшественников кладём в ТОМ формате, который читает харнесс, — чтобы
    # человеку не пришлось выяснять, какой из двух форматов «правильный».
    $tpl = $tpl -replace '(?m)^—$', '**Gate-вход:** нет'
    # Исполнитель проставляется в готовую строку шаблона, а не дописывается сбоку:
    # два места, где может стоять одно поле, однажды разойдутся, и разойдутся молча.
    if ($forWhom) { $tpl = $tpl -replace '(?m)^Исполнитель:.*$', "Исполнитель: $forWhom" }
    Set-Content -LiteralPath $path -Value $tpl -Encoding UTF8

    Write-BcfTitle "СОЗДАНА ЗАДАЧА  $id" $title
    Write-BcfOk ($path.Substring($project.Length).TrimStart('\', '/'))
    if ($forWhom) {
        Write-Host ''
        Write-BcfWarn "исполнитель: $forWhom — фабрика эту задачу не возьмёт"
        Write-BcfNote 'её не будет ни в bcf run night, ни в bcf run queue; в bcf tasks она видна.'
        Write-BcfNote 'вернуть фабрике — стереть строку «Исполнитель:» или написать в ней «фабрика».'
    }
    Write-Host ''
    Write-BcfLine '  ЧТО ЗАПОЛНИТЬ, ИНАЧЕ ЗАДАЧА НЕ ПОЕДЕТ' 'White'
    Write-BcfNote '· «## Файлы» — без списка задача к работе НЕ допускается: владение неизвестно,'
    Write-BcfNote '  и расползание скоупа обнаружится только на слиянии;'
    Write-BcfNote '· «## Готовность» — до трёх условий, каждое проверяется КОМАНДОЙ;'
    Write-BcfNote '· «## Проверки» — те же команды продублировать в config/checks.json под ключом'
    Write-BcfNote "  «$id»: там их задаёт владелец, и агент не может сузить их до тривиально зелёных."
    Write-Host ''
    Write-BcfNote "открыть: $path"
    Write-BcfNote "проверить: bcf task why $id"
    Write-Host ''
    exit 0
}

'why' {
    $id = ($rest | Select-Object -First 1)
    if (-not $id) { Write-BcfFail 'нужен id: bcf task why TASK-03'; exit 2 }
    $id = $id.ToUpper()
    $all = Get-AllTasks
    $t = @($all | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $t) { Write-BcfFail "задача $id не найдена в $tasksRel/"; exit 2 }

    Write-BcfTitle "ПОЧЕМУ $id" $t.File.Name

    $blockers = @()

    # Исполнитель проверяется ПЕРВЫМ и заканчивает разговор: у задачи человека все
    # остальные ответы («ждёт предшественников», «нет секции Файлы») — не причина,
    # по которой она стоит, а описание того, чего фабрика всё равно не будет делать.
    $who = Get-TaskExecutor -TaskId $id -Root $project
    if ($who -and -not (Test-BcfExecutorIsFactory $who) -and -not $t.Pass) {
        Write-BcfWarn "задачу ведёт человек: $who"
        Write-BcfNote 'фабрика её не берёт: из очереди run-all и графа она исключена по строке'
        Write-BcfNote '«Исполнитель:» в файле задачи. Вернуть фабрике — стереть строку или'
        Write-BcfNote 'написать в ней «фабрика».'
        Write-Host ''
        exit 0
    }

    if ($t.Pass) {
        Write-BcfOk 'задача закрыта: verdict PASS — запускать нечего'
        Write-BcfNote $t.Verdict.Substring($project.Length).TrimStart('\', '/')
        Write-Host ''
        exit 0
    }

    # 1. Предшественники
    $passSet = @{}; foreach ($x in $all) { if ($x.Pass) { $passSet[$x.Id] = $true } }
    $open = @($t.Preds | Where-Object { -not $passSet.ContainsKey($_) })
    if ($t.Preds.Count) {
        if ($open.Count) {
            Write-BcfFail "ждёт предшественников: $($open -join ', ')"
            foreach ($p in $open) {
                $pt = @($all | Where-Object { $_.Id -eq $p }) | Select-Object -First 1
                if (-not $pt) { Write-BcfNote "$p — файла задачи нет вовсе, гейт не закроется никогда" }
                else { Write-BcfNote "$p — есть, вердикта PASS нет" }
            }
            $blockers += 'предшественники'
        } else {
            Write-BcfOk "предшественники закрыты: $($t.Preds -join ', ')"
        }
    } else {
        Write-BcfOk 'предшественников нет'
    }

    # 2. Владение файлами
    if (-not $t.Files.Count) {
        Write-BcfFail 'нет секции «## Файлы» — к работе не допускается'
        Write-BcfNote 'без декларации владения проверить, что задача не залезет в чужой файл, нечем,'
        Write-BcfNote 'и расползание скоупа обнаружится только на слиянии, когда работа уже сделана.'
        $blockers += 'файлы'
    } else {
        Write-BcfOk "владеет файлами: $($t.Files -join ', ')"
        # Коллизия — то, из-за чего задача поедет, но дорого и рискованно.
        foreach ($o in $all) {
            if ($o.Id -eq $t.Id -or $o.Pass) { continue }
            $common = @($o.Files | Where-Object { $t.Files -contains $_ })
            if (-not $common.Count) { continue }
            if (($t.Preds -contains $o.Id) -or ($o.Preds -contains $t.Id)) { continue }
            Write-BcfWarn "коллизия владения с $($o.Id): $($common -join ', ')"
            Write-BcfNote 'предшествования между вами нет — планировщик пустит обе в одну волну,'
            Write-BcfNote 'и арбитр будет сводить два независимых переписывания одного файла.'
        }
    }

    # 3. Проверки: чем задача вообще будет доказана
    $checksFile = Join-Path $project 'config\checks.json'
    $own = @()
    if (Test-Path $checksFile) {
        try {
            $cj = Get-Content -Raw -LiteralPath $checksFile | ConvertFrom-Json
            if ($cj.PSObject.Properties[$id]) { $own = @($cj.$id) }
            elseif ($cj._default) { $own = @($cj._default) }
        } catch { }
    }
    if ($own.Count) { Write-BcfOk "обязательных проверок: $($own.Count)" }
    else {
        Write-BcfWarn 'обязательных проверок нет — ни своих, ни _default'
        Write-BcfNote 'вердикт будет опираться только на то, что предложит сам агент,'
        Write-BcfNote 'то есть PASS можно получить, ничего по сути не доказав.'
    }

    # 4. Готов ли вообще прогон
    $missingRoles = @()
    if ($cfg -and $cfg.graph -and $cfg.graph.roles) {
        foreach ($r in @('planner', 'worker', 'arbiter', 'critic')) {
            $p = $cfg.graph.roles.PSObject.Properties[$r]
            if (-not $p -or -not $p.Value.backend -or -not $p.Value.model) { $missingRoles += $r }
        }
    } else { $missingRoles = @('planner', 'worker', 'arbiter', 'critic') }
    if ($missingRoles.Count) {
        Write-BcfFail "роли графа не заполнены: $($missingRoles -join ', ')"
        $blockers += 'роли'
    }

    Write-Host ''
    if ($blockers.Count) {
        Write-BcfLine "  НЕ ПОЕДЕТ: $($blockers -join ', ')" 'Red'
        Write-Host ''
        exit 1
    }
    Write-BcfLine '  ГОТОВА К РАБОТЕ' 'Green'
    Write-BcfNote "запустить одну: bcf run loop $id   ·   всю волну: bcf run queue"
    Write-Host ''
    exit 0
}

'show' {
    $id = ($rest | Select-Object -First 1)
    if (-not $id) { Write-BcfFail 'нужен id: bcf task show TASK-03'; exit 2 }
    $id = $id.ToUpper()
    $t = @(Get-AllTasks | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $t) { Write-BcfFail "задача $id не найдена"; exit 2 }

    Write-BcfTitle "ЗАДАЧА $id" $t.File.Name
    Get-Content -LiteralPath $t.File.FullName | ForEach-Object { Write-Host "  $_" }

    if (Test-Path $t.Verdict) {
        Write-Host ''
        Write-BcfLine '  ВЕРДИКТ' 'White'
        Get-Content -LiteralPath $t.Verdict -TotalCount 20 | ForEach-Object { Write-BcfDim $_ }
    }
    $research = Join-Path $tasksDir "$id.research.md"
    if (Test-Path $research) {
        Write-Host ''
        Write-BcfNote "разведка: $($research.Substring($project.Length).TrimStart('\','/'))"
    }
    Write-Host ''
    exit 0
}

default {
    Write-BcfFail $(if ($sub) { "неизвестная подкоманда: $sub" } else { 'нужна подкоманда' })
    Write-BcfNote 'доступно: new "<название>" [--for <имя>] | why <ID> | show <ID>'
    exit 2
}
}
