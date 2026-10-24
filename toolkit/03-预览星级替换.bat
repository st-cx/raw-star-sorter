@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sort-by-rating.ps1" -DryRun %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 预览检查未通过，请先处理上方问题。
pause
exit /b %result%
