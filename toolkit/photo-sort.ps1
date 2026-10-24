#requires -Version 5.1
<#
.SYNOPSIS
    按同名 RAW/JPG 匹配分类，XMP 跟随 RAW。
.DESCRIPTION
    单次扫描建立索引；JPG 同时识别 .jpg/.jpeg。先检查全部目标，禁止覆盖
    不同内容的同名文件。每张照片的 RAW、JPG、XMP 作为一组执行，失败时
    撤回当前组。重复复制时跳过内容完全相同的文件。
.EXAMPLE
    .\photo-sort.ps1 -Path 'D:\照片' -DryRun
.EXAMPLE
    .\photo-sort.ps1 arw jpg -Copy -NoConfirm
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$SourceExt = 'nef',
    [Parameter(Position = 1)][string]$RefExt = 'jpg',
    [Parameter(Position = 2)][AllowEmptyString()][string]$SidecarExt = 'xmp',
    [string]$Path = '.',
    [switch]$Copy,
    [switch]$DryRun,
    [switch]$IncludeUnmatchedRef,
    [switch]$NoConfirm,
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
function Invoke-TransferGroup($Operations) {
    $finished = [Collections.Generic.List[object]]::new()
    try {
        foreach ($operation in $Operations) {
            if ($operation.Existing) { continue }
            $directory = [IO.Path]::GetDirectoryName($operation.To)
            if (-not $readyDirectories.ContainsKey($directory)) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                $readyDirectories[$directory] = $true
            }
            if ($Copy) { [IO.File]::Copy($operation.From, $operation.To, $false) }
            else { [IO.File]::Move($operation.From, $operation.To) }
            $finished.Add($operation)
            Write-Verbose ("{0} -> {1}" -f $operation.From, $operation.To)
        }
    }
    catch {
        $originalError = $_
        for ($index = $finished.Count - 1; $index -ge 0; $index--) {
            $operation = $finished[$index]
            try {
                if ($Copy) { [IO.File]::Delete($operation.To) }
                else { [IO.File]::Move($operation.To, $operation.From) }
            }
            catch { Write-Warning "撤回失败，请检查：$($operation.To) -> $($operation.From)。$($_.Exception.Message)" }
        }
        throw $originalError
    }
}
$sourceExt = Convert-Extension $SourceExt
$refExt = Convert-Extension $RefExt
$sidecarExt = if ($SidecarExt) { Convert-Extension $SidecarExt } else { '' }
$refExtensions = if ($refExt -in @('jpg', 'jpeg')) { @('jpg', 'jpeg') } else { @($refExt) }
if ($sourceExt -in $refExtensions -or ($sidecarExt -and ($sidecarExt -eq $sourceExt -or $sidecarExt -in $refExtensions))) {
    throw 'RAW、JPG 和 XMP 的扩展名必须不同。'
}
$rootItem = Get-Item -LiteralPath $Path
if (-not $rootItem.PSIsContainer -or $rootItem.PSProvider.Name -ne 'FileSystem') { throw "不是文件夹：$Path" }
$root = $rootItem.FullName
$matchedRaw = Join-Path $root "matched_$sourceExt"
$matchedJpg = Join-Path $root "matched_$refExt"
$unmatchedRaw = Join-Path $root "unmatched_$sourceExt"
$unmatchedJpg = Join-Path $root "unmatched_$refExt"
$sources = @{}
$references = @{}
$sidecars = @{}
foreach ($file in Get-ChildItem -LiteralPath $root -File) {
    $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
    $fileIndex = if ($extension -eq $sourceExt) { $sources }
        elseif ($extension -in $refExtensions) { $references }
        elseif ($sidecarExt -and $extension -eq $sidecarExt) { $sidecars }
        else { continue }
    if ($fileIndex.ContainsKey($file.BaseName)) {
        throw "同一照片有多个同类文件，无法确定匹配：$($fileIndex[$file.BaseName].Name)、$($file.Name)"
    }
    $fileIndex[$file.BaseName] = $file
}
# 识别已分类的文件，以便从中断或分步执行中继续。
$existingMatchedRaw = @{}
$existingUnmatchedRaw = @{}
$existingMatchedJpg = @{}
$existingTargets = @{}
$targetDirectories = @($matchedRaw, $unmatchedRaw, $matchedJpg)
if ($IncludeUnmatchedRef) { $targetDirectories += $unmatchedJpg }
foreach ($directory in $targetDirectories) {
    if ([IO.File]::Exists($directory)) { throw "目标位置是文件，不能创建文件夹：$directory" }
    if (-not [IO.Directory]::Exists($directory)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Force) {
        $existingTargets[$file.FullName] = $file
        if ($file.PSIsContainer) { continue }
        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        if ($directory -eq $matchedJpg -and $extension -in $refExtensions) { $existingMatchedJpg[$file.BaseName] = $true }
        elseif ($extension -eq $sourceExt) {
            if ($directory -eq $matchedRaw) { $existingMatchedRaw[$file.BaseName] = $true }
            else { $existingUnmatchedRaw[$file.BaseName] = $true }
        }
    }
}
$groups = [Collections.Generic.List[object]]::new()
$operations = [Collections.Generic.List[object]]::new()
$counts = @{ MatchedRaw = 0; MatchedJpg = 0; UnmatchedRaw = 0; UnmatchedJpg = 0; Sidecars = 0 }
function Add-Transfer($Group, $File, [string]$Directory, [string]$Category) {
    $operation = [pscustomobject]@{ From = $File.FullName; To = [IO.Path]::Combine($Directory, $File.Name); Source = $File; Existing = $false }
    $Group.Add($operation)
    $operations.Add($operation)
    $counts[$Category]++
}
foreach ($base in $sources.Keys) {
    $group = [Collections.Generic.List[object]]::new()
    $isMatched = $references.ContainsKey($base) -or $existingMatchedJpg.ContainsKey($base)
    $directory = if ($isMatched) { $matchedRaw } else { $unmatchedRaw }
    $category = if ($isMatched) { 'MatchedRaw' } else { 'UnmatchedRaw' }
    Add-Transfer $group $sources[$base] $directory $category
    if ($sidecars.ContainsKey($base)) { Add-Transfer $group $sidecars[$base] $directory 'Sidecars' }
    if ($references.ContainsKey($base)) { Add-Transfer $group $references[$base] $matchedJpg 'MatchedJpg' }
    $groups.Add($group)
}
foreach ($base in $references.Keys) {
    if ($sources.ContainsKey($base)) { continue }
    $group = [Collections.Generic.List[object]]::new()
    if ($existingMatchedRaw.ContainsKey($base)) { Add-Transfer $group $references[$base] $matchedJpg 'MatchedJpg' }
    elseif ($IncludeUnmatchedRef) { Add-Transfer $group $references[$base] $unmatchedJpg 'UnmatchedJpg' }
    if ($group.Count) { $groups.Add($group) }
}
foreach ($base in $sidecars.Keys) {
    if ($sources.ContainsKey($base)) { continue }
    $group = [Collections.Generic.List[object]]::new()
    if ($existingMatchedRaw.ContainsKey($base)) { Add-Transfer $group $sidecars[$base] $matchedRaw 'Sidecars' }
    elseif ($existingUnmatchedRaw.ContainsKey($base)) { Add-Transfer $group $sidecars[$base] $unmatchedRaw 'Sidecars' }
    if ($group.Count) { $groups.Add($group) }
}
# 完整检查发生在创建目录、提示确认和移动文件之前。
$conflicts = [Collections.Generic.List[string]]::new()
$reserved = @{}
$skippedExisting = 0
foreach ($operation in $operations) {
    if ($reserved.ContainsKey($operation.To)) { $conflicts.Add($operation.To); continue }
    $reserved[$operation.To] = $true
    if ($existingTargets.ContainsKey($operation.To)) {
        $target = $existingTargets[$operation.To]
        $source = $operation.Source
        if (-not $target.PSIsContainer -and $source.Length -eq $target.Length -and
            (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $target.FullName -Algorithm SHA256).Hash) {
            $operation.Existing = $true
            $skippedExisting++
        }
        else { $conflicts.Add($operation.To) }
    }
}
if ($conflicts.Count) { throw ("存在不同内容的同名目标，未移动任何文件。请先处理：`n" + ($conflicts -join "`n")) }
$planned = $operations.Count - $skippedExisting
Write-Host '照片匹配分类' -ForegroundColor Cyan
Write-Host "目录：$root"
Write-Host ("匹配 RAW：{0}；匹配 JPG/JPEG：{1}；未匹配 RAW：{2}；未匹配 JPG：{3}；XMP：{4}" -f
    $counts.MatchedRaw, $counts.MatchedJpg, $counts.UnmatchedRaw, $counts.UnmatchedJpg, $counts.Sidecars)
