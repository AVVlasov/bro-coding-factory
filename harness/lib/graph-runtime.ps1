# graph-runtime.ps1 — движок графа агентов (замена линейной петли).
#
# ЗАЧЕМ. До этого файла оркестрация была ЦИКЛОМ: run-all.ps1 шёл по очереди задач
# многопроходно, и каждый шаг ждал предыдущего, даже когда они не связаны. Всё, что
# было от графа, — грубые рёбра «Gate-вход» между задачами. Верификация была прибита
# гвоздями внутрь одной задачи (verify.ps1, фазы C/D/E) и не была переиспользуемым узлом.
#
# ЗДЕСЬ. План переезжает В КОД: скрипт графа сам держит ветвления, циклы и промежуточные
# результаты, а узлы — агенты — не хранят план в своём контексте. Отсюда два выигрыша,
# и параллелизм из них ВТОРОЙ по важности:
#   1. Чистота контекста: планировщик никогда не реализует, исполнитель никогда не планирует.
#   2. Скорость: независимые узлы идут одновременно.
#
# АЛГЕБРА (сознательно повторяет примитивы динамических воркфлоу Claude Code, чтобы
# готовые рецепты графов переносились сюда без перевода):
#
#   Set-Phase 'Название'                    — группа узлов в прогрессе и в журнале
#   Invoke-Node   -Prompt … [-Schema …]     — ОДИН агент; со схемой возвращает объект
#   Invoke-Barrier  -Thunks @({…},{…})      — БАРЬЕР: ждём все ветки, потом дальше
#   Invoke-Pipeline -Items … -Stages @(…)   — БЕЗ барьера: каждый элемент течёт по стадиям сам
#   Write-GraphLog 'строка'                 — сообщение прогресса
#   $GraphArgs                              — вход графа
#
# ПО УМОЛЧАНИЮ — Invoke-Pipeline. Барьер оправдан ТОЛЬКО когда стадии N нужен
# перекрёстный контекст всех результатов стадии N-1 (дедуп по всему множеству, ранний
# выход при нуле находок, сравнение находок между собой). «Мне надо сначала сплющить
# список» барьером не является — плющить надо внутри стадии. Барьер стоит реального
# времени: если из пяти веток самая медленная втрое дольше самой быстрой, барьер
# выбрасывает две трети простоя быстрых веток.
#
# ЖУРНАЛ И ВОЗОБНОВЛЕНИЕ. Каждый узел пишется в .bcf/graph/<runId>/journal.jsonl.
# Ключ узла — АДРЕС ПО СОДЕРЖИМОМУ: sha256(фаза|метка|промпт) + порядковый номер
# повтора этого же ключа. Поэтому возобновление здесь строго сильнее, чем replay «по
# порядку старта»: остановленный веер сохраняет ВСЕ доработавшие узлы, а не только
# префикс до первого недоработавшего. Плата — запрет на недетерминированность в самом
# скрипте графа (Get-Random / Get-Date в тексте промпта ломают ключ; время и случайность
# передавай через -GraphArgs).

Set-StrictMode -Off

$script:GraphCtx = $null

# ---------------------------------------------------------------------------
# Контекст прогона
# ---------------------------------------------------------------------------

function Initialize-GraphRun {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Meta,
        $GraphArgs = $null,
        [string]$RunId = '',
        [string]$ResumeFromRunId = '',
        [int]$MaxConcurrency = 0,
        [int]$MaxNodes = 1000,
        [double]$TokenBudget = 0,
        [switch]$DryPlan,
        # ТОЛЬКО ЧТЕНИЕ: собрать контекст для показа чужого прогона, ничего в него не
        # записав. Без этого просмотр доски дописывал в журнал ПОКАЗЫВАЕМОГО прогона
        # второй run-start: время старта уезжало на «сейчас», длительность становилась
        # отрицательной, и запись портилась просто оттого, что на неё посмотрели.
        [switch]$ReadOnly
    )

    $cfg = $null
    try { $cfg = Get-Content -Raw -LiteralPath (Join-Path $Root 'config\harness.json') | ConvertFrom-Json } catch { }

    if ($MaxConcurrency -le 0) {
        $cores = [Environment]::ProcessorCount
        $byCfg = if ($cfg -and $cfg.limits.agentConcurrency) { [int]$cfg.limits.agentConcurrency } else { 6 }
        # Тот же потолок, что у остальных ролей: упираемся в rate-limit провайдера
        # раньше, чем в машину, поэтому счётчик агентов один на весь харнесс.
        $MaxConcurrency = [Math]::Max(1, [Math]::Min($byCfg, [Math]::Max(1, $cores - 2)))
    }

    if (-not $RunId) {
        # Идентификатор прогона — единственное место, где допустимо текущее время:
        # в тексте промптов его быть не должно, иначе развалится адресация по содержимому.
        $RunId = 'g_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    }

    $graphDir = Join-Path $Root ".bcf\graph\$RunId"
    if (-not (Test-Path $graphDir)) { New-Item -ItemType Directory -Force -Path $graphDir | Out-Null }

    # Кэш возобновления: читаем журнал ПРОШЛОГО прогона, а пишем всегда в свой.
    $cache = @{}
    if ($ResumeFromRunId) {
        $prev = Join-Path $Root ".bcf\graph\$ResumeFromRunId\journal.jsonl"
        if (Test-Path $prev) {
            foreach ($line in (Get-Content -LiteralPath $prev -Encoding UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $rec = $line | ConvertFrom-Json } catch { continue }
                # Незавершённый узел в кэш не попадает: он обязан переиграться.
                if ($rec.event -ne 'node-finish' -or -not $rec.ok) { continue }
                $cache[[string]$rec.key] = $rec
            }
        }
    }

    $script:GraphCtx = @{
        Root           = $Root
        RunId          = $RunId
        Dir            = $graphDir
        Journal        = (Join-Path $graphDir 'journal.jsonl')
        Meta           = $Meta
        Args           = $GraphArgs
        Phase          = if ($Meta.phases -and @($Meta.phases).Count) { [string]@($Meta.phases)[0].title } else { 'main' }
        MaxConcurrency = $MaxConcurrency
        MaxNodes       = $MaxNodes
        BudgetTotal    = $TokenBudget
        DryPlan        = [bool]$DryPlan
        Cache          = $cache
        ResumeFrom     = $ResumeFromRunId
        RuntimePath    = $PSCommandPath
        AgentCmdTpl    = if ($cfg -and $cfg.agent.command) { [string]$cfg.agent.command } else { 'opencode run --dangerously-skip-permissions --thinking --format json --model {model}' }
        Models         = @{
            planner = _GraphModel $cfg @('graph', 'models', 'planner') (_GraphModel $cfg @('models', 'code') '')
            worker  = _GraphModel $cfg @('graph', 'models', 'worker')  (_GraphModel $cfg @('models', 'code') '')
            critic  = _GraphModel $cfg @('graph', 'models', 'critic')  (_GraphModel $cfg @('models', 'judge') '')
            arbiter = _GraphModel $cfg @('graph', 'models', 'arbiter') (_GraphModel $cfg @('models', 'code') '')
        }
        Backends       = _GraphBackends $cfg
        Roles          = _GraphRoles $cfg
        Vars           = @{}
        StartedAt      = (Get-Date)
        Board          = (_GraphBoardSupported)
        BoardRow       = $null
        BoardLines     = 0
        Pulse          = 0
        Activity       = @{}
        Quiet          = $false
        NodeTimeoutSec = if ($cfg -and $cfg.timeouts.stepSec)   { [int]$cfg.timeouts.stepSec }   else { 1800 }
        SilentSec      = if ($cfg -and $cfg.timeouts.silentSec) { [int]$cfg.timeouts.silentSec } else { 300 }
        MutexName      = "Global\bcf-graph-$RunId"
    }

    if (-not $ReadOnly) {
        _GraphJournal @{ event = 'run-start'; runId = $RunId; name = $Meta.name; doctor = [bool]$Meta.doctor; resumeFrom = $ResumeFromRunId
                         concurrency = $MaxConcurrency; budget = $TokenBudget; dryPlan = [bool]$DryPlan }
    }
    return $script:GraphCtx
}

# --- Бэкенды и роли ---
#
# Раньше команда агента была ОДНА на весь граф, и роль переключала только модель. Это
# годится, пока все роли живут в одной CLI, и разваливается ровно тогда, когда ярусы
# разъезжаются по разным инструментам: у каждой CLI свой формат событий, своя авторизация
# и свои флаги доступа к диску. Поэтому роль разрешается в ТРОЙКУ: команда, модель, разборщик.

# ПРИБИТЫЙ ПУТЬ К CLI ПРОТУХАЕТ — ЛЕЧИМ НА МЕСТЕ.
#
# Часть агентских CLI живёт не на PATH, а внутри установки приложения, и путь содержит хэш
# сборки: `…\Codex\bin\68de26ad08be95cd\codex.exe`. После обновления приложения каталог
# другой, а в конфиге проекта остаётся старый. Наблюдалось живьём 2026-08-08: все три
# критика упали по три попытки с «is not recognized as a name of a cmdlet», приёмка не
# выполнилась, а отчёт написал «Находок нет».
#
# Чиним ровно ту форму, которая протухает: сосед по каталогу-родителю с тем же именем
# файла. Ничего не выдумываем: если замены нет, оставляем как было — пусть падает с
# понятной ошибкой, а не с подменённым бинарём.
function _RepairPinnedBinary([string]$Command, [string]$BackendName) {
    if (-not $Command) { return $Command }
    $m = [regex]::Match($Command, "^\s*&\s*'([^']+)'")
    if (-not $m.Success) { return $Command }
    $pinned = $m.Groups[1].Value
    if (Test-Path -LiteralPath $pinned) { return $Command }

    $leaf   = Split-Path $pinned -Leaf
    $parent = Split-Path (Split-Path $pinned -Parent) -Parent
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { return $Command }

    $found = Get-ChildItem -Path (Join-Path $parent "*\$leaf") -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { return $Command }

    Write-Host "  · путь к '$BackendName' протух ($pinned) — беру свежий: $($found.FullName)" -ForegroundColor DarkGray
    return ($Command -replace [regex]::Escape("'$pinned'"), "'$($found.FullName)'")
}

