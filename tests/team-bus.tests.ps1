# team-bus.tests.ps1 — фабрику ведут с нескольких машин, и обмен между ними идёт по git.
#
#   pwsh tests/team-bus.tests.ps1
#
# ЧТО ЛОВЯТ ЭТИ ТЕСТЫ. Вердикты и заявки уже лежат в git, но сами по себе они никуда не
# едут: их видно после чужого pull и они уезжают после чьего-то push. Пока обоих движений
# нет в самом прогоне, остаются четыре дыры, и каждая обнаруживается поздно.
#
#   · Прогон стартует на отставшей ветке и строит поверх кода, которого у него нет.
#     Обнаруживается на слиянии — работой, которую надо выбрасывать.
#   · Ночной прогон пишет прямо в общую ветку: посмотреть на результат до того, как он
#     стал общим, человек уже не может.
#   · Отправка волны не удалась — и об этом сказано строкой в журнале, которую утром никто
#     не открывает. «Прогон закрыл всё» при этом звучит по-прежнему.
#   · Со стороны не видно, чем фабрика занята: доски задач нет, и «работает» неотличимо
#     от «умерла три часа назад».
#
# Origin здесь — настоящий bare-репозиторий во временном каталоге. Ни одного сетевого
# вызова и ни одного вызова модели: узел графа исполняется подставным агентом.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent                     # корень фабрики
$bcf  = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-bus-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ok   $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ПРОВАЛ  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Assert-True  { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-False { param($Cond, [string]$Msg = 'ожидалось ложное')  if ($Cond) { throw $Msg } }
function Assert-Eq {
    param($Actual, $Expected, [string]$Msg = '')
    if ("$Actual" -ne "$Expected") { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "ждал «$Expected», получил «$Actual»") }
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" +
               (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 20) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
$env:BCF_PROJECT_ROOT = $sandboxRoot
. (Join-Path $root 'harness\lib\claims.ps1')
. (Join-Path $root 'harness\lib\worktree.ps1')
. (Join-Path $root 'harness\lib\team-bus.ps1')

function New-Origin {
    param([string]$Name = 'origin')
    $d = Join-Path $sandboxRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.git')
    & git init --bare -q -b main $d 2>&1 | Out-Null
    return $d
}

# Проект участника: git, задачи, конфиг обвязки с ключами шины. Ровно то, что человек
# получает после `bcf install` и правки двух строк в config/harness.json.
function New-Member {
    param(
        [string]$Name = 'm',
        [string]$Origin = '',
        # $Remote — то, что попадёт в publish.remote конфига; $RemoteName — как remote
        # называется в самом git. Разные потому, что пустой publish.remote (публикация
        # выключена) не означает отсутствия origin в репозитории.
        [string]$Remote = 'origin',
        [string]$RemoteName = 'origin',
        [string]$Branch = 'main',
        [hashtable]$Tasks = @{}
    )
    $d = Join-Path $sandboxRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    & git -C $d init -q -b $Branch 2>&1 | Out-Null
    & git -C $d config user.email team@local 2>&1 | Out-Null
    & git -C $d config user.name 'команда' 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $d '.gitignore') -Value ".bcf/`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
    $cfg = [ordered]@{
        paths       = @{ tasks = 'tasks' }
        integration = @{ branch = $Branch }
        publish     = @{ remote = $Remote }
    }
    Set-Content -LiteralPath (Join-Path $d 'config\harness.json') -Encoding UTF8 `
        -Value (ConvertTo-Json -InputObject $cfg -Depth 5)
    foreach ($k in $Tasks.Keys) {
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $d "tasks\$k.md") -Value $Tasks[$k]
    }
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'исходное состояние' 2>&1 | Out-Null
    if ($Origin) {
        & git -C $d remote add $RemoteName $Origin 2>&1 | Out-Null
        & git -C $d push -q $RemoteName "${Branch}:${Branch}" 2>&1 | Out-Null
        & git -C $d fetch -q $RemoteName 2>&1 | Out-Null
    }
    return $d
}

function New-Commit {
    param([string]$Repo, [string]$File, [string]$Text, [string]$Message)
    Set-Content -LiteralPath (Join-Path $Repo $File) -Value $Text -Encoding UTF8
    & git -C $Repo add -A 2>&1 | Out-Null
    & git -C $Repo commit -q -m $Message 2>&1 | Out-Null
    return (& git -C $Repo rev-parse HEAD | Out-String).Trim()
}

function Get-Sha { param([string]$Repo, [string]$Ref) return (& git -C $Repo rev-parse --verify --quiet $Ref 2>$null | Out-String).Trim() }

Write-Host ''
Write-Host "  ШИНА КОМАНДЫ   песочница: $sandboxRoot" -ForegroundColor Cyan

# --- 1. Ключи конфига ---------------------------------------------------------------------
Write-Host ''
Write-Host '1. integration.branch и publish.remote: умолчания и чтение' -ForegroundColor White

It 'без ключей ветка интеграции — main, публикация выключена' {
    # Умолчание «не публиковать» обязано быть именно таким: фабрика на одной машине не
    # имеет ни remote, ни сети, и один сетевой вызов на старте сломал бы ей прогон.
    $p = Join-Path $sandboxRoot 'bare-config'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Assert-Eq (Get-BcfIntegrationBranch -Root $p) 'main'
    Assert-Eq (Get-BcfPublishRemote -Root $p) ''
}

It 'ключи читаются из config/harness.json' {
    $p = New-Member -Name 'cfg' -Remote 'upstream' -Branch 'develop'
    Assert-Eq (Get-BcfIntegrationBranch -Root $p) 'develop'
    Assert-Eq (Get-BcfPublishRemote -Root $p) 'upstream'
}

It 'шаблон конфига несёт оба ключа с умолчаниями' {
    # Ключ, которого нет в шаблоне, не существует для человека: он о нём не узнает.
    $tpl = Get-Content -Raw -LiteralPath (Join-Path $root 'templates\config\harness.json') | ConvertFrom-Json
    Assert-Eq $tpl.integration.branch 'main' 'в шаблоне нет ветки интеграции'
    Assert-Eq $tpl.publish.remote '' 'в шаблоне публикация включена по умолчанию — прогон полезет в сеть без спроса'
}

It 'имя ветки волны содержит дату и время до минут' {
    $n = Get-BcfWaveBranchName -When ([datetime]'2026-09-05 21:07:33')
    Assert-Eq $n 'bcf/wave/2026-09-05-2107' 'два прогона за день попадут в одну ветку'
}

# --- 2. Прогон начинается с чужой работы --------------------------------------------------
Write-Host ''
Write-Host '2. fetch и перемотка ветки интеграции' -ForegroundColor White

It 'ОТСТАВШАЯ ВЕТКА ПЕРЕМАТЫВАЕТСЯ ДО СОСТОЯНИЯ REMOTE' {
    $o = New-Origin
    $a = New-Member -Name 'a' -Origin $o
    $b = New-Member -Name 'b'
    & git -C $b remote add origin $o 2>&1 | Out-Null
    & git -C $b fetch -q origin 2>&1 | Out-Null
    & git -C $b reset -q --hard origin/main 2>&1 | Out-Null

    $sha = New-Commit -Repo $a -File 'src\colleague.rs' -Text 'работа коллеги' -Message 'коллега: своя правка'
    & git -C $a push -q origin main 2>&1 | Out-Null

    Assert-False (Test-Path (Join-Path $b 'src\colleague.rs')) 'фикстура не воспроизводит отставание'
    $r = Sync-IntegrationBranch -Root $b -Remote 'origin' -Branch 'main'
    Assert-True $r.Ok "перемотка не прошла: $($r.Reason)"
    Assert-Eq $r.Kind 'fast-forward'
    Assert-Eq (Get-Sha -Repo $b -Ref 'refs/heads/main') $sha 'ветка не догнала remote — прогон пойдёт поверх несуществующего кода'
    Assert-True (Test-Path (Join-Path $b 'src\colleague.rs')) 'работа коллеги не приехала в рабочее дерево'
}

It 'РАЗОШЕДШИЕСЯ ВЕТКИ ОСТАНАВЛИВАЮТ ПРОГОН И НАЗЫВАЮТ ПРИЧИНУ' {
    $o = New-Origin
    $a = New-Member -Name 'ff-a' -Origin $o
    $b = New-Member -Name 'ff-b'
    & git -C $b remote add origin $o 2>&1 | Out-Null
    & git -C $b fetch -q origin 2>&1 | Out-Null
    & git -C $b reset -q --hard origin/main 2>&1 | Out-Null

    New-Commit -Repo $a -File 'src\theirs.rs' -Text 'их' -Message 'коллега: правка' | Out-Null
    & git -C $a push -q origin main 2>&1 | Out-Null
    New-Commit -Repo $b -File 'src\mine.rs' -Text 'моё' -Message 'моя правка' | Out-Null

    $r = Sync-IntegrationBranch -Root $b -Remote 'origin' -Branch 'main'
    Assert-False $r.Ok 'разошедшиеся ветки свелись молча — решение приняла фабрика, а не человек'
    Assert-Eq $r.Kind 'not-ff'
    Assert-Match $r.Reason 'main'
    Assert-Match $r.Reason 'перемотка невозможна'
    Assert-Match $r.Reason 'локальных коммитов сверх удалённой — 1'
    # Свою работу прогон при этом не трогает: ни отката, ни слияния.
    Assert-True (Test-Path (Join-Path $b 'src\mine.rs')) 'локальная работа исчезла при отказе'
}

It 'при отказе перемотки прогон не заводит ветку волны' {
    $o = New-Origin
    $a = New-Member -Name 'nw-a' -Origin $o
    $b = New-Member -Name 'nw-b'
    & git -C $b remote add origin $o 2>&1 | Out-Null
    & git -C $b fetch -q origin 2>&1 | Out-Null
    & git -C $b reset -q --hard origin/main 2>&1 | Out-Null
    New-Commit -Repo $a -File 'src\theirs.rs' -Text 'их' -Message 'коллега' | Out-Null
    & git -C $a push -q origin main 2>&1 | Out-Null
    New-Commit -Repo $b -File 'src\mine.rs' -Text 'моё' -Message 'моё' | Out-Null

    $t = Start-TeamRun -Root $b
    Assert-False $t.Ok 'прогон стартовал на разошедшейся ветке'
    Assert-Eq $t.Wave '' 'ветка волны заведена, хотя прогон не стартовал'
    $waves = @(& git -C $b branch --list 'bcf/wave/*' 2>$null | Where-Object { $_ })
    Assert-Eq $waves.Count 0 "ветки волны остались в репозитории: $($waves -join ', ')"
    Assert-Eq ((& git -C $b rev-parse --abbrev-ref HEAD | Out-String).Trim()) 'main' 'рабочее дерево уехало с ветки интеграции'
}

It 'НЕДОСТУПНЫЙ REMOTE — ЭТО ОТКАЗ С ТЕКСТОМ ОШИБКИ, А НЕ ТИХИЙ СТАРТ' {
    $b = New-Member -Name 'nofetch'
    & git -C $b remote add origin (Join-Path $sandboxRoot 'нет-такого-каталога.git') 2>&1 | Out-Null
    $t = Start-TeamRun -Root $b
    Assert-False $t.Ok 'прогон стартовал, не сумев забрать чужую работу'
    Assert-Eq $t.Kind 'fetch-failed'
    Assert-Match $t.Reason 'git fetch origin не прошёл'
    Assert-True ($t.Reason.Length -gt 40) "причина пуста — читать нечего: $($t.Reason)"
}

It 'без publish.remote прогон идёт по-старому и в сеть не ходит' {
    $b = New-Member -Name 'solo' -Remote ''
    $t = Start-TeamRun -Root $b
    Assert-True $t.Ok "локальный прогон не стартовал: $($t.Reason)"
    Assert-Eq $t.Wave '' 'без remote заведена ветка волны — поведение изменилось там, где не просили'
    Assert-Eq ((& git -C $b rev-parse --abbrev-ref HEAD | Out-String).Trim()) 'main'
    $p = Publish-WaveBranch -Root $b -Wave '' -Remote ''
    Assert-True $p.Ok
    Assert-Eq $p.Kind 'local'
}

# --- 3. Волна уходит своей веткой ---------------------------------------------------------
Write-Host ''
Write-Host '3. Ветка волны: работа сливается в неё и уезжает в remote' -ForegroundColor White

It 'прогон переводит дерево на bcf/wave/<дата-время>' {
    $o = New-Origin
    $b = New-Member -Name 'wave' -Origin $o
    $t = Start-TeamRun -Root $b
    Assert-True $t.Ok "прогон не стартовал: $($t.Reason)"
    Assert-Match $t.Wave '^bcf/wave/\d{4}-\d{2}-\d{2}-\d{4}$'
    Assert-Eq ((& git -C $b rev-parse --abbrev-ref HEAD | Out-String).Trim()) $t.Wave 'дерево осталось на ветке интеграции — задачи польются прямо в неё'
}

It 'РАБОТА ЗАДАЧИ ПОПАДАЕТ В ВОЛНУ, А ОБЩАЯ ВЕТКА НЕ ТРОНУТА' {
    $o = New-Origin
    $b = New-Member -Name 'wm' -Origin $o
    $mainBefore = Get-Sha -Repo $b -Ref 'refs/heads/main'
    $t = Start-TeamRun -Root $b
    Assert-True $t.Ok $t.Reason

    # Ветка задачи, как её оставляет цикл, и слияние тем же кодом, что в прогоне.
    & git -C $b checkout -q -b bcf/task/TASK-01 2>&1 | Out-Null
    New-Commit -Repo $b -File 'src\feature.rs' -Text 'фича' -Message 'TASK-01: работа' | Out-Null
    & git -C $b checkout -q $t.Wave 2>&1 | Out-Null
    $m = Merge-TaskWorktree -Root $b -Task 'TASK-01'
    Assert-True $m.Ok "слияние в волну не прошло: $($m.Message)"

    Assert-Eq (Get-Sha -Repo $b -Ref 'refs/heads/main') $mainBefore `
        'работа уехала прямо в общую ветку — посмотреть на неё до этого человек не мог'
    $inWave = (& git -C $b show "$($t.Wave):src/feature.rs" 2>$null | Out-String).Trim()
    Assert-Eq $inWave 'фича' 'работы задачи нет в ветке волны'
}

