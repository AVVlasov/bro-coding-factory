# bcf-context.ps1 — кто такой «корень» для харнесса.
#
# Движок (этот каталог) живёт в фабрике и НЕ копируется в проект. Проект, над которым
# идёт работа, задаётся снаружи: `bcf` выставляет BCF_PROJECT_ROOT перед запуском любого
# скрипта харнесса. Без этой переменной скрипты остаются работоспособными вручную —
# корнем становится верх git-репозитория текущего каталога.
#
# Разделение нужно ровно за тем, чтобы одна установка фабрики обслуживала любое число
# проектов, а состояние прогонов не смешивалось: всё, что харнесс пишет во время работы,
# уходит в <проект>/.bcf/ и целиком принадлежит проекту.

function Get-BcfProjectRoot {
    param([string]$Explicit = '')

    if ($Explicit) {
        $p = (Resolve-Path -LiteralPath $Explicit -ErrorAction SilentlyContinue)
        if ($p) { return $p.Path }
        return $Explicit.TrimEnd('\', '/')
    }
    if ($env:BCF_PROJECT_ROOT) { return $env:BCF_PROJECT_ROOT.TrimEnd('\', '/') }

    $top = ''
    try { $top = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim() } catch { }
    if ($top) { return ($top -replace '/', [IO.Path]::DirectorySeparatorChar) }

    return (Get-Location).Path
}

# Каталог состояния прогонов. Создаётся по требованию: скрипты, которые только читают,
# не должны оставлять после себя пустую папку в чужом проекте.
function Get-BcfStateDir {
    param([string]$Root = '', [switch]$NoCreate)

    if (-not $Root) { $Root = Get-BcfProjectRoot }
    $d = Join-Path $Root '.bcf'
    if (-not $NoCreate) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

# Корень движка (фабрика/harness). Нужен, когда узел графа или планировщик запускает
# другой скрипт харнесса: путь до него не выводится из корня проекта.
function Get-BcfHarnessRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

# Корень установки фабрики (родитель harness/) — там лежат templates/, meta/, memory/.
function Get-BcfHomeRoot {
    if ($env:BCF_HOME) { return $env:BCF_HOME.TrimEnd('\', '/') }
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}
