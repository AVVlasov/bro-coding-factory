# event-bus.ps1 — append-only event log для Ralph harness (event-sourced state).
#
# Один файл: loop/events.jsonl. Append-only, NEVER редактируется.
# Snapshot для быстрого доступа: loop/state/STATE.json (derived, можно пересчитать
# `Compute-State` из events.jsonl).
#
# Контракт события (JSON, одна строка per event):
#   {
#     "ts": "2026-05-25T10:00:00.123Z",
#     "event_type": "iter-started|iter-completed|phase-started|phase-completed|"
#                  +"phase-failed|opencode-run|opencode-timeout|verify-requested|"
#                  +"verdict-recorded|restart-required|human-callout|task-closed|"
#                  +"loop-paused|loop-resumed|no-progress|launch-failed|commit",
#     "phase": "0|A|B|C|D|E|loop",
#     "task_id": "TASK-NN",
#     "iteration": 42,
#     "session_id": "abc123...",
#     "host": "DESKTOP-...",
#     "payload": { event-specific fields },
#     "idempotency_key": "<optional>"
#   }
#
# Использование (dot-source в loop.ps1 / verify.ps1):
#   . (Join-Path $PSScriptRoot 'lib\event-bus.ps1')
#   Initialize-EventBus -RalphRoot (Split-Path $PSScriptRoot -Parent)/loop
#   Append-Event -EventType iter-started -TaskId $task -Iteration $i -Phase loop
#   Compute-State -StateDir "loop/state"

$script:EventsFile = $null
$script:StateDir   = $null
$script:HostId     = $env:COMPUTERNAME
$script:SessionId  = [Guid]::NewGuid().ToString('N').Substring(0, 12)

function Initialize-EventBus {
    param(
        [Parameter(Mandatory)] [string]$RalphRoot
    )
    $script:EventsFile = Join-Path $RalphRoot 'events.jsonl'
    $script:StateDir   = Join-Path $RalphRoot 'state'
    if (-not (Test-Path $script:EventsFile)) {
        New-Item -ItemType File -Path $script:EventsFile -Force | Out-Null
    }
    if (-not (Test-Path $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
}

function Get-EventBusFile { return $script:EventsFile }
function Get-EventBusSession { return $script:SessionId }

function Append-Event {
    param(
        [Parameter(Mandatory)] [string]$EventType,
        [string]   $Phase     = '',
        [string]   $TaskId    = '',
        [int]      $Iteration = 0,
        [hashtable]$Payload   = $null,
        [string]   $IdempotencyKey = ''
    )
    if (-not $script:EventsFile) { return }

    # Идемпотентность (дорого — только если задан ключ):
    # проверим последние 500 строк на совпадение идемпотентного ключа.
    if ($IdempotencyKey -and (Test-Path $script:EventsFile)) {
        $needle = "`"idempotency_key`":`"$IdempotencyKey`""
        $tail   = Get-Content $script:EventsFile -Tail 500 -ErrorAction SilentlyContinue
        if ($tail -and ($tail | Where-Object { $_ -like "*$needle*" })) { return }
    }

    $ev = [ordered]@{
        ts          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        event_type  = $EventType
        phase       = $Phase
        task_id     = $TaskId
        iteration   = $Iteration
        session_id  = $script:SessionId
        host        = $script:HostId
    }
    if ($Payload) { $ev.payload = $Payload } else { $ev.payload = @{} }
    if ($IdempotencyKey) { $ev.idempotency_key = $IdempotencyKey }

    $line = $ev | ConvertTo-Json -Compress -Depth 10
    Add-Content -Path $script:EventsFile -Value $line -Encoding UTF8
}

function Get-Events {
    param(
        [string]$EventType = '',
        [string]$TaskId    = '',
        [string]$Phase     = '',
        [int]   $Last      = 0,
        [string]$SinceTs   = ''
    )
    if (-not $script:EventsFile -or -not (Test-Path $script:EventsFile)) { return @() }
    $lines = Get-Content $script:EventsFile -ErrorAction SilentlyContinue
    if ($Last -gt 0) { $lines = $lines | Select-Object -Last $Last }
    $events = @()
    foreach ($l in $lines) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try {
            $e = $l | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if ($EventType -and $e.event_type -ne $EventType) { continue }
        if ($TaskId    -and $e.task_id    -ne $TaskId)    { continue }
        if ($Phase     -and $e.phase      -ne $Phase)     { continue }
        if ($SinceTs   -and $e.ts -lt $SinceTs)           { continue }
        $events += $e
    }
    return $events
}

function Compute-State {
    param([string]$StateDir = $null)
    if (-not $StateDir) { $StateDir = $script:StateDir }
    $events = Get-Events
    $tasks  = @{}
    $last_event = $null
    foreach ($e in $events) {
        $last_event = $e
        if (-not $e.task_id) { continue }
        if (-not $tasks.ContainsKey($e.task_id)) {
            $tasks[$e.task_id] = [ordered]@{
                first_seen = $e.ts
                last_seen  = $e.ts
                iterations = 0
                verdicts   = @()
                fails      = 0
                passes     = 0
                last_phase = ''
            }
        }
        $t = $tasks[$e.task_id]
        $t.last_seen = $e.ts
        if ($e.phase) { $t.last_phase = $e.phase }
        if ($e.event_type -eq 'iter-started') { $t.iterations++ }
        if ($e.event_type -eq 'verdict-recorded' -and $e.payload.verdict) {
            $v = $e.payload.verdict
            $t.verdicts += $v
            if ($v -eq 'PASS') { $t.passes++ } else { $t.fails++ }
        }
    }
    $state = [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        session_id   = $script:SessionId
        host         = $script:HostId
        last_event   = $last_event
        total_events = $events.Count
        tasks        = $tasks
    }
    if ($StateDir) {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        $stateFile = Join-Path $StateDir 'STATE.json'
        Set-Content -LiteralPath $stateFile -Value ($state | ConvertTo-Json -Depth 10) -Encoding UTF8
    }
    return $state
}

function Get-LastVerdict {
    param([string]$TaskId)
    $events = Get-Events -EventType 'verdict-recorded' -TaskId $TaskId
    if (-not $events) { return $null }
    return ($events | Select-Object -Last 1).payload.verdict
}

function Count-ConsecutiveFails {
    param([string]$TaskId, [string]$Criterion = '')
    # Сколько подряд FAIL/NEEDS-MORE-EVIDENCE без PASS между ними (для throw-out N=2).
    $events = Get-Events -EventType 'verdict-recorded' -TaskId $TaskId
    $count = 0
    foreach ($e in ($events | Sort-Object { $_.ts } -Descending)) {
        $v = $e.payload.verdict
        if ($v -eq 'PASS') { break }
        if ($Criterion -and $e.payload.failing_criterion -and $e.payload.failing_criterion -ne $Criterion) { continue }
        $count++
    }
    return $count
}
