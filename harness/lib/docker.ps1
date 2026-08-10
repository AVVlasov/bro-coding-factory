# docker.ps1 — безопасная проба Docker.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ РАДИ ОДНОЙ ПРОВЕРКИ. В коде было написано так:
#
#     # Демон (Docker Desktop) поднят? `docker version` падает быстро если нет.
#     & docker version --format '{{.Server.Version}}'
#
# На Windows это неверно, и цена ошибки высокая. Если Docker Desktop установлен, но не
# запущен, docker.exe НЕ падает — он ЗАПУСКАЕТ Docker Desktop и ждёт его готовности.
# Наблюдалось: `bcf run queue` висел больше шести минут, не напечатав ни строки, поднял
# Docker Desktop на машине человека и вывесил поверх всего его диалог об ошибке. Снаружи
# это выглядит как намертво зависший прогон, причём зависший ещё до первой задачи.
#
# Именованный канал демона существует ровно тогда, когда демон уже слушает. Проверка по
# каналу отвечает мгновенно и, главное, НИЧЕГО НЕ ЗАПУСКАЕТ.

function Test-BcfDockerDaemon {
    # $true — демон отвечает; $false — не запущен (или docker не установлен).
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }

    if ($IsWindows -eq $false) {
        # На Linux/macOS docker действительно падает быстро: сокета нет — ошибка сразу,
        # автозапуска демона из клиента там не происходит.
        & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    # Куда ПОЙДЁТ следующая команда docker — решает не список каналов, а активный
    # контекст. Каналы неактивных движков публикуются тоже (проверено: при активном
    # desktop-linux рядом живут dockerDesktopEngine и dockerDesktopWindowsEngine), поэтому
    # «какой-то канал есть» не значит «тот самый демон отвечает». Спрашиваем адрес.
    $endpoint = $env:DOCKER_HOST
    if (-not $endpoint) {
        try {
            $cfg = Join-Path $env:USERPROFILE '.docker\config.json'
            $ctxName = ''
            if (Test-Path $cfg) {
                $j = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Json
                if ($j.currentContext) { $ctxName = [string]$j.currentContext }
            }
            if ($ctxName -and $ctxName -ne 'default') {
                # Метаданные контекста лежат в каталоге, имя которого — sha256 от имени.
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ctxName)) |
                         ForEach-Object { $_.ToString('x2') }) -join ''
                $meta = Join-Path $env:USERPROFILE ".docker\contexts\meta\$hash\meta.json"
                if (Test-Path $meta) {
                    $m = Get-Content -Raw -LiteralPath $meta | ConvertFrom-Json
                    if ($m.Endpoints -and $m.Endpoints.docker -and $m.Endpoints.docker.Host) {
                        $endpoint = [string]$m.Endpoints.docker.Host
                    }
                }
            }
        } catch { }
    }

    if ($endpoint -and $endpoint -notlike 'npipe:*') {
        # Удалённый демон (tcp/ssh) каналом не проверить. Спрашиваем сам docker, но
        # ОБЯЗАТЕЛЬНО с потолком времени: автозапуск Desktop здесь не грозит, а вот
        # висящее сетевое подключение — вполне.
        $r = Invoke-BcfDocker -DockerArgs @('version', '--format', '{{.Server.Version}}') -TimeoutSec 8
        return [bool]$r.Ok
    }

    # npipe:////./pipe/dockerDesktopLinuxEngine -> dockerDesktopLinuxEngine
    $wanted = ''
    if ($endpoint -like 'npipe:*') { $wanted = ($endpoint -replace '.*[\\/]', '') }

    try {
        $pipes = [System.IO.Directory]::GetFiles('\\.\pipe\')
    } catch {
        # Перечислить каналы не вышло — не выдумываем ответ и не рискуем зависанием.
        return $false
    }
    foreach ($p in $pipes) {
        $n = [IO.Path]::GetFileName($p)
        if ($wanted) {
            if ($n -eq $wanted) { return $true }
        } elseif ($n -eq 'dockerDesktopLinuxEngine' -or $n -eq 'dockerDesktopEngine' -or $n -eq 'docker_engine') {
            return $true
        }
    }
    return $false
}

