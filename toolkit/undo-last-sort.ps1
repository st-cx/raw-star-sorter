#requires -Version 5.1
[CmdletBinding()]
param([string]$Path = $PSScriptRoot, [switch]$DryRun, [switch]$PassThru)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'workflow-common.ps1')
$root = (Get-Item -LiteralPath $Path).FullName
$historyDirectory = Assert-LocalPath $root (Join-Path $root '.raw-star-sorter')
if (-not [IO.Directory]::Exists($historyDirectory)) { throw '没有可撤销的星级归类记录。' }
$lock = $null
$writer = $null
try {
    if (-not $DryRun) { $lock = Open-WorkflowLock $root }
    $selected = $null
    foreach ($file in Get-ChildItem -LiteralPath $historyDirectory -Filter '*.jsonl' -File | Sort-Object Name -Descending) {
        $null = Assert-LocalPath $root $file.FullName
        if (Test-Path -LiteralPath ($file.FullName + '.undone')) { continue }
        $events = Read-MoveHistory $file.FullName
        if (@($events | Where-Object { $_.Type -eq 'Undone' }).Count) { continue }
        $selected = $file
        break
    }
    if (-not $selected) { throw '没有可撤销的星级归类记录。' }
    if ($events[0].Root -ne $root) { throw '照片目录已经改名或移动，不能自动套用旧操作记录。' }
    $intents = @($events | Where-Object { $_.Type -eq 'Move' })
    $completed = @{}
    foreach ($event in $events) { if ($event.Type -eq 'Moved') { $completed[[int]$event.Id] = $true } }
    $moves = [Collections.Generic.List[object]]::new()
    $seenFrom = @{}
    $seenTo = @{}
    foreach ($entry in $intents) {
        $from = Assert-LocalPath $root ([string]$entry.From)
        $to = Assert-LocalPath $root ([string]$entry.To)
        if ($from -eq $to -or $seenFrom.ContainsKey($from) -or $seenTo.ContainsKey($to) -or
            $from.StartsWith($historyDirectory + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $to.StartsWith($historyDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '操作记录包含重复或无效路径。' }
        $seenFrom[$from] = $true; $seenTo[$to] = $true
        if ([IO.File]::Exists($from) -and -not (Test-Path -LiteralPath $to)) { continue }
        if ((Test-Path -LiteralPath $from) -or -not [IO.File]::Exists($to)) {
            throw "无法撤销，原位置已被占用或目标文件丢失，未移动任何文件：$to -> $from"
        }
        # Completed moves preserve later edits. An interrupted, unconfirmed move needs its original identity.
        if (-not $completed.ContainsKey([int]$entry.Id)) {
            $item = Get-Item -LiteralPath $to -Force
            if ($item.Length -ne $entry.Length -or $item.LastWriteTimeUtc.Ticks -ne $entry.ModifiedTicks) { throw "中断记录与文件不符，请人工检查：$to" }
        }
        $moves.Add([pscustomobject]@{ From = $to; To = $from })
    }
    Write-Host "撤销记录：$($selected.Name)；待还原文件：$($moves.Count)"
    Write-Host '仅还原文件位置，保留当前文件内容；不会撤回标签编辑、首次匹配分类或精选复制。'
    $restored = 0
    if ($DryRun) { foreach ($move in $moves) { Write-Host "$($move.From) -> $($move.To)" } }
    else {
        # Reconcile locations on every retry; even a stopped undo is resumable.
        for ($i = $moves.Count - 1; $i -ge 0; $i--) {
            $move = $moves[$i]
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($move.To)) | Out-Null
            [IO.File]::Move($move.From, $move.To)
            $restored++
        }
        $marker = Assert-LocalPath $root ($selected.FullName + '.undone')
        $stream = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        Write-HistoryEvent $writer @{ Type = 'Undone'; Restored = $restored; AtUtc = [DateTime]::UtcNow.ToString('o') }
        Write-Host "撤销完成：还原 $restored 个文件。" -ForegroundColor Green
    }
    if ($PassThru) { [pscustomobject]@{ Planned = $moves.Count; Restored = $restored; DryRun = [bool]$DryRun; HistoryPath = $selected.FullName } }
}
finally { if ($writer) { $writer.Dispose() }; if ($lock) { $lock.Dispose() } }
