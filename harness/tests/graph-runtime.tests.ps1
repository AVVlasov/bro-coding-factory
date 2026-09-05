# graph-runtime.tests.ps1 — проверка движка графа БЕЗ единого обращения к модели.
#
#   pwsh harness/tests/graph-runtime.tests.ps1
#
# Исполнитель узла подменяется через BCF_GRAPH_FAKE_AGENT, поэтому тесты гоняют
# настоящий рантайм — настоящие потоки, настоящий журнал, настоящее возобновление —
# и при этом идут за секунды и ничего не стоят.
#
# Главное, что здесь доказывается, — семантика конвейера. «Конвейер быстрее барьера»
# легко объявить в комментарии и невозможно проверить чтением кода: разница видна
# только по времени на несимметричных ветках. Тест 6 её и меряет.

$ErrorActionPreference = 'Continue'
$root    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$libDir  = Join-Path $root 'harness\lib'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

. (Join-Path $libDir 'agent-sandbox.ps1')
. (Join-Path $libDir 'fleet.ps1')
. (Join-Path $libDir 'worktree.ps1')
. (Join-Path $libDir 'graph-runtime.ps1')

$script:Pass = 0
$script:Fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $name $(if ($detail) { "— $detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

# Рабочая песочница: свой корень, чтобы журналы тестов не смешивались с боевыми.
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-graph-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $sandbox '.bcf\graph') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sandbox 'config') | Out-Null
'{ "limits": { "agentConcurrency": 8 }, "timeouts": { "stepSec": 60, "silentSec": 30 } }' |
    Set-Content -LiteralPath (Join-Path $sandbox 'config\harness.json') -Encoding UTF8

# --- Фальшивый исполнитель: отвечает по «командам», зашитым в текст промпта ---
$fakeAgent = Join-Path $sandbox 'fake-agent.ps1'
@'
function Get-FakeAgentReply {
    param([string]$Prompt, [string]$Label)

    # SLEEP:<мс> — управляемая длительность узла (нужно тестам про параллелизм).
    $m = [regex]::Match($Prompt, 'SLEEP:(\d+)')
    if ($m.Success) { Start-Sleep -Milliseconds ([int]$m.Groups[1].Value) }

    # TRACE:<файл>|<метка> — отметка «узел отработал», с временем начала и конца.
    $tr = [regex]::Match($Prompt, 'TRACE:([^|]+)\|(\S+)')
    if ($tr.Success) {
        $mtx = New-Object System.Threading.Mutex($false, 'Global\bcf-graph-test-trace')
        [void]$mtx.WaitOne(10000)
        try { Add-Content -LiteralPath $tr.Groups[1].Value -Value ("{0}|{1:o}" -f $tr.Groups[2].Value, (Get-Date)) -Encoding UTF8 }
        finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
    }

    if ($Prompt -match 'FAILNODE') { return @{ Fail = 'фальшивый отказ' } }
    if ($Prompt -match 'THROWSTAGE') { throw 'стадия упала намеренно' }

    # BADSCHEMA — первая попытка отдаёт мусор, вторая (после переспроса) — валидный JSON.
    if ($Prompt -match 'BADSCHEMA') {
        if ($Prompt -match 'ПРЕДЫДУЩИЙ ОТВЕТ ОТВЕРГНУТ') {
            return @{ Text = '{"name":"чинёный","count":7}'; Tokens = 20 }
        }
        return @{ Text = 'конечно! вот результат: name=чинёный'; Tokens = 10 }
    }
    if ($Prompt -match 'FENCED') {
        # Забор собираем из кода: три обратных апострофа в двойных кавычках съедают
        # закрывающую кавычку и рвут разбор самого теста.
        $bt = [string][char]0x60
        $body = 'Готово, держи:' + [Environment]::NewLine +
                ($bt * 3) + 'json' + [Environment]::NewLine +
                '{"name":"в заборе","count":3}' + [Environment]::NewLine +
                ($bt * 3) + [Environment]::NewLine + 'добавлю, что всё хорошо'
        return @{ Text = $body; Tokens = 15 }
    }
    if ($Prompt -match 'SCHEMAOK') { return @{ Text = '{"name":"ровно","count":1}'; Tokens = 12 }; }

    return @{ Text = "ответ узла $Label"; Tokens = 5 }
}
'@ | Set-Content -LiteralPath $fakeAgent -Encoding UTF8
$env:BCF_GRAPH_FAKE_AGENT = $fakeAgent

$objSchema = @{
    type = 'object'; required = @('name', 'count')
    properties = @{ name = @{ type = 'string' }; count = @{ type = 'integer' } }
}

# ---------------------------------------------------------------------------
Section "1. Валидация схемы"
# ---------------------------------------------------------------------------
$e = Test-GraphSchema -Value ([pscustomobject]@{ name = 'a'; count = 2 }) -Schema $objSchema
Check "валидный объект — без ошибок" ($e.Count -eq 0) "получено: $($e -join '; ')"

