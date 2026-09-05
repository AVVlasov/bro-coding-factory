# critics-in-project.tests.ps1 — ракурсы приёмки принадлежат проекту, а не движку.
#
#   pwsh tests/critics-in-project.tests.ps1
#
# ЧТО ЗДЕСЬ ДОКАЗЫВАЕТСЯ И ПОЧЕМУ ИМЕННО ЭТО.
#
# 1. Текст критика читается ИЗ ПРОЕКТА и доезжает до промпта узла. Пока тексты лежали
#    строками внутри графа, приёмка чужого продукта шла вопросами, написанными под другой
#    продукт: критик отвечал «указанные требования неприменимы» и сжигал треть круга.
#    Проверяется не наличие файла, а то, что его текст оказался в промпте настоящего узла —
#    через подставного исполнителя (BCF_GRAPH_FAKE_AGENT), то есть на настоящем барьере.
#
# 2. Подмена текста шаблоном фабрики ГРОМКАЯ. Молчаливый фолбэк читается как «проект
#    настроен под себя», и разбор чужой приёмки начинается с поиска текста, которого в
#    проекте нет. Негативная половина теста важнее позитивной: у ракурса, чей файл в
#    проекте есть, предупреждения быть НЕ ДОЛЖНО.
#
# 3. Блокирующий ракурс роняет вердикт, совещательный — нет. Пока все ракурсы весили
#    одинаково, ракурс, заведённый «посмотреть», ронял прогон наравне с требованием
#    заказчика — и его переставали заводить. Проверять это по краям цепочки мало: свод
#    считает одна функция, отчёт печатает другая, а КАКОЕ из двух чисел уедет в вердикт,
#    решает строка графа между ними. Поэтому блок вердикта вырезается из файла графа
#    разборщиком PowerShell и исполняется целиком — от Measure-BcfAcceptance до
#    настоящего Emit-RunAllReport, пишущего .bcf/REVIEW.md и run-all.status.json.
#
# 4. Номера требований заказчика разбираются из задачи. Зона чтения сужена намеренно, и
#    негативные случаи здесь главные: широкий разбор превратил бы столбец требований в
#    мусор — задача с командой `pkg@3.1.1` объявила бы себя закрывающей требование 3.1.1.
#    Каждая охрана сторожится своей фикстурой: строка «Требование:» ниже первой секции,
#    жирный номер внутри блока кода, буллет с номером без жирного. Фикстура, которая
#    проходит по другой причине (номер с нумерацией «1. », который регексп не берёт и без
#    охраны), сторожем не является — она была здесь и молчала на всех трёх мутациях.
#
# 5. Вердикт называет, чем он получен: версия фабрики и хэш файла графа.
#
# Ни одного обращения к модели: исполнитель узла подменён, отчёт считается headless.

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path $PSScriptRoot -Parent          # корень фабрики
$bcf  = Join-Path $root 'bin\bcf.ps1'
$runAll = Join-Path $root 'harness\run-all.ps1'
$box = Join-Path ([IO.Path]::GetTempPath()) ("bcf-critics-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $box | Out-Null

# Фабрика и проект называются ЯВНО. Иначе тест читает шаблоны той установки, которая
# прописана в окружении машины, и краснеет (или зеленеет) по чужим файлам.
$env:BCF_HOME = $root
$env:BCF_PROJECT_ROOT = $box
$env:BCF_MEMORY_DISABLED = '1'

. (Join-Path $root 'harness\lib\bcf-context.ps1')
. (Join-Path $root 'harness\lib\agent-sandbox.ps1')
. (Join-Path $root 'harness\lib\fleet.ps1')
. (Join-Path $root 'harness\lib\claims.ps1')
. (Join-Path $root 'harness\lib\worktree.ps1')
. (Join-Path $root 'harness\lib\graph-runtime.ps1')
. (Join-Path $root 'harness\lib\graph-memory.ps1')
. (Join-Path $root 'harness\lib\critics.ps1')
. (Join-Path $root 'harness\lib\requirement.ps1')

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ok   $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ПРОВАЛ  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Assert-True  { param($Cond, [string]$Msg = 'ожидалось истинное')  if (-not $Cond) { throw $Msg } }
function Assert-False { param($Cond, [string]$Msg = 'ожидалось ложное')    if ($Cond) { throw $Msg } }
function Assert-Eq {
    param($Actual, $Expected, [string]$Msg = '')
    if ("$Actual" -ne "$Expected") { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "ждал «$Expected», получил «$Actual»") }
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" +
               (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 15) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

function New-Project {
    param([string]$Name)
    $p = Join-Path $box $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'config') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'tasks') | Out-Null
    '{ "limits": { "agentConcurrency": 4 }, "timeouts": { "stepSec": 60, "silentSec": 30 } }' |
        Set-Content -LiteralPath (Join-Path $p 'config\harness.json') -Encoding UTF8
    return $p
}
function Set-Lenses {
    param([string]$Project, [string]$Json)
    Set-Content -LiteralPath (Join-Path $Project 'config\review-lenses.json') -Value $Json -Encoding UTF8
}
function Set-Critic {
    param([string]$Project, [string]$Id, [string]$Body)
    $d = Join-Path $Project '.claude\agents\critics'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d "$Id.md") -Value $Body -Encoding UTF8
}

Write-Host ''
Write-Host "  РАКУРСЫ В ПРОЕКТЕ   песочница: $box" -ForegroundColor Cyan

# --- 1. Состав ракурсов ------------------------------------------------------------------
Write-Host ''
Write-Host '1. Состав ракурсов: умолчание фабрики и запись проекта' -ForegroundColor White

$p1 = New-Project 'lenses'

It 'без конфига берутся ракурсы приёмки по умолчанию' {
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-False $s.FromProject 'ракурсы объявлены проектными, хотя конфига нет'
    Assert-Eq @($s.Lenses).Count 4
    Assert-Eq (@($s.Lenses | ForEach-Object { $_.Id }) -join ',') 'invariants,seams,gates,journey'
    Assert-True (@($s.Lenses | Where-Object { $_.Blocking }).Count -eq 4) 'умолчание перестало быть блокирующим'
}

It 'у ревью свой набор по умолчанию' {
    $s = Get-BcfLenses -Root $p1 -Kind review
    Assert-Eq (@($s.Lenses | ForEach-Object { $_.Id }) -join ',') 'correctness,failures,boundaries,gates,journey'
}

It 'запись внешней рассылки правил разобрана, лишние поля не мешают' {
    Set-Lenses $p1 '[{"id":"java","owner":"лидер java","blocking":true,"file":".claude/agents/testers/java.md","rules":7}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-True $s.FromProject 'конфиг проекта не прочитан'
    Assert-Eq @($s.Lenses).Count 1
    Assert-Eq $s.Lenses[0].Id 'java'
    Assert-Eq $s.Lenses[0].Owner 'лидер java'
    Assert-Eq $s.Lenses[0].Blocking 'True'
    Assert-Eq $s.Lenses[0].File '.claude/agents/testers/java.md'
}