Write-Host "待处理文件：$planned；目标已有相同内容：$skippedExisting"
if ($DryRun) {
    Write-Host '预览模式：不会创建文件夹或修改文件。' -ForegroundColor Magenta
    $shown = 0
    foreach ($operation in $operations) {
        if ($operation.Existing) { continue }
        if ($shown -lt 20) { Write-Host ("  {0} -> {1}" -f $operation.From, $operation.To) }
        else { Write-Verbose ("{0} -> {1}" -f $operation.From, $operation.To) }
        $shown++
    }
    if ($shown -gt 20) { Write-Host '其余项目可加 -Verbose 查看。' }
}
$completed = 0
$readyDirectories = @{}
if (-not $DryRun -and $planned) {
    if (-not $NoConfirm) {
        $answer = Read-Host '按回车开始，输入 N 取消'
        if ($answer -and $answer -notmatch '^(y|yes|是)$') { Write-Host '已取消，未修改文件。'; return }
    }
    try {
        foreach ($group in $groups) {
            Invoke-TransferGroup $group
            foreach ($operation in $group) { if (-not $operation.Existing) { $completed++ } }
            if ($completed % 50 -eq 0 -or $completed -eq $planned) {
                Write-Progress -Activity '照片匹配分类' -Status "$completed / $planned" -PercentComplete (100 * $completed / $planned)
            }
        }
    }
    finally { Write-Progress -Activity '照片匹配分类' -Completed }
    Write-Host ("完成：{0} 个文件，耗时 {1:N2} 秒。" -f $completed, $timer.Elapsed.TotalSeconds) -ForegroundColor Green
}
elseif (-not $DryRun) { Write-Host '没有需要处理的文件。' -ForegroundColor Yellow }
if ($skippedExisting -and -not $Copy) { Write-Host '同内容的源文件仍保留在原处，未删除重复原件。' -ForegroundColor Yellow }
if ($PassThru) {
    [pscustomobject]@{
        MatchedRaw = $counts.MatchedRaw; MatchedJpg = $counts.MatchedJpg
        UnmatchedRaw = $counts.UnmatchedRaw; UnmatchedJpg = $counts.UnmatchedJpg
        Sidecars = $counts.Sidecars; Planned = $planned; Completed = $completed
        SkippedExisting = $skippedExisting; DryRun = [bool]$DryRun
        ElapsedSeconds = $timer.Elapsed.TotalSeconds
    }
}
