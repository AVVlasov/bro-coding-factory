# journey-gate.tests.ps1 — гейт «продуктом можно пользоваться».
#
#   pwsh harness/tests/journey-gate.tests.ps1
#
# Проверяется ровно то, на чём 2026-08-09 сгорел прогон clinic-scheduler: отчёт
# «COMPLETE — все 35 задач закрыты (PASS)» при продукте, в котором не работал ни один
# клиентский путь. Гейт, который должен был это остановить, обязан сам быть доказан —
# иначе он такое же обещание, как строка «Работает» в отчёте.
#
# Каждый случай ниже — отдельный способ соврать зелёным цветом, и все три наблюдались
# живьём: сценарий объявлен и не написан; сценарий написан и красный; сценарий удалён,
# а раннер по несуществующему фильтру вернул exit 0 «0 tests» и выглядел пройденным.

$ErrorActionPreference = 'Continue'
$gate = Join-Path (Split-Path $PSScriptRoot -Parent) 'journey-gate.ps1'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Pass = 0; $script:Fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { $script:Pass++; Write-Host "  ok   $name" -ForegroundColor Green }
    else       { $script:Fail++; Write-Host "  FAIL $name $(if ($detail) { "— $detail" })" -ForegroundColor Red }
}
function Section($t) { Write-Host "`n$t" -ForegroundColor Cyan }