It 'ВОЛНА ОТПРАВЛЯЕТСЯ В REMOTE' {
    $o = New-Origin
    $b = New-Member -Name 'push' -Origin $o
    $t = Start-TeamRun -Root $b
    New-Commit -Repo $b -File 'src\feature.rs' -Text 'фича' -Message 'работа волны' | Out-Null

    $p = Publish-WaveBranch -Root $b -Wave $t.Wave -Remote 'origin'
    Assert-True $p.Ok "отправка не прошла: $($p.Reason)"
    Assert-Eq $p.Kind 'pushed'
    Assert-Eq (Get-Sha -Repo $o -Ref "refs/heads/$($t.Wave)") (Get-Sha -Repo $b -Ref "refs/heads/$($t.Wave)") `
        'в origin нет ветки волны — работа осталась на одной машине'
}

It 'ОТКАЗ ОТПРАВКИ ВОЗВРАЩАЕТСЯ ТЕКСТОМ ОШИБКИ, А НЕ ФЛАГОМ' {
    # Отказ прав, отсутствующий адрес и отклонённый non-fast-forward чинятся по-разному:
    # «не удалось отправить» без причины отправляет человека читать логи.
    $o = New-Origin
    $b = New-Member -Name 'push-fail' -Origin $o
    $t = Start-TeamRun -Root $b
    & git -C $b remote set-url origin (Join-Path $sandboxRoot 'исчез.git') 2>&1 | Out-Null

    $p = Publish-WaveBranch -Root $b -Wave $t.Wave -Remote 'origin'
    Assert-False $p.Ok 'отправка в никуда объявлена успешной'
    Assert-Eq $p.Kind 'push-failed'
    Assert-Match $p.Reason ([regex]::Escape($t.Wave))
    Assert-Match $p.Reason 'origin'
    Assert-True ($p.Reason.Length -gt 40) "в причине нет текста ошибки git: $($p.Reason)"
}

# --- 4. Доска задач tasks/STATUS.json -----------------------------------------------------
Write-Host ''
Write-Host '4. Доска задач: контракт файла и состояния' -ForegroundColor White

It 'доска заводится со всей очередью и в контрактном виде' {
    $b = New-Member -Name 'board' -Remote ''
    Reset-TaskStatusBoard -Root $b -Run 'run_1' -Queued @('TASK-01', 'TASK-02') -Closed @('TASK-03') | Out-Null
    $s = Read-TaskStatus -Root $b
    Assert-Eq $s.run 'run_1'
    Assert-True ([bool]$s.host) 'нет имени машины — по доске не понять, чья фабрика это делала'
    # Время проверяем по САМОМУ ФАЙЛУ: ConvertFrom-Json превращает ISO-строку в дату и
    # печатает её локальным форматом, то есть проверка через объект молчала бы о том,
    # что в файле лежит «05.09.2026 15:57» — формат, который читателю разбирать нечем.
    $raw = Get-Content -Raw -LiteralPath (Get-TaskStatusPath -Root $b)
    Assert-Match $raw '"updated": *"\d{4}-\d{2}-\d{2}T'
    Assert-Match $raw '"since": *"\d{4}-\d{2}-\d{2}T'
    Assert-False $s.complete
    Assert-Eq $s.tasks.'TASK-01'.state 'в очереди'
    Assert-Eq $s.tasks.'TASK-03'.state 'закрыта'
    Assert-Eq @($s.needs_human).Count 0
    Assert-Eq @($s.gate_blocked).Count 0
}

It 'состояние вне контракта отвергается привязкой параметра' {
    # Контракт читает не только человек: опечатка в состоянии обязана быть громкой, иначе
    # наблюдатель получит поле, которого не понимает, и решит, что задачи нет.
    $b = New-Member -Name 'board-bad' -Remote ''
    $threw = $false
    try { Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'работает' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'состояние «работает» принято — контракт файла ничем не защищён'
}

It 'смена состояния двигает since, повтор того же — нет' {
    $b = New-Member -Name 'board-since' -Remote ''
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'у фабрики' -Node 'работа-TASK-01' | Out-Null
    $first = (Read-TaskStatus -Root $b).tasks.'TASK-01'.since
    Start-Sleep -Milliseconds 30
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'у фабрики' -Node 'работа-TASK-01' | Out-Null
    Assert-Eq (Read-TaskStatus -Root $b).tasks.'TASK-01'.since $first `
        'since сдвинулся на записи без смены состояния — по нему не увидеть, что задача висит третий час'
    Start-Sleep -Milliseconds 30
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'закрыта' -Node 'слияние-TASK-01' | Out-Null
    Assert-True ((Read-TaskStatus -Root $b).tasks.'TASK-01'.since -ne $first) 'since не двинулся на смене состояния'
}

