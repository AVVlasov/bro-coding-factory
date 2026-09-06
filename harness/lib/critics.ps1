# critics.ps1 — ракурсы приёмки: чей ракурс, каким текстом смотрит и что значит его провал.
#
# ЗАЧЕМ ОТДЕЛЬНЫМ ФАЙЛОМ. Тексты критиков лежали строками внутри harness/graphs/queue.graph.ps1,
# и это давало три следствия, ни одно из которых не про красоту кода:
#
#   1. Проект не мог их поправить. Приёмка чужого продукта шла вопросами, написанными под
#      другой продукт: критик честно отвечал «указанные требования неприменимы» и сжигал
#      треть круга. Поправить текст можно было только правкой движка — то есть всем сразу.
#   2. Ракурс не имел владельца. Находка приезжала «от критика», и спросить по ней было
#      некого: ни в отчёте, ни в конфиге не было строки «за этот ракурс отвечает такой-то».
#   3. Провал любого ракурса весил одинаково. Ракурс, заведённый «посмотреть», ронял вердикт
#      наравне с ракурсом, за которым стоит требование заказчика, — и его переставали заводить.
#
# Здесь ракурс — это ЗАПИСЬ (id, владелец, блокирующий он или совещательный) плюс ТЕКСТ,
# который лежит файлом в проекте рядом с тестерами: .claude/agents/critics/<id>.md. Файла
# в проекте нет — берётся шаблон фабрики, и об этом пишется строка в журнал прогона, а не
# молчание: подмена текста без предупреждения читается как «проект настроен», хотя он не настроен.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')

# Наборы по умолчанию РАЗНЫЕ у приёмки и у ревью, и это не небрежность. Приёмка смотрит на
# слитое дерево целиком (инварианты, склейка задач между собой), ревью — на правку (краевые
# значения, обработка отказов, границы слоёв). Общего у них два ракурса: честность гейтов и
# работа пользователя — их ломают одинаково в обоих режимах.
$script:BcfDefaultLensIds = @{
    acceptance = @('invariants', 'seams', 'gates', 'journey')
    review     = @('correctness', 'failures', 'boundaries', 'gates', 'journey')
}

# Каталог текстов критиков в фабрике. Он же источник для `bcf install`: то, что кладётся
# в проект, и то, чем движок подменяет отсутствующее, — один и тот же файл.
function Get-BcfCriticTemplateDir {
    return (Join-Path (Get-BcfHomeRoot) 'templates\claude\agents\critics')
}

# Каталог текстов критиков в проекте.
function Get-BcfCriticProjectDir {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root '.claude\agents\critics')
}

function _BcfLensString($Record, [string[]]$Names) {
    foreach ($n in $Names) {
        $p = $Record.PSObject.Properties[$n]
        if (-not $p) { continue }
        $v = [string]$p.Value
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    }
    return ''
}

# Идентификатор ракурса уезжает в метку узла и в имя переменной графа, то есть в текст,
# который потом собирается в скриптблок. Кавычку и обратный апостроф вырезаем здесь, а не
# надеемся, что их никто не напишет: запись в конфиг приходит извне (рассылка правил).
function _BcfSafeLensId([string]$Id) {
    $s = ($Id -replace '[^\p{L}\p{Nd}_.\-]', '')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40) }
    return $s
}

