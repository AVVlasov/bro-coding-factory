# bcf prd — четыре вопроса о продукте → docs/PRD.md.
#
#   bcf prd            задать вопросы и записать ответы
#   bcf prd --show     показать текущий PRD и чего в нём не хватает
#
# ЗАЧЕМ ИМЕННО ЧЕТЫРЕ ВОПРОСА. Без них планировщик нарежет задачи ПО КОДУ, а не по
# продукту — и первая же приёмка будет спорить с ним о смысле, за твои деньги. Четыре
# ответа закрывают ровно те развилки, которые агент не имеет права решать сам:
#
#   1. кто пользователь и что для него «работает»  — иначе «работает» проверить нечем;
#   2. что входит в MVP                            — иначе объём задачи бесконечен;
#   3. чего в первой версии НЕ делаем              — самый пропускаемый и самый дорогой:
#                                                    без него агент реализует «на всякий случай»;
#   4. чем доказывается закрытая задача            — становится обязательной проверкой
#                                                    в config/checks.json.
#
# Вопросы задаются человеку. Агента здесь нет намеренно: сгенерированный PRD — это
# пересказ кода теми же словами, и спорить с ним приёмка будет ровно так же.

$project = $script:BcfProject
$prdPath = Join-Path $project 'docs\PRD.md'
$show = $script:BcfArgs -contains '--show'

$QUESTIONS = @(
    @{ key = 'Кто пользователь и что для него «работает»'
       hint = 'один человек, одна ситуация. «Работает» = что он смог сделать, а не какая функция появилась.'
       example = 'моддер-одиночка. работает = нашёл значение и правит его в игре, не читая исходники игры' }
    @{ key = 'Что входит в MVP'
       hint = 'список из 3–6 пунктов. Если пунктов больше — это не MVP, а план года.'
       example = 'скан, правка, один скил под одну игру, оболочка показывает найденное' }
    @{ key = 'Что явно НЕ делаем в первой версии'
       hint = 'самый пропускаемый раздел и самый дорогой: без него агент реализует «на всякий случай».'
       example = 'обход анти-читов, режим ядра, профили на несколько игр' }
    @{ key = 'Чем доказывается закрытая задача'
       hint = 'это станет обязательной проверкой в config/checks.json — формулируй командой, а не словами.'
       example = 'тесты модуля на живом процессе, без моков' }
)

if ($show) {
    Write-BcfTitle 'PRD' $prdPath
    if (-not (Test-Path $prdPath)) {
        Write-BcfFail 'docs/PRD.md нет'
        Write-BcfNote 'заполнить: bcf prd'
        exit 2
    }
    $body = Get-Content -Raw -LiteralPath $prdPath
    $missing = @()
    foreach ($q in $QUESTIONS) {
        if ($body -notmatch [regex]::Escape($q.key)) { $missing += $q.key }
    }
    Write-Host ($body -split "`r?`n" | Select-Object -First 40 | Out-String)
    if ($missing.Count) {
        Write-BcfWarn "не отвечено: $($missing.Count) из $($QUESTIONS.Count)"
        foreach ($m in $missing) { Write-BcfNote $m }
    } else { Write-BcfOk 'все четыре вопроса закрыты' }
    Write-Host ''
    exit 0
}

Write-BcfTitle 'ОПРОС ПО ПРОДУКТУ' "4 вопроса · ответы правятся потом · черновик → docs/PRD.md"

if (Test-Path $prdPath) {
    Write-BcfWarn 'docs/PRD.md уже есть — новые ответы допишутся в конец, старое не тронем'
    Write-Host ''
}

# В режиме без вопросов писать за человека нечего: PRD — единственный документ, который
# нельзя заполнить значением по умолчанию. Заготовка с вопросами честнее выдуманных
# ответов, и это прямо говорится.
if (Get-BcfAssumeYes) {
    $stub = "# PRD — $(Split-Path $project -Leaf)`n`n> Заготовка, созданная ``bcf prd --yes``. Ответов нет: их не может дать никто, кроме владельца продукта.`n"
    foreach ($q in $QUESTIONS) {
        $stub += "`n## $($q.key)`n`n_(не отвечено)_`n`n> $($q.hint)`n> Пример: $($q.example)`n"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $prdPath -Parent) | Out-Null
    if (Test-Path $prdPath) { Add-Content -LiteralPath $prdPath -Value $stub -Encoding UTF8 }
    else { Set-Content -LiteralPath $prdPath -Value $stub -Encoding UTF8 }
    Write-BcfWarn 'режим без вопросов: записана ЗАГОТОВКА с вопросами, а не ответы'
    Write-BcfNote 'пока она не заполнена, планировщик режет задачи по коду, а не по продукту.'
    Write-BcfNote "заполнить: bcf prd (без --yes) или руками — $prdPath"
    Write-Host ''
    exit 0
}

$answers = @()
$i = 0
foreach ($q in $QUESTIONS) {
    $i++
    Write-Host ''
    Write-BcfLine "  $i/$($QUESTIONS.Count)  $($q.key)?" 'White'
    Write-BcfNote $q.hint
    Write-BcfNote "пример: $($q.example)"
    $a = Read-Host '  ответ (пусто = пропустить)'
    $answers += [pscustomobject]@{ Q = $q; A = $a.Trim() }
}

$answered = @($answers | Where-Object { $_.A })
$doc = "`n# PRD — $(Split-Path $project -Leaf)`n`n> Собрано ``bcf prd`` $(Get-Date -Format 'yyyy-MM-dd'). Правится руками.`n"
foreach ($x in $answers) {
    $doc += "`n## $($x.Q.key)`n`n"
    if ($x.A) { $doc += "$($x.A)`n" }
    else { $doc += "_(не отвечено)_`n`n> $($x.Q.hint)`n" }
}

New-Item -ItemType Directory -Force -Path (Split-Path $prdPath -Parent) | Out-Null
if (Test-Path $prdPath) { Add-Content -LiteralPath $prdPath -Value $doc -Encoding UTF8 }
else { Set-Content -LiteralPath $prdPath -Value $doc.TrimStart() -Encoding UTF8 }

Write-Host ''
Write-BcfOk "записано: docs/PRD.md ($($answered.Count) из $($QUESTIONS.Count) ответов)"

if ($answered.Count -lt $QUESTIONS.Count) {
    Write-BcfWarn "не отвечено: $($QUESTIONS.Count - $answered.Count)"
    Write-BcfNote 'пропущенный вопрос не исчезает — он всплывёт на приёмке в виде спора о смысле.'
}

# Четвёртый ответ — единственный, который превращается в исполняемый гейт. Напоминаем
# об этом прямо: PRD, не доехавший до config/checks.json, остаётся пожеланием.
$proof = @($answers | Where-Object { $_.Q.key -like 'Чем доказывается*' -and $_.A }) | Select-Object -First 1
if ($proof) {
    Write-Host ''
    Write-BcfLine '  ЭТОТ ОТВЕТ ОБЯЗАН СТАТЬ ПРОВЕРКОЙ' 'White'
    Write-BcfNote "«$($proof.A)»"
    Write-BcfNote 'впиши его командой в config/checks.json → _default (или под ключ задачи).'
    Write-BcfNote 'Без этого он остаётся пожеланием: общие проверки зелены и на пустом месте.'
}
Write-Host ''
exit 0
