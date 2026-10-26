#requires -Version 5.1
<#
.SYNOPSIS
    将 matched_jpg 中每张 JPG/JPEG 的标签独立同步到星级目录的同名 RAW。
.DESCRIPTION
    默认每批 200 张，共用一个 ExifTool 进程，用 -execute 分隔每张照片。
    仅同步星级、颜色标签、关键字和文字说明，已有 XMP 侧车同时更新。
    不复制相机、镜头、画质或 Camera Raw 调色参数。预览不需要 ExifTool。
    缺失的源标签默认清除目标旧标签；-KeepMissingTags 可保留旧标签。
.EXAMPLE
    .\sync-tags-to-nef.ps1 -Path 'D:\照片' -DryRun
.EXAMPLE
    .\sync-tags-to-nef.ps1 -BatchSize 200 -KeepBackup
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$RawExt = 'nef',
    [string]$PickExt = 'jpg',
    [string]$JpgSourceDir = 'matched_jpg',
    [string[]]$StarFolders = @('0', '1', '2', '3', '4', '5'),
    [ValidateRange(1, 1000)][int]$BatchSize = 200,
    [string]$ExifToolPath = '',
    [string]$ReportPath = '',
    [switch]$DryRun,
    [switch]$KeepBackup,
    [switch]$KeepMissingTags,
    [switch]$SkipSidecars,
    [switch]$RatingFromFolder,
    [hashtable]$RatingOverrides,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = $PSScriptRoot }
