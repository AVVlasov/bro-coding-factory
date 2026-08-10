# merge-integration.tests.ps1 — узел ИНТЕГРАЦИИ на настоящем git.
#
#   pwsh harness/tests/merge-integration.tests.ps1
#
# Проверяется ровно то, на чём 2026-07-26 сгорел прогон: слияние ветки задачи в
# основное дерево. Тогда единственный изменённый Cargo.lock отменил слияние СЕМИ
# задач подряд — каждая из них уже дошла до PASS, то есть работа была сделана и
# выброшена. Тест поднимает настоящий репозиторий и воспроизводит эту ситуацию.

$ErrorActionPreference = 'Continue'
$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
. (Join-Path $libDir 'worktree.ps1')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Pass = 0; $script:Fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $name $(if ($detail) { "— $detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

# Собрать чистый репозиторий с одной задачной веткой.
function New-Fixture {
    param([string]$MainEdit = '', [string]$BranchEdit = '')
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-merge-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t; & git -C $d config user.name t
    'исходная строка'            | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
    'lock = "1.0"'               | Set-Content -LiteralPath (Join-Path $d 'Cargo.lock') -Encoding UTF8
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m init 2>&1 | Out-Null

    # Ветка задачи со своей правкой.
    & git -C $d checkout -q -b bcf/task/TASK-99 2>&1 | Out-Null
    if ($BranchEdit) { $BranchEdit | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8 }
    else { 'правка задачи' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8 }
    & git -C $d add -A 2>&1 | Out-Null
    & git -C $d commit -q -m "TASK-99" 2>&1 | Out-Null
    & git -C $d checkout -q main 2>&1 | Out-Null

    if ($MainEdit) {
        $MainEdit | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
        & git -C $d add -A 2>&1 | Out-Null
        & git -C $d commit -q -m "main" 2>&1 | Out-Null
    }
    return $d
}

# ---------------------------------------------------------------------------
Section "1. Грязный сгенерированный файл НЕ отменяет слияние (регрессия 2026-07-26)"
# ---------------------------------------------------------------------------
$d = New-Fixture
'lock = "2.0-перегенерён"' | Set-Content -LiteralPath (Join-Path $d 'Cargo.lock') -Encoding UTF8
$dirtyBefore = @(& git -C $d status --porcelain)
Check "предусловие: дерево грязное по Cargo.lock" ($dirtyBefore.Count -eq 1 -and $dirtyBefore[0] -match 'Cargo\.lock')

$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock', 'package-lock.json')
Check "слияние прошло" ($r.Ok) "вид=$($r.Kind) сообщение=$($r.Message)"
Check "правка задачи в основном дереве" ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim() -eq 'правка задачи')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# Тот же случай БЕЗ списка сгенерированных — обязан вести себя по-старому.
$d = New-Fixture
'lock = "2.0"' | Set-Content -LiteralPath (Join-Path $d 'Cargo.lock') -Encoding UTF8
$r = Merge-TaskWorktree -Root $d -Task 'TASK-99'
Check "без списка сгенерированных — прежний отказ" ((-not $r.Ok) -and $r.Kind -eq 'dirty-tree')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section "2. Грязный ИСХОДНИК по-прежнему отменяет слияние (сторож не ослаблен)"
# ---------------------------------------------------------------------------
$d = New-Fixture
'несохранённая работа человека' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock')
Check "слияние отклонено" ((-not $r.Ok) -and $r.Kind -eq 'dirty-tree')
Check "виновник назван" ($r.Message -match 'src\.rs')
Check "правка человека не тронута" ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim() -eq 'несохранённая работа человека')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# Смешанный случай: и лок, и исходник. Отказ обязан называть ТОЛЬКО исходник.
$d = New-Fixture
'работа человека' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
'lock = "2.0"'    | Set-Content -LiteralPath (Join-Path $d 'Cargo.lock') -Encoding UTF8
$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock')
Check "смешанная грязь: отказ по исходнику" ((-not $r.Ok) -and $r.Message -match 'src\.rs' -and $r.Message -notmatch 'Cargo\.lock')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section "3. Конфликт: дерево остаётся арбитру, а не откатывается"
# ---------------------------------------------------------------------------
$d = New-Fixture -MainEdit 'версия основной ветки' -BranchEdit 'версия задачи'
$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock') -KeepConflictForArbiter
Check "конфликт распознан" ((-not $r.Ok) -and $r.Kind -eq 'conflict-open')
Check "конфликтный файл назван" (@($r.Conflicts) -contains 'src.rs')
$body = Get-Content -Raw (Join-Path $d 'src.rs')
Check "маркеры конфликта доступны арбитру" ($body -match '<<<<<<<' -and $body -match '>>>>>>>')

