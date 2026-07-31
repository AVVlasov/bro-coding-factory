# bcf install — записать/обновить обвязку в проекте.
#
#   bcf install                  поставить недостающее, существующее не трогать
#   bcf install --force          перезаписать файлы обвязки (правки в них будут потеряны)
#   bcf install --dry            показать, что было бы записано
#   bcf install --only claude    только .claude (hooks/skills/commands/agents/settings)
#
# ПРИНЦИП: по умолчанию ничего не перезаписывается. Обвязка — это файлы, которые владелец
# правит под себя; молчаливая перезапись при обновлении фабрики означает потерю его
# правок, и заметит он это на следующем прогоне, а не сейчас.

. (Join-Path $BcfRoot 'src\lib\detect.ps1')

$force = $script:BcfArgs -contains '--force'
$dry   = $script:BcfArgs -contains '--dry'
$only  = ''
for ($i = 0; $i -lt $script:BcfArgs.Count; $i++) {
    if ($script:BcfArgs[$i] -eq '--only') { $only = [string]$script:BcfArgs[$i + 1] }
}

$project = $script:BcfProject
$templates = Get-BcfTemplates
$projName = Split-Path $project -Leaf

$written = @()
$skipped = @()

function Copy-BcfTemplate {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [switch]$Substitute
    )
    $rel = $To.Substring($project.Length).TrimStart('\', '/')
    if ((Test-Path $To) -and -not $force) { $script:skipped += $rel; return }

    if ($dry) { $script:written += $rel; return }

    New-Item -ItemType Directory -Force -Path (Split-Path $To -Parent) | Out-Null
    if ($Substitute) {
        $t = Get-Content -Raw -LiteralPath $From
        $t = $t -replace '\{\{PROJECT_NAME\}\}', $projName
        $t = $t -replace '\{\{PROJECT_ROOT\}\}', ($project -replace '\\', '/')
        $t = $t -replace '\{\{BCF_HOME\}\}', ((Get-BcfHome) -replace '\\', '/')
        Set-Content -LiteralPath $To -Value $t -Encoding UTF8 -NoNewline
    } else {
        Copy-Item -LiteralPath $From -Destination $To -Force
    }
    $script:written += $rel
}

function Copy-BcfTree {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To, [switch]$Substitute)
    if (-not (Test-Path $From)) { return }
    foreach ($f in (Get-ChildItem -LiteralPath $From -Recurse -File)) {
        $rel = $f.FullName.Substring($From.Length).TrimStart('\', '/')
        Copy-BcfTemplate -From $f.FullName -To (Join-Path $To $rel) -Substitute:$Substitute
    }
}

Write-BcfTitle "УСТАНОВКА ОБВЯЗКИ  $projName" `
               "$(if ($dry) { 'сухой прогон — ничего не пишется' } elseif ($force) { 'РЕЖИМ ПЕРЕЗАПИСИ' } else { 'существующие файлы не трогаем' })"

# --- .claude: хуки, скилы, команды, субагенты, settings -------------------------------
if (-not $only -or $only -eq 'claude') {
    Copy-BcfTree -From (Join-Path $templates 'claude\hooks')    -To (Join-Path $project '.claude\hooks') -Substitute
    Copy-BcfTree -From (Join-Path $templates 'claude\skills')   -To (Join-Path $project '.claude\skills') -Substitute
    Copy-BcfTree -From (Join-Path $templates 'claude\commands') -To (Join-Path $project '.claude\commands') -Substitute
    # Роли живут в ОДНОМ месте: .claude/agents. Их читает и Claude Code как субагентов,
    # и обвязка при верификации — держать две копии значит однажды править не ту.
    Copy-BcfTree -From (Join-Path $templates 'agents')          -To (Join-Path $project '.claude\agents')
    Copy-BcfTemplate -From (Join-Path $templates 'claude\settings.json') -To (Join-Path $project '.claude\settings.json')
}

# --- config: конфиги обвязки ----------------------------------------------------------
if (-not $only -or $only -eq 'config') {
    Copy-BcfTree -From (Join-Path $templates 'config') -To (Join-Path $project 'config')
}

# --- project: CLAUDE.md, каркас задач -------------------------------------------------
if (-not $only -or $only -eq 'project') {
    Copy-BcfTemplate -From (Join-Path $templates 'project\CLAUDE.md') -To (Join-Path $project 'CLAUDE.md') -Substitute
    if (-not $dry) {
        New-Item -ItemType Directory -Force -Path (Join-Path $project 'tasks') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $project 'tasks\.verdicts') | Out-Null
    }
}

# --- .gitignore: состояние прогонов и рабочие каталоги задач --------------------------
$giPath = Join-Path $project '.gitignore'
$giAdd = @('.bcf/', 'tasks/.verdicts/', 'tasks/.bugs/', 'tasks/CURRENT-FOCUS.md')
if (-not $dry) {
    $gi = if (Test-Path $giPath) { @(Get-Content -LiteralPath $giPath) } else { @() }
    $missing = @($giAdd | Where-Object { $gi -notcontains $_ })
    if ($missing.Count) {
        $block = @('', '# --- bcf: состояние прогонов (создаётся во время работы) ---') + $missing
        Add-Content -LiteralPath $giPath -Value ($block -join "`n") -Encoding UTF8
        $written += ".gitignore (+$($missing.Count) строк)"
    }
}

