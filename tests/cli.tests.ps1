# cli.tests.ps1 — дымовые тесты CLI. Без сети и без единого вызова модели.
#
#   pwsh tests/cli.tests.ps1
#
# ЧТО ЭТИ ТЕСТЫ ЛОВЯТ И ПОЧЕМУ ИМЕННО ЭТО. Все проверки здесь — про класс дефектов
# «команда отработала и соврала»: разбор аргументов, который молча роняет флаг в чужой
# список; таблица, которая падает на пустых данных; отчёт, который называет сухой план
# результатом; установка, которая перезаписывает правки владельца. Ошибки компиляции
# ловит парсер, а вот эти — только запуск.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Выключатели цвета снимаем на весь прогон: цвет и маскот здесь ПРЕДМЕТ проверки, а
# NO_COLOR стоит по умолчанию в агентских и CI-окружениях. Суита, красная в зависимости от
# того, из какой оболочки её запустили, перестаёт быть сигналом — её начинают игнорировать.
# Тест самого выключателя ставит переменную сам и возвращает как было.
$env:NO_COLOR = ''
$env:BCF_NO_COLOR = ''

$root = Split-Path $PSScriptRoot -Parent
$bcf = Join-Path $root 'bin\bcf.ps1'
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("bcf-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$script:pass = 0
$script:fail = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "  ✓ $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  ✗ $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Assert-True { param($Cond, [string]$Msg = 'ожидалось истинное') if (-not $Cond) { throw $Msg } }
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -notmatch $Pattern) {
        throw ($(if ($Msg) { "$Msg. " } else { '' }) + "не нашёл /$Pattern/ в:`n" + (($Text -split "`r?`n" | Select-Object -First 12) -join "`n"))
    }
}
function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Msg = '')
    if ($Text -match $Pattern) { throw ($(if ($Msg) { "$Msg. " } else { '' }) + "нашёл /$Pattern/, а не должен был") }
}

function Bcf {
    param([string[]]$CliArgs, [switch]$Ansi)

    # ЦВЕТ ПРОВЕРЯЕТСЯ ТОЛЬКО С -Ansi, И ЭТО НЕ КАПРИЗ ТЕСТА.
    #
    # PowerShell 7 при перенаправлении вывода вырезает управляющие последовательности сам
    # ($PSStyle.OutputRendering = PlainText). Тестовая обвязка ВСЕГДА перенаправляет —
    # значит проверка «в выводе есть ANSI» без этого ключа проверяла бы не фабрику, а
    # поведение оболочки, и была красной всегда. Просим потомка сохранить разметку.
    if ($Ansi) {
        $quoted = ($CliArgs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
        $cmd = "`$PSStyle.OutputRendering='Ansi'; & '$($bcf -replace "'", "''")' $quoted"
        $out = & pwsh -NoProfile -Command $cmd 2>&1 | Out-String
        return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
    }
    $all = @('-NoProfile', '-File', $bcf) + $CliArgs
    $out = & pwsh @all 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

function New-Sandbox {
    param([string]$Name, [switch]$NoGit)
    $p = Join-Path $sandboxRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'src\main.rs') -Value 'fn main() {}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p 'Cargo.toml') -Value "[package]`nname=`"t`"`nversion=`"0.1.0`"`nedition=`"2021`"" -Encoding UTF8
    if (-not $NoGit) {
        & git -C $p init -q 2>&1 | Out-Null
        & git -C $p add -A 2>&1 | Out-Null
        & git -C $p -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    }
    return $p
}

Write-Host ''
Write-Host "  ДЫМОВЫЕ ТЕСТЫ CLI   песочница: $sandboxRoot" -ForegroundColor Cyan
Write-Host ''

# --- Целостность исходников ------------------------------------------------------------
Write-Host '  целостность' -ForegroundColor White

# Регрессия и защита от целого класса дефектов. В verify.ps1 в путь к каталогу ролей попал
# байт BEL (0x07) — след неудачного экранирования "\a" при пакетной правке. Путь стал
# несуществующим, ВСЕ тестеры Фазы C молча пропускались строкой «предупреждение», а
# вердикт считался по оставшимся зелёным гейтам: PASS выдавался за проверку, которой не
# было. Глазами такой байт не виден, парсер на него не ругается — ловить можно только так.
function Get-RepoScripts {
    # Весь репозиторий, а не только движок: тот же дефект нашёлся в мета-судьях, куда
    # первая версия проверки не заглядывала. Судьи запускаются редко — поломка живёт в
    # них месяцами и всплывает ровно тогда, когда на них рассчитывают.
    return @(Get-ChildItem -Path $root -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '[\\/]\.bcf[\\/]|[\\/]node_modules[\\/]|[\\/]\.git[\\/]' })
}

It 'в скриптах нет управляющих байтов и висячих CR' {
    $bad = @()
    foreach ($f in (Get-RepoScripts)) {
        $text = Get-Content -Raw -LiteralPath $f.FullName
        for ($i = 0; $i -lt $text.Length; $i++) {
            $c = [int]$text[$i]
            # разрешены только табуляция, перевод строки и возврат каретки
            if ($c -lt 32 -and $c -ne 9 -and $c -ne 10 -and $c -ne 13) {
                $line = ($text.Substring(0, $i) -split "`n").Count
                $bad += "$($f.Name):$line  байт 0x{0:X2}" -f $c
                break
            }
            # Одиночный CR — тот же дефект неэкранированного `\r`, но ХУЖЕ: он не только
            # ломает путь, он невидим в выводе, потому что затирает начало строки.
            if ($c -eq 13 -and ($i + 1 -ge $text.Length -or [int]$text[$i + 1] -ne 10)) {
                $line = ($text.Substring(0, $i) -split "`n").Count
                $bad += "$($f.Name):$line  одиночный CR"
                break
            }
        }
    }
    Assert-True ($bad.Count -eq 0) ("порченые байты: " + ($bad -join '; '))
}

# Скрипт, который не разбирается, — это не «сломанная фича», это ветка, которой нет.
# Именно так ported-судьи и лежали: файл на месте, в реестре числится, а исполнить его
# нельзя. Парсер отвечает на этот вопрос за секунду и по всему репозиторию сразу.
It 'каждый скрипт репозитория разбирается' {
    $bad = @()
    foreach ($f in (Get-RepoScripts)) {
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
        if ($e -and $e.Count) { $bad += "$($f.Name):$($e[0].Extent.StartLineNumber)" }
    }
    Assert-True ($bad.Count -eq 0) ("не разбираются: " + ($bad -join '; '))
}

# Регрессия. В проверке доступности памяти стояло `docker version` с комментарием
# «падает быстро если нет». На Windows это неверно: при незапущенном Docker Desktop
# docker.exe не падает, а ЗАПУСКАЕТ его и ждёт готовности. Наблюдалось: `bcf run queue`
# висел больше шести минут, не напечатав ни строки, поднял Docker Desktop на машине
# человека и вывесил поверх всего его диалог об ошибке. Снаружи — намертво зависший
# прогон, зависший ещё до первой задачи.
It 'проба демона docker отвечает мгновенно и ничего не запускает' {
    . (Join-Path $root 'harness\lib\docker.ps1')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Test-BcfDockerDaemon
    $sw.Stop()
    Assert-True ($sw.ElapsedMilliseconds -lt 5000) "проба заняла $($sw.ElapsedMilliseconds) мс — она обязана отвечать мгновенно"

    # И сам источник: возврат к `docker version` в проверке здоровья вернёт зависание.
    $bridge = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\lib\m13-bridge.ps1')
    $health = [regex]::Match($bridge, '(?ms)function Get-M13Health\s*\{.*?\n\}')
    Assert-True $health.Success 'Get-M13Health не найдена — проверять нечего'
    # Ищем ВЫЗОВ, а не упоминание: в коде стоит комментарий, объясняющий, почему так
    # делать нельзя, и он обязан там остаться.
    $call = [regex]::Match($health.Value, '(?m)^[^#\r\n]*docker\s+version')
    Assert-True (-not $call.Success) 'в проверке здоровья снова вызывается docker version — на Windows он поднимает Docker Desktop и ждёт'
}

# Инструкция, обещающая несуществующую команду, — тот же дефект, что и врущий вывод:
# человек делает по ней и получает «Неизвестная команда». Docs дрейфуют молча, поэтому
# сверяем их с диспетчером механически.
It 'команды из документации существуют' {
    $known = @()
    $disp = Get-Content -Raw -LiteralPath (Join-Path $root 'bin\bcf.ps1')
    foreach ($m in [regex]::Matches($disp, "(?m)^\s+'([a-z-]+)'\s*=\s*@\{\s*file")) { $known += $m.Groups[1].Value }
    Assert-True ($known.Count -gt 10) "в диспетчере нашлось всего $($known.Count) команд — сломался разбор"

    # Подкоманды и флаги разбираются своими командами, диспетчер о них не знает.
    $subs = @('new','why','show','loop','night','queue','review','init','status','ask','down',
              'stats','list','register','audit','wiki','log')

    $bad = @()
    foreach ($doc in @('README.md', 'docs\WORKFLOW.md', 'docs\CLI.md', 'docs\SETUP.md')) {
        $path = Join-Path $root $doc
        if (-not (Test-Path $path)) { continue }
        $text = Get-Content -Raw -LiteralPath $path
        foreach ($m in [regex]::Matches($text, 'bcf ([a-z][a-z-]+)')) {
            $c = $m.Groups[1].Value
            if ($c -in $known -or $c -in $subs) { continue }
            $bad += "$doc → bcf $c"
        }
    }
    Assert-True (-not $bad.Count) ("документация обещает несуществующее: " + (($bad | Select-Object -Unique) -join '; '))
}

# --- Диспетчер -----------------------------------------------------------------------
Write-Host '  диспетчер' -ForegroundColor White

It 'help перечисляет команды' {
    $r = Bcf @('--help')
    Assert-Match $r.Out 'bcf <команда>'
    foreach ($c in @('init', 'install', 'doctor', 'run', 'memory', 'meta')) { Assert-Match $r.Out "\b$c\b" }
}

It 'неизвестная команда — код 2, а не тихий успех' {
    $r = Bcf @('nosuchcommand')
    Assert-True ($r.Code -eq 2) "ожидал код 2, получил $($r.Code)"
    Assert-Match $r.Out 'Неизвестная команда'
}

