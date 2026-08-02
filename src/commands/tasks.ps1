# bcf tasks — бэклог: что закрыто, что готово к работе, что ждёт.
#
#   bcf tasks              состояние очереди
#   bcf tasks --json       машиночитаемо
#
# Готовность считается ДЕТЕРМИНИРОВАННО, тем же способом, что и в планировщике: задача
# готова, если все её предшественники имеют verdict: PASS. Спрашивать об этом модель
# значит платить за угадывание уже известного.

$project = $script:BcfProject
$asJson = $script:BcfArgs -contains '--json'

# Разбор очереди — общим проходом (src/lib/queue.ps1), тем же, что у карточки состояния
# и у мастера. Своя копия здесь читала ДРУГОЕ поле, и на реальном проекте это дало
# одиннадцать задач «готова» при пяти заблокированных плюс совет «запустить готовые».
. (Join-Path $BcfRoot 'src\lib\queue.ps1')

$q = Get-BcfQueue -Project $project
$prefix = $q.Prefix

if (-not $q.Exists) {
    Write-BcfDim "папки $($q.TasksRel)/ нет — bcf init"
    exit 2
}

$items = $q.Tasks

if ($asJson) {
    ($items | ConvertTo-Json -Depth 5) | Write-Output
    exit 0
}

$closed  = @($items | Where-Object { $_.Pass })
$ready   = @($items | Where-Object { $_.Ready })
$waiting = @($items | Where-Object { -not $_.Pass -and -not $_.Ready })

Write-BcfTitle "БЭКЛОГ  $(Split-Path $project -Leaf)" `
               "всего $($items.Count) · закрыто $($closed.Count) · готово к работе $($ready.Count) · ждёт $($waiting.Count)"

if (-not $items.Count) {
    Write-BcfDim "задач нет: нарежь их в tasks/ по шаблону $prefix-01-example.md или командой /feature в кодовом агенте"
    Write-Host ''
    exit 0
}

function _trim([string]$s, [int]$n) {
    if (-not $s) { return '' }
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n - 1) + '…'
}
function _cells($t, $state) {
    $files = if ($t.Files.Count) { ($t.Files | Select-Object -First 2) -join ', ' } else { '(файлы не объявлены)' }
    if ($t.Files.Count -gt 2) { $files += " +$($t.Files.Count - 2)" }
    return @($t.Id, $state, (_trim $t.Title 30), (_trim $files 34))
}

$rows = New-BcfRows
$colors = @()
foreach ($t in $ready)   { Add-BcfRow $rows (_cells $t 'готова');  $colors += 'Green' }
foreach ($t in $waiting) { Add-BcfRow $rows (_cells $t "ждёт $($t.Preds -join ',')"); $colors += 'DarkGray' }
foreach ($t in $closed)  { Add-BcfRow $rows (_cells $t 'PASS');    $colors += 'DarkCyan' }

Write-BcfTable -Headers @('id', 'состояние', 'что', 'владеет файлами') `
               -Widths @(10, 18, 31, 35) -Rows $rows -RowColors $colors

# Коллизия владения — единственное, что здесь считается сверх состояния. Две задачи на
# одном файле без предшествования планировщик пустит в одну волну, и арбитр будет сводить
# два независимых переписывания: ярус слияния дороже и рискованнее прогона по очереди.
$owners = @{}
foreach ($t in $items) {
    if ($t.Pass) { continue }
    foreach ($f in $t.Files) {
        $k = ($f -replace '\\', '/').ToLower()
        if (-not $owners.ContainsKey($k)) { $owners[$k] = @() }
        $owners[$k] += $t
    }
}
$collisions = @()
foreach ($k in $owners.Keys) {
    $ts = @($owners[$k])
    if ($ts.Count -lt 2) { continue }
    for ($i = 0; $i -lt $ts.Count; $i++) {
        for ($j = $i + 1; $j -lt $ts.Count; $j++) {
            $a = $ts[$i]; $b = $ts[$j]
            if (($a.Preds -contains $b.Id) -or ($b.Preds -contains $a.Id)) { continue }
            $collisions += [pscustomobject]@{ File = $k; A = $a.Id; B = $b.Id }
        }
    }
}
if ($collisions.Count) {
    Write-Host ''
    Write-BcfLine "  ⚠ КОЛЛИЗИИ ВЛАДЕНИЯ  $($collisions.Count)" 'Yellow'
    foreach ($c in ($collisions | Select-Object -First 8)) {
        Write-BcfLine "    $($c.A) и $($c.B) владеют одним файлом: $($c.File)" 'Yellow'
    }
    Write-BcfNote 'предшествования между ними нет — планировщик пустит обе в одну волну, и арбитр'
    Write-BcfNote 'будет сводить два независимых переписывания одного файла. Это ярус слияния:'
    Write-BcfNote 'дороже и рискованнее, чем прогнать по очереди. Лечится строкой «Вход» в задаче.'
}

$noFiles = @($items | Where-Object { -not $_.Pass -and -not $_.Files.Count })
if ($noFiles.Count) {
    Write-Host ''
    Write-BcfWarn "задач без объявленных файлов: $($noFiles.Count) ($(($noFiles | ForEach-Object { $_.Id }) -join ', '))"
    Write-BcfNote 'без секции «Файлы» допуск не работает: задача возьмёт что угодно, и расползание'
    Write-BcfNote 'скоупа обнаружится только на слиянии.'
}

Write-Host ''
if ($ready.Count) { Write-BcfNote "запустить готовые: bcf run queue   ·   одну: bcf run loop $($ready[0].Id)" }
Write-Host ''
exit 0
