# install.ps1 — установка зависимостей harness/memory/
# Запускать один раз перед первым использованием. Идемпотентно.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

Write-Host "=== harness/memory install ===" -ForegroundColor Cyan

# 1. Python + pip
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { throw "Python не найден в PATH. Установи Python 3.10+." }
Write-Host "[ok] $(python --version)" -ForegroundColor Green

# 2. pip dependencies
Write-Host "[install] pip install -r requirements.txt"
python -m pip install --upgrade pip
python -m pip install -r (Join-Path $here 'requirements.txt')

# 3. Smoke test sqlite-vec
Write-Host "[check] sqlite-vec import + extension load"
python -c "import sqlite3, sqlite_vec; c=sqlite3.connect(':memory:'); c.enable_load_extension(True); sqlite_vec.load(c); print('sqlite-vec OK, version:', c.execute('select vec_version()').fetchone()[0])"

# 4. Init memory.db (применить schema)
$db = Join-Path $here 'memory.db'
Write-Host "[init] $db"
Push-Location $here
try {
    python memory.py init --db $db --project default
} finally {
    Pop-Location
}

# 5. Проверка embedding endpoint (OpenAI-compat: LM Studio / Ollama / др.)
$embedUrl   = if ($env:MEMORY_EMBED_URL)   { $env:MEMORY_EMBED_URL }   else { 'http://localhost:1234/v1/embeddings' }
$embedModel = if ($env:MEMORY_EMBED_MODEL) { $env:MEMORY_EMBED_MODEL } else { 'text-embedding-nomic-embed-text-v1.5' }
$embedDim   = if ($env:MEMORY_EMBED_DIM)   { [int]$env:MEMORY_EMBED_DIM } else { 768 }
Write-Host "[check] embedding endpoint $embedUrl (model: $embedModel)"
try {
    $body = @{ model = $embedModel; input = 'smoke-test' } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Method Post -Uri $embedUrl -ContentType 'application/json' -Body $body -TimeoutSec 10
    $dim = $resp.data[0].embedding.Count
    Write-Host "[ok] embedding dim=$dim" -ForegroundColor Green
    if ($dim -ne $embedDim) {
        Write-Warning "Размерность $dim != $embedDim (ожидаемо для nomic-embed-text-v1.5)."
        Write-Warning "Установи переменную окружения: `$env:MEMORY_EMBED_DIM = '$dim'"
    }
} catch {
    Write-Warning "Embedding endpoint недоступен: $($_.Exception.Message)"
    Write-Warning "Запусти OpenAI-compat сервер (LM Studio/Ollama/llama.cpp), загрузи embedding-модель (768d)."
    Write-Warning "Memory будет работать, но без embeddings (ask/memorize не функционируют)."
}

Write-Host ""
Write-Host "=== install complete ===" -ForegroundColor Cyan
Write-Host "Дальше:" -ForegroundColor Cyan
Write-Host "  python memorize.py --kind decision --title '<...>' --body '<...>'"
Write-Host "  python ask.py 'similar boundary issue'"
Write-Host "  python ingest-events.py        # инжест verdict-файлов и events"
Write-Host "  python daily-summary.py        # вечерний summary"
Write-Host "  python weekly-retro.py         # воскресный retro"