# Проект-пустышка: git-репозиторий (его ищет Get-BcfProjectRoot) + config/journeys.json.
function New-Fixture {
    param($Registry)
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("bcf-jg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
    & git -C $d init -q -b main 2>&1 | Out-Null
    & git -C $d config user.email t@t; & git -C $d config user.name t
    if ($null -ne $Registry) {
        ($Registry | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $d 'config\journeys.json') -Encoding UTF8
    }
    return $d
}
function Invoke-Gate($dir) {
    $out = & pwsh -NoProfile -NonInteractive -File $gate -ProjectRoot $dir 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
$cleanup = @()

# ---------------------------------------------------------------------------
Section "1. Реестра нет — это НЕ провал задачи, но и НЕ доказательство продукта"
# ---------------------------------------------------------------------------
# Отдельный код возврата нужен, чтобы вызывающий мог различить «сценарии красные» и
# «сценариев нет». Свалив их в один код, мы бы либо блокировали проект без реестра,
# либо (что и было) молча считали его доказанным.
$d = New-Fixture $null; $cleanup += $d
$r = Invoke-Gate $d
Check "код возврата 3 (не заведён), а не 0 и не 1" ($r.Code -eq 3) "код=$($r.Code)"
Check "вслух сказано, что зелёный прогон продукт не доказывает" ($r.Out -match 'НЕ означает|не заведён')

# ---------------------------------------------------------------------------
Section "2. Сценарий объявлен, файла-доказательства нет — провал"
# ---------------------------------------------------------------------------
# Реестр намерений выглядит как реестр проверок и читается как он же.
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "exit 0"'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'src/journeys/нет-такого.test.tsx' })
}
$cleanup += $d
$r = Invoke-Gate $d
Check "провал, хотя команда завершилась нулём" ($r.Code -eq 1) "код=$($r.Code)"
Check "назван конкретный сценарий" ($r.Out -match 'operator-book')

# ---------------------------------------------------------------------------
Section "3. Тихий ноль: команда зелёная, но сценарий не прогонялся"
# ---------------------------------------------------------------------------
# Главный случай. У vitest/pytest/cargo фильтр без совпадений даёт exit 0 «0 tests»:
# удалённый или переименованный сценарий выглядит пройденным. Ловится только тем, что
# id сценария обязан встретиться в выводе.
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''Test Files 0 passed''; exit 0"'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$r = Invoke-Gate $d
Check "провал при exit 0 и нуле прогнанных сценариев" ($r.Code -eq 1) "код=$($r.Code)"
Check "объяснено, что нулевой код тут ничего не доказывает" ($r.Out -match 'не встретились|Нулевой код')

# ---------------------------------------------------------------------------
Section "4. Сценарий прогнан и красный — провал"
# ---------------------------------------------------------------------------
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book FAILED''; exit 1"'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$r = Invoke-Gate $d
Check "провал по коду команды" ($r.Code -eq 1) "код=$($r.Code)"
Check "сказано, что сломан сквозной путь" ($r.Out -match 'сквозной путь сломан')

# ---------------------------------------------------------------------------
Section "5. Все сценарии прогнаны и зелёные — только тогда ноль"
# ---------------------------------------------------------------------------
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book ok''; Write-Output ''registrar-pay ok''; exit 0"'
    journeys = @(
        @{ id = 'operator-book';  title = 'запись пациента'; proof = 'proof.txt' }
        @{ id = 'registrar-pay';  title = 'оплата визита';   proof = 'proof.txt' }
    )
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$r = Invoke-Gate $d
Check "ноль" ($r.Code -eq 0) "код=$($r.Code); вывод=$($r.Out)"
Check "перечислены оба сценария" (($r.Out -match 'operator-book') -and ($r.Out -match 'registrar-pay'))

# ---------------------------------------------------------------------------
Section "6. Один зелёный сценарий не закрывает второй — красный"
# ---------------------------------------------------------------------------
# Проверка на «частично зелено засчитали за зелено»: ровно так закрылась очередь из
# 35 задач при одном работающем куске.
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book ok''; exit 0"'
    journeys = @(
        @{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' }
        @{ id = 'registrar-pay'; title = 'оплата визита';   proof = 'proof.txt' }
    )
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$r = Invoke-Gate $d
Check "провал: второй сценарий не прогонялся" ($r.Code -eq 1) "код=$($r.Code)"
Check "назван именно недостающий" ($r.Out -match 'registrar-pay')

# ---------------------------------------------------------------------------
Section "7. planned: путь назван, но ещё не доказан — не блокирует, но и не «готово»"
# ---------------------------------------------------------------------------
# Реестр обязан содержать все пути с самого начала, иначе гейт доказывает ровно то,
# что уже сделано. Но требовать все сразу — значит остановить очередь на первой задаче.
# Отсюда третье состояние: доказанные пути зелёные, остальные названы вслух.
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book ok''; exit 0"'
    journeys = @(
        @{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt'; status = 'required' }
        @{ id = 'registrar-pay'; title = 'оплата визита';   proof = 'нет.txt';   status = 'planned' }
    )
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$r = Invoke-Gate $d
Check "код 4 — доказано частично, не 0 и не 1" ($r.Code -eq 4) "код=$($r.Code)"
Check "planned не требует файла-доказательства" ($r.Out -notmatch 'нет\.txt')
Check "недоказанный путь назван вслух" ($r.Out -match 'registrar-pay')
Check "сказано, что «готово» говорить нельзя" ($r.Out -match 'сказать нельзя|planned')

# ---------------------------------------------------------------------------
Section "8. Все пути planned — доказано ноль путей"
# ---------------------------------------------------------------------------
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "exit 0"'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'нет.txt'; status = 'planned' })
}
$cleanup += $d
$r = Invoke-Gate $d
Check "код 3 — доказывать нечего" ($r.Code -eq 3) "код=$($r.Code)"

# ---------------------------------------------------------------------------
Section "9. Машиночитаемый ответ пригоден для обвязки"
# ---------------------------------------------------------------------------
# run-all и queue.graph принимают решение по этому JSON; распарситься он обязан и в
# провальном случае, иначе «не смог прочитать» превратится в «всё хорошо».
$d = New-Fixture @{
    command  = 'pwsh -NoProfile -Command "Write-Output ''operator-book FAILED''; exit 1"'
    journeys = @(@{ id = 'operator-book'; title = 'запись пациента'; proof = 'proof.txt' })
}
$cleanup += $d
'доказательство' | Set-Content -LiteralPath (Join-Path $d 'proof.txt') -Encoding UTF8
$out = & pwsh -NoProfile -NonInteractive -File $gate -ProjectRoot $d -Json 2>$null | Out-String
$ok = $false; $state = ''
try { $j = $out | ConvertFrom-Json; $ok = $true; $state = [string]$j.state } catch { }
Check "JSON разобран" $ok "вывод=$out"
Check "state = fail" ($state -eq 'fail') "state=$state"

foreach ($p in $cleanup) { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:Fail) { Write-Host "ИТОГ: $($script:Pass) прошло, $($script:Fail) провалено" -ForegroundColor Red; exit 1 }
Write-Host "ИТОГ: $($script:Pass) прошло, 0 провалено" -ForegroundColor Green
exit 0
