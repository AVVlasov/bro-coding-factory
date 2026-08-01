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

    try {
        $pipes = [System.IO.Directory]::GetFiles('\\.\pipe\')
    } catch {
        # Перечислить каналы не вышло — не выдумываем ответ и не рискуем зависанием.
        return $false
    }
    foreach ($p in $pipes) {
        $n = [IO.Path]::GetFileName($p)
        if ($n -eq 'dockerDesktopLinuxEngine' -or $n -eq 'dockerDesktopEngine' -or $n -eq 'docker_engine') {
            return $true
        }
    }
    return $false
}

# Вызов docker с жёстким потолком времени. Нужен там, где демон уже отвечает: даже живой
# docker inspect может залипнуть на переключении контекста, а прогон, молчащий минутами,
# неотличим от сломанного.
function Invoke-BcfDocker {
    param([Parameter(Mandatory)][string[]]$DockerArgs, [int]$TimeoutSec = 15)

    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath 'docker' -ArgumentList $DockerArgs -NoNewWindow -PassThru `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }
            return @{ Ok = $false; Out = ''; TimedOut = $true }
        }
        $text = ''
        if (Test-Path $out) { $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) }
        return @{ Ok = ($p.ExitCode -eq 0); Out = [string]$text; TimedOut = $false }
    } catch {
        return @{ Ok = $false; Out = ''; TimedOut = $false }
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}
