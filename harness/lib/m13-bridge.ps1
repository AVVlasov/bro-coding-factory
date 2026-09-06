# m13-bridge.ps1 — memory bridge (vector memory + retrospector) в loop-harness.
#
# loop-harness вызывает opencode subprocess'ом → хуки агентского рантайма не
# срабатывают. Этот мостик встраивает три механизма памяти явно:
#
#   Inject-AntiPatterns   — перед opencode A/B: recall по контексту итерации,
#                            prepend <known-anti-patterns> блок в STATE.md.
#   Run-Retrospector      — после verdict: ретроспектор JSON → upsert в anti_patterns.
#   Invoke-FindingGate    — между opencode-run и verify: блокирует non-verifiable dismiss.

# ДВА разных корня, и путать их дорого:
#   RepoRoot  — проект, над которым идёт работа (там задачи, вердикты, .claude/);
#   HomeRoot  — фабрика (там движок и ОДНА установка памяти на все проекты).
# Клиент памяти искался в проекте, и на любом чужом проекте это выглядело как
# «memory_client.py не найден» — то есть память молча выключалась на всём, кроме
# самой фабрики.
. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:RepoRoot     = Get-BcfProjectRoot
$script:HomeRoot     = Get-BcfHomeRoot

$script:M13Disabled  = ($env:BCF_MEMORY_DISABLED -eq '1')
$script:MemClient    = if ($env:BCF_MEMORY_CLIENT)   { $env:BCF_MEMORY_CLIENT }   else { Join-Path $script:HomeRoot 'memory/pgvector/memory_client.py' }
$script:Retrospector = if ($env:BCF_INVOKE_RETROSPECTOR) { $env:BCF_INVOKE_RETROSPECTOR } else { Join-Path $script:RepoRoot '.claude/agents/bin/invoke-retrospector.ps1' }
$script:FindingGate  = if ($env:BCF_FINDING_GATE)    { $env:BCF_FINDING_GATE }    else { Join-Path $script:RepoRoot '.claude/hooks/subagent-finding-gate.sh' }

$script:MemCompose   = if ($env:BCF_MEM_COMPOSE)     { $env:BCF_MEM_COMPOSE }     else { Join-Path $script:HomeRoot 'memory/pgvector/docker-compose.yml' }

# Имя контейнера, ПОРТ и адрес — из одного места на всю фабрику (memory-config.ps1):
# конфиг проекта плюс накладка машины .bcf/memory.local.json. Своя копия правила здесь
# уже расходилась с командой `bcf memory`: контейнер поднимался один, клиент шёл в другой.
#
# Порт читается не для красоты. Compose параметризован переменными окружения
# (BCF_MEM_CONTAINER, BCF_PG_PORT), и пока мостик их не выставлял, он поднимал контейнер по
# ДЕФОЛТАМ compose, а клиент шёл по адресу из конфига. На проекте со своей базой это
# расходилось молча: контейнер есть, память «недоступна».
. (Join-Path $PSScriptRoot 'memory-config.ps1')
$script:MemSettings  = Resolve-BcfMemorySettings -Project $script:RepoRoot -FactoryMemoryDir (Join-Path $script:HomeRoot 'memory')
$script:MemDbConfig  = if ($script:MemSettings) { $script:MemSettings.Path } else { Join-Path $script:HomeRoot 'memory/memory.config.json' }
$script:MemContainer = if ($script:MemSettings) { $script:MemSettings.Container } else { 'bcf-agent-memory' }
$script:MemPort      = if ($script:MemSettings) { [int]$script:MemSettings.Port } else { 5433 }
$script:MemHost      = if ($script:MemSettings) { $script:MemSettings.Host } else { 'localhost' }
$script:MemIsLocal   = if ($script:MemSettings) { [bool]$script:MemSettings.IsLocalHost } else { $true }

