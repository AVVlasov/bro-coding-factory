# bcf setup — сделать так, чтобы команда называлась `bcf`.
#
#   bcf setup           добавить bin/ в PATH пользователя
#   bcf setup --check   только проверить, ничего не менять
#   bcf setup --remove  убрать из PATH
#
# ЗАЧЕМ ОТДЕЛЬНАЯ КОМАНДА. `pwsh D:\...\bin\bcf.ps1 detect --project D:\...` — это не
# работа с CLI, это вызов скрипта: путь набирается руками, каталог проекта повторяется в
# каждой команде, и любая инструкция превращается в две строки вместо одной. Инструмент,
# который зовут так, не используют — про него забывают.
#
# После setup правильная форма такая:
#     cd D:\projects\my-app
#     bcf                 карточка состояния и выбор запуска
#     bcf run queue       без --project: проект берётся из текущего каталога

$check  = $script:BcfArgs -contains '--check'
$remove = $script:BcfArgs -contains '--remove'
$binDir = Join-Path (Get-BcfHome) 'bin'

Write-BcfTitle 'КОМАНДА bcf' $binDir

function Test-OnPath {
    $cmd = Get-Command bcf -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    return $cmd.Source
}

$found = Test-OnPath
if ($found) {
    $same = $found -like (Join-Path $binDir '*')
    if ($same) { Write-BcfOk "уже работает: $found" }
    else {
        Write-BcfWarn "команда bcf уже есть, но ДРУГАЯ: $found"
        Write-BcfNote 'две разные фабрики на одном PATH — источник расхождений, которые видны только по итогу прогона.'
    }
} else {
    Write-BcfDim 'команда bcf на PATH не найдена'
}

if ($check) {
    Write-Host ''
    exit $(if ($found) { 0 } else { 1 })
}

if ($IsWindows -eq $false) {
    # На Linux/macOS PATH правится профилем оболочки, а какой именно у человека — мы не
    # знаем. Менять чужой .bashrc без спроса нельзя: это его файл, а не наш.
    Write-Host ''
    Write-BcfLine '  добавь в свой профиль оболочки одну строку:' 'White'
    Write-Host ''
    Write-BcfLine "    export PATH=`"$binDir`":`$PATH" 'Cyan'
    Write-Host ''
    Write-BcfNote 'и сделай обёртку исполняемой: chmod +x ' + (Join-Path $binDir 'bcf')
    Write-Host ''
    exit 0
}

# --- Windows: PATH пользователя ---------------------------------------------------------
#
# Пишем в HKCU (переменную пользователя), а не в системную: правка системного PATH
# требует прав администратора и трогает всех, кому эта фабрика не нужна.
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_ })

if ($remove) {
    $kept = @($parts | Where-Object { $_.TrimEnd('\') -ne $binDir.TrimEnd('\') })
    if ($kept.Count -eq $parts.Count) {
        Write-BcfDim 'в PATH пользователя этого каталога и не было — убирать нечего'
        Write-Host ''
        exit 0
    }
    [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
    Write-BcfOk 'убрано из PATH пользователя'
    Write-BcfNote 'уже открытые окна сохраняют старый PATH — Windows не обновляет переменные в запущенных процессах.'
    Write-Host ''
    exit 0
}

if ($parts | Where-Object { $_.TrimEnd('\') -eq $binDir.TrimEnd('\') }) {
    Write-BcfOk 'каталог уже в PATH пользователя'
} else {
    [Environment]::SetEnvironmentVariable('PATH', (@($parts + $binDir) -join ';'), 'User')
    Write-BcfOk "добавлено в PATH пользователя: $binDir"
}

# То же самое в текущем процессе — иначе проверка ниже честно скажет «не работает»,
# хотя в новом окне уже всё хорошо, и человек решит, что setup не сработал.
if ($env:PATH -notlike "*$binDir*") { $env:PATH = "$env:PATH;$binDir" }

Write-Host ''
Write-BcfLine '  ПРОВЕРКА' 'White'
$now = Test-OnPath
if ($now) { Write-BcfOk "bcf → $now" }
else {
    Write-BcfWarn 'в ЭТОМ окне команда ещё не видна'
    Write-BcfNote 'Windows не обновляет переменные в уже запущенных процессах — открой новое окно.'
}

# --- Автодополнение ---------------------------------------------------------------------
#
# Не украшение: команд уже под двадцать, и половина имеет подкоманды. Инструмент, в
# котором надо помнить точное написание, используют на треть возможностей — остальное
# просто не вспоминают. Дополнение ставится в профиль пользователя, потому что жить оно
# должно между сессиями.
$completer = @'

# --- bcf: автодополнение (добавлено `bcf setup`) ---
Register-ArgumentCompleter -Native -CommandName bcf -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $cmds = @('setup','update','init','install','migrate','doctor','detect','tasks','task',
              'run','stop','watch','runs','board','report','cost','memory','research','prd','meta','help','version')
    $subs = @{
        run    = @('loop','night','queue','review')
        task   = @('new','why','show')
        memory = @('status','init','ask','stats','down')
        meta   = @('list','register','audit','wiki','log')
    }
    $tokens = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.ToString() } |
                Where-Object { $_ -notlike '-*' })
    if ($tokens.Count -ge 1 -and $subs.ContainsKey($tokens[0]) -and
        ($tokens.Count -eq 1 -or ($tokens.Count -eq 2 -and $wordToComplete))) {
        return $subs[$tokens[0]] | Where-Object { $_ -like "$wordToComplete*" } |
               ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
    if ($tokens.Count -eq 0 -or ($tokens.Count -eq 1 -and $wordToComplete)) {
        return $cmds | Where-Object { $_ -like "$wordToComplete*" } |
               ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
}
# --- /bcf ---
'@

$profilePath = $PROFILE.CurrentUserAllHosts
$marker = '# --- bcf: автодополнение'
$has = (Test-Path $profilePath) -and ((Get-Content -Raw -LiteralPath $profilePath) -match [regex]::Escape($marker))
if ($has) {
    Write-BcfOk 'автодополнение уже в профиле'
} else {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $profilePath -Parent) | Out-Null
        Add-Content -LiteralPath $profilePath -Value $completer -Encoding UTF8
        Write-BcfOk "автодополнение добавлено в профиль: $profilePath"
        Write-BcfNote 'заработает в новых окнах — профиль читается при старте оболочки.'
    } catch {
        Write-BcfWarn "не удалось дописать профиль: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-BcfLine '  ДАЛЬШЕ' 'White'
Write-Host '    cd <путь к проекту>'
Write-Host '    bcf                 карточка состояния и выбор запуска'
Write-Host '    bcf run queue       без --project: проект берётся из текущего каталога'
Write-Host ''
exit 0
