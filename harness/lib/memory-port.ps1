# memory-port.ps1 — порт векторной памяти, который не спорит с соседями.
#
# ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ПРОВЕРКА НА МЕСТЕ.
#
# Порт 5433 записан дефолтом и в memory/memory.config.json, и в docker-compose.yml. Это
# значит, что ВТОРАЯ установка фабрики на той же машине — или любой другой pgvector,
# поднятый соседним проектом, — гарантированно занимает наш порт. Наблюдалось живьём:
# `bcf doctor` на новом проекте не поднял память, потому что 5433 держал контейнер
# samanta-agent-memory — тот же образ pgvector/pgvector:pg16, клон этого же стека.
#
# Прежнее поведение — «⚠ недоступна» плюс «повтори вручную» — это команда, которая
# отработала и соврала: повтор упал бы так же, а имя занявшего не называлось. Здесь порт
# ПОДБИРАЕТСЯ и записывается в конфиг ПРОЕКТА, а не фабрики: чинить надо там, где сломано,
# и не менять молча настройку всем остальным проектам.
#
# Чего эта функция НЕ делает: не трогает чужой контейнер. Остановить соседа — решение
# владельца машины, а не автоматики.

if (-not (Get-Command Get-BcfPortHolder -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'docker.ps1')
}

function Resolve-BcfMemoryPort {
    param(
        [Parameter(Mandatory)][int]$Wanted,
        [Parameter(Mandatory)][string]$Container,
        [string]$ConfigPath,          # откуда прочитан текущий порт (проектный или фабричный)
        [string]$ProjectRoot          # куда писать исправление; пусто — правим ConfigPath
    )

    $res = [pscustomobject]@{
        Port       = $Wanted
        Changed    = $false
        Holder     = ''
        HolderKind = ''
        ConfigPath = ''
        Error      = ''
    }

    $holder = Get-BcfPortHolder -Port $Wanted
    if (-not $holder.Kind) { return $res }
    if ($holder.Kind -eq 'container' -and $holder.Name -eq $Container) { return $res }

    $res.Holder = $holder.Name
    $res.HolderKind = $holder.Kind

    $free = Find-BcfFreePort -From ($Wanted + 1)
    if (-not $free) {
        $res.Error = "свободного порта не нашлось в диапазоне $($Wanted + 1)–$($Wanted + 40)"
        return $res
    }

    # КУДА ПИСАТЬ. Проектный конфиг перекрывает фабричный и у клиента (memory_client.py,
    # _config_candidates), и у мостика — поэтому исправление, положенное в проект, увидят
    # оба. Правка фабричного файла чинила бы этот проект ценой всех остальных.
    $target = if ($ProjectRoot) { Join-Path $ProjectRoot 'config\memory.config.json' }
              elseif ($ConfigPath) { $ConfigPath }
              else { '' }
    if (-not $target) {
        $res.Error = 'некуда записать порт: не задан ни проект, ни путь конфига'
        return $res
    }

    try {
        $json = $null
        if (Test-Path $target) {
            $json = Get-Content -Raw -LiteralPath $target | ConvertFrom-Json
        } elseif ($ConfigPath -and (Test-Path $ConfigPath)) {
            # Проектного конфига ещё нет — заводим его копией фабричного, чтобы вместе с
            # портом не потерять модель эмбеддингов, размерность и имя схемы.
            $json = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        }
        if (-not $json) { $res.Error = "конфиг памяти не найден: $ConfigPath"; return $res }

        $json | Add-Member -NotePropertyName 'port' -NotePropertyValue $free -Force
        # Имя контейнера фиксируем явно: иначе проект с исправленным портом поднимет
        # контейнер с фабричным именем, и следующая установка снова придёт в тот же спор.
        $json | Add-Member -NotePropertyName 'container' -NotePropertyValue $Container -Force

        $dir = Split-Path $target -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ($json | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $target -Encoding UTF8
    } catch {
        $res.Error = "не удалось записать порт в $target : $($_.Exception.Message)"
        return $res
    }

    $res.Port = $free
    $res.Changed = $true
    $res.ConfigPath = $target
    return $res
}