# Гарантирует, что эмбеддинг-модель памяти загружена в LM Studio. Без неё
# memory_client.py embed падает → recall/upsert молча мрут → цикл обучения не
# работает (та же тихая поломка, что и с pgvector). ВАЖНО:
#   • не запускать второй LM Studio сервер (сначала проба endpoint'а);
#   • не грузить модель повторно (сначала `lms ps` — если уже загружена, выходим).
function Ensure-LmStudioEmbedding {
    param([int]$TimeoutSec = 40)

    $lms = (Get-Command lms -ErrorAction SilentlyContinue).Source
    if (-not $lms) {
        Write-Host "[memory] ⚠ LM Studio CLI 'lms' не найден в PATH — эмбеддинги памяти недоступны, recall/upsert работать НЕ будут." -ForegroundColor Red
        return $false
    }

    # Модель и endpoint берём из memory.config.json (single source of truth).
    $model = 'text-embedding-bge-m3'
    $endpoint = 'http://localhost:1234/v1/embeddings'
    if (Test-Path $script:MemDbConfig) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $script:MemDbConfig | ConvertFrom-Json
            if ($cfg.embedding_model)    { $model = $cfg.embedding_model }
            if ($cfg.embedding_endpoint) { $endpoint = $cfg.embedding_endpoint }
        } catch { }
    }
    $modelsUrl = ($endpoint -replace '/embeddings/?$', '/models')

    # 1. GUARD против двойной загрузки: если модель уже в `lms ps` — ничего не грузим.
    $psOut = (& lms ps 2>$null | Out-String)
    if ($psOut -match [regex]::Escape($model)) {
        Write-Host "[memory] ✅ эмбеддинг-модель '$model' уже загружена в LM Studio (без повторной загрузки)." -ForegroundColor Green
        return $true
    }

    # 2. GUARD против двойного запуска сервера: стартуем только если endpoint недоступен.
    $serverUp = $false
    try { Invoke-RestMethod -Uri $modelsUrl -TimeoutSec 4 | Out-Null; $serverUp = $true } catch { $serverUp = $false }
    if (-not $serverUp) {
        Write-Host "[memory] LM Studio сервер недоступен ($modelsUrl) — lms server start..." -ForegroundColor Yellow
        # Запускаем ФОНОМ: синхронный вызов здесь тоже ничем не ограничен, а ждать мы и
        # так умеем — поллингом endpoint ниже, у которого потолок настоящий.
        try {
            Start-Process -FilePath 'lms' -ArgumentList @('server', 'start') -NoNewWindow -PassThru | Out-Null
        } catch {
            Write-Host "[memory] ⚠ не удалось запустить lms: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Seconds 2
            try { Invoke-RestMethod -Uri $modelsUrl -TimeoutSec 4 | Out-Null; $serverUp = $true } catch { }
        } while (-not $serverUp -and (Get-Date) -lt $deadline)
        if (-not $serverUp) {
            Write-Host "[memory] ⚠ LM Studio сервер не поднялся — эмбеддинги недоступны." -ForegroundColor Red
            return $false
        }
    }

    # 3. Модель не загружена → грузим РОВНО ОДИН раз (guard из шага 1 гарантирует
    #    отсутствие дубля). --yes подавляет интерактивный prompt выбора конфига.
    # ЗАГРУЗКА ИДЁТ ФОНОМ, А ЖДЁМ МЫ ПО ЧАСАМ.
    #
    # `& lms load … | Out-Null` — синхронный вызов: он тянет несколько гигабайт в VRAM и
    # возвращается только по окончании. Дедлайн заводился СТРОКОЙ НИЖЕ, то есть не
    # ограничивал ничего, а сообщение «не удалось загрузить за ${TimeoutSec}s» называло
    # время, которое ничего не измеряло. Плюс весь прогресс `lms` уничтожался Out-Null, и
    # прогон стоял молча минуты. Теперь процесс запускается отдельно, а ожидание —
    # честное, с потолком и с отметками, что загрузка идёт.
    Write-Host "[memory] эмбеддинг-модель '$model' не загружена — lms load (это минуты: модель едет с диска в память)..." -ForegroundColor Yellow
    $loadLog = [IO.Path]::GetTempFileName()
    $proc = $null
    try {
        $proc = Start-Process -FilePath 'lms' -ArgumentList @('load', $model, '--yes') -NoNewWindow -PassThru `
                              -RedirectStandardOutput $loadLog -RedirectStandardError "$loadLog.err"
    } catch {
        Write-Host "[memory] ⚠ не удалось запустить lms: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $psOut = ''
    $tick = 0
    do {
        Start-Sleep -Seconds 2
        $tick += 2
        $psOut = (& lms ps 2>$null | Out-String)
        if ($psOut -match [regex]::Escape($model)) { break }
        # Каждые полминуты говорим, что живы: молчащая на минуты команда читается как
        # зависшая, и её убивают ровно перед тем, как она бы закончила.
        if ($tick % 30 -eq 0) { Write-Host "[memory]   всё ещё гружу '$model' ($tick с из $TimeoutSec)…" -ForegroundColor DarkGray }
    } while ((Get-Date) -lt $deadline)

    if ($psOut -match [regex]::Escape($model)) {
        Write-Host "[memory] ✅ эмбеддинг-модель '$model' загружена." -ForegroundColor Green
        return $true
    }

    # Не уложились — снимаем зависшую загрузку и печатаем НАСТОЯЩУЮ причину, а не только
    # время: stderr до сих пор молча выбрасывался.
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
    $why = ''
    try { if (Test-Path "$loadLog.err") { $why = (Get-Content -Raw -LiteralPath "$loadLog.err" -EA SilentlyContinue) } } catch { }
    Remove-Item $loadLog, "$loadLog.err" -Force -ErrorAction SilentlyContinue
    Write-Host "[memory] ⚠ не удалось загрузить '$model' за ${TimeoutSec}s — recall/upsert будут падать. Загрузи вручную: lms load $model" -ForegroundColor Red
    if ($why.Trim()) { Write-Host "[memory]    lms сказал: $(($why -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' ')" -ForegroundColor DarkGray }
    return $false
}

. (Join-Path $PSScriptRoot 'docker.ps1')
. (Join-Path $PSScriptRoot 'memory-port.ps1')

function Get-M13Health {
    # 'healthy'|'starting'|'unhealthy'|'stopped'|'absent'|'no-response'|'no-daemon'|'no-docker'|'remote'.
    #
    # Базы может не быть на этой машине: тогда контейнера нет и быть не должно, а
    # docker-ветка подняла бы ВТОРУЮ, пустую, рядом с настоящей — и прогон учился бы в
    # ней. Живость удалённой базы проверяет сам клиент при первом обращении.
    if (-not $script:MemIsLocal) { return 'remote' }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'no-docker' }
    # НЕ `docker version`: на Windows он не падает, а ЗАПУСКАЕТ Docker Desktop и ждёт его
    # — прогон вис минутами, ничего не печатая. Канал демона существует ровно тогда,
    # когда демон слушает, и проверка по нему ничего не запускает. См. lib/docker.ps1.
    if (-not (Test-BcfDockerDaemon)) { return 'no-daemon' }
    $r = Invoke-BcfDocker -DockerArgs @('inspect', '-f', '{{.State.Status}}', $script:MemContainer) -TimeoutSec 15
    # ТАЙМАУТ — НЕ «КОНТЕЙНЕРА НЕТ». Пока их склеивали, подвисший или ещё
    # инициализирующийся демон давал 'absent', и восстановление уходило поднимать
    # контейнер, которого никто не проверял: потолок времени превращался во вход в
    # новое зависание. Утверждать про контейнер что-либо, не получив ответа, нельзя.
    if ($r.TimedOut) { return 'no-response' }
    $state = ([string]$r.Out).Trim()
    if (-not $r.Ok -or -not $state) { return 'absent' }
    if ($state -ne 'running') { return 'stopped' }
    $r2 = Invoke-BcfDocker -DockerArgs @('inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $script:MemContainer) -TimeoutSec 15
    if ($r2.TimedOut) { return 'no-response' }
    $h = ([string]$r2.Out).Trim()
    if (-not $h -or $h -eq 'none') { return 'healthy' }   # без healthcheck — running считаем healthy
    return $h                                              # healthy | starting | unhealthy
}

function Test-M13Available {
    if ($script:M13Disabled) { return $false }
    if (-not (Test-Path $script:MemClient)) { return $false }
    return ((Get-M13Health) -eq 'healthy')
}

# Автостарт векторной памяти + ГРОМКАЯ диагностика. Вызывается один раз при
# старте loop.ps1. Раньше отсутствие контейнера тихо отключало весь цикл
# обучения (recall/retrospector/finding-gate молча return) — не стартовало
# автоматически и не сигналило, что памяти нет. Возвращает $true если память
# доступна после попытки старта.
function Ensure-M13Memory {
    param([int]$TimeoutSec = 45)

    if ($script:M13Disabled) {
        Write-Host "[memory] BCF_MEMORY_DISABLED=1 — цикл обучения выключен намеренно." -ForegroundColor DarkYellow
        return $false
    }
    if (-not (Test-Path $script:MemClient)) {
        Write-Host "[memory] ⚠ memory_client.py не найден ($script:MemClient) — recall/retrospector/finding-gate работать НЕ будут." -ForegroundColor Red
        return $false
    }

    $health = Get-M13Health
    if ($health -eq 'remote') {
        Write-Host "[memory] база памяти на $($script:MemHost):$($script:MemPort) — контейнером здесь не управляем." -ForegroundColor DarkGray
        return $true
    }
    if ($health -eq 'no-docker') {
        Write-Host "[memory] ⚠ docker не найден в PATH — векторная память недоступна, цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
        return $false
    }

    # Демон Docker (Docker Desktop) поднят? Контейнер не стартанёт без него.
    # GUARD двойного запуска: запускаем Desktop только если процесс НЕ найден;
    # если процесс есть, но демон ещё инициализируется — просто ждём.
    if ($health -eq 'no-daemon') {
        $dockerDesktop = @(
            "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
            "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        $proc = @(Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
        if ($proc.Count -gt 0) {
            Write-Host "[memory] Docker Desktop запущен, но демон ещё не готов — жду инициализации..." -ForegroundColor Yellow
        } elseif ($dockerDesktop) {
            Write-Host "[memory] демон Docker не отвечает — запускаю Docker Desktop ($dockerDesktop)..." -ForegroundColor Yellow
            Start-Process -FilePath $dockerDesktop | Out-Null
        } else {
            Write-Host "[memory] ⚠ демон Docker не отвечает и Docker Desktop.exe не найден — запусти Docker вручную. Цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
            return $false
        }
        # Поллинг готовности демона (Desktop стартует долго — даём до 120s).
        $deadline = (Get-Date).AddSeconds(120)
        do {
            Start-Sleep -Seconds 3
            $health = Get-M13Health
        } while ($health -eq 'no-daemon' -and (Get-Date) -lt $deadline)
        if ($health -eq 'no-daemon') {
            Write-Host "[memory] ⚠ демон Docker не поднялся за 120s — векторная память недоступна, цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
            return $false
        }
        Write-Host "[memory] ✅ демон Docker готов." -ForegroundColor Green
    }

    # Демон не ответил — восстанавливать вслепую нельзя: мы не знаем, есть контейнер или
    # нет, а `docker compose up -d` в этом состоянии уходит в тот же колодец.
    if ($health -eq 'no-response') {
        Write-Host "[memory] ⚠ docker не ответил за 15с (демон подвис или ещё инициализируется) — векторная память недоступна, цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
        Write-Host "[memory]    проверь вручную: docker ps --filter name=$($script:MemContainer)" -ForegroundColor DarkGray
        return $false
    }

    if ($health -ne 'healthy') {
        if ($health -eq 'stopped') {
            Write-Host "[memory] контейнер '$($script:MemContainer)' остановлен — docker start..." -ForegroundColor Yellow
            # С ПОТОЛКОМ и с причиной. Сырой `& docker start … | Out-Null` не ограничен по
            # времени и уничтожает stderr: при отказе человек получал подменённый диагноз
            # «pgvector не поднялся за 45s», не имеющий отношения к настоящей ошибке.
            $st = Invoke-BcfDocker -DockerArgs @('start', $script:MemContainer) -TimeoutSec 60
            if (-not $st.Ok) {
                Write-Host "[memory] ⚠ docker start не отработал: $(($st.Err).Trim())" -ForegroundColor Red
                return $false
            }
        } elseif ($health -eq 'absent') {
            if (Test-Path $script:MemCompose) {
                # Образ ещё не скачан? Тогда это не «секунды», а минуты загрузки ~450 МБ.
                # Молчать об этом нельзя: прогон, замерший на пять минут без единой
                # строки, читается как зависший — и его убивают.
                $img = Invoke-BcfDocker -DockerArgs @('image', 'inspect', 'pgvector/pgvector:pg16') -TimeoutSec 15
                if (-not $img.Ok) {
                    Write-Host "[memory] образа pgvector/pgvector:pg16 нет локально — идёт загрузка (~450 МБ, это минуты)." -ForegroundColor Yellow
                }
                # ПОРТ ПРОВЕРЯЕМ ДО ЗАПУСКА, А НЕ РАЗБИРАЕМ ОТКАЗ ПОСЛЕ.
                #
                # Дефолт 5433 один на все установки фабрики, поэтому чужой pgvector на нём —
                # не экзотика, а норма для машины с двумя проектами. Compose в этом случае
                # падает на «port is already allocated», и совет «повтори вручную» негоден:
                # повтор упадёт так же. Подбираем свободный порт и пишем его в конфиг
                # ПРОЕКТА — там же его прочитает клиент памяти.
                $pr = Resolve-BcfMemoryPort -Wanted $script:MemPort -Container $script:MemContainer `
                                            -ProjectRoot $script:RepoRoot -HostName $script:MemHost
                if ($pr.Holder) {
                    $kind = if ($pr.HolderKind -eq 'container') { 'контейнер' } else { 'процесс' }
                    Write-Host "[memory] порт $($script:MemPort) занят: $kind '$($pr.Holder)' — это не наша база." -ForegroundColor Yellow
                }
                if ($pr.Error) {
                    Write-Host "[memory] ⚠ порт $($script:MemPort) занят и заменить его не вышло: $($pr.Error)" -ForegroundColor Red
                    Write-Host "[memory]    останови занявшего или впиши свободный port в $script:MemDbConfig" -ForegroundColor DarkGray
                    return $false
                }
                if ($pr.Changed) {
                    $script:MemPort = $pr.Port
                    Write-Host "[memory] беру свободный порт $($pr.Port) и записываю его в $($pr.ConfigPath)" -ForegroundColor Yellow
                }

                # Compose получает ИМЕННО то, что прочитает клиент. Без этих переменных он
                # брал свои дефолты, и адрес контейнера расходился с адресом клиента.
                $env:BCF_MEM_CONTAINER = $script:MemContainer
                $env:BCF_PG_PORT = "$($script:MemPort)"

                Write-Host "[memory] контейнер отсутствует — docker compose up -d ($script:MemCompose), порт $($script:MemPort)..." -ForegroundColor Yellow
                $up = Invoke-BcfDockerStreamed -DockerArgs @('compose', '-f', $script:MemCompose, 'up', '-d') -TimeoutSec 900 -Prefix '[memory]'
                if (-not $up.Ok) {
                    Write-Host "[memory] ⚠ docker compose up не отработал: $(($up.Err).Trim())" -ForegroundColor Red
                    # НЕ советуем повтор вслепую: если причина — занятый порт, повтор даст то
                    # же самое. Называем занявшего, а не действие.
                    $h2 = Get-BcfPortHolder -Port $script:MemPort
                    if ($h2.Kind -and -not ($h2.Kind -eq 'container' -and $h2.Name -eq $script:MemContainer)) {
                        Write-Host "[memory]    порт $($script:MemPort) держит $($h2.Kind) '$($h2.Name)' — повтор той же командой упадёт так же." -ForegroundColor DarkGray
                    } else {
                        Write-Host "[memory]    повтори вручную: docker compose -f `"$script:MemCompose`" up -d" -ForegroundColor DarkGray
                    }
                    return $false
                }
            } else {
                Write-Host "[memory] ⚠ контейнер отсутствует и compose-файл не найден ($script:MemCompose) — память недоступна." -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "[memory] контейнер в состоянии '$health' — жду перехода в healthy..." -ForegroundColor Yellow
        }

        # Поллинг health до таймаута.
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Seconds 2
            $health = Get-M13Health
        } while ($health -ne 'healthy' -and (Get-Date) -lt $deadline)
    }

    if ($health -ne 'healthy') {
        Write-Host "[memory] ⚠ pgvector не поднялся за ${TimeoutSec}s (state=$health) — цикл обучения ВЫКЛЮЧЕН. Запусти вручную: docker compose -f `"$script:MemCompose`" up -d" -ForegroundColor Red
        return $false
    }

    # ЖИВОЙ КОНТЕЙНЕР — ЕЩЁ НЕ НАШ АДРЕС.
    #
    # Наблюдалось: compose не смог привязать 5433 (порт держал чужой pgvector), контейнер
    # остался созданным, а следующий `docker start` поднял его БЕЗ публикации портов.
    # Состояние running + healthy, зелёная строка на экране — и клиент, уходящий на
    # localhost:5433 в чужую базу. Поэтому спрашиваем не «жив ли», а «слушает ли он там,
    # куда пойдёт клиент», и при расхождении пересоздаём на свободном порту.
    $pub = @(Get-BcfContainerHostPorts -Name $script:MemContainer)
    if ($pub -notcontains $script:MemPort) {
        $where = if ($pub.Count) { "опубликован на $($pub -join ', ')" } else { 'НЕ опубликован наружу вовсе' }
        Write-Host "[memory] контейнер '$($script:MemContainer)' жив, но $where, а клиент идёт на $($script:MemPort) — пересоздаю." -ForegroundColor Yellow

        $pr2 = Resolve-BcfMemoryPort -Wanted $script:MemPort -Container $script:MemContainer `
                                     -ProjectRoot $script:RepoRoot -HostName $script:MemHost
        if ($pr2.Holder) {
            $kind2 = if ($pr2.HolderKind -eq 'container') { 'контейнер' } else { 'процесс' }
            Write-Host "[memory] порт $($script:MemPort) занят: $kind2 '$($pr2.Holder)' — это не наша база." -ForegroundColor Yellow
        }
        if ($pr2.Changed) {
            $script:MemPort = $pr2.Port
            Write-Host "[memory] беру свободный порт $($pr2.Port) и записываю его в $($pr2.ConfigPath)" -ForegroundColor Yellow
        }
        # Данные лежат в примонтированном каталоге, а не в контейнере: пересоздание их не
        # трогает. Удаляем ТОЛЬКО контейнер с нашим именем.
        $null = Invoke-BcfDocker -DockerArgs @('rm', '-f', $script:MemContainer) -TimeoutSec 60
        $env:BCF_MEM_CONTAINER = $script:MemContainer
        $env:BCF_PG_PORT = "$($script:MemPort)"
        $up2 = Invoke-BcfDockerStreamed -DockerArgs @('compose', '-f', $script:MemCompose, 'up', '-d') -TimeoutSec 900 -Prefix '[memory]'
        if (-not $up2.Ok) {
            Write-Host "[memory] ⚠ пересоздать контейнер не вышло: $(($up2.Err).Trim())" -ForegroundColor Red
            return $false
        }
        $deadline2 = (Get-Date).AddSeconds($TimeoutSec)
        do {
            Start-Sleep -Seconds 2
            $health = Get-M13Health
        } while ($health -ne 'healthy' -and (Get-Date) -lt $deadline2)
        if ($health -ne 'healthy') {
            Write-Host "[memory] ⚠ пересозданный контейнер не стал healthy за ${TimeoutSec}s — цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
            return $false
        }
    }
    Write-Host "[memory] ✅ pgvector '$($script:MemContainer)' healthy, порт $($script:MemPort)." -ForegroundColor Green

    # Эмбеддинги (LM Studio) — вторая половина готовности памяти. Без неё recall/
    # upsert падают так же, как без pgvector. Оба должны быть живы.
    $embedOk = Ensure-LmStudioEmbedding
    if (-not $embedOk) {
        Write-Host "[memory] ⚠ pgvector есть, но эмбеддинги недоступны — цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
        return $false
    }

    # ГОТОВНОСТЬ ПОДТВЕРЖДАЕТСЯ ЗАПРОСОМ, А НЕ СУММОЙ ЗЕЛЁНЫХ ПРИЗНАКОВ.
    #
    # Здесь стояло безусловное «✅ векторная память готова». В том же прогоне doctor тут же
    # печатал «✗ недоступна»: контейнер был healthy, эмбеддинги живы, а клиент до базы не
    # доходил. Два вердикта на одном экране — это не косметика, это потеря доверия ко
    # всему выводу. Спрашиваем ровно то, чем пользуется харнесс: клиента.
    $probe = ''
    try { $probe = (& python $script:MemClient stats 2>&1 | Out-String).Trim() } catch { $probe = $_.Exception.Message }
    if ($probe -notmatch '\{') {
        Write-Host "[memory] ⚠ база и эмбеддинги живы, но КЛИЕНТ до памяти не доходит — цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
        Write-Host "[memory]    адрес: порт $($script:MemPort), конфиг $script:MemDbConfig" -ForegroundColor DarkGray
        if ($probe) {
            Write-Host ("[memory]    клиент сказал: " + (($probe -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ')) -ForegroundColor DarkGray
        }
        return $false
    }

    Write-Host "[memory] ✅ векторная память готова (pgvector + эмбеддинги + клиент) — цикл обучения АКТИВЕН (recall + retrospector + finding-gate)." -ForegroundColor Green
    return $true
}

function Inject-AntiPatterns {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$Iteration,
        [int]$TopK = 5,
        [double]$Threshold = 0.4
    )
    if (-not (Test-M13Available)) { return }

    # Контекст для recall = task brief + backpressure (если есть).
    $brief = "$TaskId iteration $Iteration"
    $tasksDir = if ($env:BCF_TASKS_DIR) { $env:BCF_TASKS_DIR } else { Join-Path $script:RepoRoot 'tasks' }
    $taskFile = Join-Path $tasksDir "$TaskId.md"
    if (Test-Path $taskFile) {
        $tcontent = Get-Content -Raw $taskFile
        if ($tcontent -match '(?ms)^##\s+1\.\s+.+?\r?\n(.+?)(?=^##|\z)') { $brief += "`n" + $Matches[1].Trim() }
    }
    $bp = ''
    if (Test-Path $StateFile) {
        $stxt = Get-Content -Raw $StateFile
        if ($stxt -match '(?s)BACKPRESSURE.*?(?=## evidence|\z)') { $bp = $Matches[0] }
    }
    $recallText = ($brief + "`n" + $bp).Substring(0, [Math]::Min(4000, ($brief + "`n" + $bp).Length))

    $iterId = "$TaskId-iter$Iteration-$(Get-Date -Format yyyyMMdd-HHmmss)"
    $recallJson = & python $script:MemClient recall `
        --text $recallText --scope code --k $TopK --threshold $Threshold `
        --iteration-id $iterId 2>$null
    if (-not $recallJson) { return }
    try { $hits = $recallJson | ConvertFrom-Json } catch { return }
    if (-not $hits -or @($hits).Count -eq 0) { return }

    # Собираем блок и кладём в начало STATE.md (агент читает первым шагом).
    $lines = @()
    $lines += "<known-anti-patterns source='agent_memory' scope='code' matched='$(@($hits).Count)'>"
    $lines += "Заметки из векторной памяти — типичные грабли, которые уже фиксировались на похожих задачах."
    $lines += "Не повторяй их; читай ``correct_alternative`` и применяй позитивную форму."
    $lines += ""
    foreach ($h in $hits) {
        $sim = [Math]::Round([double]$h.similarity, 2)
        $lines += "- [sim=$sim] $($h.trigger_summary)"
        if ($h.what_went_wrong)    { $lines += "    что пошло не так: $($h.what_went_wrong)" }
        if ($h.correct_alternative){ $lines += "    как надо: $($h.correct_alternative)" }
    }
    $lines += "</known-anti-patterns>"
    $lines += ""

    $original = if (Test-Path $StateFile) { Get-Content -Raw -LiteralPath $StateFile } else { '' }
    # Удаляем предыдущий блок (если был от прошлой итерации), чтобы не накапливать.
    $original = [regex]::Replace($original, '(?s)<known-anti-patterns[^>]*>.*?</known-anti-patterns>\r?\n?', '')
    $injected = ($lines -join "`n") + $original
    Set-Content -LiteralPath $StateFile -Value $injected -Encoding UTF8
    Write-Host "[memory] injected $(@($hits).Count) anti-patterns into STATE.md" -ForegroundColor DarkCyan
}

# Robust-извлечение верхнеуровневого JSON-объекта судьи (с "verdict") из вывода
# opencode. Терпит произвольную вложенность (assertions[]/cross_checks[]) и
# ```json-фенсы. Возвращает распарсенный объект или $null.
function Extract-JudgeJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Кандидаты: содержимое ```json ... ``` фенсов + весь текст как fallback.
    $candidates = @()
    foreach ($m in [regex]::Matches($Text, '(?s)```(?:json)?\s*(\{.*?\})\s*```')) {
        $candidates += $m.Groups[1].Value
    }
    $candidates += $Text

    foreach ($cand in $candidates) {
        $idx = $cand.IndexOf('"verdict"')
        if ($idx -lt 0) { continue }
        # Откатываемся к открывающей '{' перед "verdict".
        $start = $cand.LastIndexOf('{', $idx)
        if ($start -lt 0) { continue }
        # Brace-counting вперёд, игнорируя скобки внутри строк.
        $depth = 0; $inStr = $false; $esc = $false
        for ($i = $start; $i -lt $cand.Length; $i++) {
            $ch = $cand[$i]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq '"') { $inStr = $false }
                continue
            }
            if ($ch -eq '"') { $inStr = $true }
            elseif ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $json = $cand.Substring($start, $i - $start + 1)
                    try { return ($json | ConvertFrom-Json -ErrorAction Stop) } catch { break }
                }
            }
        }
    }
    return $null
}

