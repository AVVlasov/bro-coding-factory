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
# Конфиг памяти: проектный переопределяет фабричный, если проекту нужна своя база.
$script:MemDbConfig  = if ($env:BCF_MEM_CONFIG) { $env:BCF_MEM_CONFIG }
                       elseif (Test-Path (Join-Path $script:RepoRoot 'config/memory.config.json')) { Join-Path $script:RepoRoot 'config/memory.config.json' }
                       else { Join-Path $script:HomeRoot 'memory/memory.config.json' }

# Имя контейнера: из memory.config.json (ключ 'container'), иначе дефолт.
$script:MemContainer = 'bcf-agent-memory'
if (Test-Path $script:MemDbConfig) {
    try {
        $__memCfg = Get-Content -Raw -LiteralPath $script:MemDbConfig | ConvertFrom-Json
        if ($__memCfg.container) { $script:MemContainer = "$($__memCfg.container)" }
    } catch { }
}

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
        & lms server start 2>&1 | Out-Null
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
    Write-Host "[memory] эмбеддинг-модель '$model' не загружена — lms load..." -ForegroundColor Yellow
    & lms load $model --yes 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 2
        $psOut = (& lms ps 2>$null | Out-String)
    } while (($psOut -notmatch [regex]::Escape($model)) -and (Get-Date) -lt $deadline)

    if ($psOut -match [regex]::Escape($model)) {
        Write-Host "[memory] ✅ эмбеддинг-модель '$model' загружена." -ForegroundColor Green
        return $true
    }
    Write-Host "[memory] ⚠ не удалось загрузить '$model' за ${TimeoutSec}s — recall/upsert будут падать. Загрузи вручную: lms load $model" -ForegroundColor Red
    return $false
}

function Get-M13Health {
    # 'healthy'|'starting'|'unhealthy'|'stopped'|'absent'|'no-daemon'|'no-docker'.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'no-docker' }
    # Демон (Docker Desktop) поднят? `docker version` падает быстро если нет.
    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return 'no-daemon' }
    $state = (& docker inspect -f '{{.State.Status}}' $script:MemContainer 2>$null | Out-String).Trim()
    if (-not $state) { return 'absent' }
    if ($state -ne 'running') { return 'stopped' }
    $h = (& docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $script:MemContainer 2>$null | Out-String).Trim()
    if ($h -eq 'none') { return 'healthy' }   # без healthcheck — running считаем healthy
    return $h                                  # healthy | starting | unhealthy
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

    if ($health -ne 'healthy') {
        if ($health -eq 'stopped') {
            Write-Host "[memory] контейнер '$($script:MemContainer)' остановлен — docker start..." -ForegroundColor Yellow
            & docker start $script:MemContainer 2>&1 | Out-Null
        } elseif ($health -eq 'absent') {
            if (Test-Path $script:MemCompose) {
                Write-Host "[memory] контейнер отсутствует — docker compose up -d ($script:MemCompose)..." -ForegroundColor Yellow
                & docker compose -f $script:MemCompose up -d 2>&1 | Out-Null
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
    Write-Host "[memory] ✅ pgvector '$($script:MemContainer)' healthy." -ForegroundColor Green

    # Эмбеддинги (LM Studio) — вторая половина готовности памяти. Без неё recall/
    # upsert падают так же, как без pgvector. Оба должны быть живы.
    $embedOk = Ensure-LmStudioEmbedding
    if (-not $embedOk) {
        Write-Host "[memory] ⚠ pgvector есть, но эмбеддинги недоступны — цикл обучения ВЫКЛЮЧЕН." -ForegroundColor Red
        return $false
    }

    Write-Host "[memory] ✅ векторная память готова (pgvector + эмбеддинги) — цикл обучения АКТИВЕН (recall + retrospector + finding-gate)." -ForegroundColor Green
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
