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
    $cfgFile = Join-Path (Get-BcfMemoryDir) 'memory.config.json'
    $endpoint = 'http://localhost:1234/v1/embeddings'
    $model = ''
    $mc = $null
    if (Test-Path $cfgFile) {
        try {
            $mc = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($mc.embedding_endpoint) { $endpoint = [string]$mc.embedding_endpoint }
            if ($mc.embedding_model) { $model = [string]$mc.embedding_model }
        } catch { }
    }
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
    if ($ap -le 1) {
        Write-BcfWarn 'уроков почти нет: чтение работает, ЗАПИСЬ — нет'
        Write-BcfNote 'после боевого прогона это число обязано вырасти. Если не растёт — уроки пишет'
        Write-BcfNote 'только ретроспектор после вердикта, а до вердикта доходят единицы задач.'
        exit 1
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
    $port = 5433
    $cfgFileEarly = Join-Path $memDir 'memory.config.json'
    if (Test-Path $cfgFileEarly) {
        try { $port = [int]((Get-Content -Raw -LiteralPath $cfgFileEarly | ConvertFrom-Json).port) } catch { }
    }
    $ours = 'bcf-agent-memory'
    $holder = ''
    try {
        foreach ($line in (& docker ps --format '{{.Names}}|{{.Ports}}' 2>$null)) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 2) { continue }
            if ($parts[1] -match ":$port->") { $holder = $parts[0]; break }
        }
    } catch { }
    if ($holder -and $holder -ne $ours) {
        Write-BcfFail "порт $port уже занят другим контейнером: $holder"
        Write-BcfNote 'это не просто «занято»: клиент подключится к ЧУЖОЙ базе, получит отказ'
        Write-BcfNote 'авторизации, и выглядеть это будет как поломка нашей памяти.'
        Write-BcfNote "поправь port в $cfgFileEarly и BCF_PG_PORT в окружении на свободный, затем повтори."
        exit 2
    }

    Write-BcfDim 'поднимаю контейнер…'
    & docker compose -f $compose up -d 2>&1 | ForEach-Object { Write-BcfNote $_ }
    if ($LASTEXITCODE -ne 0) { Write-BcfFail 'docker compose up не отработал'; exit 1 }

    # Ждём healthy, а не «команда вернула 0»: контейнер поднимается раньше, чем база
    # готова принимать соединения, и первая же запись после старта падала бы молча.
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        $h = (& docker inspect -f '{{.State.Health.Status}}' bcf-agent-memory 2>$null | Out-String).Trim()
        if ($h -eq 'healthy') { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($ok) { Write-BcfOk 'база отвечает (healthy)' }
    else {
        Write-BcfWarn 'база не сообщила healthy за минуту — проверь docker logs bcf-agent-memory'
    }

    # Эмбеддинги. Без них recall не работает вовсе, а выглядит это как «память пустая».
    $cfgFile = Join-Path $memDir 'memory.config.json'
    $endpoint = 'http://localhost:1234/v1/embeddings'
    $model = ''
    if (Test-Path $cfgFile) {
        try {
            $mc = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
            if ($mc.embedding_endpoint) { $endpoint = [string]$mc.embedding_endpoint }
            if ($mc.embedding_model) { $model = [string]$mc.embedding_model }
        } catch { }
    }
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
            $hc.features.memory = $true
            ($hc | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
            Write-BcfOk 'features.memory = true в config/harness.json'
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
