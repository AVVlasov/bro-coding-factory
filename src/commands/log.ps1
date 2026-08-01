# bcf log — что агент на самом деле ответил.
#
#   bcf log                     узлы последнего прогона: где что сохранилось
#   bcf log <часть имени узла>  ответ этого узла, его ошибки, его промпт
#   bcf log --failed            только упавшие узлы, сразу с причиной
#   bcf log <runId> <узел>      то же самое по конкретному прогону
#   bcf log <узел> --prompt     показать промпт, с которым узел звали
#   bcf log <узел> --raw        файл как есть, без разбора потока
#
# ЗАЧЕМ. Доска и отчёт отвечают на вопрос «что случилось»: узел упал, причина такая-то.
# Но следующий вопрос всегда один и тот же — «а что он ВООБЩЕ ответил». До сих пор
# ответом было «загляни в .bcf/graph/<runId>/nodes/*.out.jsonl», то есть читай поток
# событий бэкенда глазами. Причём имя файла надо угадать: оно собрано из подписи узла.
#
# Эти файлы уже пишутся на каждый узел — промпт, поток ответа, stderr. Команда не заводит
# ничего нового, она делает уже существующее доступным.

. (Join-Path $BcfRoot 'src\lib\journal.ps1')

$project = $script:BcfProject
$raw     = $script:BcfArgs -contains '--raw'
$wantPr  = $script:BcfArgs -contains '--prompt'
$onlyBad = $script:BcfArgs -contains '--failed'
$free    = @($script:BcfArgs | Where-Object { $_ -notlike '-*' })

# Первый свободный аргумент может быть и runId, и куском имени узла. Различаем по форме:
# runId — это YYYYMMDD-HHMMSS-…, ни один разумный ярлык узла так не выглядит.
$runId = ''
$query = ''
foreach ($a in $free) {
    if (-not $runId -and $a -match '^\d{8}-\d{6}') { $runId = $a; continue }
    if (-not $query) { $query = $a }
}

$run = if ($runId) { Resolve-BcfRun -Project $project -RunId $runId } else { Get-BcfLastRun -Project $project }
if (-not $run) {
    Write-BcfTitle 'ЖУРНАЛ УЗЛОВ' (Split-Path $project -Leaf)
    Write-BcfDim $(if ($runId) { "прогон $runId не найден" } else { 'прогонов ещё не было' })
    Write-BcfNote 'запустить: bcf run queue'
    Write-Host ''
    exit 2
}

$dir = Join-Path $run.Dir 'nodes'
Write-BcfTitle 'ЖУРНАЛ УЗЛОВ' "$($run.RunId) · $($run.Name)"

if (-not (Test-Path $dir)) {
    # Каталога нет — это не «пусто», это конкретная причина, и их всего две.
    if ($run.DryPlan) { Write-BcfDim 'сухой план: агентов не звали, сохранять было нечего' }
    else { Write-BcfWarn 'узлы ничего не сохранили — прогон оборвался до первого вызова агента' }
    Write-BcfNote (Get-BcfRelPath -Project $project -Path $run.Dir)
    Write-Host ''
    exit 1
}

$files = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue)

# «Есть содержимое» — это не «файл существует» и даже не «размер больше нуля». Умерший
# агент оставляет файл из одного перевода строки, а редактор добавляет BOM: по размеру оба
# непусты. Смотрим начало файла — целиком читать нельзя, поток ответа бывает в мегабайты.
function Test-BcfHasContent {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $len = (Get-Item $Path).Length
    if ($len -eq 0) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] ([math]::Min(4096, $len))
            $read = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        $s = [Text.Encoding]::UTF8.GetString($buf, 0, $read).TrimStart([char]0xFEFF)
        return [bool]$s.Trim()
    } catch { return $true }
}

