# research.graph.ps1 — разведка одной задачи. Один узел, только чтение, один файл.
#
#   pwsh harness/graph.ps1 research -ArgsJson '{"task":"TASK-06","role":"critic","prompt":"…","out":"…"}'
#
# Обычно зовётся через `bcf research <TASK>`, который и собирает этот вход.
#
# ЗАЧЕМ ЭТО ГРАФ, А НЕ ПРОСТО ВЫЗОВ АГЕНТА. Ради журнала. Разведка стоит денег и иногда
# ошибается; без записи в journal.jsonl её нельзя ни посчитать (bcf cost), ни разобрать
# потом («откуда взялся этот вывод»). Один узел в графе даёт и то, и другое бесплатно.

$Meta = @{
    name        = 'research'
    description = 'Разведка задачи до работы: что уже есть, чего не хватает, что решать человеку'
    phases      = @(
        @{ title = 'Разведка'; detail = 'один узел только на чтение, пишет ровно один файл' }
    )
}
if ($GraphMetaOnly) { return }

$root = $script:GraphCtx.Root

if (-not $GraphArgs -or -not $GraphArgs.prompt) {
    Write-GraphLog 'нет входа: ожидается -ArgsJson с полями task/role/prompt/out'
    return @{ ok = $false; reason = 'нет входа' }
}

$task = [string]$GraphArgs.task
$role = if ($GraphArgs.role) { [string]$GraphArgs.role } else { 'critic' }
$out  = [string]$GraphArgs.out

Set-Phase 'Разведка'

# -Recall поднимает в контекст узла уроки из памяти. Для разведки это ценнее, чем для
# работы: «мы уже пробовали и вот на чём обожглись» — ровно тот факт, ради которого
# разведка и делается.
$text = Invoke-Node -Prompt ([string]$GraphArgs.prompt) -Label "разведка-$task" -Role $role -Recall

if (-not $text) {
    Write-GraphLog "разведка не дала результата — узел не ответил"
    return @{ ok = $false; task = $task; reason = 'узел не ответил' }
}

$header = @"
# Разведка $task

> Собрано ``bcf research`` $(Get-Date -Format 'yyyy-MM-dd HH:mm'), роль ``$role``, только чтение.
> Это не решение и не часть контракта задачи: раздел «Решать человеку» намеренно
> оставлен без ответа — там выбор меняет продукт, а не реализацию.

"@

if ($out) {
    New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
    Set-Content -LiteralPath $out -Value ($header + $text) -Encoding UTF8
    Write-GraphLog "записано: $out"
}

# Развилки для человека вытаскиваем в лог: файл прочитают не всегда, а строку в ленте —
# увидят сразу. Именно они блокируют работу, а не остальной текст разведки.
$m = [regex]::Match($text, '(?ms)^##[^\r\n]*Решать человеку(.*?)(?=^##\s|\z)')
if ($m.Success) {
    $items = @($m.Groups[1].Value -split "`r?`n" | Where-Object { $_ -match '^\s*[-*\d]' } | Select-Object -First 5)
    if ($items.Count) {
        Write-GraphLog "решать человеку — $($items.Count):"
        foreach ($i in $items) { Write-GraphLog "  $($i.Trim())" }
    }
}

return @{ ok = $true; task = $task; out = $out; chars = $text.Length }
