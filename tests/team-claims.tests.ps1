# team-claims.tests.ps1 — фабрику ведут несколько человек, шина между ними — git.
#
#   pwsh tests/team-claims.tests.ps1
#
# ЧТО ЛОВЯТ ЭТИ ТЕСТЫ. Пока фабрика стояла на одной машине, три вещи работали и были
# неправильными по построению:
#
#   · вердикт лежал в .gitignore — закрытая задача существовала ровно у одного человека,
#     второй видел бэклог, в котором не закрыто ничего;
#   · заявка на задачу была записью в .bcf/, а живость считалась по pid — номер чужого
#     процесса на своей машине либо не находится, либо принадлежит постороннему;
#   · красную проверку на слитом дереве откатывал `git reset --hard HEAD~1` — он снимает
#     ПОСЛЕДНИЙ коммит, ничего не зная о том, чей он. В команде между слиянием и проверкой
#     в ту же ветку успевает приехать чужая работа.
#
# Каждый случай проверяется с негативной стороны: второй претендент получает отказ с
# именем первого, протухшая заявка задачу не держит, а после красной проверки чужой коммит
# остаётся в ветке.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent                     # корень фабрики
$bcf  = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-team-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

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
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" + (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 20) -join "`n"))
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

# Голый git-проект с задачами: ровно то, что получает участник команды после клона.
function New-TeamProject {
    param([string]$Name = 'p', [hashtable]$Tasks = @{})
    $d = Join-Path $sandboxRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email team@local 2>&1 | Out-Null
    & git -C $d config user.name 'команда' 2>&1 | Out-Null
    # Как после bcf install: состояние прогонов локальное, вердикты и заявки — нет.
    Set-Content -LiteralPath (Join-Path $d '.gitignore') -Value ".bcf/`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
    foreach ($k in $Tasks.Keys) {
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $d "tasks\$k.md") -Value $Tasks[$k]
    }
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'исходное состояние' 2>&1 | Out-Null
    return $d
}

function New-TaskBody {
    param([string]$Id, [string[]]$Files)
    $lines = @("# $Id — задача", '', '## Файлы', '')
    foreach ($f in $Files) { $lines += "- ``$f``" }
    $lines += @('', '**Gate-вход:** нет', '')
    return ($lines -join "`n")
}

Write-Host ''
Write-Host "  ФАБРИКА В КОМАНДЕ   песочница: $sandboxRoot" -ForegroundColor Cyan

# --- 1. Вердикт живёт в git ---------------------------------------------------------------
Write-Host ''
Write-Host '1. Вердикт коммитится вместе с задачей, а не прячется в .gitignore' -ForegroundColor White

$viProj = Join-Path $sandboxRoot 'verdicts'
New-Item -ItemType Directory -Force -Path $viProj | Out-Null
& git -C $viProj init -q -b main 2>&1 | Out-Null
& git -C $viProj config user.email t@local 2>&1 | Out-Null
& git -C $viProj config user.name t 2>&1 | Out-Null
Set-Content -LiteralPath (Join-Path $viProj 'README.md') -Value 'проект' -Encoding UTF8
& git -C $viProj add -A 2>&1 | Out-Null
& git -C $viProj commit -q -m init 2>&1 | Out-Null
& pwsh -NoProfile -File $bcf install --project $viProj 2>&1 | Out-Null

It 'install не прячет вердикты и заявки в .gitignore' {
    $gi = Get-Content -Raw -LiteralPath (Join-Path $viProj '.gitignore')
    Assert-NoMatch $gi 'tasks/\.verdicts' 'вердикт снова спрятан — у второго участника бэклог пуст по построению'
    Assert-NoMatch $gi 'tasks/\.claims'   'заявка спрятана — её не видно на второй машине'
    # Состояние прогонов по-прежнему локальное: делить .bcf между машинами нечем.
    Assert-Match $gi '\.bcf/' 'состояние прогонов перестало игнорироваться'
}

