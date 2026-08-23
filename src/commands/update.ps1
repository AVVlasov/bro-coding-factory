# bcf update — обновить саму фабрику.
#
#   bcf update           подтянуть новую версию и показать, что изменилось
#   bcf update --check   только посмотреть, есть ли новее
#   bcf update --to <ref> перейти на конкретную версию/ветку
#
# ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ `git pull`. Тремя вещами, и каждая — про то, что обновление
# инструмента, который водит чужие проекты, не должно ничего сломать молча:
#
#   1. ЛОКАЛЬНЫЕ ПРАВКИ. Фабрику правят под себя — это её нормальный режим. Обновление
#      обязано остановиться на грязном дереве, а не перезаписать чужую работу и сообщить
#      об этом строкой в выводе git.
#   2. ЧТО ИМЕННО ИЗМЕНИЛОСЬ ДЛЯ ТЕБЯ. `git log` показывает коммиты; человеку нужно
#      знать другое — поменялись ли ШАБЛОНЫ (значит проекты стоит обновить командой
#      bcf install), поменялся ли ДВИЖОК (значит поведение прогона другое), поменялась
#      ли схема конфига (значит надо посмотреть свои config/*.json).
#   3. ОТКАТ. Версия до обновления называется явно, чтобы вернуться было одной командой,
#      а не археологией по рефлогу.

. (Join-Path $BcfRoot 'src\lib\tui.ps1')

$check = $script:BcfArgs -contains '--check'
$home_ = Get-BcfHome
$toRef = ''
for ($i = 0; $i -lt $script:BcfArgs.Count; $i++) {
    if ($script:BcfArgs[$i] -eq '--to') { $toRef = [string]$script:BcfArgs[$i + 1] }
}

Write-BcfTitle 'ОБНОВЛЕНИЕ ФАБРИКИ' $home_

function _git { param([string[]]$A) return (& git -C $home_ @A 2>&1 | Out-String).Trim() }

if (-not (Test-Path (Join-Path $home_ '.git'))) {
    Write-BcfFail 'фабрика установлена не из git — обновлять нечем'
    Write-BcfNote 'скачай новую версию поверх или склонируй репозиторий заново.'
    Write-Host ''
    exit 2
}

$before = _git @('rev-parse', '--short', 'HEAD')
$branch = _git @('rev-parse', '--abbrev-ref', 'HEAD')
$verBefore = Get-BcfVersion
Write-BcfField 'сейчас' "v$verBefore · $branch · $before"

# --- Локальные правки ------------------------------------------------------------------
$dirty = @(_git @('status', '--porcelain') -split "`r?`n" | Where-Object { $_.Trim() })
if ($dirty.Count -and -not $check) {
    Write-Host ''
    Write-BcfFail "в фабрике $($dirty.Count) незакоммиченных файлов — обновление остановлено"
    foreach ($d in ($dirty | Select-Object -First 8)) { Write-BcfNote $d.Trim() }
    if ($dirty.Count -gt 8) { Write-BcfNote "… ещё $($dirty.Count - 8)" }
    Write-Host ''
    Write-BcfNote 'фабрику правят под себя — это нормальный режим, и терять эти правки нельзя.'
    Write-BcfNote 'закоммить их (git -C "' + $home_ + '" commit -am "свои правки") или отложи (git stash),'
    Write-BcfNote 'затем повтори. Так обновление сольётся с твоими изменениями, а не затрёт их.'
    Write-Host ''
    exit 1
}

# --- Что нового ------------------------------------------------------------------------
Write-BcfDim 'смотрю удалённый репозиторий…'
$fetchFailed = $false
& git -C $home_ fetch --quiet --all --tags 2>$null
if ($LASTEXITCODE -ne 0) { $fetchFailed = $true }
# Офлайн сравнение с устаревшим upstream печатало «новее нет» — уверенное враньё,
# ради которого эту команду и открывают. Явный --to от сети не зависит: ref задан рукой.
if ($fetchFailed -and -not $toRef) {
    Write-Host ''
    Write-BcfFail 'fetch не удался: свежесть проверить нельзя, сравнение было бы с устаревшим upstream'
    Write-BcfNote 'проверь сеть и доступность удалённого репозитория, затем повтори.'
    Write-BcfNote 'известный ref можно обновиться и офлайн: bcf update --to <ref>'
    Write-Host ''
    exit 2
}
$upstream = _git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
if ($upstream -match 'no upstream|fatal') {
    Write-Host ''
    Write-BcfWarn "у ветки $branch нет upstream — сравнивать не с чем"
    Write-BcfNote 'задай его: git -C "' + $home_ + '" branch --set-upstream-to=origin/' + $branch
    Write-Host ''
    exit 1
}

$target = if ($toRef) { $toRef } else { $upstream }
$behind = [int](_git @('rev-list', '--count', "HEAD..$target"))
$ahead  = [int](_git @('rev-list', '--count', "$target..HEAD"))

if ($ahead -gt 0) {
    Write-BcfWarn "локально на $ahead коммитов впереди $target — это твои изменения"
    Write-BcfNote 'обновление их не тронет: слияние сохранит и то, и другое.'
}
if ($behind -eq 0) {
    Write-Host ''
    Write-BcfOk "новее нет — уже на $target"
    Write-Host ''
    exit 0
}

