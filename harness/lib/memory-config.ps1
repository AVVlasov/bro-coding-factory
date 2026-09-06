# memory-config.ps1 — откуда берутся адрес, порт и контейнер памяти.
#
# ДВА ФАЙЛА, И РОЛИ У НИХ РАЗНЫЕ.
#
#   config/memory.config.json — намерение владельца проекта. Лежит в git, одинаков у
#                               всех, кто склонировал репозиторий: адрес сервера, база,
#                               пользователь, модель эмбеддингов.
#   .bcf/memory.local.json    — накладка ЭТОЙ машины. В git не попадает (.bcf/ в
#                               .gitignore). Здесь и только здесь живёт подобранный порт
#                               и имя контейнера, поднятого локально.
#
# Почему их пришлось разделить. Порт 5433 записан дефолтом во все установки фабрики,
# поэтому вторая установка на той же машине гарантированно приходит в занятый порт и
# подбирает свободный. Раньше подобранный порт писался в config/memory.config.json —
# то есть в отслеживаемый файл: у человека появлялся диff, которого он не делал, а
# коммит с ним увозил номер порта СВОЕЙ машины всем остальным. Порт — свойство машины,
# а не проекта, и место ему в .bcf/.
#
# Адрес сервера (host) остаётся в конфиге проекта: это решение о том, где база живёт,
# а не случайность запуска. localhost по умолчанию — база поднимается тут же в docker.

if (-not (Get-Command Get-BcfHomeRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'bcf-context.ps1')
}

# Локальный ли адрес. От этого зависит слишком многое, чтобы решать «на глаз» в каждом
# вызывающем: контейнер поднимается только для локальной базы, порт подбирается только
# для локальной, а пароль по умолчанию допустим только для локальной.
function Test-BcfMemoryHostLocal {
    param([string]$HostName)
    if (-not $HostName) { return $true }
    return @('localhost', '127.0.0.1', '::1', '0.0.0.0') -contains $HostName.Trim().ToLower()
}

function Get-BcfMemoryLocalPath {
    param([Parameter(Mandatory)][string]$Project)
    return (Join-Path $Project '.bcf\memory.local.json')
}

# Накладка машины. Отсутствие файла — нормальное состояние: порт не подбирали.
function Read-BcfMemoryLocal {
    param([Parameter(Mandatory)][string]$Project)
    $p = Get-BcfMemoryLocalPath -Project $Project
    if (-not (Test-Path $p)) { return $null }
    try { return Get-Content -Raw -LiteralPath $p | ConvertFrom-Json } catch { return $null }
}

function Write-BcfMemoryLocal {
    param(
        [Parameter(Mandatory)][string]$Project,
        [int]$Port = 0,
        [string]$Container = ''
    )
    $path = Get-BcfMemoryLocalPath -Project $Project
    $cur = Read-BcfMemoryLocal -Project $Project
    if (-not $cur) { $cur = [pscustomobject]@{} }
    if ($Port)      { $cur | Add-Member -NotePropertyName 'port'      -NotePropertyValue $Port      -Force }
    if ($Container) { $cur | Add-Member -NotePropertyName 'container' -NotePropertyValue $Container -Force }
    $cur | Add-Member -NotePropertyName 'resolvedAt' -NotePropertyValue (Get-Date -Format 'o') -Force
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($cur | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

# Готовые к употреблению параметры памяти: конфиг проекта плюс накладка машины.
#
# Порядок поиска базового конфига ТОТ ЖЕ, что у клиента (memory_client.py,
# _config_candidates): BCF_MEM_CONFIG → проект → фабрика. Разойтись им нельзя: команда,
# показывающая один адрес, и клиент, ходящий по другому, — это зелёный init и «память
# недоступна» на прогоне одновременно.
function Resolve-BcfMemorySettings {
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$FactoryMemoryDir = ''
    )

    if (-not $FactoryMemoryDir) { $FactoryMemoryDir = Join-Path (Get-BcfHomeRoot) 'memory' }

    $candidates = @()
    if ($env:BCF_MEM_CONFIG) { $candidates += $env:BCF_MEM_CONFIG }
    if ($Project)            { $candidates += (Join-Path $Project 'config\memory.config.json') }
    $candidates += (Join-Path $FactoryMemoryDir 'memory.config.json')

    $cfg = $null; $path = ''
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path $c)) { continue }
        try { $cfg = Get-Content -Raw -LiteralPath $c | ConvertFrom-Json; $path = $c; break } catch { }
    }
    if (-not $cfg) { return $null }

    $local = Read-BcfMemoryLocal -Project $Project

    $port = if ($cfg.port) { [int]$cfg.port } else { 5433 }
    $container = if ($cfg.container) { [string]$cfg.container } else { 'bcf-agent-memory' }
    $portFromLocal = $false
    if ($local -and $local.port)      { $port = [int]$local.port; $portFromLocal = $true }
    if ($local -and $local.container) { $container = [string]$local.container }

    $hostName = if ($cfg.host) { [string]$cfg.host } else { 'localhost' }

    return [pscustomobject]@{
        Path          = $path
        LocalPath     = (Get-BcfMemoryLocalPath -Project $Project)
        HasLocal      = [bool]$local
        PortFromLocal = $portFromLocal
        Host          = $hostName
        IsLocalHost   = (Test-BcfMemoryHostLocal -HostName $hostName)
        Port          = $port
        Container     = $container
        Database      = [string]$cfg.database
        User          = [string]$cfg.user
        PwEnv         = $(if ($cfg.password_env) { [string]$cfg.password_env } else { 'BCF_PG_PASSWORD' })
        PwDefault     = [string]$cfg.password_default
        Endpoint      = $(if ($cfg.embedding_endpoint) { [string]$cfg.embedding_endpoint } else { 'http://localhost:1234/v1/embeddings' })
        Model         = [string]$cfg.embedding_model
        Dim           = $cfg.embedding_dim
        DataDir       = [string]$cfg.data_dir
        Raw           = $cfg
    }
}

# Пароль, с которым пойдёт клиент, и признак «это дефолт из репозитория».
#
# Дефолтный пароль в конфиге — не секрет и заведён намеренно: локальная база в docker
# на машине владельца, лишний шаг настройки тут никому не нужен. Но тот же дефолт на
# СЕТЕВОМ адресе означает базу, которую видят соседи по сети, с паролем, лежащим в
# открытом репозитории.
function Get-BcfMemoryPassword {
    param([Parameter(Mandatory)]$Settings)
    $env_ = $Settings.PwEnv
    $fromEnv = if ($env_) { [Environment]::GetEnvironmentVariable($env_) } else { '' }
    if ($fromEnv) {
        return [pscustomobject]@{ Value = $fromEnv; IsDefault = ($fromEnv -eq $Settings.PwDefault); FromEnv = $true }
    }
    return [pscustomobject]@{ Value = $Settings.PwDefault; IsDefault = [bool]$Settings.PwDefault; FromEnv = $false }
}
