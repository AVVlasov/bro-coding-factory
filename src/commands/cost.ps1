# bcf cost — расход прогона: токены и, если тарифы заданы, деньги.
#
#   bcf cost              последний прогон
#   bcf cost <runId>      конкретный
#   bcf cost --all        все прогоны разом
#   bcf cost --json       машиночитаемо
#
# ЗАЧЕМ ОТДЕЛЬНОЙ КОМАНДОЙ. `bcf init` намеренно не говорит о деньгах: он настраивает, а
# не продаёт, и решение «каким бэкендом исполнять роль» там принимается по ярусу. Цена
# спрашивается тогда, когда её действительно хотят знать.

. (Join-Path $BcfRoot 'src\lib\journal.ps1')
. (Join-Path $BcfRoot 'src\lib\pricing.ps1')

$project = $script:BcfProject
$all = $script:BcfArgs -contains '--all'
$asJson = $script:BcfArgs -contains '--json'
$runId = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1

$runs = if ($all) { Get-BcfRuns -Project $project } else { @(Resolve-BcfRun -Project $project -RunId $runId) | Where-Object { $_ } }
if (-not $runs.Count) {
    if ($runId) { Write-BcfFail "прогон '$runId' не найден" } else { Write-BcfDim 'прогонов ещё не было — считать нечего' }
    exit 2
}

$pricing = Get-BcfPricing -Project $project
$cur = if ($pricing) { $pricing.Currency } else { 'USD' }

if ($asJson) {
    $out = foreach ($r in $runs) {
        $byRole = Get-BcfRunByRole -Run $r
        [ordered]@{
            runId = $r.RunId; name = $r.Name; tokens = $r.Tokens
            roles = @($byRole | ForEach-Object {
                [ordered]@{ role = $_.Role; model = $_.Model; nodes = $_.Nodes; tokens = $_.Tokens
                            cost = (Get-BcfNodeCost -Pricing $pricing -Model $_.Model -Tokens $_.Tokens) }
            })
        }
    }
    ($out | ConvertTo-Json -Depth 8) | Write-Output
    exit 0
}

$sub = if ($pricing) { "тарифы от $($pricing.Updated) · $($pricing.Source)" } else { 'тарифы не заданы — только токены' }
Write-BcfTitle "РАСХОД  $(Split-Path $project -Leaf)" $sub

$grandTokens = 0.0
$grandCost = 0.0
$anyUnknown = $false

foreach ($r in $runs) {
    if ($runs.Count -gt 1) {
        Write-Host ''
        Write-BcfLine ("  {0}  ·  {1}  ·  {2}" -f $r.RunId, $r.Name, $r.Started.ToString('yyyy-MM-dd HH:mm')) 'Cyan'
    }
    $byRole = Get-BcfRunByRole -Run $r
    $rows = New-BcfRows
    foreach ($b in $byRole) {
        $c = Get-BcfNodeCost -Pricing $pricing -Model $b.Model -Tokens $b.Tokens
        if ($null -eq $c -and $b.Tokens -gt 0) { $anyUnknown = $true }
        if ($null -ne $c) { $grandCost += $c }
        Add-BcfRow $rows @($b.Role, $(if ($b.Model) { $b.Model } else { '—' }), "$($b.Nodes)", "$([int]$b.Tokens)", (Format-BcfMoney $c $cur))
    }
    Add-BcfRow $rows @('итого', '', "$($r.NodeCount)", "$([int]$r.Tokens)", '')
    $grandTokens += $r.Tokens
    Write-Host ''
    Write-BcfTable -Headers @('роль', 'модель', 'узлов', 'токенов', 'деньги') `
                   -Widths @(12, 30, 7, 12, 14) -Rows $rows

    # Куда ушли деньги — по фазам, а не по узлам. Узлов десятки, и построчный список
    # ничего не объясняет; фаза объясняет: «приёмка съела половину» — это решение о
    # том, что менять.
    $byPhase = @{}
    foreach ($n in $r.Nodes) {
        $ph = if ($n.Phase) { $n.Phase } else { '(без фазы)' }
        if (-not $byPhase.ContainsKey($ph)) { $byPhase[$ph] = 0.0 }
        $byPhase[$ph] += [double]$n.Tokens
    }
    if ($r.Tokens -gt 0 -and $byPhase.Count -gt 1) {
        Write-Host ''
        foreach ($ph in ($byPhase.Keys | Sort-Object { -$byPhase[$_] })) {
            $pct = [int](100.0 * $byPhase[$ph] / $r.Tokens)
            $bar = ('█' * [math]::Max(0, [int]($pct / 3))).PadRight(33, '░')
            Write-BcfLine ("    {0,-12} {1} {2,3}%   {3} ток." -f $ph, $bar, $pct, [int]$byPhase[$ph]) 'DarkGray'
        }
    }

    # Узлы, которые пришли нулевыми при живой работе. Это не «бесплатно», это «бэкенд не
    # сообщил расход» — и на такой роли бюджетный ограничитель слеп.
    $zero = @($r.Nodes | Where-Object { $_.Tokens -eq 0 -and $_.Ok -eq $true -and -not $_.Cached -and -not $_.Dry })
    if ($zero.Count) {
        Write-Host ''
        Write-BcfWarn "$($zero.Count) узлов отработали с нулевым расходом — их бэкенд не сообщает токены"
        Write-BcfNote "затронуты роли: $((@($zero | ForEach-Object { $_.Role } | Where-Object { $_ } | Select-Object -Unique)) -join ', ')"
        Write-BcfNote 'бюджетный ограничитель на них не работает: потолок «до исчерпания» не сработает никогда.'
    }
}

Write-Host ''
if ($runs.Count -gt 1) {
    Write-BcfLine ("  ВСЕГО за $($runs.Count) прогонов: $([int]$grandTokens) токенов" + $(if ($pricing) { " · $(Format-BcfMoney $grandCost $cur)" } else { '' })) 'White'
}

if (-not $pricing) {
    Write-Host ''
    Write-BcfWarn 'тарифы не заданы — деньги не считаются'
    Write-BcfNote 'положи config/pricing.json (или memory/pricing.json в фабрике):'
    Write-BcfNote '{ "updated": "2026-07-31", "currency": "USD", "rate": 1.0,'
    Write-BcfNote '  "models": { "opus": { "input": 15, "output": 75 } } }   ← цена за 1M токенов'
} elseif ($anyUnknown) {
    Write-Host ''
    Write-BcfWarn 'для части моделей тарифа нет — их стоимость показана как «—», а не как ноль'
    Write-BcfNote 'ноль в колонке денег читается как «бесплатно», и это единственная ошибка,'
    Write-BcfNote "которую отчёт о расходе не имеет права делать. Допиши модели в $($pricing.Source)."
}
Write-Host ''
exit 0
