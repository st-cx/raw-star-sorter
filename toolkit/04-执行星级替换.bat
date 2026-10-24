@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sort-by-rating.ps1" %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 自动归类未全部完成，请查看上方错误。当前照片组已尝试撤回，可修复后重跑。
pause
exit /b %result%
