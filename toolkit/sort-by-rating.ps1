#requires -Version 5.1
<#
.SYNOPSIS
    读取 matched_jpg 中已保存的照片星级，将同名 RAW/XMP 自动移入 0-5 文件夹。
.DESCRIPTION
    JPG/JPEG 留在原处。优先读取 Adobe XMP Rating，兼容 EXIF Rating；
    未评分按 0 星，拒绝标记 (-1) 跳过。再次运行可按新星级重新归类 RAW/XMP。
    全部读取和冲突检查通过后才移动文件，每张照片失败时撤回当前组。
.EXAMPLE
    .\sort-by-rating.ps1 -Path 'D:\照片' -DryRun
.EXAMPLE
    .\sort-by-rating.ps1 -Path 'D:\照片'
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$RawExt = 'nef',
    [string]$PickExt = 'jpg',
    [AllowEmptyString()][string]$SidecarExt = 'xmp',
    [string]$RawSourceDir = 'matched_nef',
    [string]$JpgSourceDir = 'matched_jpg',
    [string]$ExifToolPath = '',
    [ValidateSet('Zero', 'Skip')][string]$UnratedAction = 'Zero',
    [string]$ReportPath = '',
    [switch]$SyncTags,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'workflow-common.ps1')
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
    return (Assert-LocalPath $root $candidate)
}
function Add-IndexedFile($Index, $File) {
    $null = Assert-LocalPath $root $File.FullName
    if ($Index.ContainsKey($File.BaseName)) {
        throw "同名文件无法确定匹配，未移动任何文件：$($Index[$File.BaseName].FullName)、$($File.FullName)"
    }
    $Index[$File.BaseName] = $File
}
function Read-JpgRatings($Files) {
    $ratings = @{}
    if (-not $Files.Count) { return $ratings }
    if ($ExifToolPath) { $tool = (Get-Item -LiteralPath $ExifToolPath).FullName }
    elseif ([IO.File]::Exists((Join-Path $PSScriptRoot 'tools\exiftool\exiftool.exe'))) {
        $tool = Join-Path $PSScriptRoot 'tools\exiftool\exiftool.exe'
    }
    elseif ([IO.File]::Exists((Join-Path $PSScriptRoot 'exiftool.exe'))) { $tool = Join-Path $PSScriptRoot 'exiftool.exe' }
    else {
        $command = Get-Command exiftool -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) { throw '未找到 ExifTool。请保留完整 tools 文件夹，或使用 -ExifToolPath 指定。' }
        $tool = $command.Source
    }
    $argumentFile = [IO.Path]::GetTempFileName()
    $process = $null
    try {
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @('-charset', 'filename=UTF8', '-json', '-n', '-a', '-G1', '-q',
            '-XMP-xmp:Rating', '-IFD0:Rating', '-FileType', '-Error', '-Warning')) { $arguments.Add($argument) }
        foreach ($file in $Files) { $arguments.Add($file.FullName) }
        [IO.File]::WriteAllLines($argumentFile, $arguments, [Text.UTF8Encoding]::new($false))
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $tool
        $startInfo.Arguments = '-@ "' + $argumentFile + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
        $startInfo.EnvironmentVariables['LC_ALL'] = 'C'
        $process = [Diagnostics.Process]::Start($startInfo)
        # 同时读取两个流，避免大量照片或警告使输出缓冲区阻塞。
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $outputTask.GetAwaiter().GetResult()
        $errors = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "ExifTool 读取星级失败，未移动任何文件：`n$errors`n$output" }
        if ($errors.Trim()) { Write-Warning $errors.Trim() }
        # PowerShell 5.1 的 ConvertFrom-Json 会返回未展开的数组，直接赋值后再遍历。
        $entries = ConvertFrom-Json -InputObject $output
        foreach ($entry in $entries) {
            if ($entry.PSObject.Properties['ExifTool:Error'] -or $entry.PSObject.Properties['Error']) {
                throw "照片读取失败，未移动任何文件：$($entry.SourceFile)"
            }
            $sourcePath = [IO.Path]::GetFullPath([string]$entry.SourceFile)
            if ($pickExt -in @('jpg', 'jpeg') -and $entry.'File:FileType' -ne 'JPEG') {
                throw "文件不是有效的 JPG/JPEG，未移动任何文件：$sourcePath"
            }
            if ($ratings.ContainsKey($sourcePath)) { throw "ExifTool 返回重复照片：$sourcePath" }
            $property = $entry.PSObject.Properties['XMP-xmp:Rating']
            $source = 'Adobe XMP'
            if (-not $property) { $property = $entry.PSObject.Properties['IFD0:Rating']; $source = 'EXIF' }
            $rating = 0
            if ($property) {
                $value = [string]$property.Value
                # XMP 允许实数，但本工具只把 -1、0、1、2、3、4、5 当作明确的选片结果。
                $number = [decimal]0
                if (-not [decimal]::TryParse($value, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
                    $number -lt -1 -or $number -gt 5 -or $number -ne [Math]::Truncate($number)) {
                    throw "无效星级 $value，未移动任何文件：$sourcePath"
                }
                $rating = [int]$number
            }
            else { $source = '未评分' }
            $ratings[$sourcePath] = [pscustomobject]@{ Rating = $rating; Source = $source }
        }
        foreach ($file in $Files) {
            if (-not $ratings.ContainsKey($file.FullName)) { throw "未读到照片信息，未移动任何文件：$($file.FullName)" }
        }
        return $ratings
    }
    finally {
        if ($process) { $process.Dispose() }
        [IO.File]::Delete($argumentFile)
    }
}
function Add-Move($Group, $File, [string]$Directory) {
    $target = [IO.Path]::Combine($Directory, $File.Name)
    if ($File.FullName -eq $target) { return }
    if ($existingTargets.ContainsKey($target) -or $reserved.ContainsKey($target)) { $conflicts.Add($target) }
    $reserved[$target] = $true
    $operation = [pscustomobject]@{ From = $File.FullName; To = $target }
    $Group.Add($operation)
    $operations.Add($operation)
}
function Invoke-MoveGroup($Operations) {
    $finished = [Collections.Generic.List[object]]::new()
    try {
        foreach ($operation in $Operations) {
            $directory = [IO.Path]::GetDirectoryName($operation.To)
            if (-not $readyDirectories.ContainsKey($directory)) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                $readyDirectories[$directory] = $true
            }
            $source = Get-Item -LiteralPath $operation.From -Force
            $script:moveId++
            Write-HistoryEvent $history.Writer @{ Type = 'Move'; Id = $script:moveId; From = $operation.From; To = $operation.To; Length = $source.Length; ModifiedTicks = $source.LastWriteTimeUtc.Ticks }
            [IO.File]::Move($operation.From, $operation.To)
            $finished.Add($operation)
            Write-HistoryEvent $history.Writer @{ Type = 'Moved'; Id = $script:moveId }
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
if ($SyncTags -and $sidecarExt -and $sidecarExt -ne 'xmp') {
    throw '-SyncTags 仅支持 -SidecarExt xmp 或空字符串；未移动任何文件。'
}
$pickExtensions = if ($pickExt -in @('jpg', 'jpeg')) { @('jpg', 'jpeg') } else { @($pickExt) }
if ($rawExt -in $pickExtensions -or ($sidecarExt -and ($sidecarExt -eq $rawExt -or $sidecarExt -in $pickExtensions))) {
    throw 'RAW、JPG 和 XMP 的扩展名必须不同。'
}
$rootItem = Get-Item -LiteralPath $Path
if (-not $rootItem.PSIsContainer -or $rootItem.PSProvider.Name -ne 'FileSystem') { throw "不是文件夹：$Path" }
$root = $rootItem.FullName
$rawSource = Get-ChildDirectory $RawSourceDir
$jpgSource = Get-ChildDirectory $JpgSourceDir
if (-not [IO.Directory]::Exists($jpgSource)) { throw "未找到 JPG 来源：$jpgSource。请先执行匹配分类。" }
$starPaths = @{}
$existingTargets = @{}
foreach ($star in 0..5) {
    $starPath = Get-ChildDirectory ([string]$star)
    if ($starPath -eq $rawSource -or $starPath -eq $jpgSource) { throw 'RAW/JPG 来源不能是 0-5 星级文件夹。' }
    $starPaths[$star] = $starPath
    if ([IO.Directory]::Exists($starPath)) {
        foreach ($file in Get-ChildItem -LiteralPath $starPath -Force) { $existingTargets[$file.FullName] = $true }
    }
}
$jpgByBase = @{}
foreach ($file in Get-ChildItem -LiteralPath $jpgSource -File) {
    if ($file.Extension.TrimStart('.') -in $pickExtensions) { Add-IndexedFile $jpgByBase $file }
}
$rawByBase = @{}
$sidecarByBase = @{}
$rawDirectories = @($rawSource) + @(0..5 | ForEach-Object { $starPaths[$_] })
foreach ($directory in $rawDirectories) {
    if (-not [IO.Directory]::Exists($directory)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force) {
        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        if ($extension -eq $rawExt) { Add-IndexedFile $rawByBase $file }
        elseif ($sidecarExt -and $extension -eq $sidecarExt) { Add-IndexedFile $sidecarByBase $file }
    }
}
if ($sidecarExt -and $rawSource -ne $root) {
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Force) {
        if ($file.Extension.TrimStart('.') -eq $sidecarExt -and -not $sidecarByBase.ContainsKey($file.BaseName)) {
            Add-IndexedFile $sidecarByBase $file
        }
    }
}
Write-Host '按 JPG/JPEG 星级自动归类 RAW' -ForegroundColor Cyan
Write-Host "目录：$root"
Write-Host '请先在 Adobe 软件中将星级保存到 JPG 元数据；JPG 留在原处。'
$jpgFiles = @($jpgByBase.Values | Sort-Object Name)
$ratings = Read-JpgRatings $jpgFiles
$groups = [Collections.Generic.List[object]]::new()
$items = [Collections.Generic.List[object]]::new()
$operations = [Collections.Generic.List[object]]::new()
$missing = [Collections.Generic.List[string]]::new()
$rejected = [Collections.Generic.List[string]]::new()
$conflicts = [Collections.Generic.List[string]]::new()
$reserved = @{}
$starCounts = @(0, 0, 0, 0, 0, 0)
$alreadySorted = 0
$sidecarCount = 0
$unrated = 0
$explicitZero = 0
foreach ($jpg in $jpgFiles) {
    $rating = $ratings[$jpg.FullName].Rating
    $source = $ratings[$jpg.FullName].Source
    $raw = if ($rawByBase.ContainsKey($jpg.BaseName)) { $rawByBase[$jpg.BaseName].FullName } else { '' }
    $sidecar = if ($sidecarByBase.ContainsKey($jpg.BaseName)) { $sidecarByBase[$jpg.BaseName].FullName } else { '' }
    $item = [pscustomobject]@{ BaseName = $jpg.BaseName; Jpg = $jpg.FullName; Raw = $raw; Sidecar = $sidecar; Rating = $rating; RatingSource = $source; Status = 'Planned'; TargetDirectory = '' }
    $items.Add($item)
    if ($source -eq '未评分') { $unrated++ }
    elseif ($rating -eq 0) { $explicitZero++ }
    if ($rating -eq -1) { $rejected.Add($jpg.FullName); $item.Status = 'Rejected'; continue }
    if ($source -eq '未评分' -and $UnratedAction -eq 'Skip') { $item.Status = 'UnratedSkipped'; continue }
    $starCounts[$rating]++
    if (-not $rawByBase.ContainsKey($jpg.BaseName)) { $missing.Add($jpg.FullName); $item.Status = 'MissingRaw'; continue }
    $item.TargetDirectory = $starPaths[$rating]
    $group = [Collections.Generic.List[object]]::new()
    Add-Move $group $rawByBase[$jpg.BaseName] $starPaths[$rating]
    if ($sidecarExt -and $sidecarByBase.ContainsKey($jpg.BaseName)) {
        $before = $group.Count
        Add-Move $group $sidecarByBase[$jpg.BaseName] $starPaths[$rating]
        if ($group.Count -gt $before) { $sidecarCount++ }
    }
    if ($group.Count) { $groups.Add([pscustomobject]@{ Jpg = $jpg; Rating = $rating; Moves = $group }) }
    else { $alreadySorted++; $item.Status = 'AlreadySorted' }
}
if ($conflicts.Count) { throw ("存在同名目标，未移动任何文件。请先处理：`n" + ($conflicts -join "`n")) }
Write-Host "JPG/JPEG：$($jpgFiles.Count)；待归类：$($groups.Count)；已在正确星级：$alreadySorted；待移动 XMP：$sidecarCount"
Write-Host ((0..5 | ForEach-Object { "$_ 星：$($starCounts[$_])" }) -join '；')
Write-Host "未保存星级：$unrated（处理策略：$UnratedAction）；明确 0 星：$explicitZero；拒绝跳过：$($rejected.Count)；缺 RAW：$($missing.Count)"
if ($unrated -eq $jpgFiles.Count -and $unrated) { Write-Warning '所有 JPG 都没有星级标签。如果已在 Lightroom 打星，请先将元数据保存到文件，再重新预览。' }
foreach ($file in $missing) { Write-Warning "没有同名 RAW，跳过：$file" }
foreach ($file in $rejected) { Write-Verbose "拒绝标记 (-1)，保留当前位置：$file" }
if ($ReportPath) { Export-PlanCsv $items $ReportPath }
if ($PlanOnly) {
    [pscustomobject]@{ Root = $root; Items = @($items.ToArray()); Groups = @($groups.ToArray()); Unrated = $unrated; ExplicitZero = $explicitZero }
    return
}
if ($DryRun) {
    Write-Host '预览模式：只读星级，不创建文件夹、不移动文件、不修改标签。' -ForegroundColor Magenta
    if ($SyncTags) { Write-Host '执行时还会同步有效匹配照片的星级与标签，保留目标缺失字段及 _original 副本；拒绝/跳过的照片不参与同步。' }
    for ($index = 0; $index -lt $groups.Count; $index++) {
        $group = $groups[$index]
        $description = "$($group.Jpg.Name) [$($group.Rating) 星]"
        foreach ($operation in $group.Moves) { $description += "`n  $($operation.From) -> $($operation.To)" }
        if ($index -lt 20) { Write-Host $description } else { Write-Verbose $description }
    }
    if ($groups.Count -gt 20) { Write-Host '其余项目可加 -Verbose 查看。' }
}
$completed = 0
$filesMoved = 0
$readyDirectories = @{}
$history = $null
$workflowLock = $null
$script:moveId = 0
$syncResult = $null
if (-not $DryRun) {
    try {
        if ($groups.Count -or $SyncTags) { $workflowLock = Open-WorkflowLock $root }
        if ($groups.Count) { $history = New-MoveHistory $root }
        foreach ($group in $groups) {
            Invoke-MoveGroup $group.Moves
            $completed++
            $filesMoved += $group.Moves.Count
            if ($completed % 25 -eq 0 -or $completed -eq $groups.Count) {
                Write-Progress -Activity '按照片星级自动归类' -Status "$completed / $($groups.Count)" -PercentComplete (100 * $completed / $groups.Count)
            }
        }
        if ($history) { Write-HistoryEvent $history.Writer @{ Type = 'Finished'; Photos = $completed } }
        if ($SyncTags) {
            $ratingOverrides = @{}
            foreach ($item in $items) {
                if ($item.Status -in @('Planned', 'AlreadySorted')) { $ratingOverrides[$item.BaseName] = $item.Rating }
            }
            if ($ratingOverrides.Count) {
                $syncResult = & (Join-Path $PSScriptRoot 'sync-tags-to-nef.ps1') -Path $root -RawExt $RawExt -PickExt $PickExt -JpgSourceDir $JpgSourceDir -ExifToolPath $ExifToolPath -RatingOverrides $ratingOverrides -KeepMissingTags -KeepBackup -SkipSidecars:([string]::IsNullOrEmpty($sidecarExt)) -PassThru
            }
        }
    }
    finally {
        if ($history) { $history.Writer.Dispose(); Write-Host "可撤销记录：$($history.Path)" }
        if ($workflowLock) { $workflowLock.Dispose() }
        Write-Progress -Activity '按照片星级自动归类' -Completed
    }
    Write-Host ("完成：归类 {0} 张，移动 {1} 个 RAW/XMP 文件；耗时 {2:N2} 秒。" -f $completed, $filesMoved, $timer.Elapsed.TotalSeconds) -ForegroundColor Green
}
if ($PassThru) {
    [pscustomobject]@{
        PickFilesSeen = $jpgFiles.Count; Planned = $groups.Count; MovedPhotos = $completed
        FilesMoved = $filesMoved; Sidecars = $sidecarCount; AlreadySorted = $alreadySorted
        RawMissing = $missing.Count; Rejected = $rejected.Count; DryRun = [bool]$DryRun
        Unrated = $unrated; ExplicitZero = $explicitZero; UnratedAction = $UnratedAction
        HistoryPath = if ($history) { $history.Path } else { '' }; Sync = $syncResult
        ElapsedSeconds = $timer.Elapsed.TotalSeconds
    }
}
