# ui.ps1 — вывод CLI.
#
# Правило вывода, из-за которого этот файл вообще существует: у каждого утверждения
# должен быть виден ИСТОЧНИК. «Проверено» (запускали и смотрели) и «догадка» (вывели из
# структуры проекта) печатаются по-разному, потому что подписываться под ними человек
# будет по-разному. Второе правило: опасное место называется ПОСЛЕДСТВИЕМ, а не
# статусом — «затянет чужие правки в задачу», а не «дерево грязное».

# --- Цвет ------------------------------------------------------------------------------
#
# Цвет здесь несёт СМЫСЛ, а не украшает: зелёное — то, что проверено и работает; жёлтое —
# оговорка; красное — то, из-за чего прогон встанет; серое — фон, который читать не надо.
# Экран, где всё одного цвета, заставляет читать всё подряд, и человек перестаёт читать
# вообще — а именно в этих строках лежат предупреждения, ради которых команда написана.
#
# Пишем ANSI, а не Write-Host -ForegroundColor. Разница не косметическая: атрибуты консоли
# теряются при ЛЮБОМ перенаправлении — в файл, в пайп, в панель IDE, — и вывод, который в
# окне выглядит осмысленным, в логе прогона оказывается серой простынёй. ANSI переживает
# перенаправление, а выключается явно (NO_COLOR/BCF_NO_COLOR — общепринятый признак).

$script:BcfNoColor = [bool]($env:BCF_NO_COLOR -or $env:NO_COLOR)

# Палитра — стандартные 16 цветов терминала, а не RGB: так она подчиняется теме
# пользователя. Тёмная тема, светлая, высококонтрастная — цвет остаётся читаемым.
$script:BcfInk = @{
    ''        = ''
    'reset'   = "`e[0m"
    'bold'    = "`e[1m"
    'Red'     = "`e[91m"
    'Green'   = "`e[92m"
    'Yellow'  = "`e[93m"
    'Blue'    = "`e[94m"
    'Magenta' = "`e[95m"
    'Cyan'    = "`e[96m"
    'White'   = "`e[97m"
    'Gray'    = "`e[37m"
    'DarkGray'= "`e[90m"
    'DarkCyan'= "`e[36m"
    'DarkYellow' = "`e[33m"
}

function Test-BcfColor {
    if ($script:BcfNoColor) { return $false }
    return $true
}

# Раскрасить КУСОК строки. Нужно именно так: строка «TASK-02 готова crates/core/src.rs»
# состоит из трёх разных по важности вещей, и красить её целиком одним цветом — значит
# не сказать ничего. Текст передаётся уже дополненным до нужной ширины: ANSI-коды не
# имеют ширины, и padding после раскраски съезжает.
function Ink {
    param([string]$Text, [string]$Color = '')
    if (-not $Color -or -not (Test-BcfColor) -or -not $script:BcfInk.ContainsKey($Color)) { return $Text }
    return $script:BcfInk[$Color] + $Text + $script:BcfInk['reset']
}

function Write-BcfLine {
    param([string]$Text = '', [string]$Color = '')
    if ($Color -and (Test-BcfColor)) { Write-Host (Ink $Text $Color) }
    else { Write-Host $Text }
}

function Write-BcfTitle {
    param([Parameter(Mandatory)][string]$Text, [string]$Sub = '')
    Write-Host ''
    Write-BcfLine "  $Text" 'Cyan'
    if ($Sub) { Write-BcfLine "  $Sub" 'DarkGray' }
    Write-Host ''
}

function Write-BcfRule { param([int]$Width = 78) Write-BcfLine ('  ' + ('─' * $Width)) 'DarkGray' }

function Write-BcfOk    { param([string]$T) Write-Host ('  ' + (Ink '✓' 'Green')  + ' ' + (Ink $T 'Green')) }
function Write-BcfWarn  { param([string]$T) Write-Host ('  ' + (Ink '⚠' 'Yellow') + ' ' + (Ink $T 'Yellow')) }
function Write-BcfFail  { param([string]$T) Write-Host ('  ' + (Ink '✗' 'Red')    + ' ' + (Ink $T 'Red')) }
function Write-BcfDim   { param([string]$T) Write-Host ('  ' + (Ink ('· ' + $T) 'DarkGray')) }
function Write-BcfNote  { param([string]$T) Write-BcfLine "    $T" 'DarkGray' }

# Источник вывода. Печатается рядом со значением, а не в легенде внизу: легенду не
# читают, а решение принимают по строке.
function Get-BcfSourceTag {
    param([ValidateSet('проверено', 'уверенно', 'догадка')][string]$Source)
    switch ($Source) {
        'проверено' { return @{ text = 'проверено'; color = 'Green' } }
        'уверенно'  { return @{ text = 'уверенно';  color = 'DarkCyan' } }
        default     { return @{ text = 'догадка';   color = 'Yellow' } }
    }
}

function Write-BcfField {
    param([string]$Name, [string]$Value, [string]$Source = '', [int]$NameWidth = 16, [string]$ValueColor = 'White')
    $line = '  ' + (Ink ("{0,-$NameWidth}" -f $Name) 'DarkGray') + ' ' + (Ink $Value $ValueColor)
    if (-not $Source) { Write-Host $line; return }
    $tag = Get-BcfSourceTag $Source
    Write-Host ($line + '   ' + (Ink $tag.text $tag.color))
}

