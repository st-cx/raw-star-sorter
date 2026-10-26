@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sort-by-rating.ps1" -DryRun -SyncTags %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 标签预览检查未通过，请查看上方错误。
pause
exit /b %result%
