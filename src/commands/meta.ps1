# bcf meta — мета-слой: что фабрика знает о проектах.
#
#   bcf meta list                реестр: где проекты и когда их последний раз смотрели
#   bcf meta register            занести текущий проект в реестр
#   bcf meta audit               пройти чеклист по текущему проекту
#   bcf meta wiki [запрос]       вики: лучшие практики и типичные ошибки
#   bcf meta log "<что сделали>" запись в audit-log текущего проекта
#
# ЗАЧЕМ ЭТОТ СЛОЙ ВООБЩЕ. Обвязка деградирует МОЛЧА. Хук, переставший срабатывать после
# обновления CLI, не сообщает об этом — он просто пропускает то, что раньше блокировал,
# и проект ещё месяцами выглядит защищённым. Единственная защита — периодически смотреть
# и записывать дату; отсюда и реестр, и append-only журнал аудита.
#
# И правило, которое этот слой обязан соблюдать сам: кодовый агент в проекте НЕ должен
# узнать о существовании фабрики. Поэтому `bcf meta` пишет только в meta/ — ни одна его
# команда не оставляет в проекте ссылки на мета-слой.

$project = $script:BcfProject
$projName = Split-Path $project -Leaf
$meta = Get-BcfMeta

$sub = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -First 1
$rest = @($script:BcfArgs | Where-Object { $_ -notlike '-*' }) | Select-Object -Skip 1
if (-not $sub) { $sub = 'list' }

$registry = Join-Path $meta 'registry.md'
$projMeta = Join-Path $meta "projects\$projName"
$auditLog = Join-Path $projMeta 'audit-log.md'

function Get-BcfProjectSnapshot {
    param([string]$Root)
    $claudeMd = Join-Path $Root 'CLAUDE.md'
    $hooks = @(Get-ChildItem (Join-Path $Root '.claude\hooks') -Filter '*.sh' -File -ErrorAction SilentlyContinue)
    $skills = @(Get-ChildItem (Join-Path $Root '.claude\skills') -Directory -ErrorAction SilentlyContinue)
    $agents = @(Get-ChildItem (Join-Path $Root '.claude\agents') -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue)
    $cfg = $null
    try { $cfg = Get-BcfHarnessConfig -Project $Root } catch { }
    return [pscustomobject]@{
        Name = (Split-Path $Root -Leaf); Path = $Root
        ClaudeMd = (Test-Path $claudeMd)
        ClaudeMdLines = $(if (Test-Path $claudeMd) { @(Get-Content -LiteralPath $claudeMd).Count } else { 0 })
        Hooks = $hooks.Count; Skills = $skills.Count; Agents = $agents.Count
        Settings = (Test-Path (Join-Path $Root '.claude\settings.json'))
        Config = ($null -ne $cfg)
        Memory = ($cfg -and $cfg.features -and $cfg.features.memory)
        Checks = (Test-Path (Join-Path $Root 'config\checks.json'))
        Card = (Get-BcfProjectCard -Project $Root)
    }
}