# --- Ракурсы проекта -------------------------------------------------------------------
#
# ФОРМАТ ЗАПИСИ (config/review-lenses.json):
#
#   { "id": "java", "owner": "лидер java", "blocking": true,
#     "file": ".claude/agents/testers/java.md", "rules": 7 }
#
# Тот же файл пишет внешняя рассылка правил, поэтому разбор ТЕРПИМЫЙ: лишние поля (rules и
# что угодно ещё) игнорируются, id читается и из "key" (так писала прежняя версия формата),
# текст можно оставить прямо в записи полем "ask". Строгая схема здесь означала бы, что
# рассылка правил однажды выключит приёмку целиком — молча, потому что дефолт подставится
# сам и выглядит рабочим.
#
# НЕОБЯЗАТЕЛЬНОЕ ПОЛЕ "kind" ("acceptance" или "review") сужает ракурс до одного графа.
# Без него ракурс идёт в оба — так ведёт себя запись рассылки правил, которая про графы
# ничего не знает. Поле нужно ровно затем, что каждый ракурс это отдельный вызов агента на
# каждый круг: файл, где перечислены ракурсы обоих графов, без "kind" сделал бы приёмку
# в полтора раза дороже, чем она была до появления конфига, и сделал бы это молча.
function Get-BcfLenses {
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('acceptance', 'review')][string]$Kind = 'acceptance',
        [string]$ConfigFile = ''
    )

    $notes = @()
    $file = if ($ConfigFile) { $ConfigFile } else { Join-Path $Root 'config\review-lenses.json' }
    $lenses = @()
    $parsed = @()

    if (Test-Path -LiteralPath $file) {
        $raw = $null
        try { $raw = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json }
        catch {
            $notes += "config/review-lenses.json не разобран ($($_.Exception.Message)) — беру ракурсы по умолчанию"
            $raw = $null
        }
        if ($null -ne $raw) {
            $items = if ($raw -is [array]) { @($raw) }
                     elseif ($raw.PSObject.Properties['lenses']) { @($raw.lenses) }
                     else { @($raw) }
            $seen = @{}
            foreach ($it in $items) {
                if ($null -eq $it -or $it -is [string]) { continue }
                $id = _BcfSafeLensId (_BcfLensString $it @('id', 'key', 'name'))
                if (-not $id) { $notes += 'ракурс без id пропущен: запись без имени адресовать некому'; continue }
                if ($seen.ContainsKey($id)) { $notes += "ракурс $id объявлен дважды — беру первое объявление"; continue }
                $seen[$id] = $true

                # Блокирующий по умолчанию. Обратный дефолт («не сказано — совещательный»)
                # означал бы, что забытое поле молча снимает ракурс с вердикта: приёмка
                # продолжает печатать находки, а прогон становится зелёным.
                $blocking = $true
                $bp = $it.PSObject.Properties['blocking']
                if ($bp) {
                    $bv = $bp.Value
                    if ($bv -is [bool]) { $blocking = [bool]$bv }
                    else {
                        $bs = ([string]$bv).Trim()
                        if ($bs -match '^(?i)(false|no|off|0|нет|совещательный)$') { $blocking = $false }
                        elseif ($bs -match '^(?i)(true|yes|on|1|да|блокирующий)$') { $blocking = $true }
                        else {
                            $notes += "ракурс ${id}: значение blocking «$bs» не понято — считаю блокирующим"
                            $blocking = $true
                        }
                    }
                }

                # Область ракурса. Непонятое значение НЕ выбрасывает запись: ракурс,
                # молча исчезнувший из-за опечатки в необязательном поле, — это выключенная
                # приёмка, о которой никто не узнает.
                $lensKind = ''
                $kv = (_BcfLensString $it @('kind', 'graph', 'scope'))
                if ($kv) {
                    if ($kv -match '^(?i)(acceptance|приёмка|приемка|queue)$') { $lensKind = 'acceptance' }
                    elseif ($kv -match '^(?i)(review|ревью)$') { $lensKind = 'review' }
                    elseif ($kv -match '^(?i)(both|оба|any|все)$') { $lensKind = '' }
                    else { $notes += "ракурс ${id}: область «$kv» не понята — беру ракурс в оба графа" }
                }

                $parsed += [pscustomobject]@{
                    Id       = $id
                    Owner    = (_BcfLensString $it @('owner'))
                    Blocking = $blocking
                    Kind     = $lensKind
                    File     = (_BcfLensString $it @('file'))
                    Ask      = (_BcfLensString $it @('ask'))
                }
            }
            if (-not $parsed.Count) {
                $notes += 'в config/review-lenses.json не осталось ни одного разобранного ракурса — беру ракурсы по умолчанию'
            }
            $lenses = @($parsed | Where-Object { -not $_.Kind -or $_.Kind -eq $Kind })
            if ($parsed.Count -and -not $lenses.Count) {
                $notes += "в config/review-lenses.json нет ни одного ракурса для «$Kind» — беру ракурсы по умолчанию"
            }
        }
    }

    $fromProject = [bool]$lenses.Count
    if (-not $fromProject) {
        foreach ($id in @($script:BcfDefaultLensIds[$Kind])) {
            $lenses += [pscustomobject]@{ Id = $id; Owner = ''; Blocking = $true; Kind = $Kind; File = ''; Ask = '' }
        }
    }

    return @{
        Lenses      = @($lenses)
        Notes       = @($notes)
        FromProject = $fromProject
        File        = $file
    }
}

