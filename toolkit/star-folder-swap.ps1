#requires -Version 5.1
<#
.SYNOPSIS
    将星级文件夹中的 JPG/JPEG 换成同名 RAW，XMP 跟随 RAW。
.DESCRIPTION
    先建立完整计划再移动。重复星级、同名目标和扩展名错误会在修改前报错；
    缺 RAW 的 JPG 留在原处。预览使用相同计划。每组失败时撤回当前组，
    不生成 __dup 文件。支持从已有 RAW 的星级文件夹继续收回 JPG。
.EXAMPLE
    .\star-folder-swap.ps1 -Path 'D:\照片' -DryRun
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$RawExt = 'nef',
    [string]$PickExt = 'jpg',
    [AllowEmptyString()][string]$SidecarExt = 'xmp',
    [string]$RawSourceDir = 'matched_nef',
    [string]$JpgTargetDir = 'matched_jpg',
    [string[]]$StarFolders = @('0', '1', '2', '3', '4', '5'),
    [switch]$DryRun,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = $PSScriptRoot }
$timer = [Diagnostics.Stopwatch]::StartNew()
function Convert-Extension([string]$Value) {
    $value = $Value.Trim().TrimStart('.').ToLowerInvariant()
    if ($value -notmatch '^[a-z0-9]+$') { throw "无效扩展名：$Value" }
    return $value
}
function Get-ChildDirectory([string]$Value) {
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $Value))
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($candidate -ne $root -and -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "文件夹必须位于照片目录内：$Value"
    }
    if ([IO.File]::Exists($candidate)) { throw "文件夹位置被文件占用：$candidate" }
    return $candidate
}
function Add-IndexedFile($Index, $File) {
    if ($Index.ContainsKey($File.BaseName)) { throw "同名文件无法确定匹配：$($Index[$File.BaseName].FullName)、$($File.FullName)" }
    $Index[$File.BaseName] = $File
}
function Invoke-SwapGroup($Operations) {
    $finished = [Collections.Generic.List[object]]::new()
    try {
        foreach ($operation in $Operations) {
            $directory = [IO.Path]::GetDirectoryName($operation.To)
            if (-not $readyDirectories.ContainsKey($directory)) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                $readyDirectories[$directory] = $true
            }
            [IO.File]::Move($operation.From, $operation.To)
            $finished.Add($operation)
            Write-Verbose ("{0} -> {1}" -f $operation.From, $operation.To)
        }
    }
    catch {
        $originalError = $_
        for ($index = $finished.Count - 1; $index -ge 0; $index--) {
            $operation = $finished[$index]
            try { [IO.File]::Move($operation.To, $operation.From) }
            catch { Write-Warning "撤回失败，请检查：$($operation.To) -> $($operation.From)。$($_.Exception.Message)" }
        }
        throw $originalError
    }
}
$rawExt = Convert-Extension $RawExt
$pickExt = Convert-Extension $PickExt
$sidecarExt = if ($SidecarExt) { Convert-Extension $SidecarExt } else { '' }
$pickExtensions = if ($pickExt -in @('jpg', 'jpeg')) { @('jpg', 'jpeg') } else { @($pickExt) }
if ($rawExt -in $pickExtensions -or ($sidecarExt -and ($sidecarExt -eq $rawExt -or $sidecarExt -in $pickExtensions))) {
    throw 'RAW、JPG 和 XMP 的扩展名必须不同。'
}
$rootItem = Get-Item -LiteralPath $Path
if (-not $rootItem.PSIsContainer -or $rootItem.PSProvider.Name -ne 'FileSystem') { throw "不是文件夹：$Path" }
$root = $rootItem.FullName
$rawSource = Get-ChildDirectory $RawSourceDir
$jpgTarget = Get-ChildDirectory $JpgTargetDir
if ($rawSource -eq $jpgTarget) { throw 'RAW 来源和 JPG 目标文件夹不能相同。' }
if (-not [IO.Directory]::Exists($rawSource)) { throw "未找到 RAW 来源：$rawSource。请先执行匹配分类，或指定 -RawSourceDir。" }
$rawByBase = @{}
$sidecarByBase = @{}
foreach ($file in Get-ChildItem -LiteralPath $rawSource -File) {
    $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
    if ($extension -eq $rawExt) { Add-IndexedFile $rawByBase $file }
    elseif ($sidecarExt -and $extension -eq $sidecarExt) { Add-IndexedFile $sidecarByBase $file }
}
if ($sidecarExt -and $rawSource -ne $root) {
    foreach ($file in Get-ChildItem -LiteralPath $root -File) {
        if ($file.Extension.TrimStart('.') -eq $sidecarExt -and -not $sidecarByBase.ContainsKey($file.BaseName)) {
            $sidecarByBase[$file.BaseName] = $file
        }
    }
}
$picks = [Collections.Generic.List[object]]::new()
$existingTargets = @{}
if ([IO.Directory]::Exists($jpgTarget)) {
    foreach ($file in Get-ChildItem -LiteralPath $jpgTarget -Force) { $existingTargets[$file.FullName] = $true }
}
$pickLocations = @{}
$starNames = @{}
$starRaw = @{}
$foundFolders = 0
foreach ($star in $StarFolders) {
    if (-not $star -or $star -in @('.', '..') -or $star.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "无效星级文件夹名称：$star"
    }
    if ($starNames.ContainsKey($star)) { throw "星级文件夹重复：$star" }
    $starNames[$star] = $true
    $starPath = Get-ChildDirectory $star
    if ($starPath -eq $rawSource -or $starPath -eq $jpgTarget) { throw "星级文件夹不能作为 RAW 来源或 JPG 目标：$star" }
    if (-not [IO.Directory]::Exists($starPath)) { continue }
    $foundFolders++
    $localRaw = @{}
    foreach ($file in Get-ChildItem -LiteralPath $starPath -Force) {
        $existingTargets[$file.FullName] = $true
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        if ($extension -eq $rawExt) { Add-IndexedFile $localRaw $file }
        elseif ($extension -in $pickExtensions) {
            if ($pickLocations.ContainsKey($file.BaseName)) {
                throw "同一照片被放入多个星级或有多个 JPG/JPEG，未移动任何文件：$($pickLocations[$file.BaseName])、$($file.FullName)"
            }
            $pickLocations[$file.BaseName] = $file.FullName
            $picks.Add([pscustomobject]@{ File = $file; StarPath = $starPath })
        }
    }
    $starRaw[$starPath] = $localRaw
}
$groups = [Collections.Generic.List[object]]::new()
$operations = [Collections.Generic.List[object]]::new()
$missing = [Collections.Generic.List[string]]::new()
$conflicts = [Collections.Generic.List[string]]::new()
$reserved = @{}
$sidecarCount = 0
$recovered = 0
function Add-Move($Group, $File, [string]$Directory) {
    $target = [IO.Path]::Combine($Directory, $File.Name)
    if ($existingTargets.ContainsKey($target)) { $conflicts.Add($target) }
    if ($reserved.ContainsKey($target)) { $conflicts.Add($target) }
    $reserved[$target] = $true
    $operation = [pscustomobject]@{ From = $File.FullName; To = $target }
    $Group.Add($operation)
    $operations.Add($operation)
}
foreach ($pick in $picks) {
    $base = $pick.File.BaseName
    $group = [Collections.Generic.List[object]]::new()
    if ($rawByBase.ContainsKey($base)) { Add-Move $group $rawByBase[$base] $pick.StarPath }
    elseif ($starRaw[$pick.StarPath].ContainsKey($base)) { $recovered++ }
    else { $missing.Add($pick.File.FullName); continue }
    if ($sidecarExt -and $sidecarByBase.ContainsKey($base)) {
        Add-Move $group $sidecarByBase[$base] $pick.StarPath
        $sidecarCount++
    }
    # JPG 最后移动；任何一项失败都会撤回这张照片之前完成的移动。
    Add-Move $group $pick.File $jpgTarget
    $groups.Add($group)
}
if ($conflicts.Count) { throw ("存在同名目标，未移动任何文件，也未生成重复名称。请先处理：`n" + ($conflicts -join "`n")) }
Write-Host '星级 JPG/JPEG 替换为 RAW' -ForegroundColor Cyan
Write-Host "目录：$root"
Write-Host "星级文件夹：$foundFolders；选片：$($picks.Count)；可替换：$($groups.Count)；XMP：$sidecarCount；缺 RAW：$($missing.Count)"
foreach ($file in $missing) { Write-Warning "缺少 RAW，JPG 保留原处：$file" }
if ($DryRun) {
    Write-Host '预览模式：不会创建文件夹或修改文件。' -ForegroundColor Magenta
    for ($index = 0; $index -lt $operations.Count; $index++) {
        $operation = $operations[$index]
        if ($index -lt 20) { Write-Host ("  {0} -> {1}" -f $operation.From, $operation.To) }
        else { Write-Verbose ("{0} -> {1}" -f $operation.From, $operation.To) }
    }
    if ($operations.Count -gt 20) { Write-Host '其余项目可加 -Verbose 查看。' }
}
$completed = 0
$readyDirectories = @{}
if (-not $DryRun) {
    try {
        foreach ($group in $groups) {
            Invoke-SwapGroup $group
            $completed++
            if ($completed % 25 -eq 0 -or $completed -eq $groups.Count) {
                Write-Progress -Activity '星级替换' -Status "$completed / $($groups.Count)" -PercentComplete (100 * $completed / $groups.Count)
            }
        }
    }
    finally { Write-Progress -Activity '星级替换' -Completed }
    Write-Host ("已替换 {0} 张；缺 RAW 保留 {1} 张；耗时 {2:N2} 秒。" -f $completed, $missing.Count, $timer.Elapsed.TotalSeconds) -ForegroundColor Green
}
if ($PassThru) {
    [pscustomobject]@{
        StarFoldersFound = $foundFolders; PickFilesSeen = $picks.Count; Planned = $groups.Count
        SwapsDone = $completed; Sidecars = $sidecarCount; RawMissing = $missing.Count
        Recovered = $recovered; DryRun = [bool]$DryRun; ElapsedSeconds = $timer.Elapsed.TotalSeconds
    }
}
