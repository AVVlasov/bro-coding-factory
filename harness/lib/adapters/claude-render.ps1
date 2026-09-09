# claude-render.ps1 — разбор потока `claude -p --output-format stream-json` для цикла:
# одна строка события → строка журнала и «что делает агент» для heartbeat.
#
# События (Claude Code stream-json): system (init, hook_*), assistant (message.content:
# text | tool_use {name, input}), user (tool_result), result (result, is_error, usage,
# total_cost_usd). Разбор нарочно терпимый: незнакомое событие не роняет цикл.

function Get-ClaudeActivity {
    param($ev)
    $t = [string]$ev.type
    if ($t -eq 'assistant') {
        foreach ($c in @($ev.message.content)) {
            $ct = [string]$c.type
            if ($ct -eq 'tool_use') {
                $inp = $c.input
                $hint = ''
                if ($inp) {
                    if ($inp.PSObject.Properties['description'] -and $inp.description) { $hint = [string]$inp.description }
                    elseif ($inp.PSObject.Properties['file_path'] -and $inp.file_path) { $hint = [string]$inp.file_path }
                    elseif ($inp.PSObject.Properties['pattern'] -and $inp.pattern) { $hint = [string]$inp.pattern }
                    elseif ($inp.PSObject.Properties['command'] -and $inp.command) { $hint = [string]$inp.command }
                }
                return "$([string]$c.name) — $hint"
            }
            if ($ct -eq 'text') { return 'пишет ответ' }
            if ($ct -eq 'thinking') { return 'думает (reasoning)' }
        }
        return ''
    }
    if ($t -eq 'user') { return 'получил результат инструмента' }
    if ($t -eq 'result') { return 'итог' }
    return ''
}

function Render-ClaudeLine {
    param([string]$line, [switch]$Color)
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $ev = $null
    try { $ev = $line | ConvertFrom-Json -ErrorAction Stop } catch { return }
    $t = [string]$ev.type
    $ts = Get-Date -Format 'HH:mm:ss'
    switch ($t) {
        'system' {
            if ([string]$ev.subtype -eq 'init') { Write-Host "[$ts] claude: сессия $([string]$ev.session_id), модель $([string]$ev.model)" -ForegroundColor DarkGray }
        }
        'assistant' {
            foreach ($c in @($ev.message.content)) {
                $ct = [string]$c.type
                if ($ct -eq 'text') {
                    $txt = [string]$c.text
                    if ($txt.Length -gt 300) { $txt = $txt.Substring(0, 300) + '…' }
                    Write-Host "  💬 $txt" -ForegroundColor White
                } elseif ($ct -eq 'tool_use') {
                    $a = Get-ClaudeActivity $ev
                    Write-Host "→ $a" -ForegroundColor Cyan
                } elseif ($ct -eq 'thinking') {
                    Write-Host "  💭 думает" -ForegroundColor DarkGray
                }
            }
        }
        'user' {
            foreach ($c in @($ev.message.content)) {
                if ([string]$c.type -eq 'tool_result') {
                    $body = ''
                    if ($c.content -is [string]) { $body = [string]$c.content }
                    elseif ($c.content) { $body = (@($c.content) | ForEach-Object { if ($_.PSObject.Properties['text']) { [string]$_.text } }) -join ' ' }
                    $body = ($body -replace '\s+', ' ')
                    if ($body.Length -gt 160) { $body = $body.Substring(0, 160) + '…' }
                    $mark = if ($c.PSObject.Properties['is_error'] -and $c.is_error) { '✗' } else { '↳' }
                    Write-Host "  $mark $body" -ForegroundColor DarkGray
                }
            }
        }
        'result' {
            $u = $ev.usage
            $tok = 0
            if ($u) { $tok = [double]$u.input_tokens + [double]$u.output_tokens + [double]$u.cache_read_input_tokens + [double]$u.cache_creation_input_tokens }
            $cost = if ($ev.PSObject.Properties['total_cost_usd']) { [string]$ev.total_cost_usd } else { '' }
            $mark = if ($ev.is_error) { '✗' } else { '✓' }
            Write-Host "[$ts] $mark claude итог: токенов $tok$(if ($cost) { ", $cost USD" })" -ForegroundColor $(if ($ev.is_error) { 'Red' } else { 'Green' })
            if ($ev.is_error) { Write-Host "  $([string]$ev.result)" -ForegroundColor Red }
        }
        default { }
    }
}