# Заголовок YAML в файле роли (name/description/model) — служебная шапка для Claude Code,
# а не часть вопроса критику. В промпт она попадать не должна: критик начинает отвечать
# на «description», а не на ракурс.
function Remove-BcfFrontMatter {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text -replace "^﻿", ''
    $m = [regex]::Match($t, "(?s)^\s*---\r?\n.*?\r?\n---\r?\n")
    if ($m.Success) { $t = $t.Substring($m.Length) }
    return $t.Trim()
}

# --- Текст ракурса ---------------------------------------------------------------------
#
# Порядок источников: поле file записи → .claude/agents/critics/<id>.md проекта → шаблон
# фабрики → поле ask записи. Шаблон фабрики — фолбэк С ПРЕДУПРЕЖДЕНИЕМ: молчаливая подмена
# читается как «проект настроен под себя», и разбор чужой приёмки начинается с поиска
# текста, которого в проекте нет.
function Get-BcfCriticText {
    param(
        [Parameter(Mandatory)]$Lens,
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Values = @{},
        [string]$TemplateDir = ''
    )

    $id = [string]$Lens.Id
    $tplDir = if ($TemplateDir) { $TemplateDir } else { Get-BcfCriticTemplateDir }

    $candidates = @()
    if ($Lens.File) {
        $p = [string]$Lens.File
        $abs = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $Root ($p -replace '/', '\') }
        $candidates += [pscustomobject]@{ Path = $abs; Source = 'проект'; Rel = $p }
    }
    $candidates += [pscustomobject]@{ Path = (Join-Path (Get-BcfCriticProjectDir -Root $Root) "$id.md")
                                      Source = 'проект'; Rel = ".claude/agents/critics/$id.md" }
    $candidates += [pscustomobject]@{ Path = (Join-Path $tplDir "$id.md")
                                      Source = 'фабрика'; Rel = "templates/claude/agents/critics/$id.md" }

    $text = ''
    $source = ''
    $path = ''
    $rel = ''
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path -PathType Leaf)) { continue }
        $body = Remove-BcfFrontMatter (Get-Content -Raw -LiteralPath $c.Path -ErrorAction SilentlyContinue)
        if (-not $body) { continue }
        $text = $body; $source = $c.Source; $path = $c.Path; $rel = $c.Rel
        break
    }

    $note = ''
    if (-not $text -and $Lens.Ask) {
        $text = [string]$Lens.Ask
        $source = 'конфиг'
        $rel = 'config/review-lenses.json'
    }
    if (-not $text) {
        $note = "ракурс ${id}: текста нет ни в проекте (.claude/agents/critics/$id.md), ни в шаблонах фабрики — ракурс пропущен"
        $source = 'нет'
    } elseif ($source -eq 'фабрика') {
        $note = "ракурс ${id}: в проекте нет .claude/agents/critics/$id.md — беру текст из шаблона фабрики"
    }

    # Подстановки, которые знает только прогон: список документов проекта с инвариантами,
    # перечень закрытых задач и прочее. Неизвестный ключ НЕ вычищается — он остаётся видимым
    # в промпте, потому что тихо стёртый кусок вопроса выглядит как исправный вопрос.
    foreach ($k in @($Values.Keys)) {
        $text = $text.Replace('{{' + $k + '}}', [string]$Values[$k])
    }

    return [pscustomobject]@{ Text = $text; Source = $source; Path = $path; Rel = $rel; Note = $note }
}