It 'git видит вердикт как обычный файл проекта' {
    New-Item -ItemType Directory -Force -Path (Join-Path $viProj 'tasks\.verdicts') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $viProj 'tasks\.verdicts\TASK-01.md') `
        -Value "# Вердикт TASK-01`nverdict: PASS"
    & git -C $viProj check-ignore -q 'tasks/.verdicts/TASK-01.md' 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) 'git по-прежнему игнорирует вердикт'
    # --untracked-files=all: иначе git показывает только каталог целиком, и проверка
    # прошла бы на любом содержимом, включая пустоту.
    $untracked = @(& git -C $viProj status --porcelain --untracked-files=all 2>$null |
                   Where-Object { $_ -match 'tasks/\.verdicts/TASK-01\.md' })
    Assert-Eq $untracked.Count 1 'вердикт не виден в git status — значит он нигде'
}

It 'установка поверх старого проекта снимает прежнюю строку .gitignore' {
    # Апгрейд без этого молчалив: всё остальное сделано, а вердикты по-прежнему никуда
    # не едут, и узнают об этом на второй машине через неделю.
    $old = Join-Path $sandboxRoot 'upgrade'
    New-Item -ItemType Directory -Force -Path $old | Out-Null
    & git -C $old init -q -b main 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $old '.gitignore') -Value ".bcf/`ntasks/.verdicts/`nnode_modules/" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $old 'README.md') -Value 'проект' -Encoding UTF8
    & git -C $old add -A 2>&1 | Out-Null
    & git -C $old -c user.name=t -c user.email=t@local commit -q -m init 2>&1 | Out-Null

    & pwsh -NoProfile -File $bcf install --project $old 2>&1 | Out-Null
    $gi = @(Get-Content -LiteralPath (Join-Path $old '.gitignore'))
    Assert-False ($gi -contains 'tasks/.verdicts/') 'строка осталась — вердикты продолжают прятаться'
    Assert-True  ($gi -contains 'node_modules/') 'вместе с вердиктами снесли чужие строки владельца'
}

