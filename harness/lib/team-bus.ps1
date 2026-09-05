# team-bus.ps1 — шина между машинами команды: общая ветка, ветка волны, общая доска задач.
#
# ЗАЧЕМ. Заявки и вердикты уже лежат в git, то есть видны всем. Но видны они только
# после того, как кто-то сделает pull, и уезжают только после того, как кто-то сделает
# push. Пока обоих движений нет в самом прогоне, фабрика второго участника работает на
# вчерашнем дереве и молча: он узнаёт об этом на слиянии, когда работа уже сделана.
#
# Здесь три вещи, каждая закрывает свой класс потерь.
#
#   1. НАЧАЛО ПРОГОНА — fetch и перемотка ветки интеграции. Прогон, стартовавший на
#      отставшей ветке, строит поверх несуществующего кода. Перемотка именно
#      fast-forward: слить чужую работу молча значит принять решение, которого никто не
#      принимал, — поэтому разошедшиеся ветки останавливают прогон, а не сводятся сами.
#   2. ВОЛНА УХОДИТ СВОЕЙ ВЕТКОЙ bcf/wave/<дата>. Задачи сливаются в неё, а не в общую
#      ветку напрямую: ночной прогон, пишущий прямо в main, отбирает у человека право
#      посмотреть на результат до того, как тот станет общим.
#   3. ДОСКА ЗАДАЧ tasks/STATUS.json — единственный файл, по которому со стороны видно,
#      что фабрика делает прямо сейчас и что она бросила. Формат закреплён: его читает
#      не только человек.
#
# Без publish.remote всё это выключено, и прогон идёт ровно так, как шёл раньше: на
# локальной ветке интеграции, без ветки волны и без единого сетевого вызова.

. (Join-Path $PSScriptRoot 'claims.ps1')

# ---------------------------------------------------------------------------
# Конфиг
# ---------------------------------------------------------------------------

function _TeamConfig {
    param([Parameter(Mandatory)][string]$Root)
    $f = Join-Path $Root 'config\harness.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch { return $null }
}

