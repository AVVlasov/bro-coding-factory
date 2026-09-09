# split.graph.ps1 — нарезка одной задачи на подзадачи под локальную модель. Один узел
# планировщика, ответ JSON, файлы пишет сама фабрика (harness/lib/split.ps1).
#
#   pwsh harness/graph.ps1 split -ArgsJson '{"task":"TASK-06","role":"planner","prompt":"…","profile":"local"}'
#
# Обычно зовётся через `bcf task split <ID> --for local`. Планировщик живёт на большой
# модели (roles.planner): резать задачу так, чтобы каждую часть закрыла слабая модель,
# это как раз рамочное решение, которое слабой модели не доверяют.

$Meta = @{
    name        = 'split'
    description = 'Нарезка задачи на подзадачи под локальную модель: один-два файла, одна проверка'
    phases      = @(
        @{ title = 'Нарезка'; detail = 'один узел планировщика, ответ JSON, файлы пишет фабрика' }
    )
}
if ($GraphMetaOnly) { return }

. (Join-Path $PSScriptRoot '..\lib\split.ps1')

$root = $script:GraphCtx.Root

if (-not $GraphArgs -or -not $GraphArgs.prompt -or -not $GraphArgs.task) {
    Write-GraphLog 'нет входа: ожидается -ArgsJson с полями task/role/prompt/profile'
    return @{ ok = $false; reason = 'нет входа' }
}

$task    = [string]$GraphArgs.task
$role    = if ($GraphArgs.role) { [string]$GraphArgs.role } else { 'planner' }
$profile = if ($GraphArgs.profile) { [string]$GraphArgs.profile } else { 'local' }
$prefix  = if ($GraphArgs.prefix) { [string]$GraphArgs.prefix } else { 'TASK' }
$tasksRel = if ($GraphArgs.tasksRel) { [string]$GraphArgs.tasksRel } else { 'tasks' }

Set-Phase 'Нарезка'

$text = Invoke-Node -Prompt ([string]$GraphArgs.prompt) -Label "нарезка-$task" -Role $role -Recall
if (-not $text) {
    Write-GraphLog 'нарезка не дала результата — узел не ответил'
    return @{ ok = $false; task = $task; reason = 'узел не ответил' }
}

$json = ''
$m = [regex]::Match($text, '(?s)```json\s*(\[.*?\])\s*```')
if ($m.Success) { $json = $m.Groups[1].Value }
else {
    $m2 = [regex]::Match($text, '(?s)(\[\s*\{.*\}\s*\])')
    if ($m2.Success) { $json = $m2.Groups[1].Value }
}
if (-not $json) {
    Write-GraphLog 'в ответе планировщика нет JSON-массива подзадач'
    return @{ ok = $false; task = $task; reason = 'нет JSON' }
}
$items = $null
try { $items = $json | ConvertFrom-Json -ErrorAction Stop } catch {
    Write-GraphLog "JSON подзадач не разобрался: $($_.Exception.Message)"
    return @{ ok = $false; task = $task; reason = 'JSON не разобрался' }
}

$res = Write-BcfSubtasks -Root $root -ParentId $task -Items @($items) -Prefix $prefix -TasksRel $tasksRel -Profile $profile
foreach ($c in $res.Created) { Write-GraphLog "создана $($c.Id): $($c.Title) — $($c.Files -join ', ')" }
if ($res.Rewired.Count) { Write-GraphLog "вход переведён на $($res.Last) у: $($res.Rewired -join ', ')" }
Write-GraphLog "родитель $task помечен «Исполнитель: подзадачи», из очереди вышел"

return @{ ok = $true; task = $task; created = @($res.Created | ForEach-Object { $_.Id }); last = $res.Last; rewired = $res.Rewired }