# --- Сборка промптов -------------------------------------------------------------------
#
# ОДНА СБОРКА НА ОБА ГРАФА. Приёмка и ревью задают ракурсу один и тот же вопрос в разной
# обстановке: приёмка — про слитое дерево, ревью — про правку. Разное у них обрамление
# (шапка и хвост), общее — сам ракурс, его вес и то, откуда взялся текст. Две копии этой
# сборки разошлись бы на первом же изменении, и разошлись бы молча: каждая по отдельности
# работает.
#
# Здесь же пишется строка в журнал прогона о подмене текста шаблоном фабрики: молчаливая
# подмена читается как «проект настроен под себя».
function Build-BcfCriticPrompts {
    param(
        [Parameter(Mandatory)][array]$Lenses,
        [Parameter(Mandatory)][string]$Root,
        [string]$Header = '',
        [string]$Tail = '',
        [hashtable]$Values = @{},
        [string]$TemplateDir = ''
    )

    $used = @()
    $prompts = @()
    foreach ($lens in @($Lenses)) {
        # Текст уже прочитан вызывающим (ревью читает его один раз на прогон, а промпты
        # собирает каждый раунд) — тогда читаем файл повторно и предупреждаем повторно
        # только зря: в журнале появлялось бы по три одинаковых строки на ракурс.
        $preset = ''
        if ($lens.PSObject.Properties['Text']) { $preset = [string]$lens.Text }
        $ct = if ($preset) {
            [pscustomobject]@{ Text = $preset; Source = 'разобран ранее'; Path = ''; Rel = ''; Note = '' }
        } else {
            Get-BcfCriticText -Lens $lens -Root $Root -Values $Values -TemplateDir $TemplateDir
        }
        if ($ct.Note) { Write-GraphLog "! $($ct.Note)" }
        if (-not $ct.Text) { continue }

        $weight = if ($lens.Blocking) {
            'БЛОКИРУЮЩИЙ: находка P1 роняет вердикт прогона'
        } else {
            'совещательный: находки идут в отчёт, вердикт прогона не меняют'
        }
        $parts = @()
        if ($Header) { $parts += $Header; $parts += '' }
        $parts += "Ракурс «$($lens.Id)» — $weight."
        $parts += ''
        $parts += $ct.Text
        if ($Tail) { $parts += $Tail }

        $used += $lens
        $prompts += ($parts -join "`n")
        Write-GraphLog -Detail "· ракурс $($lens.Id): текст из источника «$($ct.Source)» ($($ct.Rel))"
    }

    return @{ Lenses = @($used); Prompts = @($prompts) }
}

# --- Запуск ракурсов -------------------------------------------------------------------
#
# Ветки барьера живут в ЧУЖИХ runspace и видят только GraphVars: обычная переменная скрипта
# там просто не существует. Наблюдалось живьём — `-Schema $criticSchema` превращался в
# `-Schema $null`, узел молча возвращал прозу вместо структуры, а отчёт печатал «Находок нет».
# Поэтому и промпт, и схема кладутся в общее состояние графа, а ветка достаёт их по имени.
function Invoke-BcfCriticBarrier {
    param(
        [Parameter(Mandatory)][array]$Lenses,
        [Parameter(Mandatory)][string[]]$Prompts,
        [string]$LabelPrefix = 'приёмка',
        # Хвост метки — там, где один и тот же ракурс запускается несколько раз за прогон
        # (раунды поиска в ревью). Без него метки совпадают, и на доске видно один узел
        # вместо трёх.
        [string]$LabelSuffix = '',
        [hashtable]$Schema = $null,
        [ValidateSet('worker', 'planner', 'critic', 'arbiter')][string]$Role = 'critic'
    )

    $ls = @($Lenses)
    $ps = @($Prompts)
    if ($ls.Count -ne $ps.Count) {
        throw "ракурсов $($ls.Count), а промптов $($ps.Count) — соответствие ракурс→ответ развалится"
    }
    if (-not $ls.Count) { return @() }

    Set-GraphVar 'bcfCriticSchema' $Schema
    $thunks = @()
    for ($i = 0; $i -lt $ls.Count; $i++) {
        $var = "bcfCriticPrompt$i"
        Set-GraphVar $var $ps[$i]
        $label = "$LabelPrefix-$(_BcfSafeLensId ([string]$ls[$i].Id))$(if ($LabelSuffix) { "-$(_BcfSafeLensId $LabelSuffix)" })"
        $schemaArg = if ($Schema) { "-Schema (Get-GraphVar 'bcfCriticSchema') " } else { '' }
        $thunks += [scriptblock]::Create(
            "Invoke-Node -Role $Role -Recall $schemaArg-Label '$label' -Prompt (Get-GraphVar '$var')")
    }
    return @(Invoke-Barrier -Thunks $thunks)
}