It 'без поля blocking ракурс считается блокирующим' {
    # Обратный дефолт молча снимал бы ракурс с вердикта: находки печатаются, прогон зелёный.
    Set-Lenses $p1 '[{"id":"java","owner":"лидер java"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq $s.Lenses[0].Blocking 'True'
}

It 'blocking:false делает ракурс совещательным' {
    Set-Lenses $p1 '[{"id":"java","blocking":false}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq $s.Lenses[0].Blocking 'False'
}

It 'blocking понимается и строкой' {
    Set-Lenses $p1 '[{"id":"a","blocking":"false"},{"id":"b","blocking":"да"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq $s.Lenses[0].Blocking 'False'
    Assert-Eq $s.Lenses[1].Blocking 'True'
}

It 'обёртка {"lenses": [...]} читается наравне с массивом' {
    Set-Lenses $p1 '{"$comment":"пояснение","lenses":[{"id":"java"},{"id":"ui"}]}'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq @($s.Lenses).Count 2
}

It 'битый JSON не выключает приёмку молча' {
    Set-Lenses $p1 '{ это не json'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-False $s.FromProject
    Assert-Eq @($s.Lenses).Count 4 'после битого конфига не осталось ни одного ракурса'
    Assert-Match ($s.Notes -join ' ') 'не разобран' 'о битом конфиге не сказано ни слова'
}

It 'запись без id пропущена, и сказано почему' {
    Set-Lenses $p1 '[{"owner":"никто"},{"id":"gates"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq @($s.Lenses).Count 1
    Assert-Match ($s.Notes -join ' ') 'без id'
}

It 'дубль id берётся один раз' {
    Set-Lenses $p1 '[{"id":"gates","owner":"первый"},{"id":"gates","owner":"второй"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq @($s.Lenses).Count 1
    Assert-Eq $s.Lenses[0].Owner 'первый'
    Assert-Match ($s.Notes -join ' ') 'дважды'
}

It 'kind сужает ракурс до одного графа, а без kind ракурс идёт в оба' {
    # Каждый ракурс — отдельный вызов агента на каждый круг. Один файл на два графа без
    # области сделал бы приёмку дороже, чем она была до появления конфига.
    Set-Lenses $p1 '[{"id":"seams","kind":"acceptance"},{"id":"failures","kind":"review"},{"id":"gates"}]'
    Assert-Eq ((Get-BcfLenses -Root $p1 -Kind acceptance).Lenses.Id -join ',') 'seams,gates'
    Assert-Eq ((Get-BcfLenses -Root $p1 -Kind review).Lenses.Id -join ',') 'failures,gates'
}

It 'непонятая область не выбрасывает ракурс молча' {
    Set-Lenses $p1 '[{"id":"gates","kind":"кудато"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-Eq @($s.Lenses).Count 1 'ракурс исчез из-за опечатки в необязательном поле'
    Assert-Match ($s.Notes -join ' ') 'область'
}

It 'в конфиге только чужой граф — берутся умолчания, и об этом сказано' {
    Set-Lenses $p1 '[{"id":"failures","kind":"review"}]'
    $s = Get-BcfLenses -Root $p1 -Kind acceptance
    Assert-False $s.FromProject
    Assert-Eq @($s.Lenses).Count 4
    Assert-Match ($s.Notes -join ' ') 'ни одного ракурса'
}

It 'шаблон фабрики не делает приёмку дороже умолчания' {
    # Этот шаблон кладёт в проект `bcf install`, и после установки он становится ЕДИНСТВЕННЫМ
    # источником состава. Без областей все семь ракурсов уехали бы в оба графа: приёмка
    # 4 → 7 вызовов на круг, и подорожала бы она молча.
    $tpl = Join-Path $root 'templates\config\review-lenses.json'
    $a = Get-BcfLenses -Root $p1 -Kind acceptance -ConfigFile $tpl
    $r = Get-BcfLenses -Root $p1 -Kind review     -ConfigFile $tpl
    Assert-Eq ($a.Lenses.Id -join ',') 'invariants,seams,gates,journey'
    Assert-Eq ($r.Lenses.Id -join ',') 'correctness,failures,boundaries,gates,journey'
    Assert-True $a.FromProject 'шаблон не прочитан как состав проекта'
    Assert-Eq (@($a.Notes).Count) 0 "разбор шаблона фабрики жалуется: $($a.Notes -join '; ')"
}

It 'каждому ракурсу шаблона есть текст в фабрике' {
    # Иначе установка кладёт в проект состав, половина которого пропускается на прогоне
    # со строкой «ракурс пропущен» — и приёмка тише, чем объявлена.
    $tpl = Join-Path $root 'templates\config\review-lenses.json'
    foreach ($k in @('acceptance', 'review')) {
        foreach ($lens in @((Get-BcfLenses -Root $p1 -Kind $k -ConfigFile $tpl).Lenses)) {
            $f = Join-Path $root "templates\claude\agents\critics\$($lens.Id).md"
            Assert-True (Test-Path -LiteralPath $f) "ракурс $($lens.Id) объявлен в шаблоне конфига, а текста в фабрике нет"
        }
    }
}

# --- 2. Текст ракурса --------------------------------------------------------------------
Write-Host ''
Write-Host '2. Текст ракурса: файл проекта, шаблон фабрики, подстановки' -ForegroundColor White

$p2 = New-Project 'text'
Set-Critic $p2 'gates' "---`nname: gates`ndescription: служебная шапка`n---`n`nМАРКЕР-ПРОЕКТА-ГЕЙТЫ: смотри только на честность тестов."

