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
    param([string[]]$CliArgs)
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
It 'в скриптах нет управляющих байтов' {
    $bad = @()
    foreach ($f in (Get-ChildItem -Path (Join-Path $root 'harness'), (Join-Path $root 'src'), (Join-Path $root 'bin') -Recurse -Filter '*.ps1')) {
        $text = Get-Content -Raw -LiteralPath $f.FullName
        for ($i = 0; $i -lt $text.Length; $i++) {
            $c = [int]$text[$i]
            # разрешены только табуляция, перевод строки и возврат каретки
            if ($c -lt 32 -and $c -ne 9 -and $c -ne 10 -and $c -ne 13) {
                $line = ($text.Substring(0, $i) -split "`n").Count
                $bad += "$($f.Name):$line  байт 0x{0:X2}" -f $c
                break
            }
        }
    }
    Assert-True ($bad.Count -eq 0) ("управляющие байты: " + ($bad -join '; '))
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
    foreach ($row in @('проект', 'бэкенды', 'память', 'тарифы', 'подписки')) {
        Assert-Match $r.Out $row "в карточке нет строки «$row»"
    }
    # То, чего нет, называется словом «нет» и ценой, а не прячется и не выдумывается.
    Assert-Match $r.Out 'тарифы\s+не заданы'
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