# --- карточка проекта -----------------------------------------------------------------
if (-not $dry) {
    $card = Get-BcfProjectCard -Project $project
    if (-not $card) {
        $card = [ordered]@{ name = $projName; created = (Get-Date -Format 'o') }
    }
    $card = $card | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $card | Add-Member -NotePropertyName 'installedBy' -NotePropertyValue ("bcf " + (Get-BcfVersion)) -Force
    $card | Add-Member -NotePropertyName 'installedAt' -NotePropertyValue (Get-Date -Format 'o') -Force
    $card | Add-Member -NotePropertyName 'bcfHome' -NotePropertyValue (Get-BcfHome) -Force
    Save-BcfProjectCard -Project $project -Card $card
}

# --- Отчёт ----------------------------------------------------------------------------
Write-BcfLine "  ЗАПИСАНО  $($written.Count)" 'White'
foreach ($w in ($written | Sort-Object)) { Write-BcfLine "    A  $w" 'Green' }
if (-not $written.Count) { Write-BcfDim '(нечего писать)' }

if ($skipped.Count) {
    Write-Host ''
    Write-BcfLine "  УЖЕ ЕСТЬ, НЕ ТРОНУТО  $($skipped.Count)" 'DarkGray'
    if ($skipped.Count -le 12) { foreach ($s in ($skipped | Sort-Object)) { Write-BcfDim $s } }
    else { Write-BcfDim "$(($skipped | Sort-Object | Select-Object -First 8) -join ', ') … и ещё $($skipped.Count - 8)" }
    Write-BcfNote 'Перезаписать целиком: bcf install --force (правки в этих файлах будут потеряны).'
}

if ($dry) {
    Write-Host ''
    Write-BcfWarn 'Сухой прогон: на диск ничего не записано.'
    Write-Host ''
    exit 0
}

# --- Что осталось сделать руками ------------------------------------------------------
$blocking = @()
$later = @()

$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { }
if ($cfg) {
    $rolesFilled = $cfg.graph -and $cfg.graph.roles -and
                   @($cfg.graph.roles.PSObject.Properties | Where-Object { $_.Name -ne '$comment' -and $_.Value.backend }).Count
    if (-not $rolesFilled) {
        $blocking += @{ what = 'роли графа не назначены (config/harness.json → graph.roles)'
                        why  = 'граф не знает, каким бэкендом исполнять узел, и упрётся на первом же.'
                        fix  = 'bcf init   (шаги 3–5 опросят установленные CLI и расставят модели)' }
    }
    if (-not @($cfg.backpressure.typecheck).Count) {
        $later += 'backpressure.typecheck пуст: ошибки компиляции всплывут только на верификации, то есть на несколько итераций позже.'
    }
    if (-not $cfg.tests.runner) {
        $later += 'tests.runner не задан: гейт «фича доказана тестами» не работает — задача может получить PASS без единого нового теста.'
    }
}

$claudeMd = Join-Path $project 'CLAUDE.md'
if ((Test-Path $claudeMd) -and (Select-String -Path $claudeMd -Pattern '^TODO$' -Quiet)) {
    $later += 'CLAUDE.md — заготовка с TODO. Пока он пуст, приёмке нечем обосновать блокировку, и ревью превращается в спор о вкусах.'
}
$later += 'память не подключена по умолчанию: без неё прогоны не учатся на прошлых ошибках — bcf memory init.'

Write-BcfManualActions -Blocking $blocking -Later $later

Write-Host ''
Write-BcfLine '  ДАЛЬШЕ' 'White'
Write-Host '    bcf doctor         живая проба всех ролей — без работы'
Write-Host '    bcf tasks          что уже есть в бэклоге'
Write-Host '    bcf run queue      первая волна'
Write-Host ''
exit 0