# Первые строки вывода git — в причину. Целиком туда класть нельзя: `git push` на
# недоступный адрес печатает десяток строк подсказок, и причина тонет в них.
function _TeamWhy {
    param([AllowEmptyString()][string]$Text, [int]$Lines = 3)
    $t = @(($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $Lines)
    return ($t -join ' / ').Trim()
}

function _TeamHost {
    if ($env:COMPUTERNAME) { return [string]$env:COMPUTERNAME }
    try { return [System.Net.Dns]::GetHostName() } catch { return 'неизвестно' }
}

# Ветка, в которую сводится работа всех участников. Пусто в конфиге читается как
# умолчание, а не как «ветки нет»: пустое имя ветки не бывает осмысленным.
function Get-BcfIntegrationBranch {
    param([Parameter(Mandatory)][string]$Root)
    $cfg = _TeamConfig -Root $Root
    if ($cfg -and $cfg.integration -and $cfg.integration.branch -and "$($cfg.integration.branch)".Trim()) {
        return "$($cfg.integration.branch)".Trim()
    }
    return 'main'
}

# Имя remote, куда публикуется волна. ПУСТО = не публиковать, и это умолчание: фабрика
# на одной машине не обязана иметь ни сети, ни удалённого репозитория.
function Get-BcfPublishRemote {
    param([Parameter(Mandatory)][string]$Root)
    $cfg = _TeamConfig -Root $Root
    if ($cfg -and $cfg.publish -and $cfg.publish.remote) { return "$($cfg.publish.remote)".Trim() }
    return ''
}

# Имя ветки волны. Минуты в имени обязательны: два прогона за день — норма, и второй
# не имеет права дописывать в ветку первого.
function Get-BcfWaveBranchName {
    param([datetime]$When = (Get-Date))
    return 'bcf/wave/' + $When.ToString('yyyy-MM-dd-HHmm')
}

# ---------------------------------------------------------------------------
# Начало прогона: fetch и перемотка ветки интеграции
# ---------------------------------------------------------------------------
#
# ТОЛЬКО FAST-FORWARD, И ЭТО НЕ ОСТОРОЖНОСТЬ. Обычный merge здесь означал бы, что ночной
# прогон сводит две линии работы за человека и без него — а разошлись они как раз потому,
# что кто-то сделал то, чего фабрика не знает. Такое слияние либо конфликтует посреди
# ночи, либо проходит и уносит чужое решение в общую ветку.

function Sync-IntegrationBranch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$Branch
    )
    $inside = (& git -C $Root rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
    if ($inside -ne 'true') {
        return @{ Ok = $false; Kind = 'no-git'; Reason = "$Root — не git-репозиторий, синхронизировать нечего" }
    }

    $fetch = (& git -C $Root fetch $Remote 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; Kind = 'fetch-failed'
                  Reason = "git fetch $Remote не прошёл: $(_TeamWhy $fetch)" }
    }

    $remoteRef = "refs/remotes/$Remote/$Branch"
    $remoteSha = (& git -C $Root rev-parse --verify --quiet $remoteRef 2>$null | Out-String).Trim()
    if (-not $remoteSha) {
        # Первый участник, ещё никто ничего не публиковал. Это не отказ: перематывать
        # нечего, и прогон едет на том, что есть локально.
        return @{ Ok = $true; Kind = 'no-remote-branch'; Sha = ''
                  Reason = "на $Remote ветки $Branch ещё нет — перематывать нечего" }
    }

    $localSha = (& git -C $Root rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-String).Trim()
    if (-not $localSha) {
        & git -C $Root branch $Branch $remoteSha 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Kind = 'branch-failed'
                      Reason = "ветку $Branch не завести от $Remote/$Branch" }
        }
        return @{ Ok = $true; Kind = 'created'; Sha = $remoteSha
                  Reason = "ветка $Branch заведена от $Remote/$Branch" }
    }

    if ($localSha -eq $remoteSha) {
        return @{ Ok = $true; Kind = 'up-to-date'; Sha = $localSha
                  Reason = "$Branch совпадает с $Remote/$Branch" }
    }

    # Перемотка возможна ровно тогда, когда локальная ветка — предок удалённой.
    & git -C $Root merge-base --is-ancestor $localSha $remoteSha 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $ahead = (& git -C $Root rev-list --count "$remoteSha..$localSha" 2>$null | Out-String).Trim()
        if (-not $ahead) { $ahead = '?' }
        return @{ Ok = $false; Kind = 'not-ff'; Sha = $localSha
                  Reason = ("ветка $Branch разошлась с $Remote/$Branch — локальных коммитов сверх удалённой — $ahead, " +
                            "перемотка невозможна. Прогон не стартует: свести две линии работы имеет право человек, " +
                            "а не ночной прогон. Забрать чужое и решить самому — git pull --rebase $Remote $Branch.") }
    }

    $head = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($head -eq $Branch) {
        # Перемотка чекаутом трогает рабочее дерево, поэтому грязь здесь — отказ, а не
        # предупреждение: иначе git отвергнет merge посреди старта и без внятной причины.
        $dirty = @(& git -C $Root status --porcelain 2>$null |
                   Where-Object { $_ -notmatch '^\?\?' } |
                   ForEach-Object { ($_ -replace '^..\s*', '').Trim() } | Where-Object { $_ })
        if ($dirty.Count) {
            return @{ Ok = $false; Kind = 'dirty-tree'; Sha = $localSha
                      Reason = "дерево грязное, перемотка $Branch невозможна: $($dirty -join ', ')" }
        }
        $out = (& git -C $Root merge --ff-only $remoteRef 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Kind = 'not-ff'; Sha = $localSha
                      Reason = "перемотка $Branch до $Remote/$Branch не прошла: $(_TeamWhy $out)" }
        }
    } else {
        & git -C $Root branch -f $Branch $remoteSha 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Kind = 'not-ff'; Sha = $localSha
                      Reason = "ветку $Branch не перемотать до $Remote/$Branch (она занята другим рабочим деревом)" }
        }
    }
    return @{ Ok = $true; Kind = 'fast-forward'; Sha = $remoteSha
              Reason = "$Branch перемотана до $Remote/$Branch" }
}

# ---------------------------------------------------------------------------
# Ветка волны
# ---------------------------------------------------------------------------

function New-WaveBranch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Base
    )
    $head = (& git -C $Root rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($head -eq $Wave) {
        return @{ Ok = $true; Kind = 'already'; Wave = $Wave; Reason = "рабочее дерево уже на ветке волны $Wave" }
    }
    if ($head -ne $Base) {
        $co = (& git -C $Root checkout -q $Base 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Kind = 'checkout-failed'; Wave = ''
                      Reason = "не перейти на ветку интеграции ${Base}: $(_TeamWhy $co)" }
        }
    }
    $exists = (& git -C $Root rev-parse --verify --quiet "refs/heads/$Wave" 2>$null | Out-String).Trim()
    $out = if ($exists) {
        (& git -C $Root checkout -q $Wave 2>&1 | Out-String)
    } else {
        (& git -C $Root checkout -q -b $Wave 2>&1 | Out-String)
    }
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; Kind = 'branch-failed'; Wave = ''
                  Reason = "ветку волны $Wave не завести от $Base : $(_TeamWhy $out)" }
    }
    return @{ Ok = $true; Kind = $(if ($exists) { 'reused' } else { 'created' }); Wave = $Wave
              Reason = "волна идёт веткой $Wave от $Base" }
}