function _GraphBackends($cfg) {
    $out = @{}
    $b = $null
    if ($cfg) { $p = $cfg.PSObject.Properties['graph']; if ($p) { $q = $p.Value.PSObject.Properties['backends']; if ($q) { $b = $q.Value } } }
    if ($b) {
        foreach ($prop in $b.PSObject.Properties) {
            if ($prop.Name -like '$*') { continue }
            $v = $prop.Value
            if (-not $v.command) { continue }
            # probeModel — чем проверять бэкенд, у которого ещё нет ролей. Без него
            # «готов ли claude/cursor» нельзя узнать, не назначив им роли в боевом графе,
            # то есть проверка требовала бы сначала сделать прогон зависимым от непроверенного.
            $out[$prop.Name] = @{
                Command    = (_RepairPinnedBinary ([string]$v.command) $prop.Name)
                Format     = [string]$(if ($v.format) { $v.format } else { 'opencode' })
                ProbeModel = [string]$v.probeModel
                # Дешёвая проверка авторизации: не тратит ни одного токена и отвечает
                # точнее пробного прогона. Незалогиненная CLI отвечает штатным событием,
                # и без такой проверки причина «нет авторизации» неотличима от «модель
                # промолчала» — а стоит она полного пробного запроса.
                AuthCheck  = [string]$v.authCheck
                AuthOk     = [string]$v.authOkPattern
                # Переменные окружения, без которых бэкенд не авторизован. Windows не
                # пробрасывает новые переменные в УЖЕ запущенные процессы: харнесс,
                # стартовавший до `claude setup-token`, не увидит токен и получит
                # «Not logged in» при полностью исправной учётке. Поэтому недостающие
                # добираем из User/Machine-области явно, а не надеемся на наследование.
                Env        = @($v.env)
            }
        }
    }
    return $out
}

function _GraphRoles($cfg) {
    $out = @{}
    $r = $null
    if ($cfg) { $p = $cfg.PSObject.Properties['graph']; if ($p) { $q = $p.Value.PSObject.Properties['roles']; if ($q) { $r = $q.Value } } }
    if ($r) {
        foreach ($prop in $r.PSObject.Properties) {
            if ($prop.Name -like '$*') { continue }
            $v = $prop.Value
            # Запасная модель роли. Необязательна; когда её нет — поведение прежнее.
            # Две формы, обе валидны: "fallback": "sonnet" (та же CLI, другая модель) и
            # "fallback": { "backend": "codex", "model": "gpt-5.6" }. Строку человек пишет
            # руками чаще, и отвергать её значит требовать формальности вместо работы.
            $fb = $null
            $fp = $v.PSObject.Properties['fallback']
            if ($fp -and $fp.Value) {
                $fv = $fp.Value
                if ($fv -is [string]) {
                    if ($fv.Trim()) { $fb = @{ Backend = [string]$v.backend; Model = $fv.Trim() } }
                } elseif ([string]$fv.backend -or [string]$fv.model) {
                    $fb = @{ Backend = [string]$fv.backend; Model = [string]$fv.model }
                    if (-not $fb.Backend) { $fb.Backend = [string]$v.backend }   # та же CLI, другая модель
                }
            }
            $out[$prop.Name] = @{ Backend = [string]$v.backend; Model = [string]$v.model; Fallback = $fb }
        }
    }
    return $out
}

# Роль → чем и как её исполнять. Если ролей в конфиге нет, поведение остаётся прежним:
# единая agent.command и models.* — старые прогоны от этой правки не меняются.
function Resolve-GraphRole {
    param([Parameter(Mandatory)][string]$Role, [string]$ModelOverride = '')

    $ctx = $script:GraphCtx
    $spec = $ctx.Roles[$Role]
    if ($spec -and $spec.Backend -and $ctx.Backends.ContainsKey($spec.Backend)) {
        $b = $ctx.Backends[$spec.Backend]
        # Запасная резолвится СРАЗУ и здесь же: искать её в момент отказа значит делать это
        # на горячем пути, где уже нет ни времени, ни внятной диагностики.
        $fb = $null
        if ($spec.Fallback -and $ctx.Backends.ContainsKey($spec.Fallback.Backend)) {
            $fbB = $ctx.Backends[$spec.Fallback.Backend]
            $fb = @{
                Backend = $spec.Fallback.Backend
                Command = $fbB.Command
                Format  = $fbB.Format
                Env     = @($fbB.Env)
                Model   = $spec.Fallback.Model
            }
        }
        return @{
            Backend  = $spec.Backend
            Command  = $b.Command
            Format   = $b.Format
            Env      = @($b.Env)
            Model    = if ($ModelOverride) { $ModelOverride } else { $spec.Model }
            Fallback = $fb
        }
    }
    if ($spec -and $spec.Backend) {
        throw "роль '$Role' указывает на бэкенд '$($spec.Backend)', которого нет в graph.backends"
    }
    return @{
        Backend = 'default'
        Command = $ctx.AgentCmdTpl
        Format  = 'opencode'
        Env     = @()
        Model   = if ($ModelOverride) { $ModelOverride } else { [string]$ctx.Models[$Role] }
    }
}

# Разбор потока событий. У каждой CLI своя схема — схемы сняты с живого вывода
# (кроме cursor: он на Free-плане не дал завершить прогон, его ветка помечена как
# неподтверждённая и обязана быть проверена первым же удачным запуском).
function ConvertFrom-AgentStream {
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Format)

    $text = [System.Text.StringBuilder]::new()
    $tokens = 0
    $failed = ''

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $ev = $null
        try { $ev = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $t = [string]$ev.type

        switch ($Format) {
            'opencode' {
                if ($t -eq 'text') { [void]$text.AppendLine([string]$ev.part.text) }
                elseif ($t -eq 'step_finish' -and $ev.part.tokens.total) { $tokens += [double]$ev.part.tokens.total }
            }
            'codex' {
                # Финальный ответ приходит одним item.completed с type=agent_message.
                if ($t -eq 'item.completed' -and [string]$ev.item.type -eq 'agent_message') {
                    [void]$text.AppendLine([string]$ev.item.text)
                }
                elseif ($t -eq 'turn.completed' -and $ev.usage) {
                    $tokens += [double]$ev.usage.input_tokens + [double]$ev.usage.output_tokens
                }
                elseif ($t -eq 'turn.failed' -or $t -eq 'error') {
                    $failed = [string]$(if ($ev.error.message) { $ev.error.message } else { $line })
                }
            }
            'claude' {
                # У claude есть итоговое событие result с готовым текстом — оно
                # авторитетнее склейки assistant-кусков, поэтому перезаписывает её.
                if ($t -eq 'result') {
                    if ($ev.is_error) { $failed = [string]$ev.result }
                    else { [void]$text.Clear(); [void]$text.AppendLine([string]$ev.result) }
                    # ВНИМАНИЕ: у claude input_tokens — это ТОЛЬКО некэшированный вход.
                    # Чтение и запись кэша приходят отдельными полями, и без них узел с
                    # большим системным промптом выглядел одиннадцатитокенным: живая проба
                    # ролей давала claude 11 против 16 677 у codex на одной и той же
                    # задаче. Числа несравнимы между бэкендами — а на них держится и смета,
                    # и потолок «до исчерпания»: слепой ограничитель не срабатывает никогда.
                    # У codex input_tokens уже включает кэш (cached_input_tokens — его
                    # подмножество), поэтому там складывать нечего.
                    if ($ev.usage) {
                        $tokens += [double]$ev.usage.input_tokens + [double]$ev.usage.output_tokens +
                                   [double]$ev.usage.cache_read_input_tokens + [double]$ev.usage.cache_creation_input_tokens
                    }
                }
                elseif ($t -eq 'assistant' -and $text.Length -eq 0) {
                    foreach ($c in @($ev.message.content)) {
                        if ([string]$c.type -eq 'text') { [void]$text.AppendLine([string]$c.text) }
                    }
                }
            }
            'cursor' {
                if ($t -eq 'result') {
                    if ($ev.is_error) { $failed = [string]$ev.result }
                    else { [void]$text.Clear(); [void]$text.AppendLine([string]$ev.result) }
                    # ВНИМАНИЕ: у cursor расход в camelCase (inputTokens/outputTokens), а не
                    # в snake_case, как у claude. Схема выглядит почти одинаково, поэтому
                    # скопированный разборщик молча возвращал ноль — то есть узлы этого
                    # бэкенда были невидимы для бюджета графа, а выглядело это как «бесплатно».
                    if ($ev.usage) { $tokens += [double]$ev.usage.inputTokens + [double]$ev.usage.outputTokens }
                }
                elseif ($t -eq 'assistant') {
                    foreach ($c in @($ev.message.content)) {
                        if ([string]$c.type -eq 'text') { [void]$text.AppendLine([string]$c.text) }
                    }
                }
            }
        }
    }
    return @{ Text = $text.ToString().Trim(); Tokens = $tokens; Failed = $failed }
}

# Значение из вложенного пути конфига с запасным вариантом.
function _GraphModel($cfg, [string[]]$path, $fallback) {
    $cur = $cfg
    foreach ($p in $path) {
        if ($null -eq $cur) { return $fallback }
        $prop = $cur.PSObject.Properties[$p]
        if (-not $prop) { return $fallback }
        $cur = $prop.Value
    }
    if ($null -eq $cur -or [string]::IsNullOrWhiteSpace([string]$cur)) { return $fallback }
    return [string]$cur
}

