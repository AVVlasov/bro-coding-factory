# claims.ps1 — общая память между параллельными агентами о том, кто какие файлы трогает.
#
# ЗАЧЕМ. git worktree изолирует рабочие деревья, но (документированное ограничение)
# НЕ предупреждает, что две ветки правят одни файлы: конфликт всплывает на слиянии,
# когда оба агента уже приняли несовместимые решения. Локи под работу агента —
# отдельно известный провал (у Cursor 20 агентов дали пропускную способность 2–3:
# держали лок слишком долго). Поэтому здесь НЕ лок на время работы, а
# **допуск на старте** плюс накопление фактов.
#
# Разбор подходов и цифры — wiki/research/2026-07-26-parallel-agents-file-conflicts.md.
#
# Три источника знания, и все три общие для всех процессов:
#   1. claims.json    — какие файлы держат прямо сейчас запущенные задачи;
#   2. co-change      — какие файлы исторически меняются вместе (git log), то есть
#                       связаны, даже если в декларации задачи их нет;
#   3. conflicts.json — какие пары задач реально столкнулись раньше. Планировщик
#                       больше не сводит их в параллель, даже если декларации чисты.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
$script:FleetDir      = Join-Path (Get-BcfProjectRoot) '.bcf\fleet'
$script:ClaimsFile    = Join-Path $script:FleetDir 'claims.json'
$script:ConflictsFile = Join-Path $script:FleetDir 'conflicts.json'
$script:CoChangeFile  = Join-Path $script:FleetDir 'co-change.json'

function _Ensure-FleetDir {
    if (-not (Test-Path $script:FleetDir)) {
        New-Item -ItemType Directory -Force -Path $script:FleetDir | Out-Null
    }
}

# Все изменения реестра — под межпроцессной блокировкой: параллельные раннеры
# читают-модифицируют-пишут один и тот же файл.
function _With-ClaimsLock {
    param([Parameter(Mandatory)][scriptblock]$Body)
    _Ensure-FleetDir
    $lockPath = Join-Path $script:FleetDir 'claims.lock'
    $fs = $null
    for ($i = 0; $i -lt 100; $i++) {
        try { $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    try { return & $Body }
    finally { if ($fs) { try { $fs.Dispose() } catch { } } }
}

function _Read-Json($path, $default) {
    if (-not (Test-Path $path)) { return $default }
    try {
        $raw = Get-Content -Raw -LiteralPath $path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        return ($raw | ConvertFrom-Json)
    } catch { return $default }
}

function _Write-Json($path, $obj) {
    _Ensure-FleetDir
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
}

# --- Объявленные файлы задачи: секция «## Файлы» task-файла ---
function Get-TaskDeclaredFiles {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)

    # Пустой результат уходит вызывающему как $null (PowerShell разворачивает пустой
    # массив на выходе функции). Вызывающие обёрнуты в @(), поэтому у них он снова
    # становится пустым массивом; терпимость к $null нужна только тем, кто передаёт
    # результат дальше параметром — см. Get-CoupledFiles.
    $tasksDir = Join-Path $Root 'tasks'
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return @() }
    $body = Get-Content -Raw -LiteralPath $tf.FullName
    $m = [regex]::Match($body, '(?ms)^##[^\r\n]*Файлы.*?(?=^##\s|\z)')
    if (-not $m.Success) { return @() }
    # Только элементы списка. Раньше выкусывались любые «похожие на файл» токены из
    # всей секции — и пояснение вида «не трогай `lib.rs`» попадало в декларацию как
    # заявка на файл. В результате все задачи «сталкивались» на lib.rs и параллелизм
    # выключался полностью.
    $files = @()
    foreach ($line in ($m.Value -split "`r?`n")) {
        if ($line -notmatch '^\s*[-*]\s') { continue }
        foreach ($pm in [regex]::Matches($line, '([A-Za-z0-9_][A-Za-z0-9_./-]+\.[A-Za-z0-9]+)')) {
            $files += ($pm.Groups[1].Value -replace '\\', '/')
        }
    }
    return @($files | Select-Object -Unique)
}