It 'version печатает версию из VERSION' {
    $r = Bcf @('--version')
    $v = (Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim()
    Assert-Match $r.Out ([regex]::Escape($v))
}

# Регрессия: switch без break проверял и общее правило '^-', и флаг уезжал дальше
# как неизвестный аргумент харнесса.
It 'общий флаг не утекает в подкоманду' {
    $p = New-Sandbox 'flags'
    $r = Bcf @('detect', '--project', $p, '--no-color')
    Assert-NoMatch $r.Out 'no-color'
    Assert-Match $r.Out 'РАЗБОР ПРОЕКТА'
}

# --- bcf без аргументов ----------------------------------------------------------------
Write-Host ''
Write-Host '  запуск без аргументов' -ForegroundColor White

It 'печатает карточку состояния, а не список команд' {
    $p = New-Sandbox 'launch-banner'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('--project', $p)
    Assert-Match $r.Out 'BRO CODING FACTORY'
    foreach ($row in @('проект', 'прогон', 'бэкенды', 'память', 'тарифы', 'подписки')) {
        Assert-Match $r.Out $row "в карточке нет строки «$row»"
    }
    # То, чего нет, называется словом «нет» и ценой, а не прячется и не выдумывается.
    Assert-Match $r.Out 'тарифы\s+не заданы'
    Assert-Match $r.Out 'прогон\s+ещё не было' 'карточка молчит о том, был ли прогон'
    Assert-NoMatch $r.Out 'bcf <команда>' 'вместо состояния напечатана справка'
}

It 'без консоли уступает место печати и не падает на чтении клавиши' {
    $p = New-Sandbox 'launch-noninteractive'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('--project', $p)
    Assert-True ($r.Code -eq 0) "ожидал 0, получил $($r.Code)"
    Assert-Match $r.Out 'интерактивный выбор недоступен'
    Assert-Match $r.Out 'bcf doctor' 'doctor подан как режим run, хотя это своя команда'
}

# Кадр выбора иначе не покрыт ничем: крэш в его построении вылезал бы только у человека
# за клавиатурой — там, где его нельзя ни залогировать, ни воспроизвести.
It 'кадр выбора строится на непустом бэклоге' {
    $p = New-Sandbox 'launch-screen'
    Bcf @('install', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-base.md') -Value @"
# TASK-01 — основа

## Файлы
- ``src/a.rs``
"@
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-02-next.md') -Value @"
# TASK-02 — следом

**Gate-вход:** TASK-01

## Файлы
- ``src/b.rs``
"@
    $r = Bcf @('--screen', '--project', $p)
    Assert-True ($r.Code -eq 0) "кадр не построился: $($r.Out)"
    Assert-Match $r.Out 'что запускаем'
    Assert-Match $r.Out '▸'
    Assert-Match $r.Out '\[×\] TASK-01' 'готовая задача не отмечена по умолчанию'
    Assert-Match $r.Out '\[ \] TASK-02' 'заблокированная задача отмечена'
    Assert-Match $r.Out 'ждёт 01'
    Assert-Match $r.Out 'сметы нет' 'без прогонов смета обязана отсутствовать, а не считаться из воздуха'
}

It 'кадр выбора строится и на пустом бэклоге' {
    $p = New-Sandbox 'launch-screen-empty'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('--screen', '--project', $p)
    Assert-True ($r.Code -eq 0) "кадр не построился на пустом бэклоге: $($r.Out)"
    Assert-Match $r.Out 'очередь пуста'
}

It 'setup --check не меняет PATH и сообщает состояние' {
    $r = Bcf @('setup', '--check')
    Assert-Match $r.Out 'КОМАНДА bcf'
    Assert-True ($r.Code -in @(0, 1)) "неожиданный код $($r.Code)"
}

# --- init: экраны мастера ---------------------------------------------------------------
Write-Host ''
Write-Host '  init — восемь экранов' -ForegroundColor White

It 'все восемь шагов имеют заголовок «шаг N / 8»' {
    $p = New-Sandbox 'init-steps'
    $r = Bcf @('init', '--yes', '--project', $p)
    for ($i = 1; $i -le 8; $i++) {
        Assert-Match $r.Out "шаг $i / 8" "нет заголовка шага $i"
    }
}

It 'шаг 1 показывает маскот и недавние проекты' {
    $p = New-Sandbox 'init-step1'
    $r = Bcf @('init', '--yes', '--project', $p)
    Assert-Match $r.Out 'ГДЕ ПРОЕКТ'
    Assert-Match $r.Out 'BRO CODING FACTORY'
    # Маскот рисуется полублоками — без них шапка пустая.
    Assert-Match $r.Out '[▀▄]' 'маскот не нарисован'
    Assert-Match $r.Out 'состояние сохраняется в \.bcf/init\.json'
}

It 'вывод несёт ANSI-цвет, а не только текст' {
    $p = New-Sandbox 'init-color'
    $r = Bcf @('init', '--yes', '--project', $p) -Ansi
    Assert-Match $r.Out "`e\[" 'в выводе нет ни одной ANSI-последовательности'
}

# Регрессия к сути: цвет обязан гаснуть по общепринятому признаку, иначе вывод в файл
# засоряется управляющими последовательностями, а их потом читают глазами.
It 'BCF_NO_COLOR полностью выключает цвет' {
    $p = New-Sandbox 'init-nocolor'
    $old = $env:BCF_NO_COLOR
    $env:BCF_NO_COLOR = '1'
    try {
        $r = Bcf @('init', '--yes', '--project', $p)
        Assert-NoMatch $r.Out "`e\[" 'при BCF_NO_COLOR в выводе остались ANSI-коды'
        Assert-Match $r.Out 'шаг 1 / 8' 'текст пропал вместе с цветом'
    } finally { $env:BCF_NO_COLOR = $old }
}

# --- Отчёт мастера не выдаёт шаблон за выбор владельца ----------------------------------
#
# `bcf install` создаёт config/harness.json из ЗАПОЛНЕННОГО шаблона, а init потом дописывает
# в него разбор. Пока «уже заполнено» проверялось сравнением с пустотой, первая же
# инициализация отчитывалась «ОСТАВЛЕНО КАК БЫЛО: agent.command, productPaths» — о файле,
# которого до этой команды не существовало. Класс дефекта тот же, что и всюду здесь: отчёт,
# который врёт, хуже отсутствующего, потому что человек по нему НЕ идёт проверять.

It 'первая инициализация не выдаёт шаблонные значения за настройки владельца' {
    $p = New-Sandbox 'init-fresh-report'
    $r = Bcf @('init', '--yes', '--project', $p)
    Assert-NoMatch $r.Out 'ОСТАВЛЕНО КАК БЫЛО' 'на пустом проекте беречь нечего'
    Assert-Match   $r.Out 'A\s+config/harness\.json' 'созданный конфиг обязан быть помечен как A'
    Assert-NoMatch $r.Out 'M\s+config/harness\.json' 'тот же файл не может быть и создан, и изменён'
}

It 'повторная инициализация бережёт заполненное и говорит об этом' {
    $p = New-Sandbox 'init-second-report'
    $null = Bcf @('init', '--yes', '--project', $p)
    # Ставим значение, которого init угадать не может: подпись владельца на конфиге.
    $cfgFile = Join-Path $p 'config\harness.json'
    $c = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
    $c.graph.roles.worker.backend = 'my-own-cli'
    ($c | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgFile -Encoding UTF8

    $r = Bcf @('init', '--yes', '--project', $p)
    Assert-Match $r.Out 'ОСТАВЛЕНО КАК БЫЛО' 'второй проход обязан сказать, что не тронул'
    $after = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
    Assert-True ($after.graph.roles.worker.backend -eq 'my-own-cli') 'чужой бэкенд перезаписан мастером'
    Assert-Match $r.Out 'M\s+config/harness\.json' 'существовавший конфиг обязан быть помечен как M'
}

# --- Модель роли берётся из настроек самого CLI -----------------------------------------
#
# init оставлял model пустым и сам же объявлял это стопором прогона, отправляя человека
# вписывать руками то, что записано в настройках его же CLI. Проверяем инвариант, который
# не зависит от машины: read-only-псевдоним обязан отвечать тем же, что и его оригинал —
# иначе критик поедет на модели, которой у codex нет.

It 'песочный псевдоним бэкенда знает ту же модель, что и оригинал' {
    . (Join-Path $root 'src\lib\backends.ps1')
    $a = Get-BcfBackendDefaultModel -Name 'codex'
    $b = Get-BcfBackendDefaultModel -Name 'codex-ro'
    Assert-True ($a.Model -eq $b.Model) "codex='$($a.Model)', codex-ro='$($b.Model)' — псевдоним разошёлся с оригиналом"
    $c = Get-BcfBackendDefaultModel -Name 'нет-такого-cli'
    Assert-True ($c.Model -eq '') 'неизвестный бэкенд обязан отвечать пустотой, а не выдумкой'
}

# --- Занятый порт памяти ----------------------------------------------------------------
#
# Порт 5433 записан дефолтом во все установки фабрики, поэтому вторая установка на машине
# садится на чужой контейнер. Compose падает на «port is already allocated», а мостик
# советовал «повтори вручную» — совет, который заведомо не работает. Проверяем то, чем это
# заменено: занявший НАЗЫВАЕТСЯ, свободный порт ПОДБИРАЕТСЯ, исправление ложится в конфиг
# ПРОЕКТА, а не фабрики.

It 'занятый порт виден, а свободный подбирается' {
    . (Join-Path $root 'harness\lib\docker.ps1')

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $busy = ([System.Net.IPEndPoint]$listener.Server.LocalEndPoint).Port
    try {
        Assert-True (-not (Test-BcfPortFree -Port $busy)) "порт $busy занят слушателем, а проверка считает его свободным"
        $free = Find-BcfFreePort -From $busy
        Assert-True ($free -ne 0) 'свободного порта не нашлось вовсе'
        Assert-True ($free -ne $busy) 'подбор вернул занятый порт'
        Assert-True (Test-BcfPortFree -Port $free) "подобранный порт $free на самом деле занят"
    } finally { try { $listener.Stop() } catch { } }
}

It 'порт памяти чинится в конфиге проекта, а не фабрики' {
    . (Join-Path $root 'harness\lib\docker.ps1')
    . (Join-Path $root 'harness\lib\memory-port.ps1')

    $p = New-Sandbox 'memory-port'
    $factoryCfg = Join-Path $p 'factory-memory.config.json'
    Set-Content -LiteralPath $factoryCfg -Encoding UTF8 -Value (@{
        host = 'localhost'; port = 5433; database = 'bcf_agent_memory'; user = 'bcf'
        embedding_dim = 1024; embedding_model = 'text-embedding-bge-m3'
    } | ConvertTo-Json)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $busy = ([System.Net.IPEndPoint]$listener.Server.LocalEndPoint).Port
    try {
        $r = Resolve-BcfMemoryPort -Wanted $busy -Container 'bcf-agent-memory' -ConfigPath $factoryCfg -ProjectRoot $p
        Assert-True ($r.Changed) 'занятый порт остался прежним'
        Assert-True (-not $r.Error) "подбор отказал: $($r.Error)"
        Assert-True ($r.Port -ne $busy) 'подставлен тот же занятый порт'

        $projCfg = Join-Path $p 'config\memory.config.json'
        Assert-True (Test-Path $projCfg) 'исправление не записано в конфиг проекта'
        $j = Get-Content -Raw -LiteralPath $projCfg | ConvertFrom-Json
        Assert-True ([int]$j.port -eq $r.Port) 'в конфиге проекта не тот порт, что вернула функция'
        # Остальные ключи обязаны доехать: иначе починили порт и потеряли модель эмбеддингов.
        Assert-True ($j.embedding_dim -eq 1024) 'конфиг проекта потерял размерность эмбеддингов'
        # Фабричный образец не трогаем: он общий для всех проектов машины.
        $f = Get-Content -Raw -LiteralPath $factoryCfg | ConvertFrom-Json
        Assert-True ([int]$f.port -eq 5433) 'фабричный конфиг переписан — сломано всем остальным проектам'
    } finally { try { $listener.Stop() } catch { } }
}

It 'свободный порт не переписывает конфиги' {
    . (Join-Path $root 'harness\lib\docker.ps1')
    . (Join-Path $root 'harness\lib\memory-port.ps1')

    $p = New-Sandbox 'memory-port-free'
    $free = Find-BcfFreePort -From 5600
    $r = Resolve-BcfMemoryPort -Wanted $free -Container 'bcf-agent-memory' -ConfigPath '' -ProjectRoot $p
    Assert-True (-not $r.Changed) 'порт был свободен, а функция всё равно его сменила'
    Assert-True ($r.Port -eq $free) 'свободный порт подменён'
    Assert-True (-not (Test-Path (Join-Path $p 'config\memory.config.json'))) 'конфиг создан там, где чинить было нечего'
}

# --- Пустая память ≠ сломанная запись ---------------------------------------------------
#
# «Уроков почти нет: чтение работает, ЗАПИСЬ — нет» печаталось безусловно и в трёх местах
# сразу (граф, doctor, memory status). На свежей базе это неправда — писать было нечему.
# Диагноз без основания обесценивает ровно тот текст, ради которого написан: когда запись
# отвалится по-настоящему, строку прочитают как жёлтый фон, который тут всегда.

It 'пустая база памяти не объявляется сломанной записью' {
    . (Join-Path $root 'harness\lib\graph-memory.ps1')
    $p = New-Sandbox 'memory-verdict'

    $v = Get-BcfLearningVerdict -Lessons 0 -Project $p
    Assert-True ($v.Level -eq 'empty') "прогонов не было, а вердикт '$($v.Level)'"
    Assert-NoMatch $v.Text 'ЗАПИСЬ' 'о сломанной записи сказано там, где не было ни одного прогона'

    # Появился прогон с журналом — и та же пустая база становится настоящим диагнозом.
    $runDir = Join-Path $p '.bcf\graph\g_test'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    Set-Content -LiteralPath (Join-Path $runDir 'journal.jsonl') -Value '{"event":"run-start"}' -Encoding UTF8
    $v2 = Get-BcfLearningVerdict -Lessons 0 -Project $p
    Assert-True ($v2.Level -eq 'broken') "после прогона пустая база обязана быть диагнозом, получено '$($v2.Level)'"
    Assert-Match $v2.Text 'ЗАПИСЬ'

    $v3 = Get-BcfLearningVerdict -Lessons 7 -Project $p
    Assert-True ($v3.Level -eq 'ok') "уроки есть, а вердикт '$($v3.Level)'"
}

# Проба окружения — не прогон. Пока это не различалось, пять запусков `bcf doctor` подряд
# давали «прогонов было 5, а уроков 0 — запись не работает» на базе, в которую ни один узел
# не писал: проверка окружения сама себе фабриковала диагноз.
It 'проба doctor не считается прогоном в вердикте об обучении' {
    . (Join-Path $root 'harness\lib\graph-memory.ps1')
    $p = New-Sandbox 'memory-verdict-doctor'

    foreach ($n in @('g_doc1', 'g_doc2')) {
        $d = Join-Path $p ".bcf\graph\$n"
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'journal.jsonl') -Encoding UTF8 `
            -Value '{"event":"run-start","name":"doctor","doctor":true}'
    }
    $v = Get-BcfLearningVerdict -Lessons 0 -Project $p
    Assert-True ($v.Level -eq 'empty') "пробы doctor сосчитаны прогонами: вердикт '$($v.Level)', прогонов $($v.Runs)"
    Assert-True ($v.Runs -eq 0) "прогонов насчитано $($v.Runs), а был только doctor"
}

# --- Расщеплённый прогон: цикл и верификация обязаны работать в ОДНОМ дереве ------------
#
# Цена этого дефекта измерена: 2026-08-06, прогон g_20260806-132023. Цикл работал в
# worktree задачи, а verify.ps1 звался без корня — и брал его из $env:BCF_PROJECT_ROOT,
# который указывает на ОСНОВНОЙ проект. Итог: проверки исполнились на дереве без работы
# агента (и потому были красными), вердикт лёг в основное дерево, цикл искал его у себя,
# не находил и рапортовал агенту «verify не дал вердикта» — то есть требовал от него
# починить дефект обвязки. Агент сделал задачу правильно, задача умерла по loop-detection,
# следом каскадом не поехали остальные восемь.
#
# Проверка статическая: вызов verify.ps1 в цикле обязан нести -ProjectRoot. Живьём это
# ловится только сорокаминутным прогоном, то есть на практике не ловится.

It 'цикл зовёт верификацию с явным корнем проекта' {
    $loop = Get-Content -Raw (Join-Path $root 'harness\loop.ps1')

    $m = [regex]::Match($loop, '(?s)\$vArgs\s*=\s*@\((.*?)\)')
    Assert-True $m.Success 'не нашёл сборку аргументов verify.ps1 в loop.ps1'
    Assert-Match $m.Groups[1].Value '-ProjectRoot' 'verify.ps1 зовётся без -ProjectRoot: верификация уйдёт в дерево из окружения'

    # Окружение подменяется тоже: тестеры и судья — отдельные процессы, они читают корень
    # из него, а не из нашего параметра.
    Assert-Match $loop '\$env:BCF_PROJECT_ROOT\s*=\s*\$root' 'перед verify не выставляется BCF_PROJECT_ROOT на корень цикла'
}

# --- Вердикт переживает worktree ---------------------------------------------------------
#
# Вердикт пишется в дерево задачи (только там проверки честные) и обязан дожить до общей
# ветки. По нему считается готовность СЛЕДУЮЩЕЙ волны и состояние бэклога. Прогон
# g_20260806-141305: TASK-01 слита за семь минут, восемь задач так и остались «ждёт», отчёт
# назвал это «не закрыто» — работа сделана, а бухгалтерия её не увидела.
#
# Раньше он доживал копией мимо git, потому что каталог вердиктов лежал в .gitignore.
# Теперь это обычный файл в git: PASS приезжает слиянием, FAIL публикуется коммитом.

It 'граф доводит вердикт задачи до общей ветки' {
    $g = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')

    Assert-NoMatch $g 'Copy-Item[^\r\n]*\$vf' `
        'вердикт снова копируется мимо git — на второй машине его не будет'

    $iRead = $g.IndexOf('$vf = Join-Path $wt')
    Assert-True ($iRead -ge 0) 'не нашёл чтение вердикта из worktree'
    $tail = $g.Substring($iRead)

    # FAIL публикуется ДО удаления рабочего дерева, иначе публиковать будет нечего.
    $iPub  = [regex]::Match($tail, 'Publish-TaskVerdict').Index
    $iDrop = [regex]::Match($tail, 'Remove-TaskWorktree').Index
    Assert-True ($iPub -gt 0) 'FAIL-вердикт никуда не публикуется — человек не увидит ремедиацию'
    Assert-True ($iPub -lt $iDrop) 'публикация вердикта идёт после удаления worktree — публиковать будет нечего'

    # ЗАКРЫТИЕ — ЭТО «СЛИТО», А НЕ «В СВОЕЙ ВЕТКЕ ЗЕЛЕНО».
    #
    # Пока PASS переносился до интеграции, задача с провалившимся слиянием объявлялась
    # закрытой: 2026-08-06 TASK-02 и TASK-03 получили PASS в основном дереве, код туда не
    # попал, и следующая волна честно взялась строить TASK-04 поверх несуществующих стабов.
    Assert-Match $tail '(?s)-not \$isPass.*?Publish-TaskVerdict' `
        'вердикт публикуется без проверки исхода — PASS закроет несведённую задачу'
    # Работа задачи коммитится ДО чтения вердикта, иначе вердикт не попадёт в ветку и
    # слияние не принесёт его в общее дерево. Сообщение коммита строится отдельной
    # переменной (New-BcfCommitMessage, M-06): коммит несёт трейлеры Task/Run-Id/Role/
    # Model/Backend, поэтому здесь ищем переменную коммита, а не литеральную строку.
    $head = $g.Substring(0, $iRead)
    Assert-Match $head '(?s)git -C \$wt add -A.*?git -C \$wt @\w+ commit -m \$\w+' `
        'вердикт читается раньше коммита ветки — слияние принесёт код без вердикта'
    Assert-Match $head '(?s)New-BcfCommitMessage[^\r\n]*Subject "\$\{task\}: работа агента"' `
        'сообщение коммита работы задачи не строится через New-BcfCommitMessage — трейлеры прогона потеряны'
    Assert-Match $head "New-BcfCommitMessage[\s\S]*?-Task \`$task[\s\S]*?-RunId \(Get-GraphRunId\)" `
        'коммит работы задачи не несёт Task/Run-Id — разбор дефекта по одному git log станет гаданием'
}

# --- Гейт, который нечем выполнить -------------------------------------------------------
#
# Проверка без инструмента — не строгий гейт, а красный свет по причине, не связанной с
# работой. npm вдобавок маскирует причину: на отсутствующий локальный бинарь он подставляет
# одноимённый пакет из реестра, и `npx tsc` отвечает «This is not the tsc command you are
# looking for» — в логе это выглядит поломкой компилятора. 2026-08-06 незаявленный
# typescript уронил слияние двух готовых задач волны.

It 'doctor называет проверку, для которой нет инструмента' {
    $p = New-Sandbox 'doctor-missing-bin'
    Bcf @('install', '--project', $p) | Out-Null

    $cfgFile = Join-Path $p 'config\harness.json'
    $c = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json
    $c.backpressure.typecheck = @('npx --no-install tsc --noEmit')
    ($c | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgFile -Encoding UTF8

    $r = Bcf @('doctor', '--no-probe', '--project', $p)
    Assert-Match $r.Out 'гейт нечем выполнить' 'отсутствующий инструмент проверки не назван'
    Assert-Match $r.Out 'tsc' 'не назван сам инструмент'

    # А когда бинарь на месте — молчим: ложная тревога на каждом прогоне обесценивает строку.
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'node_modules\.bin') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'node_modules\.bin\tsc.cmd') -Value 'echo tsc' -Encoding UTF8
    $r2 = Bcf @('doctor', '--no-probe', '--project', $p)
    Assert-NoMatch $r2.Out 'гейт нечем выполнить' 'инструмент на месте, а doctor всё равно жалуется'
}

# --- Закрытые задачи не тянут за собой планировщика ---------------------------------------
#
# Планировщик — рамочная роль на дорогой модели, и зовут его ТОЛЬКО при коллизии владения.
# Пока в анализ попадали закрытые задачи, каждый повторный прогон по бэклогу с
# исправлениями звал его ради «разведения» новой задачи с той, что закрыта и не поедет:
# 2026-08-06 «строго последовательно: TASK-06 → TASK-11» — сериализация, не меняющая ничего.

It 'коллизии владения считаются без закрытых задач' {
    $g = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')

    $m = [regex]::Match($g, '(?s)\$owner = @\{\}.*?\$undeclared = @\([^\r\n]*')
    Assert-True $m.Success 'не нашёл расчёт коллизий владения в графе очереди'
    Assert-Match $m.Value 'if \(\$t\.Pass\) \{ continue \}' 'закрытые задачи участвуют в анализе коллизий'
    Assert-Match $m.Value '-not \$_\.Pass -and -not \$_\.Files\.Count' 'закрытая задача без объявленных файлов тянет ревизию плана'
}

# --- Находки приёмки входят в вердикт прогона ---------------------------------------------
#
# Гейты задач детерминированы и ловят своё; критики ловят то, чего гейт не видит. Пока их
# работа не входила в итог, прогон g_20260806-195014 напечатал «итог: ок» и вернул ноль,
# имея восемь семантических конфликтов, четыре из них P1 — включая «оператор может
# записать пациента в отсутствие врача». Человек читает последнюю строку и уходит с ней.

It 'прогон с находками приёмки не называется «ок»' {
    $g = Get-Content -Raw (Join-Path $root 'harness\graph.ps1')
    Assert-Match $g "has 'findings'\) -and \[int\]" 'итог не смотрит на находки приёмки'
    Assert-Match $g "ЗАМЕЧАНИЯ" 'нет отдельного вердикта для «задачи закрыты, но приёмка нашла»'

    $q = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')
    Assert-Match $q 'Schema \$criticSchema' 'критик отвечает свободным текстом — находки нечем сосчитать'
    Assert-Match $q 'findings = \$findAll\.Count' 'граф не возвращает число находок наверх'
    Assert-Match $q "severity -eq 'P1'" 'находки не разделены по тяжести — вердикт не отличит опечатку от потери данных'
}

# --- Вопрос, который некому услышать, не задаётся ------------------------------------------
#
# graph.ps1 спрашивает подтверждение перед роем агентов — это правильно и стоит дёшево
# ровно один раз. Но CLI добавлял `-Yes` только в интерактивном запуске, и запуск из
# скрипта упирался в Read-Host на stdin, которого никто не видит: 2026-08-07 прогон
# простоял 2 ч 20 мин, не напечатав ни строки и не запустив ни одного агента. Молчаливое
# ожидание неотличимо от работы — это худший вид отказа.

It 'запуск графа не упирается в вопрос без адресата' {
    $r = Get-Content -Raw (Join-Path $root 'src\commands\run.ps1')
    Assert-NoMatch $r "if \(\$live -or \(Get-BcfAssumeYes\)\) \{ \$a \+= '-Yes' \}" `
        'подтверждение пробрасывается только в интерактивном запуске'
    Assert-Match $r "(?m)^\s*\`$a \+= '-Yes'" 'CLI не передаёт движку принятое решение'

    # Движок обязан отказать, а не ждать, когда отвечать некому.
    $g = Get-Content -Raw (Join-Path $root 'harness\graph.ps1')
    Assert-Match $g 'IsInputRedirected -or \[Console\]::IsOutputRedirected' `
        'движок задаёт вопрос, не проверив, есть ли кому отвечать'
    $iCheck = $g.IndexOf('IsInputRedirected')
    $iAsk   = $g.IndexOf('Read-Host "Запускать?')
    Assert-True ($iCheck -gt 0 -and $iCheck -lt $iAsk) 'проверка стоит после вопроса — ждать всё равно будет'
}

# --- Задача, не сделавшая ничего, не может быть закрыта -----------------------------------
#
# Гейты проверяют СОСТОЯНИЕ ДЕРЕВА, а не работу задачи: на нетронутом дереве они зелены по
# определению — они проходили и до неё. Прогон g_20260808-120927: четыре задачи подряд не
# изменили ни строки, получили PASS «все гейты зелёные», слились вхолостую, их ветки
# удалили как отработанные, а итог отчитался «PASS 19/19, ок». Дефекты P1, ради которых
# задачи заводились, остались в коде и стали считаться закрытыми.

It 'пустой diff задачи — провал, а не предупреждение' {
    $v = Get-Content -Raw (Join-Path $root 'harness\verify.ps1')

    Assert-Match $v '\$emptyDiff = \[string\]::IsNullOrWhiteSpace\(\$diffFull\)' `
        'пустой diff не вычисляется как признак'
    Assert-Match $v 'if \(\$emptyDiff\) \{ \$gateFailures \+=' `
        'пустой diff не попадает в список проваленных гейтов'

    # Проверка обязана стоять ДО остальных гейтов: они говорят о дереве, а не о работе.
    $iEmpty  = $v.IndexOf('if ($emptyDiff) { $gateFailures +=')
    $iChecks = $v.IndexOf('if ($checksFailed) { $gateFailures +=')
    Assert-True ($iEmpty -gt 0 -and $iEmpty -lt $iChecks) 'гейт «работа была» стоит после проверок дерева'

    # И это больше не «предупреждение»: слово меняет то, как строку читают.
    Assert-NoMatch $v 'ПРЕДУПРЕЖДЕНИЕ: diff пуст' 'пустой diff всё ещё подаётся как предупреждение'
}

# --- Позвали человека — покажи, зачем ------------------------------------------------------
#
# Цикл встаёт на friction-триггере (зависимости, CI, авторизация, крупное удаление) и пишет
# записку с причиной. Записка писалась в каталог САМОЙ ФАБРИКИ, а сообщение отправляло
# человека в `.bcf/human-callout.md` проекта — файла по этому адресу не было. Плюс один файл
# на всю фабрику затирался каждой следующей задачей любого проекта. 2026-08-08 две готовые
# задачи встали, и причину пришлось восстанавливать из config/triggers.json вручную.

It 'записка человеку пишется в проект и переживает worktree' {
    $t = Get-Content -Raw (Join-Path $root 'harness\triggers.ps1')
    Assert-Match $t '\$stateDir = Join-Path \$Repo ' 'записка по-прежнему пишется мимо проекта'
    Assert-NoMatch $t "calloutFile = Join-Path \`$PSScriptRoot 'human-callout\.md'" `
        'записка всё ещё уходит в каталог фабрики'
    Assert-Match $t "callouts\b" 'нет копии на задачу — соседи по волне затрут общий файл'

    $g = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')
    Assert-Match $g 'callouts\\\$task\.md' 'граф не переносит записку из worktree в проект'
    Assert-Match $g 'требует ревью человека' 'причина остановки не названа в отчёте'
}

# --- Не ответивший критик ≠ чистая приёмка -------------------------------------------------
#
# Узел роли возвращает пустоту, когда агент не дал текста: протух путь к CLI, кончилась
# квота, оборвался поток. 2026-08-08 у codex сменился хэш сборки в пути — все три критика
# упали по три попытки, отчёт написал «Находок нет», а итог «ок». Смотреть было некому, и
# именно это обязано быть написано.

It 'приёмка без ответа критиков не выдаётся за чистую' {
    $q = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')
    Assert-Match $q '\$criticsFailed = @\(\$acceptance \| Where-Object \{' 'граф не считает не ответивших критиков'
    Assert-Match $q 'Приёмка НЕ ВЫПОЛНЕНА' 'отчёт не отличает «не нашли» от «не смотрели»'
    Assert-Match $q 'criticsFailed = \$criticsFailed' 'число не поднимается наверх, в вердикт прогона'

    $g = Get-Content -Raw (Join-Path $root 'harness\graph.ps1')
    Assert-Match $g "has 'criticsFailed'\) -and \[int\]" 'итог не смотрит на несработавшую приёмку'
    Assert-Match $g 'ПРИЁМКА НЕ ВЫПОЛНЕНА' 'нет отдельного вердикта для несработавшей приёмки'

    # Ответ прозой = схема не доехала = валидации не было. Такой ответ не находки.
    Assert-Match $q '\$_ -is \[string\]' 'строковый ответ критика считается структурой'
}

# --- Ветка барьера видит только общее состояние графа --------------------------------------
#
# Invoke-Barrier пересоздаёт ветку ИЗ ТЕКСТА в другом runspace: обычные переменные скрипта
# там не существуют. `-Schema $criticSchema` превращался в `-Schema $null` — узел молча
# возвращал прозу вместо структуры, а блок фактов уходил пустым. 2026-08-08: журнал писал
# «критик: находок 1», отчёт — «Находок нет», итог — «ок»; в промпте не было ни схемы, ни
# фактов, и никто этого не заметил, потому что всё выглядело зелёным.

It 'критики получают схему и факты через состояние графа, а не через переменные' {
    $q = Get-Content -Raw (Join-Path $root 'harness\graphs\queue.graph.ps1')

    Assert-Match $q 'Set-GraphVar criticSchema' 'схема не положена в общее состояние'
    Assert-Match $q 'Set-GraphVar criticFacts'  'факты проверок не положены в общее состояние'
    Assert-Match $q '-Schema \(Get-GraphVar criticSchema\)' 'критик по-прежнему берёт схему из переменной скрипта'
    Assert-NoMatch $q 'Invoke-Node -Role critic[^
]*-Schema \$criticSchema' 'остался вызов со схемой из переменной — в runspace она пуста'
    Assert-NoMatch $q '\$gateFacts\$criticTail' 'факты подставляются переменной, которой в ветке нет'
}

It 'мастер сохраняет и убирает состояние .bcf/init.json' {
    $p = New-Sandbox 'init-state'
    $r = Bcf @('init', '--yes', '--project', $p)
    Assert-True ($r.Code -in @(0, 1)) "неожиданный код $($r.Code)"
    # После полного прохода состояние снимается: иначе следующий запуск сообщит о
    # прерывании, которого не было.
    Assert-True (-not (Test-Path (Join-Path $p '.bcf\init.json'))) 'состояние мастера не убрано после завершения'
    Assert-True (Test-Path (Join-Path $p '.bcf\project.json')) 'карточка проекта не записана'
}

# Регрессия к сути шага 4: он объясняет, за что человек заплатит. «По задаче + слияния»
# на это не отвечает — разница между очередью из двух задач и из двадцати и есть ответ.
# Числа обязаны приходить из tasks/, а не из примера в шаблоне экрана.
It 'шаг 4 считает узлы по настоящей очереди' {
    $p = New-Sandbox 'init-step4-queue'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'tasks') | Out-Null
    foreach ($t in @(@('01', 'a', 'src/a.rs'), @('02', 'b', 'src/b.rs'), @('03', 'c', 'src/c.rs'))) {
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p "tasks\TASK-$($t[0])-$($t[1]).md") -Value @"
# TASK-$($t[0]) — $($t[1])

## Вход
нет

## Файлы
- $($t[2])
"@
    }
    $r = Bcf @('init', '--yes', '--dry', '--project', $p)
    Assert-Match $r.Out 'узлов на очередь из 3 задач' 'заголовок колонки не назвал размер очереди'
    Assert-Match $r.Out '3 \+ слияния' 'узлы работы не посчитаны по очереди'
    # Владение чистое — планировщика граф не зовёт, и экран обязан говорить это же.
    Assert-Match $r.Out '0 — владение непротиворечиво'
}

It 'шаг 4 называет коллизию владения и задачу без деклараций' {
    $p = New-Sandbox 'init-step4-collision'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'tasks') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-a.md') -Value @"
# TASK-01 — a

## Файлы
- src/main.rs
"@
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-02-b.md') -Value @"
# TASK-02 — b

## Файлы
- src/main.rs
"@
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-03-c.md') -Value "# TASK-03 — c`n`n## Готовность`n- работает`n"
    $r = Bcf @('init', '--yes', '--dry', '--project', $p)
    Assert-Match $r.Out 'владение пересекается: src/main\.rs — TASK-01 и TASK-02'
    Assert-Match $r.Out 'файлы не объявлены: TASK-03'
    Assert-Match $r.Out '1 — ревизия владения' 'узел планировщика при коллизии обязан быть посчитан'
    # Задача без деклараций к работе не допускается — значит и в узлы работы не входит.
    Assert-Match $r.Out '2 \+ слияния'
}

# Число критиков — свойство графа, а не мастера. Записанное в init константой, оно
# останется тройкой и после того, как в граф добавят четвёртый ракурс.
It 'критиков на экране столько, сколько ракурсов в графе' {
    $graph = Get-Content -Raw -LiteralPath (Join-Path $root 'harness\graphs\queue.graph.ps1')
    $angles = @([regex]::Matches($graph, "-Label\s+'приёмка-([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($angles.Count -gt 0) 'в графе не нашлось ни одного узла приёмки — разошёлся разбор'
    $p = New-Sandbox 'init-step4-critics'
    $r = Bcf @('init', '--yes', '--dry', '--project', $p)
    Assert-Match $r.Out "critic ×$($angles.Count)"
    foreach ($a in $angles) { Assert-Match $r.Out ([regex]::Escape($a)) "ракурс '$a' не назван" }
}

It 'init --dry проходит все экраны и ничего не пишет' {
    $p = New-Sandbox 'init-dry'
    $r = Bcf @('init', '--yes', '--dry', '--project', $p)
    Assert-Match $r.Out 'шаг 8 / 8'
    Assert-Match $r.Out 'ничего не записано'
    Assert-True (-not (Test-Path (Join-Path $p 'config'))) 'сухой прогон записал config'
    Assert-True (-not (Test-Path (Join-Path $p '.claude'))) 'сухой прогон записал .claude'
}

# --- detect --------------------------------------------------------------------------
Write-Host ''
Write-Host '  detect' -ForegroundColor White

It 'узнаёт стек и помечает источник вывода' {
    $p = New-Sandbox 'detect'
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'Rust'
    Assert-Match $r.Out 'cargo'
    Assert-Match $r.Out '(уверенно|догадка|проверено)' 'у предложений должен быть виден источник'
}

It 'проект без git назван блокером с последствием, а не статусом' {
    $p = New-Sandbox 'nogit' -NoGit
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'НЕ ПОЕДЕТ'
    Assert-Match $r.Out 'восстановить'  'блокер обязан называть цену, а не только факт'
}

# Регрессия: продуктовые каталоги брались из захардкоженного списка, и крейт воркспейса
# вне crates/ (например app/src-tauri) терялся. Итерация, правившая только его, была бы
# засчитана как «прогресса нет» — при источнике вывода «уверенно».
It 'члены cargo-воркспейса попадают в productPaths, вложенные пути не дублируются' {
    $p = New-Sandbox 'detect-workspace'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'app\src-tauri\src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'crates\core\src') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'app\src-tauri\src\lib.rs') -Value 'pub fn x() {}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p 'crates\core\src\lib.rs') -Value 'pub fn y() {}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p 'Cargo.toml') -Encoding UTF8 -Value @"
[workspace]
members = ["crates/core", "app/src-tauri"]
"@
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    $pp = @($j.ProductPaths)
    Assert-True ($pp -contains 'app/src-tauri/src') "член воркспейса потерян: $($pp -join ', ')"
    Assert-True (-not ($pp -contains 'crates/core/src')) "вложенный путь не схлопнут: $($pp -join ', ')"
}

It 'второй раннер тестов назван, а источник понижен до догадки' {
    $p = New-Sandbox 'detect-runners'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'app') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'app\package.json') -Encoding UTF8 -Value '{"name":"a","scripts":{"test":"vitest run"}}'
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'найдено 2' 'второй раннер проглочен молча'
    Assert-Match $r.Out 'vitest'
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    Assert-True (@($j.Runners).Count -eq 2) 'в JSON не оба раннера'
}

It '--json отдаёт разбираемый JSON' {
    $p = New-Sandbox 'detectjson'
    $r = Bcf @('detect', '--project', $p, '--json')
    $j = $r.Out | ConvertFrom-Json
    Assert-True ($j.Root) 'в JSON нет Root'
}

# --- install -------------------------------------------------------------------------
Write-Host ''
Write-Host '  install' -ForegroundColor White

It 'ставит .claude, config и CLAUDE.md' {
    $p = New-Sandbox 'install'
    $r = Bcf @('install', '--project', $p)
    foreach ($f in @('.claude\settings.json', '.claude\hooks\done-gate.sh', 'config\harness.json', 'CLAUDE.md')) {
        Assert-True (Test-Path (Join-Path $p $f)) "не поставлен: $f"
    }
    Assert-True (@(Get-ChildItem (Join-Path $p '.claude\agents') -Filter '*.md' -Recurse).Count -gt 0) 'нет ролей'
}

It 'подстановки не оставляют шаблонных плейсхолдеров' {
    $p = New-Sandbox 'install-subst'
    Bcf @('install', '--project', $p) | Out-Null
    $left = @(Get-ChildItem (Join-Path $p '.claude') -Recurse -File |
              Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match '\{\{[A-Z_]+\}\}' })
    Assert-True ($left.Count -eq 0) "остались плейсхолдеры в: $(($left | ForEach-Object { $_.Name }) -join ', ')"
}

# Регрессия: обвязка — это файлы, которые владелец правит под себя. Молчаливая
# перезапись при обновлении фабрики теряет его правки, и замечает он это на прогоне.
It 'повторный install не затирает правки владельца' {
    $p = New-Sandbox 'install-twice'
    Bcf @('install', '--project', $p) | Out-Null
    $mine = Join-Path $p '.claude\settings.json'
    Set-Content -LiteralPath $mine -Value '{"mine":true}' -Encoding UTF8
    $r = Bcf @('install', '--project', $p)
    Assert-Match (Get-Content -Raw -LiteralPath $mine) 'mine'
    Assert-Match $r.Out 'НЕ ТРОНУТО'
}

# Регрессия: --only без значения молча превращался в ПОЛНУЮ установку, то есть флаг
# сужения области делал ровно обратное тому, ради чего его написали.
It '--only без значения и с чужим значением отказывает' {
    $p = New-Sandbox 'install-only'
    $r1 = Bcf @('install', '--only', '--project', $p)
    Assert-True ($r1.Code -eq 2) "ожидал отказ, получил $($r1.Code)"
    Assert-True (-not (Test-Path (Join-Path $p 'config'))) '--only без значения поставил всё'

    $r2 = Bcf @('install', '--only', 'nonsense', '--project', $p)
    Assert-True ($r2.Code -eq 2) '--only с неизвестной областью принят молча'
    Assert-Match $r2.Out 'claude \| config \| project'
}

# Регрессия: --dry показывал только копируемые файлы и умалчивал про .gitignore, tasks/
# и карточку проекта — то есть выдавал за план половину изменений.
It '--dry перечисляет и то, что не является копированием файла' {
    $p = New-Sandbox 'install-dry-full'
    $r = Bcf @('install', '--dry', '--project', $p)
    Assert-Match $r.Out '\.gitignore'
    Assert-Match $r.Out 'project\.json'
    Assert-True (-not (Test-Path (Join-Path $p '.claude'))) 'сухой прогон записал .claude'
}

It '--dry ничего не пишет' {
    $p = New-Sandbox 'install-dry'
    $r = Bcf @('install', '--project', $p, '--dry')
    Assert-True (-not (Test-Path (Join-Path $p '.claude'))) 'сухой прогон создал .claude'
    Assert-Match $r.Out 'ничего не записано'
}

It '.gitignore получает каталог состояния' {
    $p = New-Sandbox 'install-gitignore'
    Bcf @('install', '--project', $p) | Out-Null
    Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $p '.gitignore')) '\.bcf/'
}

# Регрессия: init переписывал уже настроенный проект своими догадками, а на конфиге без
# новых секций (tests/graph) падал посреди записи — и падение выглядело как успех, потому
# что конфиг оставался нетронутым.
It 'init не переписывает заполненный конфиг и дополняет недостающие секции' {
    $p = New-Sandbox 'init-preserve'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'config') | Out-Null
    # конфиг «старого» вида: боевые роли, никаких tests/backpressure
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'config\harness.json') -Value @"
{
  "productPaths": ["crates"],
  "taskIdPrefix": "TASK",
  "models": { "code": "my-pinned-model" },
  "agent": { "command": "my-agent --model {model}", "adapter": "custom" },
  "graph": {
    "backends": { "mine": { "command": "my-agent --model {model}", "format": "text" } },
    "roles": { "worker": { "backend": "mine", "model": "my-pinned-model" } }
  }
}
"@
    & git -C $p add -A 2>&1 | Out-Null
    & git -C $p -c user.name=t -c user.email=t@local commit -qm cfg 2>&1 | Out-Null

    $r = Bcf @('init', '--yes', '--project', $p)
    Assert-Match $r.Out 'ОСТАВЛЕНО КАК БЫЛО' 'init молчит о том, что сохранил'

    $cfg = Get-Content -Raw -LiteralPath (Join-Path $p 'config\harness.json') | ConvertFrom-Json
    Assert-True ($cfg.graph.roles.worker.backend -eq 'mine') "роль перезаписана: $($cfg.graph.roles.worker.backend)"
    Assert-True ($cfg.models.code -eq 'my-pinned-model') "модель перезаписана: $($cfg.models.code)"
    Assert-True ($cfg.agent.command -like 'my-agent*') 'команда агента перезаписана'
    Assert-True (@($cfg.productPaths) -contains 'crates') 'productPaths перезаписан'
    # чужой бэкенд остался, недостающие секции добавлены
    Assert-True ($null -ne $cfg.graph.backends.mine) 'свой бэкенд проекта потерян'
    Assert-True ($null -ne $cfg.tests) 'секция tests не добавлена — init упал бы на её отсутствии'
}

# --- tasks ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  tasks' -ForegroundColor White

It 'пустой бэклог не роняет таблицу' {
    $p = New-Sandbox 'tasks-empty'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'БЭКЛОГ'
    Assert-NoMatch $r.Out 'Exception|не удалось привязать|Cannot bind'
}

# Регрессия того же класса, что «одиннадцать задач готова при пяти заблокированных»:
# состояние считалось ОДНИМ условием (предшественники закрыты), а допуск в волну — двумя
# (ещё и владение объявлено). Поэтому `bcf tasks` печатал «готова» и советовал запуск о
# задаче, про которую тот же экран строкой ниже писал «файлы не объявлены», а мастер на
# шаге 4 — «не допущено: 1». Три экрана об одной задаче говорили разное.

It 'задача без объявленных файлов не называется готовой' {
    $p = New-Sandbox 'tasks-undeclared'
    Bcf @('install', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-nofiles.md') -Value @"
# TASK-01 — без владения

## Готовность
- что-то работает
"@
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match   $r.Out 'НЕ ДОПУЩЕНА' 'недопущенная задача обязана называться недопущенной'
    Assert-Match   $r.Out 'готово к работе 0' 'недопущенная задача сосчитана готовой'
    Assert-NoMatch $r.Out 'запустить готовые' 'совет запускать даётся при нулевой очереди'

    $j = (Bcf @('tasks', '--project', $p, '--json')).Out | ConvertFrom-Json
    $t = @($j)[0]
    Assert-True ($t.Ready -and -not $t.Admitted -and -not $t.Runnable) `
        "Ready=$($t.Ready) Admitted=$($t.Admitted) Runnable=$($t.Runnable) — допуск и готовность склеились"
}

It 'коллизия владения названа последствием' {
    $p = New-Sandbox 'tasks-collide'
    Bcf @('install', '--project', $p) | Out-Null
    foreach ($id in @('01', '02')) {
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p "tasks\TASK-$id-x.md") -Value @"
# TASK-$id — тест

## Файлы
- ``src/main.rs``

## Вход
—
"@
    }
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'КОЛЛИЗИИ ВЛАДЕНИЯ'
    Assert-Match $r.Out 'арбитр'  'коллизия обязана объяснять, чем она обернётся'
}

# Регрессия и она же самая дорогая из найденных: CLI читал секцию «## Вход», а
# планировщик — строку «**Gate-вход:**». На реальном проекте это дало одиннадцать задач
# «готова» при пяти заблокированных плюс совет «запустить готовые»: запуск задачи, у
# которой не сделан ни один вход, стоит целого прогона.
It 'предшественники читаются в обоих форматах, тем же разборщиком, что у планировщика' {
    $p = New-Sandbox 'tasks-preds'
    Bcf @('install', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-base.md') -Value @"
# TASK-01 — основа

## Файлы
- ``src/a.rs``
"@
    # формат харнесса и старых проектов
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-02-gate.md') -Value @"
# TASK-02 — через Gate-вход

**Gate-вход:** TASK-01

## Файлы
- ``src/b.rs``
"@
    # формат шаблона задачи фабрики
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-03-section.md') -Value @"
# TASK-03 — через секцию

## Файлы
- ``src/c.rs``

## Вход

TASK-01
"@
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'TASK-02\s+ждёт TASK-01' 'формат **Gate-вход:** не распознан'
    Assert-Match $r.Out 'TASK-03\s+ждёт TASK-01' 'формат секции ## Вход не распознан'
    Assert-Match $r.Out 'готово к работе 1' 'заблокированные задачи посчитаны готовыми'

    $j = (Bcf @('tasks', '--project', $p, '--json')).Out | ConvertFrom-Json
    $t2 = @($j | Where-Object { $_.Id -eq 'TASK-02' })[0]
    Assert-True (@($t2.Preds).Count -eq 1) 'в JSON у TASK-02 нет предшественника'
}

It 'tasks читает paths.tasks и paths.verdicts из конфига' {
    $p = New-Sandbox 'tasks-paths'
    Bcf @('install', '--project', $p) | Out-Null
    $cfgPath = Join-Path $p 'config\harness.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    $cfg.paths.tasks = 'backlog'
    $cfg.paths.verdicts = 'backlog/.verdicts'
    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    New-Item -ItemType Directory -Force -Path (Join-Path $p 'backlog\.verdicts') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'backlog\TASK-01-x.md') -Value "# TASK-01 — x`n`n## Файлы`n- ``src/a.rs```n"
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'backlog\.verdicts\TASK-01.md') -Value "verdict: PASS`n"

    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'всего 1'
    Assert-Match $r.Out 'закрыто 1' 'вердикт по настроенному пути не найден'
}

