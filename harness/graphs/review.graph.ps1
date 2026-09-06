# review.graph.ps1 — поиск дефектов с состязательной проверкой.
#
#   pwsh harness/graph.ps1 review                                 по незакоммиченным правкам
#   pwsh harness/graph.ps1 review -GraphArgs '{"base":"HEAD~3"}'  по диапазону коммитов
#   pwsh harness/graph.ps1 review -DryPlan                        состав узлов без запуска
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ГРАФ. Главная болезнь веера в том, что наружу выходит только итог:
# ошибка в одном мелком узле портит весь результат, и по готовому ответу не видно, где
# именно соврали. Лечится это не «ещё одним проверяющим в конце», а тем, что проверка
# сама становится графом — и каждая находка обязана пережить попытку её опровергнуть.
#
# ТРИ ПРАВИЛА, БЕЗ КОТОРЫХ ЭТО НЕ РАБОТАЕТ:
#
#   1. Искатели смотрят РАЗНЫМИ глазами, а не одними и теми же. Несколько одинаковых
#      агентов на одной модели читают один и тот же контекст и выдают согласованную
#      чушь промышленного масштаба. Ловит непохожесть, а не количество.
#   2. Проверяющих просят ОПРОВЕРГНУТЬ, а не «оценить». Вопрос «это настоящая ошибка?»
#      получает вежливое «да» на что угодно; вопрос «докажи, что этого бага нет»
#      заставляет лезть в код.
#   3. Дедуп идёт по ВСЕМУ увиденному, а не по подтверждённому. Иначе находка,
#      отклонённая проверкой, всплывает каждый раунд, и цикл никогда не сходится.

$Meta = @{
    name        = 'review'
    description = 'Поиск дефектов разными ракурсами + состязательная проверка каждой находки'
    phases      = @(
        @{ title = 'Разведка';   detail = 'что изменилось — вычисляется git-ом, не моделью' }
        @{ title = 'Маршрут';    detail = 'узел оценивает риск правки, КОД выбирает лёгкий или полный путь' }
        @{ title = 'Поиск';      detail = 'искатели с непересекающимися ракурсами, раундами до исчерпания' }
        @{ title = 'Проверка';   detail = 'на каждую находку — три опровергателя с разными углами' }
        @{ title = 'Сведение';   detail = 'ранжирование выживших находок в один отчёт' }
    )
}
if ($GraphMetaOnly) { return }

$root = $script:GraphCtx.Root
$base = if ($GraphArgs -and $GraphArgs.base) { [string]$GraphArgs.base } else { '' }

