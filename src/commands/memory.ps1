# bcf memory — векторная память: то, ради чего прогоны учатся на прошлых ошибках.
#
#   bcf memory status      что в памяти лежит и растёт ли это
#   bcf memory init        поднять pgvector, применить схему, включить в конфиге проекта
#   bcf memory ask <текст> что память помнит по этому поводу
#   bcf memory stats       то же, что status, но JSON
#   bcf memory down        убрать контейнер; данные остаются на диске, init поднимет заново
#
# ПОЧЕМУ ЭТО ВАЖНЕЕ, ЧЕМ ВЫГЛЯДИТ. Без памяти каждый прогон начинается с нуля: один и тот
# же провал повторяется столько раз, сколько раз запущен цикл. С памятью — провал узла,
# провал задачи и подтверждённая находка критика становятся уроками, и следующий узел
# получает их в контекст ДО работы.
#
# И главная ловушка, ради которой status печатает числа, а не «ок»: память бывает
# доступна и при этом содержать один-единственный урок, который перечитывается полсотни
# раз. «Память активна» в такой ситуации — правда, которая скрывает, что запись не
# работает. Живое обучение видно только по росту чисел от прогона к прогону.

$project = $script:BcfProject
$home_ = Get-BcfHome
$memDir = Get-BcfMemoryDir
$client = Join-Path $memDir 'pgvector\memory_client.py'
$compose = Join-Path $memDir 'pgvector\docker-compose.yml'

# Без этого диагностика клиента приходит в кодировке консоли и читается как мусор —
# то есть теряется ровно там, где важнее всего: в сообщении о причине отказа.
$env:PYTHONIOENCODING = 'utf-8'

$sub = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1
$rest = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -Skip 1
if (-not $sub) { $sub = 'status' }

$env:BCF_PROJECT_ROOT = $project

# Конфиг памяти — ТОТ ЖЕ, что возьмёт клиент, и в том же порядке.
#
# У клиента (memory_client.py, _config_candidates) приоритет такой: $BCF_MEM_CONFIG →
# <проект>/config/memory.config.json → конфиг фабрики. Команда же читала ТОЛЬКО конфиг
# фабрики — и на проекте со своей базой это расходилось молча: `bcf memory init` поднимал
# контейнер фабрики (bcf-agent-memory:5433) и рапортовал об успехе, а клиент шёл в базу
# проекта (например bgc-agent-memory:5434), которой никто не поднял. Человек видел
# зелёный init и «память недоступна» на прогоне — одновременно.
function Get-BcfMemoryConfig {
    param([string]$Project)
    $candidates = @()
    if ($env:BCF_MEM_CONFIG) { $candidates += $env:BCF_MEM_CONFIG }
    if ($Project) { $candidates += (Join-Path $Project 'config\memory.config.json') }
    $candidates += (Join-Path (Get-BcfMemoryDir) 'memory.config.json')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) {
            try {
                $cfg = Get-Content -Raw -LiteralPath $c | ConvertFrom-Json
                return [pscustomobject]@{
                    Path      = $c
                    Port      = $(if ($cfg.port) { [int]$cfg.port } else { 5433 })
                    Container = $(if ($cfg.container) { [string]$cfg.container } else { 'bcf-agent-memory' })
                    Database  = [string]$cfg.database
                    User      = [string]$cfg.user
                    PwEnv     = $(if ($cfg.password_env) { [string]$cfg.password_env } else { 'BCF_PG_PASSWORD' })
                    PwDefault = [string]$cfg.password_default
                    Endpoint  = $(if ($cfg.embedding_endpoint) { [string]$cfg.embedding_endpoint } else { 'http://localhost:1234/v1/embeddings' })
                    Model     = [string]$cfg.embedding_model
                    Dim       = $cfg.embedding_dim
                    DataDir   = [string]$cfg.data_dir
                    Raw       = $cfg
                }
            } catch { }
        }
    }
    return $null
}

