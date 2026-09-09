# tiers.ps1 — ярусы задач: какая модель делает задачу и какая судит, по строке `Ярус:` в шапке.
#
# Постановка владельца 2026-09-09: «сложные задачи на opus, средней сложности на sonnet,
# лёгкие на qwen; судит результат opus по задаче fable, sonnet судит opus, qwen судит sonnet».
# Конфиг в config/harness.json:
#
#   "tiers": {
#     "default": "средняя",
#     "лёгкая":  { "worker": { "backend": "opencode", "model": "lmstudio/qwen/qwen3.8-27b" },
#                  "judge":  { "backend": "claude",   "model": "sonnet" }, "profile": "local" },
#     "средняя": { "worker": { "backend": "claude", "model": "sonnet" },
#                  "judge":  { "backend": "claude", "model": "opus" } },
#     "сложная": { "worker": { "backend": "claude", "model": "opus" },
#                  "judge":  { "backend": "meta",   "model": "fable" } }
#   }
#
# Бэкенд `meta` у судьи значит: судит не фабрика, а мета-слой снаружи (модель, которой нет
# в CLI: claude 2.1.220 отвечает на fable «does not support this model»). verify.ps1 ставит
# вердикт по гейтам и пишет в notes, что судья внешний; мета-слой дописывает своё решение.
# Команды бэкендов берутся из graph.backends, как у графа, вместе с их переменными окружения.

function Get-BcfTaskTier {
    param([Parameter(Mandatory)][string]$TaskFile, $Cfg = $null)
    $tier = ''
    if (Test-Path -LiteralPath $TaskFile) {
        $body = Get-Content -Raw -LiteralPath $TaskFile
        $head = ($body -split '(?m)^##\s', 2)[0]
        $m = [regex]::Match($head, '(?im)^Ярус:\s*(\S+)')
        if ($m.Success) { $tier = $m.Groups[1].Value.Trim().ToLower() }
    }
    if (-not $tier -and $Cfg -and $Cfg.PSObject.Properties['tiers'] -and $Cfg.tiers -and $Cfg.tiers.PSObject.Properties['default']) {
        $tier = [string]$Cfg.tiers.default
    }
    return $tier
}

function Resolve-BcfTier {
    param([Parameter(Mandatory)]$Cfg, [string]$Tier)
    if (-not $Tier -or -not $Cfg -or -not $Cfg.PSObject.Properties['tiers'] -or -not $Cfg.tiers) { return $null }
    $p = $Cfg.tiers.PSObject.Properties[$Tier]
    if (-not $p -or -not $p.Value) { return $null }
    $t = $p.Value
    $out = [ordered]@{ Tier = $Tier; Worker = $null; Judge = $null; Profile = '' }
    if ($t.PSObject.Properties['worker'] -and $t.worker -and $t.worker.backend) {
        $out.Worker = @{ Backend = [string]$t.worker.backend; Model = [string]$t.worker.model }
    }
    if ($t.PSObject.Properties['judge'] -and $t.judge -and $t.judge.backend) {
        $out.Judge = @{ Backend = [string]$t.judge.backend; Model = [string]$t.judge.model }
    }
    if ($t.PSObject.Properties['profile'] -and $t.profile) { $out.Profile = [string]$t.profile }
    return [pscustomobject]$out
}

