# bcf task — работа с задачами: создать, объяснить, почему не идёт, принять.
#
#   bcf task new "<что сделать>"   создать файл задачи по шаблону
#   bcf task new "<...>" --for Иван   то же, но задачу ведёт человек: фабрика её не берёт
#   bcf task why <ID>              почему эта задача не может пойти в работу
#   bcf task show <ID>             файл задачи, вердикт, разведка — одним экраном
#   bcf task accept <ID> --as <имя> [--lens <ракурс>] [--note "..."]   приёмка лидером
#
# ЗАЧЕМ. Создание задачи — САМОЕ ЧАСТОЕ ежедневное действие: очередь не берётся из
# воздуха. Делать это руками значит каждый раз вспоминать формат имени, обязательные
# секции и то, что «Вход» читается двумя разными способами. Ошибка в любом из трёх мест
# обнаруживается не сразу, а на прогоне — задачей, которую планировщик не увидел или
# пустил в волну, где ей не место.
#
# `why` отвечает на второй по частоте вопрос. «Ждёт TASK-02» в списке — это ЧТО, а не
# ПОЧЕМУ: дальше человек идёт смотреть вердикты, файлы и коллизии руками.
#
# `accept` — четвёртое действие с задачей, отдельное от трёх остальных: verdict: PASS
# доказывает, что гейты зелёные, а не то, что задача решает нужную проблему верным
# способом. Классы CORE и NFR (`Класс:` в шапке задачи, без строки — CORE) без файла
# приёмки не продвигаются в integration.branch — см. Test-BcfTaskAcceptanceGate в
# harness/lib/claims.ps1 и её вызов из Merge-TaskWorktree.

. (Join-Path (Get-BcfHarness) 'lib\claims.ps1')
. (Join-Path (Get-BcfHarness) 'lib\team-bus.ps1')

$project = $script:BcfProject

