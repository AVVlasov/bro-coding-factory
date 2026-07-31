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

Write-Host ""
Write-Host ("ИТОГ: {0} прошло, {1} провалено" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
Write-Host ""
if ($script:Fail) { exit 1 }
exit 0