$e = Test-GraphSchema -Value ([pscustomobject]@{ name = 'a' }) -Schema $objSchema
Check "отсутствие обязательного поля ловится" ($e.Count -eq 1 -and $e[0] -match "count")

$e = Test-GraphSchema -Value ([pscustomobject]@{ name = 5; count = 2 }) -Schema $objSchema
Check "неверный тип поля ловится" ($e.Count -eq 1 -and $e[0] -match 'name')

$nested = @{ type = 'object'; required = @('items')
             properties = @{ items = @{ type = 'array'; items = @{ type = 'object'; required = @('id')
                             properties = @{ id = @{ type = 'string' } } } } } }
$bad = '{"items":[{"id":"ок"},{"nope":1}]}' | ConvertFrom-Json
$e = Test-GraphSchema -Value $bad -Schema $nested
Check "ошибка внутри массива адресуется путём" ($e.Count -eq 1 -and $e[0] -match '\[1\]') "получено: $($e -join '; ')"

$e = Test-GraphSchema -Value 'жёлтый' -Schema @{ type = 'string'; enum = @('красный', 'синий') }
Check "enum ловится" ($e.Count -eq 1)

# Закрытый контракт: узел не имеет права доложить в ответ поля сверх схемы.
$closed = @{ type = 'object'; required = @('name'); additionalProperties = $false
             properties = @{ name = @{ type = 'string' } } }
$e = Test-GraphSchema -Value ([pscustomobject]@{ name = 'a'; лишнее = 1 }) -Schema $closed
Check "additionalProperties:false ловит поле вне схемы" ($e.Count -eq 1 -and $e[0] -match 'лишнее') "получено: $($e -join '; ')"

$e = Test-GraphSchema -Value ([pscustomobject]@{ name = 'a'; лишнее = 1 }) -Schema @{
    type = 'object'; required = @('name'); properties = @{ name = @{ type = 'string' } } }
Check "без additionalProperties контракт открыт (как раньше)" ($e.Count -eq 0)

# Пустой список — штатный ответ узла поиска («ничего не нашёл»), а не нарушение схемы.
# PowerShell схлопывает @() в $null при связывании параметров, из-за чего честный
# {"findings":[]} трижды переспрашивался и ронял узел.
$listSchema = @{ type = 'object'; required = @('findings')
                 properties = @{ findings = @{ type = 'array'; items = @{ type = 'object' } } } }
$e = Test-GraphSchema -Value ('{"findings":[]}' | ConvertFrom-Json) -Schema $listSchema
Check "пустой список проходит схему" ($e.Count -eq 0) "получено: $($e -join '; ')"

$e = Test-GraphSchema -Value ('{"findings":[{"a":1}]}' | ConvertFrom-Json) -Schema $listSchema
Check "непустой список по-прежнему проходит" ($e.Count -eq 0) "получено: $($e -join '; ')"

$e = Test-GraphSchema -Value ('{"nope":1}' | ConvertFrom-Json) -Schema $listSchema
Check "отсутствие ключа ловится по-прежнему" ($e.Count -eq 1 -and $e[0] -match 'findings')

# ---------------------------------------------------------------------------
Section "2. Извлечение JSON из ответа модели"
# ---------------------------------------------------------------------------
$o = _GraphExtractJson 'Вот результат: {"a":1,"b":{"c":2}} — надеюсь, подошло'
Check "JSON из прозы" ($null -ne $o -and $o.b.c -eq 2)

$bt = [string][char]0x60
$fenced = ($bt * 3) + 'json' + "`n" + '{"a":42}' + "`n" + ($bt * 3)
$o = _GraphExtractJson $fenced
Check "JSON из огороженного блока" ($null -ne $o -and $o.a -eq 42)

$o = _GraphExtractJson '{"s":"строка со скобкой } внутри","n":1}'
Check "скобка внутри строки не рвёт разбор" ($null -ne $o -and $o.n -eq 1)

$o = _GraphExtractJson 'тут вообще нет json'
Check "нет JSON → null" ($null -eq $o)

# ---------------------------------------------------------------------------
Section "2б. Разбор потоков разных CLI"
# ---------------------------------------------------------------------------
# Фикстуры сняты с ЖИВОГО вывода (кроме cursor — Free-план не дал завершить прогон).
# Придуманная фикстура тут бесполезна: весь смысл разборщика в том, что схема события
# у каждой CLI своя, и угаданная схема даёт зелёный тест при нерабочем бэкенде.

