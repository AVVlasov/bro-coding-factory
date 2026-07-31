# bug-supervisor.ps1 — мостик supervisor-agent ↔ bug_tracker.py в loop-harness.
# Используется loop.ps1 после verdict-recorded.

# Repo root: env override, иначе два уровня вверх от lib-каталога (REPO\harness\lib → REPO).
. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:RepoRoot    = Get-BcfProjectRoot
$script:BugTracker  = if ($env:BCF_BUG_TRACKER)     { $env:BCF_BUG_TRACKER }     else { Join-Path $script:RepoRoot 'memory/pgvector/bug_tracker.py' }
$script:Invoker     = if ($env:BCF_INVOKE_SUPERVISOR) { $env:BCF_INVOKE_SUPERVISOR } else { Join-Path $script:RepoRoot 'agents/bin/invoke-supervisor.ps1' }
$script:TestAuthor  = if ($env:BCF_INVOKE_TEST_AUTHOR) { $env:BCF_INVOKE_TEST_AUTHOR } else { Join-Path $script:RepoRoot 'agents/bin/invoke-test-author.ps1' }

function Author-RegressionTest {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ShortId,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter(Mandatory)][string]$Verification,
        [string]$Severity = 'high',
        [string[]]$RelatedFiles = @()
    )
    if (-not (Test-Path $script:TestAuthor)) { return $null }

    $root = $script:RepoRoot
    # Тест-раскладка проекта — конфигурируема (env), нейтральные дефолты.
    $testRoot   = if ($env:BCF_TEST_REGRESSION_ROOT) { $env:BCF_TEST_REGRESSION_ROOT } else { 'tests/regressions/' }
    $testDirRel = if ($env:BCF_TEST_DIR) { $env:BCF_TEST_DIR } else { 'tests' }
    $specGlob   = if ($env:BCF_TEST_SPEC_GLOB) { $env:BCF_TEST_SPEC_GLOB } else { '*.spec.ts' }
    $testConfig = if ($env:BCF_TEST_CONFIG) { $env:BCF_TEST_CONFIG } else { '' }
    $existingSpecs = @()
    $dir = Join-Path $root ($testDirRel -replace '/','\')
    if (Test-Path $dir) {
        $existingSpecs = @(Get-ChildItem -Path $dir -Recurse -Filter $specGlob -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { ($_.FullName -replace [regex]::Escape($root + '\'),'') -replace '\\','/' })
    }

    $input = @{
        task_id              = $TaskId
        short_id             = $ShortId
        summary              = $Summary
        verification         = $Verification
        severity             = $Severity
        related_files        = $RelatedFiles
        existing_specs_in_area = $existingSpecs
        test_root            = $testRoot
        test_config          = $testConfig
    } | ConvertTo-Json -Depth 10

    $tmp = Join-Path $env:TEMP "test-author-$TaskId-$ShortId.json"
    Set-Content -LiteralPath $tmp -Value $input -Encoding UTF8
    $out = Get-Content -Raw -LiteralPath $tmp | & pwsh -NoProfile -File $script:TestAuthor 2>$null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $out) { return $null }
    try { $authored = $out | ConvertFrom-Json } catch { return $null }

    if ($authored.spec_kind -eq 'unwritable') {
        Log "[test-author] B-${ShortId}: spec unwritable — $($authored.red_state_observable)"
        return $authored
    }
    if (-not $authored.spec_content -or -not $authored.spec_path) {
        Log "[test-author] B-${ShortId}: empty spec_content/path — skipping write"
        return $authored
    }

    $specFull = Join-Path $root ($authored.spec_path -replace '/','\')
    $specDir  = Split-Path -Parent $specFull
    if (-not (Test-Path $specDir)) { New-Item -ItemType Directory -Force -Path $specDir | Out-Null }
    Set-Content -LiteralPath $specFull -Value $authored.spec_content -Encoding UTF8
    Log "[test-author] B-${ShortId}: spec написан → $($authored.spec_path) ($($authored.spec_kind))"

    # Линкуем в bug_tracker.
    & python $script:BugTracker link-test --task $TaskId --short-id $ShortId --test-path $authored.spec_path 2>$null | Out-Null

    return $authored
}

function Run-IterationSupervisor {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][string]$JudgeOutFile,
        [Parameter(Mandatory)][string]$VerdictFile,
        [string]$DiffFingerprint = '',
        [string[]]$DiffFiles = @()
    )
    if (-not (Test-Path $script:Invoker))    { return $null }
    if (-not (Test-Path $script:BugTracker)) { return $null }

    # 1. Собрать input.
    $judgeText = if (Test-Path $JudgeOutFile) { Get-Content -Raw -LiteralPath $JudgeOutFile } else { '' }
    $remediation = @()
    $verdict = ''
    $jm = [regex]::Match($judgeText, '(?s)\{(?:[^{}]|\{[^{}]*\})*"verdict"\s*:\s*"[^"]+"(?:[^{}]|\{[^{}]*\})*\}')
    if ($jm.Success) {
        try {
            $jj = $jm.Value | ConvertFrom-Json -ErrorAction Stop
            $verdict = "$($jj.verdict)"
            if ($jj.remediation) {
                foreach ($r in @($jj.remediation)) {
                    if ($r -is [string]) {
                        $remediation += @{ summary = $r; verification = $r; severity = 'medium' }
                    } else {
                        $remediation += @{
                            summary      = "$($r.summary)"
                            verification = "$($r.verification ?? $r.summary)"
                            severity     = if ($r.severity) { "$($r.severity)".ToLower() } else { 'medium' }
                        }
                    }
                }
            }
        } catch { }
    }
    if (-not $remediation -or $remediation.Count -eq 0) { return $null }   # Нет remediation — нечего трекать.

    # 2. Текущие open/chronic bugs (для prev_open_bugs).
    $listJson = & python $script:BugTracker list --task $TaskId --status all 2>$null
    $prevOpen = @()
    if ($listJson) {
        try {
            $allBugs = $listJson | ConvertFrom-Json
            $prevOpen = @($allBugs | Where-Object { $_.status -in @('open','chronic') } | ForEach-Object {
                @{ short_id = $_.short_id; summary = $_.summary; verification = $_.verification; status = $_.status; reopened_count = $_.reopened_count }
            })
        } catch { }
    }

    # 3. Вызвать supervisor.
    $input = @{
        task_id           = $TaskId
        iteration         = $Iteration
        diff_fingerprint  = $DiffFingerprint
        judge_verdict     = $verdict
        remediation       = $remediation
        findings_extra    = @()
        prev_open_bugs    = $prevOpen
        diff_files        = $DiffFiles
    } | ConvertTo-Json -Depth 10

    $tmp = Join-Path $env:TEMP "supervisor-$TaskId-$Iteration.json"
    Set-Content -LiteralPath $tmp -Value $input -Encoding UTF8
    $out = Get-Content -Raw -LiteralPath $tmp | & pwsh -NoProfile -File $script:Invoker 2>$null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not $out) { return $null }

    try { $supervised = $out | ConvertFrom-Json } catch { return $null }

    # 4. Применяем actions через bug_tracker.py.
    $applied = @{ opened = 0; closed = 0; redetected = 0; reopened = 0; fallback_open = 0 }
    # складываем structural_instruction в history открываемых багов (доступно Inject-OpenBugs).
    $instrByShortId = @{}
    if ($supervised.bundle_for_next_iter) {
      foreach ($entry in @($supervised.bundle_for_next_iter)) {
        if ($entry.short_id -and $entry.structural_instruction) {
          $instrByShortId[$entry.short_id] = $entry.structural_instruction
        }
      }
    }
    # deterministic fallback. Если supervisor (LLM) вернул empty actions при non-empty
    # remediation — open каждый remediation item напрямую. Это защищает от LLM-flakiness
    # (локальные модели нестабильны и иногда возвращают actions:[] хотя remediation непустой).
    $supervisorActionsCount = if ($supervised.actions) { @($supervised.actions).Count } else { 0 }
    if ($supervisorActionsCount -eq 0 -and $remediation.Count -gt 0) {
      Log "[supervisor] LLM вернул actions:[] при $($remediation.Count) remediation — детерминистический fallback"
      $fallbackItems = @()
      foreach ($r in $remediation) {
        $fallbackItems += @{
          task         = $TaskId
          summary      = "$($r.summary)"
          verification = "$($r.verification)"
          severity     = "$($r.severity)"
          opened_by    = 'supervisor-fallback'
          iteration    = $Iteration
        }
      }
      $payload = $fallbackItems | ConvertTo-Json -Depth 6 -AsArray
      # НЕ глушим stderr — 2>$null прятал UniqueViolation (bugs_short_id_key),
      # из-за чего bug-ledger молча не писался у всех задач, кроме первой → самообучение мертво.
      $fbErr = ''
      $fbOut = $payload | & python $script:BugTracker open 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $fbErr += "$_`n"; } else { $_ }
      }
      $fbCount = 0
      if ($fbOut) { try { $fbResults = ($fbOut -join "`n") | ConvertFrom-Json; foreach ($fr in @($fbResults)) { $applied.fallback_open++; $fbCount++ } } catch { $fbErr += "parse: $($_.Exception.Message)`n" } }
      if ($fbCount -eq 0) { Log "[supervisor] ВНИМАНИЕ: fallback-open записал 0 багов из $($remediation.Count) (bug_tracker сбой?). stderr: $($fbErr.Trim())" }
    }
    if ($supervised.actions) {
        foreach ($a in $supervised.actions) {
            switch ($a.kind) {
                'open' {
                    $payload = @(@{
                        task         = $TaskId
                        summary      = "$($a.summary)"
                        verification = "$($a.verification)"
                        severity     = if ($a.severity) { "$($a.severity)" } else { 'medium' }
                        opened_by    = if ($a.opened_by) { "$($a.opened_by)" } else { 'supervisor' }
                        iteration    = $Iteration
                    }) | ConvertTo-Json -Depth 6 -AsArray
                    $r = $payload | & python $script:BugTracker open 2>$null
                    if ($r) {
                        try { $rr = $r | ConvertFrom-Json; foreach ($i in $rr) { $applied[($i.action)]++ } } catch { }
                    }
                }
                'close' {
                    & python $script:BugTracker close --task $TaskId --short-id "$($a.short_id)" `
                        --diff-fingerprint $DiffFingerprint --iteration $Iteration 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $applied.closed++ }
                }
                'chronic_note' { }   # informational, no DB write
            }
        }
    }

    # 5. Phase 2: для каждого chronic без regression_test_path — запускаем test-author.
    $listJson2 = & python $script:BugTracker list --task $TaskId --status chronic 2>$null
    if ($listJson2) {
        try {
            $chronicBugs = $listJson2 | ConvertFrom-Json
            foreach ($cb in @($chronicBugs)) {
                if ($cb.regression_test_path) { continue }   # тест уже есть
                Log "[supervisor] chronic $($cb.short_id) без regression test — зовём test-author"
                Author-RegressionTest -TaskId $TaskId -ShortId $cb.short_id `
                    -Summary $cb.summary -Verification $cb.verification `
                    -Severity $cb.severity -RelatedFiles $DiffFiles | Out-Null
            }
        } catch { Log "test-author trigger failed (non-fatal): $($_.Exception.Message)" }
    }

    # 6. Возвращаем supervised object — caller инжектит в STATE.md.
    $supervised | Add-Member -NotePropertyName _applied -NotePropertyValue $applied -Force
    return $supervised
}

function Inject-OpenBugs {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$TaskId
    )
    $listJson = & python $script:BugTracker list --task $TaskId --status all 2>$null
    if (-not $listJson) { return }
    try { $bugs = $listJson | ConvertFrom-Json } catch { return }
    $active = @($bugs | Where-Object { $_.status -in @('open','chronic') })
    if ($active.Count -eq 0) { return }

    $lines = @()
    $lines += "<open-bugs task='$TaskId' count='$($active.Count)' chronic='$(@($active | Where-Object { $_.status -eq 'chronic' }).Count)'>"
    $lines += "Список открытых багов этой задачи. Закрой их в следующей итерации; на chronic — обязателен regression-test."
    $lines += ""
    $priority = 1
    foreach ($b in ($active | Sort-Object @{e={ if ($_.status -eq 'chronic') {0} else {1} }}, @{e={ switch("$($_.severity)".ToLower()){'critical'{0};'high'{1};'medium'{2};default{3}} }}, opened_at)) {
        $tag = if ($b.status -eq 'chronic') { '🔴 CHRONIC' } else { "[$($b.severity)]" }
        $lines += "$priority. $($b.short_id) $tag $($b.summary)"
        $lines += "    verification: $($b.verification)"
        # structural_instruction из последнего bundle (если был от supervisor'а).
        if ($b.history) {
            foreach ($h in @($b.history)) {
                if ($h -match 'structural_instruction:\s*(.+)$') { $lines += "    💡 $($Matches[1])"; break }
            }
        }
        if ($b.status -eq 'chronic') {
            $regRoot = if ($env:BCF_TEST_REGRESSION_ROOT) { $env:BCF_TEST_REGRESSION_ROOT.TrimEnd('/') } else { 'tests/regressions' }
            $rt = if ($b.regression_test_path) { $b.regression_test_path } else { "$regRoot/$($b.short_id).spec.ts (TODO)" }
            $lines += "    regression test: $rt"
            $lines += "    reopened $($b.reopened_count) times — на этот раз закрой С тестом."
        }
        $priority++
    }
    $lines += "</open-bugs>"
    $lines += ""

    $original = if (Test-Path $StateFile) { Get-Content -Raw -LiteralPath $StateFile } else { '' }
    $original = [regex]::Replace($original, '(?s)<open-bugs[^>]*>.*?</open-bugs>\r?\n?', '')
    $injected = ($lines -join "`n") + $original
    Set-Content -LiteralPath $StateFile -Value $injected -Encoding UTF8
    Write-Host "[memory/bug] injected $($active.Count) open-bugs into STATE.md" -ForegroundColor DarkCyan
}
