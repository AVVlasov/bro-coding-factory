# bcf runs — журналы прошлых прогонов графа.
#
#   bcf runs            последние 20
#   bcf runs --all      все
#   bcf runs --json     машиночитаемо

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$all = $script:BcfArgs -contains '--all'
$asJson = $script:BcfArgs -contains '--json'
$project = $script:BcfProject

$runs = Get-BcfRuns -Project $project -Limit $(if ($all) { 0 } else { 20 })

if ($asJson) {
    ($runs | Select-Object RunId, Name, Started, Finished, Complete, NodeCount, Failed, Tokens | ConvertTo-Json -Depth 5) | Write-Output
    exit 0
}

Write-BcfTitle 'ПРОГОНЫ ГРАФА' "$(Split-Path $project -Leaf) · .bcf/graph/"

if (-not $runs.Count) {
    Write-BcfDim 'прогонов ещё не было'
    Write-BcfNote 'первый: bcf run queue'
    Write-Host ''
    exit 0
}

$rows = New-BcfRows
$colors = @()
foreach ($r in $runs) {
    # Четыре разных состояния, и склеивать их нельзя:
    #   сухой    — агентов не звали, о задачах не говорит ничего;
    #   ОБОРВАН  — можно доиграть, работа отработавших узлов не потеряна;
    #   неполно  — граф доиграл, но очередь закрылась не вся (его собственный вердикт);
    #   ок       — закрылось всё.
    $res = $r.Result
    $state = if ($r.DryPlan) { 'сухой план' }
             elseif (-not $r.Complete) { 'ОБОРВАН' }
             elseif ($null -ne $res -and $res.PSObject.Properties['complete'] -and -not $res.complete) {
                 "неполно: $($res.passed)/$($res.total)"
             }
             elseif ($r.Failed) { "провалов узлов $($r.Failed)" }
             else { 'ок' }
    Add-BcfRow $rows @($r.RunId, $r.Name, "$($r.NodeCount)", ('{0:hh\:mm\:ss}' -f $r.Duration), "$([int]$r.Tokens)", $state)
    $colors += $(if ($r.DryPlan) { 'DarkGray' }
                 elseif (-not $r.Complete) { 'DarkYellow' }
                 elseif ($state -eq 'ок') { 'Green' } else { 'Yellow' })
}
Write-BcfTable -Headers @('runId', 'граф', 'узлов', 'время', 'токенов', 'состояние') `
               -Widths @(24, 10, 7, 10, 10, 16) -Rows $rows -RowColors $colors

$broken = @($runs | Where-Object { -not $_.Complete })
Write-Host ''
if ($broken.Count) {
    Write-BcfNote "оборванных: $($broken.Count). Доиграть: bcf run queue --resume $($broken[0].RunId)"
    Write-BcfNote 'узлы, успевшие завершиться, возьмутся из журнала и не будут пересчитаны.'
}
Write-BcfNote 'доска прогона: bcf board <runId>   ·   расход: bcf cost <runId>'
Write-Host ''
exit 0
