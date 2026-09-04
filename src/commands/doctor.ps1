# bcf doctor — живая проба окружения. Без работы, но с настоящими запросами.
#
#   bcf doctor              бэкенды + память + проверки проекта
#   bcf doctor --no-probe   без запросов к моделям (только бинари и авторизации)
#   bcf doctor --checks     ещё и прогнать backpressure проекта
#
# ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА. Дефекты проводки МОЛЧАЛИВЫ. Неавторизованный бэкенд отвечает
# штатным событием, а не падением: снаружи это выглядит как пустой ответ модели, и
# обвязка спокойно записывает «агент ничего не сделал». Поймать это можно только
# настоящим запуском — поэтому он здесь и есть, на тривиальном промпте, до того как от
# бэкенда начнёт зависеть боевой прогон.

. (Join-Path $BcfRoot 'src\lib\backends.ps1')
. (Join-Path $BcfRoot 'src\lib\detect.ps1')

$noProbe   = $script:BcfArgs -contains '--no-probe'
$runChecks = $script:BcfArgs -contains '--checks'
$project   = $script:BcfProject

Write-BcfTitle "ОКРУЖЕНИЕ  $(Split-Path $project -Leaf)" "фабрика v$(Get-BcfVersion) · $(Get-BcfHome)"

$bad = 0
$warn = 0

# --- Бэкенды --------------------------------------------------------------------------
Write-BcfLine '  БЭКЕНДЫ' 'White'
Write-Host ''

$cfg = $null
try { $cfg = Get-BcfHarnessConfig -Project $project } catch { Write-BcfWarn "config/harness.json: $($_.Exception.Message)" }

# Какие роли на каком бэкенде — определяет, что считать поломкой: сломанный бэкенд без
# ролей это факт, сломанный бэкенд С ролью это остановленный прогон.
$roleOf = @{}
if ($cfg -and $cfg.graph -and $cfg.graph.roles) {
    foreach ($p in $cfg.graph.roles.PSObject.Properties) {
        if ($p.Name -eq '$comment' -or -not $p.Value.backend) { continue }
        $b = [string]$p.Value.backend
        if (-not $roleOf.ContainsKey($b)) { $roleOf[$b] = @() }
        $roleOf[$b] += $p.Name
    }
}

$survey = Invoke-BcfBackendSurvey
foreach ($r in $survey) {
    $roles = @()
    foreach ($k in $roleOf.Keys) {
        if ($k -eq $r.Name -or (Get-BcfKnownBackends)[$k].aliasOf -eq $r.Name) { $roles += $roleOf[$k] }
    }
    $roleTxt = if ($roles.Count) { "роли: $($roles -join ', ')" } else { 'ролей нет' }

    if (-not $r.Installed) {
        Write-BcfDim ("{0,-11} не установлен   ({1})" -f $r.Name, $roleTxt)
        if ($roles.Count) { $bad++ }
        continue
    }
    if (-not $r.AuthOk) {
        Write-BcfFail ("{0,-11} НЕ АВТОРИЗОВАН   ({1})" -f $r.Name, $roleTxt)
        if ($r.AuthDetail) { Write-BcfNote $r.AuthDetail }
        if ($roles.Count) { $bad++ } else { $warn++ }
        continue
    }
    $ver = if ($r.Version) { "v$($r.Version)" } else { '' }
    Write-BcfOk ("{0,-11} {1,-9} {2,-13} ({3})" -f $r.Name, $ver, $r.Auth, $roleTxt)
    if (-not $r.OnPath) {
        Write-BcfNote "не на PATH, найден по пути: $($r.Path)"
        Write-BcfNote 'путь содержит версию сборки и меняется после обновления приложения — перепроверь после апдейта.'
        $warn++
    }
    if (-not $r.Tokens -and $roles.Count) {
        Write-BcfLine "     ⚠ расход токенов в потоке не виден — бюджетный ограничитель на ролях $($roles -join ', ') слеп" 'Yellow'
        $warn++
    }
}

