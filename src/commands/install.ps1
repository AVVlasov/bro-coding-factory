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

# --only без значения или с чужим значением РАНЬШЕ молча означало полную установку —
# то есть флаг сужения области делал ровно обратное тому, ради чего его написали.
$ONLY_VALUES = @('claude', 'config', 'project')
for ($i = 0; $i -lt $script:BcfArgs.Count; $i++) {
    if ($script:BcfArgs[$i] -ne '--only') { continue }
    $only = if ($i + 1 -lt $script:BcfArgs.Count) { [string]$script:BcfArgs[$i + 1] } else { '' }
    if (-not $only -or $only.StartsWith('-')) {
        Write-BcfFail '--only требует значения'
        Write-BcfNote "доступно: $($ONLY_VALUES -join ' | ')"
        exit 2
    }
    if ($ONLY_VALUES -notcontains $only) {
        Write-BcfFail "--only $only — неизвестная область"
        Write-BcfNote "доступно: $($ONLY_VALUES -join ' | ')"
        exit 2
    }
}

$project = $script:BcfProject
$templates = Get-BcfTemplates
$projName = Split-Path $project -Leaf

$written = @()
$skipped = @()
$refused = @()

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
        $t = $t -replace '\{\{BASH_PATH\}\}', ($bashPath -replace '\\', '/')
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

# --- bash для settings.json -------------------------------------------------------------
#
# Claude Code исполняет command хука буквально. Голый 'bash' на Windows чаще всего находит
# ЛАУНЧЕР WSL (C:\Windows\System32\bash.exe) раньше настоящего Git Bash: на неинициализиро-
# ванном дистрибутиве первый же хук уходит в интерактивную настройку и виснет на stdin, а
# без дистрибутива — падает с ненулевым кодом. Поэтому settings.json пишется с ПОЛНЫМ путём
# к bash, а не с именем команды. Резолв — тем же правилом, что у остального харнесса
# (Get-BcfBash: BCF_BASH → git --exec-path → известные каталоги → PATH без WSL).
#
# Проверяем ТОЛЬКО когда settings.json реально будет записан: повторный install без
# --force его не трогает, и требовать bash ради файлов, которые и так не запишутся, —
# значит однажды заблокировать безобидное обновление hooks/skills на машине, где Git Bash
# временно не резолвится.
#
# НЕ НАШЁЛ — НЕ ЗНАЧИТ «ОСТАНОВИТЬ ВЕСЬ INSTALL». `bcf init` вызывает install как подпроцесс
# и следующим шагом читает config/harness.json (init-write.ps1) — упади install целиком,
# и init свалился бы необработанным исключением на файле, которого больше не пишут по
# другой, не связанной с bash причине. Поэтому отказ точечный: settings.json остаётся
# незаписанным (заготовка не спрятана и не тронута, если уже была), всё остальное ставится
# как обычно, а команда завершается ненулевым кодом — молчаливо-частичная установка хуже
# явного отказа с причиной.
$settingsPath = Join-Path $project '.claude\settings.json'
$willWriteSettings = (-not $only -or $only -eq 'claude') -and ((-not (Test-Path $settingsPath)) -or $force)
$bashPath = ''
$bashRefused = $false
if ($willWriteSettings) {
    . (Join-Path (Get-BcfHarness) 'lib\bcf-context.ps1')
    $bashPath = Get-BcfBash
    if (-not $bashPath) {
        $bashRefused = $true
        Write-BcfFail 'settings.json НЕ будет записан: настоящий Git Bash не найден'
        Write-BcfNote 'голый "bash" на Windows чаще ловит лаунчер WSL — хук либо зависает на неинициализиро-'
        Write-BcfNote 'ванном дистрибутиве, либо падает молча, и это выглядит как поломка обвязки, а не bash.'
        Write-BcfNote 'поставь Git for Windows: https://git-scm.com/download/win — bash найдётся сам через git --exec-path.'
        Write-BcfNote 'уже стоит не в обычном месте — укажи путь явно: $env:BCF_BASH = "C:\путь\к\bash.exe"'
        Write-BcfNote 'остальное поставится как обычно; довести настройку: bcf install --only claude (после того как bash найдётся).'
        Write-Host ''
    }
}

# --- .claude: хуки, скилы, команды, субагенты, settings -------------------------------
if (-not $only -or $only -eq 'claude') {
    Copy-BcfTree -From (Join-Path $templates 'claude\hooks')    -To (Join-Path $project '.claude\hooks') -Substitute
    Copy-BcfTree -From (Join-Path $templates 'claude\skills')   -To (Join-Path $project '.claude\skills') -Substitute
    Copy-BcfTree -From (Join-Path $templates 'claude\commands') -To (Join-Path $project '.claude\commands') -Substitute
    # Роли живут в ОДНОМ месте: .claude/agents. Их читает и Claude Code как субагентов,
    # и обвязка при верификации — держать две копии значит однажды править не ту.
    Copy-BcfTree -From (Join-Path $templates 'agents')          -To (Join-Path $project '.claude\agents')
    # Тексты критиков приёмки ложатся туда же, рядом с тестерами: .claude/agents/critics/.
    # Пока они жили строками внутри графа, проект не мог поправить ни одного вопроса —
    # приёмка чужого продукта шла ракурсами, написанными под другой продукт.
    Copy-BcfTree -From (Join-Path $templates 'claude\agents')   -To (Join-Path $project '.claude\agents')
    if ($bashRefused) {
        $script:refused += $settingsPath.Substring($project.Length).TrimStart('\', '/')
    } else {
        Copy-BcfTemplate -From (Join-Path $templates 'claude\settings.json') -To $settingsPath -Substitute
    }
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
        New-Item -ItemType Directory -Force -Path (Join-Path $project 'tasks\.claims') | Out-Null
    }
}