# Плоский снимок контекста: то, что переживает переезд в чужой runspace.
# Кэш и мета сериализуемы, объекты процессов — нет, поэтому их тут и нет.
function Export-GraphContext { return $script:GraphCtx }
function Import-GraphContext { param($Ctx) $script:GraphCtx = $Ctx }

# --- Захват внешних значений в ветки ---
#
# `$using:` внутри веток НЕ РАБОТАЕТ, и это не недоделка, а следствие устройства:
# скриптблок ветки переезжает в чужой runspace ИСХОДНЫМ ТЕКСТОМ и собирается там
# заново, а `$using:` разрешается только у литерального тела ForEach-Object -Parallel.
# Роль замыкания играет эта пара: значение, положенное ДО веера, видно во всех ветках.
#
#     Set-GraphVar tasks $queue
#     Invoke-Barrier -Thunks @({ foreach ($t in (Get-GraphVar tasks)) { … } })
#
# Обратно значения не ходят: ветка изолирована, её результат — это то, что она вернула.
function Set-GraphVar {
    param([Parameter(Mandatory, Position = 0)][string]$Name, [Parameter(Position = 1)]$Value)
    if (-not $script:GraphCtx.Vars) { $script:GraphCtx.Vars = @{} }
    $script:GraphCtx.Vars[$Name] = $Value
}

function Get-GraphVar {
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    if (-not $script:GraphCtx.Vars) { return $null }
    return $script:GraphCtx.Vars[$Name]
}

function Get-GraphRunId { return $script:GraphCtx.RunId }

# ---------------------------------------------------------------------------
# Журнал (потокобезопасно) и бюджет
# ---------------------------------------------------------------------------

function _GraphJournal {
    param([hashtable]$Record)
    if (-not $script:GraphCtx) { return }
    $Record['ts'] = (Get-Date -Format 'o')
    $line = ($Record | ConvertTo-Json -Depth 8 -Compress)
    # Журнал пишут параллельные ветки одновременно; без взаимного исключения строки
    # рвутся посередине и файл перестаёт разбираться — то есть возобновление молча
    # теряет узлы, а выглядит это как «кэш пуст».
    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, $script:GraphCtx.MutexName)
        [void]$mtx.WaitOne(15000)
    } catch { $mtx = $null }
    try {
        Add-Content -LiteralPath $script:GraphCtx.Journal -Value $line -Encoding UTF8
    } catch { } finally {
        if ($mtx) { try { $mtx.ReleaseMutex() } catch { }; $mtx.Dispose() }
    }
}

function Write-GraphLog {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [switch]$Detail)
    $line = "[{0}] [graph] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    # Ветка внутри веера в консоль НЕ пишет. Иначе N параллельных узлов рвут вывод друг
    # друга на середине строки, и чем шире веер, тем менее читаем экран — то есть
    # параллелизм платит наглядностью. Ветки пишут в журнал, а рисует доску один поток.
    $quiet = $script:GraphCtx -and $script:GraphCtx.Quiet
    if (-not $quiet -and -not ($Detail -and $script:GraphCtx -and $script:GraphCtx.Board)) {
        Write-Host $line -ForegroundColor DarkCyan
    }
    if ($script:GraphCtx) {
        try { Add-Content -LiteralPath (Join-Path $script:GraphCtx.Root '.bcf\loop.log') -Value $line -Encoding UTF8 } catch { }
        _GraphJournal @{ event = 'log'; phase = $script:GraphCtx.Phase; message = $Message }
    }
}

function Set-Phase {
    param([Parameter(Mandatory, Position = 0)][string]$Title)
    if ($script:GraphCtx.Board) { Show-GraphBoard -Final }   # закрепить кадр прошлой фазы
    $script:GraphCtx.Phase = $Title
    _GraphJournal @{ event = 'phase'; phase = $Title }
    Write-Host ""
    Write-Host "  ── фаза: $Title " -ForegroundColor Cyan
    # Доска рисуется НИЖЕ баннера: якорь кадра сбрасываем, иначе следующая перерисовка
    # затрёт заголовок фазы.
    $script:GraphCtx.BoardRow = $null
    $script:GraphCtx.BoardLines = 0
}

# Потрачено токенов за прогон — считается по журналу, поэтому одинаково видно
# из любой ветки и переживает возобновление.
function Get-GraphSpent {
    if (-not $script:GraphCtx -or -not (Test-Path $script:GraphCtx.Journal)) { return 0 }
    $sum = 0
    foreach ($line in (Get-Content -LiteralPath $script:GraphCtx.Journal -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '"event":"node-finish"') { continue }
        try { $rec = $line | ConvertFrom-Json } catch { continue }
        if ($rec.tokens) { $sum += [double]$rec.tokens }
    }
    return $sum
}

function Get-GraphRemaining {
    if (-not $script:GraphCtx.BudgetTotal -or $script:GraphCtx.BudgetTotal -le 0) { return [double]::PositiveInfinity }
    return [Math]::Max(0, $script:GraphCtx.BudgetTotal - (Get-GraphSpent))
}

function _GraphNodeCount {
    if (-not (Test-Path $script:GraphCtx.Journal)) { return 0 }
    return @(Select-String -LiteralPath $script:GraphCtx.Journal -Pattern '"event":"node-start"' -ErrorAction SilentlyContinue).Count
}

# ---------------------------------------------------------------------------
# Живая доска прогона
# ---------------------------------------------------------------------------
#
# ЗАЧЕМ. Веер из восьми узлов, каждый из которых пишет в консоль сам, даёт ленту, где
# ничего не найти: строки разных узлов чередуются, а долгие узлы просто молчат по десять
# минут, и экран выглядит зависшим. Наглядность тут не украшение — по ней принимается
# решение «идёт нормально или пора останавливать», а оно стоит денег.
#
# УСТРОЙСТВО. Источник истины — журнал, а не переменные в памяти: он один на все ветки и
# переживает возобновление. Ветки в консоль не пишут вовсе (Quiet), рисует один поток —
# тот, что ждёт веер. Доска перерисовывается на месте по позиции курсора; если вывод
# перенаправлен (запуск из другого агента, редирект в файл), позиционирование недоступно —
# тогда честно переключаемся на обычные строки, а не рисуем мусор из escape-последовательностей.

function _GraphBoardSupported {
    if ($env:BCF_GRAPH_NO_BOARD) { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        [void][Console]::CursorTop
        return $true
    } catch { return $false }
}