It 'текст берётся из файла проекта, YAML-шапка в промпт не едет' {
    $lens = [pscustomobject]@{ Id = 'gates'; Owner = ''; Blocking = $true; File = ''; Ask = '' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2
    Assert-Eq $t.Source 'проект'
    Assert-Match $t.Text 'МАРКЕР-ПРОЕКТА-ГЕЙТЫ'
    Assert-NoMatch $t.Text 'description:' 'служебная шапка роли уехала в вопрос критику'
    Assert-Eq $t.Note '' 'о файле проекта предупреждать не о чем'
}

It 'файла в проекте нет — берётся шаблон фабрики, и это сказано вслух' {
    $lens = [pscustomobject]@{ Id = 'seams'; Owner = ''; Blocking = $true; File = ''; Ask = '' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2
    Assert-Eq $t.Source 'фабрика'
    Assert-Match $t.Text 'СЕМАНТИКА СКЛЕЙКИ'
    Assert-Match $t.Note 'шаблона фабрики'
}

It 'поле file указывает, откуда брать текст' {
    $d = Join-Path $p2 '.claude\agents\testers'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'java.md') -Value 'МАРКЕР-ТЕСТЕРА-JAVA' -Encoding UTF8
    $lens = [pscustomobject]@{ Id = 'java'; Owner = ''; Blocking = $true; File = '.claude/agents/testers/java.md'; Ask = '' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2
    Assert-Match $t.Text 'МАРКЕР-ТЕСТЕРА-JAVA'
    Assert-Eq $t.Note ''
}

It 'подстановка прогона попадает в текст ракурса' {
    $lens = [pscustomobject]@{ Id = 'invariants'; Owner = ''; Blocking = $true; File = ''; Ask = '' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2 -Values @{ INVARIANT_SOURCES = '- CLAUDE.md проекта' }
    Assert-Match $t.Text 'CLAUDE.md проекта'
    Assert-NoMatch $t.Text '\{\{INVARIANT_SOURCES\}\}' 'подстановка осталась плейсхолдером'
}

It 'нет ни файла, ни шаблона — ракурс объявлен без текста, а не выдуман' {
    $lens = [pscustomobject]@{ Id = 'нетакого'; Owner = ''; Blocking = $true; File = ''; Ask = '' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2
    Assert-Eq $t.Text ''
    Assert-Match $t.Note 'ракурс пропущен'
}

It 'текст из конфига (поле ask) — последний источник' {
    $lens = [pscustomobject]@{ Id = 'нетакого'; Owner = ''; Blocking = $true; File = ''; Ask = 'вопрос прямо из конфига' }
    $t = Get-BcfCriticText -Lens $lens -Root $p2
    Assert-Eq $t.Source 'конфиг'
    Assert-Match $t.Text 'прямо из конфига'
}

# --- 3. Промпт настоящего узла -----------------------------------------------------------
Write-Host ''
Write-Host '3. Критик из файла проекта попадает в промпт узла (подставной исполнитель)' -ForegroundColor White

$fakeAgent = Join-Path $box 'fake-agent.ps1'
@'
function Get-FakeAgentReply {
    param([string]$Prompt, [string]$Label)

    # Промпт узла складывается на диск: только так видно, ЧТО реально доехало до агента.
    if ($env:BCF_TEST_TRACE) {
        $safe = ($Label -replace '[\\/:*?"<>|]', '_')
        $mtx = New-Object System.Threading.Mutex($false, 'Global\bcf-critics-trace')
        [void]$mtx.WaitOne(10000)
        try { Set-Content -LiteralPath (Join-Path $env:BCF_TEST_TRACE "$safe.txt") -Value $Prompt -Encoding UTF8 }
        finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
    }

    if ($Prompt -match 'МОЛЧУ-В-ОТВЕТ') { return @{ Fail = 'подставной отказ' } }
    if ($Prompt -match 'НАЙДИ-ДЕФЕКТ') {
        return @{ Tokens = 7; Text = '{"summary":"смотрел код","findings":[{"severity":"P1","what":"оператор не может записать пациента","file":"src/app.ts","line":10}]}' }
    }
    return @{ Tokens = 5; Text = '{"summary":"смотрел код","findings":[]}' }
}
'@ | Set-Content -LiteralPath $fakeAgent -Encoding UTF8
$env:BCF_GRAPH_FAKE_AGENT = $fakeAgent

$criticSchema = @{
    type = 'object'; required = @('summary', 'findings')
    properties = @{
        summary  = @{ type = 'string' }
        findings = @{ type = 'array'; items = @{
            type = 'object'; required = @('severity', 'what', 'file')
            properties = @{ severity = @{ type = 'string'; enum = @('P1', 'P2', 'P3') }
                            what = @{ type = 'string' }; file = @{ type = 'string' }; line = @{ type = 'integer' } } } }
    }
}

$p3 = New-Project 'prompt'
$trace = Join-Path $p3 'trace'
New-Item -ItemType Directory -Force -Path $trace | Out-Null
$env:BCF_TEST_TRACE = $trace
Set-Critic $p3 'gates' "---`nname: gates`n---`n`nМАРКЕР-ПРОЕКТА-ГЕЙТЫ. Ищи тесты, которые ничего не проверяют."
Set-Lenses $p3 '[{"id":"gates","owner":"лидер java","blocking":true},{"id":"seams","owner":"","blocking":false}]'

$ctx3 = Initialize-GraphRun -Root $p3 -Meta @{ name = 'т'; description = 'т' } -MaxConcurrency 4
$set3 = Get-BcfLenses -Root $p3 -Kind acceptance
$built3 = Build-BcfCriticPrompts -Lenses $set3.Lenses -Root $p3 `
            -Header 'На слитом дереве закрыты задачи: TASK-01.' -Tail 'ФАКТЫ-ОБВЯЗКИ: проверки уже выполнены.'
$ans3 = @(Invoke-BcfCriticBarrier -Lenses $built3.Lenses -Prompts $built3.Prompts -LabelPrefix 'приёмка' -Schema $criticSchema)
$journal3 = (Get-Content -Raw -LiteralPath $ctx3.Journal -Encoding UTF8)

It 'текст критика из файла проекта доехал до промпта узла' {
    $f = Join-Path $trace 'приёмка-gates-a1.txt'
    Assert-True (Test-Path -LiteralPath $f) "узел приёмка-gates не запускался: в $trace нет его промпта"
    Assert-Match (Get-Content -Raw -LiteralPath $f) 'МАРКЕР-ПРОЕКТА-ГЕЙТЫ' 'в промпт уехал не текст проекта'
}

It 'ракурсу без файла в проекте достался текст шаблона фабрики' {
    $f = Join-Path $trace 'приёмка-seams-a1.txt'
    Assert-True (Test-Path -LiteralPath $f)
    Assert-Match (Get-Content -Raw -LiteralPath $f) 'СЕМАНТИКА СКЛЕЙКИ'
}

It 'подмена текста шаблоном фабрики записана в журнал прогона' {
    Assert-Match $journal3 'seams.*шаблона фабрики' 'фолбэк на шаблон прошёл молча'
}

It 'у ракурса с файлом в проекте предупреждения нет' {
    # Негативная половина: предупреждение «на всякий случай» обесценивает предупреждение.
    Assert-NoMatch $journal3 'ракурс gates: в проекте нет' 'предупреждение выдано о файле, который в проекте есть'
}

It 'вес ракурса назван в самом промпте' {
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $trace 'приёмка-gates-a1.txt')) 'БЛОКИРУЮЩИЙ'
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $trace 'приёмка-seams-a1.txt')) 'совещательный'
}

It 'шапка и хвост прогона доехали вместе с ракурсом' {
    $t = Get-Content -Raw -LiteralPath (Join-Path $trace 'приёмка-gates-a1.txt')
    Assert-Match $t 'закрыты задачи: TASK-01'
    Assert-Match $t 'ФАКТЫ-ОБВЯЗКИ'
}

It 'ответы вернулись по схеме, а не прозой' {
    Assert-Eq @($ans3).Count 2
    Assert-True ($null -ne $ans3[0].PSObject.Properties['findings']) 'схема до узла не доехала'
}

It 'несоответствие ракурсов и промптов — отказ, а не тихий сдвиг' {
    # Соответствие «ракурс → ответ» держится на порядке: разъехавшись на один, оно повесит
    # находки блокирующего ракурса на совещательный, и вердикт станет считаться не по тому.
    $err = ''
    try {
        Invoke-BcfCriticBarrier -Lenses @($built3.Lenses) -Prompts @($built3.Prompts[0]) -LabelPrefix 'приёмка'
    } catch { $err = $_.Exception.Message }
    Assert-Match $err 'соответствие' 'сдвиг ракурсов прошёл молча'
}

It 'граф подключает библиотеку ракурсов и называет свой файл' {
    # Оба графа зовут Get-BcfLenses и Invoke-BcfCriticBarrier; выпадет эта строка — оба
    # упадут на первом же прогоне приёмки, а тест на текст ракурса этого не заметит.
    $g = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\graph.ps1')
    Assert-Match $g 'lib\\critics\.ps1' 'graph.ps1 не подключает harness/lib/critics.ps1'
    Assert-Match $g 'BCF_GRAPH_FILE' 'граф не сообщает потомкам, каким файлом он гоняется'
}

# --- 4. Вес ракурса: блокирующий и совещательный ------------------------------------------
Write-Host ''
Write-Host '4. Блокирующий ракурс роняет вердикт, совещательный — нет' -ForegroundColor White

function New-Answer {
    param([string]$Severity = 'P1', [string]$What = 'оператор не может записать пациента')
    return ('{"summary":"смотрел","findings":[{"severity":"' + $Severity + '","what":"' + $What + '","file":"src/app.ts","line":10}]}' | ConvertFrom-Json)
}
$empty = ('{"summary":"чисто","findings":[]}' | ConvertFrom-Json)
$lensBlocking = [pscustomobject]@{ Id = 'gates';   Owner = 'лидер java'; Blocking = $true;  File = ''; Ask = '' }
$lensAdvisory = [pscustomobject]@{ Id = 'journey'; Owner = 'аналитик';   Blocking = $false; File = ''; Ask = '' }

It 'находка блокирующего ракурса считается блокирующей' {
    $m = Measure-BcfAcceptance -Lenses @($lensBlocking, $lensAdvisory) -Answers @((New-Answer), $empty)
    Assert-Eq $m.BlockingP1 1
    Assert-Eq $m.AdvisoryP1 0
    Assert-Eq @($m.Findings).Count 1
    Assert-Eq $m.Findings[0].owner 'лидер java' 'владелец ракурса не доехал до находки'
}

It 'находка совещательного ракурса вердикт не трогает' {
    $m = Measure-BcfAcceptance -Lenses @($lensBlocking, $lensAdvisory) -Answers @($empty, (New-Answer))
    Assert-Eq $m.BlockingP1 0
    Assert-Eq $m.AdvisoryP1 1
    Assert-Eq @($m.Advisory).Count 1
}

It 'молчание блокирующего и молчание совещательного считаются раздельно' {
    $m = Measure-BcfAcceptance -Lenses @($lensBlocking, $lensAdvisory) -Answers @($null, 'проза вместо JSON')
    Assert-Eq $m.BlockingFailed 1
    Assert-Eq $m.AdvisoryFailed 1
    Assert-Eq @($m.Findings).Count 0 'из прозы получились находки'
}

It 'совещательная находка помечена в отчёте совещательной' {
    $m = Measure-BcfAcceptance -Lenses @($lensBlocking, $lensAdvisory) -Answers @($empty, (New-Answer))
    $body = Format-BcfAcceptanceReport -Measure $m -Merged 'TASK-01'
    Assert-Match $body 'Совещательные ракурсы'
    Assert-Match $body 'Блокирующих находок нет'
    Assert-Match $body 'отвечает аналитик' 'владелец ракурса в отчёте не назван'
}

# Настоящий отчёт: слово COMPLETE и поле acceptance_p1 считает Emit-RunAllReport, а не тест.
$reportProj = Join-Path $box 'report'
New-Item -ItemType Directory -Force -Path (Join-Path $reportProj 'config') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $reportProj 'tasks') | Out-Null
Set-Content -LiteralPath (Join-Path $reportProj 'proof.txt') -Value 'доказательство' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $reportProj 'config\journeys.json') -Encoding UTF8 -Value @'
{ "command": "Write-Output 'J-01 зелёный'",
  "journeys": [ { "id": "J-01", "title": "человек заводит запись", "proof": "proof.txt" } ] }
'@
Set-Content -LiteralPath (Join-Path $reportProj 'tasks\TASK-01-card.md') -Encoding UTF8 -Value @'
# TASK-01 — карточка приёма

Требование: 3.1.1, ДКЦ1

## Файлы

- `src/app.ts`
'@
# Вторая задача называет ТО ЖЕ требование 3.1.1 и своё 3.2.7. Требование, названное двумя
# задачами, — ровно тот случай, ради которого раздел заведён: одна задача из двух закрывает
# половину пункта, а половина требования это незакрытое требование.
Set-Content -LiteralPath (Join-Path $reportProj 'tasks\TASK-02-plan.md') -Encoding UTF8 -Value @'
# TASK-02 — план врача

**Требование:** 3.1.1, 3.2.7

## Файлы

- `src/plan.ts`
'@

$reportRunner = Join-Path $box 'run-report.ps1'
Set-Content -LiteralPath $reportRunner -Encoding UTF8 -Value @'
param([string]$RunAll, [string]$Root, [string]$Review, [string]$Status, [int]$P1, [string]$GraphFile, [string]$Result,
      [string]$PassedIds = 'TASK-01', [string]$StuckIds = '', [string]$Ts = '2026-09-05 00:00:00',
      [switch]$BreakRequirements)
$ErrorActionPreference = 'Stop'
$env:BCF_REPORT_LIB_ONLY = '1'
$env:BCF_PROJECT_ROOT = $Root
if ($GraphFile) { $env:BCF_GRAPH_FILE = $GraphFile } else { Remove-Item Env:\BCF_GRAPH_FILE -ErrorAction SilentlyContinue }
. $RunAll -ProjectRoot $Root
# Сторож молчаливого catch: разбор требований роняется нарочно, и отчёт обязан сказать об
# этом вслух, а не выйти без раздела. Подмена работает потому, что PowerShell ищет команду
# в момент вызова, а не в момент разбора функции.
if ($BreakRequirements) { function Get-TaskRequirements { throw 'каталог задач недоступен' } }
$passed = @($PassedIds -split ',' | Where-Object { $_ })
$stuck  = @($StuckIds  -split ',' | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Task = $_; Reason = 'stuck' } })
$rep = Emit-RunAllReport -Passed $passed -Stuck $stuck -Total ($passed.Count + $stuck.Count) -Root $Root `
    -ReviewFile $Review -StatusFile $Status -Ts $Ts -AcceptanceP1 $P1
([ordered]@{
    complete = [bool]$rep.complete
    review   = (Get-Content -Raw -LiteralPath $Review)
    status   = (Get-Content -Raw -LiteralPath $Status)
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Result -Encoding UTF8
'@

function Invoke-Report {
    param([int]$P1 = 0, [string]$GraphFile = '', [string]$PassedIds = 'TASK-01', [string]$StuckIds = '',
          [string]$Ts = '2026-09-05 00:00:00', [switch]$BreakRequirements)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $result = Join-Path $box "result-$tag.json"
    $argv = @('-RunAll', $runAll, '-Root', $reportProj,
              '-Review', (Join-Path $box "REVIEW-$tag.md"), '-Status', (Join-Path $box "status-$tag.json"),
              '-P1', $P1, '-GraphFile', $GraphFile, '-Result', $result,
              '-PassedIds', $PassedIds, '-StuckIds', $StuckIds, '-Ts', $Ts)
    if ($BreakRequirements) { $argv += '-BreakRequirements' }
    & pwsh -NoProfile -NonInteractive -File $reportRunner @argv *> $null
    if (-not (Test-Path -LiteralPath $result)) { throw "Emit-RunAllReport не отработал (нет $result)" }
    $r = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
    $r | Add-Member -NotePropertyName statusObj -NotePropertyValue ($r.status | ConvertFrom-Json)
    return $r
}

It 'P1 блокирующего ракурса отменяет COMPLETE' {
    $r = Invoke-Report -P1 1
    Assert-False $r.complete 'блокирующая находка не помешала объявить готовность'
    Assert-Match $r.review 'ЕСТЬ P1 ПРИЁМКИ'
    Assert-Eq $r.statusObj.acceptance_p1 1
}

It 'ноль P1 приёмки COMPLETE не отменяет' {
    # Половина от предыдущей проверки: сам по себе отчёт при нуле P1 объявляет готовность.
    # ЧЕМ ЭТОТ НОЛЬ ПОЛУЧЕН — вопрос следующего блока: здесь число передано руками.
    $r = Invoke-Report -P1 0
    Assert-True $r.complete "нулевой P1 уронил вердикт:`n$($r.review)"
    Assert-Match $r.review 'Статус:\*\* COMPLETE'
}

# --- 4б. Вес ракурса на настоящей проводке графа -------------------------------------------
#
# ПОЧЕМУ ОТДЕЛЬНЫМ БЛОКОМ. Предыдущие проверки стоят по краям цепочки: одна считает свод
# (Measure-BcfAcceptance), другая печатает отчёт (Emit-RunAllReport) по числу, которое ей
# дали руками. Между ними — строка графа, решающая, КАКОЕ число уедет в вердикт: число
# блокирующих P1 или число всех P1. Пока эту строку никто не исполнял, замена
# `-AcceptanceP1 $blockP1` на `-AcceptanceP1 $findP1.Count` (поведение до правки: находка
# совещательного ракурса роняет прогон) оставляла все сюиты зелёными.
#
# Здесь блок вердикта ВЫРЕЗАЕТСЯ ИЗ ФАЙЛА ГРАФА разборщиком PowerShell и исполняется:
# от подсчёта находок до настоящего Emit-RunAllReport, который пишет .bcf/REVIEW.md и
# .bcf/run-all.status.json. Тест не пересказывает проводку своими словами — он её гоняет.
Write-Host ''
Write-Host '4б. Вес ракурса решается кодом графа, а не пересказом в тесте' -ForegroundColor White

$verdictProj = Join-Path $box 'verdict'
New-Item -ItemType Directory -Force -Path (Join-Path $verdictProj 'config') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $verdictProj 'tasks') | Out-Null
Set-Content -LiteralPath (Join-Path $verdictProj 'proof.txt') -Value 'доказательство' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $verdictProj 'config\journeys.json') -Encoding UTF8 -Value @'
{ "command": "Write-Output 'J-01 зелёный'",
  "journeys": [ { "id": "J-01", "title": "человек заводит запись", "proof": "proof.txt" } ] }
'@
Set-Content -LiteralPath (Join-Path $verdictProj 'tasks\TASK-01-card.md') -Encoding UTF8 -Value @'
# TASK-01 — карточка приёма

Требование: 3.1.1

## Файлы

- `src/app.ts`
'@

$verdictRunner = Join-Path $box 'run-verdict.ps1'
Set-Content -LiteralPath $verdictRunner -Encoding UTF8 -Value @'
param([string]$FactoryHome, [string]$Graph, [string]$Root, [string]$Mode, [string]$Result)
$ErrorActionPreference = 'Stop'
$env:BCF_HOME = $FactoryHome
$env:BCF_PROJECT_ROOT = $Root
$env:BCF_MEMORY_DISABLED = '1'
. (Join-Path $FactoryHome 'harness\lib\bcf-context.ps1')
. (Join-Path $FactoryHome 'harness\lib\critics.ps1')

# Два ракурса разного веса. Находка кладётся тому, кого просит режим, — свод считает
# настоящая Measure-BcfAcceptance, а не тест.
$lenses = @(
    [pscustomobject]@{ Id = 'gates';   Owner = 'лидер java'; Blocking = $true;  File = ''; Ask = '' },
    [pscustomobject]@{ Id = 'journey'; Owner = 'аналитик';   Blocking = $false; File = ''; Ask = '' }
)
$found = ('{"summary":"смотрел","findings":[{"severity":"P1","what":"путь не проходится","file":"src/app.ts","line":10}]}' | ConvertFrom-Json)
$empty = ('{"summary":"чисто","findings":[]}' | ConvertFrom-Json)
$answers = if ($Mode -eq 'blocking') { @($found, $empty) } else { @($empty, $found) }
$measure = Measure-BcfAcceptance -Lenses $lenses -Answers $answers

# Блок вердикта из файла графа: от $findAll до присваивания с Emit-RunAllReport.
$toks = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Graph, [ref]$toks, [ref]$errs)
$asgs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
$from = @($asgs | Where-Object { $_.Left.Extent.Text -eq '$findAll' })[0]
$to   = @($asgs | Where-Object { $_.Right.Extent.Text -match 'Emit-RunAllReport' })[0]
if (-not $from) { throw 'в графе не найден подсчёт находок приёмки ($findAll)' }
if (-not $to)   { throw 'в графе не найден вызов Emit-RunAllReport' }
if ($to.Extent.EndOffset -le $from.Extent.StartOffset) { throw 'блок вердикта в графе идёт задом наперёд' }
$src = Get-Content -Raw -LiteralPath $Graph
$region = $src.Substring($from.Extent.StartOffset, $to.Extent.EndOffset - $from.Extent.StartOffset)

# Обвязка узла графа, без которой вырезанный блок не запустится. Подменяются только журнал
# и фаза: всё, что касается вердикта, исполняется настоящим кодом.
function Write-GraphLog { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
function Set-Phase { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
$script:GraphCtx = [pscustomobject]@{ DryPlan = $false; Dir = $Root }
$passed = @('TASK-01')
$stuck  = @()
$tasks  = @('TASK-01')
$root   = $Root

. ([scriptblock]::Create($region))

$statusPath = Join-Path $Root '.bcf\run-all.status.json'
$status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
([ordered]@{
    mode          = $Mode
    complete      = [bool]$rep.complete
    acceptance_p1 = [int]$status.acceptance_p1
    blocking_p1   = [int]$measure.BlockingP1
    total_p1      = @(@($measure.Findings) | Where-Object { $_.severity -eq 'P1' }).Count
    advisory_p1   = [int]$measure.AdvisoryP1
    review        = (Get-Content -Raw -LiteralPath (Join-Path $Root '.bcf\REVIEW.md'))
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Result -Encoding UTF8
'@

function Invoke-GraphVerdict {
    param([Parameter(Mandatory)][ValidateSet('advisory', 'blocking')][string]$Mode)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $result = Join-Path $box "verdict-$tag.json"
    $graph = Join-Path $root 'harness\graphs\queue.graph.ps1'
    & pwsh -NoProfile -NonInteractive -File $verdictRunner -FactoryHome $root -Graph $graph `
        -Root $verdictProj -Mode $Mode -Result $result *> $null
    if (-not (Test-Path -LiteralPath $result)) { throw "блок вердикта графа не отработал в режиме «$Mode» (нет $result)" }
    return (Get-Content -Raw -LiteralPath $result | ConvertFrom-Json)
}

It 'находка совещательного ракурса доезжает до отчёта, но вердикт не роняет' {
    $r = Invoke-GraphVerdict -Mode advisory
    # Числа расходятся — иначе проверка проходила бы при любом выборе аргумента.
    Assert-Eq $r.total_p1 1 'находки совещательного ракурса нет в своде'
    Assert-Eq $r.advisory_p1 1
    Assert-Eq $r.blocking_p1 0
    # И граф выбрал из двух чисел именно блокирующее: это видно в статусе прогона.
    Assert-Eq $r.acceptance_p1 0 'в вердикт уехало общее число P1, а не число блокирующих'
    Assert-True $r.complete "находка совещательного ракурса уронила прогон:`n$($r.review)"
    Assert-Match $r.review 'Статус:\*\* COMPLETE'
}

It 'та же находка блокирующего ракурса прогон роняет' {
    $r = Invoke-GraphVerdict -Mode blocking
    Assert-Eq $r.blocking_p1 1
    Assert-Eq $r.acceptance_p1 1 'блокирующая находка не доехала до вердикта'
    Assert-False $r.complete 'блокирующая находка не помешала объявить готовность'
    Assert-Match $r.review 'ЕСТЬ P1 ПРИЁМКИ'
}

It 'в вызов отчёта граф передаёт счётчик блокирующих, а не всех находок' {
    # Читается разборщиком, а не грепом: аргумент берётся у самого узла дерева разбора.
    $graph = Join-Path $root 'harness\graphs\queue.graph.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($graph, [ref]$null, [ref]$null)
    $call = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Emit-RunAllReport'
    }, $true))[0]
    Assert-True $call 'в графе очереди нет вызова Emit-RunAllReport'
    $els = @($call.CommandElements)
    $ix = -1
    for ($i = 0; $i -lt $els.Count; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
            $els[$i].ParameterName -eq 'AcceptanceP1') { $ix = $i; break }
    }
    Assert-True ($ix -ge 0) 'отчёту не передан -AcceptanceP1: приёмка перестала влиять на вердикт'
    $arg = [string]$els[$ix + 1].Extent.Text
    Assert-Eq $arg '$blockP1' 'в -AcceptanceP1 уехало не число блокирующих находок'
    $asg = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$blockP1'
    }, $true))[0]
    Assert-True $asg 'в графе нет присваивания $blockP1'
    Assert-Match $asg.Right.Extent.Text 'BlockingP1' '$blockP1 считается не по блокирующим ракурсам'
}

