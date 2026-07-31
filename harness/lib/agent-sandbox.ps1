# agent-sandbox.ps1 — изоляция состояния CLI-агента для параллельных прогонов.
#
# ЗАЧЕМ. opencode держит своё состояние в ОДНОЙ глобальной SQLite-базе
# (~/.local/share/opencode/opencode.db, WAL). Два одновременных `opencode run`
# дерутся за неё, и лишние падают мгновенно с
#     Error: Failed to run the query 'PRAGMA journal_mode = WAL'
# Замер 2026-07-26: из трёх параллельных тестеров двое умерли через 3 секунды,
# отдав вместо отчёта текст ошибки — а вердикт при этом остался зелёным, потому
# что держался на детерминированных проверках. Ровно тот случай, когда
# «параллелизм включили» и никто не заметил, что две трети работы не сделано.
#
# РЕШЕНИЕ. Каждому параллельному воркеру — свой XDG_DATA_HOME (проверено: два
# агента с разными XDG_DATA_HOME отработали одновременно без единой ошибки).
# Внутрь копируются только auth.json/account.json — без них воркер не
# авторизован; сама база создаётся воркером и переиспользуется между прогонами,
# чтобы одноразовая миграция не повторялась каждый раз.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:SandboxRoot = Join-Path (Get-BcfProjectRoot) '.bcf\workers'

function Get-AgentDataHome {
    if ($env:BCF_AGENT_DATA_HOME) { return $env:BCF_AGENT_DATA_HOME }
    if ($env:XDG_DATA_HOME) { return $env:XDG_DATA_HOME }
    return (Join-Path $env:USERPROFILE '.local\share')
}

# Готовит песочницу воркера и возвращает путь, который надо положить в XDG_DATA_HOME.
# $Slot = 0 означает «без изоляции» — вернётся $null, и вызывающий не трогает env.
function Initialize-AgentSandbox {
    param([Parameter(Mandatory)][int]$Slot)

    if ($Slot -le 0) { return $null }

    # ВНИМАНИЕ: не $home — это read-only автопеременная PowerShell, присваивание
    # ей роняет функцию, а вызывающий catch превращает это в «нет слотов».
    $dataHome = Get-AgentDataHome
    $sandbox = Join-Path $script:SandboxRoot "w$Slot"
    $target  = Join-Path $sandbox 'opencode'
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }

    # Учётные файлы обновляем, если оригинал новее: перелогинился — воркеры подхватят.
    foreach ($f in @('auth.json', 'account.json')) {
        $src = Join-Path $dataHome "opencode\$f"
        $dst = Join-Path $target $f
        if (-not (Test-Path $src)) { continue }
        $stale = (-not (Test-Path $dst)) -or
                 ((Get-Item $src).LastWriteTimeUtc -gt (Get-Item $dst).LastWriteTimeUtc)
        if ($stale) { Copy-Item $src $dst -Force -ErrorAction SilentlyContinue }
    }
    return $sandbox
}

# --- Межпроцессная аренда слотов ---
#
# Слоты нельзя раздавать внутри одного процесса: verify.ps1 запускается и раннером,
# и человеком, и (в перспективе) несколькими параллельными задачами разом. Два
# процесса, независимо раздавшие w1..w3, посадят разных агентов на ОДНУ песочницу —
# то есть вернут ровно ту гонку за SQLite, ради которой всё это и сделано.
# Поэтому слот арендуется файловой блокировкой: держим эксклюзивный хендл на
# w<N>.lock всё время работы воркера.

function Acquire-AgentSlot {
    param([int]$MaxSlots = 16)

    if (-not (Test-Path $script:SandboxRoot)) {
        New-Item -ItemType Directory -Force -Path $script:SandboxRoot | Out-Null
    }
    for ($slot = 1; $slot -le $MaxSlots; $slot++) {
        $lockPath = Join-Path $script:SandboxRoot "w$slot.lock"
        try {
            $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            $sandbox = Initialize-AgentSandbox -Slot $slot
            return @{ Slot = $slot; Path = $sandbox; Lock = $fs }
        } catch {
            continue   # слот занят другим процессом — берём следующий
        }
    }
    return $null       # все слоты заняты: вызывающий подождёт освобождения
}

function Release-AgentSlot {
    param($Handle)
    if (-not $Handle) { return }
    try { $Handle.Lock.Dispose() } catch { }
}

# Освободить место: песочницы переиспользуются, но БД растёт вместе с историей сессий.
function Clear-AgentSandboxes {
    param([int]$KeepSlots = 0)
    if (-not (Test-Path $script:SandboxRoot)) { return }
    Get-ChildItem $script:SandboxRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^w(\d+)$' -and [int]$Matches[1] -gt $KeepSlots) {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
