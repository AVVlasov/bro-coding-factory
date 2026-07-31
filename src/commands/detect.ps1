# bcf detect — разбор проекта. Ничего не пишет на диск.
#
#   bcf detect              быстрый разбор
#   bcf detect --probe      + живой запуск кандидатов в backpressure
#   bcf detect --json       машиночитаемо

. (Join-Path $BcfRoot 'src\lib\detect.ps1')

$probe = $script:BcfArgs -contains '--probe'
$asJson = $script:BcfArgs -contains '--json'
$project = $script:BcfProject

$d = Invoke-BcfDetect -Root $project -Probe:$probe

if ($asJson) {
    ($d | ConvertTo-Json -Depth 8) | Write-Output
    exit 0
}

Write-BcfTitle "РАЗБОР ПРОЕКТА  $(Split-Path $project -Leaf)" `
               "прочитано $($d.Languages.Total) файлов, не записано ничего"

$top = @($d.Languages.Languages | Select-Object -First 4)
if ($top.Count) {
    $langs = ($top | ForEach-Object { "$($_.Language) $($_.Percent)%" }) -join '   '
    Write-BcfField 'языки' $langs
} else {
    Write-BcfField 'языки' '(исходников не найдено)'
}

Write-BcfField 'сборка' $(if ($d.Ecosystems.Count) { $d.Ecosystems -join ', ' } else { '(манифестов не найдено)' })

if ($d.Git.IsGit) {
    $dirty = if ($d.Git.Dirty.Count) { "$($d.Git.Dirty.Count) грязных" } else { 'чисто' }
    $hooks = if ($d.Git.Hooks.Count) { "git-хуков $($d.Git.Hooks.Count)" } else { 'git-хуков нет' }
    # Про worktree говорим то, что ИЗМЕРИЛИ: все прогоны идут через него, и безусловная
    # строка «поддерживается» — утверждение, за которое никто не отвечает.
    $wt = if ($d.Git.Worktree) { 'worktree работает' } else { 'worktree НЕ отвечает' }
    Write-BcfField 'git' "$($d.Git.Branch) · $dirty · $wt · $hooks"
} else {
    Write-BcfField 'git' 'НЕ репозиторий'
}

$docsFound = @($d.Docs.Files | Where-Object { $_.Exists })
Write-BcfField 'доки' $(if ($docsFound.Count) {
    (($docsFound | ForEach-Object { "$($_.Path) ($($_.Lines) строк)" }) -join ', ')
} else { '(README/CLAUDE.md/PRD не найдены)' })

Write-Host ''
Write-BcfLine '  ПРЕДЛАГАЕМ ЗАПИСАТЬ В config/harness.json' 'White'
Write-Host ''

Write-BcfField 'productPaths' $(if ($d.ProductPaths.Count) { $d.ProductPaths -join ', ' } else { '(не определились)' }) `
               $(if ($d.ProductPaths.Count) { 'уверенно' } else { 'догадка' }) 18

foreach ($t in $d.Typechecks) {
    $p = @($d.Probes | Where-Object { $_.Command -eq $t }) | Select-Object -First 1
    $src = if ($p) { if ($p.Ok) { 'проверено' } else { 'догадка' } } else { 'уверенно' }
    $val = if ($p -and -not $p.Ok) { "$t   ← упало (exit $($p.ExitCode))" } else { $t }
    Write-BcfField 'backpressure' $val $src 18
}
if (-not $d.Typechecks.Count) {
    Write-BcfField 'backpressure' '(быстрой проверки не нашлось)' 'догадка' 18
}

Write-BcfField 'generatedFiles' $(if ($d.Generated.Count) { $d.Generated -join ', ' } else { '(нет)' }) `
               $(if ($d.Generated.Count) { 'уверенно' } else { 'догадка' }) 18
# Несколько раннеров — не деталь, а разрыв гарантии: гейт «фича доказана тестами»
# одноместный, и половина задач будет проверяться чужим раннером.
$runnerVal = if (-not $d.Tests.runner) { '(не определился)' }
             elseif ($d.Runners.Count -gt 1) { "$($d.Tests.runner)   ← найдено $($d.Runners.Count): $((($d.Runners | ForEach-Object { "$($_.Runner)$(if ($_.Scope) { " в $($_.Scope)" })" }) -join ', '))" }
             else { $d.Tests.runner }
Write-BcfField 'tests.runner' $runnerVal `
               $(if (-not $d.Tests.runner) { 'догадка' } elseif ($d.Runners.Count -gt 1) { 'догадка' } else { 'уверенно' }) 18

Write-Host ''
Write-BcfNote 'productPaths решает, где искать «прогресса нет» и расползание скоупа.'
Write-BcfNote 'generatedFiles — что не блокирует слияние: один лок-файл уже валил семь задач подряд.'

# --- Ручная работа: то, из-за чего прогон встанет ---
$blocking = @()
$later = @()

if (-not $d.Git.IsGit) {
    $blocking += @{ what = 'проект не под git'
                    why  = 'слияния идут через worktree, снапшоты работы — через git-refs. Без репозитория ни то, ни другое невозможно, и потерянную итерацию восстановить будет нечем.'
                    fix  = 'git init && git add -A && git commit -m "initial"' }
} elseif ($d.Git.Dirty.Count) {
    $blocking += @{ what = "$($d.Git.Dirty.Count) файлов не закоммичено"
                    why  = 'первое же слияние затянет эти правки в чужую задачу, и разбираться будешь ты, а не арбитр.'
                    fix  = 'git commit -am "wip"   или   git stash' }
}

foreach ($p in $d.Probes) {
    if ($p.Ok) { continue }
    $blocking += @{ what = "быстрая проверка падает: $($p.Command)"
                    why  = 'она вызывается КАЖДУЮ итерацию — гейт будет красным всегда, и агент начнёт чинить несуществующее.'
                    fix  = "проверь команду руками; последние строки вывода:`n     " + ($p.Output -replace "`n", "`n     ") }
}

if (-not $d.Tests.runner) {
    $later += 'раннер тестов не определился: гейт «фича доказана тестами» не работает — задача может получить PASS без единого нового теста (config/harness.json → tests.runner).'
}
if ($d.Runners.Count -gt 1) {
    $later += "раннеров тестов найдено $($d.Runners.Count) ($((($d.Runners | ForEach-Object { $_.Runner }) -join ', '))), а гейт «фича доказана тестами» одноместный: задачи второго стека будут проверяться чужим раннером. Выбери основной в config/harness.json → tests.runner и закрой второй стек явными командами в config/checks.json."
}
if (-not $d.Typechecks.Count) {
    $later += 'быстрой проверки нет: ошибки компиляции всплывут только на верификации, то есть на несколько итераций позже.'
}

Write-BcfManualActions -Blocking $blocking -Later $later
Write-Host ''
exit 0