# Бэкенды, объявленные ПРОЕКТОМ, но отсутствующие в каталоге фабрики.
#
# Без этого блока роль, сидящая на собственном бэкенде проекта (своя обёртка, локальная
# модель, форк CLI), просто исчезала из вывода: doctor перебирал только знакомые имена и
# докладывал «все роли отвечают», ни разу не взглянув на ту, которая и исполняет работу.
$known = @((Get-BcfKnownBackends).Keys)
$foreign = @($roleOf.Keys | Where-Object { $known -notcontains $_ })
if ($foreign.Count) {
    Write-Host ''
    foreach ($b in $foreign) {
        $entry = if ($cfg.graph.backends) { $cfg.graph.backends.PSObject.Properties[$b] } else { $null }
        if (-not $entry) {
            Write-BcfFail ("{0,-11} роли {1} ссылаются на бэкенд, которого НЕТ в config/harness.json → graph.backends" -f $b, ($roleOf[$b] -join ', '))
            $bad++
            continue
        }
        # Бинарь проверяем: путь в команде проекта может указывать на то, чего нет —
        # особенно если он содержит версию сборки и приложение с тех пор обновилось.
        $cmd = [string]$entry.Value.command
        $exe = if ($cmd -match "^&\s*'([^']+)'") { $Matches[1] } else { ($cmd -split '\s+')[0] }
        $ok = (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue) -or [bool](Get-Command $exe -ErrorAction SilentlyContinue)
        if ($ok) {
            Write-BcfOk ("{0,-11} свой бэкенд проекта, бинарь на месте   (роли: {1})" -f $b, ($roleOf[$b] -join ', '))
            Write-BcfNote 'его нет в каталоге фабрики: авторизацию и формат потока проверить нечем, только живой пробой.'
            $warn++
        } else {
            Write-BcfFail ("{0,-11} свой бэкенд проекта, бинарь НЕ найден: {1}   (роли: {2})" -f $b, $exe, ($roleOf[$b] -join ', '))
            $bad++
        }
    }
}

# То же для знакомых бэкендов: команда в конфиге проекта может указывать на путь, которого
# уже нет (приложение обновилось — хэш сборки в пути сменился), а doctor при этом покажет
# «✓» по бинарю, найденному в системе, но НЕ тому, который реально пропишется в узел.
if ($cfg -and $cfg.graph -and $cfg.graph.backends) {
    foreach ($p in $cfg.graph.backends.PSObject.Properties) {
        if ($p.Name -eq '$comment' -or -not $roleOf.ContainsKey($p.Name)) { continue }
        $cmd = [string]$p.Value.command
        if ($cmd -notmatch "^&\s*'([^']+)'") { continue }
        $pinned = $Matches[1]
        if (-not (Test-Path -LiteralPath $pinned -ErrorAction SilentlyContinue)) {
            Write-Host ''
            Write-BcfFail ("{0}: в конфиге закреплён путь, которого нет: {1}" -f $p.Name, $pinned)
            Write-BcfNote "роли $($roleOf[$p.Name] -join ', ') упрутся на первом же узле, даже если такой CLI есть в системе:"
            Write-BcfNote 'узел запускается ИМЕННО этой командой. Обнови путь в config/harness.json → graph.backends.'
            $bad++
        }
    }
}

# --- Живая проба ролей ----------------------------------------------------------------
#
# Здесь и только здесь тратятся токены. Один короткий запрос на роль: этого достаточно,
# чтобы отличить «CLI отвечает» от «модель отвечает и её ответ разбирается».
# Неназначенные роли — блокер, и он проверяется НЕЗАВИСИМО от того, гоняем ли мы живую
# пробу. Раньше эта проверка жила в ветке else и с --no-probe не выполнялась: doctor на
# проекте без ролей печатал «ГОТОВ» и отдавал ноль — то есть флаг «не тратить токены»
# заодно выключал единственную проверку, которая ловит ненастроенный граф.
if (-not $roleOf.Count) {
    Write-Host ''
    Write-BcfFail 'роли графа не назначены (config/harness.json → graph.roles)'
    Write-BcfNote 'граф не знает, каким бэкендом исполнять узел, и упрётся на первом же.'
    Write-BcfNote 'назначить: bcf init'
    $bad++
}