$ocLines = @(
    '{"type":"text","part":{"text":"первая часть"}}',
    '{"type":"text","part":{"text":"вторая часть"}}',
    '{"type":"step_finish","part":{"tokens":{"total":120}}}'
)
$r = ConvertFrom-AgentStream -Lines $ocLines -Format 'opencode'
Check "opencode: текст склеен, токены сочтены" ($r.Text -match 'первая' -and $r.Text -match 'вторая' -and $r.Tokens -eq 120) "текст='$($r.Text)' ток=$($r.Tokens)"

# Реальный вывод codex exec --json (снят 2026-07-30).
$cxLines = @(
    '{"type":"thread.started","thread_id":"019fb3bc"}',
    '{"type":"turn.started"}',
    '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"PROBE_OK"}}',
    '{"type":"turn.completed","usage":{"input_tokens":14058,"cached_input_tokens":4480,"output_tokens":27}}'
)
$r = ConvertFrom-AgentStream -Lines $cxLines -Format 'codex'
Check "codex: agent_message извлечён" ($r.Text -eq 'PROBE_OK') "получено: '$($r.Text)'"
Check "codex: токены = вход + выход" ($r.Tokens -eq 14085) "получено: $($r.Tokens)"

$r = ConvertFrom-AgentStream -Format 'codex' -Lines @(
    '{"type":"turn.failed","error":{"message":"квота исчерпана"}}')
Check "codex: отказ бэкенда распознан" ($r.Failed -match 'квота')

# Реальный вывод claude -p --output-format stream-json (снят 2026-07-30).
$clLines = @(
    '{"type":"system","subtype":"init","session_id":"996b299c"}',
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"черновик"}]}}',
    '{"type":"result","subtype":"success","is_error":false,"result":"итоговый ответ","usage":{"input_tokens":10,"output_tokens":5}}'
)
$r = ConvertFrom-AgentStream -Lines $clLines -Format 'claude'
Check "claude: итог из result важнее черновика" ($r.Text -eq 'итоговый ответ') "получено: '$($r.Text)'"
Check "claude: токены сочтены" ($r.Tokens -eq 15) "получено: $($r.Tokens)"

# Кэш у claude приходит ОТДЕЛЬНЫМИ полями, и input_tokens его не включает. Пока их не
# складывали, узел с большим системным промптом выглядел одиннадцатитокенным рядом с
# codex-узлом на 16 тысяч — то есть смета и потолок «до исчерпания» были слепы ровно на
# том бэкенде, которым чаще всего работают.
$clCached = @(
    '{"type":"result","subtype":"success","is_error":false,"result":"ок","usage":{"input_tokens":11,"cache_read_input_tokens":14200,"cache_creation_input_tokens":300,"output_tokens":40}}'
)
$r = ConvertFrom-AgentStream -Lines $clCached -Format 'claude'
Check "claude: кэшированный вход входит в расход" ($r.Tokens -eq 14551) "получено: $($r.Tokens)"

# Ровно тот отказ, который CLI выдал на этой машине: код возврата ненулевой, но
# событие штатное — без распознавания это выглядело бы как успешный пустой ответ.
$r = ConvertFrom-AgentStream -Format 'claude' -Lines @(
    '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}')
Check "claude: отсутствие авторизации — это отказ, а не пустой ответ" ($r.Failed -match 'Not logged in' -and -not $r.Text)

# --- Протухший путь к CLI ---------------------------------------------------------------
#
# CLI, живущая внутри установки приложения, лежит по пути с хэшем сборки. После обновления
# каталог другой, а в конфиге остаётся старый: 2026-08-08 все три критика упали с «is not
# recognized as a name of a cmdlet», приёмка не выполнилась, отчёт написал «Находок нет».
$fakeRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-bin-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $fakeRoot 'cfac6bda') | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'cfac6bda\codex.exe') -Value 'x' -Encoding UTF8
$stale = "& '$fakeRoot\68de26ad\codex.exe' exec --json -m {model}"
$fixed = _RepairPinnedBinary $stale 'codex'
Check "протухший путь заменён на существующий" ($fixed -like "*cfac6bda\codex.exe*") "получено: $fixed"
Check "остальная команда не тронута" ($fixed -like '*exec --json -m {model}*')

$live = "& '$fakeRoot\cfac6bda\codex.exe' exec -m {model}"
Check "живой путь не подменяется" ((_RepairPinnedBinary $live 'codex') -eq $live)