It 'задача без секции Файлы отмечена как непроверяемая' {
    $p = New-Sandbox 'tasks-nofiles'
    Bcf @('install', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-09-x.md') -Value "# TASK-09 — без файлов`n"
    $r = Bcf @('tasks', '--project', $p)
    Assert-Match $r.Out 'без объявленных файлов'
}

# --- отчётность ----------------------------------------------------------------------
Write-Host ''
Write-Host '  отчётность' -ForegroundColor White

It 'на пустом проекте report и cost честно говорят «прогонов не было»' {
    $p = New-Sandbox 'reports'
    Bcf @('install', '--project', $p) | Out-Null
    foreach ($cmd in @('report', 'cost', 'runs', 'board')) {
        $r = Bcf @($cmd, '--project', $p)
        Assert-NoMatch $r.Out 'ГОТОВО' "$cmd не имеет права говорить «готово» без прогона"
    }
}

# Регрессия: узлы отработали → отчёт печатал «ГОТОВО», хотя очередь закрылась не вся.
It 'вердикт берётся из итога графа, а не из числа узлов' {
    $p = New-Sandbox 'report-verdict'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_test01'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $j = Join-Path $dir 'journal.jsonl'
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"node-start","key":"n1","label":"работа-TASK-01","phase":"Работа","role":"worker","model":"m","ts":"2026-01-01T00:00:01.0000000+00:00"}'
        '{"event":"node-finish","key":"n1","label":"работа-TASK-01","phase":"Работа","ok":true,"tokens":1234,"ts":"2026-01-01T00:00:09.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":1234,"result":"{\"passed\":0,\"stuck\":1,\"complete\":false,\"total\":1}","ts":"2026-01-01T00:00:10.0000000+00:00"}'
    ) | Set-Content -LiteralPath $j -Encoding UTF8

    $r = Bcf @('report', '--project', $p)
    Assert-Match $r.Out 'НЕПОЛНО' 'узлы зелёные, но очередь не закрыта — это не «готово»'
    Assert-Match $r.Out 'закрыто 0 из 1'
    Assert-True ($r.Code -eq 1) "неполный прогон обязан давать ненулевой код, получил $($r.Code)"
}