# --- 4в. Тот же вес в графе ревью ----------------------------------------------------------
#
# ВЕС РАКУРСА РЕШАЕТСЯ В ДВУХ МЕСТАХ, А СТОРОЖ СТОЯЛ У ОДНОГО. Приёмка отдаёт наверх
# `$blockP1`, ревью — поле `findings` своего результата, и по нему graph.ps1 решает, назвать
# прогон «ок» или нет. Пока эта строка не исполнялась, замена `$confirmedBlocking.Count` на
# `$confirmed.Count` (поведение до правки: находка совещательного ракурса роняет ревью)
# не красила ни одну сюиту — ровно тот дефект, который в графе очереди уже закрыт выше.
#
# Хвост вердикта вырезается из файла графа тем же способом и исполняется: от разделения
# находок по весу до `return`. Подменены только журнал и узел сведения — всё, что касается
# веса, считает настоящий код графа.
Write-Host ''
Write-Host '4в. Тот же вес ракурса в графе ревью' -ForegroundColor White

$reviewRunner = Join-Path $box 'run-review-verdict.ps1'
Set-Content -LiteralPath $reviewRunner -Encoding UTF8 -Value @'
param([string]$Graph, [string]$Box, [string]$Result)
$ErrorActionPreference = 'Stop'

# Две находки, пережившие состязательную проверку: одна блокирующего ракурса, одна
# совещательного. Разделить их обязан граф, а не тест.
$confirmed = @(
    [pscustomobject]@{ severity = 'P1'; file = 'src/app.ts'; line = 10; title = 'путь не проходится'
                       why = 'нет обработчика пустого расписания'; lens = 'gates'; owner = 'лидер java'; blocking = $true },
    [pscustomobject]@{ severity = 'P2'; file = 'src/ui.ts'; line = 20; title = 'подпись мимо макета'
                       why = 'шрифт другого начертания'; lens = 'journey'; owner = 'аналитик'; blocking = $false }
)
$seen = @{ 'a' = $true; 'b' = $true; 'c' = $true }
$round = 2
$reportFile = Join-Path $Box 'REVIEW-graph.md'