It 'Copy-WorktreeVerdicts удалена вместе с вызовами' {
    $wt = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\lib\worktree.ps1')
    Assert-NoMatch $wt '(?m)^\s*Copy-WorktreeVerdicts' 'вызов копирования вердиктов остался'
    Assert-NoMatch $wt 'function Copy-WorktreeVerdicts' 'функция копирования вердиктов на месте'
    Assert-True (-not (Get-Command Copy-WorktreeVerdicts -ErrorAction SilentlyContinue)) `
        'функция всё ещё определяется при загрузке библиотеки'
}

# --- 2. Заявка на задачу: файл в git ------------------------------------------------------
Write-Host ''
Write-Host '2. Заявка — файл tasks/.claims/<TASK>.md, а не запись в .bcf' -ForegroundColor White

$claimProj = New-TeamProject -Name 'claims' -Tasks @{
    'TASK-01-first'  = (New-TaskBody -Id 'TASK-01' -Files @('src/a.rs'))
    'TASK-02-second' = (New-TaskBody -Id 'TASK-02' -Files @('src/a.rs', 'src/b.rs'))
    'TASK-03-third'  = (New-TaskBody -Id 'TASK-03' -Files @('src/c.rs'))
}

It 'заявка кладётся файлом и коммитится' {
    $env:BCF_CLAIM_OWNER = 'Андрей'
    Add-TaskClaim -TaskId 'TASK-01' -Root $claimProj
    $path = Join-Path $claimProj 'tasks\.claims\TASK-01.md'
    Assert-True (Test-Path $path) 'файла заявки нет'
    $body = Get-Content -Raw -LiteralPath $path
    Assert-Match $body '(?m)^Кто: Андрей$'
    Assert-Match $body '(?m)^Ветка: bcf/task/TASK-01$'
    Assert-Match $body '(?m)^Когда: \d{4}-\d{2}-\d{2}T'
    Assert-Match $body '(?m)^- src/a\.rs$'
    $dirty = @(& git -C $claimProj status --porcelain 2>$null | Where-Object { $_ })
    Assert-Eq $dirty.Count 0 "заявка осталась некоммиченной: $($dirty -join '; ')"
    $tracked = @(& git -C $claimProj ls-files 'tasks/.claims/TASK-01.md' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'git не отслеживает заявку — второму участнику её не видно'
}

It 'заявку читает тот же разбор, что и её пишет' {
    $c = @(Get-BcfFileClaims -Root $claimProj)[0]
    Assert-Eq $c.task 'TASK-01'
    Assert-Eq $c.who 'Андрей'
    Assert-Eq $c.branch 'bcf/task/TASK-01'
    Assert-Eq @($c.files).Count 1
    Assert-Eq @($c.files)[0] 'src/a.rs'
    Assert-False $c.stale 'свежая заявка объявлена протухшей'
}

It 'ВТОРОЙ ПРЕТЕНДЕНТ ПОЛУЧАЕТ ОТКАЗ С ИМЕНЕМ ПЕРВОГО И ВРЕМЕНЕМ ЗАЯВКИ' {
    # Ровно тот случай, ради которого заявка переехала в git: двое на разных машинах
    # берут одну задачу и узнают об этом на слиянии, когда работа уже сделана дважды.
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-01' -Root $claimProj
    Assert-False $adm.Ok 'вторая машина допущена в занятую задачу'
    Assert-Match $adm.Reason 'Андрей' 'в отказе не названо имя того, кто держит задачу'
    Assert-Match $adm.Reason '\d{4}-\d{2}-\d{2} \d{2}:\d{2}' 'в отказе нет времени заявки'
    Assert-Eq $adm.Holder 'Андрей'
}

It 'первый претендент в свою же задачу проходит' {
    $env:BCF_CLAIM_OWNER = 'Андрей'
    $adm = Test-TaskAdmission -TaskId 'TASK-01' -Root $claimProj
    Assert-True $adm.Ok "собственная заявка заблокировала владельца: $($adm.Reason)"
}

It 'пересечение файлов называет и задачу, и человека' {
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-02' -Root $claimProj
    Assert-False $adm.Ok 'задача с общим файлом допущена'
    Assert-Match $adm.Reason 'TASK-01'
    Assert-Match $adm.Reason 'src/a\.rs'
    Assert-Match $adm.Reason 'Андрей' 'сказано «пересечение с TASK-01», но не сказано, к кому идти'
}

It 'непересекающаяся задача другого участника идёт' {
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-03' -Root $claimProj
    Assert-True $adm.Ok "чужая заявка заблокировала независимую задачу: $($adm.Reason)"
}

It 'снятие заявки удаляет файл и коммитит удаление' {
    Remove-TaskClaim -TaskId 'TASK-01' -Root $claimProj
    Assert-False (Test-Path (Join-Path $claimProj 'tasks\.claims\TASK-01.md')) 'файл заявки остался'
    $dirty = @(& git -C $claimProj status --porcelain 2>$null | Where-Object { $_ })
    Assert-Eq $dirty.Count 0 "удаление заявки осталось некоммиченным: $($dirty -join '; ')"
    # Негативный случай, который прятался годами: пустой массив в конвейере не даёт
    # ConvertTo-Json ни строки, Set-Content не получает входа — и файл кэша остаётся
    # прежним. Снятая последняя заявка продолжала держать задачу.
    $cache = Get-Content -Raw -LiteralPath (Join-Path $claimProj '.bcf\fleet\claims.json')
    Assert-NoMatch $cache 'TASK-01' "кэш не перезаписан при снятии последней заявки: $cache"
    $env:BCF_CLAIM_OWNER = 'Мария'
    Assert-True (Test-TaskAdmission -TaskId 'TASK-01' -Root $claimProj).Ok 'снятая заявка всё ещё держит задачу'
}

# --- 3. Живость по свежести, а не по pid --------------------------------------------------
Write-Host ''
Write-Host '3. Протухшая заявка задачу не держит' -ForegroundColor White

$ttlProj = New-TeamProject -Name 'ttl' -Tasks @{
    'TASK-01-first' = (New-TaskBody -Id 'TASK-01' -Files @('src/a.rs'))
}

function Set-Claim {
    param([string]$Proj, [string]$Task, [string]$Who, [datetime]$When)
    $dir = Join-Path $Proj 'tasks\.claims'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $text = ConvertTo-BcfClaimText -TaskId $Task -Who $Who -Branch "bcf/task/$Task" `
                -Files @('src/a.rs') -Since ([datetimeoffset]$When).ToString('o')
    Set-Content -LiteralPath (Join-Path $dir "$Task.md") -Value $text -Encoding UTF8
}

