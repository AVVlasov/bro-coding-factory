# backends.ps1 — каталог кодовых CLI-агентов и живая проверка их проводки.
#
# ЧТО ЗДЕСЬ ВАЖНО И ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ФАЙЛ.
#
# Дефекты этого слоя МОЛЧАЛИВЫ. Неавторизованный бэкенд отвечает штатным событием, а не
# падением: снаружи это выглядит как пустой ответ модели, и обвязка спокойно записывает
# «агент ничего не сделал». Поэтому проверка здесь двухступенчатая — сначала бесплатный
# `auth status`, и только потом настоящий запрос.
#
# Три свойства бэкенда, которые влияют на РОЛИ, а не на удобство:
#
#   ro          есть ли песочница «только чтение». Роль, обязанная лишь смотреть
#               (критик, ресёрчер), на бэкенде без неё получает право писать — и
#               однажды что-нибудь поправит «по пути».
#   tokens      видно ли расход токенов в потоке. Если нет, бюджетный ограничитель на
#               этой роли слеп: узлы выглядят нулевыми, и потолок «до исчерпания»
#               не сработает никогда.
#   env         переменные, без которых бэкенд не авторизован. Windows не пробрасывает
#               переменные в уже запущенные процессы: харнесс, стартовавший до выдачи
#               токена, видит «не авторизован» при полностью исправной учётке.

$script:BcfBackends = [ordered]@{

    claude = @{
        bin = 'claude'
        command = 'claude -p --output-format stream-json --verbose --permission-mode acceptEdits --model {model}'
        format = 'claude'
        env = @('CLAUDE_CODE_OAUTH_TOKEN')
        probeModel = 'sonnet'
        authCheck = 'claude auth status'
        authOkPattern = '"loggedIn"\s*:\s*true'
        ro = $false
        tokens = $true
        note = 'Окно Claude Code может отвечать при полностью неавторизованном CLI: десктоп держит учётку у себя и отдаёт встроенной сессии, а харнесс порождает отдельный процесс. Верить только auth status.'
    }

    opencode = @{
        bin = 'opencode'
        command = 'opencode run --dangerously-skip-permissions --thinking --format json --model {model}'
        format = 'opencode'
        env = @()
        probeModel = ''
        authCheck = ''
        authOkPattern = ''
        ro = $false
        tokens = $true
        note = 'Провайдер-агностик: ключ провайдера берётся из окружения (например MINIMAX_API_KEY).'
    }

    codex = @{
        bin = 'codex'
        command = 'codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -m {model}'
        format = 'codex'
        env = @()
        probeModel = ''
        authCheck = ''
        authOkPattern = ''
        ro = $false
        tokens = $true
        note = 'Бинарь часто НЕ на PATH: лежит внутри установки приложения, и путь содержит хэш сборки — после обновления он меняется. bcf doctor находит его и предлагает закрепить обёрткой.'
        binHints = @(
            '$env:LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe'
            '$env:LOCALAPPDATA\Programs\codex\codex.exe'
        )
    }

    'codex-ro' = @{
        bin = 'codex'
        command = 'codex exec --json --skip-git-repo-check -s read-only -m {model}'
        format = 'codex'
        env = @()
        probeModel = ''
        authCheck = ''
        authOkPattern = ''
        ro = $true
        tokens = $true
        note = 'Тот же codex, но песочница только на чтение — для критиков и ресёрчера.'
        aliasOf = 'codex'
    }

    cursor = @{
        bin = 'cursor-agent'
        command = 'cursor-agent -p --output-format stream-json --force --trust --model {model}'
        format = 'cursor'
        env = @()
        probeModel = ''
        authCheck = 'cursor-agent status'
        authOkPattern = 'Logged in as'
        ro = $false
        tokens = $false
        note = 'В потоке НЕТ события о расходе токенов: узлы этого бэкенда для бюджета нулевые. На цикл «до исчерпания» ставить нельзя, на разовую роль — можно.'
    }

    gemini = @{
        bin = 'gemini'
        command = 'gemini --yolo -m {model} -p'
        format = 'text'
        env = @('GEMINI_API_KEY')
        probeModel = ''
        authCheck = ''
        authOkPattern = ''
        ro = $false
        tokens = $false
        note = 'Вывод текстовый: расход считается по длине ответа, погрешность до 15%.'
    }

    aider = @{
        bin = 'aider'
        command = 'aider --yes --no-auto-commits --model {model} --message'
        format = 'text'
        env = @()
        probeModel = ''
        authCheck = ''
        authOkPattern = ''
        ro = $false
        tokens = $false
        note = 'Вывод текстовый: расход считается по длине ответа.'
    }
}

function Get-BcfKnownBackends { return $script:BcfBackends }

