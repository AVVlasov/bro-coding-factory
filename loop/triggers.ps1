# triggers.ps1 — friction-triggers / human-callouts (W4).
#
# Friction-triggers — это пути/изменения, которые СТАВЯТ ЦИКЛ НА ПАУЗУ для ревью
# человеком до того как правки уйдут на verify (irreversible / high-blast-radius):
#   - DB-миграции, prisma-схемы, изменения зависимостей (package.json и т.п.);
#   - CI-workflow, build/test-config, container-build;
#   - auth/permissions/roles;
#   - удаление более N строк в одном файле.
# Сам список путей и порог удаления НЕ хардкодятся — они грузятся из
# config/triggers.json (bigDeletionThreshold + pathTriggers[]). Адаптируй под проект там.
#
# Database migration зависит от locks/data size in production — human judgment call.
# Ralph не должен делать irreversible вещи без человека.
#
# Поведение:
#   - запускается из loop.ps1 в backpressure section ПЕРЕД VERIFY-REQUEST;
#   - проверяет git diff HEAD на матч с триггерами;
#   - если совпадение — пишет loop/human-callout.md + emit event + exit 2.
#
# Exit codes:
#   0 — нет триггеров (loop продолжается)
#   2 — есть human-callout (loop ставит паузу)
#   1 — внутренняя ошибка
#
# Использование (standalone):
#   pwsh loop/triggers.ps1 -Repo <repo> -TaskId <TASK> -Iteration 5
#   pwsh loop/triggers.ps1 -Repo <repo> -JsonOutput

param(
    [Parameter(Mandatory)] [string] $Repo,
    [string] $TaskId    = '',
    [int]    $Iteration = 0,
    [string] $BaseRef   = '',   # M-09 (2026-05-26): git-ref для diff. Если задан — сравниваем
                                # с ним вместо HEAD. Loop.ps1 передаёт snapshot начала итерации,
                                # чтобы триггер видел ТОЛЬКО правки этой итерации, не pre-existing
                                # uncommitted мусор (типа моих правок CLAUDE.md, незакоммиченных).
    [switch] $JsonOutput,
    [switch] $NoEvent
)

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

Set-Location $Repo