function Write-GraphLog { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
function Invoke-Node {
    param([string]$Prompt, [string]$Label = '', [string]$Role = '', $Schema = $null,
          [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    # Узел сведения возвращает текст; тесту важно не что он сказал, а что ему показали.
    Set-Content -LiteralPath (Join-Path $Box 'summary-prompt.txt') -Value $Prompt -Encoding UTF8
    return 'сводка узла сведения'
}

# Хвост вердикта из файла графа: от разделения находок по весу до return с полем advisory.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Graph, [ref]$null, [ref]$null)
$from = @($ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
              $n.Left.Extent.Text -eq '$confirmedBlocking' }, $true))[0]
$ret = @($ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and
              $n.Extent.Text -match 'advisory' }, $true))[-1]
if (-not $from) { throw 'в графе ревью нет разделения находок по весу ($confirmedBlocking)' }
if (-not $ret)  { throw 'в графе ревью нет return с полем advisory' }
if ($ret.Extent.EndOffset -le $from.Extent.StartOffset) { throw 'хвост вердикта в графе ревью идёт задом наперёд' }
$src = Get-Content -Raw -LiteralPath $Graph
$region = $src.Substring($from.Extent.StartOffset, $ret.Extent.EndOffset - $from.Extent.StartOffset)

$out = & ([scriptblock]::Create($region))