It 'заявка часовой давности задачу держит' {
    Set-Claim -Proj $ttlProj -Task 'TASK-01' -Who 'Пётр' -When (Get-Date).AddHours(-1)
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-01' -Root $ttlProj
    Assert-False $adm.Ok 'свежая заявка перестала держать задачу — двое поедут в одну'
    Assert-Match $adm.Reason 'Пётр'
}

It 'ЗАЯВКА СТАРШЕ ПОРОГА ЗАДАЧУ НЕ ДЕРЖИТ' {
    Set-Claim -Proj $ttlProj -Task 'TASK-01' -Who 'Пётр' -When (Get-Date).AddHours(-20)
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-01' -Root $ttlProj
    Assert-True $adm.Ok "заявка 20-часовой давности держит задачу до утра: $($adm.Reason)"
    $stale = @(Get-BcfFileClaims -Root $ttlProj | Where-Object { $_.stale })
    Assert-Eq $stale.Count 1 'протухшая заявка не помечена протухшей — её нечем показать человеку'
}

It 'порог берётся из конфига проекта' {
    New-Item -ItemType Directory -Force -Path (Join-Path $ttlProj 'config') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $ttlProj 'config\harness.json') `
        -Value '{ "paths": { "tasks": "tasks" }, "team": { "claimTtlHours": 48 } }'
    Assert-Eq (Get-BcfClaimTtlHours -Root $ttlProj) 48
    $env:BCF_CLAIM_OWNER = 'Мария'
    $adm = Test-TaskAdmission -TaskId 'TASK-01' -Root $ttlProj
    Assert-False $adm.Ok 'при пороге 48 часов заявка 20-часовой давности обязана держать задачу'
}

It 'заявка без разобранного времени задачу не держит' {
    # Иначе битая строка блокирует задачу навсегда, и понять почему нечем.
    $dir = Join-Path $ttlProj 'tasks\.claims'
    Set-Content -LiteralPath (Join-Path $dir 'TASK-01.md') -Encoding UTF8 `
        -Value "# Заявка на TASK-01`n`nКто: Пётр`nВетка: bcf/task/TASK-01`nКогда: позавчера`n`n## Файлы`n`n- src/a.rs`n"
    $env:BCF_CLAIM_OWNER = 'Мария'
    Assert-True (Test-TaskAdmission -TaskId 'TASK-01' -Root $ttlProj).Ok 'битое время держит задачу вечно'
}

It 'живость больше не считается по pid' {
    $src = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\lib\claims.ps1')
    Assert-NoMatch $src 'Get-Process -Id \$c\.pid' 'заявка снова проверяется существованием процесса'
    Assert-Match $src 'claimTtlHours' 'порог свежести не читается из конфига'
}

It 'локальный кэш остался, но правду говорит файл' {
    $cacheProj = New-TeamProject -Name 'cache' -Tasks @{
        'TASK-01-first' = (New-TaskBody -Id 'TASK-01' -Files @('src/a.rs'))
    }
    $env:BCF_CLAIM_OWNER = 'Андрей'
    Add-TaskClaim -TaskId 'TASK-01' -Root $cacheProj
    Assert-True (Test-Path (Join-Path $cacheProj '.bcf\fleet\claims.json')) 'кэш перестал писаться'
    # Файл — источник правды: убираем его руками, кэш остаётся, задача свободна.
    Remove-Item -LiteralPath (Join-Path $cacheProj 'tasks\.claims\TASK-01.md') -Force
    $cached = @(Get-ActiveClaims -Root $cacheProj | Where-Object { $_.task -eq 'TASK-01' })
    Assert-Eq $cached.Count 1 'кэш перестал подстраховывать сухой план'
    Assert-Eq @($cached)[0].source 'cache'
}

It 'сухой план ничего не коммитит' {
    $dryProj = New-TeamProject -Name 'dry' -Tasks @{
        'TASK-01-first' = (New-TaskBody -Id 'TASK-01' -Files @('src/a.rs'))
    }
    $head = (& git -C $dryProj rev-parse HEAD | Out-String).Trim()
    Add-TaskClaim -TaskId 'TASK-01' -Root $dryProj -Local
    Remove-TaskClaim -TaskId 'TASK-01' -Root $dryProj -Local
    Assert-Eq ((& git -C $dryProj rev-parse HEAD | Out-String).Trim()) $head 'сухой план оставил коммиты в проекте'
    Assert-False (Test-Path (Join-Path $dryProj 'tasks\.claims\TASK-01.md')) 'сухой план положил заявку в git'
}