# Отправка волны. Отказ возвращается ТЕКСТОМ ОШИБКИ, а не флагом: «не удалось отправить»
# без причины отправляет человека читать логи, а чинятся отказ прав, отсутствие адреса и
# отклонённый non-fast-forward совершенно по-разному.
function Publish-WaveBranch {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Wave,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Remote
    )
    if (-not $Remote) {
        return @{ Ok = $true; Kind = 'local'; Reason = 'publish.remote не задан — волна остаётся локальной' }
    }
    if (-not $Wave) {
        return @{ Ok = $false; Kind = 'no-wave'; Reason = 'ветка волны не заводилась — отправлять нечего' }
    }
    $out = (& git -C $Root push $Remote "refs/heads/${Wave}:refs/heads/${Wave}" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; Kind = 'push-failed'
                  Reason = "ветка волны $Wave не отправлена в ${Remote}: $(_TeamWhy $out)" }
    }
    return @{ Ok = $true; Kind = 'pushed'; Reason = "ветка волны $Wave отправлена в $Remote" }
}

# Единая точка старта прогона для обоих оркестраторов (цикл и граф). Возвращает то, что
# им нужно знать дальше: имя remote, имя ветки волны и причину, если стартовать нельзя.
function Start-TeamRun {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Wave = ''
    )
    $branch = Get-BcfIntegrationBranch -Root $Root
    $remote = Get-BcfPublishRemote -Root $Root
    if (-not $remote) {
        return @{ Ok = $true; Kind = 'local'; Remote = ''; Branch = $branch; Wave = ''
                  Reason = "publish.remote не задан — прогон идёт на локальной ветке интеграции $branch" }
    }

    $sync = Sync-IntegrationBranch -Root $Root -Remote $remote -Branch $branch
    if (-not $sync.Ok) {
        return @{ Ok = $false; Kind = $sync.Kind; Remote = $remote; Branch = $branch; Wave = ''
                  Reason = $sync.Reason }
    }

    $name = if ($Wave) { $Wave } else { Get-BcfWaveBranchName }
    $w = New-WaveBranch -Root $Root -Wave $name -Base $branch
    if (-not $w.Ok) {
        return @{ Ok = $false; Kind = $w.Kind; Remote = $remote; Branch = $branch; Wave = ''
                  Reason = $w.Reason }
    }
    return @{ Ok = $true; Kind = 'wave'; Remote = $remote; Branch = $branch; Wave = $name
              Reason = "$($sync.Reason); $($w.Reason)" }
}

# ---------------------------------------------------------------------------
# Доска задач: tasks/STATUS.json
# ---------------------------------------------------------------------------
#
# КОНТРАКТ ФАЙЛА (его читает не только человек, поэтому имена полей и значения состояний
# фиксированы):
#
#   {
#     "run": "<id прогона>", "host": "<имя машины>", "updated": "<ISO-время>",
#     "complete": false,
#     "tasks": { "<TASK-ID>": { "state": "у фабрики|закрыта|заблокирована|в очереди",
#                               "node": "<имя узла>", "since": "<ISO>" } },
#     "needs_human": ["<ID>"], "gate_blocked": ["<ID>"]
#   }
#
# «у фабрики» ставится, пока узел задачи не закончен. После конца прогона complete=true,
# а всё, что осталось «у фабрики», возвращается в «в очереди»: оборванный прогон не имеет
# права оставить задачу навсегда занятой — со стороны это неотличимо от работающей.
#
# Файл отслеживается git и уезжает вместе с волной: доска, видимая одному человеку,
# ничем не лучше её отсутствия.

$script:BcfTaskStateFactory = 'у фабрики'
$script:BcfTaskStateClosed  = 'закрыта'
$script:BcfTaskStateBlocked = 'заблокирована'
$script:BcfTaskStateQueued  = 'в очереди'

function Get-TaskStatusPath {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path (Get-BcfTasksDir -Root $Root) 'STATUS.json')
}

