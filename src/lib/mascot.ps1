# mascot.ps1 — маскот фабрики в терминале.
#
# В макете он растровый. В консоли растра нет, поэтому рисуем полублоками: символ ▀ даёт
# ДВА пикселя в одной ячейке — цвет символа сверху, цвет фона снизу. Так картинка выходит
# вдвое выше по вертикали и перестаёт быть «лесенкой из ASCII».
#
# Палитра — 256-цветная, а не 24-битная, СОЗНАТЕЛЬНО: truecolor поддержан не везде, и на
# терминале без него в вывод летят escape-последовательности вместо картинки. 256 цветов
# понимает практически всё, где вообще есть цвет.
#
# Зачем он нужен. Не для красоты: по лицу окно узнают, не читая, а выражение повторяет
# вердикт карточки — так состояние видно боковым зрением ещё до того, как прочитан текст.

$script:BcfPix = @{
    '.' = $null      # прозрачный — фон терминала
    'H' = 214        # шляпа
    '#' = 172        # поле шляпы, тень
    'o' = 208        # ухо снаружи
    'p' = 217        # ухо внутри
    'F' = 223        # мех
    'L' = 230        # мех, светлый
    'E' = 235        # глаз
    'W' = 231        # белое: морда, воротник
    'N' = 210        # нос
    'B' = 33         # рубашка
    '+' = 26         # рубашка, тень
}

# 14 × 16 пикселей. Ряды идут парами: каждая пара — одна строка вывода.
$script:BcfMascotArt = @(
    '..oo......oo..',
    '.opo......opo.',
    '.HHHHHHHHHHHH.',
    'HHHHHHHHHHHHHH',
    '##############',
    '.FFFFFFFFFFFF.',
    '.FFFFFFFFFFFF.',
    '.FEEFFFFFFEEF.',
    '.FEEFFFFFFEEF.',
    '.FFFFWWWWFFFF.',
    '.FFFFWNNWFFFF.',
    '..FFFWWWWFFF..',
    '...FFFFFFFF...',
    '..BBBWWWWBBB..',
    '.BBBBBBBBBBBB.',
    '.+BBBBBBBBBB+.'
)

# Выражение меняем не рисованием второго лица, а точечной подменой пикселей: так
# гарантированно совпадают силуэт и позиция, и «настроение» не превращается в другого
# персонажа.
$script:BcfMoodPatch = @{
    ok   = @{}
    warn = @{ 9 = '.FFFFWWWWFFFF.'; 10 = '.FFFFWNNWFFFF.' }
    bad  = @{ 7 = '.FFEFFFFFFEFF.'; 8 = '.FEFFFFFFFFEF.' }
}

function Test-BcfMascotSupported {
    if (-not (Test-BcfColor)) { return $false }
    # Дальше можно было бы гадать по TERM/WT_SESSION, но гадание тут вредно: маскот —
    # украшение, а не сообщение, и лучше показать его лишний раз, чем спрятать нужное.
    return $true
}

function Get-BcfMascotLines {
    param([ValidateSet('ok', 'warn', 'bad')][string]$Mood = 'ok')

    $art = @($script:BcfMascotArt)
    foreach ($k in $script:BcfMoodPatch[$Mood].Keys) { $art[[int]$k] = $script:BcfMoodPatch[$Mood][$k] }

    $w = ($art | Measure-Object -Property Length -Maximum).Maximum
    $out = @()
    if (-not (Test-BcfMascotSupported)) {
        # Без цвета полублоки превращаются в кашу — отдаём пустые строки нужной высоты,
        # чтобы разметка шапки не поехала.
        for ($r = 0; $r -lt [math]::Ceiling($art.Count / 2); $r++) { $out += (' ' * $w) }
        return $out
    }

    for ($r = 0; $r -lt $art.Count; $r += 2) {
        $top = $art[$r].PadRight($w)
        $bot = if ($r + 1 -lt $art.Count) { $art[$r + 1].PadRight($w) } else { ('.' * $w) }
        $sb = [System.Text.StringBuilder]::new()
        for ($c = 0; $c -lt $w; $c++) {
            $tp = $script:BcfPix[[string]$top[$c]]
            $bp = $script:BcfPix[[string]$bot[$c]]
            if ($null -eq $tp -and $null -eq $bp) { [void]$sb.Append(' '); continue }
            if ($null -eq $bp) { [void]$sb.Append("`e[38;5;${tp}m▀`e[0m"); continue }
            if ($null -eq $tp) { [void]$sb.Append("`e[38;5;${bp}m▄`e[0m"); continue }
            [void]$sb.Append("`e[38;5;${tp}m`e[48;5;${bp}m▀`e[0m")
        }
        $out += $sb.ToString()
    }
    return $out
}

# Шапка «маскот слева, текст справа». Текст выравнивается по высоте картинки, а не
# наоборот: строки текста бывают разной длины, а картинка — фиксированной.
function Write-BcfMascotHeader {
    param(
        [ValidateSet('ok', 'warn', 'bad')][string]$Mood = 'ok',
        [Parameter(Mandatory)][object[]]$Text
    )
    $face = @(Get-BcfMascotLines -Mood $Mood)
    $rows = [math]::Max($face.Count, $Text.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        $l = if ($i -lt $face.Count) { $face[$i] } else { ' ' * 14 }
        $t = ''
        if ($i -lt $Text.Count) {
            $t = if ($Text[$i] -is [string]) { $Text[$i] } else { Ink ([string]$Text[$i].t) ([string]$Text[$i].c) }
        }
        Write-Host ('  ' + $l + '   ' + $t)
    }
}