function Run-Retrospector {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][string]$IterOutJsonl,
        [Parameter(Mandatory)][string]$VerdictFile,
        [string]$JudgeOutFile
    )
    if (-not (Test-M13Available)) { return $null }
    if (-not (Test-Path $script:Retrospector)) { return $null }

    # Сборка input.
    $transcript = if (Test-Path $IterOutJsonl) {
        $raw = Get-Content -Raw -LiteralPath $IterOutJsonl
        # Извлекаем человекочитаемое: message-text + tool descriptions
        $tlines = @()
        foreach ($ln in ($raw -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try {
                $ev = $ln | ConvertFrom-Json -ErrorAction Stop
                if ($ev.type -eq 'message' -and $ev.part.text) { $tlines += "[msg] " + [string]$ev.part.text }
                elseif ($ev.type -eq 'tool_use') {
                    $desc = [string]($ev.part.state.input.description)
                    if (-not $desc) { $desc = [string]($ev.part.tool) }
                    $tlines += "[tool] " + $desc
                }
            } catch { }
        }
        ($tlines -join "`n").Substring(0, [Math]::Min(8000, ($tlines -join "`n").Length))
    } else { '' }

    $verdictText = if (Test-Path $VerdictFile) { Get-Content -Raw -LiteralPath $VerdictFile } else { '' }
    $judgeText   = if ($JudgeOutFile -and (Test-Path $JudgeOutFile)) { Get-Content -Raw -LiteralPath $JudgeOutFile } else { '' }

    # Найдём inner judge JSON чтобы вытащить findings.
    # ВАЖНО: судья выдаёт глубоко вложенный JSON (assertions[]/cross_checks[]/
    # remediation[]). Регэксп с балансом на 1 уровень его не матчит → verdicts
    # пустой → ретро-судья годами писал "verdicts is empty". Берём robust-экстракцию:
    # сначала ```json-фенс, затем brace-counting от первого '{' перед "verdict".
    $jj = Extract-JudgeJson -Text $judgeText
    $findings = @()
    $verdicts = @()
    if ($jj) {
        $verdicts += @{ judge='judge'; verdict=$jj.verdict; notes=$jj.failing_criterion }
        if ($jj.remediation) {
            foreach ($r in @($jj.remediation)) {
                $sum = if ($r -is [string]) { $r } elseif ($r.summary) { $r.summary } else { ($r | ConvertTo-Json -Compress) }
                # verification='unverified' — честный статус ДО finding-gate. Хардкод
                # 'addressed in next iter diff' заставлял ретро-судью метить findings
                # как non_verifiable_dismiss/subagent_finding_ignored на ровном месте.
                $findings += @{ agent='judge'; finding_id="rem-$([Math]::Abs($sum.GetHashCode()))"; must_address=$true; severity='high'; summary=$sum; verification='unverified' }
            }
        }
    }

    $iterId = "$TaskId-iter$Iteration"
    $payload = @{
        iteration_id = $iterId
        transcript   = $transcript
        verdicts     = $verdicts
        findings     = $findings
        prior_memory = @()
    } | ConvertTo-Json -Depth 10

    $tmp = Join-Path $env:TEMP "memory-retro-$iterId.json"
    Set-Content -LiteralPath $tmp -Value $payload -Encoding UTF8
    $retroOut = Get-Content -Raw -LiteralPath $tmp | & pwsh -NoProfile -File $script:Retrospector 2>$null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $retroOut) { return $null }

    try { $parsed = $retroOut | ConvertFrom-Json } catch { return $null }

    # Сохраняем JSON ретроспективы внутри harness-каталога (.bcf/retros).
    $retroDir = if ($env:BCF_RETRO_DIR) { $env:BCF_RETRO_DIR } else { Join-Path $script:RepoRoot '.bcf/retros' }
    if (-not (Test-Path $retroDir)) { New-Item -ItemType Directory -Force -Path $retroDir | Out-Null }
    $retroFile = Join-Path $retroDir "$iterId-$(Get-Date -Format HHmmss).json"
    Set-Content -LiteralPath $retroFile -Value $retroOut -Encoding UTF8

    # Upsert anti-patterns в память.
    $upsertOut = $retroOut | & python $script:MemClient recall-from-retrospector 2>$null
    Write-Host "[memory] retrospector: $(@($parsed.root_causes).Count) root causes, $(@($parsed.proposals).Count) proposals; upsert: $upsertOut" -ForegroundColor DarkCyan
    return $parsed
}