# --- Сведение ответов ------------------------------------------------------------------
#
# ОТВЕТ, КОТОРОГО НЕТ, — НЕ «НАХОДОК НЕТ». Узел роли возвращает $null, когда агент не дал
# текста (протух путь к CLI, кончилась квота, оборвался поток), и строка возвращается, когда
# схема до узла не доехала. Оба случая раньше считались чистой приёмкой.
#
# БЛОКИРУЮЩИЙ И СОВЕЩАТЕЛЬНЫЙ РАЗВЕДЕНЫ ЗДЕСЬ, А НЕ В ОТЧЁТЕ. Вердикт считается по
# блокирующим ракурсам; совещательные печатаются целиком, но прогон не роняют.
function Measure-BcfAcceptance {
    param([Parameter(Mandatory)][array]$Lenses, $Answers)

    $ls = @($Lenses)
    $ans = @($Answers)
    $rows = @()
    $all = @()

    for ($i = 0; $i -lt $ls.Count; $i++) {
        $lens = $ls[$i]
        $a = if ($i -lt $ans.Count) { $ans[$i] } else { $null }
        $ok = $false
        if ($a -and -not ($a -is [string]) -and $a.PSObject.Properties['findings']) { $ok = $true }

        $found = @()
        if ($ok) {
            foreach ($f in @($a.findings)) {
                if (-not $f) { continue }
                # Ракурс и его владелец едут вместе с находкой: без них в отчёте стоит
                # «нашёл критик», и спросить по находке некого.
                $f | Add-Member -NotePropertyName 'lens'     -NotePropertyValue ([string]$lens.Id) -Force
                $f | Add-Member -NotePropertyName 'owner'    -NotePropertyValue ([string]$lens.Owner) -Force
                $f | Add-Member -NotePropertyName 'blocking' -NotePropertyValue ([bool]$lens.Blocking) -Force
                $found += $f
                $all += $f
            }
        }

        $rows += [pscustomobject]@{
            Lens     = $lens
            Ok       = $ok
            Summary  = $(if ($ok -and $a.PSObject.Properties['summary']) { [string]$a.summary } else { '' })
            Findings = @($found)
            P1       = @($found | Where-Object { $_.severity -eq 'P1' }).Count
        }
    }

    $blockingRows = @($rows | Where-Object { $_.Lens.Blocking })
    $advisoryRows = @($rows | Where-Object { -not $_.Lens.Blocking })
    $blockingFind = @($all | Where-Object { $_.blocking })
    $advisoryFind = @($all | Where-Object { -not $_.blocking })

    return [pscustomobject]@{
        Run            = $rows.Count
        Answered       = @($rows | Where-Object { $_.Ok }).Count
        Failed         = @($rows | Where-Object { -not $_.Ok }).Count
        BlockingFailed = @($blockingRows | Where-Object { -not $_.Ok }).Count
        AdvisoryFailed = @($advisoryRows | Where-Object { -not $_.Ok }).Count
        Rows           = @($rows)
        Findings       = @($all)
        FindingsP1     = @($all | Where-Object { $_.severity -eq 'P1' }).Count
        Blocking       = @($blockingFind)
        BlockingP1     = @($blockingFind | Where-Object { $_.severity -eq 'P1' }).Count
        Advisory       = @($advisoryFind)
        AdvisoryP1     = @($advisoryFind | Where-Object { $_.severity -eq 'P1' }).Count
    }
}