$nowhere = "& 'Z:\нет\такого\каталога\codex.exe' exec"
Check "без замены команда остаётся прежней (падать с понятной ошибкой, а не с чужим бинарём)" `
    ((_RepairPinnedBinary $nowhere 'codex') -eq $nowhere)
Remove-Item -Recurse -Force $fakeRoot -ErrorAction SilentlyContinue

# Реальный вывод cursor-agent (снят 2026-07-30, Pro). Расход в camelCase — схема почти
# совпадает с claude, и скопированный snake_case разборщик молча давал ноль: узлы были
# невидимы для бюджета, а выглядело это как «бесплатный бэкенд».
$cuLines = @(
    '{"type":"system","subtype":"init","session_id":"345a89bb"}',
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"черновик"}]}}',
    '{"type":"result","subtype":"success","is_error":false,"result":"PROBE_OK","usage":{"inputTokens":12645,"outputTokens":25,"cacheReadTokens":1408}}'
)
$r = ConvertFrom-AgentStream -Lines $cuLines -Format 'cursor'
Check "cursor: итог извлечён" ($r.Text -eq 'PROBE_OK') "получено: '$($r.Text)'"
Check "cursor: токены сочтены из camelCase" ($r.Tokens -eq 12670) "получено: $($r.Tokens)"

$r = ConvertFrom-AgentStream -Format 'opencode' -Lines @('не json вовсе', '', '{"type":"text","part":{"text":"ок"}}')
Check "мусорные строки не ломают разбор" ($r.Text -eq 'ок')

# ---------------------------------------------------------------------------
Section "2в. Доска прогона (слой данных)"
# ---------------------------------------------------------------------------
# Сам рисунок headless не проверить — он про позиционирование курсора. Проверяем то,
# что определяет его правдивость: состояние узлов, собранное из журнала. Ошибка здесь
# опаснее кривой рамки: доска, показывающая законченным то, что ещё идёт, хуже, чем
# отсутствие доски, — по ней принимают решение «останавливать или нет».

Initialize-GraphRun -Root $sandbox -Meta @{ name = 'board'; description = 'т' } -MaxConcurrency 1 | Out-Null
$script:GraphCtx.Board = $false

_GraphJournal @{ event = 'node-start';  key = 'a#0'; label = 'узел-A'; phase = 'Ф1'; role = 'worker'; backend = 'opencode' }
_GraphJournal @{ event = 'node-finish'; key = 'a#0'; ok = $true; tokens = 1500 }
_GraphJournal @{ event = 'node-start';  key = 'b#0'; label = 'узел-B'; phase = 'Ф1'; role = 'critic'; backend = 'cursor' }
_GraphJournal @{ event = 'node-finish'; key = 'b#0'; ok = $false; tokens = 0; reason = 'схема' }
_GraphJournal @{ event = 'node-start';  key = 'c#0'; label = 'узел-C'; phase = 'Ф2'; role = 'planner'; backend = 'claude' }

$bd = Get-GraphBoardState
Check "доска видит все узлы" (@($bd).Count -eq 3) "получено: $(@($bd).Count)"
Check "завершённый узел помечен ok" ((@($bd | Where-Object { $_.Label -eq 'узел-A' })[0].State) -eq 'ok')
Check "упавший узел помечен fail с причиной" (
    (@($bd | Where-Object { $_.Label -eq 'узел-B' })[0].State) -eq 'fail' -and
    (@($bd | Where-Object { $_.Label -eq 'узел-B' })[0].Reason) -eq 'схема')
Check "НЕзавершённый узел остаётся running" ((@($bd | Where-Object { $_.Label -eq 'узел-C' })[0].State) -eq 'run')
Check "токены сведены по узлам" ((($bd | Measure-Object -Property Tokens -Sum).Sum) -eq 1500)
Check "фазы различаются" (@($bd | Where-Object { $_.Phase -eq 'Ф1' }).Count -eq 2)

# --- Память не имеет права блокировать узел ---
# Память вспомогательна: без уроков узел работает хуже, но работает. Когда она стала
# жёсткой зависимостью без таймаута, недоступный pgvector остановил ВЕСЬ граф — прогон
# замер на барьере без единого node-start (2026-07-31, Docker не был запущен).
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\graph-memory.ps1')
$env:BCF_MEMORY_DISABLED = '1'
$script:GMemState = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rc = Get-GraphRecall -Text 'что угодно' -Scope code
$ls = Add-GraphLesson -Trigger 'проба' -WentWrong 'проба'
$sw.Stop()
$env:BCF_MEMORY_DISABLED = $null
$script:GMemState = $null
Check "при недоступной памяти отзыв возвращает пусто, а не падает" ($rc -eq '')

# АРГУМЕНТЫ С ПРОБЕЛАМИ. Start-Process отдаёт их через командную строку Windows и сам не
# экранирует: `--text проверка доступности памяти` уезжает тремя аргументами, клиент падает
# на разборе за доли секунды, stdout пуст — и снаружи это неотличимо от «память недоступна».
# Так рефакторинг таймаута молча отключил память ЦЕЛИКОМ: текст запроса всегда с пробелами.
$script:GMemState = $null
if (Test-GraphMemory) {
    $one   = _GMemPython -MemArgs @('recall','--text','слово','--scope','code','--k','1','--threshold','0.99') -TimeoutSec 25
    $multi = _GMemPython -MemArgs @('recall','--text','текст из нескольких слов','--scope','code','--k','1','--threshold','0.99') -TimeoutSec 25
    Check "запрос из одного слова доходит до клиента" ($null -ne $one) "получено: $one"
    Check "запрос С ПРОБЕЛАМИ доходит так же" ($null -ne $multi) "получено: $multi"
} else {
    Write-Host "  ПРОПУЩЕН тест экранирования аргументов — память недоступна (docker/LM Studio)" -ForegroundColor DarkYellow
}
$script:GMemState = $null
Check "при недоступной памяти запись отвечает 'off'" ($ls -eq 'off') "получено: '$ls'"
Check "и делает это быстро, не блокируя узел" ($sw.Elapsed.TotalSeconds -lt 5) "заняло $([int]$sw.Elapsed.TotalSeconds)с"

# --- Имя файла узла ---
# Прежний санитайзер [^A-Za-z0-9_.-] выбрасывал кириллицу целиком: «работа-TASK-06»
# становилось «______-TASK-06» (наблюдалось на живом прогоне). Метки здесь русские,
# поэтому два узла одинаковой длины писали бы в ОДИН файл, и доска показывала бы
# активность соседа как свою.
$n1 = _GraphSafeName 'работа-TASK-06'
$n2 = _GraphSafeName 'приёмка-склейка'
$n3 = _GraphSafeName 'приёмка-склеЙка'      # та же длина, отличается одной буквой
Check "имя файла сохраняет кириллицу" ($n1 -match 'работа') "получено: '$n1'"
Check "разные метки — разные имена" ($n2 -ne $n3) "'$n2' vs '$n3'"
Check "одна метка — стабильное имя" ((_GraphSafeName 'работа-TASK-06') -eq $n1)
Check "имя пригодно для файловой системы" ($n1 -notmatch '[\\/:*?"<>|]') "получено: '$n1'"

# ШОВ, который уже ломался живьём. Узел пишет в журнал имя от БАЗОВОЙ метки, а файлы
# создаются с номером попытки. Пока имя передаётся явно, файл начинается с журнального —
# доска его находит. Если кто-то вернёт вычисление имени из метки С суффиксом, хэш станет
# другим, маска перестанет совпадать, и активность молча исчезнет (наблюдалось: у критиков
# не было строки активности вообще, при полностью работающих узлах).
$base = _GraphSafeName 'приёмка-гейты'
Check "файл попытки начинается с журнального имени" ("$base-a1" -like "$base*")
Check "вычислять имя из метки с суффиксом НЕЛЬЗЯ — хэш другой" (
    (_GraphSafeName 'приёмка-гейты-a1') -notlike "$base*") `
    "если это упало — значит имена совпали случайно, и шов снова без защиты"