# Вызов docker с жёстким потолком времени. Нужен там, где демон уже отвечает: даже живой
# docker inspect может залипнуть на переключении контекста, а прогон, молчащий минутами,
# неотличим от сломанного.
# Аргументы с пробелами ОБЯЗАНЫ быть в кавычках: Start-Process отдаёт их через командную
# строку Windows и сам не экранирует. Без этого `--format '{{.Names}} {{.State}}'` уезжает
# двумя аргументами, docker падает на разборе за доли секунды и отвечает «accepts no
# arguments» — снаружи неотличимо от «демон не ответил». Тот же дефект уже ловили в
# клиенте памяти (см. _GMemPython в graph-memory.ps1), и он повторяется всюду, где
# Start-Process зовут с готовым списком.
function _BcfQuoteArgs {
    param([string[]]$A)
    return @($A | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
}

function Invoke-BcfDocker {
    param([Parameter(Mandatory)][string[]]$DockerArgs, [int]$TimeoutSec = 15)

    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList (_BcfQuoteArgs $DockerArgs) -NoNewWindow -PassThru `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            return @{ Ok = $false; Out = ''; Err = "не ответил за ${TimeoutSec}с"; TimedOut = $true }
        }
        $text = ''
        if (Test-Path $out) { $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) }
        # stderr ВОЗВРАЩАЕМ, а не выбрасываем. Пока он молча удалялся в finally, вызывающий
        # не мог напечатать настоящую причину отказа и подставлял свою — «не поднялся за
        # 45с» вместо «нет доступа к реестру» или «порт занят».
        $e = ''
        if (Test-Path $err) { $e = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) }
        # Приводим ЯВНО. Get-Content -Raw на пустом файле не возвращает пустую строку — он
        # не возвращает ничего, и поле уезжает в $null. Вызывающий делает .Trim() на
        # причине отказа и падает ровно там, где пытался её напечатать.
        if ($null -eq $text) { $text = '' }
        if ($null -eq $e) { $e = '' }
        return @{ Ok = ($p.ExitCode -eq 0); Out = "$text"; Err = "$e"; TimedOut = $false }
    } catch {
        return @{ Ok = $false; Out = ''; Err = $_.Exception.Message; TimedOut = $false }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# --- КТО ДЕРЖИТ ПОРТ --------------------------------------------------------------------
#
# Дефект, ради которого это написано: `docker compose up` на занятом порту падает строкой
# «Bind for 0.0.0.0:5433 failed: port is already allocated», а вызывающий печатал
# «повтори вручную». Повтор упал бы так же — то есть совет был заведомо негодным, а
# настоящая причина (ЧУЖОЙ контейнер на нашем порту) не называлась вовсе. Порт по
# умолчанию один на все установки фабрики, поэтому вторая установка на той же машине
# гарантированно приезжает в это место.
#
# Спрашиваем ДО запуска и отвечаем именем занявшего: имя — единственное, с чем человек
# может что-то сделать.

function Get-BcfDockerPortMap {
    # порт (int) → имя контейнера. Один вызов docker на все проверки: перебор портов по
    # одному вызову на порт превращает подбор свободного в десяток запусков docker.
    $map = @{}
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $map }
    if (-not (Test-BcfDockerDaemon)) { return $map }
    $r = Invoke-BcfDocker -DockerArgs @('ps', '--format', '{{.Names}}|{{.Ports}}') -TimeoutSec 15
    if (-not $r.Ok) { return $map }
    foreach ($line in (($r.Out -split "`r?`n") | Where-Object { $_.Trim() })) {
        $parts = $line -split '\|', 2
        if ($parts.Count -lt 2) { continue }
        $name = $parts[0].Trim()
        foreach ($m in [regex]::Matches($parts[1], ':(\d+)->')) {
            $p = [int]$m.Groups[1].Value
            if (-not $map.ContainsKey($p)) { $map[$p] = $name }
        }
    }
    return $map
}

function Get-BcfPortHolder {
    param([Parameter(Mandatory)][int]$Port, [hashtable]$PortMap)

    $map = if ($null -ne $PortMap) { $PortMap } else { Get-BcfDockerPortMap }
    if ($map.ContainsKey($Port)) {
        return [pscustomobject]@{ Kind = 'container'; Name = [string]$map[$Port] }
    }
    # Порт может держать и обычный процесс — свой postgres, туннель, чужая сборка. Для
    # человека разница существенная: контейнер останавливают, процесс убивают.
    try {
        $conn = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) | Select-Object -First 1
        if ($conn) {
            $name = "pid $($conn.OwningProcess)"
            try { $name = (Get-Process -Id $conn.OwningProcess -ErrorAction Stop).ProcessName } catch { }
            return [pscustomobject]@{ Kind = 'process'; Name = $name }
        }
    } catch { }
    return [pscustomobject]@{ Kind = ''; Name = '' }
}

# НА КАКИЕ ПОРТЫ ХОСТА ОПУБЛИКОВАН КОНТЕЙНЕР.
#
# Наблюдалось живьём: compose не смог привязать 0.0.0.0:5433 (порт держал чужой pgvector),
# контейнер остался СОЗДАННЫМ, а следующий `docker start` поднял его вообще без публикации
# портов. Снаружи всё зелено — `running`, `healthy`, — а клиент идёт на localhost:5433 и
# попадает в ЧУЖУЮ базу. Живой контейнер, отвечающий не по тому адресу, хуже упавшего:
# упавший виден.
function Get-BcfContainerHostPorts {
    param([Parameter(Mandatory)][string]$Name)

    $ports = @()
    $r = Invoke-BcfDocker -DockerArgs @('inspect', '-f', '{{json .NetworkSettings.Ports}}', $Name) -TimeoutSec 15
    if (-not $r.Ok) { return $ports }
    try {
        $j = ([string]$r.Out).Trim() | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            foreach ($b in @($p.Value)) {
                if ($b -and $b.HostPort) { $ports += [int]$b.HostPort }
            }
        }
    } catch { }
    return @($ports | Select-Object -Unique)
}

function Test-BcfPortFree {
    param([Parameter(Mandatory)][int]$Port)
    # Проба привязкой, а не опросом списков: списки отвечают на «кто слушает сейчас», а
    # нам нужно «сможет ли контейнер встать». Это разные ответы при чужих правах на порт.
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch { return $false } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Find-BcfFreePort {
    param([Parameter(Mandatory)][int]$From, [int]$Tries = 40)
    $map = Get-BcfDockerPortMap
    for ($p = $From; $p -lt ($From + $Tries); $p++) {
        if ($p -gt 65535) { break }
        if ($map.ContainsKey($p)) { continue }
        if (Test-BcfPortFree -Port $p) { return $p }
    }
    return 0
}

# Долгая операция docker, ход которой ВИДНО. Для compose up и pull: они идут минутами, и
# потолок времени тут не решение — решение показывать, что происходит. Прогон, молчащий
# пять минут, неотличим от зависшего, и именно так его и воспринимают.
function Invoke-BcfDockerStreamed {
    param([Parameter(Mandatory)][string[]]$DockerArgs, [int]$TimeoutSec = 900, [string]$Prefix = '[docker]')

    $log = [IO.Path]::GetTempFileName()
    $elog = "$log.err"
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList (_BcfQuoteArgs $DockerArgs) -NoNewWindow -PassThru `
                           -RedirectStandardOutput $log -RedirectStandardError $elog
        $shown = 0
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 700
            try {
                $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
                for ($i = $shown; $i -lt $lines.Count; $i++) { Write-Host "  $Prefix $($lines[$i])" -ForegroundColor DarkGray }
                $shown = $lines.Count
            } catch { }
            if ((Get-Date) -gt $deadline) {
                try { $p.Kill($true) } catch { }
                return @{ Ok = $false; Err = "не завершилось за ${TimeoutSec}с"; TimedOut = $true }
            }
        }
        $p.WaitForExit()
        $e = ''
        if (Test-Path $elog) { $e = (Get-Content -LiteralPath $elog -Raw -ErrorAction SilentlyContinue) }
        # У compose ход работы идёт в stderr — это не ошибка, а прогресс. Печатаем его,
        # чтобы человек видел загрузку образа, а не пустой экран.
        foreach ($l in (($e -split "`r?`n") | Where-Object { $_.Trim() })) {
            Write-Host "  $Prefix $l" -ForegroundColor DarkGray
        }
        return @{ Ok = ($p.ExitCode -eq 0); Err = [string]$e; TimedOut = $false }
    } catch {
        return @{ Ok = $false; Err = $_.Exception.Message; TimedOut = $false }
    } finally {
        Remove-Item $log, $elog -Force -ErrorAction SilentlyContinue
    }
}
