# bcf stop — остановить прогон.
#
#   bcf stop            попросить остановиться между задачами (мягко)
#   bcf stop --now      снять работающие процессы агентов
#   bcf stop --clear    убрать запрос на остановку
#
# ЗАЧЕМ КОМАНДА ДЛЯ ОДНОГО ФАЙЛА. Раньше остановка ночного прогона звучала как «создай
# файл .bcf/STOP». Это не инструкция, а требование помнить путь — в три часа ночи, когда
# прогон делает не то. Команда помнит его за тебя и заодно отвечает на вопрос, который
# сразу за этим следует: «а он вообще ещё идёт и когда остановится».
#
# ДВА РЕЖИМА, И РАЗНИЦА МЕЖДУ НИМИ ВАЖНА:
#   мягкий  — прогон дочитает текущую задачу и остановится сам. Работа не теряется:
#             итерация доводится до конца, вердикт пишется, worktree убирается.
#   --now   — снимает процессы. Текущая итерация теряется целиком, worktree остаётся
#             заклеймлённым, и следующая волна не возьмёт те же файлы, пока не убрать
#             заявку. Это аварийный тормоз, а не «побыстрее».

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$project = $script:BcfProject
$now   = $script:BcfArgs -contains '--now'
$clear = $script:BcfArgs -contains '--clear'

$stateDir = Join-Path $project '.bcf'
$stopFile = Join-Path $stateDir 'STOP'

Write-BcfTitle 'ОСТАНОВКА ПРОГОНА' (Split-Path $project -Leaf)

if ($clear) {
    if (Test-Path $stopFile) {
        Remove-Item -LiteralPath $stopFile -Force
        Write-BcfOk 'запрос на остановку убран — следующий прогон поедет'
    } else {
        Write-BcfDim 'запроса на остановку и не было'
    }
    Write-Host ''
    exit 0
}

# Что вообще сейчас происходит. Команда, которая молча создаёт файл, не отвечает на
# главный вопрос: было ли что останавливать.
$run = Get-BcfLastRun -Project $project
$live = $run -and (-not $run.Complete) -and (((Get-Date) - $run.Finished).TotalSeconds -lt 90)

$procs = @()
try {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($project) -and
                              $_.Name -match 'pwsh|powershell|node|python|claude|opencode|codex|cursor-agent' })
} catch { }

if ($live) {
    Write-BcfWarn "прогон идёт: $($run.Name) · $($run.RunId) · узлов $($run.NodeCount)"
} elseif ($run) {
    Write-BcfDim "последний прогон $($run.RunId) $(if ($run.Complete) { 'завершён' } else { 'оборван' }) — активного не видно"
} else {
    Write-BcfDim 'прогонов ещё не было'
}
if ($procs.Count) { Write-BcfNote "процессов, связанных с проектом: $($procs.Count)" }

# --- Мягкая остановка ------------------------------------------------------------------
if (-not $now) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    Set-Content -LiteralPath $stopFile -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Host ''
    Write-BcfOk 'запрошена остановка: .bcf/STOP'
    Write-BcfNote 'ночной прогон проверяет этот файл МЕЖДУ задачами — текущая задача'
    Write-BcfNote 'доработает до конца, её вердикт запишется, worktree уберётся.'
    Write-Host ''
    Write-BcfNote 'следить: bcf watch   ·   передумал: bcf stop --clear   ·   срочно: bcf stop --now'
    Write-Host ''
    exit 0
}

# --- Аварийный тормоз ------------------------------------------------------------------
Write-Host ''
Write-BcfWarn 'СНЯТИЕ ПРОЦЕССОВ — текущая итерация будет потеряна'
Write-BcfNote 'потеряется не «немного времени»: агент не допишет правку, вердикт не запишется,'
Write-BcfNote 'а worktree останется заклеймлённым — следующая волна не возьмёт те же файлы,'
Write-BcfNote 'пока заявка не снята. Работа задачи при этом сохранена в её ветке.'

if (-not $procs.Count) {
    Write-Host ''
    Write-BcfDim 'снимать нечего — процессов этого проекта не найдено'
    Write-Host ''
    exit 0
}

Write-Host ''
foreach ($p in ($procs | Select-Object -First 10)) {
    Write-BcfDim ("pid {0,-7} {1,-12} {2}" -f $p.ProcessId, $p.Name, ($p.CommandLine.Substring(0, [math]::Min(90, $p.CommandLine.Length))))
}

if (-not (Get-BcfAssumeYes)) {
    Write-Host ''
    if (-not (Read-BcfConfirm "снять $($procs.Count) процессов?" $false)) {
        Write-BcfDim 'отменено — ничего не снято'
        Write-Host ''
        exit 130
    }
}

# Файл-запрос ставим ТОЖЕ: иначе оркестратор, переживший снятие дочерних процессов,
# спокойно возьмёт следующую задачу — и получится, что остановка «не сработала».
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
Set-Content -LiteralPath $stopFile -Value (Get-Date -Format 'o') -Encoding UTF8

$killed = 0
foreach ($p in $procs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
}
Write-Host ''
Write-BcfOk "снято процессов: $killed"
Write-BcfNote 'заявки на файлы: bcf tasks покажет коллизии; снять руками — .bcf/fleet/claims.json'
Write-BcfNote 'вернуть возможность запуска: bcf stop --clear'
Write-Host ''
exit 0
