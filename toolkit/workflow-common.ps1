#requires -Version 5.1
# Shared filesystem boundaries and append-only move history. No photo writes at import.
function Assert-LocalPath([string]$Root, [string]$Candidate) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Candidate)
    if ($full -ne $rootPath -and -not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径超出照片目录：$Candidate"
    }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "请使用真实文件夹，不能通过链接处理照片：$cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Open-WorkflowLock([string]$Root) {
    $directory = Assert-LocalPath $Root (Join-Path $Root '.raw-star-sorter')
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $lockPath = Assert-LocalPath $Root (Join-Path $directory 'workflow.lock')
    try { return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw '此照片目录正在整理或撤销，请等另一个窗口完成后重试。' }
}
function Write-HistoryEvent($Writer, $Event) {
    $Writer.WriteLine((ConvertTo-Json -InputObject $Event -Depth 6 -Compress))
    $Writer.Flush()
    $Writer.BaseStream.Flush($true)
}
function New-MoveHistory([string]$Root) {
    $name = (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff') + '-' + [Guid]::NewGuid().ToString('N') + '.jsonl'
    $file = Join-Path (Join-Path $Root '.raw-star-sorter') $name
    $stream = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { Write-HistoryEvent $writer @{ Type = 'Header'; Version = 1; Root = $Root; CreatedUtc = [DateTime]::UtcNow.ToString('o') } }
    catch { $writer.Dispose(); throw }
    return [pscustomobject]@{ Path = $file; Writer = $writer }
}
function Read-MoveHistory([string]$File) {
    $events = [Collections.Generic.List[object]]::new()
    $lines = [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        try { $events.Add((ConvertFrom-Json -InputObject $lines[$i])) }
        catch {
            # A power loss may truncate the last append; intents are flushed before moving.
            if ($i -eq $lines.Count - 1) { Write-Warning "忽略操作记录末尾未写完的一行：$File" }
            else { throw "操作记录损坏，请人工检查：$File" }
        }
    }
    if (-not $events.Count -or $events[0].Type -ne 'Header' -or $events[0].Version -ne 1) { throw "不支持的操作记录：$File" }
    return ,$events
}
function Export-PlanCsv($Items, [string]$File) {
    $full = [IO.Path]::GetFullPath($File)
    if ([IO.Path]::GetExtension($full) -ne '.csv') { throw '清单文件必须以 .csv 结尾。' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) { throw "清单所在文件夹不存在：$full" }
    # CreateNew refuses existing files, including photos; quote formula-like cells for spreadsheet users.
    $rows = foreach ($item in $Items) {
        $row = [ordered]@{}
        foreach ($property in $item.PSObject.Properties) {
            $value = [string]$property.Value
            if ($value -match '^[=+@\-\t\r\n]') { $value = "'" + $value }
            $row[$property.Name] = $value
        }
        [pscustomobject]$row
    }
    $lines = if (@($rows).Count) { @($rows | ConvertTo-Csv -NoTypeInformation) } else { @('"Status"') }
    $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($true))
    try { foreach ($line in $lines) { $writer.WriteLine($line) } }
    finally { $writer.Dispose() }
    Write-Host "完整清单：$full"
}