# Имя файла узла. Кириллицу СОХРАНЯЕМ: прежний набор [^A-Za-z0-9_.-] выбрасывал её
# целиком, и «работа-TASK-06» превращалось в «______-TASK-06». Метки здесь русские,
# поэтому два узла одинаковой длины давали ОДНО имя файла — писали бы в него вперемешку,
# а доска показывала бы активность соседа. Хвост-хэш закрывает остаток коллизий.
function _GraphSafeName([string]$Label) {
    $s = $Label -replace '[^\p{L}\p{Nd}_.-]', '_'
    if ($s.Length -gt 48) { $s = $s.Substring(0, 48) }
    $h = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Label))).Replace('-', '').Substring(0, 6)
    return "$s~$h"
}
function _GraphFmtDur([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    # ОТБРАСЫВАТЬ, а не округлять: [int] в PowerShell округляет, и 59.7 с превращались
    # в «60», а 15.99 мин — в «16», давая на доске невозможное время вида 15:60.
    return '{0:00}:{1:00}' -f [int][Math]::Floor($sec / 60), [int][Math]::Floor($sec % 60)
}

function _GraphFmtTok([double]$t) {
    if ($t -ge 1000) { return "$([Math]::Round($t / 1000, 1))k" }
    return "$([int]$t)"
}

# Состояние узлов из журнала: старт → финиш. Возвращает список в порядке появления.
# Чем узел занят ПРЯМО СЕЙЧАС и сколько молчит.
#
# Без этого доска отвечает только на «жив ли процесс», а нужен ответ на «работает ли он».
# Разница видна на узле работы: внутри идёт loop.ps1 со своими итерациями и вызовами
# инструментов, но снаружи это выглядело как строка с тикающим временем — неотличимо от
# зависания. Тишина здесь важнее самой активности: растущий счётчик тишины — единственный
# честный признак того, что пора вмешаться.
function _GraphNodeActivity {
    param($Node)
    $ctx = $script:GraphCtx
    if (-not $Node.Out) { return @{ Text = ''; Silent = -1 } }
    $dir = Join-Path $ctx.Dir 'nodes'
    if (-not (Test-Path $dir)) { return @{ Text = ''; Silent = -1 } }

    # Имя файла зависит от вида узла и (у агентского) от номера попытки — берём свежайший.
    $file = Get-ChildItem $dir -Filter "$($Node.Out)*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.prompt.txt' -and $_.Name -notlike '*.err.*' } |
            Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $file) { return @{ Text = ''; Silent = -1 } }

    # Длину берём ИЗ ПОТОКА, а не из Get-ChildItem.
    #
    # Windows не обновляет метаданные каталога для файла, который держит открытым другой
    # процесс: на живом прогоне `Get-ChildItem` показывал 0 байт у файла, где уже лежали
    # килобайты лога. Считая тишину по этой длине, доска объявляла бы молчащим любой
    # работающий узел — то есть врала бы ровно в том, ради чего её и делали.
    $tail = ''
    $realLen = 0
    try {
        $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        $realLen = $fs.Length
        $take = [int][Math]::Min(8192, $realLen)
        if ($take -gt 0) {
            [void]$fs.Seek(-$take, 'End')
            $buf = New-Object byte[] $take
            [void]$fs.Read($buf, 0, $take)
            $tail = [System.Text.Encoding]::UTF8.GetString($buf)
        }
        $fs.Close()
    } catch { return @{ Text = ''; Silent = -1 } }

    # Тишина = сколько файл не рос. Состояние держим между кадрами в контексте.
    if (-not $ctx.Activity) { $ctx.Activity = @{} }
    $st = $ctx.Activity[$Node.Out]
    $now = Get-Date
    if (-not $st -or $st.Len -ne $realLen) {
        $st = @{ Len = $realLen; Since = $now }
        $ctx.Activity[$Node.Out] = $st
    }
    $silent = [int]($now - $st.Since).TotalSeconds

    $lines = @($tail -split "`r?`n" | Where-Object { $_.Trim() })
    if (-not $lines.Count) { return @{ Text = ''; Silent = $silent } }

    # Командный узел (loop.ps1 и прочее). Просто «последняя строка» не годится: в конце
    # чаще всего лежит ХВОСТ РЕЗУЛЬТАТА, а не действие — на живом прогоне это выглядело
    # как «↳ 94 lines :: <path>…\STATE.json</path>», то есть узел якобы занят выводом
    # длиной 94 строки. Ищем последнее ДЕЙСТВИЕ, а результаты пропускаем.
    if ($Node.Kind -eq 'command') {
        $clean = {
            param($s)
            $s = $s -replace '^\[[\d:\-\. ]+\]\s*', ''      # отметка времени
            $s = $s -replace '<[^>]{1,40}>', ''             # псевдо-теги вида <path>…</path>
            $s = $s -replace '\s+', ' '
            return $s.Trim()
        }
        # Строки-результаты («↳ exit=0», «↳ 94 lines») описывают прошлое, а не текущее.
        $acts = @($lines | Where-Object { $_.Trim() -and $_ -notmatch '(^|\s)↳' })
        if (-not $acts.Count) { $acts = @($lines | Where-Object { $_.Trim() }) }
        $last = & $clean $acts[-1]
        if ($last.Length -gt 90) { $last = $last.Substring(0, 89) + '…' }
        return @{ Text = $last; Silent = $silent }
    }

    # Агентский узел. Решает ПОСЛЕДНЕЕ осмысленное событие — оно и описывает текущее
    # занятие. Слова-заглушки («рассуждает», «ждёт») сюда не годятся: они отвечают на
    # вопрос «жив ли узел», на который уже отвечает таймер, и не отвечают на «чем занят».
    # Текст рассуждения в потоке есть — он приходит дельтами, которые надо склеить.
    $think = New-Object System.Collections.ArrayList
    for ($i = $lines.Count - 1; $i -ge 0 -and $i -ge $lines.Count - 120; $i--) {
        $ev = $null
        try { $ev = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $t = [string]$ev.type

        # Конкретное действие всегда важнее размышления о нём.
        if ($t -eq 'tool_use') {                                   # opencode
            $tool = [string]$ev.part.tool
            $inp = $ev.part.state.input
            $hint = ''
            foreach ($p in @('description', 'filePath', 'file_path', 'path', 'pattern', 'command')) {
                if ($inp -and $inp.PSObject.Properties[$p]) { $hint = [string]$inp.$p; break }
            }
            if ($think.Count) { break }                            # рассуждение свежее — покажем его
            return @{ Text = "$tool $hint".Trim(); Silent = $silent }
        }
        if ($t -eq 'item.completed' -and $ev.item) {               # codex
            $it = [string]$ev.item.type
            if ($it -eq 'command_execution') { if ($think.Count) { break }; return @{ Text = "$([string]$ev.item.command)"; Silent = $silent } }
            if ($it -eq 'file_change')       { if ($think.Count) { break }; return @{ Text = 'правит файлы'; Silent = $silent } }
            if ($it -eq 'reasoning' -and $ev.item.text) { [void]$think.Insert(0, [string]$ev.item.text) }
        }
        if ($t -eq 'assistant' -and $ev.message.content) {         # claude
            foreach ($cc in @($ev.message.content)) {
                if ([string]$cc.type -eq 'tool_use') { if ($think.Count) { break }; return @{ Text = [string]$cc.name; Silent = $silent } }
                if ([string]$cc.type -eq 'thinking' -and $cc.thinking) { [void]$think.Insert(0, [string]$cc.thinking) }
            }
        }
        # cursor/opencode: рассуждение стримится дельтами по несколько слов — сами по себе
        # они бессмысленны («TASK-06 на семантические»), смысл появляется после склейки.
        if (($t -eq 'thinking' -or $t -eq 'reasoning') -and $ev.text) { [void]$think.Insert(0, [string]$ev.text) }

        if ($think.Count -and (($think -join '').Length -ge 400)) { break }
    }

    if ($think.Count) {
        $s = ($think -join '') -replace '\s+', ' '
        $s = $s.Trim()
        # Показываем ХВОСТ: там то, о чём модель думает сейчас, а не с чего начала.
        if ($s.Length -gt 72) {
            $s = $s.Substring($s.Length - 72)
            $sp = $s.IndexOf(' ')
            if ($sp -gt 0 -and $sp -lt 20) { $s = $s.Substring($sp + 1) }   # не рвать слово
            $s = '…' + $s
        }
        return @{ Text = $s; Silent = $silent }
    }
    return @{ Text = ''; Silent = $silent }
}

function Get-GraphBoardState {
    $ctx = $script:GraphCtx
    if (-not $ctx -or -not (Test-Path $ctx.Journal)) { return @() }
    $nodes = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $ctx.Journal -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '"event":"node-') { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        $k = [string]$r.key
        if (-not $k) { continue }
        if ($r.event -eq 'node-start') {
            if (-not $nodes.Contains($k)) {
                $nodes[$k] = [pscustomobject]@{
                    Label = [string]$r.label; Phase = [string]$r.phase; Role = [string]$r.role
                    Backend = [string]$r.backend; Started = [datetime]$r.ts
                    State = 'run'; Tokens = 0; Reason = ''; Finished = $null
                    Out = [string]$r.out; Kind = [string]$r.kind
                }
            }
        } elseif ($r.event -eq 'node-finish' -and $nodes.Contains($k)) {
            $n = $nodes[$k]
            $n.State = if ($r.ok) { if ($r.cached) { 'cache' } else { 'ok' } } else { 'fail' }
            $n.Tokens = [double]$r.tokens
            $n.Reason = [string]$r.reason
            $n.Finished = [datetime]$r.ts
        }
    }
    return @($nodes.Values)
}

