@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-tags-to-nef.ps1" -DryRun -RatingFromFolder %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 标签预览检查未通过，请查看上方错误。
pause
exit /b %result%
