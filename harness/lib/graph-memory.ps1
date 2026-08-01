# graph-memory.ps1 — постоянная память графа: отзыв уроков в узел и запись новых.
#
# ЧТО БЫЛО НЕ ТАК В ЦИКЛЕ (замеры на прогоне 2026-07-26, 14 задач, ~10 часов):
#
#   anti_patterns = 1,  bugs = 0,  recall_events = 57
#
# То есть механизм жил, но выучил ЕДИНСТВЕННУЮ заметку и потом 57 раз перечитывал её же.
# Две причины, обе молчаливые:
#
#   1. ЗАПРОС БЫЛ ПУСТОЙ. `Inject-AntiPatterns` собирал текст запроса как
#      "$TaskId iteration $N" плюс содержимое `tasks/$TaskId.md` — файла с таким именем
#      не существует (реальные зовутся `TASK-06-pointermap.md`), поэтому брифа в запросе
#      не было НИКОГДА. Поиск по строке «TASK-06 iteration 3» естественно возвращал одно
#      и то же независимо от того, чем задача занималась.
#   2. ПИСАТЬ БЫЛО НЕКОМУ. Уроки писал только ретроспектор после вердикта, а вердиктов
#      почти не было — 12 задач из 14 не дошли до конца. Провалы, то есть самый ценный
#      материал для обучения, не записывались вообще.
#
# ЧТО ЗДЕСЬ ИНАЧЕ.
#
#   · Отзыв идёт по РЕАЛЬНОМУ тексту узла (его промпту), а не по строке-заглушке.
#   · Пишут не только успехи: провал узла, провал задачи и подтверждённая находка
#     критика — все становятся уроками. Граф даёт типизированные сигналы, которых у
#     цикла не было в принципе: он знал только «итерация не удалась».
#   · Перед записью — ДЕДУП. `upsert_entry` в memory_client делает голый INSERT без
#     ON CONFLICT: цикл писал так мало, что дубли не проявлялись, а граф пишет на
#     порядок больше, и без дедупа таблица за пару прогонов превратится в шум,
#     где каждый отзыв возвращает пять переформулировок одной мысли.

Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
# Клиент памяти — часть фабрики, а не проекта: одна установка pgvector обслуживает все
# проекты, и разводить по копии клиента на проект незачем.
$script:GMemRoot   = Get-BcfHomeRoot
$script:GMemClient = Join-Path $script:GMemRoot 'memory/pgvector/memory_client.py'
$script:GMemState  = $null    # $null = ещё не проверяли; $true/$false = результат
$script:GMemNextProbe = $null # когда можно пробовать снова после отрицательного ответа

# Похожесть, выше которой урок считается уже известным. 0.92 — намеренно высокий порог:
# ложный пропуск (не записали похожее) дешевле ложного дубля, потому что дубль портит
# ВСЕ будущие отзывы, а пропуск теряет один урок.
$script:GMemDedupThreshold = 0.92

