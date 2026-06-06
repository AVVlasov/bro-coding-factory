# venv-python.ps1 — определить путь к Python из локального venv рядом со скриптами.
# Используется как dot-source: `. ./venv-python.ps1`.
#
# Venv ожидается в каталоге .venv рядом с этими скриптами ($PSScriptRoot/.venv).
# Поддерживаются Windows (Scripts/python.exe) и Linux/macOS (bin/python).
# Если venv отсутствует — fallback на системный python (с warning).

function Get-HarnessPython {
    $venvWin  = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
    $venvNix  = Join-Path $PSScriptRoot '.venv/bin/python'
    foreach ($cand in @($venvWin, $venvNix)) {
        if (Test-Path $cand) { return $cand }
    }
    $sysPython = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $sysPython) {
        $sysPython = (Get-Command python3 -ErrorAction SilentlyContinue).Source
    }
    if ($sysPython) {
        Write-Warning "Venv не найден в $PSScriptRoot/.venv; используется системный $sysPython"
        return $sysPython
    }
    throw "Ни venv, ни системный python не найдены. Запусти install.ps1."
}

# Экспортируем переменную $HARNESS_PYTHON для удобного использования в скриптах
$Global:HARNESS_PYTHON = Get-HarnessPython