# Таблица без выравнивания по содержимому — колонки заданы заранее. Автоширина ломается
# ровно тогда, когда нужна больше всего: одна длинная строка сдвигает всю таблицу.
#
# Строки собираются через New-BcfRows/Add-BcfRow, а не в обычный массив: `$rows += ,@(...)`
# в PowerShell разворачивает вложенный массив, и таблица получает плоский список ячеек
# вместо строк — падая на форматировании там, где ошибка уже не видна.
# Запятая обязательна: PowerShell разворачивает перечисляемое на выходе функции, и
# пустой список превращается в $null у вызывающего — то есть таблица падает ровно на
# пустых данных, где ошибку заметить труднее всего.
function New-BcfRows { return , (New-Object 'System.Collections.Generic.List[object]') }

function Add-BcfRow {
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][object[]]$Cells)
    $Rows.Add($Cells) | Out-Null
}

function Write-BcfTable {
    param([string[]]$Headers, [int[]]$Widths, $Rows, [string[]]$RowColors = @())
    $fmt = ($Widths | ForEach-Object -Begin { $i = 0 } -Process { $s = "{$i,-$_}"; $i++; $s }) -join ' '
    Write-BcfLine ('  ' + ($fmt -f $Headers)) 'DarkGray'
    Write-BcfLine ('  ' + ('─' * (($Widths | Measure-Object -Sum).Sum + $Widths.Count - 1))) 'DarkGray'
    # Count берём с самого объекта, а не через @($Rows): обёртка массива в PowerShell
    # пытается сконвертировать вложенные массивы и падает на списке строк-массивов.
    $n = if ($null -eq $Rows) { 0 } elseif ($Rows.PSObject.Properties['Count']) { [int]$Rows.Count } else { 1 }
    for ($r = 0; $r -lt $n; $r++) {
        $c = if ($r -lt $RowColors.Count -and $RowColors[$r]) { $RowColors[$r] } else { '' }
        Write-BcfLine ('  ' + ($fmt -f @($Rows[$r]))) $c
    }
}

# Список ручной работы. Разделён на «без этого не поедет» и «можно позже» намеренно:
# один общий список из восьми пунктов человек не разбирает, он его закрывает.
function Write-BcfManualActions {
    param([object[]]$Blocking = @(), [object[]]$Later = @())
    if ($Blocking.Count) {
        Write-Host ''
        Write-BcfLine "  ⚠ БЕЗ ЭТОГО ПРОГОН НЕ ПОЕДЕТ   $($Blocking.Count)" 'Red'
        $i = 0
        foreach ($b in $Blocking) {
            $i++
            Write-BcfLine "  $i  $($b.what)" 'Red'
            if ($b.why) { Write-BcfNote $b.why }
            if ($b.fix) { Write-BcfLine "     $($b.fix)" 'White' }
        }
    }
    if ($Later.Count) {
        Write-Host ''
        Write-BcfLine "  · МОЖНО ПОЗЖЕ, НО ЗАПОМНИ   $($Later.Count)" 'DarkGray'
        foreach ($l in $Later) { Write-BcfDim $l }
    }
}

# --- Ввод ---------------------------------------------------------------------------
#
# Все запросы проходят через эти две функции, чтобы неинтерактивный режим (--yes, CI,
# ночной прогон) вёл себя предсказуемо: он не «отвечает за человека», а берёт дефолт и
# ГОВОРИТ, что взял. Молчаливый дефолт в мастере настройки — способ получить конфиг,
# которого никто не выбирал.
$script:BcfAssumeYes = $false
function Set-BcfAssumeYes { param([bool]$Value) $script:BcfAssumeYes = $Value }
function Get-BcfAssumeYes { return $script:BcfAssumeYes }

function Read-BcfChoice {
    param([string]$Question, [string[]]$Options, [int]$Default = 0)
    if ($script:BcfAssumeYes) {
        Write-BcfDim "$Question → $($Options[$Default]) (по умолчанию, режим без вопросов)"
        return $Default
    }
    Write-Host ''
    Write-BcfLine "  $Question" 'White'
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = if ($i -eq $Default) { '▸' } else { ' ' }
        Write-Host ("    $mark [{0}] {1}" -f ($i + 1), $Options[$i])
    }
    $ans = Read-Host "  выбор [1-$($Options.Count)], enter = $($Default + 1)"
    if (-not $ans) { return $Default }
    $n = 0
    if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n - 1 }
    return $Default
}

function Read-BcfConfirm {
    param([string]$Question, [bool]$Default = $true)
    if ($script:BcfAssumeYes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "  $Question $hint"
    if (-not $ans) { return $Default }
    return ($ans -match '^(y|yes|д|да)$')
}

function Read-BcfText {
    param([string]$Question, [string]$Default = '')
    if ($script:BcfAssumeYes) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $ans = Read-Host "  $Question$suffix"
    if (-not $ans) { return $Default }
    return $ans.Trim()
}