It 'хук не пускает агента в каталог заявок' {
    $hook = Get-Content -Raw -LiteralPath (Join-Path $root 'templates\claude\hooks\agent-infra-protect.sh')
    Assert-Match $hook 'tasks/\.claims/\*\)' 'агент может выписать себе заявку на чужую задачу'
}

# --- 4. Откат красной проверки не трогает чужую работу ------------------------------------
Write-Host ''
Write-Host '4. Откат слияния: общая ветка не теряет чужой коммит' -ForegroundColor White

# Фикстура повторяет окно, в которое попадает команда: слияние задачи прошло, проверки на
# слитом дереве идут минуты, и в это время в ту же ветку коммитит второй участник.
function New-MergedFixture {
    $d = Join-Path $sandboxRoot ('merge-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@local 2>&1 | Out-Null
    & git -C $d config user.name t 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'src.rs') -Value 'исходная строка' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null

    & git -C $d checkout -q -b bcf/task/TASK-77 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'task.rs') -Value 'работа задачи' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'TASK-77: работа' 2>&1 | Out-Null
    & git -C $d checkout -q main 2>&1 | Out-Null

    $before = (& git -C $d rev-parse HEAD | Out-String).Trim()
    & git -C $d merge --no-ff --no-edit bcf/task/TASK-77 2>&1 | Out-Null
    $merge = (& git -C $d rev-parse HEAD | Out-String).Trim()
    return @{ Dir = $d; Before = $before; Merge = $merge }
}

