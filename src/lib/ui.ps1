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

# --- Символы ----------------------------------------------------------------------------
#
# ✓ ✗ ⚠ ▸ ▀ — это не «просто символы»: в Consolas половины из них нет, и в старом conhost
# вместо значка статуса рисуется пустой квадрат. Значок, который не отрисовался, хуже
# отсутствующего: строка «□ память недоступна» читается как мусор, а не как ошибка.
# Поэтому набор переключаемый: BCF_ASCII=1 (или --ascii) даёт заведомо рисуемые аналоги.
$script:BcfAscii = [bool]$env:BCF_ASCII
function Set-BcfAscii { param([bool]$Value) $script:BcfAscii = $Value }

$script:BcfGlyphs = @{
    ok      = @{ u = '✓'; a = '+' }
    fail    = @{ u = '✗'; a = 'x' }
    warn    = @{ u = '⚠'; a = '!' }
    dim     = @{ u = '·'; a = '-' }
    cursor  = @{ u = '▸'; a = '>' }
    dot     = @{ u = '●'; a = '*' }
    boxOn   = @{ u = '×'; a = 'x' }
    rule    = @{ u = '─'; a = '-' }
    sep     = @{ u = '·'; a = '|' }
    down    = @{ u = '↓'; a = 'v' }
    updown  = @{ u = '↑↓'; a = 'up/dn' }
    arrow   = @{ u = '→'; a = '->' }
}

function Sym {
    param([Parameter(Mandatory)][string]$Name)
    $g = $script:BcfGlyphs[$Name]
    if (-not $g) { return $Name }
    if ($script:BcfAscii) { return $g.a }
    return $g.u
}

# Обрезка по ширине окна. Строка, вылезшая за край, переносится терминалом и ломает
# ВЕСЬ последующий кадр: перерисовка считает строки, а их стало больше, чем она думает.
# Длительность прогона. Отдельная функция, потому что '{0:hh\:mm\:ss}' МОЛЧА теряет дни:
# оборванный прогон недельной давности печатался как «05:12:33», то есть выглядел коротким.
# Ошибка на порядок в единственном числе, по которому судят о прогоне.
function Format-BcfDuration {
    param($Span)
    if ($null -eq $Span) { return '  --  ' }
    if ($Span -isnot [timespan]) { $Span = [timespan]$Span }

    # Знак несём сами: пользовательские форматы TimeSpan в .NET его НЕ печатают, и
    # отрицательный интервал выходил положительным — «-00:05:30» превращалось в «05:30».
    # Отрицательная длительность означает, что времена разъехались (например, Started
    # уехал вперёд Finished), и молчать об этом нельзя: беззнаковый вывод выглядит
    # нормальным числом, по которому делают выводы.
    $sign = if ($Span.Ticks -lt 0) { '-' } else { '' }
    $a = if ($Span.Ticks -lt 0) { $Span.Negate() } else { $Span }

    # Дни ОТБРАСЫВАЕМ, а не округляем: [int] в PowerShell округляет к ближайшему, и любой
    # интервал с остатком ≥ 12 часов получал лишний день — «1д 21:36» печаталось как
    # «2д 21:36», прямо противореча часам рядом.
    if ($a.TotalDays -ge 1) { return ('{0}{1}д {2:00}:{3:00}' -f $sign, [int][math]::Floor($a.TotalDays), $a.Hours, $a.Minutes) }
    if ($a.TotalHours -ge 1) { return ($sign + ('{0:hh\:mm\:ss}' -f $a)) }
    return ($sign + ('{0:mm\:ss}' -f $a))
}

function Fit-BcfWidth {
    param([string]$Text, [int]$Reserve = 2)
    $w = 100
    try { $cw = [Console]::WindowWidth; if ($cw -gt 20) { $w = $cw } } catch { }
    $limit = $w - $Reserve
    # Длину считаем по ВИДИМЫМ символам: ANSI-коды ширины не имеют, и обрезка по сырой
    # длине резала бы цветные строки втрое раньше нужного.
    $plain = [regex]::Replace($Text, "`e\[[0-9;]*m", '')
    if ($plain.Length -le $limit) { return $Text }
    if ($Text -eq $plain) { return $plain.Substring(0, [math]::Max(0, $limit - 1)) + (Sym 'dim') }
    # В цветной строке режем по видимым символам, сохраняя коды.
    $sb = [System.Text.StringBuilder]::new()
    $vis = 0; $i = 0
    while ($i -lt $Text.Length -and $vis -lt ($limit - 1)) {
        $m = [regex]::Match($Text.Substring($i), "^`e\[[0-9;]*m")
        if ($m.Success) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
        [void]$sb.Append($Text[$i]); $i++; $vis++
    }
    [void]$sb.Append((Sym 'dim')); [void]$sb.Append("`e[0m")
    return $sb.ToString()
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
    if ($Color -and (Test-BcfColor)) { Write-Host (Fit-BcfWidth (Ink $Text $Color)) }
    else { Write-Host (Fit-BcfWidth $Text) }
}