It 'сухой план не выдаётся за результат' {
    $p = New-Sandbox 'report-dry'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_dry001'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","dryPlan":true,"ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":0,"result":"{\"passed\":0,\"stuck\":1,\"complete\":false,\"total\":1}","ts":"2026-01-01T00:00:02.0000000+00:00"}'
    ) | Set-Content -LiteralPath (Join-Path $dir 'journal.jsonl') -Encoding UTF8

    $r = Bcf @('report', '--project', $p)
    Assert-Match $r.Out 'СУХОЙ ПЛАН'
    Assert-Match $r.Out 'не говорит ничего'
    Assert-True ($r.Code -eq 0) 'сухой план не провал'
}

It 'cost не печатает ноль там, где тарифа нет' {
    $p = New-Sandbox 'cost-unknown'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20260101-000000_cost01'
    $dir = Join-Path $p ".bcf\graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","ts":"2026-01-01T00:00:00.0000000+00:00"}'
        '{"event":"node-start","key":"n1","label":"a","phase":"Работа","role":"worker","model":"unknown-model","ts":"2026-01-01T00:00:01.0000000+00:00"}'
        '{"event":"node-finish","key":"n1","label":"a","phase":"Работа","ok":true,"tokens":5000,"ts":"2026-01-01T00:00:05.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":5000,"ts":"2026-01-01T00:00:06.0000000+00:00"}'
    ) | Set-Content -LiteralPath (Join-Path $dir 'journal.jsonl') -Encoding UTF8

    $r = Bcf @('cost', '--project', $p)
    Assert-Match $r.Out '5000'
    Assert-Match $r.Out '—'  'неизвестная цена показывается прочерком, а не нулём'
}

