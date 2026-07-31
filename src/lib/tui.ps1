# tui.ps1 — клавиатурный выбор запуска, перерисовываемый на месте.
#
# ПОЧЕМУ НЕ ПОЛНОЭКРАННЫЙ РЕЖИМ. Выбран вариант «лента + прибитая доска»: scrollback
# остаётся живым, а перерисовывается только кадр внизу. Alt-screen прячет всё, что было
# до запуска, — а именно там лежит вывод предыдущей команды, по которому и принимается
# решение, что запускать.
#
# ГЛАВНОЕ ТРЕБОВАНИЕ: без консоли эта штука обязана НЕ ломаться. Пайп, CI, ночной
# прогон по расписанию — там ReadKey кидает исключение, и интерактивный экран должен
# честно уступить место неинтерактивному выводу, а не уронить команду.

function Test-BcfInteractive {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        # У консоли обязана быть ширина: у «не-консоли» обращение к ней бросает.
        $null = [Console]::WindowWidth
        return $true
    } catch { return $false }
}

function Get-BcfConsoleWidth {
    try { $w = [Console]::WindowWidth; if ($w -gt 20) { return $w } } catch { }
    return 100
}

# Один кадр = список строк. Перерисовка возвращает курсор на начало кадра и переписывает
# строки, добивая пробелами до ширины: без добивки от прошлого кадра остаются хвосты,
# и экран выглядит как мусор поверх мусора.
function New-BcfFrame {
    $pos = $null
    try { $pos = $Host.UI.RawUI.CursorPosition } catch { }
    return [pscustomobject]@{ Start = $pos; Lines = 0 }
}

function Write-BcfFrame {
    param([Parameter(Mandatory)]$Frame, [Parameter(Mandatory)][object[]]$Lines)

    $w = Get-BcfConsoleWidth
    if ($Frame.Start) {
        try { $Host.UI.RawUI.CursorPosition = $Frame.Start } catch { }
    }
    foreach ($l in $Lines) {
        $text = if ($l -is [string]) { $l } else { [string]$l.t }
        $color = if ($l -is [string]) { '' } else { [string]$l.c }
        if ($text.Length -gt ($w - 1)) { $text = $text.Substring(0, $w - 2) + '…' }
        $padded = $text.PadRight([math]::Max(0, $w - 1))
        if ($color) { Write-Host $padded -ForegroundColor $color } else { Write-Host $padded }
    }
    # Кадр может стать короче предыдущего — хвост надо затереть, иначе на экране
    # останутся строки, которых уже нет в состоянии.
    for ($i = $Lines.Count; $i -lt $Frame.Lines; $i++) { Write-Host (' ' * ($w - 1)) }
    $Frame.Lines = [math]::Max($Lines.Count, $Frame.Lines)
}

function Read-BcfKey {
    try { return [Console]::ReadKey($true) } catch { return $null }
}