# Арбитр «ещё не поработал» — завершать нечего.
$c = Complete-ArbitratedMerge -Root $d -Task 'TASK-99'
Check "незавершённое сведение не коммитится" ((-not $c.Ok) -and $c.Message -match 'не свёл')

# Арбитр «свёл», но оставил маркер в тексте — самый опасный случай: git доволен,
# а в основную ветку уезжает '<<<<<<<'.
@"
версия основной ветки
<<<<<<< HEAD
версия задачи
"@ | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
& git -C $d add -A 2>&1 | Out-Null
$c = Complete-ArbitratedMerge -Root $d -Task 'TASK-99'
Check "оставленный в тексте маркер ловится" ((-not $c.Ok) -and $c.Message -match 'маркер')

# Настоящее сведение.
'версия основной ветки + версия задачи' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
& git -C $d add -A 2>&1 | Out-Null
$c = Complete-ArbitratedMerge -Root $d -Task 'TASK-99'
Check "сведённое слияние коммитится" ($c.Ok) "сообщение=$($c.Message)"
Check "результат арбитра в дереве" ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim() -eq 'версия основной ветки + версия задачи')
Check "дерево вышло из состояния слияния" (-not (Test-Path (Join-Path $d '.git\MERGE_HEAD')))
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section "4. Отказ от арбитража возвращает дерево в исходное состояние"
# ---------------------------------------------------------------------------
$d = New-Fixture -MainEdit 'версия основной ветки' -BranchEdit 'версия задачи'
$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -KeepConflictForArbiter
Undo-ArbitratedMerge -Root $d
Check "слияние отменено" (-not (Test-Path (Join-Path $d '.git\MERGE_HEAD')))
Check "дерево вернулось к основной ветке" ((Get-Content -Raw (Join-Path $d 'src.rs')).Trim() -eq 'версия основной ветки')
Check "дерево чистое" (@(& git -C $d status --porcelain).Count -eq 0)
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section "Сохранность работы незакрытой задачи"
# ---------------------------------------------------------------------------
# Правки агента лежат в рабочем каталоге worktree НЕкоммиченными. Если коммитить их
# только после проверки вердикта, незакрытая задача теряет всё: ветка остаётся пустой,
# а Remove-TaskWorktree уносит часы работы. Ветка с коммитом стоит ничего, восстановить
# из неё можно всё; обратное неверно.
$rw = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-keep-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $rw | Out-Null
& git -C $rw init -q -b main 2>&1 | Out-Null
& git -C $rw config user.email t@t; & git -C $rw config user.name t
'база' | Set-Content -LiteralPath (Join-Path $rw 'src.rs') -Encoding UTF8
& git -C $rw add -A 2>&1 | Out-Null
& git -C $rw commit -q -m init 2>&1 | Out-Null

$wt77 = New-TaskWorktree -Root $rw -Task 'TASK-77'
Set-Content -LiteralPath (Join-Path $wt77 'feature.txt') -Value 'работа агента' -Encoding UTF8

# Порядок графа: коммит ДО суждения о вердикте.
& git -C $wt77 add -A 2>&1 | Out-Null
& git -C $wt77 -c user.name=t -c user.email=t@t commit -q -m 'TASK-77: работа агента' 2>&1 | Out-Null

# Вердикта нет — задача незакрыта, worktree сносится с сохранением ветки.
Remove-TaskWorktree -Root $rw -Task 'TASK-77' -KeepBranch

$onBranch = @(& git -C $rw log --oneline main..bcf/task/TASK-77 2>$null | Where-Object { $_ })
Check "работа незакрытой задачи сохранена в ветке" ($onBranch.Count -ge 1) "коммитов: $($onBranch.Count)"
$blob = (& git -C $rw show bcf/task/TASK-77:feature.txt 2>$null | Out-String).Trim()
Check "содержимое восстановимо из ветки" ($blob -eq 'работа агента') "получено: '$blob'"
Remove-Item -Recurse -Force $rw -ErrorAction SilentlyContinue

# --- Что worktree обязан унести с собой из основного дерева ------------------------------
#
# Чистый чекаут не содержит НИЧЕГО из .gitignore, и обе стороны обмена об этом забывают.
# Цена измерена на прогонах 2026-08-06: без node_modules все три гейта в ветке задачи
# красные независимо от работы агента; без вердиктов закрытых задач цикл блокирует задачу
# через секунду после старта («предшественник TASK-01 не имеет verdict: PASS»), хотя тот
# закрыт и слит, — так волна 2 не поехала целиком.

Section "Worktree уносит зависимости и вердикты"

