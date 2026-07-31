# wizard.ps1 — рамка пошагового экрана и виджеты для него.
#
# ЗАЧЕМ РАМКА ОТДЕЛЬНО. Восемь шагов должны выглядеть одним инструментом, а не восемью
# разными: одинаковый заголовок «шаг N / 8», одинаковое место у подсказок клавиш,
# одинаковое место у списка. Как только каждый шаг рисует себя сам, они расползаются, и
# человек на каждом экране заново ищет, где тут что.
#
# ВТОРОЕ: состояние мастера сохраняется после КАЖДОГО шага. «Выйти можно на любом» — это
# не удобство, а условие того, что мастер вообще проходят: настройка на живом проекте
# упирается в вопрос, ответ на который надо пойти посмотреть, и мастер, теряющий прогресс
# при выходе, после первого такого случая больше не запускают.

function Get-BcfWizardState {
    param([Parameter(Mandatory)][string]$Project)
    $f = Join-Path $Project '.bcf\init.json'
    if (-not (Test-Path $f)) { return $null }
    try { return Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch { return $null }
}

function Save-BcfWizardState {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)]$State)
    $d = Join-Path $Project '.bcf'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    ($State | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $d 'init.json') -Encoding UTF8
}

function Clear-BcfWizardState {
    param([Parameter(Mandatory)][string]$Project)
    Remove-Item -LiteralPath (Join-Path $Project '.bcf\init.json') -Force -ErrorAction SilentlyContinue
}

function Write-BcfStepHeader {
    param([int]$Step, [int]$Total, [Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('  ' + (Ink "шаг $Step / $Total" 'DarkGray') + ' ' + (Ink '—' 'DarkGray') + ' ' + (Ink $Title 'White'))
    Write-BcfRule 92
}

# Подсказки клавиш — всегда последней строкой экрана и всегда в одном виде. Клавиша
# выделена, её действие — фоном: глаз ищет клавишу, а не слово.
function Write-BcfKeyHints {
    param([Parameter(Mandatory)][object[]]$Pairs)
    $parts = foreach ($p in $Pairs) { (Ink $p[0] 'Cyan') + ' ' + (Ink $p[1] 'DarkGray') }
    Write-Host ''
    Write-Host ('  ' + ($parts -join (Ink ' · ' 'DarkGray')))
}

# Список с курсором. Возвращает индекс выбранного или -1, если человек вышел.
# Отдельная функция, потому что выбор из списка — единственное взаимодействие, которое
# повторяется на половине шагов, и три его копии разъедутся в поведении клавиш.
function Read-BcfListChoice {
    param(
        [Parameter(Mandatory)][object[]]$Items,     # @{ main=''; note=''; dim=$false }
        [int]$Selected = 0,
        [object[]]$Hints = @(),
        [scriptblock]$Header = $null,
        [hashtable]$ExtraKeys = @{}                 # 'E' -> действие; возврат строки завершает выбор
    )
    if (-not (Test-BcfInteractive)) { return $Selected }

    $frame = New-BcfFrame
    $idx = $Selected
    while ($true) {
        $L = New-Object 'System.Collections.Generic.List[object]'
        if ($Header) { foreach ($h in (& $Header)) { $L.Add($h) } }
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($i -eq $idx) { '▸' } else { ' ' }
            $c = if ($i -eq $idx) { 'Cyan' } elseif ($Items[$i].dim) { 'DarkGray' } else { '' }
            $L.Add(@{ t = ("  {0} {1}" -f $mark, $Items[$i].main); c = $c })
            if ($Items[$i].note) { $L.Add(@{ t = "      $($Items[$i].note)"; c = 'DarkGray' }) }
        }
        Write-BcfFrame -Frame $frame -Lines $L.ToArray()
        if ($Hints.Count) { Write-BcfKeyHints -Pairs $Hints }

        $k = Read-BcfKey
        if (-not $k) { return -1 }
        switch ($k.Key) {
            'UpArrow'   { if ($idx -gt 0) { $idx-- } }
            'DownArrow' { if ($idx -lt $Items.Count - 1) { $idx++ } }
            'Enter'     { return $idx }
            'Q'         { return -1 }
            'Escape'    { return -1 }
            default {
                $ch = ([string]$k.KeyChar).ToUpper()
                if ($ExtraKeys.ContainsKey($ch)) {
                    $r = & $ExtraKeys[$ch] $idx
                    if ($null -ne $r) { return $r }
                }
            }
        }
    }
}

# Недавние проекты из истории оболочки.
#
# Смысл не в удобстве набора: список показывает, ЧТО с этими каталогами прямо сейчас —
# репозиторий ли, чисто ли дерево, когда там работали. Именно грязное дерево и «не git»
# ломают первый же прогон, и увидеть это надо до выбора, а не после.
function Get-BcfRecentProjects {
    param([string]$Current = '', [int]$Limit = 6)

    $cands = New-Object 'System.Collections.Generic.List[string]'
    if ($Current) { [void]$cands.Add($Current) }

    # PSReadLine пишет историю в один файл; берём из неё каталоги, куда переходили.
    $hist = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (Test-Path $hist) {
        $lines = @(Get-Content -LiteralPath $hist -Tail 4000 -ErrorAction SilentlyContinue)
        [array]::Reverse($lines)
        foreach ($l in $lines) {
            if ($l -notmatch '^\s*(cd|Set-Location|sl)\s+(.+)$') { continue }
            $p = $Matches[2].Trim().Trim('"', "'")
            if ($p -match '^[-$]' -or $p -eq '..' -or $p -eq '~') { continue }
            try { if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue } } catch { continue }
            $full = (Resolve-Path -LiteralPath $p).Path
            if (-not $cands.Contains($full)) { [void]$cands.Add($full) }
            if ($cands.Count -ge $Limit * 3) { break }
        }
    }

    $out = @()
    foreach ($p in $cands) {
        if ($out.Count -ge $Limit) { break }
        $git = Get-BcfGitState -Root $p
        $last = $null
        try { $last = (Get-Item -LiteralPath $p).LastWriteTime } catch { }
        $out += [pscustomobject]@{
            Path = $p
            IsGit = $git.IsGit
            Branch = $git.Branch
            Dirty = @($git.Dirty).Count
            Last = $last
            HasBcf = (Test-Path (Join-Path $p '.bcf'))
        }
    }
    return $out
}

function Format-BcfAgo {
    param($When)
    if (-not $When) { return '' }
    $d = (Get-Date) - $When
    if ($d.TotalHours -lt 1) { return 'был только что' }
    if ($d.TotalHours -lt 24) { return ('был {0} ч назад' -f [int]$d.TotalHours) }
    if ($d.TotalDays -lt 30) { return ('был {0} дня' -f [int]$d.TotalDays) }
    return ('был {0} мес' -f [int]($d.TotalDays / 30))
}
