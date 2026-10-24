@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
:: 可改为 -Copy / -DryRun / -IncludeUnmatchedRef，或从命令行传入参数。
set "OPTIONS="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0photo-sort.ps1" %OPTIONS% %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 分类未全部完成，请查看上方错误。脚本不会覆盖不同内容的同名文件。
pause
exit /b %result%