# --- КАКОЙ МОДЕЛЬЮ ЭТОТ CLI РАБОТАЕТ УЖЕ СЕЙЧАС -----------------------------------------
#
# Мастер оставлял graph.roles.<роль>.model пустым и тут же объявлял это стопором: «узел без
# модели падает на старте». То есть init сам создавал себе блокирующую проблему и
# спрашивал человека о том, что лежит у него на диске: у codex выбранная модель записана в
# ~/.codex/config.toml, у opencode — в конфиге либо в истории его собственных сессий.
#
# Спрашивать очевидное — не вежливость, а перекладывание работы. Поэтому: сначала смотрим
# сами, спрашиваем только то, чего не нашли, и ВСЕГДА называем источник — из настройки,
# из окружения или из истории. Источник важен: «взяли из истории» человек может отменить
# осознанно, а «взяли неизвестно откуда» он вынужден перепроверять целиком.

function _BcfCodexConfiguredModel {
    $cfg = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\config.toml'
    if (-not (Test-Path $cfg)) { return '' }
    try {
        foreach ($line in (Get-Content -LiteralPath $cfg -ErrorAction Stop)) {
            # Только верхний уровень: `model = "..."` внутри [profiles.*] относится к
            # профилю, а не к тому, чем codex поедет без флагов.
            if ($line -match '^\s*\[') { break }
            if ($line -match '^\s*model\s*=\s*"([^"]+)"') { return $Matches[1] }
        }
    } catch { }
    return ''
}

function _BcfOpencodeConfiguredModel {
    foreach ($p in @(
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\opencode\opencode.jsonc'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\opencode\opencode.json'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.opencode.json')
    )) {
        if (-not (Test-Path $p)) { continue }
        try {
            $raw = Get-Content -Raw -LiteralPath $p
            $raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')   # jsonc: строчные комментарии
            $j = $raw | ConvertFrom-Json
            if ($j.model) { return [string]$j.model }
        } catch { }
    }
    return ''
}

# Последняя модель, которой человек РЕАЛЬНО работал в opencode. Лежит в его sqlite-базе
# сессий; читаем строго на чтение и только если есть python — своей зависимости ради
# одной подсказки заводить не станем.
function _BcfOpencodeLastUsedModel {
    $db = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local\share\opencode\opencode.db'
    if (-not (Test-Path $db)) { return '' }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { return '' }
    $py = @'
import json, sqlite3, sys, collections
db = sys.argv[1]
for uri in ("file:%s?mode=ro" % db.replace("?", "%3f"), "file:%s?mode=ro&immutable=1" % db.replace("?", "%3f")):
    try:
        c = sqlite3.connect(uri, uri=True, timeout=2)
        seen = collections.Counter()
        for (d,) in c.execute("select data from message order by rowid desc limit 60"):
            try: j = json.loads(d)
            except Exception: continue
            p, m = j.get("providerID"), j.get("modelID")
            if p and m: seen["%s/%s" % (p, m)] += 1
        if seen:
            print(seen.most_common(1)[0][0])
        break
    except Exception:
        continue
'@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bcf-oc-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    try {
        Set-Content -LiteralPath $tmp -Value $py -Encoding UTF8
        $out = (& python $tmp $db 2>$null | Out-String).Trim()
        if ($out -match '^[\w.\-]+/[\w.\-]+$') { return $out }
    } catch { } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return ''
}

function Get-BcfBackendDefaultModel {
    param([Parameter(Mandatory)][string]$Name)

    $b = $script:BcfBackends[$Name]
    $key = if ($b -and $b.aliasOf) { $b.aliasOf } else { $Name }

    switch ($key) {
        'codex' {
            $m = _BcfCodexConfiguredModel
            if ($m) { return [pscustomobject]@{ Model = $m; Source = 'настройка codex' } }
        }
        'opencode' {
            if ($env:OPENCODE_MODEL) { return [pscustomobject]@{ Model = $env:OPENCODE_MODEL; Source = 'окружение' } }
            $m = _BcfOpencodeConfiguredModel
            if ($m) { return [pscustomobject]@{ Model = $m; Source = 'настройка opencode' } }
            $m = _BcfOpencodeLastUsedModel
            if ($m) { return [pscustomobject]@{ Model = $m; Source = 'история opencode' } }
        }
    }
    return [pscustomobject]@{ Model = ''; Source = '' }
}

function Resolve-BcfBackendBinary {
    param([Parameter(Mandatory)][string]$Name)

    $b = $script:BcfBackends[$Name]
    if (-not $b) { return $null }

    $cmd = Get-Command $b.bin -ErrorAction SilentlyContinue
    if ($cmd) { return [pscustomobject]@{ Path = $cmd.Source; OnPath = $true } }

    foreach ($hint in @($b.binHints)) {
        if (-not $hint) { continue }
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($hint)
        $hit = Get-ChildItem -Path $expanded -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Path = $hit.FullName; OnPath = $false } }
    }
    return $null
}