It 'SINCE ОСТАЁТСЯ ISO В ФАЙЛЕ ПОСЛЕ ВТОРОЙ ЗАПИСИ ТОГО ЖЕ СОСТОЯНИЯ' {
    # ConvertFrom-Json сам разбирает ISO-строку since в [datetime]: первая запись честная,
    # а вторая (перечитала доску, взяла старое since как есть и записала заново) печатает
    # его форматом ЛОКАЛИ — «09/05/2026 16:48:42», без часового пояса и без долей секунды.
    # Сравнение через объекты этого не ловит: и до, и после разбора оно проходит через тот
    # же ConvertFrom-Json, поэтому проверяем ТЕКСТ САМОГО ФАЙЛА.
    $b = New-Member -Name 'board-since-iso' -Remote ''
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'у фабрики' -Node 'работа-TASK-01' | Out-Null
    Start-Sleep -Milliseconds 30
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'у фабрики' -Node 'работа-TASK-01' | Out-Null
    $raw = Get-Content -Raw -LiteralPath (Get-TaskStatusPath -Root $b)
    $sinceValues = @([regex]::Matches($raw, '"since":\s*"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($sinceValues.Count -gt 0) "в файле нет ни одного since:`n$raw"
    foreach ($v in $sinceValues) {
        Assert-Match $v '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' "since стал форматом локали после второй записи: «$v»"
    }
}

It 'КОНЕЦ ПРОГОНА ВОЗВРАЩАЕТ НЕЗАКРЫТЫЕ ЗАДАЧИ В ОЧЕРЕДЬ' {
    # Оборванный прогон не имеет права оставить задачу навсегда занятой: со стороны это
    # неотличимо от работающей, и второй участник её не возьмёт.
    $b = New-Member -Name 'board-fin' -Remote ''
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-01', 'TASK-02') | Out-Null
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'у фабрики' -Node 'работа-TASK-01' | Out-Null
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-02' -State 'закрыта' -Node 'слияние-TASK-02' | Out-Null

    Complete-TaskStatus -Root $b -Run 'r' -NeedsHuman @('TASK-01') -GateBlocked @() | Out-Null
    $s = Read-TaskStatus -Root $b
    Assert-True $s.complete 'прогон закончился, а доска говорит, что идёт'
    Assert-Eq $s.tasks.'TASK-01'.state 'в очереди' 'брошенная задача осталась «у фабрики» навсегда'
    Assert-Eq $s.tasks.'TASK-01'.node 'работа-TASK-01' 'имя узла стёрлось — непонятно, где её бросили'
    Assert-Eq $s.tasks.'TASK-02'.state 'закрыта' 'закрытую задачу вернули в очередь'
    Assert-Eq @($s.needs_human)[0] 'TASK-01'
}

It 'новый прогон начинает доску с чистого листа' {
    $b = New-Member -Name 'board-run2' -Remote ''
    Update-TaskStatus -Root $b -Run 'run_1' -Task 'TASK-09' -State 'закрыта' | Out-Null
    Update-TaskStatus -Root $b -Run 'run_2' -Task 'TASK-01' -State 'у фабрики' | Out-Null
    $s = Read-TaskStatus -Root $b
    Assert-Eq $s.run 'run_2'
    Assert-True ($null -eq $s.tasks.PSObject.Properties['TASK-09']) `
        'состояния прошлой ночи читаются как факты про эту'
}

It 'ДОСКА ОБНОВЛЯЕТСЯ ПОСЛЕ УЗЛА — ПРОВЕРЕНО НА ПОДСТАВНОМ АГЕНТЕ' {
    # Настоящий рантайм графа, настоящий журнал, ноль обращений к модели: исполнитель узла
    # подменён через BCF_GRAPH_FAKE_AGENT.
    $b = New-Member -Name 'node-board' -Remote ''
    $fake = Join-Path $sandboxRoot 'fake-agent.ps1'
    Set-Content -LiteralPath $fake -Encoding UTF8 -Value @'
function Get-FakeAgentReply {
    param([string]$Prompt, [string]$Label)
    return @{ Text = "ответ узла $Label"; Tokens = 3 }
}
'@
    $env:BCF_GRAPH_FAKE_AGENT = $fake
    try {
        . (Join-Path $root 'harness\lib\agent-sandbox.ps1')
        . (Join-Path $root 'harness\lib\fleet.ps1')
        . (Join-Path $root 'harness\lib\graph-runtime.ps1')
        $ctx = Initialize-GraphRun -Root $b -Meta @{ name = 'очередь'; description = 'т' } -MaxConcurrency 1

        Invoke-Node -Prompt 'сделай задачу' -Label 'работа-TASK-04' | Out-Null
        $s = Read-TaskStatus -Root $b
        Assert-True ($null -ne $s) 'после узла доски нет — со стороны прогон невидим'
        Assert-Eq $s.run $ctx.RunId 'доска не привязана к прогону'
        Assert-Eq $s.tasks.'TASK-04'.state 'у фабрики'
        Assert-Eq $s.tasks.'TASK-04'.node 'работа-TASK-04'
        Assert-False $s.complete

        # Узел, который задачу не называет, задачи на доске не заводит: иначе доска
        # заполнится строками «ревизия-плана» и перестанет читаться.
        Invoke-Node -Prompt 'посмотри план' -Label 'ревизия-плана' -Role planner | Out-Null
        $s = Read-TaskStatus -Root $b
        Assert-Eq @($s.tasks.PSObject.Properties).Count 1 `
            "на доску попали узлы без задачи: $(@($s.tasks.PSObject.Properties.Name) -join ', ')"

        Complete-GraphRun -Result @{ ok = $true } | Out-Null
        $s = Read-TaskStatus -Root $b
        Assert-True $s.complete 'прогон графа закончился, доска этого не заметила'
        Assert-Eq $s.tasks.'TASK-04'.state 'в очереди' 'задача осталась «у фабрики» после конца прогона'
    } finally {
        Remove-Item Env:\BCF_GRAPH_FAKE_AGENT -ErrorAction SilentlyContinue
    }
}

It 'ГРАФ БЕЗ СВОИХ ЗАДАЧ В ОЧЕРЕДИ НЕ ТРОГАЕТ ЧУЖУЮ ДОСКУ' {
    # Ночная очередь закрыла доску и уехала. Следующим запускается граф без единой задачи
    # в узлах (bcf run review) — раньше run-finish ЛЮБОГО графа стирал доску заново:
    # tasks становился {}, needs_human пустел, а run подменялся приёмочным.
    $b = New-Member -Name 'board-foreign' -Remote ''
    Reset-TaskStatusBoard -Root $b -Run 'run_night' -Queued @('TASK-01', 'TASK-02', 'TASK-03') | Out-Null
    Complete-TaskStatus -Root $b -Run 'run_night' -NeedsHuman @('TASK-01') -GateBlocked @() | Out-Null
    Publish-TaskStatus -Root $b -Message 'фабрика: доска задач (run_night)' | Out-Null

    $fake = Join-Path $sandboxRoot 'fake-agent-review.ps1'
    Set-Content -LiteralPath $fake -Encoding UTF8 -Value @'
function Get-FakeAgentReply {
    param([string]$Prompt, [string]$Label)
    return @{ Text = "ответ узла $Label"; Tokens = 3 }
}
'@
    $env:BCF_GRAPH_FAKE_AGENT = $fake
    try {
        . (Join-Path $root 'harness\lib\agent-sandbox.ps1')
        . (Join-Path $root 'harness\lib\fleet.ps1')
        . (Join-Path $root 'harness\lib\graph-runtime.ps1')
        Initialize-GraphRun -Root $b -Meta @{ name = 'приёмка'; description = 'т' } -MaxConcurrency 1 | Out-Null
        Invoke-Node -Prompt 'посмотри риски' -Label 'роутер-риск' -Role critic | Out-Null
        Complete-GraphRun -Result @{ ok = $true } | Out-Null
    } finally {
        Remove-Item Env:\BCF_GRAPH_FAKE_AGENT -ErrorAction SilentlyContinue
    }

    $after = Read-TaskStatus -Root $b
    Assert-Eq $after.run 'run_night' 'run на доске подменился чужим приёмочным прогоном'
    Assert-True $after.complete 'доска ночного прогона стала незакрытой'
    Assert-Eq @($after.tasks.PSObject.Properties).Count 3 `
        "доска ночной очереди стёрлась: осталось задач $(@($after.tasks.PSObject.Properties).Count)"
    Assert-Eq @($after.needs_human)[0] 'TASK-01' 'needs_human ночного прогона пропал'
    $dirty = @(& git -C $b status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    Assert-Eq $dirty.Count 0 "граф без своих задач оставил доску некоммиченной грязью: $($dirty -join '; ')"
}

It 'доска отслеживается git и коммитится одним файлом' {
    $b = New-Member -Name 'board-git' -Remote ''
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-01') | Out-Null
    # Рядом лежит чужая некоммиченная правка в ОТСЛЕЖИВАЕМОМ файле: коммит доски не имеет
    # права утащить её с собой в свой коммит.
    Set-Content -LiteralPath (Join-Path $b 'src\main.rs') -Value 'fn main() { /* правка */ }' -Encoding UTF8

    & git -C $b check-ignore -q 'tasks/STATUS.json' 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) 'доска в .gitignore — её видит один человек'
    $r = Publish-TaskStatus -Root $b
    Assert-True $r.Ok "доска не закоммичена: $($r.Reason)"
    $tracked = @(& git -C $b ls-files 'tasks/STATUS.json' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'доска осталась вне git'
    $dirty = @(& git -C $b status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    Assert-Eq $dirty.Count 1 'коммит доски унёс с собой чужую правку'
}

It 'СЛИЯНИЕ КОММИТИТ ДОСКУ, А НЕ ПАРКУЕТ ЕЁ' {
    # Доска меняется после каждого узла. Попади она в парковку — каждое слияние волны
    # отправляло бы её в bcf/parked/<дата>, а прогон вставал бы на грязном дереве.
    $b = New-Member -Name 'board-merge' -Remote ''
    & git -C $b checkout -q -b bcf/task/TASK-07 2>&1 | Out-Null
    New-Commit -Repo $b -File 'src\seven.rs' -Text 'семь' -Message 'TASK-07: работа' | Out-Null
    & git -C $b checkout -q main 2>&1 | Out-Null
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-07') | Out-Null

    $m = Merge-TaskWorktree -Root $b -Task 'TASK-07'
    Assert-True $m.Ok "слияние отменилось из-за доски: вид=$($m.Kind) $($m.Message)"
    $tracked = @(& git -C $b ls-files 'tasks/STATUS.json' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'доска не доехала в git — слияние её припарковало или откатило'
    $parked = 'bcf/parked/' + (Get-Date -Format 'yyyy-MM-dd')
    $inParked = (& git -C $b show "${parked}:tasks/STATUS.json" 2>&1 | Out-String)
    Assert-Match $inParked '(?i)(fatal|does not exist|exists on disk|invalid object)' `
        'доска уехала в ветку парковки — прогон отобрал у себя собственное состояние'
}

# --- 5. Конец прогона: доска, коммит, отправка --------------------------------------------
Write-Host ''
Write-Host '5. Конец прогона: отказ отправки не молчит' -ForegroundColor White

It 'удачный конец: доска закрыта, закоммичена и уехала вместе с волной' {
    $o = New-Origin
    $b = New-Member -Name 'fin-ok' -Origin $o
    $t = Start-TeamRun -Root $b
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-01') | Out-Null
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'закрыта' -Node 'слияние-TASK-01' | Out-Null

    $fin = Complete-TeamRun -Root $b -Run 'r' -Team $t -Stuck @()
    Assert-True $fin.Publish.Ok "волна не опубликована: $($fin.Publish.Reason)"
    Assert-Eq @($fin.Stuck).Count 0
    $dirty = @(& git -C $b status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    Assert-Eq $dirty.Count 0 "доска осталась некоммиченной — следующий прогон встанет на грязном дереве: $($dirty -join '; ')"
    $onOrigin = (& git -C $o show "$($t.Wave):tasks/STATUS.json" 2>$null | Out-String)
    Assert-Match $onOrigin '"complete": *true' 'доска не уехала вместе с волной'
    Assert-Match $onOrigin 'TASK-01'
}

It 'ОТКАЗ ОТПРАВКИ ПОПАДАЕТ В needs_human, А НЕ В ЖУРНАЛ' {
    $o = New-Origin
    $b = New-Member -Name 'fin-fail' -Origin $o
    $t = Start-TeamRun -Root $b
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-01') | Out-Null
    Update-TaskStatus -Root $b -Run 'r' -Task 'TASK-01' -State 'закрыта' -Node 'слияние-TASK-01' | Out-Null
    & git -C $b remote set-url origin (Join-Path $sandboxRoot 'исчез-совсем.git') 2>&1 | Out-Null

    $fin = Complete-TeamRun -Root $b -Run 'r' -Team $t -Stuck @()
    Assert-False $fin.Publish.Ok 'отправка в никуда объявлена успешной'
    Assert-Eq @($fin.Stuck).Count 1 'отказ отправки не стал затыком — отчёт напишет «закрыто всё»'
    Assert-Eq @($fin.Stuck)[0].Task $t.Wave
    Assert-Match ([string]@($fin.Stuck)[0].Reason) 'не отправлена'
    $s = Read-TaskStatus -Root $b
    Assert-True (@($s.needs_human) -contains $t.Wave) "на доске нет неопубликованной волны: $(@($s.needs_human) -join ', ')"
}

# Отчёт прогона — та же функция, что у цикла и у графа. Проверяем на ней, что затык
# «волна не отправлена» доезжает до машиночитаемого статуса и до слова COMPLETE.
$reportRunner = Join-Path $sandboxRoot 'run-report.ps1'
Set-Content -LiteralPath $reportRunner -Encoding UTF8 -Value @'
param([string]$RunAll, [string]$Root, [string]$Review, [string]$Status, [string]$Payload, [string]$Result)
$ErrorActionPreference = 'Stop'
$in = Get-Content -Raw -LiteralPath $Payload | ConvertFrom-Json
$env:BCF_REPORT_LIB_ONLY = '1'
$env:BCF_PROJECT_ROOT = $Root
. $RunAll -ProjectRoot $Root
$rep = Emit-RunAllReport -Passed @($in.passed) -Stuck @($in.stuck) -Total ([int]$in.total) `
    -Root $Root -ReviewFile $Review -Ts '2026-09-05 00:00:00' -StatusFile $Status
([ordered]@{ complete = [bool]$rep.complete; status = (Get-Content -Raw -LiteralPath $Status) } |
    ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Result -Encoding UTF8
'@

It 'отчёт прогона называет неопубликованную волну и не говорит COMPLETE' {
    $b = New-Member -Name 'report' -Remote ''
    $payload = Join-Path $sandboxRoot 'payload.json'
    $res = Join-Path $sandboxRoot 'result.json'
    ([ordered]@{
        passed = @('TASK-01'); total = 1
        stuck  = @(@{ Task = 'bcf/wave/2026-09-05-0300'
                      Reason = 'ветка волны bcf/wave/2026-09-05-0300 не отправлена в origin: Permission denied (publickey)' })
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $payload -Encoding UTF8

    & pwsh -NoProfile -File $reportRunner -RunAll (Join-Path $root 'harness\run-all.ps1') -Root $b `
        -Review (Join-Path $sandboxRoot 'REVIEW.md') -Status (Join-Path $sandboxRoot 'status.json') `
        -Payload $payload -Result $res 2>&1 | Out-Null
    $out = Get-Content -Raw -LiteralPath $res | ConvertFrom-Json
    Assert-False $out.complete 'прогон с неотправленной волной объявлен завершённым'
    Assert-Match $out.status 'bcf/wave/2026-09-05-0300' 'волны нет в машиночитаемом статусе'
    Assert-Match $out.status 'Permission denied' 'текст ошибки git потерян по дороге'
    Assert-Match $out.status '"needs_human"' 'отказ отправки не попал в needs_human'
}

# --- 6. Номер задачи с учётом чужих номеров -----------------------------------------------
Write-Host ''
Write-Host '6. bcf task new: номер и реестр' -ForegroundColor White

function New-TaskFile {
    param([string]$Id)
    return "# $Id — задача`n`n## Файлы`n`n- ``src/x.rs```n`n**Gate-вход:** нет`n"
}

It 'НОМЕР БЕРЁТСЯ С УЧЁТОМ ВЕТКИ ИНТЕГРАЦИИ НА REMOTE' {
    # У второго участника локально шесть задач, у первого девять — и седьмая давно в
    # работе. Номер по своему каталогу совпадёт с чужим, а обнаружится это на слиянии.
    $o = New-Origin
    $a = New-Member -Name 'num-a' -Origin $o -Remote '' -Tasks @{ 'TASK-01-first' = (New-TaskFile 'TASK-01') }
    $b = New-Member -Name 'num-b' -Remote ''
    & git -C $b remote add origin $o 2>&1 | Out-Null
    & git -C $b fetch -q origin 2>&1 | Out-Null
    & git -C $b reset -q --hard origin/main 2>&1 | Out-Null

    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $a 'tasks\TASK-07-theirs.md') -Value (New-TaskFile 'TASK-07')
    & git -C $a add -A 2>&1 | Out-Null
    & git -C $a commit -q -m 'коллега: TASK-07' 2>&1 | Out-Null
    & git -C $a push -q origin main 2>&1 | Out-Null
    & git -C $b fetch -q origin 2>&1 | Out-Null

    Assert-False (Test-Path (Join-Path $b 'tasks\TASK-07-theirs.md')) 'фикстура не воспроизводит отставание'
    Assert-Eq (Get-BcfRemoteTaskMax -Root $b -Prefix 'TASK' -TasksRel 'tasks') 7 `
        'чужие номера не видны — два участника заведут одну задачу дважды'

    $r = & pwsh -NoProfile -File $bcf task new 'моя задача' --project $b 2>&1 | Out-String
    Assert-Match $r 'TASK-08' "номер выдан по локальным файлам:`n$r"
    Assert-True (Test-Path (Join-Path $b 'tasks\TASK-08-moya-zadacha.md')) 'файла задачи с новым номером нет'
}

