# lint-gate.ps1 — pre-Phase-B mechanical check.
#
# Идея: lint-сообщения = prompts для агента; каждое правило несёт remediation-инструкцию.
# Механически энфорсим: no bare catch, no silent fallbacks. Опциональные проектные
# правила (console в определённых директориях, запрещённые UI-паттерны, non-target-script
# детектор) настраиваются в hooks/hooks-config.json — по умолчанию выключены (no-op).
#
# Этот скрипт — gate: запускается из loop.ps1 как часть backpressure после tsc/done-gate.
# Падение правил → агент должен это исправить ДО создания VERIFY-REQUEST.
#
# Exit codes:
#   0  — всё чисто
#   1  — есть violations (backpressure agent'у)
#   2  — внутренняя ошибка (lint не запускается; не блокировать цикл)
#
# Использование (standalone, из корня репо):
#   pwsh harness/lint-gate.ps1
#   pwsh harness/lint-gate.ps1 -JsonOutput   # для парсинга

param(
    # Дефолт — текущая директория. Раннер (loop.ps1) всегда передаёт явно;
    # ручной вызов из корня репо работает «как ожидается».
    [string] $Repo = (Get-Location).Path,
    [switch] $JsonOutput
)

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

Set-Location $Repo

# Блокируем запуск из агентской CLI-сессии (см. lib/harness-guard.ps1).
. (Join-Path $PSScriptRoot 'lib\harness-guard.ps1')
Assert-HarnessCaller -ScriptName 'lint-gate.ps1'

# --- Конфиг: productPaths из harness.json, опциональные правила из hooks-config.json. ---
$ProductPaths = @('src')
$HooksCfg = $null
try {
    $hf = Join-Path $Repo 'config\harness.json'
    if (Test-Path $hf) { $hc = Get-Content -Raw $hf | ConvertFrom-Json; if ($hc.productPaths) { $ProductPaths = @($hc.productPaths) } }
} catch { }
try {
    $hcf = Join-Path $Repo '.claude\hooks\hooks-config.json'
    if (Test-Path $hcf) { $HooksCfg = Get-Content -Raw $hcf | ConvertFrom-Json }
} catch { }

$findings = @()

# ----------------------------------------------------------------------------
# 1) ESLint (если есть проект-конфиг и npx)
# ----------------------------------------------------------------------------
$hasEslint = (Test-Path (Join-Path $Repo 'eslint.config.js')) -or
             (Test-Path (Join-Path $Repo 'eslint.config.mjs')) -or
             (Test-Path (Join-Path $Repo 'eslint.config.cjs')) -or
             (Test-Path (Join-Path $Repo '.eslintrc.json')) -or
             (Test-Path (Join-Path $Repo '.eslintrc.cjs'))

if ($hasEslint) {
    try {
        $eslintOut = & npx --no-install eslint --format compact @ProductPaths 2>&1
        $eslintExit = $LASTEXITCODE
        if ($eslintExit -ne 0) {
            $lines = @($eslintOut | Where-Object { $_ -match ':\d+:\d+:.+' })
            if ($lines.Count -eq 0) { $lines = @($eslintOut | Select-Object -Last 10) }
            $findings += [ordered]@{
                check    = 'eslint'
                severity = 'error'
                count    = $lines.Count
                tail     = ($lines | Select-Object -Last 30) -join "`n"
            }
        }
    } catch {
        # eslint не запустился — не блокируем (это не agent fault).
    }
}

# ----------------------------------------------------------------------------
# 2) Текстовые проверки (Armin Ronacher rules)
# ----------------------------------------------------------------------------

# 2a. console.* в чувствительных директориях (опционально). Список — hooks-config.json
#     "console_check_dirs": ["server", "src/main", ...]. Пусто/нет → проверка пропускается.
$consoleHits = @()
$consoleDirs = @()
if ($HooksCfg -and $HooksCfg.console_check_dirs) { $consoleDirs = @($HooksCfg.console_check_dirs) }
foreach ($cd in $consoleDirs) {
    $cdPath = Join-Path $Repo $cd
    if (Test-Path $cdPath) {
        $consoleHits += Select-String -Path "$cdPath\*.ts","$cdPath\*.js" `
            -Pattern '\bconsole\.(log|warn|error)\b' -ErrorAction SilentlyContinue
    }
}
if ($consoleHits) {
    $findings += [ordered]@{
        check       = 'no-console-in-dirs'
        severity    = 'error'
        count       = $consoleHits.Count
        remediation = 'console.* в чувствительной директории (может ломать stdout/IPC main-процесса). Используй structured logger. Список директорий — hooks-config.json console_check_dirs.'
        tail        = ($consoleHits | Select-Object -First 10 | ForEach-Object { "$($_.Path):$($_.LineNumber) $($_.Line.Trim())" }) -join "`n"
    }
}