It 'ПОСЛЕ КРАСНОЙ ПРОВЕРКИ ЧУЖОЙ КОММИТ ОСТАЁТСЯ В ОБЩЕЙ ВЕТКЕ' {
    $f = New-MergedFixture
    # Коллега коммитит в ту же ветку, пока идут проверки на слитом дереве.
    Set-Content -LiteralPath (Join-Path $f.Dir 'colleague.rs') -Value 'работа коллеги' -Encoding UTF8
    & git -C $f.Dir add -A 2>&1 | Out-Null
    & git -C $f.Dir commit -q -m 'коллега: своя правка' 2>&1 | Out-Null

    $undo = Undo-FailedMerge -Root $f.Dir -MergeSha $f.Merge -BeforeSha $f.Before
    Assert-True $undo.Ok "откат не удался: $($undo.Message)"
    Assert-Eq $undo.Kind 'revert' 'на общей ветке применён не revert — жёсткий сброс снял бы коммит коллеги'
    Assert-True (Test-Path (Join-Path $f.Dir 'colleague.rs')) `
        'коммит коллеги потерян — ровно то, что делал git reset --hard HEAD~1'
    Assert-False (Test-Path (Join-Path $f.Dir 'task.rs')) 'работа задачи осталась в общей ветке после отката'
    $log = (& git -C $f.Dir log --oneline | Out-String)
    Assert-Match $log 'коллега' 'коммита коллеги нет в истории'
}

It 'контроль: прежний reset --hard HEAD~1 на той же фикстуре теряет коммит коллеги' {
    # Без этого проверка выше доказывала бы только «функция что-то сделала». Здесь видно
    # цену: та же ситуация, старый способ отката — и работы коллеги в ветке нет.
    $f = New-MergedFixture
    Set-Content -LiteralPath (Join-Path $f.Dir 'colleague.rs') -Value 'работа коллеги' -Encoding UTF8
    & git -C $f.Dir add -A 2>&1 | Out-Null
    & git -C $f.Dir commit -q -m 'коллега: своя правка' 2>&1 | Out-Null

    & git -C $f.Dir reset --hard HEAD~1 2>&1 | Out-Null
    Assert-False (Test-Path (Join-Path $f.Dir 'colleague.rs')) `
        'фикстура не воспроизводит потерю — значит и проверка выше ничего не доказывает'
    Assert-True (Test-Path (Join-Path $f.Dir 'task.rs')) `
        'жёсткий сброс снял чужой коммит и ОСТАВИЛ слияние, которое требовалось откатить'
}

It 'внутри ветки задачи откат идёт на запомненный SHA' {
    # Там кроме этой задачи никого нет, и жёсткий сброс не может задеть чужую работу.
    $f = New-MergedFixture
    & git -C $f.Dir checkout -q -b bcf/task/TASK-88 $f.Merge 2>&1 | Out-Null
    $undo = Undo-FailedMerge -Root $f.Dir -MergeSha $f.Merge -BeforeSha $f.Before
    Assert-True $undo.Ok "откат в ветке задачи не удался: $($undo.Message)"
    Assert-Eq $undo.Kind 'reset'
    Assert-Eq ((& git -C $f.Dir rev-parse HEAD | Out-String).Trim()) $f.Before
}

It 'в откате слияния не осталось reset --hard HEAD~1' {
    foreach ($f in @('harness\lib\scheduler.ps1', 'harness\graphs\queue.graph.ps1')) {
        $code = ((Get-Content -LiteralPath (Join-Path $root $f)) | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
        Assert-NoMatch $code 'reset --hard HEAD~1' "$f снова снимает последний коммит вслепую"
        Assert-Match $code 'Undo-FailedMerge' "$f не зовёт общий откат"
    }
}

It 'откат по несуществующему sha не притворяется успешным' {
    $f = New-MergedFixture
    $undo = Undo-FailedMerge -Root $f.Dir -MergeSha '' -BeforeSha $f.Before
    Assert-False $undo.Ok 'пустой sha принят за откат'
    Assert-Match $undo.Message 'не запомнен'
}

# --- 5. Правки человека паркуются, а не откатываются --------------------------------------
Write-Host ''
Write-Host '5. Правки в tasks/ и config/ уезжают в ветку парковки' -ForegroundColor White

It 'ПРАВКА ЧЕЛОВЕКА ВО ВРЕМЯ ПРОГОНА СОХРАНЕНА В ВЕТКЕ, А НЕ ПОТЕРЯНА' {
    $f = New-MergedFixture
    $d = $f.Dir
    & git -C $d checkout -q main 2>&1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'tasks\TASK-25.md') -Value '- [x] сделано' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Value '{ "a": 1 }' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'задачи и конфиги' 2>&1 | Out-Null

    # Человек правит бэклог и гейты, пока идёт прогон.
    Set-Content -LiteralPath (Join-Path $d 'tasks\TASK-25.md') -Value '- [ ] переоткрыл' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Value '{ "a": 2 }' -Encoding UTF8

    $park = Save-OwnerEditsToParkedBranch -Root $d -Files @('tasks/TASK-25.md', 'config/checks.json')
    Assert-True $park.Ok "парковка не удалась: $($park.Message)"
    Assert-Match $park.Branch '^bcf/parked/\d{4}-\d{2}-\d{2}$'

    $dirty = @(& git -C $d status --porcelain 2>$null | Where-Object { $_ })
    Assert-Eq $dirty.Count 0 "дерево осталось грязным — слияние всё равно не пойдёт: $($dirty -join '; ')"
    Assert-Eq ((Get-Content -Raw -LiteralPath (Join-Path $d 'tasks\TASK-25.md')).Trim()) '- [x] сделано'

    $parked = (& git -C $d show "$($park.Branch):tasks/TASK-25.md" 2>$null | Out-String).Trim()
    Assert-Eq $parked '- [ ] переоткрыл' 'правка человека не сохранена — это и есть тихая потеря работы'
    $parkedCfg = (& git -C $d show "$($park.Branch):config/checks.json" 2>$null | Out-String).Trim()
    Assert-Eq $parkedCfg '{ "a": 2 }'
}

It 'вторая парковка за день не затирает первую' {
    $f = New-MergedFixture
    $d = $f.Dir
    & git -C $d checkout -q main 2>&1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'tasks\A.md') -Value 'исходный A' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $d 'tasks\B.md') -Value 'исходный B' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'две задачи' 2>&1 | Out-Null

    Set-Content -LiteralPath (Join-Path $d 'tasks\A.md') -Value 'правка A' -Encoding UTF8
    $p1 = Save-OwnerEditsToParkedBranch -Root $d -Files @('tasks/A.md')
    Set-Content -LiteralPath (Join-Path $d 'tasks\B.md') -Value 'правка B' -Encoding UTF8
    $p2 = Save-OwnerEditsToParkedBranch -Root $d -Files @('tasks/B.md')

    Assert-Eq $p1.Branch $p2.Branch 'ветки парковки разъехались в пределах одного дня'
    Assert-Eq ((& git -C $d show "$($p2.Branch):tasks/A.md" 2>$null | Out-String).Trim()) 'правка A' `
        'первая парковка затёрта второй — сохранена только последняя правка'
    Assert-Eq ((& git -C $d show "$($p2.Branch):tasks/B.md" 2>$null | Out-String).Trim()) 'правка B'
}

