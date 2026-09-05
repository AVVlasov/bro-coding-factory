# requirement.ps1 — номера требований заказчика, записанные в задаче.
#
# ЗАЧЕМ. Задача фабрики называется «TASK-07 — карточка приёма» и ничего не говорит о том,
# какой пункт договора она закрывает. На чужом проекте это стоит дороже всего в момент
# сдачи: заказчик спрашивает «где 3.1.1», и ответ собирается руками — открыть все задачи,
# прочитать текст, вспомнить. Реестр требований при этом лежит рядом и не связан с
# бэклогом ничем, кроме памяти того, кто нарезал задачи.
#
# ДВА ФОРМАТА, ОБА ЖИВУТ В РЕАЛЬНЫХ ЗАДАЧАХ:
#
#   1. Строка в шапке — когда задача целиком про одно-два требования:
#
#        # TASK-07 — карточка приёма
#        **Требование:** 3.1.1, ДКЦ1
#
#   2. Секция «## Требования» — когда их несколько и у каждого своя формулировка:
#
#        ## Требования
#        - **3.1.1** оператор видит расписание врача на неделю
#        - **ДКЦ1** карточка открывается за два клика
#
# ЗОНА ЧТЕНИЯ СУЖЕНА НАМЕРЕННО, и это не косметика. Номер вида «3.1.1» встречается в
# обычном тексте задачи (версии, пункты чек-листа, команды в блоках кода), и чтение «где
# угодно в теле» превратило бы столбец требований в мусор: задача с командой
# `npm view pkg@3.1.1` объявила бы себя закрывающей требование 3.1.1. Читается только
# шапка задачи (до первой секции) и только секция «## Требования», и только жирные номера
# в её буллетах — то есть ровно то, что человек написал как требование, а не упомянул.

. (Join-Path $PSScriptRoot 'bcf-context.ps1')
. (Join-Path $PSScriptRoot 'claims.ps1')

# Номер требования: цифры с точками (3.1.1), возможно с буквенным префиксом заказчика
# (ДКЦ1, FR-12, П4.2). Пробелов внутри нет — номер с пробелом это уже фраза.
$script:BcfRequirementRx = '^[\p{L}]{0,8}[-.]?\d+(?:\.\d+)*[\p{L}]{0,3}$'

function _BcfCleanRequirement([string]$Raw) {
    $s = ([string]$Raw).Trim().Trim('*', '`', '«', '»', '"', "'", '(', ')', '[', ']')
    $s = $s.Trim().TrimEnd('.', ',', ';', ':').Trim()
    if (-not $s) { return '' }
    if ($s.Length -gt 24) { return '' }
    if ($s -notmatch $script:BcfRequirementRx) { return '' }
    # Голый номер без цифр требованием не является, как и год: «2026» в шапке это дата.
    if ($s -notmatch '\d') { return '' }
    return $s
}

# Разбор текста задачи. Отдельной функцией от чтения файла — чтобы её можно было прогнать
# на образце в тесте, не раскладывая каталог задач на диске.
function Get-BcfRequirementsFromText {
    param([string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]

    # 1. Шапка: строка «**Требование:** 3.1.1, ДКЦ1» (и «Требования:» тоже — люди пишут
    #    и так). Шапку выделяет тот же разборщик, что и для поля «Исполнитель», то есть
    #    строка внутри блока кода или под секцией сюда не попадает.
    $header = Get-BcfTaskHeader -Body $Body
    if ($header) {
        $m = [regex]::Match($header, '(?im)^[ \t]*(?:[-*][ \t]+)?\*{0,2}[ \t]*Требовани[ея][ \t]*\*{0,2}[ \t]*:[ \t]*(.+?)[ \t]*$')
        if ($m.Success) {
            foreach ($part in ($m.Groups[1].Value -split '[,;]')) {
                $v = _BcfCleanRequirement $part
                if ($v -and -not $out.Contains($v)) { [void]$out.Add($v) }
            }
        }
    }

    # 2. Секция «## Требования»: жирный номер в начале буллета. Всё, что после номера, —
    #    формулировка требования, и в столбец она не едет: там нужен номер, по которому
    #    заказчик ищет пункт у себя.
    $clean = [regex]::Replace($Body, '(?s)<!--.*?-->', '')
    $sec = [regex]::Match($clean, '(?ms)^##[^\r\n]*Требовани[ея].*?(?=^##\s|\z)')
    if ($sec.Success) {
        $inFence = $false
        foreach ($line in ($sec.Value -split "`r?`n")) {
            if ($line -match '^[ \t]*(```|~~~)') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            if ($line -notmatch '^\s*[-*]\s') { continue }
            $bm = [regex]::Match($line, '^\s*[-*]\s*\*\*([^*]+)\*\*')
            if (-not $bm.Success) { continue }
            $v = _BcfCleanRequirement $bm.Groups[1].Value
            if ($v -and -not $out.Contains($v)) { [void]$out.Add($v) }
        }
    }

    return @($out)
}

# Требования задачи по её id. Каталог задач берётся из конфига той же функцией, что у
# планировщика: собственный путь здесь однажды разъедется с ним, и разъедется молча.
function Get-TaskRequirements {
    param([Parameter(Mandatory)][string]$TaskId, [Parameter(Mandatory)][string]$Root)

    $tasksDir = Get-BcfTasksDir -Root $Root
    $tf = Get-ChildItem $tasksDir -Filter "$TaskId-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tf) { return @() }
    $body = Get-Content -Raw -LiteralPath $tf.FullName -ErrorAction SilentlyContinue
    return @(Get-BcfRequirementsFromText -Body ([string]$body))
}

# Обратный вопрос — тот, который задаёт заказчик: какие задачи закрывают требование.
# Нужен отчёту: список требований без задач и есть ответ на «что ещё не сделано».
function Get-BcfRequirementIndex {
    # Не Mandatory: пустой бэклог — законное состояние на входе, а привязка обязательного
    # параметра к пустому массиву роняет вызывающего. Так `bcf tasks` на новом проекте
    # падал с «Cannot bind argument to parameter 'Tasks'» вместо строки «задач нет».
    param([array]$Tasks = @())

    $index = [ordered]@{}
    foreach ($t in @($Tasks)) {
        foreach ($r in @($t.Requirements)) {
            if (-not $r) { continue }
            if (-not $index.Contains($r)) { $index[$r] = @() }
            $index[$r] += [string]$t.Id
        }
    }
    return $index
}