function Get-BcfBackendVersion {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($flag in @('--version', '-v', 'version')) {
        try {
            $o = (& $Path $flag 2>&1 | Out-String).Trim()
            if ($o -and $o -match '(\d+\.\d+[\.\d]*)') { return $Matches[1] }
        } catch { }
    }
    return ''
}

# Проверка авторизации без единого потраченного токена. Переменные окружения
# пробрасываются в дочерний процесс явно: без этого проверка врёт ровно так же, как врал
# бы прогон.
function Test-BcfBackendAuth {
    param([Parameter(Mandatory)][string]$Name)

    $b = $script:BcfBackends[$Name]
    if (-not $b -or -not $b.authCheck) { return [pscustomobject]@{ Known = $false; Ok = $true; Detail = '' } }

    $pre = ''
    foreach ($n in @($b.env)) {
        if (-not $n) { continue }
        $v = [Environment]::GetEnvironmentVariable($n)
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'User') }
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'Machine') }
        if ($v) { $pre += "`$env:$n='$($v -replace "'", "''")';" }
    }
    $out = ''
    try { $out = (& pwsh -NoProfile -NonInteractive -Command "$pre $($b.authCheck)" 2>&1 | Out-String) } catch { $out = $_.Exception.Message }
    $ok = (-not $b.authOkPattern) -or ($out -match $b.authOkPattern)
    $detail = (($out -replace '\s+', ' ')).Trim()
    if ($detail.Length -gt 140) { $detail = $detail.Substring(0, 140) + '…' }
    return [pscustomobject]@{ Known = $true; Ok = $ok; Detail = $detail }
}

# Опрос всех известных бэкендов. Без запросов к моделям: это шаг «что вообще стоит в
# системе», а не «работает ли модель». Живая проба — в bcf doctor.
function Invoke-BcfBackendSurvey {
    $rows = @()
    foreach ($name in $script:BcfBackends.Keys) {
        $b = $script:BcfBackends[$name]
        if ($b.aliasOf) { continue }        # codex-ro проверяется вместе с codex
        $bin = Resolve-BcfBackendBinary -Name $name
        if (-not $bin) {
            $rows += [pscustomobject]@{ Name = $name; Installed = $false; Path = ''; OnPath = $false
                                        Version = ''; Auth = 'нет бинаря'; AuthOk = $false
                                        Ro = $b.ro; Tokens = $b.tokens; Note = '' }
            continue
        }
        $ver = Get-BcfBackendVersion -Path $bin.Path
        $auth = Test-BcfBackendAuth -Name $name
        $authText = if (-not $auth.Known) { 'проверки нет' } elseif ($auth.Ok) { 'ок' } else { 'НЕ АВТОРИЗОВАН' }
        $rows += [pscustomobject]@{
            Name = $name; Installed = $true; Path = $bin.Path; OnPath = $bin.OnPath
            Version = $ver; Auth = $authText; AuthOk = ((-not $auth.Known) -or $auth.Ok)
            Ro = $b.ro; Tokens = $b.tokens; Note = $b.note; AuthDetail = $auth.Detail
        }
    }
    return $rows
}

# Сборка секции graph.backends для config/harness.json по результатам опроса.
# Команда с абсолютным путём пишется только тогда, когда бинаря нет на PATH: хэш сборки
# в пути меняется после обновления приложения, и закреплять его без нужды — значит
# заложить поломку на следующее обновление.
function New-BcfBackendConfig {
    param([Parameter(Mandatory)][object[]]$Survey)

    $out = [ordered]@{}
    foreach ($r in $Survey) {
        if (-not $r.Installed) { continue }
        foreach ($name in @($r.Name) + @($script:BcfBackends.Keys | Where-Object { $script:BcfBackends[$_].aliasOf -eq $r.Name })) {
            $b = $script:BcfBackends[$name]
            $cmd = $b.command
            if (-not $r.OnPath) { $cmd = "& '$($r.Path)' " + ($cmd -replace "^$([regex]::Escape($b.bin))\s+", '') }
            $entry = [ordered]@{ command = $cmd; format = $b.format }
            if ($b.env.Count)     { $entry.env = @($b.env) }
            if ($b.probeModel)    { $entry.probeModel = $b.probeModel }
            if ($b.authCheck)     { $entry.authCheck = $b.authCheck; $entry.authOkPattern = $b.authOkPattern }
            $out[$name] = $entry
        }
    }
    return $out
}