function Invoke-FindingGate {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][string]$IterOutJsonl
    )
    if (-not (Test-Path $script:FindingGate)) { return 0 }
    # Git Bash явно: WSL bash не видит Windows-пути и Windows-python.
    # Discovery: env override, иначе `bash` из PATH (обычно Git-Bash).
    $gitBash = if ($env:BCF_BASH) { $env:BCF_BASH } else { (Get-Command bash -ErrorAction SilentlyContinue).Source }
    if (-not $gitBash -or -not (Test-Path $gitBash)) { return 0 }

    $repo = $script:RepoRoot

    # Транскрипт текущего opencode-run может содержать verbal dismiss'ы
    # ("...fix deferred...") — гейт ловит это через findings.json + diff.patch.
    $iterDir = Join-Path $env:TEMP "memory-iter-$TaskId-$Iteration"
    if (Test-Path $iterDir) { Remove-Item -Recurse -Force $iterDir }
    New-Item -ItemType Directory -Force -Path $iterDir | Out-Null

    # Diff: working-tree vs HEAD. Если пусто (агент закоммитил или iter no-op) —
    # fallback на cumulative diff последних 5 коммитов. Это устраняет «BLOCK после
    # коммита фикса» — keywords могут жить уже в HEAD, а не в working-tree.
    $diff = & git -C $repo diff HEAD 2>$null
    if (-not $diff -or ($diff -join '').Trim() -eq '') {
        $diff = & git -C $repo log -p -n 5 HEAD 2>$null
    }
    Set-Content -LiteralPath (Join-Path $iterDir 'diff.patch') -Value ($diff -join "`n") -Encoding UTF8

    # findings — из предыдущего verdict-файла (must_address rem-* items).
    $verifyDir = if ($env:BCF_VERIFY_DIR) { $env:BCF_VERIFY_DIR } else { Join-Path $repo '.bcf/verify' }
    $prevVerdict = Join-Path $verifyDir "$TaskId-judge.out.txt"
    if (Test-Path $prevVerdict) {
        $jt = Get-Content -Raw -LiteralPath $prevVerdict
        # Robust-экстракция (см. Extract-JudgeJson): старый 1-уровневый регэксп не
        # матчил вложенный JSON судьи → findings.json не писался → finding-gate
        # молча пропускал (return 0), и агента никогда не заставляли закрывать
        # remediation. Это поддерживало спираль наравне с пустыми verdicts в ретро.
        $jj = Extract-JudgeJson -Text $jt
        if ($jj) {
            $findings = @()
            if ($jj.remediation) {
                foreach ($r in @($jj.remediation)) {
                    $sum = if ($r -is [string]) { $r } elseif ($r.summary) { $r.summary } else { ($r | ConvertTo-Json -Compress) }
                    $findings += @{
                        agent='judge';
                        finding_id="prev-rem-$([Math]::Abs($sum.GetHashCode()))";
                        must_address=$true;
                        severity='high';
                        summary=$sum;
                        verification=$sum
                    }
                }
            }
            if ($findings.Count -gt 0) {
                Set-Content -LiteralPath (Join-Path $iterDir 'findings.json') -Value ($findings | ConvertTo-Json -Depth 5) -Encoding UTF8
            }
        }
    }

    if (-not (Test-Path (Join-Path $iterDir 'findings.json'))) { Remove-Item -Recurse -Force $iterDir; return 0 }

    $env:BCF_ITERATION_DIR = ($iterDir -replace '\\','/')
    $gateOut = & $gitBash ($script:FindingGate -replace '\\','/') 2>&1
    $code = $LASTEXITCODE
    Remove-Item env:BCF_ITERATION_DIR -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $iterDir -ErrorAction SilentlyContinue

    if ($code -eq 127) {
        # exit 127 — tooling failure (python/jq не найдены), не настоящий BLOCK.
        Write-Host "[memory] finding-gate tooling failure (exit 127) on iter ${Iteration} — гейт пропустил, не блокируем loop." -ForegroundColor DarkYellow
        Write-Host $gateOut -ForegroundColor DarkYellow
        return 0
    }
    if ($code -ne 0) {
        Write-Host "[memory] finding-gate BLOCK on iter ${Iteration}:" -ForegroundColor Yellow
        Write-Host $gateOut -ForegroundColor Yellow
    }
    return $code
}
