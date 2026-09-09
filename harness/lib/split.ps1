# split.ps1 — запись подзадач, нарезанных из большой задачи под локальную модель.
#
# Подзадачи получают СВОИ верхнеуровневые номера (<PREFIX>-NN), а не <PREFIX>-NN.M:
# ночной прогон и очередь графа берут только верхний уровень (run-all.ps1, «Очередь»),
# и подзадача с точкой в номере никогда бы не поехала сама. Родитель помечается
# `Исполнитель: подзадачи` и уходит из очереди; задачи, у которых родитель стоял во
# «Входе», получают вместо него последнюю подзадачу цепочки. Так зависимости остаются
# файловыми и честными: никакой скрытой логики «родитель закрыт, когда закрыты дети».
#
# Формат элемента (то, что возвращает планировщик):
#   { title, summary, files: [..], input: ["<id предыдущей>"|"prev"|"-"], readiness: [..],
#     checks: [..], requirement: "ПТ4" }

function Get-BcfNextTaskNumber {
    param([Parameter(Mandatory)][string]$TasksDir, [string]$Prefix = 'TASK')
    $max = 0
    if (Test-Path -LiteralPath $TasksDir) {
        foreach ($f in Get-ChildItem -LiteralPath $TasksDir -Filter "$Prefix-*.md" -File -ErrorAction SilentlyContinue) {
            if ($f.BaseName -match "^$([regex]::Escape($Prefix))-(\d+)(?:[.-]|$)") {
                $n = [int]$Matches[1]
                if ($n -gt $max) { $max = $n }
            }
        }
    }
    $idx = Join-Path $TasksDir 'index.md'
    if (Test-Path -LiteralPath $idx) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $idx), "$([regex]::Escape($Prefix))-(\d+)")) {
            $n = [int]$m.Groups[1].Value
            if ($n -gt $max) { $max = $n }
        }
    }
    return $max + 1
}