# 2b. bare catch — pattern `catch (e?: any) { ... }` или `catch { }`.
$bareCatchHits = @()
$tsFiles = Get-ChildItem -LiteralPath $Repo -Filter '*.ts' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '\\node_modules\\|\\dist\\|\\dist-electron\\|\\.venv\\|\\harness\\.venv\\' }
foreach ($f in $tsFiles | Select-Object -First 200) {  # сэмплируем для скорости
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if ($content -match 'catch\s*\(\s*[A-Za-z_]\w*\s*\)\s*\{\s*\}' -or
        $content -match 'catch\s*\(\s*[A-Za-z_]\w*\s*:\s*any\s*\)\s*\{\s*[^}]{0,20}\}' -or
        $content -match 'catch\s*\{\s*\}') {
        $bareCatchHits += $f.FullName.Substring($Repo.Length).TrimStart('\','/')
    }
}
if ($bareCatchHits) {
    $findings += [ordered]@{
        check       = 'no-bare-catch'
        severity    = 'warn'
        count       = $bareCatchHits.Count
        remediation = 'Bare catch / catch-and-ignore = silent failure (Armin Ronacher). Логируй и/или re-throw.'
        tail        = ($bareCatchHits | Select-Object -First 10) -join "`n"
    }
}

# 2c. Запрещённые UI/код-паттерны (опционально). Список regex — hooks-config.json
#     "banned_ui_patterns": ["some-banned-regex", ...]. Пусто/нет → проверка пропускается.
$bannedHits = @()
$bannedPatterns = @()
if ($HooksCfg -and $HooksCfg.banned_ui_patterns) { $bannedPatterns = @($HooksCfg.banned_ui_patterns) }
if ($bannedPatterns.Count -gt 0) {
    $scanGlobs = $ProductPaths | ForEach-Object { "$Repo\$_\**\*.tsx","$Repo\$_\**\*.ts" }
    foreach ($pattern in $bannedPatterns) {
        $hits = Select-String -Path $scanGlobs -Pattern $pattern -ErrorAction SilentlyContinue
        if ($hits) { $bannedHits += $hits }
    }
}
if ($bannedHits) {
    $findings += [ordered]@{
        check       = 'banned-ui-patterns'
        severity    = 'error'
        count       = $bannedHits.Count
        remediation = 'Найден запрещённый паттерн (hooks-config.json banned_ui_patterns) — удали/замени.'
        tail        = ($bannedHits | Select-Object -First 10 | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join "`n"
    }
}

# 2d. Тесты, зависящие от текущего времени (опционально). Включается флагом
#     hooks-config.json "time_dependent_tests": true.
#
#     ЗАЧЕМ. clinic-scheduler, 2026-08-09: набор тестов краснел по воскресеньям. Семь
#     тестов стабов строили ожидания от системной даты, и один день в неделю доказывали
#     не то, что задумано. Шесть дней из семи гейт был зелёный, поэтому дефект не считался
#     дефектом — его просто никто не видел в будни. Недетерминированный тест хуже
#     отсутствующего: он даёт зелёный сигнал, не соответствующий состоянию кода, и
#     обесценивает весь набор — красный прогон начинают объяснять «ну оно иногда падает».
#
#     Правило точечное: время без пиновки ИМЕННО в тестовом файле И при отсутствии
#     подмены таймеров. Тест, который сам фиксирует «сейчас», к делу не относится.
$timeDepEnabled = $false
if ($HooksCfg -and $HooksCfg.PSObject.Properties['time_dependent_tests']) {
    $timeDepEnabled = [bool]$HooksCfg.time_dependent_tests
}
# Форсирование через окружение. Нужно там, где правило требуется прогнать, а редактировать
# .claude/ нельзя: во многих проектах обвязка объявлена для кодового агента запретной
# («его проверяют этим инструментом»). Без этого задача «почини недетерминированные тесты»
# не может доказать себя, не нарушив правило проекта.
if ($env:BCF_TIME_DEPENDENT_TESTS -eq '1') { $timeDepEnabled = $true }
if ($timeDepEnabled) {
    $timeHits = @()
    foreach ($d in $ProductPaths) {
        $dir = Join-Path $Repo $d
        if (-not (Test-Path $dir)) { continue }
        $testFiles = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '\.(test|spec)\.[jt]sx?$' -or $_.Name -match '_test\.py$' }
        foreach ($tf in $testFiles) {
            $c = Get-Content -Raw -LiteralPath $tf.FullName -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            # Подменённое время — это ПИНОВКА, а не зависимость: пропускаем.
            if ($c -match 'useFakeTimers|setSystemTime|MockDate|freeze_time|freezegun') { continue }
            $m = [regex]::Match($c, 'new\s+Date\s*\(\s*\)|Date\.now\s*\(\s*\)|\btoday\s*\(\s*\)|datetime\.now\s*\(')
            if ($m.Success) {
                $line = ($c.Substring(0, $m.Index) -split "`n").Count
                $timeHits += "$($tf.FullName.Substring($Repo.Length).TrimStart('\','/')):$line  $($m.Value)"
            }
        }
    }
    if ($timeHits) {
        $findings += [ordered]@{
            check       = 'time-dependent-test'
            severity    = 'error'
            count       = $timeHits.Count
            remediation = 'Тест берёт «сейчас» из системных часов и не подменяет время. Результат такого теста зависит от дня прогона: он бывает зелёным в будни и красным в выходные, и тогда зелёный гейт ничего не доказывает. Зафиксируй дату явно (vi.setSystemTime / freeze_time) либо передавай дату параметром.'
            tail        = ($timeHits | Select-Object -First 15) -join "`n"
        }
    }
}

# ----------------------------------------------------------------------------
# 3) Структурные тесты (Ryan Lepo «tests-about-source») — если файл существует
# ----------------------------------------------------------------------------
$structSpec = Join-Path $Repo 'tests\structure.spec.ts'
if (Test-Path $structSpec) {
    try {
        $structOut = & npx --no-install playwright test tests/structure.spec.ts --reporter=line 2>&1
        if ($LASTEXITCODE -ne 0) {
            $findings += [ordered]@{
                check       = 'structure-tests'
                severity    = 'error'
                remediation = 'tests/structure.spec.ts — структурные нарушения (размер файла, дублирование). См. tail.'
                tail        = ($structOut | Select-Object -Last 20) -join "`n"
            }
        }
    } catch { }
}

# ----------------------------------------------------------------------------
# Non-target-script detector (M-13, 2026-05-27): ловит CJK/хирагану/катакану/
# хангыль в src/ — артефакты декодирования модели (incident: TodayPage.tsx
# 'с昨晚'). Vision/product-critic могут пропустить, потому что визуально это
# всё ещё «текст». Регэксп — детерминированный.
# ----------------------------------------------------------------------------
$detectorPath = if ($env:BCF_NONTARGET_DETECTOR) { $env:BCF_NONTARGET_DETECTOR } else { Join-Path $Repo 'hooks\non-target-script-detector.sh' }
# bash: env BCF_BASH, иначе ищем в PATH (Get-Command). Опционально — детектор может отсутствовать.
. (Join-Path $PSScriptRoot 'lib\bcf-context.ps1')
$gitBash = Get-BcfBash
if ((Test-Path $detectorPath) -and $gitBash -and (Test-Path $gitBash)) {
    $targets = @()
    foreach ($d in $ProductPaths) {
        $dir = Join-Path $Repo $d
        if (Test-Path $dir) {
            $targets += Get-ChildItem -Path $dir -Recurse -File -Include '*.ts','*.tsx','*.js','*.jsx','*.css','*.scss','*.vue','*.svelte','*.html' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName -replace '\\','/' }
        }
    }
    if ($targets.Count -gt 0) {
        $detectorOut = & $gitBash ($detectorPath -replace '\\','/') @targets 2>&1
        if ($LASTEXITCODE -ne 0) {
            $findings += [ordered]@{
                check       = 'non-target-script'
                severity    = 'error'
                remediation = "Найдены CJK/хирагана/катакана/хангыль в продуктовом коде — артефакт декодирования модели. Замени на русский/английский текст. Подробности ниже."
                tail        = (($detectorOut | Select-Object -First 20) -join "`n")
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
if ($JsonOutput) {
    $result = [ordered]@{
        ts       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        passed   = ($findings.Count -eq 0)
        findings = $findings
    }
    Write-Output ($result | ConvertTo-Json -Depth 6)
} else {
    if ($findings.Count -eq 0) {
        Write-Output 'LINT-GATE: PASS (no violations)'
    } else {
        Write-Output "LINT-GATE: FAIL ($($findings.Count) violations)`n"
        foreach ($f in $findings) {
            Write-Output "[$($f.severity)] $($f.check) — count=$($f.count)"
            if ($f.remediation) { Write-Output "  remediation: $($f.remediation)" }
            if ($f.tail) {
                $tailIndented = ($f.tail -split "`n" | ForEach-Object { "    $_" }) -join "`n"
                Write-Output $tailIndented
            }
            Write-Output ''
        }
    }
}

if ($findings.Count -eq 0) { exit 0 } else { exit 1 }