$timer = [Diagnostics.Stopwatch]::StartNew()
if ($PSBoundParameters.ContainsKey('RatingOverrides')) {
    if ($RatingFromFolder) { throw '不能同时使用文件夹星级和已读取的照片星级。' }
    foreach ($value in $RatingOverrides.Values) {
        if ([string]$value -notmatch '^[0-5]$') { throw '指定星级必须是 0-5 的整数。' }
    }
}
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
$rawExt = Convert-Extension $RawExt
$pickExt = Convert-Extension $PickExt
$pickExtensions = if ($pickExt -in @('jpg', 'jpeg')) { @('jpg', 'jpeg') } else { @($pickExt) }
if ($rawExt -in $pickExtensions -or $rawExt -eq 'xmp') { throw 'RAW 扩展名不能与 JPG/JPEG 或 XMP 相同。' }
$rootItem = Get-Item -LiteralPath $Path
if (-not $rootItem.PSIsContainer -or $rootItem.PSProvider.Name -ne 'FileSystem') { throw "不是文件夹：$Path" }
$root = $rootItem.FullName
$jpgSource = Get-ChildDirectory $JpgSourceDir
if (-not [IO.Directory]::Exists($jpgSource)) { throw "未找到 $jpgSource。请先执行匹配分类和星级替换。" }
$rawByBase = @{}
$starNames = @{}
foreach ($star in $StarFolders) {
    if (-not $star -or $star -in @('.', '..') -or $star.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "无效星级文件夹名称：$star"
    }
    if ($starNames.ContainsKey($star)) { throw "星级文件夹重复：$star" }
    if ($RatingFromFolder -and $star -notmatch '^[0-5]$') { throw '-RatingFromFolder 只支持名称为 0 到 5 的文件夹。' }
    $starNames[$star] = $true
    $starPath = Get-ChildDirectory $star
    if ($starPath -eq $jpgSource) { throw 'JPG 来源不能是星级文件夹。' }
    if (-not [IO.Directory]::Exists($starPath)) { continue }
    $localSidecars = @{}
    $localRaw = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $starPath -File -Force) {
        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        if ($extension -eq $rawExt) { $localRaw.Add($file) }
        elseif ($extension -eq 'xmp') { $localSidecars[$file.BaseName] = $file.FullName }
    }
    foreach ($file in $localRaw) {
        if ($rawByBase.ContainsKey($file.BaseName)) {
            throw "多个星级中存在同名 RAW，未写入任何标签：$($rawByBase[$file.BaseName].Raw)、$($file.FullName)"
        }
        $sidecar = if (-not $SkipSidecars -and $localSidecars.ContainsKey($file.BaseName)) { $localSidecars[$file.BaseName] } else { '' }
        $rawByBase[$file.BaseName] = [pscustomobject]@{ Raw = $file.FullName; Star = $star; Sidecar = $sidecar }
    }
}
$jpgByBase = @{}
foreach ($file in Get-ChildItem -LiteralPath $jpgSource -File) {
    if ($file.Extension.TrimStart('.') -notin $pickExtensions) { continue }
    if ($jpgByBase.ContainsKey($file.BaseName)) {
        throw "同名 JPG/JPEG 有多个标签来源，未写入任何标签：$($jpgByBase[$file.BaseName].FullName)、$($file.FullName)"
    }
    $jpgByBase[$file.BaseName] = $file
}
$pairs = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$missing = 0
$duplicates = 0
foreach ($base in $jpgByBase.Keys) {
    if ($PSBoundParameters.ContainsKey('RatingOverrides') -and -not $RatingOverrides.ContainsKey($base)) { continue }
    $jpg = $jpgByBase[$base]
    if (-not $rawByBase.ContainsKey($base)) {
        if ($base -match '^(.*)__dup\d+$' -and $jpgByBase.ContainsKey($Matches[1])) { $duplicates++ }
        else {
            $missing++
            Write-Warning "没有对应 RAW，跳过：$($jpg.Name)"
            $results.Add([pscustomobject]@{ Jpg = $jpg.FullName; Raw = ''; Sidecar = ''; Status = 'MissingRaw'; Detail = '没有同名 RAW' })
        }
        continue
    }
    $raw = $rawByBase[$base]
    $result = [pscustomobject]@{ Jpg = $jpg.FullName; Raw = $raw.Raw; Sidecar = $raw.Sidecar; Status = 'Planned'; Detail = '' }
    $pairs.Add([pscustomobject]@{ Jpg = $jpg.FullName; Raw = $raw.Raw; Sidecar = $raw.Sidecar; Star = $raw.Star; Result = $result })
    $results.Add($result)
}
Write-Host 'JPG/JPEG 标签同步到 RAW' -ForegroundColor Cyan
Write-Host "目录：$root"
Write-Host "匹配：$($pairs.Count) 张；缺 RAW：$missing 张；旧 __dup 副本：$duplicates 张；每批：$BatchSize 张"
if ($RatingFromFolder) { Write-Host '星级来源：0-5 文件夹；其他标签来源：JPG/JPEG。' }
else { Write-Host '星级和其他标签来源：JPG/JPEG 元数据。' }
$successful = 0
$failed = 0
$report = ''
if ($DryRun) {
    Write-Host '预览模式：不写标签、不创建报告，也不要求安装 ExifTool。' -ForegroundColor Magenta
    for ($index = 0; $index -lt $pairs.Count; $index++) {
        $pair = $pairs[$index]
        $description = "{0} -> {1}" -f $pair.Jpg, $pair.Raw
        if ($pair.Sidecar) { $description += " + $($pair.Sidecar)" }
        if ($index -lt 20) { Write-Host "  $description" } else { Write-Verbose $description }
    }
    if ($pairs.Count -gt 20) { Write-Host '其余项目可加 -Verbose 查看。' }
}
elseif ($pairs.Count) {
    # 支持 PATH 中的工具，也支持将便携版 exiftool.exe 放在脚本旁。
    if ($ExifToolPath) { $tool = (Get-Item -LiteralPath $ExifToolPath).FullName }
    elseif ([IO.File]::Exists((Join-Path $PSScriptRoot 'tools\exiftool\exiftool.exe'))) { $tool = Join-Path $PSScriptRoot 'tools\exiftool\exiftool.exe' }
    elseif ([IO.File]::Exists((Join-Path $PSScriptRoot 'exiftool.exe'))) { $tool = Join-Path $PSScriptRoot 'exiftool.exe' }
    else {
        $command = Get-Command exiftool -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) { throw '未找到 ExifTool。可将便携版 exiftool.exe 和 exiftool_files 放在脚本旁，或使用 -ExifToolPath 指定。' }
        $tool = $command.Source
    }
    $report = if ($ReportPath) { [IO.Path]::GetFullPath($ReportPath) } else {
        Join-Path $root ('标签同步结果-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.csv')
    }
    # 在首次标签写入前检查报告是否可创建，避免完成后才发现无法保存结果。
    if (Test-Path -LiteralPath $report) { throw "结果报告已经存在，请指定新文件名：$report" }
    $reportDirectory = [IO.Path]::GetDirectoryName($report)
    if (-not [IO.Directory]::Exists($reportDirectory)) { throw "报告文件夹不存在：$reportDirectory" }
    $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
    $tags = @('xmp:Rating', 'xmp:RatingPercent', 'xmp:Label', 'xmp:Subject', 'xmp:HierarchicalSubject',
        'xmp:Description', 'xmp:Title', 'xmp:Creator', 'xmp:Rights', 'iptc:Keywords')
    $batches = [int][Math]::Ceiling($pairs.Count / [double]$BatchSize)
    try {
        for ($offset = 0; $offset -lt $pairs.Count; $offset += $BatchSize) {
            $count = [Math]::Min($BatchSize, $pairs.Count - $offset)
            $batchNumber = [int]($offset / $BatchSize) + 1
            $argumentFile = [IO.Path]::GetTempFileName()
            $errorFile = [IO.Path]::GetTempFileName()
            $writer = $null
            try {
                $originalTimes = @{}
                $originalAttributes = @{}
                $writer = [IO.StreamWriter]::new($argumentFile, $false, [Text.UTF8Encoding]::new($false))
                for ($index = $offset; $index -lt $offset + $count; $index++) {
                    $pair = $pairs[$index]
                    $originalTimes[$pair.Raw] = [IO.File]::GetLastWriteTimeUtc($pair.Raw)
                    $originalAttributes[$pair.Raw] = [IO.File]::GetAttributes($pair.Raw)
                    if ($pair.Sidecar) {
                        $originalTimes[$pair.Sidecar] = [IO.File]::GetLastWriteTimeUtc($pair.Sidecar)
                        $originalAttributes[$pair.Sidecar] = [IO.File]::GetAttributes($pair.Sidecar)
                    }
                    $writer.WriteLine('-charset')
                    $writer.WriteLine('filename=UTF8')
                    $writer.WriteLine('-P')
                    if (-not $KeepBackup) { $writer.WriteLine('-overwrite_original') }
                    $writer.WriteLine('-efile')
                    $writer.WriteLine($errorFile)
                    if (-not $KeepMissingTags) { foreach ($tag in $tags) { $writer.WriteLine('-' + $tag + '=') } }
                    $writer.WriteLine('-tagsFromFile')
                    $writer.WriteLine($pair.Jpg)
                    if (-not $RatingFromFolder) {
                        # EXIF 作为后备；随后存在的 XMP 评分会覆盖它，包括明确的 0 星。
                        $writer.WriteLine('-xmp:Rating<IFD0:Rating')
                    }
                    foreach ($tag in $tags) { $writer.WriteLine('-' + $tag) }
                    if ($RatingFromFolder -or $PSBoundParameters.ContainsKey('RatingOverrides')) {
                        $effectiveRating = if ($RatingFromFolder) { [int]$pair.Star } else { [int]$RatingOverrides[[IO.Path]::GetFileNameWithoutExtension($pair.Jpg)] }
                        $writer.WriteLine('-xmp:Rating=' + $effectiveRating)
                        $percent = @(0, 1, 25, 50, 75, 99)[$effectiveRating]
                        $writer.WriteLine('-xmp:RatingPercent=' + $percent)
                    }
                    $writer.WriteLine($pair.Raw)
                    if ($pair.Sidecar) { $writer.WriteLine($pair.Sidecar) }
                    # 每个来源/目标对都是独立命令，防止后一张覆盖前一张的标签。
                    $writer.WriteLine('-execute')
                }
                $writer.Dispose()
                $writer = $null
                Write-Progress -Activity '同步标签' -Status "第 $batchNumber / $batches 批" -PercentComplete (100 * $offset / $pairs.Count)
                $nativePreference = $ErrorActionPreference
                try {
                    # Windows PowerShell 5.1 会把 native stderr 转成 ErrorRecord。
                    $ErrorActionPreference = 'Continue'
                    $output = @(& $tool -charset filename=UTF8 -@ $argumentFile 2>&1)
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $nativePreference
                    # ExifTool 替换文件时会丢失隐藏属性；包括部分失败时已写入的文件也要恢复。
                    foreach ($target in $originalAttributes.Keys) {
                        [IO.File]::SetAttributes($target, $originalAttributes[$target])
                    }
                }
                $errorPaths = @{}
                foreach ($line in [IO.File]::ReadAllLines($errorFile, [Text.Encoding]::UTF8)) {
                    # ExifTool 在 Windows 上也可能返回 /，统一为绝对路径再比较。
                    if ($line.Trim()) { $errorPaths[[IO.Path]::GetFullPath($line.Trim())] = $true }
                }
                $batchTargets = @{}
                for ($index = $offset; $index -lt $offset + $count; $index++) {
                    $batchTargets[$pairs[$index].Raw] = $true
                    if ($pairs[$index].Sidecar) { $batchTargets[$pairs[$index].Sidecar] = $true }
                }
                $unconfirmed = $exitCode -ne 0 -and $errorPaths.Count -eq 0
                foreach ($errorPath in $errorPaths.Keys) {
                    if (-not $batchTargets.ContainsKey($errorPath)) { $unconfirmed = $true }
                }
                for ($index = $offset; $index -lt $offset + $count; $index++) {
                    $pair = $pairs[$index]
                    if ($unconfirmed -or $errorPaths.ContainsKey($pair.Raw) -or ($pair.Sidecar -and $errorPaths.ContainsKey($pair.Sidecar))) {
                        $pair.Result.Status = 'Failed'
                        $pair.Result.Detail = ($output | ForEach-Object { $_.ToString() }) -join ' | '
                        $failed++
                    }
                    else {
                        # ExifTool 的浮点时间转换可能损失几个 100ns tick，使用原值恢复。
                        [IO.File]::SetLastWriteTimeUtc($pair.Raw, $originalTimes[$pair.Raw])
                        if ($pair.Sidecar) { [IO.File]::SetLastWriteTimeUtc($pair.Sidecar, $originalTimes[$pair.Sidecar]) }
                        $pair.Result.Status = 'Success'
                        $successful++
                    }
                }
                if ($exitCode -ne 0 -or $errorPaths.Count) { Write-Warning ("第 $batchNumber 批出现错误：" + (($output | ForEach-Object { $_.ToString() }) -join ' | ')) }
                else { Write-Host "第 $batchNumber / $batches 批完成：$count 张" -ForegroundColor Green }
            }
            catch {
                for ($index = $offset; $index -lt $offset + $count; $index++) {
                    $pair = $pairs[$index]
                    if ($pair.Result.Status -eq 'Planned') {
                        $pair.Result.Status = 'Unconfirmed'; $pair.Result.Detail = $_.Exception.Message; $failed++
                    }
                }
                throw
            }
            finally {
                if ($writer) { $writer.Dispose() }
                [IO.File]::Delete($argumentFile)
                [IO.File]::Delete($errorFile)
            }
            $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
        }
    }
    finally {
        Write-Progress -Activity '同步标签' -Completed
        $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
        Write-Host "结果报告：$report"
    }
    Write-Host ("处理成功：{0} 张；失败或未确认：{1} 张；耗时 {2:N2} 秒。" -f $successful, $failed, $timer.Elapsed.TotalSeconds)
}
else { Write-Host '没有需要同步的匹配对。' -ForegroundColor Yellow }
if ($PassThru) {
    [pscustomobject]@{
        Pairs = $pairs.Count; Successful = $successful; Failed = $failed; MissingRaw = $missing
        SkippedDuplicates = $duplicates; DryRun = [bool]$DryRun; ReportPath = $report
        ElapsedSeconds = $timer.Elapsed.TotalSeconds
    }
}
if ($failed) { throw "有 $failed 张照片同步失败或未确认；请查看报告后重试。" }