function Get-TaskStatusRelPath {
    param([Parameter(Mandatory)][string]$Root)
    $p = Get-TaskStatusPath -Root $Root
    return (($p.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/')
}

function Read-TaskStatus {
    param([Parameter(Mandatory)][string]$Root)
    $p = Get-TaskStatusPath -Root $Root
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $p
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# Доску пишут параллельные ветки конвейера из разных потоков и разных процессов, поэтому
# чтение-правка-запись идут под межпроцессным замком. Имя замка привязано к корню
# проекта: две фабрики на одной машине не должны ждать друг друга.
function _WithTaskStatusLock {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Body)
    $tag = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Root.ToLower()))).Replace('-', '').Substring(0, 12)
    $mtx = $null
    $held = $false
    try {
        $mtx = New-Object System.Threading.Mutex($false, "Global\bcf-status-$tag")
        $held = $mtx.WaitOne(15000)
    } catch { $mtx = $null }
    try { return & $Body }
    finally {
        if ($mtx) { if ($held) { try { $mtx.ReleaseMutex() } catch { } }; $mtx.Dispose() }
    }
}

function _NewTaskStatus {
    param([string]$Run = '')
    return [ordered]@{
        run          = $Run
        host         = (_TeamHost)
        updated      = (Get-Date -Format 'o')
        complete     = $false
        tasks        = [ordered]@{}
        needs_human  = @()
        gate_blocked = @()
    }
}

# Читаем доску в изменяемый вид. НОВЫЙ прогон начинает с чистого листа: чужие состояния,
# оставшиеся от прошлой ночи, читались бы как факты про эту.
function _LoadTaskStatus {
    param([Parameter(Mandatory)][string]$Root, [string]$Run = '')
    $o = Read-TaskStatus -Root $Root
    if (-not $o) { return (_NewTaskStatus -Run $Run) }
    if ($Run -and $o.run -and ([string]$o.run) -ne $Run) { return (_NewTaskStatus -Run $Run) }

    $st = _NewTaskStatus -Run $(if ($Run) { $Run } else { [string]$o.run })
    $st.complete = [bool]$o.complete
    if ($o.tasks) {
        foreach ($p in $o.tasks.PSObject.Properties) {
            # ConvertFrom-Json сам разбирает ISO-строку since в [datetime], и голое
            # [string] печатает её ФОРМАТОМ ЛОКАЛИ («09/05/2026 16:48:42», без часового
            # пояса и долей секунды) — контракт файла требует ISO, поэтому дату при
            # перечитывании форматируем явно обратно тем же 'o', которым она писалась.
            $sinceVal = $p.Value.since
            $since = if ($sinceVal -is [datetime]) { $sinceVal.ToString('o') } else { [string]$sinceVal }
            $st.tasks[$p.Name] = [ordered]@{
                state = [string]$p.Value.state
                node  = [string]$p.Value.node
                since = $since
            }
        }
    }
    $st.needs_human  = @($o.needs_human  | Where-Object { $_ })
    $st.gate_blocked = @($o.gate_blocked | Where-Object { $_ })
    return $st
}

function _SaveTaskStatus {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Status)
    $p = Get-TaskStatusPath -Root $Root
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # -InputObject, а не конвейер: пустой массив в конвейере не даёт ConvertTo-Json ни
    # одной строки, Set-Content не получает входа и файл остаётся прежним — доска
    # прогона без задач молча показывала бы прошлую ночь.
    Set-Content -LiteralPath $p -Value (ConvertTo-Json -InputObject $Status -Depth 6) -Encoding UTF8
}

function Update-TaskStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][ValidateSet('у фабрики', 'закрыта', 'заблокирована', 'в очереди')][string]$State,
        [string]$Node = '',
        [string]$Run = ''
    )
    return (_WithTaskStatusLock -Root $Root -Body {
        $st = _LoadTaskStatus -Root $Root -Run $Run
        $now = (Get-Date -Format 'o')
        $prev = $st.tasks[$Task]
        # «since» — время ПОСЛЕДНЕЙ СМЕНЫ состояния, а не время последней записи: иначе
        # по нему нельзя увидеть, что задача висит в одном состоянии третий час.
        $since = if ($prev -and ([string]$prev.state) -eq $State -and $prev.since) { [string]$prev.since } else { $now }
        $node = if ($Node) { $Node } elseif ($prev) { [string]$prev.node } else { '' }
        $st.tasks[$Task] = [ordered]@{ state = $State; node = $node; since = $since }
        $st.updated = $now
        $st.host = (_TeamHost)
        # Смена состояния задачи означает живой прогон: держать при этом complete=true
        # значит показывать наблюдателю законченным то, что идёт.
        $st.complete = $false
        _SaveTaskStatus -Root $Root -Status $st
        return $st
    })
}

