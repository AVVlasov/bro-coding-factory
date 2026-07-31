# oc-pretty.ps1 — тонкая обёртка над lib\oc-render.ps1 для verify.ps1.
#
# Читает stdin построчно, делегирует рендер в Render-OcLine. -Color управляет
# Write-Host vs Write-Output. См. oc-render.ps1 для деталей схемы и форматирования.
#
# loop.ps1 этот скрипт НЕ использует — там pipe-buffering opencode/node убивал
# live-feedback. loop.ps1 пишет stdout opencode в файл и парсит сам.

param([switch]$Color)

$ErrorActionPreference = 'Continue'
try {
    # InputEncoding КРИТИЧЕН (фикс 2026-05-25): PS7 на ru-RU Windows дефолтит stdin
    # в cp866 → cyrillic UTF-8 байты (например 0xD0 0xA2 для «Т») декодятся как глифы
    # ╨в. Эти кривые глифы дальше пишутся в файл, и heartbeat-tail показывает mojibake.
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

. (Join-Path $PSScriptRoot 'oc-render.ps1')

while ($null -ne ($line = [Console]::In.ReadLine())) {
    Render-OcLine $line -Color:$Color
}
