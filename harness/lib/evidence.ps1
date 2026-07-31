# evidence.ps1 — машинно-агрегируемое доказательство для Phase E.
#
# Принцип: judge должен читать tool-trace, а не output агента. Этот модуль собирает
# факты прямо из репозитория и работающих артефактов, минуя рассуждения
# агента/тестеров.
#
# Используется из harness/verify.ps1 (Phase E) — добавляется в JSON-блок verdict-файла.

function Collect-Evidence {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [string[]]$TaskFiles = @(),
        [string]$VerifyWorkDir = ''
    )

    $ev = [ordered]@{
        collected_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }

    # 1. Git facts ----------------------------------------------------------
    Push-Location $Repo
    try {
        $headSha = (git rev-parse HEAD 2>$null).Trim()
        $ev.head_sha = $headSha

        # diff fingerprint
        $diff = (git diff HEAD 2>$null | Out-String)
        if ($diff) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($diff)
            $sha = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
            $ev.diff_fingerprint = ([BitConverter]::ToString($sha) -replace '-', '').ToLower()
            $diffStat = (git diff --stat HEAD 2>$null | Out-String).Trim()
            $lastLine = ($diffStat -split "`n" | Select-Object -Last 1)
            if ($lastLine -match '(\d+) file[s]? changed') { $ev.files_changed = [int]$Matches[1] }
            if ($lastLine -match '(\d+) insertion') { $ev.lines_added   = [int]$Matches[1] }
            if ($lastLine -match '(\d+) deletion')  { $ev.lines_removed = [int]$Matches[1] }
        } else {
            $ev.diff_fingerprint = 'clean'
        }

        # Recent commits (last 5)
        $log = git log -5 --pretty=format:'%H|%ai|%s' 2>$null
        if ($log) {
            $ev.recent_commits = @($log -split "`n" | ForEach-Object {
                $parts = $_ -split '\|', 3
                if ($parts.Length -eq 3) {
                    [ordered]@{ sha = $parts[0].Substring(0,7); date = $parts[1]; subject = $parts[2] }
                }
            })
        }
        # WIP-снапшоты прогресса (durable refs, см. loop.ps1 Save-WipSnapshot).
        # Петля не коммитит в основную историю (cumulative diff HEAD — source of
        # truth), поэтому прогресс отражаем через refs/bcf/wip-history.
        $wipHist = @(git for-each-ref --format='%(refname:short)|%(objectname:short)|%(committerdate:iso)' refs/bcf/wip-history 2>$null)
        if ($wipHist) {
            $latest = git for-each-ref --sort=-committerdate --count=1 --format='%(objectname:short)|%(committerdate:iso)' refs/bcf/wip-history 2>$null
            $lp = ($latest -split '\|', 2)
            $ev.wip_snapshots = [ordered]@{
                count       = @($wipHist).Count
                latest_sha  = $lp[0]
                latest_date = $(if ($lp.Length -gt 1) { $lp[1] } else { $null })
            }
        }
    } finally { Pop-Location }

    # 2. Verify-run artefacts (если есть) -----------------------------------
    if ($VerifyWorkDir -and (Test-Path $VerifyWorkDir)) {
        $checkOuts = Get-ChildItem -LiteralPath $VerifyWorkDir -Filter 'check*.out.txt' -ErrorAction SilentlyContinue
        $exitCodes = @()
        foreach ($f in $checkOuts) {
            $txt = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
            if ($txt -match '^exit=(-?\d+)') { $exitCodes += [int]$Matches[1] }
        }
        if ($exitCodes) {
            $ev.checks = [ordered]@{
                total  = $exitCodes.Count
                passed = ($exitCodes | Where-Object { $_ -eq 0 }).Count
                failed = ($exitCodes | Where-Object { $_ -ne 0 }).Count
            }
        }
    }

    # 3. Vision aggregate (если есть последний прогон vision-suite) ----
    $visionResultsRel = if ($env:BCF_VISION_RESULTS_DIR) { $env:BCF_VISION_RESULTS_DIR } else { 'tests/vision/results' }
    $resultsRoot = if ([System.IO.Path]::IsPathRooted($visionResultsRel)) { $visionResultsRel } else { Join-Path $Repo $visionResultsRel }
    if (Test-Path $resultsRoot) {
        $latestRun = Get-ChildItem $resultsRoot -Directory -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestRun) {
            $aggFile = Join-Path $latestRun.FullName 'aggregate.json'
            if (Test-Path $aggFile) {
                try {
                    $agg = Get-Content -Raw -LiteralPath $aggFile | ConvertFrom-Json
                    # Схема aggregate.json: results[] = { page, theme, ssim, vision: { severity } }.
                    # (Старая схема pages[].severity сохранена как fallback.)
                    $rows = @($agg.results)
                    if ($rows.Count -eq 0) { $rows = @($agg.pages) }
                    # Severity берём из row.vision.severity (новая) либо row.severity (старая).
                    $sev = $rows | ForEach-Object {
                        if ($_.vision -and $_.vision.severity) { $_.vision.severity } else { $_.severity }
                    }
                    $ssims = @($rows | Where-Object { -not $_.stale -and -not $_.error -and "$($_.vision.severity)$($_.severity)" -ne 'UNKNOWN' } |
                              ForEach-Object { $_.ssim } | Where-Object { $_ -ne $null })
                    $ev.vision = [ordered]@{
                        run_id       = $latestRun.Name
                        run_time     = $latestRun.LastWriteTime.ToString('o')
                        page_count   = @($rows).Count
                        critical     = @($sev | Where-Object { $_ -eq 'CRITICAL' }).Count
                        high         = @($sev | Where-Object { $_ -eq 'HIGH' }).Count
                        medium       = @($sev | Where-Object { $_ -eq 'MEDIUM' }).Count
                        pass         = @($sev | Where-Object { $_ -eq 'PASS' }).Count
                        worst_ssim   = if ($ssims.Count) { [math]::Round(($ssims | Measure-Object -Minimum).Minimum, 3) } else { $null }
                    }
                } catch { }
            }
        }
    }

    # 4. Tests-results (если есть) -----------------------------------------
    $trDir = Join-Path $Repo 'test-results'
    if (Test-Path $trDir) {
        $junit = Get-ChildItem -LiteralPath $trDir -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($junit) {
            try {
                [xml]$x = Get-Content -Raw -LiteralPath $junit.FullName
                $ts = @($x.testsuites.testsuite)
                $tot = 0; $fail = 0; $err = 0; $skip = 0
                foreach ($s in $ts) {
                    if ($s.tests)    { $tot  += [int]$s.tests }
                    if ($s.failures) { $fail += [int]$s.failures }
                    if ($s.errors)   { $err  += [int]$s.errors }
                    if ($s.skipped)  { $skip += [int]$s.skipped }
                }
                $ev.tests = [ordered]@{
                    total = $tot; failed = $fail; errors = $err; skipped = $skip;
                    passed = ($tot - $fail - $err - $skip)
                    source = $junit.FullName.Substring($Repo.Length).TrimStart('\','/')
                }
            } catch { }
        }
    }

    # 5. Lint violations (если ESLint cache есть) --------------------------
    $eslintCache = Join-Path $Repo '.eslintcache'
    if (Test-Path $eslintCache) {
        $ev.lint = [ordered]@{ source = '.eslintcache'; present = $true }
    }

    return $ev
}

function Format-EvidenceMd {
    param([Parameter(Mandatory)] $Evidence)
    $lines = @()
    $lines += '## evidence (machine-aggregated)'
    $lines += '```yaml'
    foreach ($k in $Evidence.Keys) {
        $v = $Evidence[$k]
        if ($v -is [hashtable] -or $v -is [System.Collections.IDictionary]) {
            $lines += "${k}:"
            foreach ($k2 in $v.Keys) { $lines += "  ${k2}: $($v[$k2])" }
        } elseif ($v -is [array]) {
            $lines += "${k}:"
            foreach ($item in $v) {
                if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
                    $lines += '  -'
                    foreach ($k2 in $item.Keys) { $lines += "      ${k2}: $($item[$k2])" }
                } else {
                    $lines += "  - $item"
                }
            }
        } else {
            $lines += "${k}: $v"
        }
    }
    $lines += '```'
    return ($lines -join "`n")
}