switch ($sub) {

'list' {
    Write-BcfTitle 'РЕЕСТР ПРОЕКТОВ' $registry
    if (-not (Test-Path $registry)) { Write-BcfDim 'реестра нет'; exit 2 }

    $entries = @()
    foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $registry), '(?ms)^##\s+(?!Формат)(.+?)$(.*?)(?=^##\s|\z)')) {
        $name = $m.Groups[1].Value.Trim()
        # Шаблон записи внутри самого реестра — не проект. Без этой отсечки он попадал
        # в список как «<имя проекта>, не проверялся» и красил реестр в красный.
        if ($name -match '[<>]' -or $name -eq 'Формат записи') { continue }
        $body = $m.Groups[2].Value
        $path = ''; $audit = ''
        $pm = [regex]::Match($body, '\*\*Путь:\*\*\s*`([^`]+)`'); if ($pm.Success) { $path = $pm.Groups[1].Value }
        $am = [regex]::Match($body, '\*\*Последний аудит:\*\*\s*([0-9-]+)'); if ($am.Success) { $audit = $am.Groups[1].Value }
        $entries += [pscustomobject]@{ Name = $name; Path = $path; Audit = $audit }
    }
    if (-not $entries.Count) {
        Write-BcfDim 'проектов пока нет'
        Write-BcfNote 'занести текущий: bcf meta register'
        Write-Host ''
        exit 0
    }

    $rows = New-BcfRows
    $colors = @()
    foreach ($e in $entries) {
        $age = ''
        $col = ''
        if ($e.Audit) {
            try {
                $days = [int][math]::Floor(((Get-Date).Date - [datetime]$e.Audit).TotalDays)
                $age = if ($days -le 0) { 'сегодня' } else { "$days дн. назад" }
                # Порог не абсолютный: смысл в том, что старый аудит — это не «давно
                # смотрели», а «неизвестно, работает ли обвязка сейчас».
                if ($days -gt 90) { $col = 'Red'; $age += ' — что там сейчас, неизвестно' }
                elseif ($days -gt 30) { $col = 'Yellow' }
            } catch { $age = $e.Audit }
        } else { $age = 'не проверялся'; $col = 'Red' }
        # Длинный путь ломает таблицу целиком, а полезен в нём только хвост.
        $shown = if ($e.Path.Length -gt 40) { '…' + $e.Path.Substring($e.Path.Length - 39) } else { $e.Path }
        Add-BcfRow $rows @($e.Name, $shown, $e.Audit, $age)
        $colors += $col
    }
    Write-BcfTable -Headers @('проект', 'путь', 'аудит', 'давность') `
                   -Widths @(20, 42, 12, 32) -Rows $rows -RowColors $colors
    Write-Host ''
    Write-BcfNote 'проверить обвязку текущего проекта: bcf meta audit'
    Write-Host ''
    exit 0
}

'register' {
    $s = Get-BcfProjectSnapshot -Root $project
    New-Item -ItemType Directory -Force -Path $projMeta | Out-Null

    $entry = @"

## $($s.Name)
- **Путь:** ``$($s.Path)``
- **Тип:** other
- **Статус:** active
- **CLAUDE.md:** $(if ($s.ClaudeMd) { "есть ($($s.ClaudeMdLines) строк)" } else { 'НЕТ' })
- **Хуки:** $($s.Hooks)
- **Скилы:** $($s.Skills)
- **Судьи/роли:** $($s.Agents)
- **Память:** $(if ($s.Memory) { 'подключена' } else { 'нет' })
- **Последний аудит:** $(Get-Date -Format 'yyyy-MM-dd')
- **Заметки:** запись создана ``bcf meta register``

### История аудитов
| Дата | Что нашли | Что сделали |
|------|-----------|-------------|
| $(Get-Date -Format 'yyyy-MM-dd') | заведён в реестре | — |
"@

    $existing = if (Test-Path $registry) { Get-Content -Raw -LiteralPath $registry } else { "# Реестр проектов`n" }
    if ($existing -match "(?m)^##\s+$([regex]::Escape($s.Name))\s*$") {
        Write-BcfWarn "проект '$($s.Name)' уже в реестре — запись не дублируется"
        Write-BcfNote "правь руками: $registry"
    } else {
        Add-Content -LiteralPath $registry -Value $entry -Encoding UTF8
        Write-BcfOk "занесён в реестр: $($s.Name)"
    }

    if (-not (Test-Path $auditLog)) {
        Set-Content -LiteralPath $auditLog -Encoding UTF8 -Value @"
# $($s.Name) — журнал аудита

Append-only. Каждая запись — что нашли и что с этим сделали. Не переписывать прошлое:
ценность журнала в том, что по нему видно, какие дефекты возвращаются.

## $(Get-Date -Format 'yyyy-MM-dd') — заведён в реестре
Снимок на момент заведения: CLAUDE.md $(if ($s.ClaudeMd) { "есть ($($s.ClaudeMdLines) строк)" } else { 'НЕТ' }),
хуков $($s.Hooks), скилов $($s.Skills), ролей $($s.Agents),
память $(if ($s.Memory) { 'подключена' } else { 'не подключена' }).
"@
        Write-BcfOk "заведён журнал аудита: meta/projects/$($s.Name)/audit-log.md"
    }
    Write-Host ''
    Write-BcfNote 'пройти чеклист: bcf meta audit'
    Write-Host ''
    exit 0
}

