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
. (Join-Path $BcfRoot 'src\lib\tui.ps1')   # Test-BcfInteractive: спрашивать ли подтверждение

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
# Живость — по пульсу воркеров тоже: между node-start и node-finish журнал молчит,
# и по нему одному идущий прогон выглядит оборванным уже через полторы минуты.
$live = $run -and (Test-BcfRunLive -Run $run -Project $project)

# СЕБЯ И СВОИХ РОДИТЕЛЕЙ В СПИСОК НЕ БЕРЁМ.
#
# Отбор идёт по «путь проекта встречается в командной строке», а у самой команды
# `bcf stop --now --project D:\proj` он там, разумеется, есть — как и у оболочки, из
# которой её запустили. Цикл снятия доходил до собственного PID и убивал сам себя:
# часть агентов оставалась жить, итоговая строка не печаталась вовсе, и снаружи это
# выглядело как «аварийный тормоз сработал».
$selfChain = @{}
try {
    $pid_ = $PID
    for ($d = 0; $d -lt 8 -and $pid_; $d++) {
        $selfChain[$pid_] = $true
        $pp = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
        if (-not $pp) { break }
        $pid_ = [int]$pp.ParentProcessId
    }
} catch { $selfChain[$PID] = $true }

# Смотрелки — не агенты. `bcf watch` в соседнем окне подходит под тот же отбор, но
# снимать читателя журнала бессмысленно и обидно.
$viewers = 'bcf\.ps1["'']?\s+(watch|board|report|runs|log|tasks|cost|stop)\b'

$procs = @()
try {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($project) -and
                              $_.Name -match 'pwsh|powershell|node|python|claude|opencode|codex|cursor-agent' -and
                              -not $selfChain.ContainsKey([int]$_.ProcessId) -and
                              $_.CommandLine -notmatch $viewers })
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
    # ВОПРОС, КОТОРЫЙ НЕКОМУ УСЛЫШАТЬ, — НЕ ОТКАЗ ЧЕЛОВЕКА.
    #
    # Из скрипта, планировщика или чужого агента подтверждения не будет никогда: запрос
    # уходит в никуда и команда печатает «отменено», как будто владелец передумал.
    # Снаружи это выглядит как сработавшая остановка — а прогон продолжает писать в
    # дерево. Аварийная команда обязана называть НАСТОЯЩУЮ причину бездействия и то,
    # чем её обойти; авто-подтверждать снятие процессов за человека она не вправе.
    if (-not (Test-BcfInteractive)) {
        Write-BcfFail 'подтвердить снятие некому: команда запущена не из терминала'
        Write-BcfNote 'ничего не снято, прогон продолжает работать.'
        Write-BcfNote 'из скрипта: bcf stop --now --yes   ·   мягко, между задачами: bcf stop'
        Write-Host ''
        exit 130
    }
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

# Отказ снятия НЕ глотаем. Пустой catch превращал «восемь агентов отказались умирать» в
# зелёное «снято процессов: 0»: человек уходил уверенный, что тормоз сработал, а прогон
# продолжал писать в дерево. Аварийная команда обязана говорить, что не сработала.
$killed = 0
$stubborn = @()
foreach ($p in $procs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ }
    catch { $stubborn += [pscustomobject]@{ Pid = $p.ProcessId; Name = $p.Name; Why = $_.Exception.Message } }
}

Write-Host ''
if ($killed) { Write-BcfOk "снято процессов: $killed" }

if ($stubborn.Count) {
    Write-BcfFail "НЕ снято: $($stubborn.Count) — эти процессы продолжают работать"
    foreach ($s in ($stubborn | Select-Object -First 8)) {
        Write-BcfNote ("pid {0,-7} {1,-12} {2}" -f $s.Pid, $s.Name, (($s.Why -split "`r?`n")[0]))
    }
    Write-BcfNote 'чаще всего это права: процесс запущен из другой сессии или с повышением.'
    Write-BcfNote 'сними их вручную (Диспетчер задач) или повтори из той же сессии, где они стартовали.'
    Write-BcfNote 'запрос на остановку .bcf/STOP уже записан — следующую задачу оркестратор не возьмёт.'
    Write-Host ''
    exit 1
}

if (-not $killed) {
    Write-BcfDim 'снимать оказалось нечего — процессы завершились сами, пока команда спрашивала'
    Write-Host ''
    exit 0
}

Write-BcfNote 'заявки на файлы: bcf tasks покажет коллизии; снять руками — .bcf/fleet/claims.json'
Write-BcfNote 'вернуть возможность запуска: bcf stop --clear'
Write-Host ''
exit 0