# Регрессия: проект, водивший харнесс до перехода на .bcf/, держит историю в loop/.graph/.
# Читать только новый адрес значит сказать «прогонов ещё не было» при полусотне журналов —
# то есть соврать про историю ровно тем способом, против которого весь этот CLI и сделан.
It 'история из старого каталога loop/ видна и помечена' {
    $p = New-Sandbox 'legacy-history'
    Bcf @('install', '--project', $p) | Out-Null
    $runId = 'g_20250101-000000_old001'
    $dir = Join-Path $p "loop\.graph\$runId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        '{"event":"run-start","runId":"' + $runId + '","name":"queue","ts":"2025-01-01T00:00:00.0000000+00:00"}'
        '{"event":"node-start","key":"n1","label":"работа-СТАРАЯ","phase":"Работа","role":"worker","model":"m","ts":"2025-01-01T00:00:01.0000000+00:00"}'
        '{"event":"node-finish","key":"n1","label":"работа-СТАРАЯ","phase":"Работа","ok":true,"tokens":777,"ts":"2025-01-01T00:00:05.0000000+00:00"}'
        '{"event":"run-finish","runId":"' + $runId + '","tokens":777,"ts":"2025-01-01T00:00:06.0000000+00:00"}'
    ) | Set-Content -LiteralPath (Join-Path $dir 'journal.jsonl') -Encoding UTF8

    $r = Bcf @('runs', '--project', $p)
    Assert-NoMatch $r.Out 'прогонов ещё не было' 'история есть, а CLI говорит, что её нет'
    Assert-Match $r.Out $runId
    Assert-Match $r.Out 'старом каталоге' 'молчать о разделённой истории нельзя: новые прогоны пойдут в другое место'

    # Подсказка обязана указывать на файл, который ДЕЙСТВИТЕЛЬНО там лежит.
    $b = Bcf @('board', $runId, '--project', $p)
    Assert-Match $b.Out 'loop/\.graph' 'подсказка ведёт в новый каталог, где файла нет'
    Assert-Match $b.Out '777'
}

It 'migrate --dry показывает план и ничего не переносит' {
    $p = New-Sandbox 'legacy-migrate'
    Bcf @('install', '--project', $p) | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'loop\.graph\g_x') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'loop\.graph\g_x\journal.jsonl') -Value '{"event":"run-start","name":"queue"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p 'loop\loop.log') -Value 'x' -Encoding UTF8

    $r = Bcf @('migrate', '--dry', '--project', $p)
    Assert-Match $r.Out 'loop/\.graph'
    Assert-Match $r.Out 'ничего не записано'
    Assert-True (Test-Path (Join-Path $p 'loop\.graph\g_x\journal.jsonl')) 'сухой прогон перенёс файлы'
    Assert-True (-not (Test-Path (Join-Path $p '.bcf\graph'))) 'сухой прогон создал целевой каталог'
}

# --- meta ----------------------------------------------------------------------------
Write-Host ''
Write-Host '  meta' -ForegroundColor White

It 'audit находит незаполненный CLAUDE.md' {
    $p = New-Sandbox 'meta-audit'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('meta', 'audit', '--project', $p)
    Assert-Match $r.Out 'заготовка'
    Assert-True ($r.Code -eq 1) 'аудит с находками обязан давать ненулевой код'
}

# Регрессия: ссылка на фабрику внутри проекта — утечка, после которой агент туда идёт.
It 'audit ловит утечку пути фабрики в проект' {
    $p = New-Sandbox 'meta-leak'
    Bcf @('install', '--project', $p) | Out-Null
    Add-Content -LiteralPath (Join-Path $p 'CLAUDE.md') -Value "`nСм. также $root" -Encoding UTF8
    $r = Bcf @('meta', 'audit', '--project', $p)
    Assert-Match $r.Out 'ссылки на фабрику'
}

It 'wiki перечисляет статьи' {
    $p = New-Sandbox 'meta-wiki'
    $r = Bcf @('meta', 'wiki', '--project', $p)
    Assert-Match $r.Out 'common-errors'
}

# --- run -----------------------------------------------------------------------------
Write-Host ''
Write-Host '  run' -ForegroundColor White

It 'run без режима объясняет разницу движков' {
    $p = New-Sandbox 'run-help'
    $r = Bcf @('run', '--project', $p)
    Assert-Match $r.Out 'queue'
    Assert-Match $r.Out 'дороже|дешевле' 'выбор движка — про экономику, это должно быть видно'
    Assert-True ($r.Code -eq 2) 'без режима это не успех'
}

It 'ненастроенный проект не пускается в прогон' {
    $p = New-Sandbox 'run-unconfigured'
    $r = Bcf @('run', 'queue', '--project', $p)
    Assert-Match $r.Out 'bcf init'
    Assert-True ($r.Code -eq 2) 'прогон без настройки обязан отказать до первого токена'
}