function Complete-TaskStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Run = '',
        [string[]]$NeedsHuman,
        [string[]]$GateBlocked
    )
    $setHuman = $PSBoundParameters.ContainsKey('NeedsHuman')
    $setGate  = $PSBoundParameters.ContainsKey('GateBlocked')
    return (_WithTaskStatusLock -Root $Root -Body {
        $st = _LoadTaskStatus -Root $Root -Run $Run
        $now = (Get-Date -Format 'o')
        foreach ($k in @($st.tasks.Keys)) {
            if (([string]$st.tasks[$k].state) -ne $script:BcfTaskStateFactory) { continue }
            # Узел кончился вместе с прогоном, а задача не закрылась. Она снова ничья, и
            # имя узла остаётся: по нему видно, где именно её бросили.
            $st.tasks[$k] = [ordered]@{
                state = $script:BcfTaskStateQueued
                node  = [string]$st.tasks[$k].node
                since = $now
            }
        }
        if ($setHuman) { $st.needs_human  = @($NeedsHuman  | Where-Object { $_ }) }
        if ($setGate)  { $st.gate_blocked = @($GateBlocked | Where-Object { $_ }) }
        $st.complete = $true
        $st.updated = $now
        $st.host = (_TeamHost)
        _SaveTaskStatus -Root $Root -Status $st
        return $st
    })
}

# Доска на старте прогона: очередь целиком, а не только то, за что фабрика уже взялась.
# Иначе наблюдателю видно ровно одну задачу — ту, что идёт, — и он не может отличить
# «остальные ждут» от «остальных нет».
function Reset-TaskStatusBoard {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Run,
        [string[]]$Queued = @(),
        [string[]]$Closed = @()
    )
    return (_WithTaskStatusLock -Root $Root -Body {
        $st = _NewTaskStatus -Run $Run
        $now = (Get-Date -Format 'o')
        foreach ($t in @($Queued | Where-Object { $_ })) {
            $st.tasks[$t] = [ordered]@{ state = $script:BcfTaskStateQueued; node = ''; since = $now }
        }
        foreach ($t in @($Closed | Where-Object { $_ })) {
            $st.tasks[$t] = [ordered]@{ state = $script:BcfTaskStateClosed; node = ''; since = $now }
        }
        _SaveTaskStatus -Root $Root -Status $st
        return $st
    })
}

# Конец прогона одним куском: доска закрывается, коммитится и уезжает вместе с волной.
#
# ПОРЯДОК ЗДЕСЬ — ЧАСТЬ КОНТРАКТА. Доска коммитится ДО отправки, иначе она уедет на день
# позже собственной волны. Отказ отправки дописывается в затыки ПОСЛЕ неё и попадает и в
# отчёт, и обратно на доску: «волна не опубликована» — это состояние, требующее человека,
# а не строчка в логе, которую никто не читает.
function Complete-TeamRun {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Run,
        [Parameter(Mandatory)]$Team,
        [object[]]$Stuck = @()
    )
    $stuck = @($Stuck | Where-Object { $_ })
    $needsHuman  = @($stuck | Where-Object { $_.Reason -notlike 'gate-block*' } | ForEach-Object { [string]$_.Task })
    $gateBlocked = @($stuck | Where-Object { $_.Reason -like 'gate-block*' }    | ForEach-Object { [string]$_.Task })

    Complete-TaskStatus -Root $Root -Run $Run -NeedsHuman $needsHuman -GateBlocked $gateBlocked | Out-Null
    Publish-TaskStatus -Root $Root -Message "фабрика: доска задач ($Run)" | Out-Null

    $wave   = if ($Team -and $Team.Wave)   { [string]$Team.Wave }   else { '' }
    $remote = if ($Team -and $Team.Remote) { [string]$Team.Remote } else { '' }
    $pub = Publish-WaveBranch -Root $Root -Wave $wave -Remote $remote

    if (-not $pub.Ok) {
        $stuck += [pscustomobject]@{ Task = $(if ($wave) { $wave } else { 'публикация волны' }); Reason = $pub.Reason }
        $needsHuman += $(if ($wave) { $wave } else { 'публикация волны' })
        Complete-TaskStatus -Root $Root -Run $Run -NeedsHuman $needsHuman -GateBlocked $gateBlocked | Out-Null
        Publish-TaskStatus -Root $Root -Message "фабрика: доска задач ($Run)" | Out-Null
    }
    return @{ Stuck = @($stuck); Publish = $pub; NeedsHuman = @($needsHuman); GateBlocked = @($gateBlocked) }
}

