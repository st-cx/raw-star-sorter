@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
:: 双击时以 0-5 文件夹作为星级来源，其他标签来自 JPG/JPEG。
set "OPTIONS=-RatingFromFolder"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-tags-to-nef.ps1" %OPTIONS% %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 标签同步未全部成功，请查看上方错误和结果 CSV。
pause
exit /b %result%
