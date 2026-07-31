# paths.ps1 — где что лежит с точки зрения CLI.
#
# Две системы координат, и путать их дорого:
#   ФАБРИКА (BCF_HOME)  — движок, шаблоны, мета-слой, память. Одна на машину.
#   ПРОЕКТ  (--project) — код, config/, tasks/, .claude/ и .bcf/ с состоянием прогонов.
#
# Всё, что фабрика знает о проекте, лежит в самом проекте. Единственное, что она держит
# у себя, — реестр (какие проекты вообще заведены) и мета-история аудита.

$script:BcfHome = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-BcfHome { return $script:BcfHome }
function Get-BcfHarness { return (Join-Path $script:BcfHome 'harness') }
function Get-BcfTemplates { return (Join-Path $script:BcfHome 'templates') }
function Get-BcfMeta { return (Join-Path $script:BcfHome 'meta') }
function Get-BcfMemoryDir { return (Join-Path $script:BcfHome 'memory') }

function Get-BcfVersion {
    $f = Join-Path $script:BcfHome 'VERSION'
    if (Test-Path $f) { return (Get-Content -Raw -LiteralPath $f).Trim() }
    return '0.0.0-dev'
}

# Корень проекта, над которым идёт работа. Порядок намеренный: явный флаг сильнее
# переменной окружения, переменная сильнее «где я стою» — иначе `bcf` в подкаталоге
# начинал бы настраивать подкаталог.
function Resolve-BcfProject {
    param([string]$Path = '')

    $cand = if ($Path) { $Path } elseif ($env:BCF_PROJECT_ROOT) { $env:BCF_PROJECT_ROOT } else { (Get-Location).Path }
    $rp = Resolve-Path -LiteralPath $cand -ErrorAction SilentlyContinue
    if (-not $rp) { throw "Каталог не найден: $cand" }
    $full = $rp.Path

    if (-not $Path -and -not $env:BCF_PROJECT_ROOT) {
        # Только для неявного случая: подняться до верха репозитория. Явно указанный
        # путь не переопределяем — человек мог намеренно указать подпроект монорепы.
        $top = ''
        try { $top = (& git -C $full rev-parse --show-toplevel 2>$null | Out-String).Trim() } catch { }
        if ($top) { $full = ($top -replace '/', [IO.Path]::DirectorySeparatorChar) }
    }
    return $full
}

function Get-BcfProjectState {
    param([Parameter(Mandatory)][string]$Project, [switch]$NoCreate)
    $d = Join-Path $Project '.bcf'
    if (-not $NoCreate) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

# Проект считается настроенным, когда у него есть .bcf/project.json — карточка,
# которую пишет `bcf init`. Отсутствие конфига и отсутствие карточки — разные вещи:
# первое чинится правкой файла, второе означает, что init вообще не проходил.
function Get-BcfProjectCard {
    param([Parameter(Mandatory)][string]$Project)
    $f = Join-Path $Project '.bcf\project.json'
    if (-not (Test-Path $f)) { return $null }
    try { return Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch { return $null }
}

function Save-BcfProjectCard {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)]$Card)
    $d = Get-BcfProjectState -Project $Project
    ($Card | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $d 'project.json') -Encoding UTF8
}

function Get-BcfHarnessConfig {
    param([Parameter(Mandatory)][string]$Project)
    $f = Join-Path $Project 'config\harness.json'
    if (-not (Test-Path $f)) { return $null }
    try { return Get-Content -Raw -LiteralPath $f | ConvertFrom-Json }
    catch { throw "config/harness.json не разобран: $($_.Exception.Message)" }
}