function Write-BcfTitle {
    param([Parameter(Mandatory)][string]$Text, [string]$Sub = '')
    Write-Host ''
    Write-BcfLine "  $Text" 'Cyan'
    if ($Sub) { Write-BcfLine "  $Sub" 'DarkGray' }
    Write-Host ''
}

function Write-BcfRule {
    param([int]$Width = 78)
    $w = $Width
    try { $cw = [Console]::WindowWidth; if ($cw -gt 20 -and $w -gt $cw - 4) { $w = $cw - 4 } } catch { }
    Write-BcfLine ('  ' + ((Sym 'rule') * $w)) 'DarkGray'
}

function Write-BcfOk    { param([string]$T) Write-Host (Fit-BcfWidth ('  ' + (Ink (Sym 'ok')   'Green')  + ' ' + (Ink $T 'Green'))) }
function Write-BcfWarn  { param([string]$T) Write-Host (Fit-BcfWidth ('  ' + (Ink (Sym 'warn') 'Yellow') + ' ' + (Ink $T 'Yellow'))) }
function Write-BcfFail  { param([string]$T) Write-Host (Fit-BcfWidth ('  ' + (Ink (Sym 'fail') 'Red')    + ' ' + (Ink $T 'Red'))) }
function Write-BcfDim   { param([string]$T) Write-Host (Fit-BcfWidth ('  ' + (Ink ((Sym 'dim') + ' ' + $T) 'DarkGray'))) }
# Пояснение под строкой. ПЕРЕНОСИТСЯ, а не обрезается: в пояснении лежит последствие —
# то, ради чего блокер вообще напечатан. Обрезка по ширине окна съедала именно хвост,
# и в узком терминале от «без репозитория не восстановить работу» оставалось «без репо·».
# Строка превращалась из объяснения в намёк ровно там, где объяснение и нужно.
function Write-BcfNote {
    param([string]$T)
    $w = 100
    try { $cw = [Console]::WindowWidth; if ($cw -gt 30) { $w = $cw } } catch { }
    $limit = $w - 6
    if ($T.Length -le $limit) { Write-BcfLine "    $T" 'DarkGray'; return }
    $line = ''
    foreach ($word in ($T -split ' ')) {
        if ($line -and ($line.Length + 1 + $word.Length) -gt $limit) {
            Write-BcfLine "    $line" 'DarkGray'
            $line = $word
        } else {
            $line = if ($line) { "$line $word" } else { $word }
        }
    }
    if ($line) { Write-BcfLine "    $line" 'DarkGray' }
}

# Источник вывода. Печатается рядом со значением, а не в легенде внизу: легенду не
# читают, а решение принимают по строке.
# «1 задач» и «2 задача» — это не мелочь стиля: экран, который не умеет согласовать
# число со словом, читается как черновик, и доверия к его числам меньше. Формы задаются
# вызывающим: именительный (1), родительный единственного (2–4), родительный
# множественного (5–20).
function Format-BcfCount {
    param([int]$N, [Parameter(Mandatory)][string[]]$Forms)
    $n = [math]::Abs($N)
    $form = if ($n % 100 -ge 11 -and $n % 100 -le 14) { $Forms[2] }
            elseif ($n % 10 -eq 1) { $Forms[0] }
            elseif ($n % 10 -ge 2 -and $n % 10 -le 4) { $Forms[1] }
            else { $Forms[2] }
    return "$N $form"
}

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
    if (-not $Source) { Write-Host (Fit-BcfWidth $line); return }
    $tag = Get-BcfSourceTag $Source
    # Метку источника режем последней: она короткая и важнее хвоста значения.
    Write-Host (Fit-BcfWidth ($line) 16) -NoNewline
    Write-Host ('   ' + (Ink $tag.text $tag.color))
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
