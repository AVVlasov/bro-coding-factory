# init-write.ps1 — шаг 8 мастера: то, что реально ложится на диск.
#
# Вынесено из init.ps1 отдельным файлом не ради длины: запись — единственная часть
# мастера с побочными эффектами, и держать её в одном месте значит иметь ровно одно
# место, где можно ошибиться необратимо.
#
# ПРАВИЛО ЭТОГО ФАЙЛА: заполняем пустое, не переписываем заполненное. Проект мог
# настраиваться руками или прошлой версией фабрики, и там уже стоят выверенные бэкенды с
# моделями — включая те, которые init угадать не может (имя модели задаёт подписка).
# Молча заменить их своими догадками значит сломать рабочую конфигурацию мастером,
# который человек запустил «просто посмотреть».

if ($dry) {
    Write-Host ('  ' + (Ink 'БЫЛО БЫ ЗАПИСАНО' 'White'))
    $out = & pwsh -NoProfile -File (Join-Path $BcfRoot 'bin\bcf.ps1') install --dry --project $root 2>&1 | Out-String
    foreach ($line in ($out -split "`r?`n")) { if ($line -match '^\s+A\s+') { Write-BcfLine $line 'Green' } }
    Write-BcfLine '    M  config/harness.json' 'Cyan'
    return
}

# 1. Обвязка ставится тем же кодом, что и `bcf install` — двух реализаций «что положить в
#    проект» быть не должно, они разъедутся на первом же изменении шаблонов.
$installOut = & pwsh -NoProfile -File (Join-Path $BcfRoot 'bin\bcf.ps1') install --project $root 2>&1 | Out-String

# 2. Конфиг: дописываем выясненное разбором и опросом.
$cfgPath = Join-Path $root 'config\harness.json'
$cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json

# Конфиг проекта бывает СТАРШЕ фабрики: в нём может не быть секций, появившихся позже.
# Обращение к отсутствующей секции роняет весь шаг записи — и падение выглядит как
# «init сработал», потому что конфиг остаётся нетронутым.
function _EnsureSection([string]$Name) {
    if (-not $cfg.PSObject.Properties[$Name]) {
        $cfg | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $cfg.$Name
}
function _EnsureKey($Obj, [string]$Name, $Default) {
    if (-not $Obj.PSObject.Properties[$Name]) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Default -Force
    }
}

_EnsureKey $cfg 'productPaths' @()
_EnsureKey $cfg 'generatedFiles' @()
$bp = _EnsureSection 'backpressure'; _EnsureKey $bp 'typecheck' @()
$ts = _EnsureSection 'tests';        _EnsureKey $ts 'runner' ''
$md = _EnsureSection 'models';       foreach ($k in @('code','tester','judge','vision')) { _EnsureKey $md $k '' }
$ag = _EnsureSection 'agent';        foreach ($k in @('command','adapter')) { _EnsureKey $ag $k '' }
$gr = _EnsureSection 'graph'
_EnsureKey $gr 'backends' ([pscustomobject]@{})
_EnsureKey $gr 'roles'    ([pscustomobject]@{})

function _SetIfEmpty([string]$Name, $Current, [scriptblock]$Apply) {
    $isEmpty = ($null -eq $Current) -or ($Current -is [string] -and -not $Current) -or
               ($Current -is [array] -and -not @($Current).Count)
    if ($isEmpty -or $reconfigure) { & $Apply; return }
    $script:kept += $Name
}

_SetIfEmpty 'productPaths'          $cfg.productPaths           { $cfg.productPaths = @($s2.ProductPaths) }
_SetIfEmpty 'generatedFiles'        $cfg.generatedFiles         { $cfg.generatedFiles = @($d.Generated) }
_SetIfEmpty 'backpressure.typecheck' $cfg.backpressure.typecheck { $cfg.backpressure.typecheck = @($s2.Typechecks) }
if ($d.Tests.runner) { _SetIfEmpty 'tests.runner' $cfg.tests.runner { $cfg.tests.runner = $d.Tests.runner } }

# Бэкенды дополняем, а не заменяем: у проекта может быть свой, которого нет в каталоге
# фабрики (собственная обёртка, локальная модель, форк CLI).
$surveyed = New-BcfBackendConfig -Survey $survey
foreach ($bk in $surveyed.Keys) {
    if ($cfg.graph.backends.PSObject.Properties[$bk] -and -not $reconfigure) { continue }
    $cfg.graph.backends | Add-Member -NotePropertyName $bk -NotePropertyValue ([pscustomobject]$surveyed[$bk]) -Force
}

