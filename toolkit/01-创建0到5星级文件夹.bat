@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
set "target=%~1"
if "%target%"=="" set "target=%~dp0."
if not exist "%target%\" goto error
for %%i in (0 1 2 3 4 5) do (
    if exist "%target%\%%i\" (
        echo 已存在：%%i
    ) else (
        if exist "%target%\%%i" goto error
        mkdir "%target%\%%i" || goto error
        echo 已创建：%%i
    )
)
echo 完成。
pause
exit /b 0
:error
echo [错误] 无法创建星级文件夹，请检查同名文件或写入权限。
pause
exit /b 1
