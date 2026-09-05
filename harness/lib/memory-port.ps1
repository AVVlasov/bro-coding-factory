# memory-port.ps1 — порт векторной памяти, который не спорит с соседями.
#
# ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ПРОВЕРКА НА МЕСТЕ.
#
# Порт 5433 записан дефолтом и в memory/memory.config.json, и в docker-compose.yml. Это
# значит, что ВТОРАЯ установка фабрики на той же машине — или любой другой pgvector,
# поднятый соседним проектом, — гарантированно занимает наш порт. Наблюдалось живьём:
# `bcf doctor` на новом проекте не поднял память, потому что 5433 держал контейнер
# соседнего проекта — тот же образ pgvector/pgvector:pg16, клон этого же стека.
#
# Прежнее поведение — «⚠ недоступна» плюс «повтори вручную» — это команда, которая
# отработала и соврала: повтор упал бы так же, а имя занявшего не называлось. Здесь порт
# ПОДБИРАЕТСЯ и записывается в накладку МАШИНЫ (.bcf/memory.local.json), а не в
# отслеживаемый config/memory.config.json: порт — свойство машины, на которой подняли
# контейнер, а не решение проекта. Пока он писался в конфиг проекта, у владельца
# появлялся диff, которого он не делал, и коммит увозил номер порта его машины всем.
#
# Чего эта функция НЕ делает: не трогает чужой контейнер. Остановить соседа — решение
# владельца машины, а не автоматики. И не лезет в порт, когда база не на этой машине:
# на сетевом адресе порт слушает чужой сервер, и подбирать там нечего.

if (-not (Get-Command Get-BcfPortHolder -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'docker.ps1')
}
if (-not (Get-Command Write-BcfMemoryLocal -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'memory-config.ps1')
}

function Resolve-BcfMemoryPort {
    param(
        [Parameter(Mandatory)][int]$Wanted,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$ProjectRoot,   # куда писать накладку машины
        [string]$HostName = 'localhost'               # адрес базы: чужой сервер не наш порт
    )

    $res = [pscustomobject]@{
        Port       = $Wanted
        Changed    = $false
        Holder     = ''
        HolderKind = ''
        ConfigPath = ''
        Error      = ''
    }

    if (-not (Test-BcfMemoryHostLocal -HostName $HostName)) { return $res }

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

    try {
        # Имя контейнера фиксируем рядом с портом: иначе проект с исправленным портом
        # поднимет контейнер с фабричным именем, и следующая установка снова придёт в
        # тот же спор. Обе величины — про эту машину, поэтому лежат в одном файле.
        $res.ConfigPath = Write-BcfMemoryLocal -Project $ProjectRoot -Port $free -Container $Container
    } catch {
        $res.Error = "не удалось записать порт в накладку машины: $($_.Exception.Message)"
        return $res
    }

    $res.Port = $free
    $res.Changed = $true
    return $res
}