# --- Список ------------------------------------------------------------------------------
if (-not $query) {
    $shown = @($run.Nodes)
    if ($onlyBad) { $shown = @($shown | Where-Object { $_.Ok -ne $true }) }
    if (-not $shown.Count) {
        Write-BcfDim $(if ($onlyBad) { 'упавших узлов нет' } else { 'узлов в журнале нет' })
        Write-Host ''
        exit 0
    }

    $rows = New-BcfRows
    $colors = @()
    foreach ($n in $shown) {
        $sym = if ($n.Ok -eq $true) { Sym 'ok' } elseif ($n.Ok -eq $false) { Sym 'fail' } else { Sym 'warn' }
        # Сопоставляем узел с файлами по нормализованному имени: файл назван подписью узла,
        # прогнанной через замену небезопасных символов, — обратное преобразование
        # неоднозначно, поэтому сравниваем нормализованные формы.
        $norm = ($n.Label -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')
        $mine = @($files | Where-Object { (($_.BaseName -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')) -like "$norm*" })
        # Пустой файл не считается сохранённым ответом. Иначе список обещает то, чего в
        # нём нет, — а именно за ответом упавшего узла сюда и приходят.
        $kinds = @()
        if ($mine | Where-Object { ($_.Name -like '*.out.jsonl' -or $_.Name -like '*.cmd.out.txt') -and (Test-BcfHasContent $_.FullName) }) { $kinds += 'ответ' }
        if ($mine | Where-Object { ($_.Name -like '*.err.*') -and (Test-BcfHasContent $_.FullName) }) { $kinds += 'ошибки' }
        if ($mine | Where-Object { ($_.Name -like '*.prompt.txt') -and (Test-BcfHasContent $_.FullName) }) { $kinds += 'промпт' }
        if (-not $kinds.Count) { $kinds = @('пусто') }
        Add-BcfRow $rows @($sym, $n.Label, $n.Role, ($kinds -join ' · '), $n.Reason)
        $colors += $(if ($n.Ok -eq $true) { '' } elseif ($n.Ok -eq $false) { 'Red' } else { 'DarkYellow' })
    }
    Write-Host ''
    Write-BcfTable -Headers @('', 'узел', 'роль', 'сохранено', 'причина') `
                   -Widths @(2, 28, 8, 20, 28) -Rows $rows -RowColors $colors
    Write-Host ''
    Write-BcfNote 'посмотреть один: bcf log <часть имени узла>   ·   только упавшие: bcf log --failed'
    Write-BcfNote (Get-BcfRelPath -Project $project -Path $dir)
    Write-Host ''
    exit 0
}

# --- Один узел ---------------------------------------------------------------------------
$q = ($query -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')
$hit = @($files | Where-Object { (($_.BaseName -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')) -like "*$q*" })
if (-not $hit.Count) {
    Write-BcfFail "узла по «$query» в этом прогоне нет"
    Write-BcfNote 'список: bcf log   ·   другой прогон: bcf log <runId> <узел>'
    Write-Host ''
    exit 2
}

# Группируем по базе имени: у одного узла до четырёх файлов, и показывать их надо вместе.
$bases = @($hit | ForEach-Object { $_.BaseName -replace '\.(out|err|prompt|cmd\.out|cmd\.err)$', '' -replace '\.(jsonl|log|txt)$', '' } | Select-Object -Unique)
if ($bases.Count -gt 1) {
    Write-BcfWarn "под «$query» подходит несколько узлов — уточни"
    foreach ($b in $bases) { Write-BcfNote $b }
    Write-Host ''
    exit 2
}
$base = $bases[0]
$node = @($run.Nodes | Where-Object { (($_.Label -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')) -like "*$q*" }) | Select-Object -First 1

Write-Host ''
if ($node) {
    $st = if ($node.Ok -eq $true) { Ink 'ок' 'Green' } elseif ($node.Ok -eq $false) { Ink 'ПРОВАЛ' 'Red' } else { Ink 'не завершился' 'Yellow' }
    Write-BcfLine ("  $($node.Label)   " + $st) 'White'
    $meta = @($node.Role, $node.Model, $(if ($node.Tokens) { "$([int]$node.Tokens) ток." })) | Where-Object { $_ }
    if ($meta.Count) { Write-BcfLine ('  ' + ($meta -join ' · ')) 'DarkGray' }
    if ($node.Reason) { Write-BcfLine "  причина: $($node.Reason)" 'Red' }
} else {
    Write-BcfLine "  $base" 'White'
}

function _Show { param([string]$Path, [string]$Head, [int]$Tail = 0)
    if (-not (Test-BcfHasContent $Path)) { return $false }
    Write-Host ''
    Write-BcfLine "  $Head" 'White'
    $lines = if ($Tail) { Get-Content -LiteralPath $Path -Tail $Tail -Encoding UTF8 } else { Get-Content -LiteralPath $Path -Encoding UTF8 }
    foreach ($l in $lines) { Write-Host "  $l" }
    return $true
}

if ($wantPr) {
    if (-not (_Show (Join-Path $dir "$base.prompt.txt") 'ПРОМПТ')) {
        Write-BcfDim '  промпта не сохранено — узел был командой, а не агентом'
    }
    Write-Host ''
    exit 0
}

# stderr первым: когда узел упал, ответ обычно пуст, а причина именно здесь.
$hadErr = _Show (Join-Path $dir "$base.err.log") 'ОШИБКИ БЭКЕНДА' 40
if (-not $hadErr) { $hadErr = _Show (Join-Path $dir "$base.cmd.err.txt") 'ОШИБКИ КОМАНДЫ' 40 }

$outJsonl = Join-Path $dir "$base.out.jsonl"
$outTxt   = Join-Path $dir "$base.cmd.out.txt"

if (Test-Path $outTxt) {
    if (-not (_Show $outTxt 'ВЫВОД КОМАНДЫ' 200)) { Write-BcfDim '  вывод пуст' }
} elseif (Test-Path $outJsonl) {
    if ($raw) {
        _Show $outJsonl 'ПОТОК БЭКЕНДА (как есть)' 200 | Out-Null
    } else {
        # Достаём текст из потока событий. У каждой CLI своя схема, поэтому берём все
        # известные формы, а не одну: задача — показать ответ, а не разобрать протокол.
        # Что не разобралось — честно считаем неразобранным и говорим про --raw.
        $text = New-Object 'System.Collections.Generic.List[string]'
        $unparsed = 0
        foreach ($l in (Get-Content -LiteralPath $outJsonl -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not $l.Trim()) { continue }
            $o = $null
            try { $o = $l | ConvertFrom-Json } catch { $unparsed++; continue }
            foreach ($v in @(
                $o.text,
                $o.delta.text,
                $o.result,
                $(if ($o.message -and $o.message.content) { ($o.message.content | ForEach-Object { $_.text }) -join '' }),
                $(if ($o.parts) { ($o.parts | ForEach-Object { $_.text }) -join '' })
            )) {
                if ($v -and ([string]$v).Trim()) { $text.Add([string]$v) }
            }
        }
        if ($text.Count) {
            Write-Host ''
            Write-BcfLine '  ОТВЕТ' 'White'
            foreach ($l in (($text -join '') -split "`r?`n")) { Write-Host "  $l" }
        } else {
            Write-Host ''
            Write-BcfWarn 'текста в потоке не нашлось'
            Write-BcfNote $(if ($unparsed) { "строк, которые не разобрались: $unparsed — смотри как есть: bcf log $query --raw" }
                            else { 'бэкенд отдал события без текста — смотри как есть: bcf log ' + $query + ' --raw' })
        }
    }
} elseif (-not $hadErr) {
    Write-Host ''
    Write-BcfWarn 'узел не сохранил ни ответа, ни ошибок'
    Write-BcfNote 'так выглядит узел, снятый по таймауту до первого байта ответа.'
}

Write-Host ''
Write-BcfNote "промпт: bcf log $query --prompt   ·   файлы: $(Get-BcfRelPath -Project $project -Path $dir)"
Write-Host ''
exit 0