# --- Активность узла ---
# Строка «чем занят прямо сейчас» — то, ради чего доска вообще нужна: без неё узел
# выглядит как тикающее время, неотличимое от зависания. У каждого бэкенда своя схема
# события, поэтому разбор проверяется на всех: молча не сработавший разбор одного из них
# вернёт пустую строку, и узел снова станет «просто идёт».
$ndir = Join-Path $script:GraphCtx.Dir 'nodes'
New-Item -ItemType Directory -Force -Path $ndir | Out-Null

Set-Content -LiteralPath (Join-Path $ndir 'узел-oc.out.jsonl') -Encoding UTF8 -Value @(
    '{"type":"text","part":{"text":"ок"}}',
    '{"type":"tool_use","part":{"tool":"read","state":{"input":{"filePath":"crates/bgc-core/src/scan.rs"}}}}')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-oc'; Kind = 'agent' })
Check "активность: opencode tool_use" ($a.Text -match 'read' -and $a.Text -match 'scan\.rs') "получено: '$($a.Text)'"

Set-Content -LiteralPath (Join-Path $ndir 'узел-cx.out.jsonl') -Encoding UTF8 -Value @(
    '{"type":"item.completed","item":{"type":"command_execution","command":"cargo check --workspace"}}')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-cx'; Kind = 'agent' })
Check "активность: codex command_execution" ($a.Text -match 'cargo check') "получено: '$($a.Text)'"