# Регрессия: сухой план создавал worktree и писал claims.json с pid. Проверка режима
# стояла внутри исполнителя узла, а worktree и заявка делаются ДО него — то есть план
# заявлял файлы, которые потом мешают настоящему прогону. План, меняющий состояние,
# планом не является.
It 'сухой план не создаёт worktree и не заявляет файлы' {
    $p = New-Sandbox 'run-dry-clean'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    # роли обязаны быть заполнены, иначе прогон откажет раньше, чем дойдёт до стадий
    $cfgPath = Join-Path $p 'config\harness.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    foreach ($r in @('planner', 'worker', 'arbiter', 'critic')) {
        $cfg.graph.roles.$r = [pscustomobject]@{ backend = 'claude'; model = 'sonnet' }
    }
    if (-not $cfg.graph.backends.PSObject.Properties['claude']) {
        $cfg.graph.backends | Add-Member -NotePropertyName 'claude' -NotePropertyValue ([pscustomobject]@{ command = 'claude -p --model {model}'; format = 'claude' }) -Force
    }
    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8

    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-x.md') -Value @"
# TASK-01 — тест

## Файлы
- ``src/main.rs``

## Вход
—
"@
    $r = Bcf @('run', 'queue', '--dry-plan', '--yes', '--project', $p)
    Assert-Match $r.Out 'ПЛАН' 'сухой план обязан показывать, что было бы сделано'

    Assert-True (-not (Test-Path (Join-Path $p '.bcf\fleet\claims.json'))) 'сухой план заявил файлы'
    Assert-True (-not (Test-Path "$p.wt")) 'сухой план создал каталог worktree'
    $wt = @(& git -C $p worktree list 2>$null)
    Assert-True ($wt.Count -le 1) "сухой план создал git worktree: $($wt -join '; ')"
}

# Регрессия: `exit (Invoke-Harness …)` съедал весь вывод прогона — PowerShell считает
# вывод функции её результатом. Снаружи это выглядело как «отработало мгновенно и молча»,
# то есть ход работы, ради которого прогон и запускают, не было видно вообще.
It 'вывод прогона доходит до консоли, а не в возвращаемое значение' {
    $p = New-Sandbox 'run-output'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-x.md') -Value @"
# TASK-01 — тест

## Файлы
- ``src/main.rs``

## Вход
—
"@
    $r = Bcf @('run', 'night', '--dry-plan', '--project', $p)
    Assert-Match $r.Out 'run-all' 'прогон отработал молча — его вывод потерян'
    Assert-Match $r.Out 'DRY-PLAN'
}

# --- Ежедневные команды ----------------------------------------------------------------

It 'task new даёт следующий свободный номер, а не «количество + 1»' {
    $p = New-Sandbox 'task-new'
    Bcf @('install', '--project', $p) | Out-Null
    $a = Bcf @('task', 'new', 'первая задача', '--project', $p)
    Assert-Match $a.Out 'TASK-01'
    $b = Bcf @('task', 'new', 'вторая задача', '--project', $p)
    Assert-Match $b.Out 'TASK-02'

    # Удаляем первую и создаём ещё одну. «Количество + 1» вернуло бы TASK-02 — занятый
    # номер, и две задачи начали бы спорить за один id: одна перекрыла бы вердикт другой.
    Remove-Item (Get-ChildItem (Join-Path $p 'tasks') -Filter 'TASK-01-*.md').FullName -Force
    $c = Bcf @('task', 'new', 'третья задача', '--project', $p)
    Assert-Match $c.Out 'TASK-03' 'номер выдан по количеству файлов, а не по максимуму — id столкнутся'
}

It 'имя файла задачи не содержит кириллицы' {
    $p = New-Sandbox 'task-slug'
    Bcf @('install', '--project', $p) | Out-Null
    Bcf @('task', 'new', 'фильтры последующих сканов', '--project', $p) | Out-Null
    $f = @(Get-ChildItem (Join-Path $p 'tasks') -Filter 'TASK-*.md')[0]
    Assert-True ($f.Name -notmatch '[\u0400-\u04FF]') "кириллица в имени файла: $($f.Name)"
    Assert-Match $f.Name 'filtry'
}

It 'task why называет ПРИЧИНУ, по которой задача не поедет' {
    $p = New-Sandbox 'task-why'
    Bcf @('install', '--project', $p) | Out-Null
    Bcf @('task', 'new', 'а', '--project', $p) | Out-Null
    $r = Bcf @('task', 'why', 'TASK-01', '--project', $p)
    Assert-True ($r.Code -ne 0) 'задача без секции «Файлы» и без ролей объявлена готовой'
    Assert-Match $r.Out 'Файлы'
    Assert-Match $r.Out 'НЕ ПОЕДЕТ'
}

It 'task why видит незакрытого предшественника' {
    $p = New-Sandbox 'task-why-pred'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-01-a.md') -Value @"
# TASK-01 — a

## Файлы
- ``src/a.rs``

**Gate-вход:** нет
"@
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'tasks\TASK-02-b.md') -Value @"
# TASK-02 — b

## Файлы
- ``src/b.rs``

**Gate-вход:** TASK-01
"@
    $r = Bcf @('task', 'why', 'TASK-02', '--project', $p)
    Assert-Match $r.Out 'TASK-01' 'предшественник не назван'
    Assert-True ($r.Code -ne 0) 'задача с незакрытым предшественником объявлена готовой'
}

It 'stop пишет запрос на остановку и умеет его снять' {
    $p = New-Sandbox 'stop'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('stop', '--project', $p)
    Assert-True (Test-Path (Join-Path $p '.bcf\STOP')) 'файла-запроса нет — прогон не остановится'
    Assert-Match $r.Out 'МЕЖДУ задачами'
    Bcf @('stop', '--clear', '--project', $p) | Out-Null
    Assert-True (-not (Test-Path (Join-Path $p '.bcf\STOP'))) '--clear не убрал запрос: следующий прогон не поедет'
}

# Регрессия: доска показывала у оборванного прогона РАСТУЩИЙ таймер узла. Это читается
# как «работа идёт прямо сейчас», хотя процесса нет уже сутки.
It 'watch --once не выдаёт оборванный прогон за идущий' {
    $p = New-Sandbox 'watch'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\20200101-000000-dead'
    New-Item -ItemType Directory -Force -Path $g | Out-Null
    $j = Join-Path $g 'journal.jsonl'
    Set-Content -Encoding UTF8 -LiteralPath $j -Value @(
        '{"ts":"2020-01-01T00:00:00Z","event":"run-start","name":"queue","nodes":2}'
        '{"ts":"2020-01-01T00:00:01Z","event":"node-start","key":"n1","label":"работа-TASK-01","phase":"work","role":"worker"}'
        '{"ts":"2020-01-01T00:00:30Z","event":"node-finish","key":"n1","ok":true,"tokens":100}'
        '{"ts":"2020-01-01T00:00:31Z","event":"node-start","key":"n2","label":"работа-TASK-02","phase":"work","role":"worker"}'
    )
    # Журнал оборванного прогона не дописывается — именно по этому его и отличают от идущего.
    (Get-Item $j).LastWriteTime = (Get-Date).AddDays(-3)
    $r = Bcf @('watch', '--once', '--project', $p)
    Assert-Match $r.Out 'не завершились' 'оборванный прогон показан как идущий'
    Assert-True ($r.Out -notmatch 'работают сейчас') 'мёртвый прогон объявлен живым'
}

# Ради этого команда и написана: у упавшего узла ответа обычно НЕТ, а причина лежит в
# stderr бэкенда. Показывать надо её, а не пустой ответ с бодрым заголовком.
It 'log показывает ошибки упавшего узла и не обещает пустой ответ' {
    $p = New-Sandbox 'log'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\20260101-000000-run'
    New-Item -ItemType Directory -Force -Path (Join-Path $g 'nodes') | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'journal.jsonl') -Value @(
        '{"ts":"2026-01-01T00:00:00Z","event":"run-start","name":"queue","nodes":1}'
        '{"ts":"2026-01-01T00:00:01Z","event":"node-start","key":"n1","label":"критик-TASK-01","phase":"critic","role":"critic"}'
        '{"ts":"2026-01-01T00:01:00Z","event":"node-finish","key":"n1","ok":false,"reason":"агент не вернул текста"}'
        '{"ts":"2026-01-01T00:01:01Z","event":"run-finish","ok":false}'
    )
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'nodes\критик-TASK-01.err.log') -Value 'error: authentication required'
    # Пустой файл ответа — ровно то, что оставляет молча умерший агент.
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'nodes\критик-TASK-01.out.jsonl') -Value ''

    $list = Bcf @('log', '--project', $p)
    Assert-Match $list.Out 'критик-TASK-01'
    Assert-NoMatch $list.Out 'ответ' 'пустой файл ответа выдан за сохранённый ответ'

    $one = Bcf @('log', 'критик', '--project', $p)
    Assert-Match $one.Out 'authentication required' 'причина провала не показана'
    Assert-Match $one.Out 'ПРОВАЛ'
}

It 'log без прогонов не притворяется, что что-то нашёл' {
    $p = New-Sandbox 'log-empty'
    Bcf @('install', '--project', $p) | Out-Null
    $r = Bcf @('log', '--project', $p)
    Assert-True ($r.Code -ne 0) 'пустая история отдана как успех'
    Assert-Match $r.Out 'прогонов ещё не было'
}

It 'setup --check не создаёт ярлык и не трогает PATH' {
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\BCF-test-should-not-exist.lnk'
    $pathBefore = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $r = Bcf @('setup', '--check')
    Assert-True (-not (Test-Path $lnk)) '--check создал ярлык'
    Assert-True ($pathBefore -eq [Environment]::GetEnvironmentVariable('PATH', 'User')) '--check изменил PATH'
    Assert-Match $r.Out 'КОМАНДА bcf'
}

# Регрессия. Доска и карточка судили по УЗЛАМ, а отчёт — по итогу, который вернул сам
# граф. На прогоне, где узлы отработали все до одного, а очередь закрылась 0 из 1, доска
# показывала зелёные «завершён» и 100%, карточка — зелёную галочку, а отчёт в ту же
# секунду говорил «НЕПОЛНО». Из трёх экранов два врали, и врали в сторону успеха.
It 'доска, карточка и отчёт говорят о прогоне одно и то же' {
    $p = New-Sandbox 'verdict-agree'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\g_20260101-000000_x'
    New-Item -ItemType Directory -Force -Path $g | Out-Null
    # Узел один и он УСПЕШЕН; очередь при этом закрылась 0 из 1 — это штатный исход,
    # а не выдумка: «работа-TASK-01» завершается и тогда, когда задача не достигла PASS.
    $res = '{\"complete\":false,\"passed\":0,\"total\":1,\"stuck\":1}'
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'journal.jsonl') -Value @(
        '{"ts":"2026-01-01T00:00:00Z","event":"run-start","name":"queue","nodes":1}'
        '{"ts":"2026-01-01T00:00:01Z","event":"node-start","key":"n1","label":"работа-TASK-01","phase":"Работа","role":"worker"}'
        '{"ts":"2026-01-01T00:00:30Z","event":"node-finish","key":"n1","ok":true,"tokens":10}'
        ('{"ts":"2026-01-01T00:00:31Z","event":"run-finish","ok":true,"result":"' + $res + '"}')
    )
    foreach ($cmd in @(@('report'), @('board'), @('watch', '--once'))) {
        $r = Bcf ($cmd + @('--project', $p))
        Assert-Match $r.Out 'НЕПОЛНО' "bcf $($cmd -join ' ') выдаёт незакрытую очередь за успех"
    }
    $card = Bcf @('--project', $p)
    Assert-Match $card.Out 'НЕПОЛНО' 'карточка выдаёт незакрытую очередь за успех'
}

# Регрессия: [int]$Span.TotalDays ОКРУГЛЯЕТ, а не отбрасывает — «1д 21:36» печаталось как
# «2д 21:36», противореча часам рядом. И знак терялся целиком: «-00:05:30» выходило «05:30».
It 'длительность не завышает дни и не теряет знак' {
    . (Join-Path $root 'src\lib\ui.ps1')
    Assert-True ((Format-BcfDuration ([timespan]'1.21:36:00')) -eq '1д 21:36') "получил: $(Format-BcfDuration ([timespan]'1.21:36:00'))"
    Assert-True ((Format-BcfDuration ([timespan]'6.13:00:00')) -eq '6д 13:00') "получил: $(Format-BcfDuration ([timespan]'6.13:00:00'))"
    Assert-True ((Format-BcfDuration ([timespan]'-00:05:30')).StartsWith('-')) 'отрицательный интервал напечатан как положительный'
    Assert-True ((Format-BcfDuration ([timespan]'-3.04:00:00')) -eq '-3д 04:00') "получил: $(Format-BcfDuration ([timespan]'-3.04:00:00'))"
}

# Регрессия: индекс за границей массива в PowerShell не ошибка — он даёт $null, и явно
# указанный --project молча превращался в своё отсутствие. `bcf install --project` (значение
# потерялось при копировании) записывал обвязку в текущий каталог и рапортовал об успехе.
It 'флаг --project без значения отказывает, а не берёт текущий каталог' {
    $r = Bcf @('install', '--project')
    Assert-True ($r.Code -eq 2) "ожидал код 2, получил $($r.Code)"
    Assert-Match $r.Out 'нет значения'
}

# Регрессия: разборщики деклараций смотрели строго в <root>/tasks, игнорируя paths.tasks.
# На проекте с другим каталогом обе функции возвращали пусто — то есть «предшественников
# нет» при незакрытом гейте. Задача уходила в волну, которой не должна была достаться.
It 'декларации задачи читаются из каталога, заданного в конфиге' {
    $p = New-Sandbox 'paths-tasks'
    Bcf @('install', '--project', $p) | Out-Null
    $cfgPath = Join-Path $p 'config\harness.json'
    $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
    if (-not $cfg.paths) { $cfg | Add-Member -NotePropertyName 'paths' -NotePropertyValue ([pscustomobject]@{}) -Force }
    $cfg.paths | Add-Member -NotePropertyName 'tasks' -NotePropertyValue 'backlog' -Force
    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'backlog') | Out-Null

    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'backlog\TASK-01-a.md') -Value @"