# --for <имя> вынимается ДО отбрасывания флагов. Общий фильтр `-notlike '-*'` убирает сам
# флаг, но не его значение: «bcf task new чинить связь --for Иван» без этого разбора
# создал бы задачу с названием «чинить связь Иван» и без исполнителя. Флаг, который
# молча уезжает в чужой список, — тот же класс дефектов, что уже ловил тест про --project.
$argv = @($script:BcfArgs)
$forWhom = ''
$asLeader = ''
$lens = ''
$note = ''
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
    if ($a -match '^--as=(.+)$') { $asLeader = $Matches[1]; continue }
    if ($a -eq '--as') {
        $i++
        $v = if ($i -lt $argv.Count) { [string]$argv[$i] } else { '' }
        if (-not $v -or $v.StartsWith('-')) {
            Write-BcfFail 'у флага --as нет значения: bcf task accept TASK-03 --as Иван'
            exit 2
        }
        $asLeader = $v
        continue
    }
    if ($a -match '^--lens=(.+)$') { $lens = $Matches[1]; continue }
    if ($a -eq '--lens') {
        $i++
        $v = if ($i -lt $argv.Count) { [string]$argv[$i] } else { '' }
        if (-not $v -or $v.StartsWith('-')) { Write-BcfFail 'у флага --lens нет значения'; exit 2 }
        $lens = $v
        continue
    }
    if ($a -match '^--note=(.+)$') { $note = $Matches[1]; continue }
    if ($a -eq '--note') {
        $i++
        $v = if ($i -lt $argv.Count) { [string]$argv[$i] } else { '' }
        if (-not $v -or $v.StartsWith('-')) { Write-BcfFail 'у флага --note нет значения'; exit 2 }
        $note = $v
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

    # И НОМЕРА, ЗАНЯТЫЕ НА ДРУГОЙ МАШИНЕ.
    #
    # Локальных файлов недостаточно: у второго участника команды их шесть, у первого
    # девять, и седьмая давно в работе. Номер, выбранный по своему каталогу, совпадает с
    # чужим, а обнаруживается это на слиянии — двумя разными задачами под одним именем,
    # каждая со своим вердиктом. Смотрим дерево ветки интеграции на remote (без сетевого
    # вызова: свежесть refs/remotes даёт прогон, который начинается с fetch).
    $remoteMax = 0
    try { $remoteMax = Get-BcfRemoteTaskMax -Root $project -Prefix $prefix -TasksRel $tasksRel } catch { }
    if ($remoteMax -gt $max) {
        Write-BcfNote "номера до $prefix-$('{0:D2}' -f $remoteMax) заняты на ветке интеграции — беру следующий за ними"
        $max = $remoteMax
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

    $rel = ($path.Substring($project.Length).TrimStart('\', '/')) -replace '\\', '/'
    Add-BcfTaskIndexEntry -Root $project -TaskId $id -Title $title -RelPath $rel | Out-Null

    Write-BcfTitle "СОЗДАНА ЗАДАЧА  $id" $title
    Write-BcfOk $rel
    Write-BcfOk "$tasksRel/index.md (строка реестра)"
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

'accept' {
    $id = ($rest | Select-Object -First 1)
    if (-not $id) { Write-BcfFail 'нужен id: bcf task accept TASK-03 --as Иван'; exit 2 }
    $id = $id.ToUpper()
    if (-not $asLeader) { Write-BcfFail 'нужно имя лидера: bcf task accept TASK-03 --as Иван'; exit 2 }

    $t = @(Get-AllTasks | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $t) { Write-BcfFail "задача $id не найдена в $tasksRel/"; exit 2 }
    if (-not (Test-Path -LiteralPath $t.Verdict)) {
        Write-BcfFail "у $id ещё нет вердикта ($verdictsRel/$id.md) — приёмка не на чем основана"
        Write-BcfNote "сначала прогон: bcf run loop $id или bcf run queue"
        exit 2
    }

    # sha самого файла вердикта, а не diff-отпечатка внутри него: приёмка привязывается к
    # ТЕКСТУ, который лидер прочитал, — если вердикт перепишется (новый прогон, другой
    # verdict/remediation), sha разойдётся, и `bcf task show` покажет приёмку устаревшей
    # (сравнение — там же, ниже по файлу, ветка 'show'). Гейт слияния сам это не проверяет:
    # он только требует наличия файла приёмки, см. Test-BcfTaskAcceptanceGate.
    $sha = (& git -C $project hash-object -- $t.Verdict 2>$null | Out-String).Trim()
    if (-not $sha) { $sha = 'нет-git' }

    $when = (Get-Date -Format 'o')
    $body = ConvertTo-BcfAcceptanceText -TaskId $id -Leader $asLeader -Lens $lens -Note $note -VerdictSha $sha -When $when
    $accDir = Get-BcfAcceptanceDir -Root $project
    New-Item -ItemType Directory -Force -Path $accDir | Out-Null
    $accPath = Join-Path $accDir "$id.md"
    Set-Content -LiteralPath $accPath -Value $body -Encoding UTF8

    $rel = ($accPath.Substring($project.Length).TrimStart('\', '/')) -replace '\\', '/'
    $pub = Publish-BcfClaimChange -Root $project -Paths @($rel) -Message "${id}: приёмка — $asLeader"

    Write-BcfTitle "ПРИЁМКА $id" $asLeader
    Write-BcfOk $rel
    Write-BcfNote "вердикт: $sha"
    if ($lens) { Write-BcfNote "ракурс: $lens" }
    if ($note) { Write-BcfNote "заметка: $note" }
    if (-not $pub.Ok) {
        Write-Host ''
        Write-BcfWarn "файл записан, но не закоммичен: $($pub.Reason)"
        Write-BcfNote 'закоммить руками — иначе приёмку не увидит второй участник команды.'
    }
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

    $class = Get-BcfTaskClass -TaskId $id -Root $project
    if (Test-BcfTaskNeedsAcceptance -Class $class) {
        Write-Host ''
        Write-BcfLine "  ПРИЁМКА (класс $class)" 'White'
        $accPath = Get-BcfAcceptancePath -TaskId $id -Root $project
        if (Test-Path -LiteralPath $accPath) {
            $acc = ConvertFrom-BcfAcceptanceText -Body (Get-Content -Raw -LiteralPath $accPath)
            # Приёмка привязана к ТЕКСТУ вердикта, который читал лидер (sha файла на
            # момент accept). Новый прогон переписывает вердикт — sha расходится, и это
            # обязано быть видно здесь, а не оставаться необещанным нигде: до этой правки
            # ничто не сравнивало записанный sha с текущим, и устаревшая приёмка молча
            # продолжала пускать слияние.
            $curSha = if (Test-Path $t.Verdict) { (& git -C $project hash-object -- $t.Verdict 2>$null | Out-String).Trim() } else { '' }
            if ($acc.VerdictSha -and $curSha -and $acc.VerdictSha -ne $curSha) {
                Write-BcfWarn "приёмка устарела — вердикт пересчитан после $($acc.When)"
                Write-BcfDim "было: $($acc.VerdictSha)  стало: $curSha"
                Write-BcfNote "нужна новая приёмка: bcf task accept $id --as <имя>"
            } else {
                Write-BcfOk "принято: $($acc.Leader), $($acc.When)"
                if ($acc.Lens) { Write-BcfDim "ракурс: $($acc.Lens)" }
            }
        } elseif ($t.Pass) {
            Write-BcfWarn "ждёт приёмки лидера — bcf task accept $id --as <имя>"
        } else {
            Write-BcfDim 'приёмка потребуется после verdict: PASS'
        }
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
    Write-BcfNote 'доступно: new "<название>" [--for <имя>] | why <ID> | show <ID> | accept <ID> --as <имя>'
    exit 2
}
}