# Сборка кадра отделена от вывода: те же строки нужны и для живой перерисовки, и для
# разбора завершённого прогона, где никакого курсора уже нет.
function Get-GraphBoardLines {
    param([switch]$Final)
    $ctx = $script:GraphCtx
    $nodes = Get-GraphBoardState
    $now = Get-Date
    $lines = @()

    $elapsed = _GraphFmtDur (($now - $ctx.StartedAt).TotalSeconds)
    $totTok = ($nodes | Measure-Object -Property Tokens -Sum).Sum
    $fails = @($nodes | Where-Object { $_.State -eq 'fail' }).Count
    $running = @($nodes | Where-Object { $_.State -eq 'run' }).Count

    $lines += @{ t = "  ГРАФ $($ctx.Meta.name) · $elapsed · узлов $($nodes.Count) · $(_GraphFmtTok $totTok) ток.$(if ($fails) { " · ошибок $fails" })"; c = 'Cyan' }
    $lines += @{ t = "  " + ('─' * 66); c = 'DarkGray' }

    # Группируем по фазам в порядке появления; свёрнутые фазы — одной строкой.
    $phases = @($nodes | ForEach-Object { $_.Phase } | Select-Object -Unique)
    foreach ($ph in $phases) {
        $pn = @($nodes | Where-Object { $_.Phase -eq $ph })
        $done = @($pn | Where-Object { $_.State -ne 'run' }).Count
        $pTok = ($pn | Measure-Object -Property Tokens -Sum).Sum
        $act = @($pn | Where-Object { $_.State -eq 'run' }).Count
        $mark = if ($act) { '⏳' } elseif (@($pn | Where-Object { $_.State -eq 'fail' }).Count) { '▲' } else { '✓' }
        $lines += @{ t = ("  {0} {1,-24} {2}/{3}   {4} ток." -f $mark, $ph, $done, $pn.Count, (_GraphFmtTok $pTok)); c = $(if ($act) { 'White' } else { 'DarkGray' }) }

        # Разворачиваем только незавершённую фазу и только её узлы: законченные фазы
        # экран не занимают — иначе доска уезжает вниз и снова становится лентой.
        if (-not $act -and -not $Final) { continue }
        foreach ($n in $pn) {
            if ($n.State -eq 'ok' -and -not $act) { continue }
            $dur = if ($n.Finished) { ($n.Finished - $n.Started).TotalSeconds } else { ($now - $n.Started).TotalSeconds }
            switch ($n.State) {
                'run'   { $sym = @('|','/','-','\')[$ctx.Pulse % 4]; $col = 'Yellow';   $tail = '' }
                'ok'    { $sym = '✓'; $col = 'Green';    $tail = "  $(_GraphFmtTok $n.Tokens)" }
                'cache' { $sym = '≡'; $col = 'DarkCyan'; $tail = '  из кэша' }
                default { $sym = '✗'; $col = 'Red';      $tail = "  $($n.Reason)" }
            }
            $label = if ($n.Label.Length -gt 30) { $n.Label.Substring(0, 29) + '…' } else { $n.Label }
            $t = "      {0} {1,-30} {2,-9} {3}{4}" -f $sym, $label, $n.Role, (_GraphFmtDur $dur), $tail
            if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }
            $lines += @{ t = $t; c = $col }

            # Строка активности — только у идущих узлов. Тишина дольше минуты
            # подсвечивается: именно она отличает «долго думает» от «встало».
            if ($n.State -eq 'run') {
                $act = _GraphNodeActivity $n
                if ($act.Text) {
                    $what = $act.Text
                    if ($what.Length -gt 74) { $what = $what.Substring(0, 73) + '…' }
                    $lines += @{ t = ("          → {0}" -f $what); c = 'DarkGray' }
                }
                # Тишина показывается ТОЛЬКО когда она уже о чём-то говорит.
                #
                # «тишина 1с» под каждым узлом — чистый шум: она отвечает на вопрос
                # «жив ли узел», на который уже отвечает таймер рядом. Смысл появляется
                # с порога, за которым молчание перестаёт быть нормальной паузой между
                # ответами модели, — и тогда это надо не сообщать, а показывать заметно.
                if ($act.Silent -ge 60) {
                    $lvl = if ($act.Silent -ge 300) { 'Red' } else { 'Yellow' }
                    $lines += @{ t = ("          ⚠ МОЛЧИТ {0} — возможно, встал" -f (_GraphFmtDur $act.Silent)); c = $lvl }
                    # Звук — ОДИН раз на узел при переходе порога. Повторять нельзя:
                    # сигнал, звучащий каждые полсекунды, перестаёт быть сигналом, и его
                    # начинают игнорировать вместе с настоящими.
                    if (-not $ctx.Alerted) { $ctx.Alerted = @{} }
                    if (-not $ctx.Alerted[$n.Label]) {
                        $ctx.Alerted[$n.Label] = $true
                        try { [console]::beep(660, 200); Start-Sleep -Milliseconds 80; [console]::beep(440, 320) } catch { }
                    }
                }
            }
        }
    }
    if ($running) { $lines += @{ t = "  " + ('─' * 66); c = 'DarkGray' } }
    return @($lines)
}

function Show-GraphBoard {
    param([switch]$Final)
    $ctx = $script:GraphCtx
    if (-not $ctx -or -not $ctx.Board) { return }
    $ctx.Pulse = [int]$ctx.Pulse + 1
    $lines = @(Get-GraphBoardLines -Final:$Final)

    # Перерисовка на месте: возвращаем курсор к началу доски и затираем прошлый кадр.
    try {
        if ($null -ne $ctx.BoardRow) {
            [Console]::SetCursorPosition(0, [Math]::Max(0, [int]$ctx.BoardRow))
        } else {
            $ctx.BoardRow = [Console]::CursorTop
        }
        $w = [Math]::Max(40, [Console]::WindowWidth - 1)
        foreach ($l in $lines) {
            $txt = [string]$l.t
            if ($txt.Length -gt $w) { $txt = $txt.Substring(0, $w) }
            Write-Host ($txt.PadRight($w)) -ForegroundColor $l.c
        }
        # Затираем хвост прошлого, более длинного кадра.
        for ($i = $lines.Count; $i -lt [int]$ctx.BoardLines; $i++) { Write-Host (' ' * $w) }
        $ctx.BoardLines = $lines.Count
        if ($Final) { $ctx.BoardRow = $null; $ctx.BoardLines = 0 }
    } catch {
        $ctx.Board = $false   # консоль не даёт позиционирования — дальше обычные строки
    }
}

# ---------------------------------------------------------------------------
# Схема ответа (подмножество JSON Schema) — узел со схемой обязан вернуть объект
# ---------------------------------------------------------------------------

# Из ответа модели достаём первый сбалансированный JSON-блок: модели любят обрамлять
# результат прозой и ```-заборами, и наивный ConvertFrom-Json на этом падает.
function _GraphExtractJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $fence = [regex]::Match($t, '(?s)```(?:json)?\s*(.+?)```')
    if ($fence.Success) { $t = $fence.Groups[1].Value.Trim() }

    foreach ($pair in @(@('{', '}'), @('[', ']'))) {
        $open = $pair[0]; $close = $pair[1]
        $start = $t.IndexOf($open)
        if ($start -lt 0) { continue }
        $depth = 0; $inStr = $false; $esc = $false
        for ($i = $start; $i -lt $t.Length; $i++) {
            $ch = $t[$i]
            if ($esc) { $esc = $false; continue }
            if ($ch -eq '\') { $esc = $true; continue }
            if ($ch -eq '"') { $inStr = -not $inStr; continue }
            if ($inStr) { continue }
            if ($ch -eq $open) { $depth++ }
            elseif ($ch -eq $close) {
                $depth--
                if ($depth -eq 0) {
                    $chunk = $t.Substring($start, $i - $start + 1)
                    try { return ($chunk | ConvertFrom-Json -ErrorAction Stop) } catch { break }
                }
            }
        }
    }
    return $null
}

function Test-GraphSchema {
    param($Value, [hashtable]$Schema, [string]$Path = '$')

    # ВНИМАНИЕ на `,@(…)` во всех return ниже. PowerShell разворачивает массив из
    # одного элемента в сам элемент, и список с ОДНОЙ ошибкой возвращался строкой:
    # `.Count` при этом равен 1 (похоже на правду), а `$errs[0]` даёт первый СИМВОЛ
    # вместо первой ошибки. Запятая гасит разворачивание.
    $errors = @()
    if (-not $Schema) { return , $errors }

    $type = [string]$Schema['type']

    # МАССИВ ОПОЗНАЁТСЯ НОРМАЛИЗАЦИЕЙ, А НЕ ПРОВЕРКОЙ ТИПА.
    #
    # PowerShell при связывании параметров разворачивает массивы: `@()` приезжает как
    # `$null`, а `@($x)` — как сам `$x`. Поэтому проверка «это массив?» здесь врала
    # дважды, и обе лжи смертельны для графа поиска:
    #   · `{"findings":[]}` — «ожидался array, получен null». А «ничего не нашёл» —
    #     самый частый и совершенно штатный ответ искателя.
    #   · `{"findings":[одна]}` — «ожидался array, получен PSCustomObject». Список из
    #     одной находки не менее нормален, чем из трёх.
    # В обоих случаях узел трижды переспрашивался и падал, то есть на боевом прогоне
    # искатели умирали бы ровно тогда, когда отрабатывали правильно.
    #
    # Отсутствие ключа ловится отдельно, через `required`, поэтому здесь можно
    # спокойно приводить что угодно к списку и проверять уже его элементы.
    if ($type -eq 'array') {
        $items = if ($null -eq $Value) { @() } else { @($Value) }
        if ($Schema['items']) {
            $idx = 0
            foreach ($item in $items) {
                $errors += Test-GraphSchema -Value $item -Schema $Schema['items'] -Path "$Path[$idx]"
                $idx++
            }
        }
        return , @($errors)
    }

    if ($type) {
        $ok = switch ($type) {
            'object'  { $Value -is [pscustomobject] -or $Value -is [hashtable] }
            'array'   { $Value -is [array] -or $Value -is [System.Collections.IList] }
            'string'  { $Value -is [string] }
            'number'  { $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] }
            'integer' { $Value -is [int] -or $Value -is [long] }
            'boolean' { $Value -is [bool] }
            default   { $true }
        }
        if (-not $ok) {
            $got = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
            return , @("$Path — ожидался тип '$type', получен '$got'")
        }
    }

    if ($Schema['enum']) {
        if (@($Schema['enum']) -notcontains $Value) {
            $errors += "$Path — значение '$Value' вне enum: $(@($Schema['enum']) -join ', ')"
        }
    }

    if ($type -eq 'object') {
        $names = @()
        if ($Value -is [hashtable]) { $names = @($Value.Keys) }
        elseif ($Value -is [pscustomobject]) { $names = @($Value.PSObject.Properties.Name) }

        foreach ($req in @($Schema['required'])) {
            if (-not $req) { continue }
            if ($names -notcontains $req) { $errors += "$Path — отсутствует обязательное поле '$req'" }
        }
        $props = $Schema['properties']

        # additionalProperties: false — контракт узла закрытый. Без этого узел может
        # доложить в ответ что угодно сверх схемы, и оно молча поедет по ребру дальше:
        # следующий узел построит на этом поведение, которого контракт не обещал.
        if ($props -and $Schema.ContainsKey('additionalProperties') -and $Schema['additionalProperties'] -eq $false) {
            $extra = @($names | Where-Object { @($props.Keys) -notcontains $_ })
            if ($extra.Count) { $errors += "$Path — поля вне схемы: $($extra -join ', ')" }
        }
        if ($props) {
            foreach ($k in @($props.Keys)) {
                if ($names -notcontains $k) { continue }
                $child = if ($Value -is [hashtable]) { $Value[$k] } else { $Value.$k }
                $errors += Test-GraphSchema -Value $child -Schema $props[$k] -Path "$Path.$k"
            }
        }
    }
    return , @($errors)
}