# M-09 D: блокируем запуск из агентской сессии.
. (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
Assert-HarnessCaller -ScriptName 'triggers.ps1'

# ----------------------------------------------------------------------------
# Триггеры грузятся из config/triggers.json — НЕ хардкодятся здесь.
# Структура: { bigDeletionThreshold: int, pathTriggers: [ {pattern, reason, severity} ] }.
# Если файл отсутствует/битый — безопасные дефолты (пустой список, порог 50):
# триггеров нет, цикл не блокируется на ровном месте.
# ----------------------------------------------------------------------------
$repoRoot = Split-Path $PSScriptRoot -Parent
$pathTriggers = @()
$bigDeletionThreshold = 50  # удаление > N строк в одном файле — отдельный триггер
$triggersCfgFile = Join-Path $repoRoot 'config\triggers.json'
if (Test-Path $triggersCfgFile) {
    try {
        $triggersCfg = Get-Content -Raw -LiteralPath $triggersCfgFile | ConvertFrom-Json
        if ($null -ne $triggersCfg.bigDeletionThreshold) {
            $bigDeletionThreshold = [int]$triggersCfg.bigDeletionThreshold
        }
        if ($triggersCfg.pathTriggers) {
            $pathTriggers = @($triggersCfg.pathTriggers | ForEach-Object {
                @{ pattern = [string]$_.pattern; reason = [string]$_.reason; severity = [string]$_.severity }
            })
        }
    } catch { }
}

# ----------------------------------------------------------------------------
# Per-task allowlist (M-09, 2026-05-25)
# Задача может в шапке объявить файлы, которые ей по DoD разрешено трогать —
# тогда trigger на них не зовёт человека. Формат в tasks/<ID>-*.md:
#   **Triggers-allow:** electron/main.ts, electron/preload.ts, electron/ipc/**
# Поддерживаются glob ** и *.
# ----------------------------------------------------------------------------
$taskAllow = @()
if ($TaskId) {
    $tf = Get-ChildItem (Join-Path $Repo 'tasks') -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tf) {
        $line = Select-String -Path $tf.FullName -Pattern '^\s*\*\*Triggers-allow[^:]*:\**\s*(.+)$' | Select-Object -First 1
        if ($line -and $line.Matches[0].Groups[1].Value) {
            $taskAllow = $line.Matches[0].Groups[1].Value.Trim() -split '\s*,\s*' | Where-Object { $_ }
        }
    }
}
function Test-Allowed($file, $patterns) {
    foreach ($p in $patterns) {
        # glob → regex: ** → .*, * → [^/]*, литералы экранируем
        $rx = '^' + ([regex]::Escape($p) -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*') + '$'
        if ($file -match $rx) { return $true }
    }
    return $false
}

# ----------------------------------------------------------------------------
# Сбор данных
# ----------------------------------------------------------------------------
$hits = @()

# 1) Файлы по path-pattern. BaseRef (если задан) даёт diff ТОЛЬКО за текущую итерацию.
$diffRef = if ($BaseRef) { $BaseRef } else { 'HEAD' }
$changedFiles = (git diff $diffRef --name-only 2>$null) -split "`n" | Where-Object { $_ }
$allowedFiles = @()
foreach ($f in $changedFiles) {
    $normalized = $f -replace '\\', '/'
    if ($taskAllow.Count -gt 0 -and (Test-Allowed $normalized $taskAllow)) {
        $allowedFiles += $normalized
        continue
    }
    foreach ($t in $pathTriggers) {
        if ($normalized -match $t.pattern) {
            $hits += [ordered]@{
                file     = $normalized
                pattern  = $t.pattern
                reason   = $t.reason
                severity = $t.severity
            }
            break
        }
    }
}

# 2) Big-deletion check (per file)
$numstat = (git diff $diffRef --numstat 2>$null) -split "`n" | Where-Object { $_ }
foreach ($line in $numstat) {
    $parts = $line -split "`t"
    if ($parts.Length -ge 3) {
        $deleted = 0
        if ([int]::TryParse($parts[1], [ref]$deleted) -and $deleted -ge 0 -and $parts[1] -ne '-') {
            $deletedLines = [int]$parts[1]  # added
            $removedLines = if ($parts[0] -ne '-') { [int]$parts[0] } else { 0 }  # parts[0] = added
            # numstat format: added \t deleted \t path
            $rmCount = if ($parts[1] -ne '-') { [int]$parts[1] } else { 0 }
            if ($rmCount -gt $bigDeletionThreshold) {
                $normPath = ($parts[2] -replace '\\', '/')
                if (-not ($taskAllow.Count -gt 0 -and (Test-Allowed $normPath $taskAllow))) {
                    $hits += [ordered]@{
                        file     = $normPath
                        pattern  = "deletion>$bigDeletionThreshold"
                        reason   = "удалено $rmCount строк в одном файле (порог $bigDeletionThreshold)"
                        severity = 'medium'
                    }
                }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Output + side-effects
# ----------------------------------------------------------------------------
if ($hits.Count -gt 0) {
    # Уникализируем по file+pattern
    $hits = $hits | Group-Object { "$($_.file):$($_.pattern)" } | ForEach-Object { $_.Group[0] }

    # 1) human-callout.md (живёт в каталоге харнеса loop/)
    $calloutFile = Join-Path $PSScriptRoot 'human-callout.md'
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $body = @()
    $body += "# Human callout — Ralph пауза"
    $body += ""
    $body += "**Когда:** $ts"
    $body += "**Задача:** $(if ($TaskId) { $TaskId } else { '(не передана)' })"
    $body += "**Итерация:** $Iteration"
    $body += ""
    $body += "Изменения требуют твоего ревью **до** того как они уйдут на verify (Фазы C–E)."
    $body += ""
    $body += "## Триггеры"
    $body += ""
    $body += "| File | Pattern | Severity | Reason |"
    $body += "|---|---|---|---|"
    foreach ($h in $hits) {
        $body += "| ``$($h.file)`` | ``$($h.pattern)`` | $($h.severity) | $($h.reason) |"
    }
    $body += ""
    $body += "## Что делать"
    $body += ""
    $body += "1. Открой ``git diff HEAD -- <files>`` — проверь, что изменения умышленные."
    $body += "2. Если нужно: исправь / откати / закоммить вручную."
    $body += "3. Удали ``loop/human-callout.md`` ИЛИ создай ``loop/STOP`` для полной остановки."
    $body += "4. Запусти ``loop/start.ps1 <TASK>`` для продолжения."
    Set-Content -LiteralPath $calloutFile -Value ($body -join "`n") -Encoding UTF8

    # 2) emit event (если разрешено)
    if (-not $NoEvent) {
        $eventBus = Join-Path $PSScriptRoot 'lib\event-bus.ps1'
        if (Test-Path $eventBus) {
            . $eventBus
            Initialize-EventBus -RalphRoot $PSScriptRoot
            Append-Event -EventType 'human-callout' -TaskId $TaskId -Phase 'loop' -Iteration $Iteration `
                -Payload @{
                    trigger_count = $hits.Count
                    triggers      = @($hits | ForEach-Object { "$($_.severity):$($_.pattern):$($_.file)" })
                    callout_file  = 'loop/human-callout.md'
                }
        }
    }

    if ($JsonOutput) {
        $result = [ordered]@{
            ts            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            passed        = $false
            hit_count     = $hits.Count
            hits          = $hits
            callout_file  = 'loop/human-callout.md'
        }
        Write-Output ($result | ConvertTo-Json -Depth 6)
    } else {
        Write-Output "FRICTION-TRIGGERS: HUMAN CALLOUT ($($hits.Count) hits)"
        foreach ($h in $hits) {
            Write-Output "  [$($h.severity)] $($h.file) ← $($h.reason)"
        }
        Write-Output ""
        Write-Output "Подробности: loop/human-callout.md"
    }
    exit 2
} else {
    if ($JsonOutput) {
        Write-Output '{"passed":true,"hit_count":0}'
    } else {
        Write-Output 'FRICTION-TRIGGERS: PASS (no critical changes)'
    }
    exit 0
}