# --- Связность из истории: какие файлы ходят в коммитах вместе с данными ---
#
# Декларация врёт: агент правит scan.rs, а ломает main.rs, который его зовёт.
# Co-change — дешёвый суррогат графа зависимостей: если два файла попадали в один
# коммит чаще порога, считаем их связанными и держим занятыми вместе.
function Update-CoChangeIndex {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxCommits = 300,
        [int]$MinPairCount = 2,
        # Файлы-хабы (lib.rs, mod.rs, index.ts, package.json) меняются вместе со ВСЕМ,
        # поэтому как сигнал связности бесполезны: попав в индекс, они склеивают весь
        # бэклог в одну неразделимую массу и параллелизм становится невозможен.
        # Отбрасываем всё, у чего степень связей выше порога.
        [int]$MaxDegree = 8
    )

    $log = & git -C $Root log --pretty=format:'@@' --name-only -n $MaxCommits 2>$null
    if (-not $log) { return @{} }

    $pairs = @{}
    $current = @()
    $flush = {
        if ($current.Count -gt 1 -and $current.Count -le 25) {   # мега-коммиты (рефакторинг всего) шумят
            for ($a = 0; $a -lt $current.Count; $a++) {
                for ($b = $a + 1; $b -lt $current.Count; $b++) {
                    $k1 = $current[$a]; $k2 = $current[$b]
                    $key = if ($k1 -lt $k2) { "$k1`t$k2" } else { "$k2`t$k1" }
                    if ($pairs.ContainsKey($key)) { $pairs[$key]++ } else { $pairs[$key] = 1 }
                }
            }
        }
        $current = @()
    }
    foreach ($line in $log) {
        $t = "$line".Trim()
        if ($t -eq '@@') { & $flush; continue }
        if ($t) { $current += ($t -replace '\\', '/') }
    }
    & $flush

    $index = @{}
    foreach ($key in $pairs.Keys) {
        if ($pairs[$key] -lt $MinPairCount) { continue }
        $parts = $key -split "`t"
        foreach ($side in 0, 1) {
            $from = $parts[$side]; $to = $parts[1 - $side]
            if (-not $index.ContainsKey($from)) { $index[$from] = @() }
            if ($index[$from] -notcontains $to) { $index[$from] += $to }
        }
    }
    # Убираем хабы: и как ключи, и из списков соседей.
    $hubs = @($index.Keys | Where-Object { @($index[$_]).Count -gt $MaxDegree })
    foreach ($h in $hubs) { $index.Remove($h) }
    if ($hubs.Count) {
        foreach ($k in @($index.Keys)) {
            $index[$k] = @($index[$k] | Where-Object { $hubs -notcontains $_ })
        }
    }

    _Write-Json $script:CoChangeFile @{
        built_at = (Get-Date -Format 'o'); commits = $MaxCommits
        max_degree = $MaxDegree; hubs_dropped = @($hubs)
        index = $index
    }
    return $index
}

function Get-CoupledFiles {
    # Не Mandatory: задача без объявленных файлов — законное состояние на входе, и
    # отказывать ей должен планировщик с внятной причиной, а не привязка параметра.
    param([string[]]$Files = @())

    if (-not $Files -or -not $Files.Count) { return @() }
    $data = _Read-Json $script:CoChangeFile $null
    if (-not $data -or -not $data.index) { return @() }
    $out = @()
    foreach ($f in $Files) {
        $linked = $data.index.$f
        if ($linked) { $out += @($linked) }
    }
    return @($out | Select-Object -Unique | Where-Object { $Files -notcontains $_ })
}

# --- Реестр заявок ---

function Get-ActiveClaims {
    $claims = _Read-Json $script:ClaimsFile @()
    $alive = @()
    foreach ($c in @($claims)) {
        # Осиротевшие заявки (процесс умер) не должны блокировать очередь навсегда.
        if ($c.pid -and -not (Get-Process -Id $c.pid -ErrorAction SilentlyContinue)) { continue }
        $alive += $c
    }
    return $alive
}