# Слоты яруса: сколько задач яруса идут одновременно (tiers.<ярус>.concurrency). Слот это
# файл <pid>.slot в каталоге установки фабрики (общий для всех worktree проекта), живость
# по pid; без лимита в конфиге слот не нужен. Постановка владельца 2026-09-09: «у opus
# пять параллельных запусков», при одной qwen и одном GPU.
function Get-BcfTierSlotDir {
    param([Parameter(Mandatory)][string]$Tier)
    $base = if ($env:BCF_FLEET_DIR) { $env:BCF_FLEET_DIR.TrimEnd('\', '/') } else { Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.bcf\fleet' }
    $safe = ($Tier -replace '[^\p{L}\p{Nd}_-]', '_')
    return (Join-Path $base "tiers\$safe")
}

function Get-BcfTierLimit {
    param($Cfg, [string]$Tier)
    if (-not $Tier -or -not $Cfg -or -not $Cfg.PSObject.Properties['tiers'] -or -not $Cfg.tiers) { return 0 }
    $p = $Cfg.tiers.PSObject.Properties[$Tier]
    if (-not $p -or -not $p.Value -or -not $p.Value.PSObject.Properties['concurrency']) { return 0 }
    return [int]$p.Value.concurrency
}

function Get-BcfTierSlotsAlive {
    param([Parameter(Mandatory)][string]$Tier)
    $dir = Get-BcfTierSlotDir -Tier $Tier
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $alive = @()
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.slot' -File -ErrorAction SilentlyContinue) {
        $pid_ = 0
        if ($f.BaseName -match '^\d+$') { $pid_ = [int]$f.BaseName }
        $ok = $false
        if ($pid_ -gt 0) { try { $null = Get-Process -Id $pid_ -ErrorAction Stop; $ok = $true } catch { $ok = $false } }
        if ($ok) { $alive += $f.FullName } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $alive
}

# Ждёт свободный слот яруса и занимает его файлом с pid. Возвращает путь файла слота или ''
# (лимита нет). $OnWait зовётся раз в $LogEverySec с текстом ожидания.
function Enter-BcfTierSlot {
    param([Parameter(Mandatory)][string]$Tier, [int]$Limit, [int]$OwnerPid = $PID, [int]$MaxWaitSec = 43200, [int]$LogEverySec = 60, [scriptblock]$OnWait = $null)
    if ($Limit -le 0) { return '' }
    $dir = Get-BcfTierSlotDir -Tier $Tier
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $mine = Join-Path $dir "$OwnerPid.slot"
    $waited = 0; $nextLog = 0
    while ($true) {
        $alive = @(Get-BcfTierSlotsAlive -Tier $Tier)
        if ($alive -contains $mine) { return $mine }
        if ($alive.Count -lt $Limit) {
            Set-Content -LiteralPath $mine -Value "$OwnerPid $(Get-Date -Format o)" -Encoding UTF8
            # Гонка двух стартов: перечитываем и уступаем, если нас стало больше лимита и мы младше.
            $after = @(Get-BcfTierSlotsAlive -Tier $Tier | Sort-Object { (Get-Item $_).CreationTimeUtc })
            if ($after.Count -le $Limit -or ($after | Select-Object -First $Limit) -contains $mine) { return $mine }
            Remove-Item -LiteralPath $mine -Force -ErrorAction SilentlyContinue
        }
        if ($waited -ge $MaxWaitSec) { return '' }
        if ($OnWait -and $waited -ge $nextLog) { & $OnWait "ярус «$Tier»: занято $($alive.Count) из $Limit, жду слот ($waited с)"; $nextLog = $waited + $LogEverySec }
        Start-Sleep -Seconds 10
        $waited += 10
    }
}

function Exit-BcfTierSlot {
    param([string]$SlotFile)
    if ($SlotFile -and (Test-Path -LiteralPath $SlotFile)) { Remove-Item -LiteralPath $SlotFile -Force -ErrorAction SilentlyContinue }
}

# Команда бэкенда и его переменные окружения, как их собирает граф (graph-runtime.ps1):
# значение берётся из процесса, затем из User и Machine, потому что CLAUDE_CODE_OAUTH_TOKEN
# лежит в пользовательском окружении и в дочерний pwsh сам не приходит.
function Get-BcfBackendInvocation {
    param([Parameter(Mandatory)]$Cfg, [Parameter(Mandatory)][string]$Backend)
    $b = $null
    if ($Cfg.PSObject.Properties['graph'] -and $Cfg.graph -and $Cfg.graph.PSObject.Properties['backends']) {
        $bp = $Cfg.graph.backends.PSObject.Properties[$Backend]
        if ($bp) { $b = $bp.Value }
    }
    if (-not $b -or -not $b.command) {
        if ($Backend -eq 'opencode') {
            return [pscustomobject]@{ Backend = 'opencode'; Command = 'opencode run --dangerously-skip-permissions --thinking --format json --model {model}'; Format = 'opencode'; EnvPrefix = '' }
        }
        if ($Backend -eq 'claude') {
            $b = [pscustomobject]@{ command = 'claude -p --output-format stream-json --verbose --permission-mode acceptEdits --model {model}'; format = 'claude'; env = @('CLAUDE_CODE_OAUTH_TOKEN') }
        } else { return $null }
    }
    $envs = ''
    foreach ($name in @($b.env)) {
        if (-not $name) { continue }
        $val = [Environment]::GetEnvironmentVariable($name)
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($name, 'User') }
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($name, 'Machine') }
        if ($val) { $envs += "`$env:$name='$($val -replace "'", "''")';" }
    }
    $fmt = if ($b.PSObject.Properties['format'] -and $b.format) { [string]$b.format } else { $Backend }
    return [pscustomobject]@{ Backend = $Backend; Command = [string]$b.command; Format = $fmt; EnvPrefix = $envs }
}
