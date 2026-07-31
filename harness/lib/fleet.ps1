# fleet.ps1 — реестр фоновых агентов: кто работает, над чем, жив ли.
#
# ЗАЧЕМ. Как только агентов больше одного, теряется главное: непонятно, сколько их,
# что каждый делает и кто завис. В прошлом прогоне два verify шли одновременно и
# писали в один лог вперемешку, а два из трёх агентов молча умерли — и это не было
# видно ни в логе, ни в вердикте.
#
# Реестр — файлы `.bcf/fleet/w<slot>.worker.json`, по одному на воркера: пишутся при
# старте, чистятся при завершении, осиротевшие (pid мёртв) подбираются при чтении.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:FleetRoot = Join-Path (Get-BcfProjectRoot) '.bcf\fleet'

function _Ensure-FleetRoot {
    if (-not (Test-Path $script:FleetRoot)) { New-Item -ItemType Directory -Force -Path $script:FleetRoot | Out-Null }
}

function Register-FleetWorker {
    param(
        [Parameter(Mandatory)][string]$Id,      # уникальный: слот или task-роль
        [Parameter(Mandatory)][string]$Role,    # code | tester | judge | runner
        [string]$Task = '',
        [string]$Model = '',
        [int]$ProcessId = $PID,
        [string]$Detail = ''
    )
    _Ensure-FleetRoot
    $rec = [pscustomobject]@{
        id = $Id; role = $Role; task = $Task; model = $Model
        pid = $ProcessId; detail = $Detail
        started = (Get-Date -Format 'o'); heartbeat = (Get-Date -Format 'o')
    }
    ($rec | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $script:FleetRoot "$Id.worker.json") -Encoding UTF8
}

function Update-FleetHeartbeat {
    param([Parameter(Mandatory)][string]$Id, [string]$Detail = '')
    $path = Join-Path $script:FleetRoot "$Id.worker.json"
    if (-not (Test-Path $path)) { return }
    try {
        $rec = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $rec.heartbeat = (Get-Date -Format 'o')
        if ($Detail) { $rec.detail = $Detail }
        ($rec | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch { }
}

function Unregister-FleetWorker {
    param([Parameter(Mandatory)][string]$Id)
    Remove-Item -LiteralPath (Join-Path $script:FleetRoot "$Id.worker.json") -Force -ErrorAction SilentlyContinue
}

# Живые воркеры. Записи мёртвых процессов удаляются здесь же — иначе потолок
# агентов навсегда «съедается» призраками после падения раннера.
function Get-FleetWorkers {
    param([int]$StaleSec = 0)
    _Ensure-FleetRoot
    $out = @()
    foreach ($f in (Get-ChildItem $script:FleetRoot -Filter '*.worker.json' -ErrorAction SilentlyContinue)) {
        try { $rec = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json } catch { continue }
        if ($rec.pid -and -not (Get-Process -Id $rec.pid -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $idle = [int]((Get-Date) - [datetime]$rec.heartbeat).TotalSeconds
        $out += [pscustomobject]@{
            id = $rec.id; role = $rec.role; task = $rec.task; model = $rec.model
            pid = $rec.pid; detail = $rec.detail
            started = $rec.started; idle_sec = $idle
            stalled = ($StaleSec -gt 0 -and $idle -ge $StaleSec)
        }
    }
    return @($out | Sort-Object role, id)
}

# Общий потолок агентов: параллелизм упирается не в CPU, а в rate-limit провайдера,
# поэтому счётчик один на все роли.
function Test-FleetCapacity {
    param([int]$MaxAgents = 6)
    return ((Get-FleetWorkers).Count -lt $MaxAgents)
}

function Stop-FleetWorker {
    param([Parameter(Mandatory)][string]$Id)
    $rec = Get-FleetWorkers | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $rec) { return $false }
    try { Stop-Process -Id $rec.pid -Force -ErrorAction Stop } catch { }
    Unregister-FleetWorker -Id $Id
    return $true
}