# ВСЯКИЙ вызов памяти ограничен по времени.
#
# Память — вспомогательная подсистема: без уроков узел работает хуже, но работает. Без
# таймаута она превращается в жёсткую зависимость, и её недоступность останавливает весь
# граф. Наблюдалось живьём 2026-07-31: Docker не был запущен, `memory_client.py recall`
# висел на подключении к pgvector, отзыв вызывался ДО журналирования узла — и прогон замер
# на «барьер: 3 ветк.» без единого node-start, снаружи выглядя как «граф молчит».
# Отдельно коварно то, что сам ПРОБНИК доступности висел точно так же.
function _GMemPython {
    param([string[]]$MemArgs, [int]$TimeoutSec = 25, [string]$StdIn = '')

    $out = Join-Path $env:TEMP ("gmem-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.out')
    $err = "$out.err"
    $inF = ''

    # UTF-8 ОБЯЗАТЕЛЕН, и это не про красоту вывода.
    #
    # python читает stdin в кодировке локали (на этой машине cp1251), а PowerShell пишет
    # файл в UTF-8. Байты UTF-8, прочитанные как cp1251, дают «Р—Р°РґР°С‡Р°» вместо
    # «Задача» — и урок ложится в базу в таком виде НАВСЕГДА. Дальше хуже: эмбеддинг
    # считается от этой абракадабры, поэтому отзыв по ней не находит ничего осмысленного,
    # а то, что всё-таки находится, попадает агенту в контекст нечитаемым.
    # Проверено живьём: все шесть уроков первого прогона легли двойной кодировкой.
    $env:PYTHONIOENCODING = 'utf-8'

    try {
        # Аргументы с пробелами ОБЯЗАНЫ быть в кавычках: Start-Process отдаёт их через
        # командную строку Windows и сам не экранирует. Без этого `--text проверка
        # доступности памяти` уезжает тремя аргументами, python падает на разборе за
        # доли секунды, stdout пуст — и снаружи это неотличимо от «память недоступна».
        # Именно так рефакторинг таймаута молча отключил память целиком: текст запроса
        # всегда содержит пробелы.
        $quoted = @($script:GMemClient) + @($MemArgs | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        })
        $psi = @{
            FilePath = 'python'; ArgumentList = $quoted
            NoNewWindow = $true; PassThru = $true
            RedirectStandardOutput = $out; RedirectStandardError = $err
        }
        if ($StdIn) {
            $inF = "$out.in"
            Set-Content -LiteralPath $inF -Value $StdIn -Encoding UTF8
            $psi['RedirectStandardInput'] = $inF
        }
        $p = Start-Process @psi
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            return $null            # $null = не ответила вовремя, считаем недоступной
        }
        # Ненулевой код — отказ клиента (плохие аргументы, недоступная БД). Считать его
        # «пустым ответом» нельзя: пустой ответ у recall валиден и означает «не нашлось».
        if ($p.ExitCode -ne 0) {
            $e = if (Test-Path $err) { (Get-Content -Raw -LiteralPath $err -EA SilentlyContinue) } else { '' }
            Write-Verbose "memory_client вышел с кодом $($p.ExitCode): $e"
            return $null
        }
        # Get-Content -Raw на ПУСТОМ файле возвращает $null, а не пустую строку — это
        # смешало бы «ничего не нашлось» с «клиент не ответил». Приводим явно.
        $txt = if (Test-Path $out) { Get-Content -Raw -LiteralPath $out -EA SilentlyContinue } else { '' }
        if ($null -eq $txt) { $txt = '' }
        return $txt
    } catch { return $null }
    finally {
        # Пустой путь (stdin не использовался) роняет Remove-Item — отсеиваем.
        foreach ($f in @($out, $err, $inF)) {
            if ($f) { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
        }
    }
}

function Test-GraphMemory {
    param([switch]$Recheck)

    # КЭШИРУЕМ ТОЛЬКО «ДА». Раньше кэшировался любой ответ, и один медленный первый
    # пробник выключал память на весь прогон. Выглядело это так: префлайт честно
    # доложил «pgvector healthy, эмбеддинги загружены, обучение АКТИВНО», а через восемь
    # секунд граф напечатал «память недоступна» — и дальше все узлы шли без уроков,
    # хотя память работала. «Не ответила за 8 секунд» и «недоступна» — разные вещи, и
    # склеивать их нельзя: первое лечится повтором, второе нет.
    if ($script:GMemState -eq $true) { return $true }
    if ($env:BCF_MEMORY_DISABLED) { return $false }
    if (-not (Test-Path $script:GMemClient)) { return $false }

    # Отрицательный ответ придерживаем на минуту: пробник зовётся на КАЖДОМ узле, и
    # долбить недоступную базу по разу на узел — это минуты мёртвого времени на прогон.
    if (-not $Recheck -and $script:GMemNextProbe -and (Get-Date) -lt $script:GMemNextProbe) { return $false }

    # Пробуем ДЕШЁВОЙ командой: stats ходит в базу и не считает эмбеддинг. Прежний
    # пробник делал recall, то есть round-trip к модели, и первый же вызов на холодной
    # модели не укладывался в отведённые восемь секунд.
    $probe = _GMemPython -MemArgs @('stats') -TimeoutSec 10
    $ok = $false
    if ($null -ne $probe -and $probe -notmatch 'Traceback|OperationalError|could not connect') { $ok = $true }

    if ($ok) {
        $script:GMemState = $true
        $script:GMemNextProbe = $null
        return $true
    }
    $script:GMemState = $false
    $script:GMemNextProbe = (Get-Date).AddSeconds(60)
    return $false
}