# --- .gitignore: состояние прогонов и рабочие каталоги задач --------------------------
#
# ВЕРДИКТОВ ЗДЕСЬ НЕТ, И ЭТО ГЛАВНОЕ ИЗМЕНЕНИЕ.
#
# `tasks/.verdicts/` лежал в этом списке, пока фабрику вела одна машина. В команде это
# значит, что закрытая задача существует ровно у одного человека: второй видит бэклог,
# в котором не закрыто ничего, и его фабрика честно берётся строить поверх несделанного.
# Вердикт — такой же результат работы, как код, и едет в git вместе с задачей.
#
# Каталог заявок (`tasks/.claims/`) не игнорируется по той же причине: заявка, которой
# не видно у соседа, не заявка.
$giPath = Join-Path $project '.gitignore'
$giAdd = @('.bcf/', 'tasks/.bugs/', 'tasks/CURRENT-FOCUS.md')
$gi = if (Test-Path $giPath) { @(Get-Content -LiteralPath $giPath) } else { @() }

# Установка поверх проекта, где вердикты уже спрятаны прежней версией: строку надо снять,
# иначе всё остальное сделано, а вердикты по-прежнему никуда не едут — и молча.
$giStale = @('tasks/.verdicts/', 'tasks/.verdicts', 'tasks/.claims/', 'tasks/.claims')
$giDrop = @($gi | Where-Object { $giStale -contains $_.Trim() })
if ($giDrop.Count) {
    if ($dry) { $written += ".gitignore (-$($giDrop.Count) строк: $($giDrop -join ', ') — вердикты и заявки едут в git)" }
    else {
        $gi = @($gi | Where-Object { $giStale -notcontains $_.Trim() })
        Set-Content -LiteralPath $giPath -Value ($gi -join "`n") -Encoding UTF8
        $written += ".gitignore (-$($giDrop.Count) строк: вердикты и заявки больше не прячутся)"
    }
}

$giMissing = @($giAdd | Where-Object { $gi -notcontains $_ })
if ($giMissing.Count) {
    # Сухой прогон обязан назвать И ЭТО. Показывать половину изменений — значит выдавать
    # за план то, что планом не является: человек соглашается на одно, получает другое.
    if ($dry) { $written += ".gitignore (+$($giMissing.Count) строк: $($giMissing -join ', '))" }
    else {
        $block = @('', '# --- bcf: состояние прогонов (создаётся во время работы) ---') + $giMissing
        Add-Content -LiteralPath $giPath -Value ($block -join "`n") -Encoding UTF8
        $written += ".gitignore (+$($giMissing.Count) строк)"
    }
}
if ($dry) {
    if (-not (Test-Path (Join-Path $project 'tasks')))          { $written += 'tasks/ (каталог)' }
    if (-not (Test-Path (Join-Path $project 'tasks\.verdicts'))) { $written += 'tasks/.verdicts/ (каталог)' }
    if (-not (Test-Path (Join-Path $project 'tasks\.claims')))   { $written += 'tasks/.claims/ (каталог заявок)' }
    $written += '.bcf/project.json (карточка проекта)'
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

# Обвязка, лежащая ВНЕ .claude (старая раскладка: agents/ и hooks/ в корне). Молча
# поставить рядом вторую копию — значит развести два набора ролей и хуков, из которых
# правят один, а исполняется другой. Это не блокер, но человек обязан узнать об этом
# сейчас, а не на прогоне, который пошёл по чужой роли.
$legacyDirs = @()
foreach ($d in @('agents', 'hooks')) {
    $p2 = Join-Path $project $d
    if (Test-Path $p2) {
        $n = @(Get-ChildItem $p2 -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n) { $legacyDirs += "$d/ ($n файлов)" }
    }
}
if ($legacyDirs.Count -and -not $only) {
    Write-Host ''
    Write-BcfWarn "в проекте уже есть обвязка вне .claude: $($legacyDirs -join ', ')"
    Write-BcfNote 'она осталась от старой раскладки. Роли и хуки теперь читаются из .claude/,'
    Write-BcfNote 'то есть рядом появился ВТОРОЙ набор: правят один, исполняется другой.'
    Write-BcfNote 'сверь их и удали лишнее; на что ссылается config/agents.json — проверь отдельно.'
}

if ($skipped.Count) {
    Write-Host ''
    Write-BcfLine "  УЖЕ ЕСТЬ, НЕ ТРОНУТО  $($skipped.Count)" 'DarkGray'
    if ($skipped.Count -le 12) { foreach ($s in ($skipped | Sort-Object)) { Write-BcfDim $s } }
    else { Write-BcfDim "$(($skipped | Sort-Object | Select-Object -First 8) -join ', ') … и ещё $($skipped.Count - 8)" }
    Write-BcfNote 'Перезаписать целиком: bcf install --force (правки в этих файлах будут потеряны).'
}

if ($refused.Count) {
    Write-Host ''
    Write-BcfLine "  НЕ ЗАПИСАНО: bash не найден  $($refused.Count)" 'Red'
    foreach ($r in $refused) { Write-BcfFail "    $r" }
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

if ($refused.Count) { exit 2 }
exit 0
