# backpressure.ps1 — быстрая проверка после итерации, одна для всех стеков.
#
# ЗАЧЕМ ОТДЕЛЬНЫМ ФАЙЛОМ. В цикле эта проверка была захардкожена: «есть package.json —
# зови npx tsc --noEmit, нет — молчи». Ключ config/harness.json → backpressure.typecheck
# при этом не читал никто, хотя документация обещала, что он вызывается каждую итерацию.
# Java-, Rust- и Go-проект получали ноль обратной связи внутри итерации: несобирающийся
# код доезжал до верификации и сжигал круг целиком. Здесь команды исполняются как есть,
# а решение «чем именно проверять» остаётся за проектом.
#
# Контракт функции:
#   Skipped  — команд нет вовсе. Это не «чисто», а «не проверялось»; вызывающий обязан
#              записать событие, иначе пропуск снова станет невидимым нулём.
#   Failures — по одной записи на упавшую команду: сама команда, код выхода и хвост
#              вывода. Хвост нужен агенту: «exit 1» без текста не чинится.
#   Clean    — команды были и все отработали нулём.
#   Signature — набор команд строкой. Авто-откат регрессии сравнивает не «код был 0»,
#              а «прошлая итерация была чистой ПО ЭТОМУ ЖЕ набору»: сменился набор —
#              сравнивать не с чем.

function Get-BcfBackpressureCommands {
    <#
      Достаёт список команд из разобранного config/harness.json.
      Пустой/отсутствующий ключ даёт пустой массив — и это законное состояние.
    #>
    param($Config)
    if (-not $Config) { return @() }
    $raw = $null
    try { $raw = $Config.backpressure.typecheck } catch { return @() }
    if ($null -eq $raw) { return @() }
    return @(@($raw) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })
}

function Format-BcfStateBlock {
    <#
      Собирает содержимое .bcf/STATE.md — единственное место, где агент видит результат
      быстрой проверки: он запускается подпроцессом и вывода гейтов не наблюдает.
      Отдельной функцией, чтобы «провал команды доехал до STATE» проверялось тестом,
      а не подразумевалось.
    #>
    param(
        [int]$Iteration,
        [string]$TaskId,
        [string[]]$Backpressure = @(),
        [string]$Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    )
    $block = "# Ralph STATE`n`n## Итерация $Iteration — $Timestamp — задача $TaskId`n`n"
    if (@($Backpressure).Count -gt 0) {
        $block += "BACKPRESSURE — исправь это первым шагом следующей итерации:`n`n" + (@($Backpressure) -join "`n`n") + "`n"
    } else {
        $block += "Backpressure чист (быстрая проверка и done-gate прошли). Переходи к следующей фазе активной задачи.`n"
    }
    return $block
}

function Invoke-BcfBackpressure {
    param(
        [string]$Root = (Get-Location).Path,
        [string[]]$Commands = @(),
        [int]$TailLines = 12
    )

    $cmds = @(@($Commands) | Where-Object { $_ -and $_.Trim() -ne '' })
    $signature = ($cmds -join ' ;; ')

    if ($cmds.Count -eq 0) {
        return [pscustomobject]@{
            Skipped   = $true
            Clean     = $false
            Failures  = @()
            Ran       = @()
            Signature = $signature
            Reason    = 'config/harness.json → backpressure.typecheck пуст: быстрая проверка после итерации не выполнялась'
        }
    }

    $failures = @()
    $ran = @()
    foreach ($c in $cmds) {
        $out = ''
        $code = 0
        try {
            # Отдельный процесс, а не `& npx ...`: команда приходит строкой из конфига и
            # может быть любой формы (обёртка .cmd, конвейер, флаги с кавычками). Заодно
            # не протухает $LASTEXITCODE от предыдущей команды цикла — ровно тот дефект,
            # из-за которого проверка типов годами «проходила», не выполнившись ни разу.
            $out = (& pwsh -NoProfile -NonInteractive -Command "Set-Location -LiteralPath '$($Root -replace "'","''")'; $c" 2>&1 | Out-String)
            $code = $LASTEXITCODE
        } catch {
            $out = $_.Exception.Message
            $code = 1
        }
        if ($null -eq $code) { $code = 0 }
        $ran += [pscustomobject]@{ Command = $c; ExitCode = $code }
        if ($code -ne 0) {
            $tail = (($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last $TailLines) -join "`n")
            $failures += [pscustomobject]@{
                Command  = $c
                ExitCode = $code
                Tail     = $tail
                Message  = "BACKPRESSURE FAILED (exit $code): $c`n$tail"
            }
        }
    }

    return [pscustomobject]@{
        Skipped   = $false
        Clean     = ($failures.Count -eq 0)
        Failures  = @($failures)
        Ran       = @($ran)
        Signature = $signature
        Reason    = ''
    }
}