# Раздел приёмки для .bcf/REVIEW.md. Находки разложены по весу: блокирующие сверху с
# владельцем ракурса, совещательные ниже и явно названы совещательными — иначе человек
# читает их как требования и чинит то, о чём его не просили.
function Format-BcfAcceptanceReport {
    param([Parameter(Mandatory)]$Measure, [string]$Merged = '')

    $m = $Measure
    $body = "`n## Приёмка графа (разные ракурсы, слитое дерево)`n`n"
    if ($Merged) { $body += "Задачи в дереве: $Merged`n`n" }

    $lensLines = @()
    foreach ($r in @($m.Rows)) {
        $kind = if ($r.Lens.Blocking) { 'блокирующий' } else { 'совещательный' }
        $who = if ($r.Lens.Owner) { $r.Lens.Owner } else { 'владелец не назначен' }
        $state = if ($r.Ok) { "находок $(@($r.Findings).Count)" } else { 'НЕ ОТВЕТИЛ' }
        $lensLines += "| $($r.Lens.Id) | $kind | $who | $state |"
    }
    if ($lensLines.Count) {
        $body += "| ракурс | вес | отвечает | результат |`n|---|---|---|---|`n" + ($lensLines -join "`n") + "`n`n"
    }

    if (@($m.Blocking).Count) {
        $body += "**Блокирующих находок: $(@($m.Blocking).Count)** (P1: $($m.BlockingP1)). " +
                 "Задачи закрыты по гейтам — эти замечания гейтами не ловятся.`n`n"
        foreach ($f in (@($m.Blocking) | Sort-Object severity)) {
            $where = "$($f.file)$(if ($f.line) { ":$($f.line)" })"
            $who = if ($f.owner) { ", отвечает $($f.owner)" } else { '' }
            $body += "- **[$($f.severity)]** $($f.what) — ``$where`` (ракурс $($f.lens)$who)`n"
        }
        $body += "`n"
    } elseif ($m.BlockingFailed -ge @($m.Rows | Where-Object { $_.Lens.Blocking }).Count -and $m.Run) {
        $body += "**Приёмка НЕ ВЫПОЛНЕНА**: ни один блокирующий ракурс не ответил " +
                 "($($m.BlockingFailed) из $(@($m.Rows | Where-Object { $_.Lens.Blocking }).Count)). " +
                 "«Находок нет» здесь означало бы, что смотрели и не нашли, — а не смотрели вовсе. " +
                 "Причина в журнале прогона; чаще всего это протухший путь к CLI или исчерпанная квота.`n`n"
    } else {
        $body += "Блокирующих находок нет.`n`n"
    }

    if (@($m.Advisory).Count) {
        $body += "### Совещательные ракурсы (на вердикт не влияют)`n`n"
        foreach ($f in (@($m.Advisory) | Sort-Object severity)) {
            $where = "$($f.file)$(if ($f.line) { ":$($f.line)" })"
            $who = if ($f.owner) { ", отвечает $($f.owner)" } else { '' }
            $body += "- **[$($f.severity)]** $($f.what) — ``$where`` (ракурс $($f.lens)$who)`n"
        }
        $body += "`n"
    }

    if ($m.BlockingFailed -and @($m.Blocking).Count) {
        $body += "> Внимание: не ответило блокирующих ракурсов — $($m.BlockingFailed). Часть приёмки не выполнена.`n`n"
    }
    if ($m.AdvisoryFailed) {
        $body += "> Совещательных ракурсов не ответило: $($m.AdvisoryFailed). На вердикт это не влияет.`n`n"
    }

    foreach ($r in @($m.Rows | Where-Object { $_.Ok -and $_.Summary })) {
        $body += "`n---`n`n**$($r.Lens.Id)** — $($r.Summary)`n"
    }
    return $body
}