# TASK-01 — a

## Файлы
- ``src/a.rs``

**Gate-вход:** нет
"@
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $p 'backlog\TASK-02-b.md') -Value @"
# TASK-02 — b

## Файлы
- ``src/b.rs``

**Gate-вход:** TASK-01
"@
    $r = Bcf @('task', 'why', 'TASK-02', '--project', $p)
    Assert-Match $r.Out 'TASK-01' 'предшественник не найден: разборщик смотрит не в тот каталог'
    Assert-NoMatch $r.Out 'предшественников нет' 'незакрытый гейт объявлен отсутствующим'
    Assert-Match $r.Out 'src/b\.rs' 'объявленные файлы не найдены: разборщик смотрит не в тот каталог'
}

# Регрессия: `bcf doctor` заводит каталог прогона и пишет run-start, но никогда не пишет
# run-finish — она и не прогон. В истории оставался вечный «оборванный» прогон, и он
# становился последним для ВСЕХ экранов.
It 'проба doctor не попадает в историю прогонов' {
    $p = New-Sandbox 'doctor-ghost'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\g_20260101-000000_probe'
    New-Item -ItemType Directory -Force -Path $g | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'journal.jsonl') -Value @(
        '{"ts":"2026-01-01T00:00:00Z","event":"run-start","name":"doctor","doctor":true,"nodes":0}'
    )
    $r = Bcf @('runs', '--project', $p)
    Assert-NoMatch $r.Out 'g_20260101-000000_probe' 'проба doctor показана как прогон'
    $card = Bcf @('--project', $p)
    Assert-NoMatch $card.Out 'ОБОРВАН' 'карточка объявила оборванным прогон, которого не было'
}

# Регрессия: аргумент с пробелами уезжал в docker несколькими — тот падал на разборе за
# доли секунды, и снаружи это неотличимо от «демон не ответил».
It 'docker зовётся с корректно закавыченными аргументами' {
    . (Join-Path $root 'harness\lib\docker.ps1')
    if (-not (Test-BcfDockerDaemon)) { return }   # без демона проверять нечего
    $r = Invoke-BcfDocker -DockerArgs @('ps', '--format', '{{.Names}} {{.Status}}') -TimeoutSec 15
    Assert-True $r.Ok "docker отказал: $(($r.Err).Trim())"
    Assert-True ($null -ne $r.Err) 'Invoke-BcfDocker не возвращает stderr — причину отказа печатать нечем'
}

# Регрессия. ConvertFrom-Json сам разбирает ISO-строки и для метки с «Z» отдаёт значение
# с Kind=Utc, НЕ переводя его в локальное. Дальше оно вычиталось из локального Get-Date, и
# длительность уезжала ровно на часовой пояс: четырёхминутный прогон показывал «03:04:12».
# Число выглядит правдоподобным — глазами такое не ловится.
It 'метки времени журнала приводятся к локальным' {
    . (Join-Path $root 'src\lib\journal.ps1')
    $utc = ConvertTo-BcfLocalTime '2026-08-01T18:00:00.0000000Z'
    Assert-True ($utc.Kind -eq [System.DateTimeKind]::Local) "Kind=$($utc.Kind), а должен быть Local"
    $off = ConvertTo-BcfLocalTime '2026-08-01T21:00:00.0000000+03:00'
    Assert-True ($off.Kind -eq [System.DateTimeKind]::Local) 'метка со смещением не приведена'

    # И то же самое на настоящем журнале: длительность считается по меткам.
    $p = New-Sandbox 'tz'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\g_20260801-180000_tz'
    New-Item -ItemType Directory -Force -Path $g | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'journal.jsonl') -Value @(
        '{"ts":"2026-08-01T18:00:00.0000000Z","event":"run-start","name":"queue","nodes":1}'
        '{"ts":"2026-08-01T18:00:01.0000000Z","event":"node-start","key":"n1","label":"работа","phase":"Работа","role":"worker"}'
        '{"ts":"2026-08-01T18:04:12.0000000Z","event":"node-finish","key":"n1","ok":true,"tokens":10}'
        '{"ts":"2026-08-01T18:04:12.0000000Z","event":"run-finish","ok":true,"result":"{\"complete\":true,\"passed\":1,\"total\":1}"}'
    )
    $r = Bcf @('runs', '--project', $p)
    Assert-Match $r.Out '04:12' "длительность посчитана мимо часового пояса:`n$($r.Out)"
}

# Лента прогона: сырую строку движка показывать нельзя — «[graph]» повторяется в каждой
# строке и не несёт ничего, а провал ничем не выделен.
It 'строка движка превращается в событие ленты' {
    . (Join-Path $root 'src\lib\ui.ps1')
    . (Join-Path $root 'src\lib\runview.ps1')

    $e = Convert-BcfFeedLine '[20:22:04] [graph] волна 1: 5 задач параллельно — TASK-02'
    Assert-True ($e.Time -eq '20:22:04') "время не разобрано: $($e.Time)"
    Assert-True ($e.Kind -eq 'wave') "вид не распознан: $($e.Kind)"
    Assert-NoMatch $e.Text 'graph' 'служебный префикс остался в тексте события'

    $f = Convert-BcfFeedLine '[20:24:05] [graph] ✗ работа-TASK-12 — агент не вернул текста'
    Assert-True ($f.Kind -eq 'fail') "провал не распознан: $($f.Kind)"
    Assert-True ($f.Color -eq 'Red') 'провал не выделен цветом'

    $m = Convert-BcfFeedLine '[20:23:31] [memory] урок записан в память'
    Assert-True ($m.Topic -eq 'memory') "тема потеряна: $($m.Topic)"

    Assert-True ($null -eq (Convert-BcfFeedLine '   ')) 'пустая строка попала в ленту'
}

# Доска прогона строится по журналу и не выдумывает того, чего в нём нет.
It 'доска живого прогона собирается и не врёт про деньги' {
    . (Join-Path $root 'src\lib\ui.ps1')
    . (Join-Path $root 'src\lib\runview.ps1')
    $p = New-Sandbox 'runboard'
    Bcf @('install', '--project', $p) | Out-Null
    $g = Join-Path $p '.bcf\graph\g_20260801-200000_b'
    New-Item -ItemType Directory -Force -Path $g | Out-Null
    Set-Content -Encoding UTF8 -LiteralPath (Join-Path $g 'journal.jsonl') -Value @(
        '{"ts":"2026-08-01T20:00:00.0000000+03:00","event":"run-start","name":"queue","nodes":2}'
        '{"ts":"2026-08-01T20:00:01.0000000+03:00","event":"node-start","key":"n1","label":"работа-TASK-01","phase":"Работа","role":"worker","model":"m"}'
        '{"ts":"2026-08-01T20:01:00.0000000+03:00","event":"node-finish","key":"n1","ok":true,"tokens":1000}'
        '{"ts":"2026-08-01T20:01:01.0000000+03:00","event":"node-start","key":"n2","label":"работа-TASK-02","phase":"Работа","role":"worker","model":"m"}'
    )
    $run = Get-BcfLastRun -Project $p
    $lines = @(Get-BcfRunBoardLines -Run $run -Tick 0 -Pricing $null -Project $p -Concurrency 4)
    $txt = ($lines | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.t } }) -join "`n"
    Assert-Match $txt 'queue' 'на доске нет имени графа'
    Assert-Match $txt 'работают сейчас'
    Assert-Match $txt 'готово 1'
    # Тарифов у песочницы нет — денег на доске быть не должно.
    Assert-NoMatch $txt '₽' 'доска показала деньги без тарифов'
}

# Запасная модель роли. Смысл фичи — в том, КОГДА она включается: на отказ провайдера
# (429, зависший поток, отвалившаяся авторизация, пустой ответ), а не на отказ задачи.
# Включать её на «схема не сошлась» значит списать бюджет дважды за тот же провал.
It 'запасная модель включается на отказ провайдера, а не задачи' {
    . (Join-Path $root 'harness\lib\bcf-context.ps1')
    . (Join-Path $root 'harness\lib\graph-runtime.ps1')

    foreach ($r in @('бэкенд отказал: rate limit 429', 'стрим молчит 300с — зависший поток модели',
                     'агент не вернул текста', 'бэкенд отказал: 401 unauthorized')) {
        Assert-True (Test-BcfFallbackWorthy $r) "провайдерский отказ не распознан: $r"
    }
    foreach ($r in @('схема: ответ не содержит разбираемого JSON', 'проверки на слитом дереве красные', '')) {
        Assert-True (-not (Test-BcfFallbackWorthy $r)) "на отказе задачи запасная включилась бы: $r"
    }
}

# Конфиг допускает обе формы записи: строку (та же CLI, другая модель) и объект.
It 'запасная читается и строкой, и объектом' {
    . (Join-Path $root 'harness\lib\bcf-context.ps1')
    . (Join-Path $root 'harness\lib\graph-runtime.ps1')

    $cfg = @'
{ "graph": { "backends": { "claude": { "command": "c {model}" }, "codex": { "command": "x {model}" } },
             "roles": { "a": { "backend": "claude", "model": "opus", "fallback": "sonnet" },
                        "b": { "backend": "claude", "model": "opus", "fallback": { "backend": "codex", "model": "gpt" } },
                        "c": { "backend": "claude", "model": "opus" } } } }
'@ | ConvertFrom-Json
    $roles = _GraphRoles $cfg
    Assert-True ($roles['a'].Fallback.Backend -eq 'claude') 'строка не унаследовала бэкенд роли'
    Assert-True ($roles['a'].Fallback.Model -eq 'sonnet')   'строка не прочиталась как модель'
    Assert-True ($roles['b'].Fallback.Backend -eq 'codex')  'объект не прочитался'
    Assert-True ($null -eq $roles['c'].Fallback)            'у роли без fallback появилась запасная'
}

It 'update --check не трогает рабочее дерево' {
    $before = (& git -C (Get-Location) status --porcelain | Out-String)
    $r = Bcf @('update', '--check')
    $after = (& git -C (Get-Location) status --porcelain | Out-String)
    Assert-True ($before -eq $after) '--check изменил рабочее дерево фабрики'
}

# Регрессия того же класса, что BEL в verify.ps1: управляющий байт в скрипте делает путь
# невозможным, ветка молча пропускается, и проверка выдаёт PASS, ничего не проверив.

# --- Учёт высоты кадра ------------------------------------------------------------------
#
# Перерисовка «на месте» возвращается к началу кадра ОТНОСИТЕЛЬНО текущего курсора: подняться
# надо ровно на столько строк, сколько было выведено в прошлый раз. Абсолютную координату
# запоминать нельзя — у нижнего края окна вывод кадра прокручивает буфер, запомненный Y
# перестаёт указывать на начало, и кадр дорисовывается вместо перерисовки. Именно так
# карточка `bcf` задваивалась при выборе стрелками (проверено на живой консоли: старая
# реализация оставляла на экране 2 заголовка вместо одного).
#
# Сам рисунок headless не проверить — он про позиционирование курсора. Проверяем то, на чём
# он держится: Frame.Lines обязан равняться числу ВЫВЕДЕННЫХ строк, включая затирающие.
# Разъедется этот счёт — разъедется и возврат.

It 'кадр помнит, на сколько строк ушёл курсор' {
    . (Join-Path $root 'src\lib\ui.ps1')
    . (Join-Path $root 'src\lib\tui.ps1')

    $f = New-BcfFrame
    Assert-True ($f.Lines -eq 0) 'новый кадр — нулевой высоты'

    $null = Write-BcfFrame -Frame $f -Lines @('a', 'b', 'c') 6>$null
    Assert-True ($f.Lines -eq 3) "после 3 строк ожидалось 3, получено $($f.Lines)"

    # Кадр стал короче: две строки содержимого + одна затирающая = курсор всё равно ушёл на 3.
    $null = Write-BcfFrame -Frame $f -Lines @('a', 'b') 6>$null
    Assert-True ($f.Lines -eq 3) "короткий кадр обязан досчитать затирающие: ожидалось 3, получено $($f.Lines)"

    # Кадр вырос: высота обязана вырасти вместе с ним, иначе подъём окажется коротким
    # и верх прошлого кадра останется на экране.
    $null = Write-BcfFrame -Frame $f -Lines @('a', 'b', 'c', 'd', 'e') 6>$null
    Assert-True ($f.Lines -eq 5) "выросший кадр: ожидалось 5, получено $($f.Lines)"
}

# --- Достижимость функций из команд ---------------------------------------------------
#
# bcf.ps1 подключает только paths.ps1 и ui.ps1; остальные библиотеки каждая команда берёт
# сама. Забыть подключение легко, а ошибка вылезает лишь на той ветке, где функция реально
# зовётся, — то есть у человека и обычно в самый неудобный момент. Так `bcf run` упал на
# Test-BcfInteractive уже ПОСЛЕ карточки и выбора задач: снаружи это выглядело как «прогон
# начался и умер», хотя не начинался.
#
# Проверка статическая: разбираем, кто что подключает, и ищем вызовы функций, до которых
# команда не дотягивается. Учитываем и src/lib, и harness/lib, и файлы, подключённые в
# чужой контекст (init-write.ps1 живёт внутри init.ps1 и видит его загрузки) — без этого
# проверка даёт ложные срабатывания и её перестают читать.