It 'контроль: без remote тот же проект даёт следующий локальный номер' {
    # Без этой проверки предыдущая доказывала бы только «функция что-то вернула».
    $c = New-Member -Name 'num-c' -Remote '' -Tasks @{ 'TASK-01-first' = (New-TaskFile 'TASK-01') }
    Assert-Eq (Get-BcfRemoteTaskMax -Root $c -Prefix 'TASK' -TasksRel 'tasks') 0
    $r = & pwsh -NoProfile -File $bcf task new 'вторая задача' --project $c 2>&1 | Out-String
    Assert-Match $r 'TASK-02' "локальная нумерация сломалась:`n$r"
}

It 'строка задачи дописывается в tasks/index.md' {
    $d = New-Member -Name 'idx' -Remote ''
    & pwsh -NoProfile -File $bcf task new 'первая задача' --project $d 2>&1 | Out-Null
    $idx = Join-Path $d 'tasks\index.md'
    Assert-True (Test-Path $idx) 'реестра задач нет — занятый номер виден только после слияния'
    $body = Get-Content -Raw -LiteralPath $idx
    Assert-Match $body '(?m)^- TASK-01 — первая задача — `tasks/TASK-01-pervaya-zadacha\.md`\s*$'

    & pwsh -NoProfile -File $bcf task new 'вторая задача' --project $d 2>&1 | Out-Null
    $body = Get-Content -Raw -LiteralPath $idx
    Assert-Match $body '(?m)^- TASK-02 — вторая задача — '
    Assert-Match $body '(?m)^- TASK-01 — ' 'вторая задача затёрла первую строку реестра'
    # Реестр не должен попасть в очередь: она берёт только TASK-NN-*.md.
    Assert-NoMatch (& pwsh -NoProfile -File $bcf tasks --project $d 2>&1 | Out-String) 'index' `
        'реестр читается как задача'
}

# --- 7. -DryPlan ничего не создаёт ---------------------------------------------------------
Write-Host ''
Write-Host '7. run-all -DryPlan: ни fetch, ни ветки волны, ни коммита' -ForegroundColor White

It '-DRYPLAN НЕ СОЗДАЁТ НИЧЕГО: НИ FETCH, НИ ВЕТКИ ВОЛНЫ, НИ КОММИТА ДОСКИ' {
    # docs/CLI.md: «--dry-plan не создаёт НИЧЕГО: ни рабочих деревьев, ни заявок на файлы».
    # Шина команды заводила ветку волны и коммитила доску ДО проверки самого флага — сухой
    # план с заполненным publish.remote уводил HEAD на bcf/wave/<дата> и оставлял коммит
    # «доска задач», хотя был обязан только показать план.
    $o = New-Origin
    $b = New-Member -Name 'dryplan' -Origin $o -Tasks @{ 'TASK-01-first' = (New-TaskFile 'TASK-01') }
    $headBefore = Get-Sha -Repo $b -Ref 'HEAD'
    $branchBefore = (& git -C $b rev-parse --abbrev-ref HEAD | Out-String).Trim()

    $out = & pwsh -NoProfile -File (Join-Path $root 'harness\run-all.ps1') -ProjectRoot $b -DryPlan 2>&1 | Out-String
    Assert-Match $out 'DRY-PLAN' "сухой план не отчитался о себе:`n$out"

    Assert-Eq (Get-Sha -Repo $b -Ref 'HEAD') $headBefore 'DryPlan сдвинул HEAD — появился новый коммит'
    Assert-Eq ((& git -C $b rev-parse --abbrev-ref HEAD | Out-String).Trim()) $branchBefore `
        'DryPlan увёл рабочее дерево с исходной ветки на ветку волны'
    $waves = @(& git -C $b branch --list 'bcf/wave/*' 2>$null | Where-Object { $_ })
    Assert-Eq $waves.Count 0 "DryPlan завёл ветку волны: $($waves -join ', ')"
    $dirty = @(& git -C $b status --porcelain 2>$null | Where-Object { $_ -notmatch '^\?\?' })
    Assert-Eq $dirty.Count 0 "DryPlan оставил отслеживаемую грязь: $($dirty -join '; ')"
}

It 'контроль: без DryPlan шина команды по-прежнему заводит ветку волны' {
    # Без этой проверки предыдущая доказывала бы только «DryPlan ничего не пишет в лог»,
    # а не то, что обычный прогон по-прежнему заводит волну — то есть что мы не выключили
    # шину команды вовсе, подгоняя её под сухой план. Тот же путь, что вызывает run-all.ps1
    # до ветвления по -DryPlan (harness/lib/team-bus.ps1), проверен здесь напрямую.
    $o = New-Origin
    $b = New-Member -Name 'wetplan' -Origin $o -Tasks @{ 'TASK-01-first' = (New-TaskFile 'TASK-01') }
    $t = Start-TeamRun -Root $b
    Assert-True $t.Ok $t.Reason
    Assert-Match $t.Wave '^bcf/wave/\d{4}-\d{2}-\d{2}-\d{4}$' 'реальный прогон перестал заводить ветку волны'
    Reset-TaskStatusBoard -Root $b -Run 'r' -Queued @('TASK-01') | Out-Null
    Publish-TaskStatus -Root $b -Message 'фабрика: доска задач (r)' | Out-Null
    $tracked = @(& git -C $b ls-files 'tasks/STATUS.json' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'реальный прогон перестал коммитить доску'
}

# --- Итог ---------------------------------------------------------------------------------
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