$rd = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-wt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $rd | Out-Null
& git -C $rd init -q -b main 2>&1 | Out-Null
& git -C $rd config user.email t@t; & git -C $rd config user.name t
Set-Content -LiteralPath (Join-Path $rd '.gitignore') -Value "node_modules/`ntasks/.verdicts/" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $rd 'src.txt') -Value 'код' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $rd 'node_modules\.bin') | Out-Null
Set-Content -LiteralPath (Join-Path $rd 'node_modules\.bin\tsc.cmd') -Value 'echo tsc' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $rd 'tasks\.verdicts') | Out-Null
Set-Content -LiteralPath (Join-Path $rd 'tasks\.verdicts\TASK-01.md') -Value "# Verdict — TASK-01`nverdict: PASS" -Encoding UTF8
& git -C $rd add -A 2>&1 | Out-Null
& git -C $rd commit -q -m init 2>&1 | Out-Null

$wtd = New-TaskWorktree -Root $rd -Task 'TASK-02'
Check "worktree создан" ([bool]$wtd -and (Test-Path $wtd)) "путь: $wtd"
Check "инструменты доступны в ветке задачи" (Test-Path (Join-Path $wtd 'node_modules\.bin\tsc.cmd')) `
    'без node_modules гейты в ветке красные всегда, независимо от работы агента'

# ИЗОЛЯЦИЯ, А НЕ ССЫЛКА. Общий каталог зависимостей ломает три вещи разом: `npm install`
# одной задачи вычищает пакеты другой, проверки слитого дерева ловят исчезнувший инструмент
# посреди чужой установки, а `git worktree remove` идёт по ссылке ВНУТРЬ и вычищает
# node_modules самого проекта — что и случилось 2026-08-06.
$nmWt = Get-Item (Join-Path $wtd 'node_modules') -Force
Check "зависимости задачи — не ссылка на проект" (-not ($nmWt.Attributes -band [IO.FileAttributes]::ReparsePoint)) `
    'junction/symlink: удаление рабочего дерева вычистит node_modules проекта'
Set-Content -LiteralPath (Join-Path $wtd 'node_modules\.bin\сор.txt') -Value 'мусор задачи' -Encoding UTF8
Check "порча зависимостей задачи не видна проекту" (-not (Test-Path (Join-Path $rd 'node_modules\.bin\сор.txt'))) `
    'каталоги общие — одна задача ломает гейты всем остальным'
$vcopy = Join-Path $wtd 'tasks\.verdicts\TASK-01.md'
Check "вердикт предшественника виден задаче" (Test-Path $vcopy) `
    'без него цикл блокирует задачу: «предшественник не имеет verdict: PASS»'
if (Test-Path $vcopy) {
    Check "вердикт перенесён содержимым, а не пустышкой" ((Get-Content -Raw $vcopy) -match 'verdict:\s*PASS')
}
Remove-TaskWorktree -Root $rd -Task 'TASK-02'
Check "удаление дерева задачи не тронуло зависимости проекта" (Test-Path (Join-Path $rd 'node_modules\.bin\tsc.cmd')) `
    'рекурсивное удаление пошло по ссылке внутрь и вычистило каталог проекта'

# Переиспользованная ветка обязана догонять основную: между прогонами в main попадают и
# другие задачи, и правки владельца. Задача на старой базе проверяется не тем деревом, в
# которое её сольют. 2026-08-06 это стоило волны: package.json ветки не знал про
# объявленный в main typescript, `npm install` в задаче вычистил его из общего
# node_modules — и гейт tsc упал у всех задач сразу, включая готовые.
$branchWt = New-TaskWorktree -Root $rd -Task 'TASK-03'
Set-Content -LiteralPath (Join-Path $branchWt 'branch-work.txt') -Value 'работа задачи' -Encoding UTF8
& git -C $branchWt add -A 2>&1 | Out-Null
& git -C $branchWt -c user.name=t -c user.email=t@t commit -q -m 'TASK-03: работа' 2>&1 | Out-Null
Remove-TaskWorktree -Root $rd -Task 'TASK-03' -KeepBranch

# Основная ветка ушла вперёд.
Set-Content -LiteralPath (Join-Path $rd 'main-only.txt') -Value 'правка владельца' -Encoding UTF8
& git -C $rd add -A 2>&1 | Out-Null
& git -C $rd -c user.name=t -c user.email=t@t commit -q -m 'правка в main' 2>&1 | Out-Null

$again = New-TaskWorktree -Root $rd -Task 'TASK-03'
Check "работа задачи на месте после переиспользования ветки" (Test-Path (Join-Path $again 'branch-work.txt'))
Check "ветка догнала основную" (Test-Path (Join-Path $again 'main-only.txt')) `
    'задача продолжает работать на старой базе — проверки идут не по тому дереву, в которое её сольют'
Remove-TaskWorktree -Root $rd -Task 'TASK-03'


# Каталог, оставшийся от снятого прогона, — ловушка: файл `.git` на месте, а git о дереве
# уже не знает и ветки нет. 2026-08-08 задача переиспользовала такой каталог вместе с ЧУЖИМ
# вердиктом внутри (.bcf переживает всё, он вне git), прочитала PASS от прошлого прогона и
# вышла за семь секунд, не сделав ничего.
Section "Осиротевший каталог рабочего дерева"

