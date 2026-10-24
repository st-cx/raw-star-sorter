@echo off
chcp 65001 >nul
setlocal DisableDelayedExpansion
set "photoPath=%~1"
if "%photoPath%"=="" set "photoPath=%~dp0."
for %%i in ("%photoPath%") do set "photoPath=%%~fi"
if not exist "%photoPath%\" (
    echo [错误] 照片目录不存在："%photoPath%"
    pause
    exit /b 1
)
:menu
cls
echo ============================================
echo                 照片选片工具
echo ============================================
echo 照片目录："%photoPath%"
echo.
echo 1. 创建 0-5 星级文件夹（可选，归类时会自动创建）
echo 2. 匹配分类 NEF 和 JPG/JPEG
echo 3. 预览按 JPG 星级自动归类
echo 4. 按 JPG 星级自动归类 NEF/XMP
echo 5. 预览标签同步
echo 6. 执行标签同步（星级按文件夹）
echo 0. 退出
echo.
echo 选片时在 matched_jpg 中打星并保存，无需手动移动 JPG。
echo.
choice /c 0123456 /n /m "请选择 0-6："
if errorlevel 255 exit /b 1
if errorlevel 7 goto sync
if errorlevel 6 goto previewSync
if errorlevel 5 goto swap
if errorlevel 4 goto previewSwap
if errorlevel 3 goto sort
if errorlevel 2 goto create
exit /b 0
:create
call "%~dp001-创建0到5星级文件夹.bat" "%photoPath%"
goto menu
:sort
call "%~dp002-NEF与JPG匹配分类.bat" -Path "%photoPath%"
goto menu
:previewSwap
call "%~dp003-预览星级替换.bat" -Path "%photoPath%"
goto menu
:swap
call "%~dp004-执行星级替换.bat" -Path "%photoPath%"
goto menu
:previewSync
call "%~dp005-预览标签同步.bat" -Path "%photoPath%"
goto menu
:sync
call "%~dp006-同步标签到NEF.bat" -Path "%photoPath%"
goto menu
