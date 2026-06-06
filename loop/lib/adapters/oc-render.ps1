# oc-render.ps1 — рендер JSON-событий opencode (общая библиотека).
#
# Источник истины по схеме событий (захвачена с opencode + <model>):
#   { type: <event-type>, timestamp, sessionID, part: { ... } }
#
# event-type:
#   step_start     — silent
#   step_finish    — part.reason, part.tokens.{total,input,output,cache.{write,read}}, part.cost
#   text           — part.text  (текст ответа модели)
#   reasoning      — part.text  (thinking)
#   tool_use       — part.tool, part.state.{input,output,metadata,title,status}
#
# Использование:
#   . (Join-Path $PSScriptRoot 'lib\adapters\oc-render.ps1')
#   Render-OcEvent $jsonLineAsObject [-Color]
#   Render-OcLine  $rawLineString    [-Color]
#
# В loop.ps1 — с -Color (Write-Host прямо в окно).
# В oc-pretty.ps1 — без -Color (Write-Output для file-capture в verify.ps1).

function _OcEmit {
    param([string]$text, [string]$fg, [switch]$Color)
    if ($Color) {
        if ($fg) { Write-Host $text -ForegroundColor $fg } else { Write-Host $text }
    } else {
        Write-Output $text
    }
}

function _OcTrunc {
    param($s, [int]$n)
    if ($null -eq $s) { return '' }
    $s = [string]$s
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n) + '…'
}

function _OcHasProp {
    param($obj, [string]$name)
    return ($null -ne $obj) -and ($obj.PSObject.Properties.Name -contains $name)
}

function _OcToolInputSummary {
    # NB: НЕ называть параметр $input — это автоматическая переменная PowerShell.
    param([string]$tool, $inp)
    if (-not $inp) { return '' }
    switch -Regex ($tool) {
        '^bash$' {
            $cmd  = if (_OcHasProp $inp 'command')     { [string]$inp.command }     else { '' }
            $desc = if (_OcHasProp $inp 'description') { [string]$inp.description } else { '' }
            if ($desc) { return "$desc  ::  $(_OcTrunc $cmd 100)" }
            return (_OcTrunc $cmd 140)
        }
        '^(read|edit|write|multiedit)$' {
            # opencode: camelCase `filePath`; некоторые провайдеры — `file_path` / `path`.
            if (_OcHasProp $inp 'filePath')  { return [string]$inp.filePath }
            if (_OcHasProp $inp 'file_path') { return [string]$inp.file_path }
            if (_OcHasProp $inp 'path')      { return [string]$inp.path }
        }
        '^(grep|glob)$' {
            $p = if (_OcHasProp $inp 'pattern') { [string]$inp.pattern } else { '' }
            $g = if (_OcHasProp $inp 'glob')    { " glob=$($inp.glob)" } else { '' }
            return "$p$g"
        }
        '^webfetch$' { if (_OcHasProp $inp 'url') { return [string]$inp.url } }
        '^task$'     { if (_OcHasProp $inp 'description') { return [string]$inp.description } }
        '^todowrite$' {
            if (_OcHasProp $inp 'todos') {
                $n = @($inp.todos).Count
                $cur = @($inp.todos | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1)
                if ($cur) { return "${n} todos, doing: $(_OcTrunc $cur[0].content 90)" }
                return "${n} todos"
            }
        }
    }
    return _OcTrunc (($inp | ConvertTo-Json -Compress -Depth 3)) 120
}

function _OcToolOutputSummary {
    param([string]$tool, $state)
    if (-not $state) { return '' }
    $out = if (_OcHasProp $state 'output') { [string]$state.output } else { '' }
    if ($tool -eq 'bash' -and (_OcHasProp $state 'metadata') -and (_OcHasProp $state.metadata 'exit')) {
        $exit = $state.metadata.exit
        $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | '
        return "exit=$exit  $(_OcTrunc $first 120)"
    }
    if ($tool -in 'read','grep','glob') {
        $lines = ($out -split "`r?`n").Count
        $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        return "${lines} lines  ::  $(_OcTrunc $first 100)"
    }
    if (-not $out) { return '' }
    $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    return _OcTrunc $first 140
}

function Render-OcEvent {
    param($ev, [switch]$Color)
    $t = if (_OcHasProp $ev 'type') { [string]$ev.type } else { '' }
    $part = if (_OcHasProp $ev 'part') { $ev.part } else { $null }
    switch ($t) {
        'step_start'  { return }   # silent
        'step_finish' { return }   # silent — boring marker; полезное идёт через tool_use/text/reasoning
        'text' {
            $tx = if ($part -and (_OcHasProp $part 'text')) { [string]$part.text } else { '' }
            if ($tx.Trim()) { _OcEmit $tx 'White' -Color:$Color }
            return
        }
        'reasoning' {
            $tx = ''
            if ($part -and (_OcHasProp $part 'text')) { $tx = [string]$part.text }
            elseif ($part -and (_OcHasProp $part 'content')) {
                if ($part.content -is [string]) { $tx = [string]$part.content }
                elseif ($part.content -is [array]) {
                    foreach ($c in $part.content) { if (_OcHasProp $c 'text') { $tx += [string]$c.text } }
                }
            }
            if ($tx.Trim()) {
                $brief = ($tx -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join '  '
                _OcEmit "  💭 $(_OcTrunc $brief 280)" 'DarkGray' -Color:$Color
            }
            return
        }
        'tool_use' {
            $tool   = if ($part -and (_OcHasProp $part 'tool')) { [string]$part.tool } else { '?' }
            $state  = if ($part -and (_OcHasProp $part 'state')) { $part.state } else { $null }
            $toolInp = if ($state -and (_OcHasProp $state 'input')) { $state.input } else { $null }
            $inSum  = _OcToolInputSummary $tool $toolInp
            _OcEmit "→ $tool  $inSum" 'Yellow' -Color:$Color
            if ($state -and (_OcHasProp $state 'status') -and ($state.status -eq 'completed')) {
                $outSum = _OcToolOutputSummary $tool $state
                if ($outSum) { _OcEmit "  ↳ $outSum" 'DarkGreen' -Color:$Color }
            }
            return
        }
        'error' {
            $msg = ''
            if ($part -and (_OcHasProp $part 'message')) { $msg = [string]$part.message }
            elseif (_OcHasProp $ev 'message') { $msg = [string]$ev.message }
            else { $msg = _OcTrunc (($ev | ConvertTo-Json -Compress -Depth 4)) 200 }
            _OcEmit "✗ $msg" 'Red' -Color:$Color
            return
        }
        default { _OcEmit "? type=$t" 'DarkGray' -Color:$Color }
    }
}

function Render-OcLine {
    # Принимает сырую строку (может быть не-JSON: INFO/WARN/ERROR/plain text).
    param([string]$line, [switch]$Color)
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $trimmed = $line.Trim()
    if ($trimmed[0] -ne '{' -and $trimmed[0] -ne '[') {
        if ($trimmed -match '^INFO\s')  { return }
        if ($trimmed -match '^WARN\s')  { _OcEmit $line 'Yellow' -Color:$Color; return }
        if ($trimmed -match '^ERROR\s') { _OcEmit $line 'Red'    -Color:$Color; return }
        _OcEmit $line $null -Color:$Color
        return
    }
    try {
        $ev = $line | ConvertFrom-Json -ErrorAction Stop
        Render-OcEvent $ev -Color:$Color
    } catch {
        _OcEmit $line 'DarkGray' -Color:$Color
    }
}