# ---------------------------------------------------------------------------
Set-Phase 'Разведка'
# ---------------------------------------------------------------------------
# Состав правок вычисляет git. Спрашивать об этом модель — платить за угадывание
# того, что известно точно.
if ($base) {
    $diffStat = (& git -C $root diff --stat $base 2>&1 | Out-String)
    $files = @(& git -C $root diff --name-only $base 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $diffCmd = "git diff $base --"
} else {
    $diffStat = (& git -C $root diff --stat HEAD 2>&1 | Out-String)
    $files = @(& git -C $root status --porcelain 2>$null |
               ForEach-Object { ($_ -replace '^...', '').Trim() -replace '\\', '/' } | Where-Object { $_ })
    $diffCmd = "git diff HEAD --"
}

# Что считать продуктовым кодом — свойство проекта, а не движка: берём из
# config/harness.json → productPaths. Без фильтра ревью читало бы и харнесс, и доки,
# и платило бы за это по цене критика.
$prodPaths = @()
try {
    $hcf = Join-Path $root 'config\harness.json'
    if (Test-Path $hcf) {
        $hc = Get-Content -Raw -LiteralPath $hcf | ConvertFrom-Json
        if ($hc.productPaths) { $prodPaths = @($hc.productPaths) }
    }
} catch { }
if (-not $prodPaths.Count) { $prodPaths = @('src') }

$prodRx = '^(' + (($prodPaths | ForEach-Object { [regex]::Escape(($_ -replace '\\', '/').Trim('/')) }) -join '|') + ')/'
$prodOnly = @($files | Where-Object { $_ -match $prodRx })

# ОБЛАСТЬ РЕВЬЮ: правка или продукт целиком.
#
#   pwsh harness/graph.ps1 review -GraphArgs '{"scope":"product"}'
#
# Дифф — правильная область для ревью ИТЕРАЦИИ и неправильная для ПРИЁМКИ. Дефект
# «функции нет вовсе» диффом не виден: диффа нет. Приёмка clinic-scheduler пять кругов
# читала диффы и каждый раз находила дефекты стыков — при том, что у оператора не было
# выбора даты, а у регистратора кнопки оплаты и печати талона были заглушками. Ни одно
# из этого в дифф не попадало никогда.
$scopeProduct = ($GraphArgs -and $GraphArgs.scope -eq 'product')
if ($scopeProduct) {
    $prodOnly = @(& git -C $root ls-files 2>$null |
                  ForEach-Object { $_.Trim() -replace '\\', '/' } |
                  Where-Object { $_ -and $_ -match $prodRx -and $_ -notmatch '\.(test|spec)\.[jt]sx?$' })
    $diffCmd  = 'git log --oneline -20 --'
    $diffStat = "область: ПРОДУКТ ЦЕЛИКОМ ($($prodOnly.Count) файлов в $($prodPaths -join ', ')), а не правка"
    Write-GraphLog "область ревью: ПРОДУКТ ЦЕЛИКОМ — $($prodOnly.Count) файлов"
}

if (-not $prodOnly.Count) {
    Write-GraphLog "продуктовых изменений нет ($($prodPaths -join ', ')) — ревью нечего смотреть"
    Write-GraphLog "если это ПРИЁМКА, а не итерация — запусти с -GraphArgs '{\"scope\":\"product\"}': отсутствующую функциональность в диффе не видно"
    return @{ findings = @(); reason = 'нет изменений в продуктовом коде' }
}
Write-GraphLog "под ревью: $($prodOnly.Count) файлов`n$diffStat"

Set-GraphVar files   ($prodOnly -join ' ')
Set-GraphVar diffCmd $diffCmd
Set-GraphVar scopeWord $(if ($scopeProduct) { 'ПРОДУКТ ЦЕЛИКОМ (не правка): ищи и то, чего нет — отсутствующий шаг пути, заглушку вместо действия, экран без данных' } else { 'ПРАВКА: дефект часто в том, как правка сочетается с окружающим кодом' })

# ---------------------------------------------------------------------------
# Ракурсы искателей. Намеренно НЕ перекрываются: каждый слеп к тому, что видят другие —
# именно непохожесть, а не количество, отличает рой от четырёх копий одного мнения.
#
# Ракурсы ЗАВИСЯТ ОТ ПРОДУКТА: «работа с чужой памятью» бессмысленна для веб-сервиса,
# «границы слоёв» звучат по-разному в монолите и в микросервисах. Поэтому и состав
# ракурсов (config/review-lenses.json), и текст каждого (.claude/agents/critics/<id>.md)
# живут в ПРОЕКТЕ, а движок только спрашивает. Файла в проекте нет — берётся шаблон
# фабрики, и об этом пишется строка в журнал: подмена текста молча читается как
# «проект настроен под себя».
$lensSet = Get-BcfLenses -Root $root -Kind review
foreach ($n in @($lensSet.Notes)) { Write-GraphLog "! ракурсы: $n" }

$LENSES = @()
foreach ($lens in @($lensSet.Lenses)) {
    $ct = Get-BcfCriticText -Lens $lens -Root $root
    if ($ct.Note) { Write-GraphLog "! $($ct.Note)" }
    if (-not $ct.Text) { continue }
    # Текст читается ОДИН раз на прогон и едет полем Text: раундов поиска несколько, и
    # перечитывать файл (а с ним и предупреждать про шаблон фабрики) на каждом — шум.
    $LENSES += [pscustomobject]@{
        Id = [string]$lens.Id; Owner = [string]$lens.Owner; Blocking = [bool]$lens.Blocking
        Text = $ct.Text; Source = $ct.Source
    }
}
if (-not $LENSES.Count) {
    Write-GraphLog "ни у одного ракурса нет текста — ни в проекте, ни в шаблонах фабрики; смотреть нечем"
    # «findings = 0» здесь означало бы «посмотрели и не нашли», хотя не смотрел никто:
    # graph.ps1 читает это поле и печатал «итог: ок». criticsExpected + criticsRun = 0
    # разводят два разных нуля — «чисто» и «некому было смотреть».
    return @{ findings = 0; criticsExpected = $true; criticsRun = 0
              criticsReason = 'ракурсы ревью не заданы: текста нет ни в .claude/agents/critics/, ни в шаблонах фабрики'
              reason = 'ракурсы не заданы' }
}
Write-GraphLog ("ракурсы ревью: $($LENSES.Count) из $(if ($lensSet.FromProject) { 'config/review-lenses.json' } else { 'умолчания фабрики' })" +
                ", блокирующих $(@($LENSES | Where-Object { $_.Blocking }).Count)")

$seen = @{}          # ключ находки → уже видели (включая ОТКЛОНЁННЫЕ — иначе цикл не сойдётся)
$confirmed = @()
$dryRounds = 0
$round = 0

# Контракты узлов закрытые (additionalProperties: false). Открытый контракт позволяет
# узлу доложить в ответ что угодно сверх схемы, и это молча поедет по ребру дальше.
$FIND_SCHEMA = @{
    type = 'object'; required = @('findings'); additionalProperties = $false
    properties = @{ findings = @{ type = 'array'; items = @{
        type = 'object'; required = @('file', 'line', 'severity', 'title', 'why'); additionalProperties = $false
        properties = @{
            file = @{ type = 'string' }; line = @{ type = 'integer' }
            severity = @{ type = 'string'; enum = @('высокая', 'средняя', 'низкая') }
            title = @{ type = 'string' }; why = @{ type = 'string' }
        } } } }
}
$REFUTE_SCHEMA = @{
    type = 'object'; required = @('refuted', 'why'); additionalProperties = $false
    properties = @{ refuted = @{ type = 'boolean' }; why = @{ type = 'string' } }
}
# Схема кладётся в захват ДО первого веера: ветки живут в чужих runspace и видят только
# то, что было положено сюда заранее. Схему искателей кладёт туда же общая сборка ракурсов
# (harness/lib/critics.ps1) — здесь остался барьер опровергателей, у него схема своя.
Set-GraphVar refuteSchema $REFUTE_SCHEMA

# ---------------------------------------------------------------------------
Set-Phase 'Маршрут'
# ---------------------------------------------------------------------------
# РОУТЕР. Классифицирует агент, но ребро выбирает КОД — поэтому одинаковая
# классификация всегда даёт одинаковый маршрут, и «модель решила пропустить аудит»
# случиться не может: пропуск пришлось бы вписать в граф, а его там нет.
#
# Зачем вообще: до этого ревью гоняло четыре ракурса раундами до исчерпания на ЛЮБОЙ
# правке. На однострочном фиксе это сжигание бюджета, на правке в тысячу строк —
# недобор. Граф жжёт кратно больше токенов, чем один агент, и единственное, что делает
# его окупаемым, — не платить полную цену там, где она не нужна.
$loc = 0
foreach ($f in $prodOnly) {
    $n = (& git -C $root diff --numstat $(if ($base) { $base } else { 'HEAD' }) -- $f 2>$null | Select-Object -First 1)
    if ($n -match '^(\d+)\s+(\d+)') { $loc += [int]$Matches[1] + [int]$Matches[2] }
}
Write-GraphLog "объём правки: $($prodOnly.Count) файлов, ~$loc строк"

$ROUTE_SCHEMA = @{
    type = 'object'; required = @('risk', 'why'); additionalProperties = $false
    properties = @{ risk = @{ type = 'string'; enum = @('низкий', 'высокий') }; why = @{ type = 'string' } }
}
$route = if ($scopeProduct) { $null } else { Invoke-Node -Role planner -Label 'роутер-риск' -Schema $ROUTE_SCHEMA -Prompt @"
Оцени РИСК этой правки, ничего не проверяя по существу — это работа следующих узлов.

Файлы: $($prodOnly -join ' ')
Объём: ~$loc изменённых строк
Сводка: $diffStat

«высокий» — если тронуто хоть что-то из: unsafe/WinAPI, работа с чужой памятью,
контракт CLI или формата скила, публичные сигнатуры ядра, обработка ошибок.
«низкий» — косметика, тексты, локальный рефакторинг без смены поведения.
Сомневаешься — «высокий».
"@ }

# Решение принимает код. Дешёвая правка не заслуживает полного роя, но «дешёвая» —
# это И маленькая, И признанная безопасной: любого одного признака мало.
$heavy = $true
if ($route -and $route.risk -eq 'низкий' -and $loc -le 150) { $heavy = $false }
# Приёмка продукта лёгкой не бывает: там $loc = 0 (диффа нет), и роутер честно назвал бы
# правку дешёвой — то есть режим сам себя бы и отключил.
if ($scopeProduct) { $heavy = $true }
# Лёгкий маршрут отбирал ракурсы по ключам @('память','гейты'). Ключа 'память' в наборе
# по умолчанию нет — он остался от набора другого проекта. Фильтр молча оставлял ОДИН
# ракурс вместо двух, и лёгкое ревью полгода было вдвое слабее заявленного. Поэтому здесь
# отбор по имени ПЛЮС фолбэк по позиции: набор не может тихо схлопнуться, что бы ни лежало
# в config/review-lenses.json. 'journey' в лёгком наборе обязателен — именно дешёвые с
# виду правки чаще всего и оставляют пользователя без пути.
$LITE_KEYS = @('gates', 'journey')
$LENSES_USED = if ($heavy) { $LENSES } else {
    $lite = @($LENSES | Where-Object { $_.Id -in $LITE_KEYS })
    if ($lite.Count -lt 2) { $lite = @($LENSES | Select-Object -First ([Math]::Min(2, $LENSES.Count))) }
    $lite
}
$MAX_DRY     = if ($heavy) { 2 } else { 1 }
Write-GraphLog "маршрут: $(if ($heavy) { 'ПОЛНЫЙ' } else { 'ЛЁГКИЙ' }) — риск '$(if ($route) { $route.risk } else { 'неизвестен' })', ~$loc строк → ракурсов $($LENSES_USED.Count), пустых раундов до останова $MAX_DRY"
if ($route) { Write-GraphLog "  обоснование: $($route.why)" }

# Цикл «до исчерпания»: простой счётчик раундов упускает хвост, а условие «два раунда
# подряд без нового» останавливается там, где новое действительно кончилось.
while ($dryRounds -lt $MAX_DRY) {
    $round++
    if ((Get-GraphRemaining) -lt 40000) { Write-GraphLog "бюджет на исходе — останавливаю поиск после раунда $round"; break }

    Set-Phase 'Поиск'
    Write-GraphLog "раунд $round (раундов без нового подряд: $dryRounds)"
    Set-GraphVar round $round
    Set-GraphVar known (@($seen.Keys) -join ' | ')

    # Промпты собирает общая функция — та же, что у приёмки. Текст ракурса уже прочитан
    # выше (он не меняется между раундами), поэтому сюда он приходит готовым, полем Text.
    $built = Build-BcfCriticPrompts -Lenses $LENSES_USED -Root $root `
                -Header 'Ты ищешь дефекты в изменённом коде. Твой РАКУРС — только этот, остальные смотрят другие:' `
                -Tail @"

Область: $(Get-GraphVar scopeWord)
Файлы: $(Get-GraphVar files)
История правок: $(Get-GraphVar diffCmd) <файл>

Уже найдено другими (НЕ повторяй, ищи новое):
$(Get-GraphVar known)

Читай сам код, а не только диф.
Каждая находка — с точным файлом и строкой. Не нашёл нового — верни пустой список.
"@
    $LENSES_ROUND = @($built.Lenses)
    $batches = @(Invoke-BcfCriticBarrier -Lenses $LENSES_ROUND -Prompts @($built.Prompts) `
                    -LabelPrefix 'искатель' -LabelSuffix "р$round" -Schema $FIND_SCHEMA)

    # Дедуп по ВСЕМУ увиденному.
    #
    # РАКУРС ЕДЕТ ВМЕСТЕ С НАХОДКОЙ. Без него в отчёте стоит «нашёл искатель», спросить по
    # находке некого, и главное — нечем отличить находку блокирующего ракурса от находки
    # совещательного, то есть вердикт считать не по чему. Порядок ответов барьера совпадает
    # с порядком ракурсов — на этом соответствие и держится.
    $fresh = @()
    for ($bi = 0; $bi -lt @($batches).Count; $bi++) {
        $b = @($batches)[$bi]
        if (-not $b -or ($b -is [string]) -or (-not $b.PSObject.Properties['findings'])) { continue }
        $lens = $LENSES_ROUND[$bi]
        foreach ($f in @($b.findings)) {
            if (-not $f -or -not $f.file) { continue }
            $key = "$($f.file):$($f.line):$(($f.title -replace '\s+', ' ').ToLower())"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $f | Add-Member -NotePropertyName 'lens'     -NotePropertyValue ([string]$lens.Id) -Force
            $f | Add-Member -NotePropertyName 'owner'    -NotePropertyValue ([string]$lens.Owner) -Force
            $f | Add-Member -NotePropertyName 'blocking' -NotePropertyValue ([bool]$lens.Blocking) -Force
            $fresh += $f
        }
    }
    Write-GraphLog "раунд ${round}: новых находок $($fresh.Count), всего просмотрено $($seen.Count)"
    if (-not $fresh.Count) { $dryRounds++; continue }
    $dryRounds = 0

    Set-Phase 'Проверка'
    # Три опровергателя на находку, углы РАЗНЫЕ. Проходит только то, что пережило
    # большинство: две попытки опровержения из трёх должны провалиться.
    $verdicts = Invoke-Pipeline -Items $fresh -Stages @(
        {
            param($prev, $f)
            $angles = @(
                @{ k = 'код';   q = 'Открой файл и убедись, что описанный код там ДЕЙСТВИТЕЛЬНО такой. Чаще всего находка ссылается на строку, которой нет, или на код, который делает не то.' }
                @{ k = 'путь';  q = 'Построй конкретный путь исполнения, на котором дефект проявляется: входные данные, состояние, результат. Не построил — значит, дефекта нет.' }
                @{ k = 'умысел'; q = 'Проверь, не является ли это осознанным решением: комментарий рядом, инвариант в CLAUDE.md, требование архитектуры. Осознанное решение дефектом не является.' }
            )
            $votes = Invoke-Barrier -Thunks @($angles | ForEach-Object {
                $a = $_
                [scriptblock]::Create(@"
                    Invoke-Node -Role critic -Label 'опроверг-$($a.k)' -Schema (Get-GraphVar refuteSchema) -Prompt @'
ОПРОВЕРГНИ находку. Твоя работа — показать, что её НЕТ, а не согласиться.

Находка: $($f.title)
Файл: $($f.file), строка $($f.line)
Обоснование автора: $($f.why)

Твой угол: $($a.q)

Сомневаешься — считай ОПРОВЕРГНУТОЙ (refuted: true). Ложная находка дороже пропущенной:
она отправляет людей чинить то, что не сломано.
'@
"@)
            })
            $ok = @($votes | Where-Object { $_ })
            $refutedCount = @($ok | Where-Object { $_.refuted }).Count
            $survives = ($ok.Count -ge 2) -and ($refutedCount -lt 2)
            return @{ Finding = $f; Survives = $survives; Refuted = $refutedCount; Voted = $ok.Count
                      Why = (@($ok | Where-Object { $_.refuted } | ForEach-Object { $_.why }) -join ' / ') }
        }
    )

    foreach ($v in @($verdicts | Where-Object { $_ })) {
        if ($v.Survives) {
            $confirmed += $v.Finding
            Write-GraphLog "✓ выжила: $($v.Finding.file):$($v.Finding.line) — $($v.Finding.title)"

            # ГЛАВНЫЙ НОВЫЙ ИСТОЧНИК УРОКОВ. У цикла ничего похожего не было: он умел
            # записывать только «итерация не удалась». Здесь в память попадает находка,
            # которая пережила попытку ТРЁХ разных ракурсов её опровергнуть, — то есть
            # утверждение с доказательством, а не догадка модели.
            $res = Add-GraphLesson -Scope 'code' `
                -Trigger "$($v.Finding.title) (в $($v.Finding.file))" `
                -WentWrong $v.Finding.why `
                -Evidence @{ file = $v.Finding.file; line = $v.Finding.line; severity = $v.Finding.severity
                             run = (Get-GraphRunId); voted = $v.Voted; refuted = $v.Refuted }
            if ($res -eq 'new') { Write-GraphLog "  урок записан в память" }
        } else {
            Write-GraphLog "· отклонена ($($v.Refuted)/$($v.Voted) опровергли): $($v.Finding.title) — $($v.Why)"
        }
    }
}

# ---------------------------------------------------------------------------
Set-Phase 'Сведение'
# ---------------------------------------------------------------------------
$reportFile = Join-Path $root '.bcf\REVIEW-graph.md'
if (-not $confirmed.Count) {
    Write-GraphLog "подтверждённых находок нет (просмотрено $($seen.Count), все отклонены проверкой)"
    Set-Content -LiteralPath $reportFile -Encoding UTF8 -Value (
        "# Ревью графом`n`n**Просмотрено находок:** $($seen.Count)`n**Подтверждено:** 0`n`n" +
        "Все находки не пережили состязательную проверку. Раундов: $round.`n")
    return @{ findings = @(); seen = $seen.Count; rounds = $round }
}

# Блокирующие и совещательные разведены: вердикт прогона считается по блокирующим, а
# совещательные печатаются целиком и названы совещательными — иначе человек читает их как
# требования и чинит то, о чём его не просили.
$confirmedBlocking = @($confirmed | Where-Object { $_.blocking })
$confirmedAdvisory = @($confirmed | Where-Object { -not $_.blocking })
function _ReviewLine($f) {
    $who = if ($f.owner) { ", отвечает $($f.owner)" } else { '' }
    return "- [$($f.severity)] $($f.file):$($f.line) — $($f.title) (ракурс $($f.lens)$who)`n  $($f.why)"
}
$listing = (@($confirmedBlocking | ForEach-Object { _ReviewLine $_ }) -join "`n")
if (-not $confirmedBlocking.Count) { $listing = '- (блокирующих находок нет)' }
$listingAdvisory = if ($confirmedAdvisory.Count) {
    "`n## Совещательные ракурсы (на вердикт не влияют)`n`n" +
    (@($confirmedAdvisory | ForEach-Object { _ReviewLine $_ }) -join "`n") + "`n"
} else { '' }
$summary = Invoke-Node -Role planner -Label 'сведение' -Prompt @"
Ниже находки, пережившие состязательную проверку (каждую пытались опровергнуть с трёх
разных углов, и опровержение не набрало большинства).

$listing
$listingAdvisory

Сведи их в один отчёт: сгруппируй по смыслу, отсортируй по реальному риску, слей
дубликаты, сказанные разными словами. Для каждой — что чинить, одной строкой.
Не добавляй находок от себя: их никто не проверял.
"@

Set-Content -LiteralPath $reportFile -Encoding UTF8 -Value (
    "# Ревью графом`n`n" +
    "**Просмотрено находок:** $($seen.Count)`n**Подтверждено проверкой:** $($confirmed.Count) " +
    "(блокирующих $($confirmedBlocking.Count), совещательных $($confirmedAdvisory.Count))`n" +
    "**Раундов поиска:** $round`n`n" +
    "## Сведение`n`n$summary`n`n## Находки как есть`n`n$listing`n$listingAdvisory")

Write-GraphLog ("отчёт: .bcf/REVIEW-graph.md — подтверждено $($confirmed.Count) из $($seen.Count) просмотренных " +
                "(блокирующих $($confirmedBlocking.Count), совещательных $($confirmedAdvisory.Count))")
# `findings` читает graph.ps1 и по нему решает вердикт прогона — значит туда идут только
# блокирующие ракурсы. Совещательные видны отдельным полем и в отчёте.
return @{ findings = $confirmedBlocking.Count; advisory = $confirmedAdvisory.Count
          seen = $seen.Count; rounds = $round; report = '.bcf/REVIEW-graph.md' }