function Invoke-MemClient {
    param([string[]]$MemArgs)
    if (-not (Test-Path $client)) { return $null }
    $out = & python $client @MemArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Text = $out.Trim() } }
    return [pscustomobject]@{ Ok = $true; Text = $out.Trim() }
}

function Get-MemStats {
    $r = Invoke-MemClient @('stats')
    if (-not $r -or -not $r.Ok) { return $null }
    try { return $r.Text | ConvertFrom-Json } catch { return $null }
}

switch ($sub) {

'status' {
    Write-BcfTitle 'ПАМЯТЬ' "$(Split-Path $project -Leaf) · клиент: $client"

    if (-not (Test-Path $client)) {
        Write-BcfFail "клиент не найден: $client"
        exit 2
    }

    $cfg = $null
    try { $cfg = Get-BcfHarnessConfig -Project $project } catch { }
    $enabled = $cfg -and $cfg.features -and $cfg.features.memory
    if ($enabled) { Write-BcfOk 'включена в config/harness.json → features.memory' }
    else {
        Write-BcfWarn 'ВЫКЛЮЧЕНА в config/harness.json → features.memory'
        Write-BcfNote 'прогоны идут без уроков: один и тот же провал повторяется каждый прогон.'
    }

    $st = Get-MemStats
    if (-not $st) {
        Write-BcfFail 'база недоступна — уроки не отзываются и не пишутся'
        $m0 = Get-BcfMemoryConfig -Project $project
        if ($m0) {
            # Адрес обязателен в сообщении: на проекте со своей базой «недоступна» без
            # адреса отправляет чинить не тот контейнер.
            Write-BcfNote "ходили в: $($m0.Container) на 127.0.0.1:$($m0.Port)   (конфиг: $($m0.Path))"
        }
        Write-BcfNote 'поднять: bcf memory init'
        Write-Host ''
        exit 1
    }

    Write-Host ''
    $rows = New-BcfRows
    Add-BcfRow $rows @('уроки (анти-паттерны)', $(if ($null -eq $st.anti_patterns) { 'таблицы нет' } else { "$($st.anti_patterns)" }))
    Add-BcfRow $rows @('баги', $(if ($null -eq $st.bugs) { 'таблицы нет' } else { "$($st.bugs)" }))
    Add-BcfRow $rows @('отзывы (recall)', $(if ($null -eq $st.recalls) { 'таблицы нет' } else { "$($st.recalls)" }))
    Add-BcfRow $rows @('предложения эволюции', $(if ($null -eq $st.proposals) { 'таблицы нет' } else { "$($st.proposals)" }))
    Write-BcfTable -Headers @('что', 'сколько') -Widths @(26, 16) -Rows $rows

    Write-Host ''
    # $null означает «таблицы нет», а не «нуль записей»: печатать их одинаково значит
    # сказать «уроков 0» о базе, в которой негде их хранить, — и человек пойдёт чинить
    # запись вместо схемы.
    if ($null -eq $st.anti_patterns) {
        Write-BcfFail 'таблицы уроков нет — схема не применена'
        Write-BcfNote 'применить: bcf memory init (или memory/pgvector/init.sql руками)'
        Write-Host ''
        exit 1
    }
    # ЭМБЕДДИНГИ ПРОВЕРЯЕМ ТОЖЕ. База и сервер эмбеддингов отказывают НЕЗАВИСИМО, а
    # выглядит это одинаково: «память недоступна» на прогоне при полностью живом
    # контейнере. Пока проба стояла только в `memory init`, статус показывал зелёную базу
    # и правильные числа — то есть отвечал «всё хорошо» на вопрос «почему не работает».
    $mcfg = Get-BcfMemoryConfig -Project $project
    $cfgFile = $(if ($mcfg) { $mcfg.Path } else { '(конфиг не найден)' })
    $endpoint = $(if ($mcfg) { $mcfg.Endpoint } else { 'http://localhost:1234/v1/embeddings' })
    $model = $(if ($mcfg) { $mcfg.Model } else { '' })
    $mc = $(if ($mcfg) { $mcfg.Raw } else { $null })
    try {
        $body = @{ model = $model; input = 'probe' } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 15
        $dim = @($resp.data[0].embedding).Count
        if ($dim -gt 0) {
            Write-BcfOk "эмбеддинги отвечают: $model, размерность $dim"
            if ($mc -and $mc.embedding_dim -and [int]$mc.embedding_dim -ne $dim) {
                Write-BcfFail "размерность НЕ совпадает со схемой ($($mc.embedding_dim)) — записи отвергаются базой"
                Write-BcfNote "поправь embedding_dim в $cfgFile или загрузи модель нужной размерности."
            }
        } else {
            Write-BcfFail 'сервер эмбеддингов ответил пустым вектором — отзыв работать не будет'
        }
    } catch {
        Write-BcfFail "сервер эмбеддингов не отвечает: $endpoint"
        Write-BcfNote 'база жива, но отзыв считает эмбеддинг запроса — без сервера recall не работает,'
        Write-BcfNote 'и на прогоне это выглядит как «память недоступна» при исправном контейнере.'
        Write-BcfNote "подними любой OpenAI-совместимый /v1/embeddings и загрузи модель $model."
    }

    $ap = [int]$st.anti_patterns
    $week = $st.anti_patterns_last_7d
    # Вердикт общий с графом и doctor: пустая база и сломанная запись — РАЗНЫЕ состояния, и
    # выдавать первое за второе значит приучить не читать эту строку.
    . (Join-Path (Get-BcfHarness) 'lib\graph-memory.ps1')
    $verdict = Get-BcfLearningVerdict -Lessons $ap -Project $project
    if ($verdict.Level -eq 'broken') {
        Write-BcfWarn $verdict.Text
        Write-BcfNote 'после боевого прогона это число обязано вырасти. Если не растёт — уроки пишет'
        Write-BcfNote 'только ретроспектор после вердикта, а до вердикта доходят единицы задач.'
        exit 1
    }
    if ($verdict.Level -eq 'empty') {
        Write-BcfDim $verdict.Text
        Write-BcfNote 'это нормальное состояние свежей базы, а не поломка: первый же прогон её наполнит.'
        Write-Host ''
        exit 0
    }
    if ($null -ne $week) {
        if ([int]$week -gt 0) { Write-BcfOk "за последние 7 дней прибавилось уроков: $week — обучение живое" }
        else {
            Write-BcfWarn 'за последние 7 дней новых уроков нет'
            Write-BcfNote 'память читается, но не пополняется: прогоны перечитывают старое и не учатся на свежем.'
        }
    }
    Write-Host ''
    exit 0
}

'init' {
    Write-BcfTitle 'ПОДКЛЮЧЕНИЕ ПАМЯТИ' 'pgvector + сервер эмбеддингов'

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-BcfFail 'docker не найден — контейнер с базой поднять нечем'
        Write-BcfNote 'поставь Docker Desktop и повтори. Память опциональна: без неё харнесс работает,'
        Write-BcfNote 'но не учится на прошлых прогонах.'
        exit 2
    }

    # Демон проверяем ДО первой команды docker. На Windows docker.exe при незапущенном
    # Docker Desktop не падает, а запускает его и ждёт — вместо ответа человек получает
    # минуты тишины и чужой диалог поверх экрана. Сказать прямо дешевле.
    . (Join-Path (Get-BcfHarness) 'lib\docker.ps1')
    if (-not (Test-BcfDockerDaemon)) {
        Write-BcfFail 'docker установлен, но демон не отвечает — Docker Desktop не запущен'
        Write-BcfNote 'запусти Docker Desktop, дождись зелёного значка и повтори.'
        Write-BcfNote 'сами мы его не поднимаем: старт занимает минуты, и всё это время команда'
        Write-BcfNote 'выглядела бы зависшей.'
        exit 2
    }

    # Порт занят ЧУЖОЙ базой — самый неприятный из возможных исходов, и он молчаливый.
    # Compose не поднимет свой контейнер, клиент подключится к чужому, получит отказ
    # авторизации, и это будет выглядеть как «наша память сломалась». Проверяем ДО.
    $mcfg = Get-BcfMemoryConfig -Project $project
    if (-not $mcfg) {
        Write-BcfFail 'конфиг памяти не найден ни в проекте, ни в фабрике'
        Write-BcfNote 'ожидается config/memory.config.json в проекте или memory/memory.config.json в фабрике.'
        exit 2
    }
    $port = $mcfg.Port
    $ours = $mcfg.Container
    Write-BcfDim "конфиг: $($mcfg.Path)"
    Write-BcfDim "цель: контейнер $ours, порт $port"
    # ЗАНЯТО — ЗНАЧИТ ПОДБИРАЕМ, А НЕ ОТПРАВЛЯЕМ ПРАВИТЬ КОНФИГ РУКАМИ.
    #
    # Раньше здесь стоял exit 2 с советом «поправь port и повтори». Совет верный по сути и
    # негодный по форме: порт 5433 записан дефолтом во ВСЕ установки фабрики, поэтому
    # столкновение — обычное состояние машины с двумя проектами, а не редкость, ради
    # которой стоит будить человека. Подбираем свободный, пишем в конфиг проекта и
    # говорим, что сделали.
    . (Join-Path (Get-BcfHarness) 'lib\memory-port.ps1')
    $pr = Resolve-BcfMemoryPort -Wanted $port -Container $ours -ConfigPath $mcfg.Path -ProjectRoot $project
    if ($pr.Holder) {
        $kind = if ($pr.HolderKind -eq 'container') { 'контейнером' } else { 'процессом' }
        Write-BcfWarn "порт $port занят $kind '$($pr.Holder)' — это не наша база"
        Write-BcfNote 'оставить как есть нельзя: клиент подключился бы к ЧУЖОЙ базе, получил отказ'
        Write-BcfNote 'авторизации, и выглядело бы это как поломка нашей памяти.'
    }
    if ($pr.Error) {
        Write-BcfFail "порт $port занят, заменить не вышло: $($pr.Error)"
        Write-BcfNote "останови занявшего или впиши свободный port в $($mcfg.Path) и повтори."
        exit 2
    }
    if ($pr.Changed) {
        $port = $pr.Port
        Write-BcfOk "беру свободный порт $port — записан в $($pr.ConfigPath)"
        Write-BcfNote 'проектный конфиг перекрывает фабричный: клиент памяти прочитает тот же порт.'
        # Дальше всё считаем по НОВОМУ конфигу: имя контейнера, данные и адрес клиента
        # должны сойтись, иначе мы починили порт и разошлись в остальном.
        $mcfg = Get-BcfMemoryConfig -Project $project
        $ours = $mcfg.Container
    }

    # Compose параметризован переменными окружения (см. docker-compose.yml). Передаём ему
    # ИМЕННО то, что прочитает клиент: иначе поднимется контейнер с другим именем и на
    # другом порту, а команда отчитается об успехе.
    Write-BcfDim "поднимаю контейнер $ours на порту $port…"
    $env:BCF_MEM_CONTAINER = $ours
    $env:BCF_PG_PORT = "$port"
    if (-not $env:BCF_PG_PASSWORD -and $mcfg.PwDefault) { $env:BCF_PG_PASSWORD = $mcfg.PwDefault }

    # КАТАЛОГ ДАННЫХ — СВОЙ НА КАЖДУЮ БАЗУ. Пока он был один на всех, второй контейнер
    # монтировал чужой postgres: пароль применяется только при первой инициализации
    # пустого каталога, поэтому клиент получал «password authentication failed», а при
    # одновременной работе двух контейнеров данные просто портятся.
    $dataDir = $mcfg.DataDir
    if (-not $dataDir) {
        if ($ours -eq 'bcf-agent-memory') { $dataDir = './data' }   # общая база фабрики, как было
        else { $dataDir = (Join-Path $project '.bcf\memory\data') }
    }
    if ($dataDir -ne './data') {
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        $dataDir = (Resolve-Path $dataDir).Path
        Write-BcfDim "данные: $dataDir"
    }
    $env:BCF_MEM_DATA = $dataDir
    & docker compose -f $compose up -d 2>&1 | ForEach-Object { Write-BcfNote $_ }
    if ($LASTEXITCODE -ne 0) { Write-BcfFail 'docker compose up не отработал'; exit 1 }

    # Ждём healthy, а не «команда вернула 0»: контейнер поднимается раньше, чем база
    # готова принимать соединения, и первая же запись после старта падала бы молча.
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        $h = (& docker inspect -f '{{.State.Health.Status}}' $ours 2>$null | Out-String).Trim()
        if ($h -eq 'healthy') { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($ok) { Write-BcfOk 'база отвечает (healthy)' }
    else {
        Write-BcfWarn "база не сообщила healthy за минуту — проверь docker logs $ours"
    }

    # Эмбеддинги. Без них recall не работает вовсе, а выглядит это как «память пустая».
    $cfgFile = $mcfg.Path
    $endpoint = $mcfg.Endpoint
    $model = $mcfg.Model
    $mc = $mcfg.Raw
    $embedOk = $false
    try {
        $body = @{ model = $model; input = 'probe' } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 15
        $dim = @($resp.data[0].embedding).Count
        if ($dim -gt 0) {
            Write-BcfOk "эмбеддинги отвечают: $model, размерность $dim"
            $embedOk = $true
            if ($mc -and $mc.embedding_dim -and [int]$mc.embedding_dim -ne $dim) {
                Write-BcfFail "размерность НЕ совпадает со схемой ($($mc.embedding_dim)) — записи будут отвергаться базой"
                Write-BcfNote "поправь embedding_dim в $cfgFile или загрузи модель нужной размерности."
            }
        }
    } catch {
        Write-BcfFail "сервер эмбеддингов не отвечает: $endpoint"
        Write-BcfNote 'подними любой OpenAI-совместимый /v1/embeddings (например LM Studio) и загрузи в него'
        Write-BcfNote "модель $model. Без эмбеддингов recall не работает, и это выглядит как «память пустая»."
    }

    # Включаем в конфиге проекта — иначе харнесс память просто не позовёт.
    $cfgPath = Join-Path $project 'config\harness.json'
    if (Test-Path $cfgPath) {
        try {
            $hc = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
            if ($hc.features -and $hc.features.memory) {
                # УЖЕ ВКЛЮЧЕНО — НЕ ТРОГАЕМ ФАЙЛ. Круговой прогон через ConvertTo-Json
                # переписывает конфиг целиком и уничтожает ручное форматирование: у
                # человека 24 строки диффа там, где не поменялось ни одного значения.
                Write-BcfDim 'features.memory уже true — конфиг не трогаю'
            } else {
                $hc.features.memory = $true
                ($hc | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
                Write-BcfOk 'features.memory = true в config/harness.json'
                Write-BcfNote 'файл перезаписан целиком — ручное форматирование JSON не сохраняется.'
            }
        } catch { Write-BcfWarn "не удалось включить features.memory: $($_.Exception.Message)" }
    } else {
        Write-BcfWarn 'config/harness.json не найден — включи features.memory вручную после bcf init'
    }

    Write-Host ''
    $st = Get-MemStats
    if ($st) {
        Write-BcfOk "память готова · уроков $($st.anti_patterns) · багов $($st.bugs) · отзывов $($st.recalls)"
        if ([int]$st.anti_patterns -le 1) {
            Write-BcfNote 'уроков пока нет — это нормально для свежей базы. После первого боевого'
            Write-BcfNote 'прогона число обязано вырасти; если не выросло, запись не работает.'
        }
    } else {
        Write-BcfFail 'клиент не смог прочитать счётчики — память подключена не полностью'
        exit 1
    }
    if (-not $embedOk) {
        Write-Host ''
        Write-BcfWarn 'база есть, эмбеддингов нет: писать уроки можно, отзывать — нельзя.'
        exit 1
    }
    Write-Host ''
    exit 0
}

'ask' {
    $q = ($rest -join ' ').Trim()
    if (-not $q) { Write-BcfFail 'что спросить? bcf memory ask "слияние упало на лок-файле"'; exit 2 }

    $r = Invoke-MemClient @('recall', '--text', $q, '--k', '5')
    if (-not $r -or -not $r.Ok) {
        Write-BcfFail 'память недоступна'
        if ($r) { Write-BcfNote $r.Text }
        exit 1
    }
    $items = @()
    try { $items = @($r.Text | ConvertFrom-Json) } catch { }

    Write-BcfTitle 'ЧТО ПОМНИТ ПАМЯТЬ' $q
    if (-not $items.Count) {
        Write-BcfDim 'ничего похожего не нашлось'
        Write-BcfNote 'это не «памяти нет»: возможно, такой ситуации ещё не было — тогда урок появится после первого провала.'
        Write-Host ''
        exit 0
    }
    foreach ($it in $items) {
        Write-Host ''
        $sim = if ($it.similarity) { '{0:P0}' -f [double]$it.similarity } else { '' }
        Write-BcfLine "  · $($it.trigger)   $sim" 'White'
        if ($it.went_wrong)  { Write-BcfNote "было не так: $($it.went_wrong)" }
        if ($it.alternative) { Write-BcfNote "как надо:    $($it.alternative)" }
    }
    Write-Host ''
    exit 0
}

'stats' {
    $st = Get-MemStats
    if (-not $st) { Write-BcfFail 'память недоступна'; exit 1 }
    ($st | ConvertTo-Json -Depth 5) | Write-Output
    exit 0
}

'down' {
    # Проба демона ОБЯЗАТЕЛЬНА, как и в init. Без неё `bcf memory down` при закрытом
    # Docker Desktop сам его ЗАПУСКАЕТ и ждёт минуты — то есть команда «останови»
    # поднимает приложение, которое её об этом не просили.
    . (Join-Path (Get-BcfHarness) 'lib\docker.ps1')
    if (-not (Test-BcfDockerDaemon)) {
        Write-BcfDim 'демон Docker не отвечает — останавливать нечего'
        Write-BcfNote 'Docker Desktop не запущен, значит и контейнер не работает; данные в memory/pgvector/data на месте.'
        Write-BcfNote 'сам Docker Desktop не поднимаем: старт занимает минуты, и команда выглядела бы зависшей.'
        Write-Host ''
        exit 0
    }
    if (-not (Test-Path $compose)) { Write-BcfFail "compose-файл не найден: $compose"; exit 2 }

    # Тот же конфиг, что у init: иначе compose уберёт контейнер по умолчанию, а не тот,
    # который подняли для этого проекта.
    $mcfg = Get-BcfMemoryConfig -Project $project
    if ($mcfg) {
        $env:BCF_MEM_CONTAINER = $mcfg.Container
        $env:BCF_PG_PORT = "$($mcfg.Port)"
        $dd = $mcfg.DataDir
        if (-not $dd) {
            if ($mcfg.Container -eq 'bcf-agent-memory') { $dd = './data' }
            else { $dd = (Join-Path $project '.bcf\memory\data') }
        }
        $env:BCF_MEM_DATA = $dd
        Write-BcfDim "убираю контейнер $($mcfg.Container)"
    }
    & docker compose -f $compose down 2>&1 | ForEach-Object { Write-BcfNote $_ }
    # Код возврата проверяем ДО слова «остановлен»: раньше строка успеха печаталась
    # безусловно, и отказ compose (чужой контекст, занятый ресурс) выглядел как успех.
    if ($LASTEXITCODE -ne 0) {
        Write-BcfFail 'docker compose down не отработал — контейнер, вероятно, ещё работает'
        Write-BcfNote "проверь: docker ps --filter name=bcf-agent-memory"
        Write-Host ''
        exit 1
    }
    Write-BcfOk 'контейнер остановлен, данные остались в memory/pgvector/data'
    exit 0
}

default {
    Write-BcfFail "неизвестная подкоманда: $sub"
    Write-BcfNote 'доступно: status | init | ask <текст> | stats | down'
    exit 2
}
}