# Доска едет в git вместе с волной. Коммит именно одного файла: иначе доска остаётся
# грязью в tasks/, а грязный tasks/ отменяет слияние следующей задачи.
function Publish-TaskStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Message = 'фабрика: доска задач'
    )
    $p = Get-TaskStatusPath -Root $Root
    if (-not (Test-Path -LiteralPath $p)) { return @{ Ok = $false; Reason = 'доски задач ещё нет' } }
    return (Publish-BcfClaimChange -Root $Root -Paths @(Get-TaskStatusRelPath -Root $Root) -Message $Message)
}

# Имя задачи из метки узла. Метки графа устроены как «работа-TASK-06», «арбитр-TASK-06»,
# «слитое-TASK-06-317»; всё остальное («ревизия-плана», «приёмка-гейты», «факты-2») задачи
# не называет. Идентификатор задачи начинается с латинской буквы, поэтому кириллический
# префикс метки в него не попадает.
function Get-BcfTaskIdFromLabel {
    param([AllowEmptyString()][string]$Label, [string]$Pattern = '[A-Za-z][A-Za-z0-9]*-\d+')
    if (-not $Label) { return '' }
    $m = [regex]::Match($Label, $Pattern)
    if ($m.Success) { return $m.Value }
    return ''
}

# ---------------------------------------------------------------------------
# Номер следующей задачи — с оглядкой на remote
# ---------------------------------------------------------------------------
#
# ЗАЧЕМ. Номер, выбранный по локальным файлам, у второго участника команды совпадает с
# уже занятым: он заводит TASK-07, потому что у него их шесть, а у первого их девять и
# седьмая давно в работе. Столкновение обнаруживается на слиянии — двумя разными
# задачами под одним именем, каждая со своим вердиктом.
#
# Дерево ветки читается БЕЗ fetch: `bcf task new` вызывают десятки раз в день, и сетевой
# вызов на каждый — это пауза там, где её быть не должно. Свежесть даёт прогон, который
# начинается с fetch; здесь достаточно того, что уже есть в refs/remotes.

function Get-BcfRemoteTaskMax {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Prefix = 'TASK',
        [string]$TasksRel = 'tasks'
    )
    $remote = Get-BcfPublishRemote -Root $Root
    if (-not $remote) { $remote = 'origin' }
    $branch = Get-BcfIntegrationBranch -Root $Root
    $ref = "refs/remotes/$remote/$branch"

    $sha = (& git -C $Root rev-parse --verify --quiet $ref 2>$null | Out-String).Trim()
    if (-not $sha) { return 0 }

    $rel = ($TasksRel -replace '\\', '/').TrimEnd('/')
    $names = @(& git -C $Root ls-tree --name-only $ref -- "$rel/" 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $rx = '^' + [regex]::Escape("$rel/") + [regex]::Escape($Prefix) + '-(\d+)'
    $max = 0
    foreach ($n in $names) {
        $m = [regex]::Match($n, $rx)
        if ($m.Success) { $max = [Math]::Max($max, [int]$m.Groups[1].Value) }
    }
    return $max
}

# Строка в tasks/index.md. Реестр нужен ровно затем, чтобы занятые номера было видно
# глазами и в диффе: файл задачи у соседа появляется только после слияния, а строка в
# общем списке — сразу, как только он его отправил.
function Add-BcfTaskIndexEntry {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][string]$RelPath
    )
    $dir = Get-BcfTasksDir -Root $Root
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $idx = Join-Path $dir 'index.md'
    if (-not (Test-Path -LiteralPath $idx)) {
        Set-Content -LiteralPath $idx -Encoding UTF8 -Value @"
# Реестр задач

Строку сюда дописывает ``bcf task new``. Список нужен затем, чтобы занятый номер было
видно до слияния: файл задачи, заведённой на другой машине, приезжает вместе с её
работой, а строка в реестре — сразу.

"@
    }
    $line = "- $TaskId — $Title — ``$RelPath``"
    $have = @(Get-Content -LiteralPath $idx -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($have -contains $line) { return $idx }
    Add-Content -LiteralPath $idx -Value $line -Encoding UTF8
    return $idx
}
