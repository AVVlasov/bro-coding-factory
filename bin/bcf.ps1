# bcf.ps1 — единственная точка входа фабрики.
#
# Фабрика ставит и водит обвязку в ЧУЖИХ проектах, поэтому у любой команды есть два
# адреса: где лежит движок (здесь) и над чем он работает (--project, иначе текущий
# репозиторий). Разбор аргументов намеренно ручной, а не через param(): подкоманды
# принимают свои флаги, и общий param() съел бы их молча.

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    if ($IsWindows -ne $false) { chcp 65001 | Out-Null }
} catch { }

$BcfRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $BcfRoot 'src\lib\paths.ps1')
. (Join-Path $BcfRoot 'src\lib\ui.ps1')

$COMMANDS = [ordered]@{
    'setup'    = @{ file = 'setup.ps1';    help = 'сделать команду bcf доступной из любого каталога (PATH)' }
    'init'     = @{ file = 'init.ps1';     help = 'настроить фабрику под проект — восемь шагов, всё в текстовые файлы' }
    'install'  = @{ file = 'install.ps1';  help = 'записать/обновить обвязку в проекте: .claude, config, agents, tasks' }
    'migrate'  = @{ file = 'migrate.ps1';  help = 'перенести состояние прогонов из старого каталога loop/ в .bcf/' }
    'doctor'   = @{ file = 'doctor.ps1';   help = 'живая проба окружения: бэкенды, авторизации, память, проверки' }
    'detect'   = @{ file = 'detect.ps1';   help = 'разбор проекта: языки, сборка, тесты, git — ничего не пишет' }
    'tasks'    = @{ file = 'tasks.ps1';    help = 'бэклог: что готово к работе, что ждёт, что закрыто' }
    'run'      = @{ file = 'run.ps1';      help = 'прогон: loop <TASK> | queue | review | night' }
    'runs'     = @{ file = 'runs.ps1';     help = 'журналы прошлых прогонов графа' }
    'board'    = @{ file = 'board.ps1';    help = 'доска прогона: узлы, роли, стоимость' }
    'report'   = @{ file = 'report.ps1';   help = 'итог прогона одним экраном' }
    'cost'     = @{ file = 'cost.ps1';     help = 'расход: токены → деньги, подписки против API' }
    'memory'   = @{ file = 'memory.ps1';   help = 'векторная память: init | status | ask | stats' }
    'research' = @{ file = 'research.ps1'; help = 'разведка задачи до работы — только чтение' }
    'prd'      = @{ file = 'prd.ps1';      help = 'опрос по продукту → docs/PRD.md' }
    'meta'     = @{ file = 'meta.ps1';     help = 'мета-слой: реестр проектов, аудит, вики, шаблоны' }
}

function Show-BcfHelp {
    $v = Get-BcfVersion
    Write-Host ''
    Write-BcfLine "  BRO CODING FACTORY v$v" 'Cyan'
    Write-BcfLine '  кодовая фабрика: ставит обвязку в любой проект и водит её — циклом или графом' 'DarkGray'
    Write-Host ''
    Write-BcfLine '  bcf <команда> [аргументы] [--project <путь>]' 'White'
    Write-Host ''
    foreach ($k in $COMMANDS.Keys) {
        Write-Host ("    {0,-10} {1}" -f $k, $COMMANDS[$k].help)
    }
    Write-Host ''
    Write-BcfLine '  общие флаги' 'DarkGray'
    Write-Host '    --project <путь>   над каким проектом работать (по умолчанию — текущий репозиторий)'
    Write-Host '    --yes              не задавать вопросов: везде берётся значение по умолчанию'
    Write-Host '    --no-color         вывод без цвета'
    Write-Host ''
    Write-BcfLine '  с чего начать' 'DarkGray'
    Write-Host '    bcf setup          сделать команду bcf доступной из любого каталога'
    Write-Host '    cd <проект>        дальше --project не нужен: берётся текущий репозиторий'
    Write-Host '    bcf                карточка состояния и выбор запуска'
    Write-Host '    bcf init           настроить фабрику под проект'
    Write-Host '    bcf doctor         проверить, что прогон вообще поедет'
    Write-Host '    bcf run queue      первая волна'
    Write-Host ''
}

# --- Разбор общих флагов ---
$argv = @($args)
$cmd = ''
$rest = @()
$projectArg = ''

for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = [string]$argv[$i]
    switch -Regex ($a) {
        '^(--project|-p)$' { $i++; $projectArg = [string]$argv[$i]; continue }
        '^--project=(.+)$' { $projectArg = $Matches[1]; continue }
        '^(--yes|-y)$'     { Set-BcfAssumeYes $true; continue }
        '^--no-color$'     { $env:BCF_NO_COLOR = '1'; $script:BcfNoColor = $true; continue }
        '^(--help|-h)$'    { if (-not $cmd) { Show-BcfHelp; exit 0 } else { $rest += $a }; continue }
        '^(--version|-V)$' { Write-Host (Get-BcfVersion); exit 0 }
        default {
            # Флаг ДО имени команды принадлежит команде по умолчанию (`launch`), а не
            # является именем команды. Иначе `bcf --screen` жалуется на «неизвестную
            # команду --screen» вместо того, чтобы передать флаг тому, кто его понимает.
            if (-not $cmd -and $a.StartsWith('-')) { $rest += $a }
            elseif (-not $cmd) { $cmd = $a }
            else { $rest += $a }
        }
    }
}

# `bcf` без аргументов — НЕ справка, а карточка состояния и выбор запуска.
#
# Решение «что запускать» принимается по состоянию: сколько задач готово, отвечают ли
# бэкенды, жива ли память, во что это обойдётся. Список команд ничего из этого не
# показывает — человек всё равно идёт смотреть сам, а потом запускает по памяти.
if (-not $cmd) { $cmd = 'launch' }
if ($cmd -in @('help', '--help')) { Show-BcfHelp; exit 0 }
if ($cmd -in @('version', '--version')) { Write-Host (Get-BcfVersion); exit 0 }

if ($cmd -eq 'launch') { $COMMANDS['launch'] = @{ file = 'launch.ps1'; help = '' } }

if (-not $COMMANDS.Contains($cmd)) {
    Write-BcfFail "Неизвестная команда: $cmd"
    $near = @($COMMANDS.Keys | Where-Object { $_.StartsWith($cmd.Substring(0, [math]::Min(2, $cmd.Length))) })
    if ($near.Count) { Write-BcfNote "Похоже на: $($near -join ', ')" }
    Write-BcfNote 'Список команд: bcf help'
    exit 2
}

# Корень проекта резолвится ЗДЕСЬ и передаётся дальше переменной окружения: подкоманды
# и весь харнесс читают одну и ту же величину, и разъехаться им негде.
$project = ''
try { $project = Resolve-BcfProject -Path $projectArg }
catch { Write-BcfFail $_.Exception.Message; exit 2 }
$env:BCF_PROJECT_ROOT = $project
$env:BCF_HOME = $BcfRoot

$script:BcfArgs = $rest
$script:BcfProject = $project

$file = Join-Path $BcfRoot ('src\commands\' + $COMMANDS[$cmd].file)
if (-not (Test-Path $file)) {
    Write-BcfFail "Команда '$cmd' объявлена, но её файл не найден: $file"
    exit 3
}

. $file
exit $LASTEXITCODE