function _GraphSchemaPrompt {
    param([hashtable]$Schema)
    $json = ($Schema | ConvertTo-Json -Depth 12)
    return @"

===== ФОРМАТ ОТВЕТА (обязателен) =====
Верни РОВНО ОДИН JSON-объект по схеме ниже. Без пояснений до и после, без ``` -забора.
Ответ, не разобравшийся по схеме, будет отвергнут, и узел переспросит.

$json
"@
}

# ---------------------------------------------------------------------------
# Исполнитель узла: запуск агента бэкенда
# ---------------------------------------------------------------------------

function _GraphRunAgent {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$WorkDir,
        [int]$TimeoutSec,
        [int]$SilentSec,
        [string]$CommandTpl = '',
        [string]$Format = 'opencode',
        [string[]]$RequiredEnv = @(),
        # Имя файлов вывода. Передаётся ЯВНО, потому что вычислять его здесь второй раз
        # нельзя: вызывающий записал в журнал имя от базовой метки («приёмка-гейты»), а
        # сюда приходит метка с номером попытки («приёмка-гейты-a1») — хэш выходит другой,
        # маска не совпадает, и доска не находит файл. Внешне это выглядело как «узел
        # молчит»: у критиков не было строки активности вообще.
        [string]$FileBase = ''
    )

    $ctx = $script:GraphCtx

    # ТЕСТОВЫЙ ШОВ. Подменять исполнителя изнутри процесса нельзя: параллельные ветки
    # поднимают рантайм в чистом runspace заново, и всякая правка функции там теряется.
    # Переменная окружения границу runspace переживает — поэтому шов именно такой.
    # Файл обязан определять Get-FakeAgentReply -Prompt -Label → @{ Text; Tokens; Fail }.
    if ($env:BCF_GRAPH_FAKE_AGENT) {
        . $env:BCF_GRAPH_FAKE_AGENT
        $fake = Get-FakeAgentReply -Prompt $Prompt -Label $Label
        if ($fake.Fail) { return @{ Ok = $false; Text = ''; Tokens = 0; Reason = [string]$fake.Fail } }
        return @{ Ok = $true; Text = [string]$fake.Text; Tokens = [double]$fake.Tokens; Reason = '' }
    }

    $safe = if ($FileBase) { $FileBase } else { _GraphSafeName $Label }
    $dir  = Join-Path $ctx.Dir 'nodes'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $pf = Join-Path $dir "$safe.prompt.txt"
    $of = Join-Path $dir "$safe.out.jsonl"
    $ef = Join-Path $dir "$safe.err.log"
    Set-Content -LiteralPath $pf -Value $Prompt -Encoding UTF8
    Remove-Item $of, $ef -ErrorAction SilentlyContinue

    # Слот песочницы обязателен: opencode держит состояние в ОДНОЙ глобальной SQLite,
    # и два параллельных узла без разного XDG_DATA_HOME убивают друг друга за 3 секунды,
    # отдавая вместо результата текст ошибки. Ждём слот, а не запускаемся без него.
    $lease = $null
    $waited = 0
    while (-not $lease) {
        $lease = Acquire-AgentSlot
        if ($lease) { break }
        Start-Sleep -Seconds 3
        $waited += 3
        if ($waited -ge 600) { return @{ Ok = $false; Text = ''; Tokens = 0; Reason = 'нет свободного слота агента 600с' } }
    }

    try {
        $tpl = if ($CommandTpl) { $CommandTpl } else { $ctx.AgentCmdTpl }
        if ($Model) { $cmd = $tpl -replace '\{model\}', $Model }
        else        { $cmd = ((($tpl -replace '(--model|-m)\s+\{model\}', '')) -replace '\{model\}', '').Trim() -replace '\s{2,}', ' ' }

        $utf8 = "[Console]::InputEncoding=[Text.Encoding]::UTF8;[Console]::OutputEncoding=[Text.Encoding]::UTF8;`$OutputEncoding=[Text.Encoding]::UTF8;"
        $envs = "`$env:XDG_DATA_HOME='$($lease.Path)';`$env:LANG='C.UTF-8';"
        foreach ($name in @($RequiredEnv)) {
            if (-not $name) { continue }
            $val = [Environment]::GetEnvironmentVariable($name)
            if (-not $val) { $val = [Environment]::GetEnvironmentVariable($name, 'User') }
            if (-not $val) { $val = [Environment]::GetEnvironmentVariable($name, 'Machine') }
            if ($val) { $envs += "`$env:$name='$($val -replace "'", "''")';" }
        }
        # Команда бэкенда может уже начинаться с оператора вызова — так записывают путь
        # к бинарю, которого нет в PATH (`& 'C:/…/codex.exe' exec …`). Свой `&` сверху
        # даёт `& &` и ошибку разбора ещё до запуска модели.
        $invoke = if ($cmd -match '^\s*&') { $cmd } else { "& $cmd" }
        $inner = "$utf8$envs `$p = Get-Content -Raw -LiteralPath '$pf'; $invoke `$p"

        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $inner) `
            -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $of -RedirectStandardError $ef
        Register-FleetWorker -Id "graph-$safe" -Role 'graph' -Task $Label -Model $Model -ProcessId $proc.Id -Detail "узел графа"

        $started = (Get-Date).ToUniversalTime()
        $lastLen = 0
        $lastGrow = $started
        $reason = ''
        while (-not $proc.WaitForExit(3000)) {
            $elapsed = [int]((Get-Date).ToUniversalTime() - $started).TotalSeconds
            $len = if (Test-Path $of) { (Get-Item $of -ErrorAction SilentlyContinue).Length } else { 0 }
            if ($len -gt $lastLen) { $lastLen = $len; $lastGrow = (Get-Date).ToUniversalTime() }
            $silent = [int]((Get-Date).ToUniversalTime() - $lastGrow).TotalSeconds

            if ($elapsed -ge $TimeoutSec) {
                $reason = "таймаут узла ${TimeoutSec}с"
                try { $proc.Kill($true) } catch { }
                $proc.WaitForExit(5000) | Out-Null
                break
            }
            # Зависший SSE-стрим модели — штатное поведение потокового API, а не
            # зависшая команда. Без этой ветки узел досиживает до общего таймаута,
            # сжигая минуты мёртвого эфира и получая ложную атрибуцию «таймаут».
            if ($SilentSec -gt 0 -and $silent -ge $SilentSec) {
                $reason = "стрим молчит ${silent}с — зависший поток модели"
                try { $proc.Kill($true) } catch { }
                $proc.WaitForExit(5000) | Out-Null
                break
            }
            Update-FleetHeartbeat -Id "graph-$safe" -Detail "${elapsed}с, тишина ${silent}с"
        }

        # Разбор потока событий бэкенда: у каждой CLI своя схема (см. ConvertFrom-AgentStream).
        $lines = @()
        if (Test-Path $of) { $lines = @(Get-Content -LiteralPath $of -Encoding UTF8 -ErrorAction SilentlyContinue) }
        $parsed = ConvertFrom-AgentStream -Lines $lines -Format $Format
        $out = $parsed.Text
        $tokens = $parsed.Tokens
        # Бэкенд может отчитаться о собственной ошибке (нет авторизации, отказ модели)
        # штатным событием и КОДОМ 0. Без этой ветки такой ответ выглядел бы как успех.
        if ($parsed.Failed -and -not $reason) { $reason = "бэкенд отказал: $($parsed.Failed)" }
        if (-not $out -and -not $reason) {
            # Пустой ответ при нулевом коде — это молча умерший агент (чаще всего
            # гонка за состоянием или отказ провайдера). Считать это успехом нельзя.
            $errTail = if (Test-Path $ef) { (Get-Content -LiteralPath $ef -Tail 5 -ErrorAction SilentlyContinue) -join ' ' } else { '' }
            $reason = "агент не вернул текста" + $(if ($errTail) { ": $errTail" } else { '' })
        }
        return @{ Ok = (-not $reason); Text = $out; Tokens = $tokens; Reason = $reason }
    }
    finally {
        Unregister-FleetWorker -Id "graph-$safe"
        Release-AgentSlot $lease
    }
}

# ---------------------------------------------------------------------------
# Invoke-Node — узел графа
# ---------------------------------------------------------------------------

# Стоит ли пробовать ЗАПАСНУЮ модель после этого отказа.
#
# Не всякий провал лечится сменой модели, и переключаться на всё подряд нельзя: если узел
# падает на схеме ответа, вторая модель упадёт на ней же, а бюджет будет потрачен дважды.
# Запасная нужна там, где отказал ПРОВАЙДЕР, а не задача:
#
#   · 429 / исчерпан лимит плана — модель физически недоступна ближайшее время;
#   · поток завис и был снят по тишине — у этого провайдера сейчас плохо со стримом;
#   · авторизация отвалилась на ходу — CLI больше не может ходить в эту модель;
#   · пустой ответ при нулевом коде — молча умерший агент.
#
# Цена отказа от запасной измерима: узел падает, волна встаёт и ждёт рук, а на слиянии
# worktree остаётся заклеймлённым и следующие задачи не берут те же файлы.
function Test-BcfFallbackWorthy {
    param([string]$Reason)
    if (-not $Reason) { return $false }
    return [bool]($Reason -match '(?i)429|rate.?limit|лимит|quota|усталь|overload|' +
                                 'стрим молчит|зависш|timeout|таймаут|' +
                                 'auth|авториз|unauthor|forbidden|403|401|' +
                                 'не вернул текста|бэкенд отказал')
}

function Invoke-Node {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Prompt,
        [string]$Label = '',
        [string]$Phase = '',
        [hashtable]$Schema = $null,
        [string]$Model = '',
        # Роль решает, каким классом модели считать узел. Экономика роя: рамочные
        # решения стоят дорого и их мало, исполнение стоит дёшево и его много —
        # смешивать их на одной модели значит платить планировочную цену за каждый
        # токен исполнения.
        [ValidateSet('worker', 'planner', 'critic', 'arbiter')][string]$Role = 'worker',
        [int]$TimeoutSec = 0,
        [int]$MaxRetries = 2,
        [string]$Worktree = '',
        [string]$WorkDir = '',
        # Подмешать в промпт уроки из памяти по СОДЕРЖИМОМУ этого узла. Отзыв по реальному
        # тексту — принципиальное отличие от цикла, где запрос строился из шаблона
        # «TASK-NN iteration N» и потому всегда возвращал одно и то же.
        [switch]$Recall,
        [string]$RecallScope = 'code'
    )

    $ctx = $script:GraphCtx
    if (-not $ctx) { throw "Invoke-Node вызван до Initialize-GraphRun" }

    $phase = if ($Phase) { $Phase } else { $ctx.Phase }
    $label = if ($Label) { $Label } else { "$phase-узел" }
    $safeBase = _GraphSafeName $label
    $rt = Resolve-GraphRole -Role $Role -ModelOverride $Model
    $Model = $rt.Model

    $full = if ($Schema) { $Prompt + (_GraphSchemaPrompt $Schema) } else { $Prompt }

    # Уроки подмешиваются ДО вычисления ключа узла — иначе изменившаяся память не
    # инвалидировала бы кэш возобновления, и узел переигрался бы со старым контекстом.
    if ($Recall -and -not $ctx.DryPlan -and (Get-Command Get-GraphRecall -ErrorAction SilentlyContinue)) {
        # Память — вспомогательная подсистема, а не условие работы узла. Её недоступность
        # обязана быть ГРОМКОЙ (иначе обучение тихо мертво), но НЕ блокирующей: узел без
        # уроков работает хуже, узел, не запустившийся вовсе, не работает никак.
        $lessons = ''
        try { $lessons = Get-GraphRecall -Text $Prompt -Scope $RecallScope -IterationId "$($ctx.RunId)-$label" }
        catch { $lessons = '' }
        if ($lessons) {
            $full = $lessons + "`n" + $full
            Write-GraphLog -Detail "· $label — подмешано уроков из памяти"
        } elseif (-not (Test-GraphMemory)) {
            Write-GraphLog "! память недоступна — узлы идут без уроков (docker compose -f memory/pgvector/docker-compose.yml up -d)"
        }
    }

    # Ключ по содержимому — основа возобновления. Счётчик повторов позволяет
    # запускать несколько ОДИНАКОВЫХ узлов (три скептика на одну находку) и всё
    # равно закэшировать каждого.
    $sha = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("$phase|$label|$full"))).Replace('-', '').Substring(0, 16)

    $mtx = $null
    $occ = 0
    try {
        $mtx = New-Object System.Threading.Mutex($false, $ctx.MutexName + '-occ')
        [void]$mtx.WaitOne(15000)
        $counterFile = Join-Path $ctx.Dir 'occ.json'
        $counts = @{}
        if (Test-Path $counterFile) {
            try { (Get-Content -Raw -LiteralPath $counterFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $counts[$_.Name] = [int]$_.Value } } catch { }
        }
        $occ = [int]$counts[$sha]
        $counts[$sha] = $occ + 1
        ($counts | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $counterFile -Encoding UTF8
    } catch { } finally {
        if ($mtx) { try { $mtx.ReleaseMutex() } catch { }; $mtx.Dispose() }
    }
    $key = "$sha#$occ"

    # 1. Кэш возобновления.
    if ($ctx.Cache.ContainsKey($key)) {
        $hit = $ctx.Cache[$key]
        Write-GraphLog -Detail "· $label — из кэша возобновления"
        _GraphJournal @{ event = 'node-finish'; key = $key; label = $label; phase = $phase; ok = $true
                         cached = $true; tokens = 0; result = $hit.result }
        if ($Schema) { return (_GraphExtractJson ([string]$hit.result)) }
        return [string]$hit.result
    }

    # 2. Потолки. Оба — предохранители от разогнавшегося скрипта, а не режим работы:
    #    молча урезать охват хуже, чем остановиться, поэтому оба случая громкие.
    if ((_GraphNodeCount) -ge $ctx.MaxNodes) {
        throw "граф упёрся в потолок узлов ($($ctx.MaxNodes)) — вероятен разогнавшийся цикл"
    }
    if ($ctx.BudgetTotal -gt 0 -and (Get-GraphRemaining) -le 0) {
        throw "бюджет графа ($($ctx.BudgetTotal) токенов) исчерпан на узле '$label'"
    }

    # 3. Сухой план: ничего не запускаем, только фиксируем намерение.
    #
    # ВНИМАНИЕ вызывающему графу: этот no-op спасает только от ВЫЗОВА агента. Всё, что
    # граф делает ДО Invoke-Node — создание worktree, заявки на файлы, правки в дереве —
    # он обязан пропускать сам, проверив $script:GraphCtx.DryPlan. Для таких мест есть
    # Write-GraphNodePlan: строка в плане без единого побочного эффекта.
    if ($ctx.DryPlan) {
        Write-Host ("    · {0,-30} фаза={1,-12} роль={2,-8} {3} / {4}" -f $label, $phase, $Role, $rt.Backend, ($(if ($Model) { $Model } else { '(дефолт)' }))) -ForegroundColor DarkGray
        _GraphJournal @{ event = 'node-start'; key = $key; label = $label; phase = $phase; role = $Role; model = $Model; dry = $true }
        _GraphJournal @{ event = 'node-finish'; key = $key; label = $label; phase = $phase; ok = $true; dry = $true; tokens = 0; result = '' }
        if ($Schema) { return $null }
        return ''
    }

    $timeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { [int]$ctx.NodeTimeoutSec }

    # Изоляция узла в своём рабочем дереве — только когда узлы правят файлы
    # параллельно. Это дорого (создание worktree + диск), поэтому не по умолчанию.
    $work = if ($WorkDir) { $WorkDir } else { $ctx.Root }
    if ($Worktree) {
        $wt = New-TaskWorktree -Root $ctx.Root -Task $Worktree
        if ($wt) { $work = $wt } else { Write-GraphLog "! $label — worktree '$Worktree' не создан, узел идёт в основном дереве" }
    }

    _GraphJournal @{ event = 'node-start'; key = $key; label = $label; phase = $phase; role = $Role
                     backend = $rt.Backend; model = $Model; workdir = $work
                     out = $safeBase; kind = 'agent' }
    Write-GraphLog -Detail "→ $label ($Role → $($rt.Backend)$(if ($Model) { " / $Model" }))"

    $attempt = 0
    $promptNow = $full
    $lastReason = ''
    $useFb = $false          # текущая попытка идёт на запасной модели
    $fbUsed = $false         # запасная уже включалась в этом узле
    while ($attempt -le $MaxRetries) {
        $attempt++
        $cur = if ($useFb -and $rt.Fallback) { $rt.Fallback } else { $rt }
        $curModel = if ($useFb -and $rt.Fallback) { $rt.Fallback.Model } else { $Model }
        $res = _GraphRunAgent -Prompt $promptNow -Model $curModel -Label "$label-a$attempt" `
                              -WorkDir $work -TimeoutSec $timeout -SilentSec ([int]$ctx.SilentSec) `
                              -CommandTpl $cur.Command -Format $cur.Format -RequiredEnv $cur.Env -FileBase "$safeBase-a$attempt"

        if (-not $res.Ok) {
            $lastReason = $res.Reason
            Write-GraphLog "! $label — попытка $attempt не удалась: $($res.Reason)"

            # ЗАПАСНАЯ — на отказ провайдера, а не на отказ задачи. И ровно один раз:
            # бесконечное перебирание моделей превращает потолок повторов в фикцию.
            if (-not $fbUsed -and $rt.Fallback -and (Test-BcfFallbackWorthy $res.Reason)) {
                $useFb = $true
                $fbUsed = $true
                _GraphJournal @{ event = 'node-fallback'; key = $key; label = $label; phase = $phase
                                 from = "$($rt.Backend)/$Model"; to = "$($rt.Fallback.Backend)/$($rt.Fallback.Model)"
                                 reason = $res.Reason }
                Write-GraphLog "  ↻ $label — перехожу на запасную: $($rt.Fallback.Backend) / $($rt.Fallback.Model)"
            }
            continue
        }

        if (-not $Schema) {
            _GraphJournal @{ event = 'node-finish'; key = $key; label = $label; phase = $phase; ok = $true
                             tokens = $res.Tokens; attempts = $attempt; result = $res.Text }
            Write-GraphLog -Detail "✓ $label ($([int]$res.Tokens) ток.)"
            return $res.Text
        }

        # Валидация структурного ответа. Ошибка схемы — не провал узла, а повод
        # переспросить С ТЕКСТОМ ОШИБКИ: модель почти всегда чинит формат со второго раза.
        $obj = _GraphExtractJson $res.Text
        $errs = if ($null -eq $obj) { @('ответ не содержит разбираемого JSON') } else { Test-GraphSchema -Value $obj -Schema $Schema }
        if (-not $errs.Count) {
            _GraphJournal @{ event = 'node-finish'; key = $key; label = $label; phase = $phase; ok = $true
                             tokens = $res.Tokens; attempts = $attempt; result = ($obj | ConvertTo-Json -Depth 12 -Compress) }
            Write-GraphLog -Detail "✓ $label ($([int]$res.Tokens) ток., схема ок)"
            return $obj
        }
        $lastReason = "схема: $($errs -join '; ')"
        Write-GraphLog "! $label — попытка $attempt не прошла схему: $($errs[0])"
        $promptNow = $full + "`n`n===== ПРЕДЫДУЩИЙ ОТВЕТ ОТВЕРГНУТ =====`n" + ($errs -join "`n") + "`nВерни исправленный JSON целиком."
    }

    _GraphJournal @{ event = 'node-finish'; key = $key; label = $label; phase = $phase; ok = $false
                     tokens = 0; attempts = $attempt; reason = $lastReason }
    Write-GraphLog "✗ $label — узел не дал результата за $attempt попыт.: $lastReason"
    return $null
}