# Проверка допуска. Возвращает @{ Ok; Reason; Blocking }.
function Test-TaskAdmission {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Root,
        [switch]$UseCoupling
    )

    $declared = Get-TaskDeclaredFiles -TaskId $TaskId -Root $Root
    if ($declared.Count -eq 0) {
        # Без декларации мы не знаем, что задача тронет — параллелить вслепую нельзя.
        return @{ Ok = $false; Reason = "нет секции «## Файлы» — параллельный запуск запрещён"; Blocking = @() }
    }

    $mine = @($declared)
    if ($UseCoupling) { $mine += Get-CoupledFiles -Files $declared }
    $mine = @($mine | Select-Object -Unique)

    foreach ($c in Get-ActiveClaims) {
        if ($c.task -eq $TaskId) { continue }
        $theirs = @($c.files)
        $overlap = @($mine | Where-Object { $theirs -contains $_ })
        if ($overlap.Count) {
            return @{ Ok = $false; Reason = "пересечение файлов с $($c.task): $($overlap -join ', ')"; Blocking = @($c.task) }
        }
    }

    # Память о прошлых столкновениях: пара, которая уже конфликтовала, в параллель не идёт,
    # даже если декларации сейчас чисты (связь могла быть не объявлена).
    $conflicts = _Read-Json $script:ConflictsFile @()
    $runningTasks = @((Get-ActiveClaims) | ForEach-Object { $_.task })
    foreach ($cf in @($conflicts)) {
        $pair = @($cf.pair)
        if ($pair -contains $TaskId) {
            $other = @($pair | Where-Object { $_ -ne $TaskId })
            $hit = @($other | Where-Object { $runningTasks -contains $_ })
            if ($hit.Count) {
                return @{ Ok = $false; Reason = "пара уже конфликтовала раньше ($($cf.files -join ', '))"; Blocking = @($hit) }
            }
        }
    }

    return @{ Ok = $true; Reason = 'нет пересечений'; Blocking = @() }
}

function Add-TaskClaim {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Root,
        [int]$ProcessId = $PID,
        [switch]$UseCoupling
    )
    _With-ClaimsLock {
        $declared = Get-TaskDeclaredFiles -TaskId $TaskId -Root $Root
        $files = @($declared)
        if ($UseCoupling) { $files += Get-CoupledFiles -Files $declared }
        $claims = @(_Read-Json $script:ClaimsFile @()) | Where-Object { $_.task -ne $TaskId }
        $claims = @($claims) + @([pscustomobject]@{
            task     = $TaskId
            pid      = $ProcessId
            files    = @($files | Select-Object -Unique)
            declared = @($declared)
            since    = (Get-Date -Format 'o')
        })
        _Write-Json $script:ClaimsFile $claims
    }
}

function Remove-TaskClaim {
    param([Parameter(Mandatory)][string]$TaskId)
    _With-ClaimsLock {
        $claims = @(_Read-Json $script:ClaimsFile @()) | Where-Object { $_.task -ne $TaskId }
        _Write-Json $script:ClaimsFile @($claims)
    }
}

# Факт реального столкновения — в память. Это то, чего не даёт ни worktree, ни лок:
# схема учится на собственных конфликтах.
function Register-TaskConflict {
    param(
        [Parameter(Mandatory)][string[]]$Pair,
        [string[]]$Files = @(),
        [string]$Kind = 'merge'
    )
    _With-ClaimsLock {
        $conflicts = @(_Read-Json $script:ConflictsFile @())
        $conflicts += [pscustomobject]@{
            pair  = @($Pair | Sort-Object)
            files = @($Files)
            kind  = $Kind
            at    = (Get-Date -Format 'o')
        }
        _Write-Json $script:ConflictsFile @($conflicts)
    }
}

function Get-KnownConflicts { return @(_Read-Json $script:ConflictsFile @()) }