if (-not $noProbe -and $roleOf.Count) {
    Write-Host ''
    Write-BcfLine '  ЖИВАЯ ПРОБА РОЛЕЙ' 'White'
    Write-BcfNote 'по одному короткому запросу на роль — единственное место, где doctor тратит токены'
    Write-Host ''

    # Вывод дочернего процесса идёт СРАЗУ, а не после его конца.
    #
    # `… | Out-String` буферизует всё до завершения, а завершается это не быстро: проба
    # каждой роли — живой запуск бэкенда с потолком в 180 секунд на каждый, плюс подъём
    # памяти. На четырёх ролях экран молчал минутами и выглядел зависшим ровно в той
    # команде, которую запускают, чтобы понять, всё ли живо.
    $graphPs1 = Join-Path (Get-BcfHarness) 'graph.ps1'
    & pwsh -NoProfile -File $graphPs1 -Doctor -ProjectRoot $project 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line.Trim()) { Write-Host $line }
    }
    if ($LASTEXITCODE -ne 0) { $bad++ }
} elseif ($noProbe) {
    Write-Host ''
    Write-BcfDim 'живая проба пропущена (--no-probe): «бинарь есть» ещё не значит «модель отвечает».'
}

# --- Память ---------------------------------------------------------------------------
#
# Проверяем не «доступна ли», а ЧТО В НЕЙ ЛЕЖИТ. «Память активна» — бесполезный признак:
# она бывает активна и при этом содержит один-единственный урок, который перечитывается
# полсотни раз. Живое обучение — это рост чисел от прогона к прогону.
Write-Host ''
Write-BcfLine '  ПАМЯТЬ' 'White'
Write-Host ''

$memClient = Join-Path (Get-BcfMemoryDir) 'pgvector\memory_client.py'

