# banner.ps1 — карточка состояния, с которой начинается работа.
#
# ЧТО ЗДЕСЬ ПОКАЗЫВАЕТСЯ И ПОЧЕМУ ИМЕННО ЭТО. Пять строк — это пять вещей, отсутствие
# которых обнаруживается на прогоне, а не до него:
#
#   проект     сколько задач в бэклоге и сколько закрыто — иначе «запусти очередь»
#              звучит одинаково и для четырнадцати задач, и для пустой папки;
#   бэкенды    какие роли на чём сидят. Неавторизованный бэкенд отвечает штатным
#              событием, а не падением, и молчит до первого узла;
#   память     ЧИСЛА, а не «ок»: память бывает доступна и содержать один урок,
#              перечитываемый полсотни раз;
#   тарифы     дата, а не сумма. Прайсы меняются, файл — нет;
#   подписки   что уже оплачено помесячно: без этого экономия «по API дешевле»
#              считается от нуля.
#
# Строка, для которой данных нет, НЕ выдумывается и не прячется — она печатается со
# словом «нет» и объяснением, чего это стоит.

function Get-BcfBannerStatus {
    param([Parameter(Mandatory)][string]$Project)

    $cfg = $null
    try { $cfg = Get-BcfHarnessConfig -Project $Project } catch { }

    # --- бэклог: считаем тем же, чем bcf tasks, чтобы числа не разъезжались ---
    $prefix = if ($cfg -and $cfg.taskIdPrefix) { [string]$cfg.taskIdPrefix } else { 'TASK' }
    $tasksRel = if ($cfg -and $cfg.paths -and $cfg.paths.tasks) { [string]$cfg.paths.tasks } else { 'tasks' }
    $verdictsRel = if ($cfg -and $cfg.paths -and $cfg.paths.verdicts) { [string]$cfg.paths.verdicts } else { "$tasksRel/.verdicts" }
    $tasksDir = Join-Path $Project ($tasksRel -replace '/', '\')
    $verdictsDir = Join-Path $Project ($verdictsRel -replace '/', '\')

    $tasks = @()
    if (Test-Path $tasksDir) {
        foreach ($f in (Get-ChildItem $tasksDir -Filter "$prefix-*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($f.BaseName -match "^$([regex]::Escape($prefix))-\d+\.\d+") { continue }
            $id = ($f.BaseName -split '-')[0..1] -join '-'
            $vf = Join-Path $verdictsDir "$id.md"
            $pass = (Test-Path $vf) -and (Select-String -Path $vf -Pattern '^verdict:\s*PASS' -Quiet)
            $tasks += [pscustomobject]@{
                Id = $id
                Slug = ($f.BaseName -replace "^$([regex]::Escape($prefix))-\d+-", '')
                Files = @(Get-TaskDeclaredFiles -TaskId $id -Root $Project)
                Preds = @(Get-TaskPredecessors -TaskId $id -Root $Project -Prefix $prefix)
                Pass = $pass
            }
        }
    }
    $passSet = @{}; foreach ($t in $tasks) { if ($t.Pass) { $passSet[$t.Id] = $true } }
    foreach ($t in $tasks) {
        $t | Add-Member -NotePropertyName 'Ready' `
            -NotePropertyValue (-not $t.Pass -and (@($t.Preds | Where-Object { -not $passSet.ContainsKey($_) }).Count -eq 0)) -Force
    }

    # --- роли и бэкенды ---
    $roles = @()
    if ($cfg -and $cfg.graph -and $cfg.graph.roles) {
        foreach ($p in $cfg.graph.roles.PSObject.Properties) {
            if ($p.Name -eq '$comment' -or -not $p.Value.backend) { continue }
            $roles += [pscustomobject]@{ Role = $p.Name; Backend = [string]$p.Value.backend; Model = [string]$p.Value.model }
        }
    }

    # --- память: числа, а не «активна» ---
    $mem = $null
    $memClient = Join-Path (Get-BcfMemoryDir) 'pgvector\memory_client.py'
    if ((Test-Path $memClient) -and $cfg -and $cfg.features -and $cfg.features.memory) {
        $env:BCF_PROJECT_ROOT = $Project
        $env:PYTHONIOENCODING = 'utf-8'
        try {
            $raw = (& python $memClient stats 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $raw -match '\{') { $mem = $raw | ConvertFrom-Json }
        } catch { }
    }

    # --- тарифы и подписки ---
    $pricing = Get-BcfPricing -Project $Project

    # --- последний прогон ---
    # Единственная строка карточки, которая отвечает на вопрос «а сейчас-то что». Без неё
    # человек открывает карточку, видит настроенный проект и не знает главного: идёт ли
    # прогон прямо сейчас, оборвался ли он ночью и стоит ли вообще запускать второй.
    $lastRun = $null
    try { $lastRun = Get-BcfLastRun -Project $Project } catch { }

    return [pscustomobject]@{
        Project = $Project
        Name = (Split-Path $Project -Leaf)
        Config = $cfg
        Prefix = $prefix
        Tasks = $tasks
        Closed = @($tasks | Where-Object { $_.Pass }).Count
        Ready = @($tasks | Where-Object { $_.Ready }).Count
        Roles = $roles
        Memory = $mem
        MemoryOn = [bool]($cfg -and $cfg.features -and $cfg.features.memory)
        Pricing = $pricing
        LastRun = $lastRun
    }
}

# Знак — как в дизайне: BCF блочными глифами. Ширина букв там разная (B и C по четыре
# столбца, F по пять), и выравнивать их «на глаз» нельзя — знак перестаёт читаться.
$script:BcfLogo = @(
    '████   ████  █████'
    '█  █  █      █    '
    '████  █      ████ '
    '█  █  █      █    '
    '████   ████  █    '
)

function Get-BcfMascotMood {
    param([Parameter(Mandatory)]$Status)
    # Настроение — не украшение: оно повторяет вердикт карточки. Ролей нет — прогон не
    # поедет вовсе (bad); нет памяти или тарифов — поедет с оговорками (warn).
    if (-not $Status.Roles.Count) { return 'bad' }
    if (-not $Status.Tasks.Count) { return 'warn' }
    if ($Status.MemoryOn -and $null -eq $Status.Memory) { return 'warn' }
    if (-not $Status.MemoryOn) { return 'warn' }
    return 'ok'
}

function Write-BcfBanner {
    param([Parameter(Mandatory)]$Status)

    # Маскот — ТОТ ЖЕ, что в мастере (src/lib/mascot.ps1). Своя ASCII-копия здесь жила
    # ровно до первого взгляда на реальный терминал: в баннере рисовалась рожица из
    # чёрточек, а в init — пиксельная. Один персонаж не может выглядеть двумя способами.
    $mood = Get-BcfMascotMood -Status $Status
    $face = @(Get-BcfMascotLines -Mood $mood)

    Write-Host ''
    $rows = [math]::Max($face.Count, $script:BcfLogo.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        $l = if ($i -lt $face.Count) { $face[$i] } else { ' ' * 14 }
        $g = if ($i -lt $script:BcfLogo.Count) { Ink $script:BcfLogo[$i] 'Cyan' } else { '' }
        Write-Host ('  ' + $l + '   ' + $g)
    }
    Write-Host ''
    Write-Host ('  ' + (Ink 'BRO CODING FACTORY' 'White') + ' ' + (Ink "v$(Get-BcfVersion)" 'DarkGray'))
    Write-BcfLine '  кодовая фабрика: граф агентов вместо цикла' 'DarkGray'
    Write-Host ''

    # проект
    $backlog = if (-not $Status.Tasks.Count) { 'бэклог пуст' }
               else { "$($Status.Tasks.Count) задач в бэклоге · закрыто $($Status.Closed) · готово $($Status.Ready)" }
    Write-BcfLine ("  {0,-10} {1} · {2}" -f 'проект', $Status.Name, $backlog) 'White'

    # прогон
    if ($Status.LastRun) {
        $r = $Status.LastRun
        $age = (Get-Date) - $r.Finished
        # «Идёт» определяем по свежести журнала, а не по файлу-маркеру: маркер переживает
        # падение процесса и потом сутками уверяет, что прогон работает.
        if (Test-BcfRunLive -Run $r -Project $Status.Project) {
            Write-BcfLine ("  {0,-10} идёт: {1} · узлов {2} · {3} (bcf watch · bcf stop)" -f `
                           'прогон', $r.Name, $r.NodeCount, (Format-BcfDuration ((Get-Date) - $r.Started))) 'Cyan'
        } elseif (-not $r.Complete) {
            Write-BcfLine ("  {0,-10} $(Sym warn) ОБОРВАН {1} назад — работа задач осталась в ветках (bcf runs)" -f `
                           'прогон', (Format-BcfDuration $age)) 'Yellow'
        } elseif ($r.Failed -gt 0) {
            Write-BcfLine ("  {0,-10} $(Sym fail) {1} назад, узлов не дали результата: {2} (bcf log --failed)" -f `
                           'прогон', (Format-BcfDuration $age), $r.Failed) 'Red'
        } elseif (-not $r.DryPlan -and -not (Get-BcfRunComplete -Run $r)) {
            # Ни один узел не провалился, а очередь всё равно не закрылась — самый
            # обманчивый исход: по узлам всё зелено, а сделано ничего.
            $t = Get-BcfRunTally -Run $r
            Write-BcfLine ("  {0,-10} $(Sym warn) {1} назад, НЕПОЛНО{2} (bcf report)" -f `
                           'прогон', (Format-BcfDuration $age), $(if ($t) { " — $t" } else { '' })) 'Yellow'
        } elseif ($r.DryPlan) {
            Write-BcfLine ("  {0,-10} {1} назад — сухой план, агентов не звали (bcf run queue)" -f `
                           'прогон', (Format-BcfDuration $age)) 'DarkGray'
        } else {
            Write-BcfLine ("  {0,-10} $(Sym ok) {1} назад · {2} · узлов {3} (bcf report)" -f `
                           'прогон', (Format-BcfDuration $age), $r.RunId, $r.NodeCount) 'Green'
        }
    } else {
        Write-BcfLine ("  {0,-10} ещё не было — история пуста, смета считаться не по чему" -f 'прогон') 'DarkGray'
    }

    # бэкенды
    if ($Status.Roles.Count) {
        $parts = foreach ($r in $Status.Roles) {
            $m = if ($r.Model) { " $($r.Model)" } else { '' }
            "$(Sym ok) $($r.Backend)$m"
        }
        Write-BcfLine ("  {0,-10} {1}" -f 'бэкенды', (($parts | Select-Object -Unique) -join '  ')) 'Green'
    } else {
        Write-BcfLine ("  {0,-10} ролей нет — граф не знает, чем исполнять узел (bcf init)" -f 'бэкенды') 'Red'
    }

    # память
    if (-not $Status.MemoryOn) {
        Write-BcfLine ("  {0,-10} выключена — прогоны не учатся на прошлых ошибках (bcf memory init)" -f 'память') 'DarkGray'
    } elseif ($null -eq $Status.Memory) {
        Write-BcfLine ("  {0,-10} $(Sym fail) недоступна — уроки не отзываются и не пишутся (bcf memory status)" -f 'память') 'Red'
    } else {
        $m = $Status.Memory
        $grow = if ($null -ne $m.anti_patterns_last_7d -and [int]$m.anti_patterns_last_7d -gt 0) {
            "+$($m.anti_patterns_last_7d) за неделю — обучение живое"
        } else { 'за неделю без прироста — читает старое' }
        $col = if ([int]$m.anti_patterns -le 1) { 'Yellow' } else { 'Green' }
        Write-BcfLine ("  {0,-10} $(Sym ok) уроков {1} · багов {2} · отзывов {3} · {4}" -f `
                       'память', $m.anti_patterns, $m.bugs, $m.recalls, $grow) $col
    }

    # тарифы
    if ($Status.Pricing) {
        $models = @($Status.Pricing.Models.PSObject.Properties).Count
        Write-BcfLine ("  {0,-10} $(Sym ok) от {1} · моделей {2} · валюта {3}" -f `
                       'тарифы', $Status.Pricing.Updated, $models, $Status.Pricing.Currency) 'Green'
    } else {
        Write-BcfLine ("  {0,-10} не заданы — смета не считается, только токены (config/pricing.json)" -f 'тарифы') 'DarkGray'
    }

    # подписки
    if ($Status.Pricing -and $Status.Pricing.Plans) {
        $plans = @($Status.Pricing.Plans.PSObject.Properties)
        $total = 0.0
        foreach ($pl in $plans) { $total += [double]$pl.Value.monthly }
        Write-BcfLine ("  {0,-10} {1} — {2:N0} {3}/мес" -f `
                       'подписки', (($plans | ForEach-Object { $_.Name }) -join ' · '), $total, $Status.Pricing.Currency) 'White'
    } else {
        Write-BcfLine ("  {0,-10} не описаны — экономия «подписка против API» считается от нуля" -f 'подписки') 'DarkGray'
    }

    Write-BcfRule ((Get-BcfConsoleWidth) - 4)
    Write-Host ''
}

# Смета прогона. Считается ПО ИСТОРИИ этого проекта, а не по прайсу «в среднем»: сколько
# узел стоит на самом деле, знают только прошлые журналы. Если истории нет — так и
# говорим. Выдуманная смета хуже отсутствующей: по ней принимают решение о запуске.
function Get-BcfRunEstimate {
    param([Parameter(Mandatory)][string]$Project, [int]$TaskCount = 0, $Pricing = $null)

    $runs = @(Get-BcfRuns -Project $Project | Where-Object { -not $_.DryPlan -and $_.Tokens -gt 0 })
    if (-not $runs.Count) {
        return [pscustomobject]@{ Known = $false; Runs = 0
                                  Why = 'прогонов с расходом ещё не было — оценивать не по чему' }
    }

    $nodes = 0; $tokens = 0.0
    $byRole = @{}
    foreach ($r in $runs) {
        foreach ($n in $r.Nodes) {
            if ($n.Tokens -le 0) { continue }
            $nodes++; $tokens += [double]$n.Tokens
            $role = if ($n.Role) { $n.Role } else { '(без роли)' }
            if (-not $byRole.ContainsKey($role)) { $byRole[$role] = [ordered]@{ Nodes = 0; Tokens = 0.0; Model = $n.Model } }
            $byRole[$role].Nodes++; $byRole[$role].Tokens += [double]$n.Tokens
        }
    }
    if (-not $nodes) {
        return [pscustomobject]@{ Known = $false; Runs = $runs.Count
                                  Why = 'в журналах нет узлов с ненулевым расходом — бэкенд не сообщает токены' }
    }

    # Узлов на задачу: работа + слияние + доля приёмки. Берём из истории, а не из формулы.
    $perNode = $tokens / $nodes
    $avgNodesPerRun = [math]::Max(1.0, $nodes / $runs.Count)
    $estNodes = if ($TaskCount -gt 0) { [int][math]::Ceiling($avgNodesPerRun * $TaskCount / [math]::Max(1.0, $avgNodesPerRun)) * 2 + 4 } else { [int]$avgNodesPerRun }
    $estTokens = $perNode * $estNodes

    $cost = $null
    if ($Pricing) {
        $cost = 0.0
        foreach ($role in $byRole.Keys) {
            $share = $byRole[$role].Tokens / $tokens
            $c = Get-BcfNodeCost -Pricing $Pricing -Model $byRole[$role].Model -Tokens ($estTokens * $share)
            if ($null -ne $c) { $cost += $c } else { $cost = $null; break }
        }
    }

    $top = @($byRole.Keys | Sort-Object { -$byRole[$_].Tokens } | Select-Object -First 1)
    return [pscustomobject]@{
        Known = $true; Runs = $runs.Count; Nodes = $estNodes; Tokens = $estTokens
        Cost = $cost
        TopRole = $(if ($top.Count) { $top[0] } else { '' })
        TopShare = $(if ($top.Count) { [int](100.0 * $byRole[$top[0]].Tokens / $tokens) } else { 0 })
        TopModel = $(if ($top.Count) { $byRole[$top[0]].Model } else { '' })
    }
}
