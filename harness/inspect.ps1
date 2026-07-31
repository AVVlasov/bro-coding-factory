# inspect.ps1 — CLI инспектор Ralph event-log'а.
#
# Использование:
#   pwsh harness/inspect.ps1 --last 20
#   pwsh harness/inspect.ps1 --task <TASK>
#   pwsh harness/inspect.ps1 --task <TASK> --phase A
#   pwsh harness/inspect.ps1 --replay                 # пересчитать STATE.json из events.jsonl
#   pwsh harness/inspect.ps1 --stats                  # сводка по задачам
#   pwsh harness/inspect.ps1 --export-csv events.csv  # экспорт в CSV

param(
    [int]    $Last       = 0,
    [string] $Task       = '',
    [string] $Phase      = '',
    [string] $EventType  = '',
    [switch] $Replay,
    [switch] $Stats,
    [string] $ExportCsv  = '',
    [string] $SinceTs    = '',
  [string]$ProjectRoot = ''         # корень проекта; пусто = BCF_PROJECT_ROOT, иначе верх git-репозитория
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$root = Get-BcfProjectRoot -Explicit $ProjectRoot

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

. (Join-Path $PSScriptRoot 'lib\event-bus.ps1')

# M-09 D: блокируем запуск из агентской сессии.
. (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
Assert-HarnessCaller -ScriptName 'inspect.ps1'
Initialize-EventBus -RalphRoot (Get-BcfStateDir $root)

if ($Replay) {
    $state = Compute-State
    Write-Host "[ok] STATE.json пересчитан из $($state.total_events) событий → .bcf/state/STATE.json"
    return
}

if ($Stats) {
    $state = Compute-State
    Write-Host "Всего событий: $($state.total_events)"
    Write-Host "Задач:         $($state.tasks.Count)"
    Write-Host ''
    Write-Host ('{0,-12} {1,5} {2,7} {3,7} {4,-12} {5}' -f 'TASK','iter','PASS','FAIL','last-phase','last-seen')
    Write-Host ('-' * 80)
    foreach ($k in ($state.tasks.Keys | Sort-Object)) {
        $t = $state.tasks[$k]
        Write-Host ('{0,-12} {1,5} {2,7} {3,7} {4,-12} {5}' -f `
            $k, $t.iterations, $t.passes, $t.fails, $t.last_phase, $t.last_seen)
    }
    return
}

$events = Get-Events -EventType $EventType -TaskId $Task -Phase $Phase -Last $Last -SinceTs $SinceTs

if ($ExportCsv) {
    $events | Select-Object ts, event_type, phase, task_id, iteration, session_id, `
        @{n='payload'; e={($_.payload | ConvertTo-Json -Compress -Depth 5)}} `
        | Export-Csv -LiteralPath $ExportCsv -Encoding UTF8 -NoTypeInformation
    Write-Host "[ok] $($events.Count) событий экспортировано → $ExportCsv"
    return
}

if (-not $events) {
    Write-Host '(нет событий, удовлетворяющих фильтру)'
    return
}

foreach ($e in $events) {
    $payloadShort = ''
    if ($e.payload) {
        $j = $e.payload | ConvertTo-Json -Compress -Depth 3
        if ($j.Length -gt 200) { $j = $j.Substring(0, 200) + '…' }
        $payloadShort = $j
    }
    Write-Host ('{0}  {1,-22} {2,-4} {3,-10} #{4,-4} {5}' -f `
        $e.ts, $e.event_type, $e.phase, $e.task_id, $e.iteration, $payloadShort)
}
Write-Host ''
Write-Host "[$($events.Count) событий]"