It 'каждая команда дотягивается до функций, которые зовёт' {
    $libDirs = @((Join-Path $root 'src\lib'), (Join-Path $root 'harness\lib'))
    $defs = @{}
    foreach ($d in $libDirs) {
        foreach ($f in (Get-ChildItem "$d\*.ps1" -ErrorAction SilentlyContinue)) {
            foreach ($m in [regex]::Matches((Get-Content -Raw $f.FullName), '(?m)^\s*function\s+([\w-]+)')) {
                $defs[$m.Groups[1].Value] = $f.Name
            }
        }
    }

    $cmdDir = Join-Path $root 'src\commands'
    $bodies = @{}
    foreach ($c in (Get-ChildItem "$cmdDir\*.ps1")) { $bodies[$c.Name] = Get-Content -Raw $c.FullName }

    # Кто кого подключает: команда, дот-сорснутая в другую, наследует её загрузки.
    $parents = @{}
    foreach ($name in $bodies.Keys) {
        foreach ($m in [regex]::Matches($bodies[$name], 'src\\commands\\([\w.-]+\.ps1)')) {
            $child = $m.Groups[1].Value
            if (-not $parents.ContainsKey($child)) { $parents[$child] = @() }
            $parents[$child] += $name
        }
    }

    function Get-Loaded([string]$name, $bodies, $parents, [hashtable]$seen) {
        if ($seen.ContainsKey($name)) { return @() }
        $seen[$name] = $true
        # Путь к библиотеке не всегда литерал: `Join-Path (Get-BcfHarness) 'lib\docker.ps1'`
        # собирает корень вызовом функции, и префикса `harness\` в тексте нет вовсе.
        # Поэтому цепляемся за общий хвост `lib\<файл>.ps1` — он есть во всех вариантах.
        $own = @([regex]::Matches($bodies[$name], 'lib\\([\w.-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value })
        foreach ($p in @($parents[$name])) { if ($p) { $own += Get-Loaded $p $bodies $parents $seen } }
        return $own
    }

    $problems = @()
    foreach ($name in ($bodies.Keys | Sort-Object)) {
        $body = $bodies[$name]
        $loaded = @('paths.ps1', 'ui.ps1') + (Get-Loaded $name $bodies $parents @{})
        $local = @([regex]::Matches($body, '(?m)^\s*function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
        foreach ($m in [regex]::Matches($body, '(?<![\w-])[A-Z][a-z]+-Bcf[\w-]*')) {
            $fn = $m.Value
            if ($local -contains $fn) { continue }
            if (-not $defs.ContainsKey($fn)) { continue }   # определена не в библиотеке — не наше дело
            if ($loaded -notcontains $defs[$fn]) { $problems += "$name зовёт $fn, но не подключает $($defs[$fn])" }
        }
    }
    Assert-True (-not $problems.Count) ("недостижимые вызовы:`n      " + (($problems | Select-Object -Unique) -join "`n      "))
}

# --- Флаг со значением в конце строки --------------------------------------------------
#
# Индекс за границей массива в PowerShell не ошибка: `--budget` последним аргументом
# давал [double]$null = 0, а ноль у бюджета означает «без лимита». Предохранитель денег
# отключался молча — худший способ отключаться.

It 'флаг без значения отказывает вслух, а не теряется молча' {
    $p = New-Sandbox 'run-flag-value'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    $r = Bcf @('run', 'night', '--project', $p, '--budget')
    Assert-True ($r.Code -eq 2) "ожидался exit 2, получен $($r.Code)"
    Assert-Match $r.Out 'без значения' 'причина отказа не названа'
}

It 'не число в числовом флаге — отказ с текстом, а не стек' {
    $p = New-Sandbox 'run-flag-nan'
    Bcf @('init', '--yes', '--project', $p) | Out-Null
    $r = Bcf @('run', 'night', '--max-iterations', 'дважды', '--project', $p)
    Assert-True ($r.Code -eq 2) "ожидался exit 2, получен $($r.Code)"
    Assert-Match $r.Out 'не число'
}

# --- Тариф бьётся по самой длинной модели ----------------------------------------------
#
# Поиск тарифа подстрокой брал ПЕРВЫЙ совпавший ключ: «gpt-4o-mini» содержит «gpt-4o»,
# и при неудачном порядке ключей mini считался по цене старшей модели. Разница в разы,
# молча, в отчёте о деньгах.

It 'модель mini бьётся о тариф mini, а не старшей модели' {
    . (Join-Path $root 'src\lib\pricing.ps1')
    $models = [pscustomobject]@{
        'gpt-4o'      = [pscustomobject]@{ blended = 10 }
        'gpt-4o-mini' = [pscustomobject]@{ blended = 1 }
    }
    $pricing = [pscustomobject]@{ Models = $models; Rate = 1.0 }
    $cost = Get-BcfNodeCost -Pricing $pricing -Model 'gpt-4o-mini' -Tokens 1000000
    Assert-True ($null -ne $cost) 'тариф не нашёлся вовсе'
    Assert-True ([math]::Abs($cost - 1.0) -lt 0.001) "mini посчитан по чужой ставке: $cost вместо 1"
}

# --- Проба авторизации имеет потолок времени -------------------------------------------
#
# Зависший CLI висел doctor навсегда: зависание потока здесь ШТАТНЫЙ случай, о нём
# пишет документация init и run, а проба ждала вечно.

It 'зависшая проба авторизации убивается по таймауту и зовётся ошибкой' {
    . (Join-Path $root 'src\lib\backends.ps1')
    $script:BcfBackends['test-hang'] = @{ env = @(); authCheck = 'Start-Sleep 30'; authOkPattern = '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $env:BCF_AUTH_TIMEOUT_SEC = '3'
    try { $r = Test-BcfBackendAuth -Name 'test-hang' } finally { Remove-Item Env:BCF_AUTH_TIMEOUT_SEC }
    $sw.Stop()
    Assert-True ($sw.ElapsedMilliseconds -lt 15000) "проба заняла $($sw.ElapsedMilliseconds)мс — таймаут не работает"
    Assert-True (-not $r.Ok) 'зависший CLI признан авторизованным'
    Assert-Match $r.Detail 'таймаут'
}

It 'здоровая проба авторизации отвечает и матчится по шаблону' {
    . (Join-Path $root 'src\lib\backends.ps1')
    $script:BcfBackends['test-ok'] = @{ env = @(); authCheck = "'auth-ok'"; authOkPattern = 'auth-ok' }
    $r = Test-BcfBackendAuth -Name 'test-ok'
    Assert-True $r.Ok 'живой CLI не признан авторизованным'
}

# --- Гард конкуренции verify читает живой журнал ---------------------------------------
#
# Проблема была в адресе: гард смотрел harness\events.jsonl фабрики, а шина пишет в
# <проект>\.bcf\events.jsonl. Оба адреса обязаны совпадать буквально — иначе правка
# одного из них снова разойдётся.

It 'гард verify берёт журнал из того же каталога состояния, что и шина' {
    $v = Get-Content -Raw (Join-Path $root 'harness\verify.ps1')
    # Шаблон в ОДИНАРНЫХ кавычках. В двойных PowerShell подставлял сюда $PSScriptRoot, и
    # проверка превращалась в поиск собственного пути: на каталоге, где встречается
    # недопустимая escape-последовательность (например \M), она падала разбором регулярки,
    # а на всех прочих молча проходила, ничего не проверив.
    Assert-NoMatch $v 'Join-Path \$PSScriptRoot ''events\.jsonl''' 'гард снова читает журнал из каталога фабрики'
    Assert-Match $v 'Get-BcfStateDir \$root\) .events\.jsonl.' 'журнал гарда не привязан к состоянию проекта'
}

# --- Триггеры читают конфиг проекта ----------------------------------------------------
#
# У фабрики нет каталога config/ вовсе: список friction-триггеров молча пуст во всех
# проектах, human-callout на миграции/auth не срабатывал ни разу. templates/config/
# кладёт triggers.json в проект — читать надо оттуда.

It 'triggers.ps1 грузит список из проекта, где его реально кладёт install' {
    $t = Get-Content -Raw (Join-Path $root 'harness\triggers.ps1')
    Assert-Match $t 'Join-Path \(Join-Path \$Repo ''config''\) ''triggers\.json''' 'конфиг триггеров не читается из проекта'
    Assert-NoMatch $t '\$repoRoot' 'адрес всё ещё собирается от корня фабрики'
}

# --- maven ---------------------------------------------------------------------------
#
# Java-проект был для разбора невидим целиком: экосистемы maven не существовало, и все
# четыре значения, ради которых разбор написан, оставались пустыми. Пустой productPaths
# означает, что любая итерация засчитывается как «прогресса нет»; пустой tests.runner —
# что гейт «фича доказана тестами» выключен, и задача закрывается без единого теста.
Write-Host ''
Write-Host '  maven' -ForegroundColor White

function New-MavenSandbox {
    param([string]$Name)
    $p = Join-Path $sandboxRoot $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src\main\java\ru\clinic') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src\main\resources') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'src\test\java\ru\clinic') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'target\classes') | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'pom.xml') -Encoding UTF8 -Value @'
<project><modelVersion>4.0.0</modelVersion>
  <groupId>ru.clinic</groupId><artifactId>schedule-core</artifactId><version>0.0.1</version>
</project>
'@
    Set-Content -LiteralPath (Join-Path $p 'src\main\java\ru\clinic\App.java') -Encoding UTF8 `
                -Value 'package ru.clinic; public class App { public static void main(String[] a) {} }'
    Set-Content -LiteralPath (Join-Path $p 'src\main\resources\application.yml') -Encoding UTF8 -Value 'spring: {}'
    Set-Content -LiteralPath (Join-Path $p 'src\test\java\ru\clinic\ModularityTests.java') -Encoding UTF8 -Value @'
package ru.clinic;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
class ModularityTests {
    @Test
    void modulesAreClean() {}
    @ParameterizedTest
    void eachModuleHasApi() {}
    @Test
    void noCycles() {}
}
'@
    Set-Content -LiteralPath (Join-Path $p 'target\classes\App.class') -Encoding UTF8 -Value 'compiled'
    & git -C $p init -q 2>&1 | Out-Null
    & git -C $p add -A 2>&1 | Out-Null
    & git -C $p -c user.name=t -c user.email=t@local commit -qm init 2>&1 | Out-Null
    return $p
}

It 'узнаёт сборку maven и раннер maven' {
    $p = New-MavenSandbox 'detect-maven'
    $r = Bcf @('detect', '--project', $p)
    Assert-Match $r.Out 'maven'  'сборка maven не названа'
    Assert-Match $r.Out 'Java'
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    Assert-True (@($j.Ecosystems) -contains 'maven') "экосистемы: $(@($j.Ecosystems) -join ', ')"
    Assert-True ($j.Tests.runner -eq 'maven') "раннер: $($j.Tests.runner)"
}

# Продуктовые пути названы точно, а не одним 'src'. Склеив их, разбор засчитал бы правку
# теста продуктовым прогрессом — и петля не заметила бы, что фичи нет.
It 'продуктовые пути maven — код и ресурсы, но не тесты' {
    $p = New-MavenSandbox 'detect-maven-paths'
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    $pp = @($j.ProductPaths)
    Assert-True ($pp -contains 'src/main/java') "нет src/main/java: $($pp -join ', ')"
    Assert-True ($pp -contains 'src/main/resources') "нет src/main/resources: $($pp -join ', ')"
    Assert-True (-not ($pp -contains 'src')) "склеено в один 'src': $($pp -join ', ')"
    Assert-True (-not ($pp -contains 'src/test/java')) "тесты попали в продуктовые пути: $($pp -join ', ')"
}

# target — вывод сборки. Не объявив его воспроизводимым, харнесс заблокирует слияние
# готовой задачи ровно так же, как однажды заблокировал лок-файл.
It 'target объявлен воспроизводимым, а тесты JUnit посчитаны' {
    $p = New-MavenSandbox 'detect-maven-tests'
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    Assert-True (@($j.Generated) -contains 'target') "generated: $(@($j.Generated) -join ', ')"
    Assert-True ($j.TestCounts.maven -eq 3) "тестов насчитано: $($j.TestCounts.maven)"
}

# Обёртки mvnw.cmd в песочнице нет. Предлагать команду, которой не существует, нельзя:
# гейт на несуществующей команде красный всегда, и агент начинает чинить несуществующее.
It 'без обёртки mvnw.cmd быстрая проверка предлагается через mvn' {
    $p = New-MavenSandbox 'detect-maven-nowrapper'
    $j = (Bcf @('detect', '--project', $p, '--json')).Out | ConvertFrom-Json
    $tc = @($j.Typechecks) -join ' '
    Assert-Match $tc 'test-compile' 'быстрой проверки для Java не предложено'
    Assert-NoMatch $tc 'mvnw' 'предложена обёртка, которой в проекте нет'
}

# --- Итог ----------------------------------------------------------------------------
Write-Host ''
if ($script:fail) {
    Write-Host "  ПРОВАЛ: $($script:fail) из $($script:pass + $script:fail)" -ForegroundColor Red
} else {
    Write-Host "  ВСЁ ЗЕЛЁНОЕ: $($script:pass) тестов" -ForegroundColor Green
}
Write-Host ''

# Песочницу убираем только на зелёном: на красном она — единственный способ посмотреть,
# что именно записалось.
if (-not $script:fail) { Remove-Item -Recurse -Force $sandboxRoot -ErrorAction SilentlyContinue }
else { Write-Host "  песочница оставлена для разбора: $sandboxRoot" -ForegroundColor DarkGray }

exit $(if ($script:fail) { 1 } else { 0 })