function ConvertTo-BcfSlug {
    param([string]$Title)
    $map = @{ 'а'='a';'б'='b';'в'='v';'г'='g';'д'='d';'е'='e';'ё'='e';'ж'='zh';'з'='z';'и'='i';'й'='j';'к'='k';'л'='l';'м'='m';'н'='n';'о'='o';'п'='p';'р'='r';'с'='s';'т'='t';'у'='u';'ф'='f';'х'='h';'ц'='c';'ч'='ch';'ш'='sh';'щ'='sch';'ъ'='';'ы'='y';'ь'='';'э'='e';'ю'='yu';'я'='ya' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Title.ToLower().ToCharArray()) {
        $s = [string]$ch
        if ($map.ContainsKey($s)) { [void]$sb.Append($map[$s]) }
        elseif ($s -match '[a-z0-9]') { [void]$sb.Append($s) }
        else { [void]$sb.Append('-') }
    }
    $slug = ($sb.ToString() -replace '-+', '-').Trim('-')
    if (-not $slug) { $slug = 'task' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    return $slug
}

function Write-BcfSubtasks {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ParentId,
        [Parameter(Mandatory)]$Items,
        [string]$Prefix = 'TASK',
        [string]$TasksRel = 'tasks',
        [string]$Profile = 'local'
    )
    $tasksDir = Join-Path $Root ($TasksRel -replace '/', '\')
    $parentFile = Get-ChildItem -LiteralPath $tasksDir -Filter "$ParentId-*.md" -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.BaseName -match "^$([regex]::Escape($ParentId))-" } | Select-Object -First 1
    if (-not $parentFile) { throw "файл задачи $ParentId не найден в $TasksRel/" }
    $parentBody = Get-Content -Raw -LiteralPath $parentFile.FullName
    $cls = if ($parentBody -match '(?m)^Класс:\s*(\S+)') { $Matches[1] } else { 'CORE' }
    $req = if ($parentBody -match '(?m)^Требование:\s*(.+)$') { $Matches[1].Trim() } else { '' }
    $epic = if ($parentBody -match '(?m)^Эпик:\s*(.+)$') { $Matches[1].Trim() } else { '' }
    $parentInputs = @()
    $mIn = [regex]::Match($parentBody, '(?ms)^##\s*Вход\s*$(.*?)(?=^##\s|\z)')
    if ($mIn.Success) { $parentInputs = @([regex]::Matches($mIn.Groups[1].Value, "$([regex]::Escape($Prefix))-\d+") | ForEach-Object { $_.Value } | Select-Object -Unique) }

    $items = @($Items)
    if ($items.Count -eq 0) { throw 'планировщик не дал ни одной подзадачи' }
    $num = Get-BcfNextTaskNumber -TasksDir $tasksDir -Prefix $Prefix
    $created = @()
    $prevId = ''
    $checksPath = Join-Path $Root 'config\checks.json'
    $checks = $null
    if (Test-Path -LiteralPath $checksPath) { try { $checks = Get-Content -Raw -LiteralPath $checksPath | ConvertFrom-Json -AsHashtable } catch { $checks = $null } }

    foreach ($it in $items) {
        $id = "$Prefix-$num"; $num++
        $title = [string]$it.title
        $slug = ConvertTo-BcfSlug $title
        $files = @($it.files | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $ready = @($it.readiness | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $cmds  = @($it.checks | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $reqLine = if ($it.PSObject.Properties['requirement'] -and $it.requirement) { [string]$it.requirement } else { $req }
        $inputs = @()
        $rawIn = @($it.input | ForEach-Object { [string]$_ } | Where-Object { $_ })
        foreach ($x in $rawIn) {
            if ($x -eq 'prev') { if ($prevId) { $inputs += $prevId } }
            elseif ($x -match "^$([regex]::Escape($Prefix))-\d+$") { $inputs += $x }
        }
        if ($rawIn.Count -eq 0 -and $prevId) { $inputs += $prevId }
        if (-not $prevId) { $inputs += $parentInputs }
        $inputs = @($inputs | Select-Object -Unique)
        $inputText = if ($inputs.Count) { ($inputs | ForEach-Object { "- $_" }) -join "`n" } else { '—' }
        $readyText = ''
        for ($k = 0; $k -lt $ready.Count; $k++) { $readyText += "$($k + 1). $($ready[$k])`n" }
        $body = @"
# $id — $title

Исполнитель: фабрика
Класс: $cls
Требование: $reqLine
$(if ($epic) { "Эпик: $epic`n" })Родитель: $ParentId

$([string]$it.summary)

Подзадача ${ParentId} под профиль ${Profile}: один-два файла, одна проверка, один шаг за итерацию.
Смысл и требования целиком в файле родителя.

## Файлы

$(($files | ForEach-Object { "- ``$_``" }) -join "`n")

## Вход

$inputText

## Готовность

$readyText
## Проверки

``````
$($cmds -join "`n")
``````
"@
        $path = Join-Path $tasksDir "$id-$slug.md"
        Set-Content -LiteralPath $path -Value $body -Encoding UTF8
        try { Add-BcfTaskIndexEntry -Root $Root -TaskId $id -Title $title -RelPath "$TasksRel/$id-$slug.md" | Out-Null } catch { }
        if ($checks -is [hashtable] -and $cmds.Count) { $checks[$id] = @($cmds) }
        $created += [pscustomobject]@{ Id = $id; Title = $title; Path = $path; Files = $files }
        $prevId = $id
    }
    if ($checks -is [hashtable]) {
        Set-Content -LiteralPath $checksPath -Value ($checks | ConvertTo-Json -Depth 6) -Encoding UTF8
    }

    # Родитель уходит из очереди, зависимые задачи переводятся на последнюю подзадачу.
    $ids = @($created | ForEach-Object { $_.Id })
    $lastId = $ids[-1]
    $pb = $parentBody
    if ($pb -match '(?m)^Исполнитель:.*$') { $pb = [regex]::Replace($pb, '(?m)^Исполнитель:.*$', "Исполнитель: подзадачи $($ids -join ', ')", 1) }
    else { $pb = [regex]::Replace($pb, '(?m)^(# [^\r\n]+\r?\n)', "`$1`nИсполнитель: подзадачи $($ids -join ', ')`n", 1) }
    if ($pb -notmatch '(?m)^Подзадачи:') {
        $pb = [regex]::Replace($pb, '(?m)^(Исполнитель:[^\r\n]*\r?\n)', "`$1Подзадачи: $($ids -join ', ')`n", 1)
    }
    Set-Content -LiteralPath $parentFile.FullName -Value $pb -Encoding UTF8

    $rewired = @()
    foreach ($f in Get-ChildItem -LiteralPath $tasksDir -Filter "$Prefix-*.md" -File -ErrorAction SilentlyContinue) {
        if ($ids -contains (($f.BaseName -split '-')[0..1] -join '-')) { continue }
        if ($f.FullName -eq $parentFile.FullName) { continue }
        $t = Get-Content -Raw -LiteralPath $f.FullName
        $m = [regex]::Match($t, '(?ms)^##\s*Вход\s*$(.*?)(?=^##\s|\z)')
        if (-not $m.Success) { continue }
        $sec = $m.Groups[1].Value
        if ($sec -notmatch "(?<![\w.])$([regex]::Escape($ParentId))(?![\w.])") { continue }
        $newSec = [regex]::Replace($sec, "(?<![\w.])$([regex]::Escape($ParentId))(?![\w.])", $lastId)
        $t2 = $t.Substring(0, $m.Groups[1].Index) + $newSec + $t.Substring($m.Groups[1].Index + $m.Groups[1].Length)
        Set-Content -LiteralPath $f.FullName -Value $t2 -Encoding UTF8
        $rewired += (($f.BaseName -split '-')[0..1] -join '-')
    }
    return [pscustomobject]@{ Created = $created; Parent = $ParentId; Rewired = $rewired; Last = $lastId }
}
