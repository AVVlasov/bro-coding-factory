# journal.ps1 — чтение журналов прогонов графа.
#
# Журнал (.bcf/graph/<runId>/journal.jsonl) — append-only и единственный источник правды
# о прогоне. Всё, что показывают runs / board / report / cost, читается ОТСЮДА, а не из
# отдельно ведомой сводки: сводка, живущая рядом с журналом, рано или поздно начинает
# расходиться с ним, и расходится молча.

function Get-BcfGraphRoot {
    param([Parameter(Mandatory)][string]$Project)
    return (Join-Path $Project '.bcf\graph')
}

function Get-BcfRuns {
    param([Parameter(Mandatory)][string]$Project, [int]$Limit = 0)

    $root = Get-BcfGraphRoot -Project $Project
    if (-not (Test-Path $root)) { return @() }

    $runs = @()
    foreach ($d in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $j = Join-Path $d.FullName 'journal.jsonl'
        if (-not (Test-Path $j)) { continue }
        $runs += (Read-BcfRun -JournalPath $j -RunId $d.Name)
        if ($Limit -and $runs.Count -ge $Limit) { break }
    }
    return $runs
}

function Read-BcfRun {
    param([Parameter(Mandatory)][string]$JournalPath, [string]$RunId = '')

    $name = ''; $started = $null; $finished = $null
    $nodes = @{}
    $order = @()
    $done = $false
    $curPhase = ''
    $dryPlan = $false
    $result = $null

    foreach ($line in (Get-Content -LiteralPath $JournalPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        $r = $null
        try { $r = $line | ConvertFrom-Json } catch { continue }
        switch ([string]$r.event) {
            'run-start' {
                $name = [string]$r.name
                $dryPlan = [bool]$r.dryPlan
                if ($r.ts) { $started = [datetime]$r.ts }
            }
            'phase' { $curPhase = [string]$r.phase }
            'node-start' {
                # Ключ — key, а не label: label человекочитаем и может повториться
                # (одна и та же роль по двум задачам), а key уникален и по нему же
                # рантайм ищет кэш при возобновлении.
                $id = [string]$r.key
                if (-not $id) { $id = [string]$r.label }
                if (-not $nodes.ContainsKey($id)) { $order += $id }
                $nodes[$id] = [ordered]@{
                    Label = $(if ($r.label) { [string]$r.label } else { $id })
                    Phase = $(if ($r.phase) { [string]$r.phase } else { $curPhase })
                    Role = [string]$r.role; Model = [string]$r.model
                    Started = $(if ($r.ts) { [datetime]$r.ts } else { $null })
                    Finished = $null; Ok = $null; Tokens = 0.0; Reason = ''
                    Cached = $false; Dry = [bool]$r.dry
                }
            }
            'node-finish' {
                $id = [string]$r.key
                if (-not $id) { $id = [string]$r.label }
                if (-not $nodes.ContainsKey($id)) {
                    $order += $id
                    $nodes[$id] = [ordered]@{
                        Label = $(if ($r.label) { [string]$r.label } else { $id })
                        Phase = $(if ($r.phase) { [string]$r.phase } else { $curPhase })
                        Role = ''; Model = ''; Started = $null; Finished = $null
                        Ok = $null; Tokens = 0.0; Reason = ''; Cached = $false; Dry = $false
                    }
                }
                $n = $nodes[$id]
                $n.Finished = $(if ($r.ts) { [datetime]$r.ts } else { $null })
                $n.Ok = [bool]$r.ok
                if ($r.tokens)  { $n.Tokens = [double]$r.tokens }
                if ($r.role)    { $n.Role = [string]$r.role }
                if ($r.model)   { $n.Model = [string]$r.model }
                if ($r.reason)  { $n.Reason = [string]$r.reason }
                if ($r.cached)  { $n.Cached = $true }
                $nodes[$id] = $n
            }
            'run-finish' {
                $done = $true
                if ($r.ts) { $finished = [datetime]$r.ts }
                # Итог, который вернул САМ граф. Он авторитетнее счётчика узлов: узлы
                # могут все отработать, а очередь при этом остаться незакрытой — ровно
                # тот случай, когда отчёт по узлам говорит «готово» о неполном прогоне.
                if ($r.result) { try { $result = $r.result | ConvertFrom-Json } catch { } }
            }
        }
    }

    $list = @($order | ForEach-Object { [pscustomobject]$nodes[$_] })
    $failed = @($list | Where-Object { $_.Ok -eq $false })
    $tokens = ($list | Measure-Object -Property Tokens -Sum).Sum
    if (-not $tokens) { $tokens = 0 }

    if (-not $RunId) { $RunId = Split-Path (Split-Path $JournalPath -Parent) -Leaf }
    if (-not $started) { $started = (Get-Item $JournalPath).CreationTime }
    if (-not $finished) { $finished = (Get-Item $JournalPath).LastWriteTime }

    return [pscustomobject]@{
        RunId    = $RunId
        Name     = $(if ($name) { $name } else { 'graph' })
        Started  = $started
        Finished = $finished
        Duration = ($finished - $started)
        Complete = $done
        DryPlan  = $dryPlan
        Result   = $result
        Nodes    = $list
        NodeCount = $list.Count
        Failed   = $failed.Count
        Tokens   = $tokens
        Journal  = $JournalPath
    }
}

function Get-BcfLastRun {
    param([Parameter(Mandatory)][string]$Project)
    $runs = Get-BcfRuns -Project $Project -Limit 1
    if (-not $runs.Count) { return $null }
    return $runs[0]
}

function Resolve-BcfRun {
    param([Parameter(Mandatory)][string]$Project, [string]$RunId = '')
    if (-not $RunId -or $RunId -eq 'last') { return (Get-BcfLastRun -Project $Project) }
    $j = Join-Path (Get-BcfGraphRoot -Project $Project) "$RunId\journal.jsonl"
    if (-not (Test-Path $j)) { return $null }
    return (Read-BcfRun -JournalPath $j -RunId $RunId)
}

# Сводка по ролям. Именно роль, а не узел, — единица, в которой имеет смысл считать
# деньги: узлов у исполнения десятки, и построчный список ничего не объясняет.
function Get-BcfRunByRole {
    param([Parameter(Mandatory)]$Run)
    $agg = @{}
    foreach ($n in $Run.Nodes) {
        $role = if ($n.Role) { $n.Role } else { '(без роли)' }
        if (-not $agg.ContainsKey($role)) {
            $agg[$role] = [ordered]@{ Role = $role; Model = $n.Model; Nodes = 0; Tokens = 0.0; Failed = 0 }
        }
        $agg[$role].Nodes++
        $agg[$role].Tokens += [double]$n.Tokens
        if ($n.Ok -eq $false) { $agg[$role].Failed++ }
        if (-not $agg[$role].Model -and $n.Model) { $agg[$role].Model = $n.Model }
    }
    return @($agg.Keys | Sort-Object { -$agg[$_].Tokens } | ForEach-Object { [pscustomobject]$agg[$_] })
}