# Блок уроков для вставки в промпт узла. Пусто, если памяти нет или совпадений нет —
# вызывающий просто ничего не добавляет.
function Get-GraphRecall {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Scope = 'code',
        [int]$TopK = 5,
        [double]$Threshold = 0.35,
        [string]$IterationId = ''
    )
    if (-not (Test-GraphMemory)) { return '' }
    # Обрезаем запрос: у эмбеддера всё равно ограниченное окно, а длинный промпт
    # размывает запрос — совпадения становятся общими и бесполезными.
    $q = if ($Text.Length -gt 3000) { $Text.Substring(0, 3000) } else { $Text }

    $a = @('recall', '--text', $q, '--scope', $Scope, '--k', "$TopK", '--threshold', "$Threshold")
    if ($IterationId) { $a += @('--iteration-id', $IterationId) }
    $json = _GMemPython -MemArgs $a -TimeoutSec 25
    if (-not $json) { return '' }
    try { $hits = @($json | ConvertFrom-Json) } catch { return '' }
    if (-not $hits -or $hits.Count -eq 0) { return '' }

    $lines = @()
    $lines += ''
    $lines += "===== УЖЕ НАСТУПАЛИ НА ЭТИ ГРАБЛИ ($($hits.Count)) ====="
    $lines += "Заметки из памяти харнесса по похожим задачам. Не повторяй; применяй позитивную форму."
    foreach ($h in $hits) {
        $sim = [Math]::Round([double]$h.similarity, 2)
        $lines += "- [$sim] $($h.trigger_summary)"
        if ($h.what_went_wrong)     { $lines += "    что пошло не так: $($h.what_went_wrong)" }
        if ($h.correct_alternative) { $lines += "    как надо:         $($h.correct_alternative)" }
    }
    $lines += ''
    return ($lines -join "`n")
}

# Записать урок. Возвращает 'new' | 'dup' | 'off' | 'err'.
function Add-GraphLesson {
    param(
        [Parameter(Mandatory)][string]$Trigger,        # когда это случается (по нему ищут)
        [Parameter(Mandatory)][string]$WentWrong,      # что именно пошло не так
        [string]$Alternative = '',                     # как надо — позитивная форма
        [string]$Scope = 'code',
        [hashtable]$Evidence = @{}
    )
    if (-not (Test-GraphMemory)) { return 'off' }
    if ([string]::IsNullOrWhiteSpace($Trigger)) { return 'err' }

    # СУХОЙ ПЛАН НЕ ПИШЕТ УРОКОВ. Наблюдалось живьём: `bcf run queue --dry-plan` на свежей
    # базе записал шесть «уроков» вида «задача не закрылась: сухой план: узел не
    # исполнялся». Во-первых, режим обещает не создавать НИЧЕГО. Во-вторых, это отравление
    # обучения: выдуманные провалы потом отзываются в настоящие прогоны как прошлый опыт,
    # и агент получает в контекст утверждение о поломке, которой не было.
    if ($script:GraphCtx -and $script:GraphCtx.DryPlan) { return 'dry' }

    # Дедуп: ищем почти-совпадение ДО записи.
    $near = _GMemPython -MemArgs @('recall', '--text', $Trigger, '--scope', $Scope,
                                   '--k', '1', '--threshold', "$script:GMemDedupThreshold") -TimeoutSec 20
    if ($near) {
        try {
            $n = @($near | ConvertFrom-Json)
            if ($n.Count -gt 0) { return 'dup' }
        } catch { }
    }

    $entry = @{
        agent_scope         = $Scope
        trigger_summary     = $Trigger
        what_went_wrong     = $WentWrong
        correct_alternative = $(if ($Alternative) { $Alternative } else { $null })
        evidence            = $Evidence
    }
    $payload = ($entry | ConvertTo-Json -Depth 8 -Compress)
    $out = _GMemPython -MemArgs @('upsert') -StdIn $payload -TimeoutSec 25
    if ($null -eq $out) { return 'err' }
    if ($out -match 'Traceback|Error') { return 'err' }
    return 'new'
}

# Сводка состояния памяти: используется в приёмке прогона. Признак живого обучения —
# не строка «память доступна», а РОСТ чисел от прогона к прогону.
function Get-GraphMemoryStats {
    if (-not (Test-GraphMemory)) { return $null }
    # Конфиг ищем ТАМ ЖЕ, где клиент: проект, потом фабрика. Прежний путь
    # (<фабрика>/config/memory.config.json) не существует вовсе — функция всегда возвращала
    # $null, то есть приёмка прогона молча оставалась без сводки по памяти.
    $cfgFile = ''
    foreach ($c in @(
        $env:BCF_MEM_CONFIG,
        (Join-Path (Get-BcfProjectRoot) 'config\memory.config.json'),
        (Join-Path $script:GMemRoot 'memory\memory.config.json')
    )) {
        if ($c -and (Test-Path $c)) { $cfgFile = $c; break }
    }
    if (-not $cfgFile) { return $null }
    try {
        $cfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
        $sql = "select (select count(*) from agent_memory.anti_patterns) || '|' || (select count(*) from agent_memory.bugs) || '|' || (select count(*) from agent_memory.recall_events);"
        $raw = & docker exec $cfg.container psql -U $cfg.user -d $cfg.database -t -A -c $sql 2>$null
        $parts = ("$raw".Trim() -split '\|')
        if ($parts.Count -lt 3) { return $null }
        return @{ AntiPatterns = [int]$parts[0]; Bugs = [int]$parts[1]; Recalls = [int]$parts[2] }
    } catch { return $null }
}

