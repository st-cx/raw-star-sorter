@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%