Write-Host ''
Write-BcfLine "  ДОСТУПНО ОБНОВЛЕНИЕ: $behind коммитов" 'White'
Write-Host ''
foreach ($l in (_git @('log', '--oneline', '--no-decorate', "-$([math]::Min($behind,12))", "HEAD..$target") -split "`r?`n")) {
    if ($l.Trim()) { Write-BcfDim $l.Trim() }
}
if ($behind -gt 12) { Write-BcfDim "… ещё $($behind - 12)" }

# --- Что это значит на практике --------------------------------------------------------
#
# Список коммитов не отвечает на вопрос «что мне теперь делать». Отвечают три факта ниже.
$changed = @(_git @('diff', '--name-only', "HEAD..$target") -split "`r?`n" | Where-Object { $_.Trim() })
$tplChanged   = @($changed | Where-Object { $_ -like 'templates/*' })
$engChanged   = @($changed | Where-Object { $_ -like 'harness/*' })
$cfgChanged   = @($changed | Where-Object { $_ -like 'templates/config/*' })
$cliChanged   = @($changed | Where-Object { $_ -like 'src/*' -or $_ -like 'bin/*' })

Write-Host ''
Write-BcfLine '  ЧТО ЭТО ЗНАЧИТ' 'White'
if ($tplChanged.Count) {
    Write-BcfWarn "шаблоны обвязки изменились ($($tplChanged.Count) файлов)"
    Write-BcfNote 'в уже настроенных проектах они НЕ обновятся сами: bcf install ставит только'
    Write-BcfNote 'недостающее. Пройдись по проектам и посмотри дифф — bcf install --dry.'
}
if ($cfgChanged.Count) {
    Write-BcfWarn "схема конфига изменилась ($($cfgChanged.Count) файлов в templates/config)"
    Write-BcfNote 'у существующих проектов новые ключи не появятся: их дописывает bcf init,'
    Write-BcfNote 'заполняя пустое. Проверь свои config/*.json на новые секции.'
}
if ($engChanged.Count) {
    Write-BcfNote "движок изменился ($($engChanged.Count) файлов) — поведение прогона могло поменяться."
    Write-BcfNote 'это подхватится сразу: движок один на все проекты и живёт в фабрике.'
}
if ($cliChanged.Count -and -not $tplChanged.Count -and -not $engChanged.Count) {
    Write-BcfNote 'изменился только сам CLI — проекты трогать не нужно.'
}

if ($check) {
    Write-Host ''
    Write-BcfNote 'обновить: bcf update'
    Write-Host ''
    exit 0
}

# --- Обновление ------------------------------------------------------------------------
Write-Host ''
if (-not (Get-BcfAssumeYes) -and (Test-BcfInteractive)) {
    if (-not (Read-BcfConfirm "обновить фабрику до $target?" $true)) {
        Write-BcfDim 'отменено'
        Write-Host ''
        exit 130
    }
}

$merge = _git @('merge', '--ff-only', $target)
if ($LASTEXITCODE -ne 0 -or $merge -match 'fatal|Not possible') {
    # Быстрая перемотка невозможна — значит есть локальные коммиты. Сливать автоматически
    # не будем: конфликт в инструменте, который водит чужие проекты, надо смотреть глазами.
    Write-BcfFail 'быстрая перемотка невозможна — у тебя есть свои коммиты поверх'
    Write-BcfNote $merge
    Write-BcfNote 'слей вручную: git -C "' + $home_ + '" merge ' + $target
    Write-BcfNote "вернуться к текущему состоянию: git -C `"$home_`" reset --hard $before"
    Write-Host ''
    exit 1
}

$after = _git @('rev-parse', '--short', 'HEAD')
$verAfter = Get-BcfVersion
Write-BcfOk "обновлено: $before → $after"
if ($verAfter -ne $verBefore) { Write-BcfOk "версия: v$verBefore → v$verAfter" }

# Самопроверка сразу после обновления: битую фабрику надо увидеть здесь, а не на прогоне.
Write-Host ''
Write-BcfLine '  САМОПРОВЕРКА' 'White'
$bad = 0
foreach ($must in @('bin\bcf.ps1', 'harness\graph.ps1', 'harness\loop.ps1', 'templates\config\harness.json', 'src\lib\ui.ps1')) {
    if (Test-Path (Join-Path $home_ $must)) { Write-BcfOk $must }
    else { Write-BcfFail "пропал файл: $must"; $bad++ }
}
$parseBad = 0
foreach ($f in (Get-ChildItem (Join-Path $home_ 'src'), (Join-Path $home_ 'bin'), (Join-Path $home_ 'harness') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    $e = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
    if ($e -and $e.Count) { $parseBad++; Write-BcfFail "не разбирается: $($f.Name) — строка $($e[0].Extent.StartLineNumber)" }
}
if ($parseBad -eq 0) { Write-BcfOk 'все скрипты разбираются' } else { $bad += $parseBad }

Write-Host ''
if ($bad) {
    Write-BcfFail "фабрика после обновления неисправна ($bad)"
    Write-BcfNote "откатиться: git -C `"$home_`" reset --hard $before"
    Write-Host ''
    exit 1
}
Write-BcfNote "откатиться на прежнюю версию: git -C `"$home_`" reset --hard $before"
Write-BcfNote 'проверить проект: bcf doctor   ·   обновить обвязку в проекте: bcf install'
Write-Host ''
exit 0
