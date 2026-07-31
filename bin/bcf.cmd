@echo off
rem bcf.cmd — обёртка для cmd.exe/PowerShell 5. Движок требует pwsh 7: Windows PowerShell
rem не понимает часть используемого синтаксиса, и падение было бы невнятным.
where pwsh >nul 2>&1
if errorlevel 1 (
  echo bcf: нужен PowerShell 7 ^(pwsh^). Установка: winget install Microsoft.PowerShell
  exit /b 127
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0bcf.ps1" %*
