#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot,
    [Parameter(Mandatory = $true)][string]$Destination,
    [ValidateRange(0, 5)][int]$MinRating = 4,
    [ValidateSet('Jpg', 'Raw', 'Both')][string]$Format = 'Both',
    [string]$RawExt = 'nef',
    [string]$RawSourceDir = 'matched_nef',
    [string]$ExifToolPath = '',
    [switch]$DryRun,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'workflow-common.ps1')
$plan = & (Join-Path $PSScriptRoot 'sort-by-rating.ps1') -Path $Path -RawExt $RawExt -RawSourceDir $RawSourceDir -ExifToolPath $ExifToolPath -UnratedAction Skip -PlanOnly
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw "请指定一个尚不存在的新导出文件夹：$destinationPath" }
# Do not let a mistyped destination occupy a reserved source/star/history directory.
$parent = [IO.Path]::GetDirectoryName($destinationPath)
if (-not [IO.Directory]::Exists($parent)) { throw "导出目录的上一级不存在：$parent" }
$null = Assert-LocalPath $parent $destinationPath
foreach ($reserved in @('0', '1', '2', '3', '4', '5', 'matched_jpg', $RawSourceDir, 'unmatched_nef', '.raw-star-sorter')) {
    $reservedPath = [IO.Path]::GetFullPath((Join-Path $plan.Root $reserved))
    if ($destinationPath -eq $reservedPath -or $destinationPath.StartsWith($reservedPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '请将精选照片导出到独立的新文件夹。'
    }
}
$copies = [Collections.Generic.List[object]]::new()
$targets = @{}
$photos = 0
foreach ($item in $plan.Items) {
    if ($item.RatingSource -eq '未评分' -or $item.Rating -lt $MinRating) { continue }
    if ($Format -ne 'Jpg' -and -not $item.Raw) { continue }
    $photos++
    $sources = [Collections.Generic.List[string]]::new()
    if ($Format -ne 'Raw') { $sources.Add($item.Jpg) }
    if ($Format -ne 'Jpg') {
        $sources.Add($item.Raw)
        if ($item.Sidecar) { $sources.Add($item.Sidecar) }
    }
    foreach ($source in $sources) {
        $target = Join-Path $destinationPath ([IO.Path]::GetFileName($source))
        if ($targets.ContainsKey($target)) { throw "导出文件同名：$target" }
        $targets[$target] = $true
        $copies.Add([pscustomobject]@{ From = $source; To = $target })
    }
}
Write-Host "精选导出：$MinRating 星及以上；格式：$Format；照片：$photos；文件：$($copies.Count)"
Write-Host "导出至：$destinationPath"
$copied = 0
if ($DryRun) { foreach ($copy in $copies) { Write-Host "$($copy.From) -> $($copy.To)" } }
elseif ($copies.Count) {
    # Stage in a unique sibling directory; publish only a complete copy set, never overwrite.
    $stage = Join-Path $parent ('.raw-star-export-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        foreach ($copy in $copies) {
            [IO.File]::Copy($copy.From, (Join-Path $stage ([IO.Path]::GetFileName($copy.To))), $false)
            $copied++
            Write-Progress -Activity '复制精选照片' -Status "$copied / $($copies.Count)" -PercentComplete (100 * $copied / $copies.Count)
        }
        [IO.Directory]::Move($stage, $destinationPath)
        Write-Host "导出完成：$photos 张照片，源文件保持原位。" -ForegroundColor Green
    }
    catch {
        Write-Warning "导出没有完成。已复制的临时文件保留在：$stage；可检查后删除。"
        throw
    }
    finally { Write-Progress -Activity '复制精选照片' -Completed }
}
if ($PassThru) { [pscustomobject]@{ Photos = $photos; Planned = $copies.Count; Copied = $copied; Destination = $destinationPath; DryRun = [bool]$DryRun } }
