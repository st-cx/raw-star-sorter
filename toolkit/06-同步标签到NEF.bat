@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
:: 先按当前 JPG 星级归类，再同步同一批照片；保留修改前副本。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sort-by-rating.ps1" -SyncTags %*
set "result=%errorlevel%"
if not "%result%"=="0" echo [错误] 标签同步未全部成功，请查看上方错误和结果 CSV。
pause
exit /b %result%