([ordered]@{
    findings = [int]$out.findings
    advisory = [int]$out.advisory
    report   = (Get-Content -Raw -LiteralPath $reportFile)
    prompt   = (Get-Content -Raw -LiteralPath (Join-Path $Box 'summary-prompt.txt'))
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Result -Encoding UTF8
'@

$script:reviewVerdict = $null
function Get-ReviewVerdict {
    if ($script:reviewVerdict) { return $script:reviewVerdict }
    $result = Join-Path $box 'review-verdict.json'
    $graph = Join-Path $root 'harness\graphs\review.graph.ps1'
    & pwsh -NoProfile -NonInteractive -File $reviewRunner -Graph $graph -Box $box -Result $result *> $null
    if (-not (Test-Path -LiteralPath $result)) { throw 'хвост вердикта графа ревью не отработал' }
    $script:reviewVerdict = Get-Content -Raw -LiteralPath $result | ConvertFrom-Json
    return $script:reviewVerdict
}

It 'ревью поднимает наверх находки блокирующих ракурсов, а не все подряд' {
    # По полю findings graph.ps1 решает, называть ли прогон «ок». Уедет туда общее число —
    # совещательный ракурс снова роняет прогон наравне с требованием заказчика.
    $r = Get-ReviewVerdict
    Assert-Eq $r.findings 1 'в вердикт ревью уехало общее число находок, а не число блокирующих'
    Assert-Eq $r.advisory 1 'совещательная находка потерялась вовсе'
}

It 'совещательная находка ревью печатается своим разделом, а не молчит' {
    # Вторая половина веса: находка не влияет на вердикт, но человек её видит и видит,
    # что она совещательная. Молча выброшенная находка хуже, чем роняющая прогон.
    $r = Get-ReviewVerdict
    Assert-Match $r.report 'Совещательные ракурсы' 'в отчёте ревью нет раздела совещательных находок'
    Assert-Match $r.report 'подпись мимо макета' 'совещательная находка не доехала до отчёта'
    Assert-Match $r.report 'блокирующих 1, совещательных 1' 'отчёт не называет находки по весу'
    Assert-Match $r.report 'путь не проходится' 'блокирующая находка не доехала до отчёта'
    # И владелец ракурса едет вместе с находкой: иначе спросить по ней некого.
    Assert-Match $r.report 'отвечает лидер java' 'владелец блокирующего ракурса потерян'
    Assert-Match $r.prompt 'подпись мимо макета' 'узел сведения совещательных находок не видит'
}

# --- 5. Номера требований заказчика --------------------------------------------------------
Write-Host ''
Write-Host '5. Номера требований: шапка, секция и то, что требованием НЕ является' -ForegroundColor White

$taskHeader = @'
# TASK-07 — карточка приёма

Исполнитель: фабрика
Требование: 3.1.1, ДКЦ1

## Файлы

- `src/app.ts`

## Проверки

```
npm view pkg@9.9.9
```
'@

$taskSection = @'
# TASK-08 — расписание врача

## Требования

- **3.2.1** оператор видит расписание на неделю
- **ДКЦ4** карточка открывается за два клика
- обычный пункт без номера

## Файлы

- `src/schedule.ts`
'@

# Строка «Требование:» НИЖЕ первой секции. Написана ровно так же, как настоящая строка
# шапки: без нумерации, без скобок, номер отдельным словом. Иначе фикстура проходит не
# потому, что зона чтения сужена, а потому, что регексп не принял «1. » или скобку, —
# и охрана шапки остаётся без сторожа. Проверено мутацией: `$header = $Body` вместо
# `Get-BcfTaskHeader` даёт здесь 4.4.4.
$taskNone = @'
# TASK-09 — внутренний рефакторинг

## Файлы

- `src/util.ts`

## Готовность

Требование: 4.4.4
'@

# Блок кода ВНУТРИ секции «## Требования». Пример реестра, а не требование задачи: строка
# набрана как буллет с жирным номером, то есть отличает её от настоящей только забор.
$taskFenced = @'
# TASK-11 — импорт расписания

## Требования

- **3.3.1** оператор загружает расписание из файла

Так выглядит строка чужого реестра, требованием задачи она не является:

```
- **9.9.9** строка из выгрузки заказчика
```

## Файлы

- `src/import.ts`
'@

# Буллет с номером, но БЕЗ жирного. Человек пишет так пункты списка; требованием он их
# не объявлял, и в столбец такой номер ехать не должен.
$taskPlainBullet = @'
# TASK-12 — печать талона

## Требования

- **3.4.1** оператор печатает талон приёма
- 5.5.5 сверить с версией макета

## Файлы

- `src/print.ts`
'@

It 'строка в шапке: несколько номеров через запятую' {
    $r = @(Get-BcfRequirementsFromText -Body $taskHeader)
    Assert-Eq ($r -join ',') '3.1.1,ДКЦ1'
}

It 'номер из блока кода требованием не становится' {
    # Без этого задача с командой `pkg@9.9.9` объявила бы себя закрывающей требование 9.9.9.
    $r = @(Get-BcfRequirementsFromText -Body $taskHeader)
    Assert-False ($r -contains '9.9.9') 'номер из блока кода уехал в требования'
}

It 'секция «## Требования»: жирные номера, остальное мимо' {
    $r = @(Get-BcfRequirementsFromText -Body $taskSection)
    Assert-Eq ($r -join ',') '3.2.1,ДКЦ4'
}

It 'задача без требований не выдумывает их' {
    $r = @(Get-BcfRequirementsFromText -Body $taskNone)
    Assert-Eq @($r).Count 0 "разобрано лишнее: $($r -join ',')"
}

It 'строка «Требование:» ниже первой секции шапкой не считается' {
    # Охрана зоны чтения: читается шапка задачи, а не всё тело. Без неё «Требование: 4.4.4»
    # из раздела «Готовность» объявило бы задачу закрывающей пункт договора 4.4.4.
    $r = @(Get-BcfRequirementsFromText -Body $taskNone)
    Assert-False ($r -contains '4.4.4') 'строка из тела задачи прочитана как шапка'
}

It 'жирный номер внутри блока кода в секции требований не читается' {
    # Охрана забора внутри секции: пример чужого реестра набран как настоящий буллет.
    $r = @(Get-BcfRequirementsFromText -Body $taskFenced)
    Assert-Eq ($r -join ',') '3.3.1' "номер из блока кода уехал в требования: $($r -join ',')"
}

It 'буллет с номером, но без жирного, требованием не становится' {
    # Охрана жирного номера: требование — то, что человек объявил требованием, а не всякий
    # номер в списке. Без неё «сверить с версией макета» попадает в столбец заказчика.
    $r = @(Get-BcfRequirementsFromText -Body $taskPlainBullet)
    Assert-Eq ($r -join ',') '3.4.1' "не жирный номер уехал в требования: $($r -join ',')"
}

It 'требования читаются из файла задачи по её id' {
    $p5 = New-Project 'req'
    Set-Content -LiteralPath (Join-Path $p5 'tasks\TASK-07-card.md') -Value $taskHeader -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p5 'tasks\TASK-08-plan.md') -Value $taskSection -Encoding UTF8
    Assert-Eq ((Get-TaskRequirements -TaskId 'TASK-07' -Root $p5) -join ',') '3.1.1,ДКЦ1'
    Assert-Eq ((Get-TaskRequirements -TaskId 'TASK-08' -Root $p5) -join ',') '3.2.1,ДКЦ4'
}

It 'обратный разрез: требование → задачи, которые его закрывают' {
    $tasks = @(
        [pscustomobject]@{ Id = 'TASK-07'; Requirements = @('3.1.1', 'ДКЦ1') },
        [pscustomobject]@{ Id = 'TASK-08'; Requirements = @('3.1.1') }
    )
    $ix = Get-BcfRequirementIndex -Tasks $tasks
    Assert-Eq (@($ix['3.1.1']) -join ',') 'TASK-07,TASK-08'
    Assert-Eq (@($ix['ДКЦ1']) -join ',') 'TASK-07'
}

It 'bcf tasks печатает колонку требований' {
    $p6 = New-Project 'cli'
    Set-Content -LiteralPath (Join-Path $p6 'tasks\TASK-07-card.md') -Value $taskHeader -Encoding UTF8
    $out = & pwsh -NoProfile -File $bcf tasks --project $p6 2>&1 | Out-String
    Assert-Match $out 'требования' 'в шапке таблицы нет колонки требований'
    Assert-Match $out '3\.1\.1' 'номер требования не напечатан в строке задачи'
    Assert-Match $out 'требований заказчика названо' 'счёт требований не показан'
}

It 'требования доезжают до отчёта прогона' {
    $r = Invoke-Report -P1 0
    Assert-Match $r.review 'Требования заказчика'
    Assert-Match $r.review '3\.1\.1'
}

It 'требование, названное двумя задачами, закрыто только когда закрыты обе' {
    # Ради этого случая раздел и заведён: 3.1.1 назвали TASK-01 и TASK-02, и пока обе не
    # PASS, пункт договора не закрыт. Проверка идёт на ДВУХ задачах не для полноты: на одной
    # задаче раздел был зелёным и при сломанном счёте, потому что список из одного элемента
    # неотличим от строки, в которую он схлопывается.
    $r = Invoke-Report -P1 0 -PassedIds 'TASK-01,TASK-02'
    Assert-Match $r.review '- \*\*3\.1\.1\*\* — закрыто: TASK-01, TASK-02' 'пункт двух закрытых задач не объявлен закрытым'
    Assert-Match $r.review 'Закрыто пунктов: 3 из 3'
    Assert-NoMatch $r.review '3\.1\.1\*\* — НЕ закрыто' 'закрытый пункт напечатан незакрытым'
}

It 'закрытая половина требования оставляет его незакрытым и называет только незакрытую задачу' {
    # Вторая половина: TASK-01 закрыта, TASK-02 застряла. В строке пункта должна стоять
    # только TASK-02 (чинить надо её), а «всего задач» — настоящие две, а не единица.
    $r = Invoke-Report -P1 0 -PassedIds 'TASK-01' -StuckIds 'TASK-02'
    Assert-Match $r.review '- \*\*3\.1\.1\*\* — НЕ закрыто: TASK-02 \(всего задач: 2\)' 'счёт задач требования неверен'
    Assert-Match $r.review '- \*\*ДКЦ1\*\* — закрыто: TASK-01' 'пункт единственной закрытой задачи не закрыт'
    Assert-Match $r.review 'Закрыто пунктов: 1 из 3'
}

It 'шапка отчёта печатает время прогона, а не список задач' {
    # Раздел требований стоит в той же функции, что и шапка, и однажды уже перетёр её:
    # локальная переменная совпала по имени с параметром -Ts, и «Когда» стало списком задач.
    $r = Invoke-Report -P1 0 -PassedIds 'TASK-01,TASK-02' -Ts '2026-09-05 03:14:15'
    Assert-Match $r.review '\*\*Когда:\*\* 2026-09-05 03:14:15' 'в шапке отчёта не время прогона'
    Assert-NoMatch $r.review '\*\*Когда:\*\*[^\r\n]*TASK-' 'в шапку отчёта уехали id задач'
    Assert-Eq $r.statusObj.when '2026-09-05 03:14:15'
}

It 'упавший разбор требований назван в отчёте, а не проглочен' {
    # Пустой catch оставлял отчёт вовсе без раздела и без единого слова о том, что раздел
    # был: заказчик читает «требований нет» там, где на самом деле «разбор упал».
    $r = Invoke-Report -P1 0 -BreakRequirements
    Assert-Match $r.review 'Требования заказчика' 'раздел исчез вместе с ошибкой'
    Assert-Match $r.review 'каталог задач недоступен' 'причина отказа не названа'
}

# --- 6. Чем получен вердикт ----------------------------------------------------------------
Write-Host ''
Write-Host '6. Вердикт называет версию фабрики и хэш файла графа' -ForegroundColor White

It 'без графа так и сказано, а не пустая строка' {
    $saved = $env:BCF_GRAPH_FILE
    Remove-Item Env:\BCF_GRAPH_FILE -ErrorAction SilentlyContinue
    try {
        $lines = Get-BcfProvenanceLines
        Assert-Match $lines[0] '^factory_version: \S'
        Assert-Match $lines[1] 'graph_hash: нет'
    } finally { if ($saved) { $env:BCF_GRAPH_FILE = $saved } }
}

It 'хэш считается по содержимому файла графа' {
    $g = Join-Path $root 'harness\graphs\queue.graph.ps1'
    $expected = (Get-FileHash -LiteralPath $g -Algorithm SHA256).Hash.ToLower().Substring(0, 12)
    $lines = Get-BcfProvenanceLines -GraphFile $g
    Assert-Match $lines[1] ([regex]::Escape($expected)) 'хэш в вердикте не совпадает с хэшем файла графа'
    Assert-Match $lines[1] 'queue.graph.ps1'
}

It 'версия фабрики — из файла VERSION, а не выдумана' {
    Assert-Eq (Get-BcfFactoryVersion) ((Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim())
}

It 'обе строки стоят в итоговом отчёте прогона' {
    $g = Join-Path $root 'harness\graphs\queue.graph.ps1'
    $r = Invoke-Report -P1 0 -GraphFile $g
    Assert-Match $r.review 'factory_version:'
    Assert-Match $r.review 'graph_hash:'
    Assert-Eq $r.statusObj.factory_version ((Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim())
    Assert-True ([string]$r.statusObj.graph_hash -match '^[0-9a-f]{12}$') "в статусе не хэш: «$($r.statusObj.graph_hash)»"
}

It 'вердикт задачи собирается с теми же строками' {
    # Проводка: сам вердикт пишет verify.ps1 в конце полного прогона верификации, поэтому
    # здесь проверяется, что строки провенанса стоят в его шапке, а не дописаны где-то ниже.
    $src = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\verify.ps1')
    Assert-Match $src '\$provenance = \(Get-BcfProvenanceLines\)' 'verify.ps1 не считает провенанс'
    Assert-Match $src '(?s)verdict: \$verdict\r?\ndate: \$today\r?\n\$provenance' 'строк провенанса нет в шапке вердикта'
}

# --- Итог ----------------------------------------------------------------------------------
Remove-Item Env:\BCF_GRAPH_FAKE_AGENT -ErrorAction SilentlyContinue
Remove-Item Env:\BCF_TEST_TRACE -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  ИТОГ: пройдено $script:pass, провалено $script:fail") -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:fail) { exit 1 }
exit 0