'audit' {
    $s = Get-BcfProjectSnapshot -Root $project
    Write-BcfTitle "АУДИТ ОБВЯЗКИ  $($s.Name)" 'проверяем не наличие файлов, а работают ли гейты'

    $findings = @()
    function _check($ok, $what, $why) {
        if ($ok) { Write-BcfOk $what } else { Write-BcfFail $what; Write-BcfNote $why; $script:findings += $what }
    }

    _check $s.ClaudeMd 'CLAUDE.md есть' `
        'без него приёмке нечем обосновать блокировку, и ревью превращается в спор о вкусах.'
    if ($s.ClaudeMd -and (Select-String -Path (Join-Path $project 'CLAUDE.md') -Pattern '^TODO$' -Quiet)) {
        Write-BcfWarn 'CLAUDE.md — незаполненная заготовка (в нём остались TODO)'
        $findings += 'CLAUDE.md не заполнен'
    }
    _check $s.Settings '.claude/settings.json есть' `
        'без него ни один хук не подключён: файлы лежат, но не вызываются — обвязка выглядит установленной и не работает.'
    _check ($s.Hooks -gt 0) "хуки на месте ($($s.Hooks))" `
        'гейты не установлены: сессия может завершиться на невыполненной задаче.'
    _check ($s.Agents -gt 0) "роли/судьи на месте ($($s.Agents))" `
        'верификации некому исполнять — вердикт будет опираться только на детерминированные проверки.'
    _check $s.Config 'config/harness.json есть' `
        'харнесс не настроен под проект: productPaths, проверки и раннер тестов неизвестны.'
    _check $s.Checks 'config/checks.json есть' `
        'обязательные проверки задаёт сам агент — то есть он может сузить их до тривиально зелёных.'

    # Утечка мета-слоя в проект — дефект по построению: агент не должен знать о фабрике.
    $leaks = @()
    foreach ($f in @('CLAUDE.md', '.claude\settings.json')) {
        $p = Join-Path $project $f
        if (-not (Test-Path $p)) { continue }
        if (Select-String -Path $p -Pattern ([regex]::Escape((Get-BcfHome))) -Quiet) { $leaks += $f }
    }
    if ($leaks.Count) {
        Write-Host ''
        Write-BcfFail "в проекте есть ссылки на фабрику: $($leaks -join ', ')"
        Write-BcfNote 'кодовый агент не должен знать о существовании внешних папок: сама такая ссылка —'
        Write-BcfNote 'утечка, после которой он начинает туда ходить. Удалить.'
        $findings += 'утечка пути фабрики в проект'
    }

    Write-Host ''
    $checklist = Join-Path $meta 'wiki\best-practices\project-audit-checklist.md'
    if (Test-Path $checklist) { Write-BcfNote "полный чеклист (глазами): $checklist" }

    if ($findings.Count) {
        Write-Host ''
        Write-BcfLine "  НАЙДЕНО: $($findings.Count)" 'Red'
        Write-BcfNote "записать итог: bcf meta log `"<что сделали>`""
        Write-Host ''
        exit 1
    }
    Write-BcfOk 'обвязка на месте'
    Write-BcfNote 'это проверка НАЛИЧИЯ. Что гейты реально срабатывают — показывает только прогон: bcf doctor --checks'
    Write-Host ''
    exit 0
}

'log' {
    $text = ($rest -join ' ').Trim()
    if (-not $text) { Write-BcfFail 'что записать? bcf meta log "починил done-gate: не видел новых каналов"'; exit 2 }
    New-Item -ItemType Directory -Force -Path $projMeta | Out-Null
    if (-not (Test-Path $auditLog)) {
        Set-Content -LiteralPath $auditLog -Value "# $projName — журнал аудита`n`nAppend-only.`n" -Encoding UTF8
    }
    Add-Content -LiteralPath $auditLog -Encoding UTF8 -Value "`n## $(Get-Date -Format 'yyyy-MM-dd') — запись`n$text`n"
    Write-BcfOk "записано: meta/projects/$projName/audit-log.md"
    exit 0
}

'wiki' {
    $q = ($rest -join ' ').Trim()
    $wiki = Join-Path $meta 'wiki'
    $files = @(Get-ChildItem $wiki -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($q) {
        $hits = @($files | Where-Object {
            $_.BaseName -like "*$q*" -or (Select-String -Path $_.FullName -Pattern ([regex]::Escape($q)) -Quiet)
        })
        Write-BcfTitle 'ВИКИ' "запрос: $q · найдено $($hits.Count)"
        foreach ($h in $hits) {
            $rel = $h.FullName.Substring($wiki.Length).TrimStart('\', '/')
            Write-BcfLine "  · $rel" 'White'
            foreach ($m in (Select-String -Path $h.FullName -Pattern ([regex]::Escape($q)) -Context 0, 1 | Select-Object -First 2)) {
                Write-BcfNote ($m.Line.Trim())
            }
        }
        if (-not $hits.Count) { Write-BcfDim 'ничего не нашлось' }
    } else {
        Write-BcfTitle 'ВИКИ' "$($files.Count) статей · $wiki"
        foreach ($cat in @('best-practices', 'common-errors')) {
            $inCat = @($files | Where-Object { $_.DirectoryName -like "*$cat*" })
            if (-not $inCat.Count) { continue }
            Write-Host ''
            Write-BcfLine "  $cat" 'White'
            foreach ($f in $inCat) {
                $first = (Get-Content -LiteralPath $f.FullName -TotalCount 1) -replace '^#\s*', ''
                Write-BcfLine ("    {0,-42} {1}" -f $f.BaseName, $first) 'DarkGray'
            }
        }
    }
    Write-Host ''
    exit 0
}

default {
    Write-BcfFail "неизвестная подкоманда: $sub"
    Write-BcfNote 'доступно: list | register | audit | wiki [запрос] | log "<текст>"'
    exit 2
}
}
