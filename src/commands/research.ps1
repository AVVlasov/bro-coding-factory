# bcf research <TASK> — разведка задачи до работы. Только чтение.
#
#   bcf research TASK-06            разведка, результат в tasks/TASK-06.research.md
#   bcf research TASK-06 --apply    вписать выводы в сам файл задачи
#
# ЗАЧЕМ ОТДЕЛЬНО ОТ РАБОТЫ. Кодовый агент, начинающий с незнакомого куска, первые
# итерации тратит на восстановление контекста — и делает это ВНУТРИ дорогого цикла, где
# каждая итерация тянет за собой верификацию. Разведка стоит одного узла и один файл.
#
# ПОЧЕМУ ТОЛЬКО ЧТЕНИЕ. Роль, которая обязана лишь смотреть, на бэкенде с правом записи
# однажды что-нибудь поправит «по пути» — и правка приедет в задачу как чужая. Поэтому
# ресёрчер живёт на песочнице «только чтение», если она есть, и пишет РОВНО ОДИН файл.

$project = $script:BcfProject
$task = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1
$apply = $script:BcfArgs -contains '--apply'

if (-not $task) {
    Write-BcfFail 'нужен id задачи: bcf research TASK-06'
    exit 2
}

$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { Write-BcfFail $_.Exception.Message; exit 2 }
if (-not $cfg) { Write-BcfFail 'config/harness.json не найден — bcf init'; exit 2 }

$taskFile = Get-ChildItem (Join-Path $project 'tasks') -Filter "$task-*.md" -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $taskFile) {
    Write-BcfFail "задача $task не найдена в tasks/"
    exit 2
}

# Роль ресёрчера может быть не назначена — это норма: она опциональная. Тогда берём
# критика, который у графа тоже сидит на песочнице только для чтения.
$role = 'researcher'
if (-not ($cfg.graph.roles.PSObject.Properties['researcher'] -and $cfg.graph.roles.researcher.backend)) {
    $role = 'critic'
    Write-BcfDim 'роль researcher не назначена — беру critic (он тоже только читает)'
}
if (-not ($cfg.graph.roles.PSObject.Properties[$role] -and $cfg.graph.roles.$role.backend)) {
    Write-BcfFail "роль '$role' не назначена в config/harness.json → graph.roles"
    Write-BcfNote 'назначить: bcf init (шаги 4–5)'
    exit 2
}

$backend = [string]$cfg.graph.roles.$role.backend
$outFile = Join-Path $project "tasks\$task.research.md"

Write-BcfTitle "РАЗВЕДКА  $task" "роль $role · бэкенд $backend · пишет ровно один файл"
Write-BcfNote "результат: tasks/$task.research.md"
if ($backend -notlike '*-ro') {
    Write-BcfWarn "бэкенд '$backend' не даёт песочницу «только чтение»"
    Write-BcfNote 'ресёрчер сможет править файлы. Проверь дифф после прогона: правка, приехавшая'
    Write-BcfNote 'из разведки, попадёт в задачу как чужая и всплывёт на слиянии.'
}

$brief = Get-Content -Raw -LiteralPath $taskFile.FullName
$prodPaths = @($cfg.productPaths) -join ', '

$prompt = @"
Ты — разведчик задачи. Твоя работа — НЕ писать код, а собрать то, чего не хватает, чтобы
задачу можно было закрыть с первой попытки.

ЗАДАЧА ${task}:
$brief

Продуктовый код проекта: $prodPaths

Сделай ровно это:

1. Прочитай то, что относится к задаче: соответствующие исходники и документы проекта.
   Не читай всё подряд — окно потратится, а разведка не состоится.
2. Выпиши, ЧТО УЖЕ ЕСТЬ и на что можно опереться (существующие типы, функции, контракты).
   Это чаще всего и есть главный результат: половина задач переоценена, потому что
   нужное уже написано в соседнем модуле.
3. Назови, чего в задаче не хватает для проверяемой готовности: какое условие нельзя
   проверить командой в нынешней формулировке.
4. Отдельно — РЕШЕНИЯ ДЛЯ ЧЕЛОВЕКА: развилки, где выбор меняет продукт, а не реализацию.
   Их НЕ додумывай. Агент, который «дорешает» такую развилку сам, вернёт работу,
   которую придётся переделывать.

Формат ответа — markdown с разделами:
## Что смотрел
## Что уже есть
## Чего не хватает задаче
## Решать человеку

Ничего не изменяй в репозитории. Твой единственный выход — этот текст.
"@

$graphPs1 = Join-Path (Get-BcfHarness) 'graph.ps1'
$researchGraph = Join-Path (Get-BcfHarness) 'graphs\research.graph.ps1'
if (-not (Test-Path $researchGraph)) {
    Write-BcfFail "нет графа разведки: $researchGraph"
    exit 3
}

$argsJson = (@{ task = $task; role = $role; prompt = $prompt; out = $outFile } | ConvertTo-Json -Depth 6 -Compress)
& pwsh -NoProfile -File $graphPs1 'research' -ArgsJson $argsJson -Yes -ProjectRoot $project
$code = $LASTEXITCODE

if (-not (Test-Path $outFile)) {
    Write-BcfFail 'разведка не оставила файла — смотри журнал последнего прогона: bcf board'
    exit 1
}

Write-Host ''
Write-BcfOk "готово: tasks/$task.research.md"

# Правки в файле ЗАДАЧИ делаются только по явной просьбе: задача — контракт, и менять
# его без ведома человека значит подменить то, что уже согласовано.
if ($apply) {
    Add-Content -LiteralPath $taskFile.FullName -Encoding UTF8 -Value @"

## Разведка ($(Get-Date -Format 'yyyy-MM-dd'))

См. ``tasks/$task.research.md``.
"@
    Write-BcfOk "ссылка на разведку добавлена в $($taskFile.Name)"
} else {
    Write-BcfNote "вписать ссылку в файл задачи: bcf research $task --apply"
}
Write-Host ''
exit $code