$wtOrphan = New-TaskWorktree -Root $rd -Task 'TASK-42'
New-Item -ItemType Directory -Force -Path (Join-Path $wtOrphan '.bcf\verdicts') | Out-Null
Set-Content -LiteralPath (Join-Path $wtOrphan '.bcf\verdicts\чужой.md') -Value 'PASS от прошлого прогона' -Encoding UTF8
# Прогон сняли: учётную запись убрали, ветку удалили, каталог остался.
& git -C $rd worktree remove --force $wtOrphan 2>&1 | Out-Null
New-Item -ItemType Directory -Force -Path $wtOrphan | Out-Null
Set-Content -LiteralPath (Join-Path $wtOrphan '.git') -Value 'gitdir: /nonexistent' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $wtOrphan '.bcf\verdicts') | Out-Null
Set-Content -LiteralPath (Join-Path $wtOrphan '.bcf\verdicts\чужой.md') -Value 'PASS от прошлого прогона' -Encoding UTF8

$again42 = New-TaskWorktree -Root $rd -Task 'TASK-42'
Check "осиротевший каталог не переиспользован" `
    ([bool]$again42 -and -not (Test-Path (Join-Path $again42 '.bcf\verdicts\чужой.md'))) `
    'вернули мусор прошлого прогона: задача прочитает чужой вердикт и закроется, ничего не сделав'
Check "ветка задачи снова существует" `
    ([bool]((& git -C $rd branch --list 'bcf/task/TASK-42' 2>$null | Out-String).Trim())) `
    'без ветки слияние скажет «not something we can merge»'
Remove-TaskWorktree -Root $rd -Task 'TASK-42'

Remove-Item -Recurse -Force $rd -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section "Грязь в каталогах владельца НЕ отменяет слияние (регрессия 2026-08-10)"
# ---------------------------------------------------------------------------
# Второй случай того же класса, что и с Cargo.lock. Узел ревизии плана работает в
# ОСНОВНОМ дереве и с правом правки; он зашёл в tasks/ и поменял в закрытой TASK-25
# «- [x]» на «- [V]». Две строки в файле давно закрытой задачи отменили слияние
# TASK-48, дошедшей до PASS. tasks/ и config/ принадлежат владельцу, кодовому агенту
# запрещены и в слиянии продуктового кода не участвуют — значит откат, а не отказ.
$d = New-Fixture
New-Item -ItemType Directory -Force -Path (Join-Path $d 'tasks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
'- [x] сделано' | Set-Content -LiteralPath (Join-Path $d 'tasks\TASK-25.md') -Encoding UTF8
'{ "a": 1 }'    | Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Encoding UTF8
& git -C $d add -A 2>&1 | Out-Null
& git -C $d commit -q -m "задачи и конфиги" 2>&1 | Out-Null

# Узел пачкает оба каталога владельца — ровно как в инциденте.
'- [V] сделано' | Set-Content -LiteralPath (Join-Path $d 'tasks\TASK-25.md') -Encoding UTF8
'{ "a": 2 }'    | Set-Content -LiteralPath (Join-Path $d 'config\checks.json') -Encoding UTF8
Check "предусловие: дерево грязное по tasks/ и config/" (@(& git -C $d status --porcelain).Count -eq 2)

$r = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock')
Check "слияние прошло, а не отменилось" ($r.Ok) "вид=$($r.Kind) сообщение=$($r.Message)"
Check "работа задачи в основном дереве" `
    ((Get-Content -Raw -LiteralPath (Join-Path $d 'src.rs')).Trim() -eq 'правка задачи')
Check "правка узла в tasks/ откачена" `
    ((Get-Content -Raw -LiteralPath (Join-Path $d 'tasks\TASK-25.md')).Trim() -eq '- [x] сделано')
Check "правка узла в config/ откачена" `
    ((Get-Content -Raw -LiteralPath (Join-Path $d 'config\checks.json')).Trim() -eq '{ "a": 1 }')

# Грязь в ПРОДУКТОВОМ коде по-прежнему отменяет слияние: там правку теряют молча только
# по недосмотру, и это ровно то, от чего проверка и стоит.
'чужая правка' | Set-Content -LiteralPath (Join-Path $d 'src.rs') -Encoding UTF8
$r2 = Merge-TaskWorktree -Root $d -Task 'TASK-99' -GeneratedFiles @('Cargo.lock')
Check "грязь в продуктовом коде отменяет слияние" ((-not $r2.Ok) -and ($r2.Kind -eq 'dirty-tree')) "вид=$($r2.Kind)"
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("ИТОГ: {0} прошло, {1} провалено" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ""
if ($script:Fail) { exit 1 }
exit 0
