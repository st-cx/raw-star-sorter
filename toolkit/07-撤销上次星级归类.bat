@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0undo-last-sort.ps1" %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 撤销未完成，请查看上方原因。
pause
exit /b %result%