foreach ($k in $roles.Keys) {
    $cur = $cfg.graph.roles.PSObject.Properties[$k]
    if ($cur -and $cur.Value.backend -and -not $reconfigure) { $kept += "graph.roles.$k"; continue }
    $entry = [ordered]@{ backend = $roles[$k].backend; model = $roles[$k].model }
    # Пишем ОБЪЕКТОМ: движок читает fallback.backend/fallback.model. Строка тоже
    # понимается (человек пишет её руками), но своё мы пишем в полной форме — чтобы в
    # конфиге было видно, на какую CLI уходит запасная.
    if ($roles[$k].fallback) {
        $fbv = $roles[$k].fallback
        $entry.fallback = if ($fbv -is [string]) {
            [pscustomobject]@{ backend = $roles[$k].backend; model = $fbv }
        } else { [pscustomobject]$fbv }
    }
    $cfg.graph.roles | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]$entry) -Force
}

# Цикл исполняется тем же бэкендом, что и worker графа: два разных исполнителя означали
# бы, что задача ведёт себя по-разному в зависимости от того, как её запустили.
$workerBackend = [string]$cfg.graph.roles.worker.backend
if ($workerBackend -and $cfg.graph.backends.PSObject.Properties[$workerBackend]) {
    _SetIfEmpty 'agent.command' $cfg.agent.command {
        $cfg.agent.command = $cfg.graph.backends.$workerBackend.command
        $cfg.agent.adapter = $cfg.graph.backends.$workerBackend.format
    }
}
$workerModel = [string]$cfg.graph.roles.worker.model
$criticModel = [string]$cfg.graph.roles.critic.model
if ($workerModel) { _SetIfEmpty 'models.code' $cfg.models.code { $cfg.models.code = $workerModel } }
if ($criticModel) {
    _SetIfEmpty 'models.tester' $cfg.models.tester { $cfg.models.tester = $criticModel }
    _SetIfEmpty 'models.judge'  $cfg.models.judge  { $cfg.models.judge  = $criticModel }
}

($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
$writtenFiles += 'config/harness.json'

# 3. Каркас бэклога.
$tasksDir = Join-Path $root 'tasks'
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$indexPath = Join-Path $tasksDir 'index.md'
if (-not (Test-Path $indexPath)) {
    Set-Content -LiteralPath $indexPath -Encoding UTF8 -Value @"
# Бэклог — $(Split-Path $root -Leaf)

Задачи именуются ``$prefix-<NN>-<slug>.md``. Планировщик строит волны по секциям
«Вход» (предшествования) и «Файлы» (владение): задачи без общих файлов и без общего
входа идут одновременно.

| id | что | владеет файлами | вход |
|----|-----|-----------------|------|
|    |     |                 |      |
"@
    $writtenFiles += 'tasks/index.md'
}
$existingTasks = @(Get-ChildItem $tasksDir -Filter "$prefix-*.md" -File -ErrorAction SilentlyContinue)
$samplePath = Join-Path $tasksDir "$prefix-01-example.md"
if (-not $existingTasks.Count -and -not (Test-Path $samplePath)) {
    $tpl = Get-Content -Raw -LiteralPath (Join-Path $templates 'project\task.md')
    $tpl = $tpl -replace '\{\{TASK_ID\}\}', "$prefix-01" -replace '\{\{TASK_TITLE\}\}', 'первая задача (шаблон — переписать)'
    Set-Content -LiteralPath $samplePath -Value $tpl -Encoding UTF8
    $writtenFiles += "tasks/$prefix-01-example.md"
}

# 4. Карточка проекта.
$card = Get-BcfProjectCard -Project $root
if (-not $card) { $card = [pscustomobject]@{} }
$card | Add-Member -NotePropertyName 'name'       -NotePropertyValue (Split-Path $root -Leaf) -Force
$card | Add-Member -NotePropertyName 'initAt'     -NotePropertyValue (Get-Date -Format 'o') -Force
$card | Add-Member -NotePropertyName 'bcfVersion' -NotePropertyValue (Get-BcfVersion) -Force
$card | Add-Member -NotePropertyName 'bcfHome'    -NotePropertyValue (Get-BcfHome) -Force
$card | Add-Member -NotePropertyName 'ecosystems' -NotePropertyValue @($d.Ecosystems) -Force
Save-BcfProjectCard -Project $root -Card $card

# --- Отчёт ------------------------------------------------------------------------------
Write-Host ('  ' + (Ink 'ЗАПИСАНО НА ДИСК' 'White'))
Write-Host ''
foreach ($line in ($installOut -split "`r?`n")) {
    if ($line -match '^\s+A\s+') { Write-BcfLine $line 'Green' }
}
foreach ($w in $writtenFiles) { Write-BcfLine "    M  $w" 'Cyan' }
Write-BcfLine '    A  .bcf/  (прогоны, заявки на файлы, журналы — в git не попадает)' 'Green'

if ($kept.Count) {
    Write-Host ''
    Write-Host ('  ' + (Ink "ОСТАВЛЕНО КАК БЫЛО  $($kept.Count)" 'DarkCyan'))
    Write-BcfNote 'эти значения уже были заполнены — init их не трогает:'
    foreach ($k in ($kept | Sort-Object -Unique)) { Write-BcfDim $k }
    Write-BcfNote 'заменить своими догадками: bcf init --reconfigure (существующее будет потеряно).'
}
