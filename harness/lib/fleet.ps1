# fleet.ps1 — реестр фоновых агентов: кто работает, над чем, жив ли.
#
# ЗАЧЕМ. Как только агентов больше одного, теряется главное: непонятно, сколько их,
# что каждый делает и кто завис. В прошлом прогоне два verify шли одновременно и
# писали в один лог вперемешку, а два из трёх агентов молча умерли — и это не было
# видно ни в логе, ни в вердикте.
#
# РЕЕСТР ОДИН НА УСТАНОВКУ ФАБРИКИ, А НЕ НА ПРОЕКТ.
#
# Потолок агентов упирается не в процессор, а в rate-limit провайдера — то есть в
# ресурс, общий для всех проектов на машине. Пока файлы аренды лежали в .bcf/ проекта,
# счётчик был проектным: два проекта с потолком 6 запускали двенадцать агентов, каждый
# считал себя в рамках, а провайдер отвечал отказами всем сразу. Снаружи это выглядит
# как «модель тупит», а не как превышенный потолок.
#
# Поэтому файлы `<slot>.worker.json` живут в каталоге установки (BCF_FLEET_DIR или
# <фабрика>/.bcf/fleet) и в имя файла входит ярлык проекта: слот `w1` есть у каждого
# проекта, и без ярлыка второй проект молча затирал бы запись первого — потолок опять
# считался бы неверно, теперь уже в меньшую сторону.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')

# Каталог реестра. Считается при каждом обращении, а не один раз при загрузке: переменная
# окружения может быть выставлена после dot-source (так делают тесты и обёртки).
function Get-BcfFleetRoot {
    if ($env:BCF_FLEET_DIR) { return $env:BCF_FLEET_DIR.TrimEnd('\', '/') }
    return (Join-Path (Get-BcfHomeRoot) '.bcf\fleet')
}

function _Ensure-FleetRoot {
    $r = Get-BcfFleetRoot
    if (-not (Test-Path $r)) { New-Item -ItemType Directory -Force -Path $r | Out-Null }
    return $r
}

# Ярлык проекта в имени файла. Имя каталога читается человеком, шесть знаков хэша от
# полного пути разводят одноимённые проекты на разных дисках и worktree одной задачи.
function Get-BcfFleetProjectTag {
    param([string]$Project = '')
    if (-not $Project) { $Project = Get-BcfProjectRoot }
    $norm = ([string]$Project).TrimEnd('\', '/').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))
    } finally { $sha.Dispose() }
    $hex = ([BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 6).ToLowerInvariant()
    $leaf = (Split-Path $norm -Leaf) -replace '[^a-z0-9_.-]', '_'
    if (-not $leaf) { $leaf = 'project' }
    return "$leaf-$hex"
}

function _FleetFile {
    param([Parameter(Mandatory)][string]$Id, [string]$Project = '')
    return (Join-Path (Get-BcfFleetRoot) ("$(Get-BcfFleetProjectTag -Project $Project).$Id.worker.json"))
}

function Register-FleetWorker {
    param(
        [Parameter(Mandatory)][string]$Id,      # уникальный В ПРЕДЕЛАХ ПРОЕКТА: слот или task-роль
        [Parameter(Mandatory)][string]$Role,    # code | tester | judge | runner
        [string]$Task = '',
        [string]$Model = '',
        [int]$ProcessId = $PID,
        [string]$Detail = '',
        [string]$Project = ''
    )
    _Ensure-FleetRoot | Out-Null
    if (-not $Project) { $Project = Get-BcfProjectRoot }
    $rec = [pscustomobject]@{
        id = $Id; role = $Role; task = $Task; model = $Model
        pid = $ProcessId; detail = $Detail; project = $Project
        started = (Get-Date -Format 'o'); heartbeat = (Get-Date -Format 'o')
    }
    ($rec | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (_FleetFile -Id $Id -Project $Project) -Encoding UTF8
}

function Update-FleetHeartbeat {
    param([Parameter(Mandatory)][string]$Id, [string]$Detail = '', [string]$Project = '')
    $path = _FleetFile -Id $Id -Project $Project
    if (-not (Test-Path $path)) { return }
    try {
        $rec = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $rec.heartbeat = (Get-Date -Format 'o')
        if ($Detail) { $rec.detail = $Detail }
        ($rec | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch { }
}

function Unregister-FleetWorker {
    param([Parameter(Mandatory)][string]$Id, [string]$Project = '')
    Remove-Item -LiteralPath (_FleetFile -Id $Id -Project $Project) -Force -ErrorAction SilentlyContinue
}

# Живые воркеры ВСЕЙ установки. Записи мёртвых процессов удаляются здесь же — иначе
# потолок агентов навсегда «съедается» призраками после падения раннера.
#
# -Mine оставляет только воркеров текущего проекта: показывать чужие уместно в общем
# счётчике, но не там, где по ним судят о работе этого проекта.
function Get-FleetWorkers {
    param([int]$StaleSec = 0, [switch]$Mine, [string]$Project = '')
    _Ensure-FleetRoot | Out-Null
    if (-not $Project) { $Project = Get-BcfProjectRoot }
    $mineNorm = ([string]$Project).TrimEnd('\', '/').ToLowerInvariant()
    $out = @()
    foreach ($f in (Get-ChildItem (Get-BcfFleetRoot) -Filter '*.worker.json' -ErrorAction SilentlyContinue)) {
        try { $rec = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($rec.pid -and -not (Get-Process -Id $rec.pid -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $recProject = [string]$rec.project
        $isMine = ($recProject.TrimEnd('\', '/').ToLowerInvariant() -eq $mineNorm)
        if ($Mine -and -not $isMine) { continue }
        $idle = [int]((Get-Date) - [datetime]$rec.heartbeat).TotalSeconds
        $out += [pscustomobject]@{
            id = $rec.id; role = $rec.role; task = $rec.task; model = $rec.model
            pid = $rec.pid; detail = $rec.detail
            project = $recProject; mine = $isMine
            started = $rec.started; idle_sec = $idle
            stalled = ($StaleSec -gt 0 -and $idle -ge $StaleSec)
        }
    }
    return @($out | Sort-Object role, id)
}

# Общий потолок агентов: параллелизм упирается не в CPU, а в rate-limit провайдера,
# поэтому счётчик один на все роли И на все проекты установки.
function Test-FleetCapacity {
    param([int]$MaxAgents = 6)
    return ((Get-FleetWorkers).Count -lt $MaxAgents)
}

function Stop-FleetWorker {
    param([Parameter(Mandatory)][string]$Id, [string]$Project = '')
    # Только свой проект: слот `w3` есть у каждого, и убивать чужого по совпадению
    # имени — это остановить работу, о которой вызывающий ничего не знает.
    $rec = Get-FleetWorkers -Mine -Project $Project | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $rec) { return $false }
    try { Stop-Process -Id $rec.pid -Force -ErrorAction Stop } catch { }
    Unregister-FleetWorker -Id $Id -Project $Project
    return $true
}