It 'некоммиченный вердикт слияние коммитит, а не паркует' {
    # Заявка и вердикт — файлы самой обвязки. Коммит рядом с ними иногда не проходит
    # (индекс держит параллельная задача), и припарковать их значило бы отобрать у задачи
    # её собственную заявку во время работы, а откатить — потерять вердикт.
    $f = New-MergedFixture
    $d = $f.Dir
    & git -C $d reset --hard $f.Before 2>&1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks\.verdicts') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $d 'tasks\.verdicts\TASK-77.md') `
        -Value "# Вердикт TASK-77`nverdict: FAIL"

    $r = Merge-TaskWorktree -Root $d -Task 'TASK-77'
    Assert-True $r.Ok "слияние отменилось из-за собственного вердикта: вид=$($r.Kind) $($r.Message)"
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $d 'tasks\.verdicts\TASK-77.md')) 'verdict: FAIL' `
        'вердикт откачен или припаркован — команда его не увидит'
    $tracked = @(& git -C $d ls-files 'tasks/.verdicts/TASK-77.md' 2>$null | Where-Object { $_ })
    Assert-Eq $tracked.Count 1 'вердикт остался вне git'
}

It 'слияние паркует грязь владельца и идёт дальше' {
    $f = New-MergedFixture
    $d = $f.Dir
    # Возвращаем дерево к состоянию «слияния ещё не было».
    & git -C $d reset --hard $f.Before 2>&1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Value '{ "a": 1 }' -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m 'конфиг' 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Value '{ "a": 2 }' -Encoding UTF8

    $r = Merge-TaskWorktree -Root $d -Task 'TASK-77'
    Assert-True $r.Ok "слияние отменилось из-за правки владельца: вид=$($r.Kind) $($r.Message)"
    $branch = 'bcf/parked/' + (Get-Date -Format 'yyyy-MM-dd')
    Assert-Eq ((& git -C $d show "${branch}:config/checks.json" 2>$null | Out-String).Trim()) '{ "a": 2 }' `
        'правка владельца не припаркована слиянием'
}

# --- 6. run-all заканчивается кодом возврата, а не окном ----------------------------------
Write-Host ''
Write-Host '6. Ночной прогон в команде не открывает окно на чужом экране' -ForegroundColor White

It 'в исполняемом коде run-all.ps1 нет модального окна' {
    $runAll = Join-Path $root 'harness\run-all.ps1'
    $code = ((Get-Content -LiteralPath $runAll) | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
    Assert-NoMatch $code 'MessageBox' 'окно держит процесс до нажатия ОК — ночной прогон не завершается'
    Assert-NoMatch $code 'PresentationFramework'
    Assert-NoMatch $code 'System\.Windows\.Forms'
    Assert-NoMatch $code 'Add-Type\s+-AssemblyName'
}

It 'итог печатается в консоль и пишется в .bcf/run-all.status.json' {
    $text = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\run-all.ps1')
    Assert-Match $text 'run-all\.status\.json'
    Assert-Match $text 'Log "=== run-all завершён'
}

# --- Итог ---------------------------------------------------------------------------------
Remove-Item Env:\BCF_CLAIM_OWNER -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail) { Write-Host "ИТОГ: $script:pass прошло, $script:fail провалено" -ForegroundColor Red }
else { Write-Host "ИТОГ: $script:pass прошло, 0 провалено" -ForegroundColor Green }
Write-Host ''

if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