# Без этого диагностика клиента приходит в кодировке консоли и читается как мусор —
# то есть теряется ровно там, где важнее всего: в сообщении о причине отказа.
$env:PYTHONIOENCODING = 'utf-8'
$memOn = $cfg -and $cfg.features -and $cfg.features.memory
if (-not (Test-Path $memClient)) {
    Write-BcfWarn "клиент памяти не найден: $memClient"
    $warn++
} elseif (-not $memOn) {
    Write-BcfDim 'выключена в config/harness.json → features.memory'
    Write-BcfNote 'без неё прогоны не учатся на прошлых ошибках: один и тот же провал повторяется каждый прогон.'
} else {
    # Причину отказа показываем ДОСЛОВНО и называем базу, к которой ходили. «Недоступна,
    # поднять: bcf memory init» — совет, который чинит базу фабрики, тогда как проект мог
    # быть настроен на собственную: человек поднимает не ту и не понимает, почему не помогло.
    $stats = ''
    $memErr = ''
    try {
        $stats = (& python $memClient stats 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $memErr = $stats; $stats = '' }
    } catch { $memErr = $_.Exception.Message; $stats = '' }

    $memCfgPath = ''
    foreach ($c in @((Join-Path $project 'config\memory.config.json'), (Join-Path (Get-BcfMemoryDir) 'memory.config.json'))) {
        if (Test-Path $c) { $memCfgPath = $c; break }
    }
    $memWhere = ''
    if ($memCfgPath) {
        try {
            $mc = Get-Content -Raw -LiteralPath $memCfgPath | ConvertFrom-Json
            $memWhere = "$($mc.host):$($mc.port), контейнер $(if ($mc.container) { $mc.container } else { 'bcf-agent-memory' })"
        } catch { }
    }

    if ($stats -match '\{') {
        try {
            $j = $stats | ConvertFrom-Json
            $ap = [int]$j.anti_patterns; $bg = [int]$j.bugs; $rc = [int]$j.recalls
            # ПУСТАЯ БАЗА — НЕ ДИАГНОЗ «ЗАПИСЬ СЛОМАНА». Вердикт общий с графом и
            # `bcf memory status`: три копии этого текста уже разъехались однажды.
            . (Join-Path (Get-BcfHarness) 'lib\graph-memory.ps1')
            $v = Get-BcfLearningVerdict -Lessons $ap -Project $project

            $col = if ($v.Level -eq 'broken') { 'Yellow' } else { 'Green' }
            Write-BcfLine ("  ✓ доступна · уроков {0} · багов {1} · отзывов {2}" -f $ap, $bg, $rc) $col
            if ($v.Level -eq 'broken') {
                Write-BcfLine "    ⚠ $($v.Text)" 'Yellow'
                Write-BcfNote 'провал узла и подтверждённая находка критика обязаны становиться уроками.'
                $warn++
            } elseif ($v.Level -eq 'empty') {
                Write-BcfLine "    · $($v.Text)" 'DarkGray'
                Write-BcfNote 'после первого прогона число обязано вырасти; если не выросло — запись не работает.'
            }
        } catch { Write-BcfOk 'доступна (счётчики не разобрались)' }
    } else {
        Write-BcfFail 'недоступна — уроки не отзываются и не пишутся, обучение выключено'
        if ($memWhere) { Write-BcfNote "ходили в: $memWhere   (конфиг: $(Split-Path $memCfgPath -Leaf))" }
        if ($memErr) {
            $first = @($memErr -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
            Write-BcfNote "ответ клиента: $first"
        }
        Write-BcfNote 'поднять: bcf memory init'
        $warn++
    }
}

# --- Проверки проекта -----------------------------------------------------------------
Write-Host ''
Write-BcfLine '  ПРОВЕРКИ ПРОЕКТА' 'White'
Write-Host ''

$bp = @()
if ($cfg -and $cfg.backpressure -and $cfg.backpressure.typecheck) { $bp = @($cfg.backpressure.typecheck | Where-Object { $_ }) }
if (-not $bp.Count) {
    Write-BcfWarn 'backpressure.typecheck пуст — ошибки компиляции всплывут только на верификации'
    $warn++
} elseif ($runChecks) {
    foreach ($c in $bp) {
        $r = Test-BcfCommand -Command $c -Root $project -TimeoutSec 300
        if ($r.Ok) { Write-BcfOk ("{0}   {1}s" -f $c, $r.Seconds) }
        else {
            Write-BcfFail ("{0}   exit {1}" -f $c, $r.ExitCode)
            Write-BcfNote ($r.Output -replace "`n", "`n    ")
            $bad++
        }
    }
} else {
    foreach ($c in $bp) { Write-BcfDim "$c   (не запускалась — bcf doctor --checks)" }
}

$testsRunner = if ($cfg -and $cfg.tests) { [string]$cfg.tests.runner } else { '' }
if (-not $testsRunner) {
    Write-BcfWarn 'tests.runner не задан — гейт «фича доказана тестами» не работает'
    $warn++
} else {
    Write-BcfOk "раннер тестов: $testsRunner"
}

$checksFile = Join-Path $project 'config\checks.json'
if (Test-Path $checksFile) {
    try {
        $cj = Get-Content -Raw -LiteralPath $checksFile | ConvertFrom-Json
        $def = @($cj._default | Where-Object { $_ -is [string] -and $_.Trim() })
        if (-not $def.Count) {
            Write-BcfWarn 'config/checks.json → _default пуст: задача без собственных проверок может получить PASS на одном судье'
            $warn++
        } else { Write-BcfOk "обязательных проверок по умолчанию: $($def.Count)" }
    } catch { Write-BcfFail "config/checks.json не разобран: $($_.Exception.Message)"; $bad++ }
} else {
    Write-BcfWarn 'config/checks.json нет — вердикт не на чем строить (bcf install)'
    $warn++
}

# --- ЕСТЬ ЛИ ЧЕМ ВЫПОЛНИТЬ ГЕЙТ -------------------------------------------------------
#
# Проверка, инструмента для которой в проекте нет, — это не «строгий гейт», это гейт,
# который падает всегда и по причине, не имеющей отношения к работе. Хуже того, npm на
# отсутствующий локальный бинарь подсовывает одноимённый пакет из реестра: `npx tsc`
# отвечает «This is not the tsc command you are looking for», и в логе это выглядит как
# поломка компилятора, а не как незаявленная зависимость.
#
# Цена измерена: 2026-08-06 typescript не был объявлен в package.json и жил в node_modules
# случайно. Первая же чистая установка его вымела — и слияние ДВУХ готовых задач волны
# упало на «проверки на слитом дереве красные». Проверяется дёшево и до прогона.
$allCmds = @($bp)
if (Test-Path $checksFile) {
    try {
        $cj2 = Get-Content -Raw -LiteralPath $checksFile | ConvertFrom-Json
        foreach ($p in $cj2.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            $allCmds += @($p.Value | Where-Object { $_ -is [string] })
        }
        $allCmds += @($cj2._default | Where-Object { $_ -is [string] })
    } catch { }
}

$missingBins = @{}
foreach ($c in @($allCmds | Where-Object { $_ })) {
    # Интересует ровно форма «npx [--флаги] <бинарь>»: она обещает локальный инструмент.
    $m = [regex]::Match([string]$c, '^\s*npx\s+((?:--[\w-]+\s+)*)([\w.@/-]+)')
    if (-not $m.Success) { continue }
    $bin = $m.Groups[2].Value
    if ($bin -like '-*') { continue }
    $hit = @("$bin", "$bin.cmd", "$bin.ps1") | Where-Object {
        Test-Path (Join-Path $project (Join-Path 'node_modules\.bin' $_))
    }
    if (-not $hit) { $missingBins[$bin] = $c }
}
foreach ($bin in ($missingBins.Keys | Sort-Object)) {
    Write-BcfFail "гейт нечем выполнить: '$bin' не установлен (node_modules/.bin пуст на него)"
    Write-BcfNote "команда: $($missingBins[$bin])"
    Write-BcfNote 'npx подставит одноимённый пакет из реестра, и падение будет выглядеть'
    Write-BcfNote "поломкой инструмента. Объяви зависимость в package.json и поставь: npm i -D $bin"
    $bad++
}

# --- ЧТО ДОКАЗЫВАЕТ ЗЕЛЁНЫЙ ПРОГОН ------------------------------------------------------
#
# Разбор clinic-scheduler (2026-08-09): прогон закрыл 35 задач из 35 и напечатал COMPLETE,
# а продуктом пользоваться было нельзя — ни одного работающего клиентского пути. Гейты не
# соврали, они отвечали на другой вопрос: «дерево в порядке», а не «человек может работать».
# Здесь doctor говорит заранее, ЧТО именно докажет зелёный прогон этого проекта.
Write-Host ''
Write-BcfLine '  ЧТО ДОКАЖЕТ ЗЕЛЁНЫЙ ПРОГОН' 'White'
Write-Host ''

$jFile = Join-Path $project 'config\journeys.json'
if (-not (Test-Path $jFile)) {
    Write-BcfWarn 'сквозные сценарии не заведены (config/journeys.json)'
    Write-BcfNote 'зелёный прогон докажет состояние дерева, но НЕ то, что продуктом можно пользоваться:'
    Write-BcfNote 'ни один гейт не запускает приложение и не проходит путь пользователя.'
    Write-BcfNote 'завести: config/journeys.json со списком путей, ради которых продукт существует.'
    $warn++
} else {
    try {
        $jr = Get-Content -Raw -LiteralPath $jFile | ConvertFrom-Json
        $js = @($jr.journeys | Where-Object { $_ -and $_.id })
        if (-not $js.Count) {
            Write-BcfFail 'config/journeys.json заведён, но список сценариев пуст'
            $bad++
        } else {
            # planned — путь назван, но ещё не доказан: это состояние плана, а не дефект
            # настройки. Требовать файл для него значило бы запретить объявлять цели.
            $plannedJ  = @($js | Where-Object { ([string]$_.status) -eq 'planned' })
            $requiredJ = @($js | Where-Object { ([string]$_.status) -ne 'planned' })
            $noProof = @($requiredJ | Where-Object {
                (-not $_.proof) -or -not (Test-Path (Join-Path $project ([string]$_.proof -replace '/', [IO.Path]::DirectorySeparatorChar)))
            })
            if ($noProof.Count) {
                Write-BcfFail "сценариев без файла-доказательства: $($noProof.Count) из $($requiredJ.Count) обязательных"
                foreach ($n in $noProof) { Write-BcfNote "$($n.id) -> $($n.proof)" }
                Write-BcfNote 'объявленный, но не доказанный сценарий выглядит покрытым — это хуже отсутствующего.'
                Write-BcfNote 'если путь ещё не делается — поставь ему "status": "planned".'
                $bad++
            } elseif (-not $requiredJ.Count) {
                Write-BcfWarn "все $($js.Count) сценариев в статусе planned — ни один путь продукта пока не доказан"
                Write-BcfNote 'зелёный прогон докажет состояние дерева, но не работу пользователя.'
                $warn++
            } else {
                Write-BcfOk "сквозных сценариев доказано: $($requiredJ.Count) из $($js.Count)"
                Write-BcfNote 'прогнать: pwsh harness/journey-gate.ps1'
            }
            # ВЛАДЕЛЕЦ ПУТИ ОБЯЗАН БЫТЬ ТЕМ, КТО МОЖЕТ ЕГО ЗАКРЫТЬ.
            #
            # Поле task решает, кого Фаза J валит за красный путь. 2026-08-10: у пути
            # стояло два владельца — серверная задача и клиентская, — и серверная
            # получила FAIL за путь, который без клиентской зелёным быть не может.
            # Проверяется дёшево: файл-доказательство обязан быть в разделе «Файлы»
            # задачи-владельца, иначе она физически не может сделать путь зелёным.
            $tasksDir = Join-Path $project 'tasks'
            $ownerBad = @()
            foreach ($jj in $js) {
                $owners = @([regex]::Matches([string]$jj.task, '[A-Za-z]+-\d+') | ForEach-Object { $_.Value })
                if ($owners.Count -gt 1) { $ownerBad += "$($jj.id): владельцев несколько ($($owners -join ', ')) — валить будут всех"; continue }
                if (-not $owners.Count) { continue }
                $tf = @(Get-ChildItem -LiteralPath $tasksDir -Filter "$($owners[0])-*.md" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                if (-not $tf.Count) { $ownerBad += "$($jj.id): владелец $($owners[0]) — файла задачи нет"; continue }
                $body = Get-Content -Raw -LiteralPath $tf[0].FullName -ErrorAction SilentlyContinue
                if ($body -and $jj.proof -and ($body -notmatch [regex]::Escape([string]$jj.proof))) {
                    $ownerBad += "$($jj.id): владелец $($owners[0]) не заявляет $($jj.proof) в своих файлах"
                }
            }
            if ($ownerBad.Count) {
                Write-BcfFail "владелец пути не может его закрыть: $($ownerBad.Count)"
                foreach ($b in $ownerBad) { Write-BcfNote $b }
                Write-BcfNote 'Фаза J валит по красному пути ИМЕННО владельца — он обязан быть ровно один и тот,'
                Write-BcfNote 'в чьём разделе «Файлы» лежит файл-доказательство.'
                $bad++
            }

            if ($plannedJ.Count -and $noProof.Count -eq 0 -and $requiredJ.Count) {
                Write-BcfWarn "путей объявлено, но ещё не доказано (planned): $($plannedJ.Count)"
                foreach ($p in $plannedJ) { Write-BcfNote "$($p.id) — $($p.title)" }
                Write-BcfNote 'пока они planned, «продукт готов» сказать нельзя — доказана только часть путей.'
                $warn++
            }
        }
    } catch { Write-BcfFail "config/journeys.json не разобран: $($_.Exception.Message)"; $bad++ }
}

# --- КОНФИГ ПРОТИВ ФАЙЛОВОЙ СИСТЕМЫ ------------------------------------------------------
#
# `bcf init` кладёт шаблоны-примеры (scope-map с slug'ами home/settings, пути src/api/,
# server/). Проект, который их не переписал, получает не «строгую настройку», а тихую
# деградацию: правка не попадает ни в один slug, визуальная фаза схлопывается в __none__,
# скоуп тестеров не матчится ни на что. Всё это выглядит в логе как «нечего проверять».
$fsProblems = 0

$pp = @()
if ($cfg -and $cfg.productPaths) { $pp = @($cfg.productPaths | Where-Object { $_ }) }
if (-not $pp.Count) {
    Write-BcfWarn 'productPaths пуст — «прогресса нет» и область ревью определить нечем'
    $warn++
} else {
    $ppMissing = @($pp | Where-Object { -not (Test-Path (Join-Path $project ([string]$_ -replace '/', [IO.Path]::DirectorySeparatorChar))) })
    if ($ppMissing.Count) {
        Write-BcfFail "productPaths указывает на несуществующие каталоги: $($ppMissing -join ', ')"
        Write-BcfNote 'правки вне реальных productPaths не считаются работой над задачей.'
        $bad++
    } else { Write-BcfOk "productPaths: $($pp -join ', ')" }
}

$smFile = Join-Path $project 'config\scope-map.json'
if (Test-Path $smFile) {
    try {
        $sm = Get-Content -Raw -LiteralPath $smFile | ConvertFrom-Json
        $deadTesters = @()
        foreach ($t in @($sm.testers)) {
            if (-not $t.patterns) { continue }
            $alive = @($t.patterns | Where-Object {
                $p = ([string]$_).TrimEnd('/*') -replace '/', [IO.Path]::DirectorySeparatorChar
                $p -and (Test-Path (Join-Path $project $p))
            })
            if (-not $alive.Count) { $deadTesters += [string]$t.tester }
        }
        if ($deadTesters.Count) {
            Write-BcfWarn "скоуп тестеров не матчится ни на один реальный путь: $($deadTesters -join ', ')"
            Write-BcfNote 'похоже на неотредактированный шаблон из bcf init — тестер будет молча отбрасываться.'
            $warn++; $fsProblems++
        }
        $deadSlugs = @()
        foreach ($r in @($sm.vision.rules)) {
            if (-not $r.patterns) { continue }
            $alive = @($r.patterns | Where-Object {
                $p = ([string]$_).TrimEnd('/*') -replace '/', [IO.Path]::DirectorySeparatorChar
                $p -and (Test-Path (Join-Path $project $p))
            })
            if (-not $alive.Count) { $deadSlugs += [string]$r.slug }
        }
        if ($deadSlugs.Count) {
            Write-BcfWarn "визуальные slug'и не матчатся ни на один реальный путь: $($deadSlugs -join ', ')"
            Write-BcfNote 'любая правка отобразится в __none__, и визуальная фаза пропустится целиком.'
            $warn++; $fsProblems++
        }
        if (-not $fsProblems) { Write-BcfOk 'scope-map совпадает с деревом проекта' }
    } catch { Write-BcfFail "config/scope-map.json не разобран: $($_.Exception.Message)"; $bad++ }
}

# --- СОСТОЯНИЕ РЕПОЗИТОРИЯ ---------------------------------------------------------------
#
# Оборванный прогон оставляет дерево в MERGING: арбитр слияния намеренно не отменяет
# конфликтный merge, завершить обязан вызывающий, а он умер. Следующая ночь после такого
# обрыва проходит целиком впустую — слияние отваливается у каждой задачи подряд с
# причиной «основное дерево грязное», к самим задачам отношения не имеющей.
#
# До этой правки слово git не встречалось в doctor ни разу: самое дорогое состояние
# проекта не проверялось вообще.
Write-Host ''
Write-BcfLine '  СОСТОЯНИЕ РЕПОЗИТОРИЯ' 'White'
Write-Host ''
. (Join-Path $BcfRoot 'src\lib\git-readiness.ps1')
$gitState = Get-BcfGitReadiness -Root $project
Write-BcfGitReadiness -State $gitState
$bad  += $gitState.Blocking.Count
$warn += $gitState.Warnings.Count

# --- Итог -----------------------------------------------------------------------------
Write-Host ''
if ($bad) {
    Write-BcfLine "  НЕ ГОТОВ: блокирующих проблем — $bad, предупреждений — $warn." 'Red'
    Write-BcfNote 'Прогон упрётся в перечисленное выше. Чинить сверху вниз.'
    Write-Host ''
    exit 1
}
if ($warn) {
    Write-BcfLine "  ГОТОВ С ОГОВОРКАМИ: предупреждений — $warn." 'Yellow'
    Write-BcfNote 'Прогон поедет, но часть гарантий не работает — см. выше.'
    Write-Host ''
    exit 0
}
Write-BcfLine '  ГОТОВ: все роли отвечают, гейты на месте.' 'Green'
Write-Host ''
exit 0