Set-Content -LiteralPath (Join-Path $ndir 'узел-cl.out.jsonl') -Encoding UTF8 -Value @(
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-cl'; Kind = 'agent' })
Check "активность: claude/cursor tool_use" ($a.Text -eq 'Edit') "получено: '$($a.Text)'"

Set-Content -LiteralPath (Join-Path $ndir 'узел-cmd.cmd.out.txt') -Encoding UTF8 -Value @(
    '[2026-07-30 20:04:55] [loop] Итерация 3: агент правит scan.rs')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-cmd'; Kind = 'command' })
Check "активность: командный узел берёт последнюю строку" ($a.Text -match 'Итерация 3') "получено: '$($a.Text)'"

# В конце лога чаще всего лежит ХВОСТ РЕЗУЛЬТАТА, а не действие. Наблюдалось живьём:
# «↳ 94 lines :: <path>…STATE.json</path>» — узел якобы занят выводом длиной 94 строки.
Set-Content -LiteralPath (Join-Path $ndir 'узел-res.cmd.out.txt') -Encoding UTF8 -Value @(
    '[20:27:35] → bash  Проверяю сборку  ::  cargo check --workspace',
    '  ↳ 94 lines  ::  <path>.bcf\state\STATE.json</path>')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-res'; Kind = 'command' })
Check "активность: хвост результата пропускается, показывается действие" `
    ($a.Text -match 'cargo check' -and $a.Text -notmatch '94 lines') "получено: '$($a.Text)'"
Check "активность: псевдо-теги вычищены" ($a.Text -notmatch '<path>') "получено: '$($a.Text)'"

$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'нет-такого'; Kind = 'agent' })
Check "активность: отсутствие файла не падает" ($a.Text -eq '' -and $a.Silent -eq -1)

# Рассуждение приходит ДЕЛЬТАМИ по несколько слов: по отдельности они бессмысленны
# («TASK-06 на семантические»), смысл появляется только после склейки в порядке потока.
# Показывать вместо этого слово «рассуждает» — значит отвечать на вопрос «жив ли узел»,
# на который уже отвечает таймер рядом.
Set-Content -LiteralPath (Join-Path $ndir 'узел-th.out.jsonl') -Encoding UTF8 -Value @(
    '{"type":"thinking","subtype":"delta","text":"Проверяю дерево слияния"}',
    '{"type":"thinking","subtype":"delta","text":" TASK-06 на семантические"}',
    '{"type":"thinking","subtype":"delta","text":" грани склейки"}')
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-th'; Kind = 'agent' })
Check "активность: дельты рассуждения склеиваются по порядку" `
    ($a.Text -match 'Проверяю дерево слияния TASK-06 на семантические грани склейки') "получено: '$($a.Text)'"
Check "активность: заглушки «рассуждает» больше нет" ($a.Text -ne 'рассуждает')

# Длинное рассуждение обрезается с ХВОСТА: там то, о чём модель думает сейчас.
$long = (1..40 | ForEach-Object { "{`"type`":`"thinking`",`"text`":`" слово$_`"}" })
Set-Content -LiteralPath (Join-Path $ndir 'узел-long.out.jsonl') -Encoding UTF8 -Value $long
$a = _GraphNodeActivity ([pscustomobject]@{ Out = 'узел-long'; Kind = 'agent' })
Check "активность: длинное рассуждение показывает хвост" `
    ($a.Text -match 'слово40' -and $a.Text.Length -le 80) "длина $($a.Text.Length): '$($a.Text)'"

# Доска не имеет права падать, когда позиционирование недоступно (перенаправленный вывод).
$script:GraphCtx.Board = $true
try { Show-GraphBoard; $boardOk = $true } catch { $boardOk = $false }
Check "рисование не падает при перенаправленном выводе" $boardOk

# ---------------------------------------------------------------------------
Section "3. Одиночный узел и журнал"
# ---------------------------------------------------------------------------
$meta = @{ name = 'test'; description = 'тест'; phases = @(@{ title = 'Фаза1'; detail = '' }) }
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$r = Invoke-Node -Prompt 'обычный узел' -Label 'простой'
Check "узел вернул текст" ($r -match 'ответ узла')

$journal = @(Get-Content -LiteralPath $ctx.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Check "в журнале есть node-start и node-finish" (
    @($journal | Where-Object { $_.event -eq 'node-start' }).Count -eq 1 -and
    @($journal | Where-Object { $_.event -eq 'node-finish' -and $_.ok }).Count -eq 1)
Check "токены посчитаны" ((Get-GraphSpent) -eq 5) "получено: $(Get-GraphSpent)"

$r = Invoke-Node -Prompt 'FAILNODE — этот узел обязан провалиться' -Label 'падучий' -MaxRetries 1
Check "провалившийся узел возвращает null" ($null -eq $r)
Check "провал зафиксирован в журнале" (
    @(Get-Content -LiteralPath $ctx.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } |
      Where-Object { $_.event -eq 'node-finish' -and -not $_.ok }).Count -eq 1)

# ---------------------------------------------------------------------------
Section "4. Структурный ответ и переспрос по схеме"
# ---------------------------------------------------------------------------
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$o = Invoke-Node -Prompt 'SCHEMAOK' -Label 'схема-ок' -Schema $objSchema
Check "узел со схемой вернул объект" ($null -ne $o -and $o.name -eq 'ровно' -and $o.count -eq 1)

$o = Invoke-Node -Prompt 'FENCED' -Label 'схема-забор' -Schema $objSchema
Check "ответ в ```-заборе с прозой принят" ($null -ne $o -and $o.name -eq 'в заборе')

$o = Invoke-Node -Prompt 'BADSCHEMA' -Label 'схема-переспрос' -Schema $objSchema -MaxRetries 2
Check "невалидный ответ переспрошен и починен" ($null -ne $o -and $o.name -eq 'чинёный' -and $o.count -eq 7)
$fin = @(Get-Content -LiteralPath $ctx.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } |
         Where-Object { $_.event -eq 'node-finish' -and $_.label -eq 'схема-переспрос' })
Check "переспрос виден в журнале (attempts=2)" ($fin.Count -eq 1 -and $fin[0].attempts -eq 2) "attempts=$($fin[0].attempts)"

# ---------------------------------------------------------------------------
Section "5. Барьер: ждём все ветки"
# ---------------------------------------------------------------------------
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$trace = Join-Path $sandbox 'barrier.trace'
Remove-Item $trace -ErrorAction SilentlyContinue
Set-GraphVar trace $trace
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$res = Invoke-Barrier -Thunks @(
    { Invoke-Node -Prompt "SLEEP:900 TRACE:$(Get-GraphVar trace)|A" -Label 'ветка-A' },
    { Invoke-Node -Prompt "SLEEP:100 TRACE:$(Get-GraphVar trace)|B" -Label 'ветка-B' },
    { Invoke-Node -Prompt "SLEEP:100 TRACE:$(Get-GraphVar trace)|C" -Label 'ветка-C' }
) -Throttle 4
$sw.Stop()
Check "барьер вернул все ветки" (@($res).Count -eq 3) "получено: $(@($res).Count)"
Check "все ветки реально отработали" ((Test-Path $trace) -and @(Get-Content $trace).Count -eq 3)

# Параллельность доказывается ПЕРЕКРЫТИЕМ, а не порогом по секундомеру: порог не
# отличает «параллельно плюс накладные расходы на runspace» от «последовательно» и
# начинает мигать на загруженной машине. Быстрые ветки обязаны закончить раньше
# медленной — при последовательном исполнении это невозможно ни при какой скорости.
$bm = @{}
foreach ($line in (Get-Content -LiteralPath $trace -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    $p = $line -split '\|'
    if ($p.Count -eq 2) { $bm[$p[0]] = [datetime]$p[1] }
}
Check "быстрые ветки закончили раньше медленной" `
    ($bm['B'] -lt $bm['A'] -and $bm['C'] -lt $bm['A']) `
    "A=$($bm['A']) B=$($bm['B']) C=$($bm['C'])"

# ---------------------------------------------------------------------------
Section "6. Конвейер: барьера между стадиями НЕТ"
# ---------------------------------------------------------------------------
# Два элемента, две стадии. Медленный элемент — только на ПЕРВОЙ стадии.
#   при барьере между стадиями: max(1200,100) + max(100,100) = 1300 мс
#   при конвейере:              max(1200+100, 100+100)       = 1300 мс … одинаково?
# Нет: показательна ОЧЕРЁДНОСТЬ. Быстрый элемент обязан пройти СВОЮ вторую стадию
# раньше, чем медленный закончит ПЕРВУЮ. Это и отличает конвейер от барьера,
# и проверяется по временным меткам, а не по суммарному времени.
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$trace = Join-Path $sandbox 'pipeline.trace'
Remove-Item $trace -ErrorAction SilentlyContinue
Set-GraphVar trace $trace
$res = Invoke-Pipeline -Items @('медленный', 'быстрый') -Stages @(
    {
        param($prev, $item)
        $ms = if ($item -eq 'медленный') { 1200 } else { 50 }
        Invoke-Node -Prompt "SLEEP:$ms TRACE:$(Get-GraphVar trace)|s1-$item" -Label "с1-$item"
    },
    {
        param($prev, $item)
        Invoke-Node -Prompt "SLEEP:50 TRACE:$(Get-GraphVar trace)|s2-$item" -Label "с2-$item"
    }
) -Throttle 4

Check "конвейер вернул результат по каждому элементу" (@($res).Count -eq 2) "получено: $(@($res).Count)"
$marks = @{}
foreach ($line in (Get-Content -LiteralPath $trace -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    $p = $line -split '\|'
    if ($p.Count -eq 2) { $marks[$p[0]] = [datetime]$p[1] }
}
Check "все четыре узла отработали" ($marks.Count -eq 4) "метки: $($marks.Keys -join ', ')"
Check "быстрый прошёл стадию 2 РАНЬШЕ, чем медленный закончил стадию 1" `
    ($marks['s2-быстрый'] -lt $marks['s1-медленный']) `
    "s2-быстрый=$($marks['s2-быстрый']) s1-медленный=$($marks['s1-медленный'])"

# ---------------------------------------------------------------------------
Section "7. Упавшая стадия роняет одну ветку, а не весь веер"
# ---------------------------------------------------------------------------
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$res = Invoke-Pipeline -Items @('целый', 'битый') -Stages @(
    {
        param($prev, $item)
        if ($item -eq 'битый') { throw 'THROWSTAGE' }
        Invoke-Node -Prompt 'обычный' -Label "ветка-$item"
    }
) -Throttle 4
$ok = @($res | Where-Object { $_ })
Check "выжившая ветка вернула результат" ($ok.Count -eq 1) "выжило: $($ok.Count) из $(@($res).Count)"
Check "упавшая ветка стала null" (@($res).Count -eq 2)

# ---------------------------------------------------------------------------
Section "8. Возобновление: адресация по содержимому"
# ---------------------------------------------------------------------------
$ctx1 = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
$a = Invoke-Node -Prompt 'узел один' -Label 'у1'
$b = Invoke-Node -Prompt 'узел два'  -Label 'у2'
$runId1 = $ctx1.RunId

$ctx2 = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4 -ResumeFromRunId $runId1
$a2 = Invoke-Node -Prompt 'узел один' -Label 'у1'
$b2 = Invoke-Node -Prompt 'узел два'  -Label 'у2'
$c2 = Invoke-Node -Prompt 'узел три'  -Label 'у3'
Check "возобновлённые узлы вернули то же" ($a2 -eq $a -and $b2 -eq $b)
$j2 = @(Get-Content -LiteralPath $ctx2.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Check "два узла взяты из кэша" (@($j2 | Where-Object { $_.event -eq 'node-finish' -and $_.cached }).Count -eq 2)
Check "новый узел реально исполнен" (@($j2 | Where-Object { $_.event -eq 'node-start' }).Count -eq 1)
Check "кэшированные узлы не потратили токенов" ((Get-GraphSpent) -eq 5) "потрачено: $(Get-GraphSpent)"

# Изменение промпта обязано пробивать кэш — иначе правка графа молча не применится.
$ctx3 = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4 -ResumeFromRunId $runId1
$a3 = Invoke-Node -Prompt 'узел один ИЗМЕНЁН' -Label 'у1'
$j3 = @(Get-Content -LiteralPath $ctx3.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Check "изменённый промпт мимо кэша" (@($j3 | Where-Object { $_.event -eq 'node-start' }).Count -eq 1)

# Три ОДИНАКОВЫХ узла (панель скептиков) обязаны кэшироваться по отдельности.
$ctx4 = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4
1..3 | ForEach-Object { Invoke-Node -Prompt 'одинаковый скептик' -Label 'скептик' | Out-Null }
$ctx5 = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 4 -ResumeFromRunId $ctx4.RunId
1..3 | ForEach-Object { Invoke-Node -Prompt 'одинаковый скептик' -Label 'скептик' | Out-Null }
$j5 = @(Get-Content -LiteralPath $ctx5.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Check "три одинаковых узла кэшируются по отдельности" (@($j5 | Where-Object { $_.event -eq 'node-finish' -and $_.cached }).Count -eq 3) `
    "из кэша: $(@($j5 | Where-Object { $_.event -eq 'node-finish' -and $_.cached }).Count)"

# ---------------------------------------------------------------------------
Section "9. Предохранители: потолок узлов и бюджет"
# ---------------------------------------------------------------------------
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 2 -MaxNodes 3
$threw = $false
try { 1..5 | ForEach-Object { Invoke-Node -Prompt "узел $_" -Label "у$_" | Out-Null } }
catch { $threw = $_.Exception.Message -match 'потолок узлов' }
Check "потолок узлов останавливает граф" $threw

$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 2 -TokenBudget 12
$threw = $false
try { 1..5 | ForEach-Object { Invoke-Node -Prompt "бюджетный $_" -Label "б$_" | Out-Null } }
catch { $threw = $_.Exception.Message -match 'Бюджет|бюджет' }
Check "исчерпанный бюджет останавливает граф" $threw

# ---------------------------------------------------------------------------
Section "10. Сухой план ничего не запускает"
# ---------------------------------------------------------------------------
$ctx = Initialize-GraphRun -Root $sandbox -Meta $meta -MaxConcurrency 2 -DryPlan
$r = Invoke-Node -Prompt 'SLEEP:5000 этот узел не должен исполниться' -Label 'сухой'
$dry = @(Get-Content -LiteralPath $ctx.Journal -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } |
         Where-Object { $_.event -eq 'node-start' -and $_.dry })
Check "сухой план фиксирует узел, но не исполняет" ($dry.Count -eq 1 -and (Get-GraphSpent) -eq 0)

# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
Remove-Item Env:\BCF_GRAPH_FAKE_AGENT -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("ИТОГ: {0} прошло, {1} провалено" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ""
if ($script:Fail) { exit 1 }
exit 0