# ---------------------------------------------------------------------------
# Детерминированные узлы и взаимное исключение
# ---------------------------------------------------------------------------

# Узел-команда: тот же журнал, тот же кэш возобновления, но исполняет процесс, а не модель.
#
# Граф, у которого узлами могут быть ТОЛЬКО модели, — это не граф, а веер: половина
# реальной работы (сборка, тесты, git, готовая петля задачи) детерминирована, и гонять
# её через модель значит платить за угадывание того, что и так вычислимо. Правило то же,
# что и везде: предсказуемая маршрутизация — кодом, интерпретация — моделью.
function Invoke-CommandNode {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Command,
        [Parameter(Mandatory)][string]$Label,
        [string]$Phase = '',
        [string]$WorkDir = '',
        [int]$TimeoutSec = 0,
        [int[]]$OkExitCodes = @(0)
    )
    $ctx = $script:GraphCtx
    if (-not $ctx) { throw "Invoke-CommandNode вызван до Initialize-GraphRun" }
    $phase = if ($Phase) { $Phase } else { $ctx.Phase }
    $work  = if ($WorkDir) { $WorkDir } else { $ctx.Root }

    $sha = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("cmd|$phase|$Label|$Command|$work"))).Replace('-', '').Substring(0, 16)
    $key = "cmd:$sha"

    if ($ctx.Cache.ContainsKey($key)) {
        Write-GraphLog "· $Label — из кэша возобновления (команда)"
        _GraphJournal @{ event = 'node-finish'; key = $key; label = $Label; phase = $phase; ok = $true; cached = $true; tokens = 0; result = $ctx.Cache[$key].result }
        return @{ Ok = $true; ExitCode = 0; Output = [string]$ctx.Cache[$key].result; Cached = $true }
    }

    if ($ctx.DryPlan) {
        Write-Host ("    · {0,-34} фаза={1,-14} КОМАНДА  {2}" -f $Label, $phase, $Command) -ForegroundColor DarkGray
        _GraphJournal @{ event = 'node-start'; key = $key; label = $Label; phase = $phase; kind = 'command'; dry = $true; command = $Command }
        _GraphJournal @{ event = 'node-finish'; key = $key; label = $Label; phase = $phase; ok = $true; dry = $true; tokens = 0; result = '' }
        return @{ Ok = $true; ExitCode = 0; Output = ''; Dry = $true }
    }

    _GraphJournal @{ event = 'node-start'; key = $key; label = $Label; phase = $phase; kind = 'command'; command = $Command; workdir = $work; out = (_GraphSafeName $Label) }
    Write-GraphLog "→ $Label (команда)"

    $safe = _GraphSafeName $Label
    $dir = Join-Path $ctx.Dir 'nodes'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $of = Join-Path $dir "$safe.cmd.out.txt"
    $ef = Join-Path $dir "$safe.cmd.err.txt"

    $timeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { [int]$ctx.NodeTimeoutSec }
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Command) `
        -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput $of -RedirectStandardError $ef
    if (-not $proc.WaitForExit($timeout * 1000)) {
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit(5000) | Out-Null
        _GraphJournal @{ event = 'node-finish'; key = $key; label = $Label; phase = $phase; ok = $false; tokens = 0; reason = "таймаут ${timeout}с" }
        Write-GraphLog "✗ $Label — таймаут ${timeout}с"
        return @{ Ok = $false; ExitCode = -1; Output = ''; Reason = "таймаут ${timeout}с" }
    }
    $code = $proc.ExitCode
    $out = if (Test-Path $of) { (Get-Content -LiteralPath $of -Raw -ErrorAction SilentlyContinue) } else { '' }
    $ok = ($OkExitCodes -contains $code)
    _GraphJournal @{ event = 'node-finish'; key = $key; label = $Label; phase = $phase; ok = $ok; tokens = 0; exit = $code
                     result = $(if ($ok) { [string]$out } else { '' }) }
    Write-GraphLog "$(if ($ok) { '✓' } else { '✗' }) $Label (код $code)"
    return @{ Ok = $ok; ExitCode = $code; Output = [string]$out }
}

# Критическая секция на весь граф, включая параллельные ветки в чужих runspace.
# Нужна там, где ресурс физически один: основное рабочее дерево git. Два одновременных
# слияния в него — это не «медленнее», это испорченное дерево.
function Invoke-WithGraphLock {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Body,
        [int]$TimeoutSec = 1800
    )
    $mtx = New-Object System.Threading.Mutex($false, "Global\bcf-graph-lock-$Name")
    $held = $false
    try {
        $held = $mtx.WaitOne($TimeoutSec * 1000)
        if (-not $held) { throw "не дождался блокировки '$Name' за ${TimeoutSec}с" }
        return & $Body
    } finally {
        if ($held) { try { $mtx.ReleaseMutex() } catch { } }
        $mtx.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Параллельные комбинаторы
# ---------------------------------------------------------------------------

# Общий движок: каждый элемент проходит СВОЙ конвейер стадий в отдельном потоке.
# Между стадиями барьера нет — это и есть разница между Invoke-Pipeline и Invoke-Barrier.
function _GraphParallelMap {
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock[]]$Stages,
        [int]$Throttle
    )
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    if ($Items.Count -gt 4096) { throw "в один Invoke-Pipeline/Invoke-Barrier передано $($Items.Count) элементов (потолок 4096)" }

    $ctxPlain = $script:GraphCtx.Clone()
    # Ветки молчат в консоль ТОЛЬКО когда есть доска: их показывает она. Без доски
    # (вывод перенаправлен — запуск из другого агента, CI, редирект в файл) молчание
    # означало бы полную потерю сообщений веера, то есть самый широкий кусок прогона
    # исчезал бы из лога ровно там, где он нужнее всего.
    $ctxPlain.Quiet = $script:GraphCtx.Board
    $ctxPlain.Board = $false
    $runtime  = $script:GraphCtx.RuntimePath
    $stageSrc = @($Stages | ForEach-Object { $_.ToString() })
    $libDir   = Split-Path $runtime -Parent

    # Порядок результатов сохраняем явно: задача отдаёт их в порядке ЗАВЕРШЕНИЯ, а
    # вызывающий код вправе рассчитывать на соответствие входному списку.
    $wrapped = @(0..($Items.Count - 1) | ForEach-Object { @{ i = $_; item = $Items[$_] } })

    # Один поток на элемент, стадии внутри потока — последовательно. Отсюда и
    # семантика конвейера: элемент A может быть на третьей стадии, пока B на первой.
    $job = $wrapped | ForEach-Object -ThrottleLimit $Throttle -AsJob -Parallel {
        $idx  = $_.i
        $item = $_.item
        # Чужой runspace пуст: ни функций, ни модулей. Поднимаем рантайм заново и
        # возвращаем ему контекст — состояние прогона живёт в файлах, поэтому это дёшево.
        . (Join-Path $using:libDir 'agent-sandbox.ps1')
        . (Join-Path $using:libDir 'fleet.ps1')
        . (Join-Path $using:libDir 'claims.ps1')
        . (Join-Path $using:libDir 'worktree.ps1')
        . (Join-Path $using:libDir 'graph-memory.ps1')
        . $using:runtime
        Import-GraphContext $using:ctxPlain

        $val = $item
        try {
            $idx = 0
            foreach ($src in $using:stageSrc) {
                $sb = [scriptblock]::Create($src)
                $val = & $sb $val $item $idx
                $idx++
            }
        } catch {
            # Упавшая стадия роняет ОДИН элемент в $null, а не весь веер: потеря
            # одной ветки не повод обнулять остальные.
            Write-GraphLog "✗ ветка упала: $($_.Exception.Message)"
            $val = $null
        }
        [pscustomobject]@{ __i = $idx; __v = $val }
    }

    # Пока ветки работают — перерисовываем доску. Это и есть смысл -AsJob: при
    # синхронном ForEach-Object -Parallel главный поток заблокирован, и экран стоит
    # мёртвым ровно столько, сколько идёт самый долгий узел.
    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        Show-GraphBoard
        Start-Sleep -Milliseconds 700
    }
    $raw = @(Receive-Job $job -Wait -ErrorAction SilentlyContinue)
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Show-GraphBoard

    $ordered = @($raw | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains '__i') } | Sort-Object __i)
    return @($ordered | ForEach-Object { $_.__v })
}

# Invoke-Pipeline — по умолчанию. Каждый элемент течёт по стадиям сам.
# Стадия получает ($prev, $item, $stageIndex).
function Invoke-Pipeline {
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock[]]$Stages,
        [int]$Throttle = 0
    )
    $t = if ($Throttle -gt 0) { $Throttle } else { [int]$script:GraphCtx.MaxConcurrency }
    Write-GraphLog "конвейер: $($Items.Count) элем. × $($Stages.Count) стад., до $t одновременно"
    return _GraphParallelMap -Items $Items -Stages $Stages -Throttle $t
}

# Invoke-Barrier — БАРЬЕР. Использовать только если следующему шагу нужен
# перекрёстный контекст всех веток разом.
function Invoke-Barrier {
    param(
        [Parameter(Mandatory)][scriptblock[]]$Thunks,
        [int]$Throttle = 0
    )
    $t = if ($Throttle -gt 0) { $Throttle } else { [int]$script:GraphCtx.MaxConcurrency }
    Write-GraphLog "барьер: $($Thunks.Count) ветк., до $t одновременно"
    $srcs = @($Thunks | ForEach-Object { $_.ToString() })
    # Элемент = исходник ветки; единственная стадия просто исполняет его.
    return _GraphParallelMap -Items $srcs -Stages @({ param($v) & ([scriptblock]::Create($v)) }) -Throttle $t
}

# Строка сухого плана для шага, у которого есть побочные эффекты ВНЕ узла.
#
# Нужна потому, что «пропустить в сухом режиме» и «показать, что было бы» — разные
# вещи, и без второго сухой план перестаёт быть планом: он молчит ровно про те шаги,
# которые дороже всего (создание рабочих деревьев, заявки на файлы, слияния).
function Write-GraphNodePlan {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Phase = '',
        [string]$Detail = ''
    )
    if (-not $script:GraphCtx) { return }
    $ph = if ($Phase) { $Phase } else { $script:GraphCtx.Phase }
    Write-Host ("    · {0,-34} фаза={1,-14} ПЛАН     {2}" -f $Label, $ph, $Detail) -ForegroundColor DarkGray
    _GraphJournal @{ event = 'node-start';  key = "plan:$Label"; label = $Label; phase = $ph; dry = $true; kind = 'plan' }
    _GraphJournal @{ event = 'node-finish'; key = "plan:$Label"; label = $Label; phase = $ph; ok = $true; dry = $true; tokens = 0; result = $Detail }
}

function Complete-GraphRun {
    param($Result = $null)
    $spent = Get-GraphSpent
    _GraphJournal @{ event = 'run-finish'; runId = $script:GraphCtx.RunId; tokens = $spent
                     result = $(if ($null -ne $Result) { ($Result | ConvertTo-Json -Depth 8 -Compress) } else { '' }) }
    Write-GraphLog "граф завершён: узлов $(_GraphNodeCount), токенов $([int]$spent), журнал — .bcf/graph/$($script:GraphCtx.RunId)/journal.jsonl"
    return $Result
}






