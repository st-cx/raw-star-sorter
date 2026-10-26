#requires -Version 5.1
[CmdletBinding()]
param([string]$Path = '', [string]$ExifToolPath = '')
$ErrorActionPreference = 'Stop'
function Select-PhotoFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择照片批次根目录（包含 matched_jpg 和 RAW 的目录）'
    try { if ($dialog.ShowDialog() -eq 'OK') { return $dialog.SelectedPath } }
    finally { $dialog.Dispose() }
    return ''
}
function Confirm-Action([string]$Message) { return (Read-Host "$Message 输入 Y 执行，回车取消") -match '^(y|yes|是)$' }
if (-not $Path) { $Path = Select-PhotoFolder }
if (-not $Path) { return }
$Path = (Get-Item -LiteralPath $Path.Trim('"')).FullName
if (-not [IO.Directory]::Exists($Path)) { throw '请选择照片文件夹。' }
$unratedAction = 'Skip'
while ($true) {
    Write-Host "`nRAW Star Sorter v1.1 · 照片：$Path" -ForegroundColor Cyan
    Write-Host "未保存星级：$(if ($unratedAction -eq 'Skip') { '跳过（推荐）' } else { '归入 0 星' })；明确 0 星始终归入 0"
    Write-Host @'
1  首次匹配 RAW / JPG（先预览）
2  查看星级归类预览
3  按星级归类 RAW / XMP（先预览）
4  归类并同步标签（保留旧标签和修改前副本）
5  导出完整归类清单 CSV
6  撤销上次星级归类（先预览）
7  复制精选照片到新文件夹
8  切换未评分处理方式
9  更换照片目录
0  退出
'@
    $choice = Read-Host '请选择'
    if ($choice -eq '0') { return }
    $options = @{ Path = $Path; ExifToolPath = $ExifToolPath; UnratedAction = $unratedAction }
    try {
        switch ($choice) {
            '1' {
                & (Join-Path $PSScriptRoot 'photo-sort.ps1') -Path $Path -DryRun
                if (Confirm-Action '将首次匹配分类，撤销功能仅针对后续星级归类。') {
                    & (Join-Path $PSScriptRoot 'photo-sort.ps1') -Path $Path -NoConfirm
                }
            }
            '2' { & (Join-Path $PSScriptRoot 'sort-by-rating.ps1') @options -DryRun }
            { $_ -in '3', '4' } {
                & (Join-Path $PSScriptRoot 'sort-by-rating.ps1') @options -DryRun
                if ($choice -eq '4') { Write-Host '同时把 JPG 星级/标签写入 RAW 和已有 XMP；_original 副本保留，撤销只还原文件位置。' }
                if (Confirm-Action '按当前 JPG 星级整理。') {
                    & (Join-Path $PSScriptRoot 'sort-by-rating.ps1') @options -SyncTags:($choice -eq '4')
                }
            }
            '5' {
                $report = Join-Path $Path ('星级归类清单-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.csv')
                & (Join-Path $PSScriptRoot 'sort-by-rating.ps1') @options -DryRun -ReportPath $report
            }
            '6' {
                & (Join-Path $PSScriptRoot 'undo-last-sort.ps1') -Path $Path -DryRun
                if (Confirm-Action '撤销上次星级归类。') { & (Join-Path $PSScriptRoot 'undo-last-sort.ps1') -Path $Path }
            }
            '7' {
                $minimum = Read-Host '最低星级 0-5（回车为 4）'
                if (-not $minimum) { $minimum = '4' }
                if ($minimum -notmatch '^[0-5]$') { throw '请输入 0-5。' }
                $format = Read-Host '复制格式 J=JPG、R=RAW+XMP、B=两者（回车为 B）'
                $formatName = switch ($format.ToUpperInvariant()) { 'J' { 'Jpg' }; 'R' { 'Raw' }; '' { 'Both' }; 'B' { 'Both' }; default { throw '请输入 J、R 或 B。' } }
                $destination = (Read-Host '输入新的导出文件夹完整路径').Trim('"')
                $exportOptions = @{ Path = $Path; ExifToolPath = $ExifToolPath; Destination = $destination; MinRating = [int]$minimum; Format = $formatName }
                & (Join-Path $PSScriptRoot 'export-selected.ps1') @exportOptions -DryRun
                if (Confirm-Action '复制精选照片。') { & (Join-Path $PSScriptRoot 'export-selected.ps1') @exportOptions }
            }
            '8' { $unratedAction = if ($unratedAction -eq 'Skip') { 'Zero' } else { 'Skip' } }
            '9' { $selected = Select-PhotoFolder; if ($selected) { $Path = $selected } }
            default { Write-Host '请输入 0-9。' }
        }
    }
    catch { Write-Host "操作未完成：$($_.Exception.Message)" -ForegroundColor Red }
}
