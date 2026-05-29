<#
  Folder Size Browser  (FindBigFiles.ps1)
  ---------------------------------------
  An interactive terminal "file explorer" for disk usage. You start at a
  root (default C:\), see every sub-folder with its TOTAL size (everything
  inside it, recursively), sorted biggest-first with a small bar chart.
  Type a number to open that folder and drill down; the same view appears
  one level deeper. Walk the drive this way to hunt down what eats space.

  WHY robocopy for sizing:
    Summing a big tree with Get-ChildItem -Recurse is slow and chokes on
    junctions / permission errors (that is why AppData read as 0 before).
    robocopy in LIST-ONLY mode (/L = it copies NOTHING) walks the tree far
    faster, skips junctions with /XJ (no double-counting, no infinite
    loops), and prints an exact byte total we parse out.

  Controls:  [number] open folder   U up a level   B back (history)
             R re-scan this folder   O open in Explorer   Q quit
#>

param(
    # Where the browser opens. Default is the whole C: drive.
    [string]$Path = "C:\"
)

# Size cache: folder full path -> bytes. Makes Back / re-visits instant.
$sizeCache = @{}

# Remember where we came from, for [B]ack.
$history = New-Object 'System.Collections.Generic.Stack[string]'

# ---------------------------------------------------------------------------
# Get-FolderSize - total bytes inside a folder (recursive), via robocopy /L.
#   /L     list only (NEVER remove this - without it, source==dest would be
#                     a real copy operation)
#   /E     recurse into all subfolders
#   /BYTES raw byte counts (easy to parse)
#   /XJ    skip junctions & symlinks (avoids double-count / loops)
#   /NFL /NDL /NJH /NC /NP  trim output down to just the summary block
# ---------------------------------------------------------------------------
function Get-FolderSize {
    param([string]$FolderPath)

    if ($sizeCache.ContainsKey($FolderPath)) { return $sizeCache[$FolderPath] }

    $bytes = 0
    try {
        $out  = robocopy $FolderPath $FolderPath /L /E /BYTES /NFL /NDL /NJH /NC /NP /XJ 2>$null
        $line = $out | Where-Object { $_ -match 'Bytes :' } | Select-Object -First 1
        if ($line -match 'Bytes :\s+(\d+)') { $bytes = [int64]$matches[1] }
    } catch {
        $bytes = 0
    }

    $sizeCache[$FolderPath] = $bytes
    return $bytes
}

# Human-readable size string (B / KB / MB / GB / TB), right-padded for columns.
function Format-Size {
    param([int64]$Bytes)
    if     ($Bytes -ge 1TB) { '{0,8:N2} TB' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0,8:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0,8:N2} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0,8:N1} KB' -f ($Bytes / 1KB) }
    else                    { '{0,8} B'  -f  $Bytes }
}

# A 10-char bar, scaled so the biggest sibling fills it (visual size compare).
function Get-Bar {
    param([int64]$Value, [int64]$Max)
    if ($Max -le 0) { return ('.' * 10) }
    $filled = [int][math]::Round(10 * $Value / $Max)
    if ($filled -gt 10) { $filled = 10 }
    if ($filled -lt 0)  { $filled = 0 }
    ('#' * $filled) + ('.' * (10 - $filled))
}

while ($true) {
    Clear-Host

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Path no longer exists: $Path" -ForegroundColor Red
        $Path = "C:\"
        Start-Sleep -Seconds 1.5
        continue
    }

    Write-Host "===== Folder Size Browser =====" -ForegroundColor Cyan
    Write-Host (" Location: {0}" -f $Path) -ForegroundColor White

    # Immediate sub-folders.
    $dirs = Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue

    # Immediate files at this level (shown as a summary line, not in the table).
    $fileAgg   = Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum
    $fileBytes = [int64]($fileAgg.Sum)
    $fileCount = [int]($fileAgg.Count)

    $folderInfo = @()
    if ($dirs) {
        Write-Host " Scanning $($dirs.Count) folders... (first scan of a big folder can take a bit)" -ForegroundColor DarkGray
        $i = 0
        foreach ($d in $dirs) {
            $i++
            Write-Progress -Activity "Sizing folders in $Path" -Status "$i / $($dirs.Count): $($d.Name)" -PercentComplete (100 * $i / $dirs.Count)
            $size = Get-FolderSize -FolderPath $d.FullName
            $folderInfo += [PSCustomObject]@{
                Index    = 0
                Name     = $d.Name
                Bytes    = $size
                FullPath = $d.FullName
            }
        }
        Write-Progress -Activity "Sizing folders" -Completed
    }

    # Totals for this level.
    $subTotal = ($folderInfo | Measure-Object Bytes -Sum).Sum
    if ($null -eq $subTotal) { $subTotal = 0 }
    $grandTotal = [int64]$subTotal + $fileBytes
    $maxBytes = ($folderInfo | Measure-Object Bytes -Maximum).Maximum
    if ($null -eq $maxBytes) { $maxBytes = 0 }

    Write-Host (" Total here: {0}   ({1} folders, {2} loose files = {3})" -f (Format-Size $grandTotal).Trim(), $folderInfo.Count, $fileCount, (Format-Size $fileBytes).Trim()) -ForegroundColor Yellow
    Write-Host ""

    if (-not $folderInfo -or $folderInfo.Count -eq 0) {
        Write-Host " (no sub-folders here)" -ForegroundColor DarkGray
    }
    else {
        # Sort biggest-first, then number the rows so the visible Index matches selection.
        $folderInfo = $folderInfo | Sort-Object Bytes -Descending
        $n = 1
        foreach ($row in $folderInfo) { $row.Index = $n; $n++ }

        $folderInfo |
            Select-Object `
                Index,
                @{N='Size';  E={ Format-Size $_.Bytes }},
                @{N='%';     E={ if ($grandTotal -gt 0) { '{0,3:N0}' -f (100 * $_.Bytes / $grandTotal) } else { '  0' } }},
                @{N='Chart'; E={ Get-Bar $_.Bytes $maxBytes }},
                Name |
            Format-Table -AutoSize | Out-Host
    }

    Write-Host ""
    Write-Host " [number] open   U up   B back   R re-scan   O explorer   Q quit" -ForegroundColor Cyan
    $choice = Read-Host " >"

    switch -Regex ($choice) {
        '^\s*$'   { break }                                  # empty = just redraw
        '^[Qq]$'  { Write-Progress -Activity 'done' -Completed; return }
        '^[Uu]$'  {
            $parent = Split-Path -Parent $Path
            if ($parent) { $history.Push($Path); $Path = $parent }
            else { Write-Host " Already at the top." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
            break
        }
        '^[Bb]$'  {
            if ($history.Count -gt 0) { $Path = $history.Pop() }
            else { Write-Host " No previous folder." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
            break
        }
        '^[Rr]$'  {
            # Drop cached sizes for the current sub-folders, then redraw to recompute.
            foreach ($row in $folderInfo) { [void]$sizeCache.Remove($row.FullPath) }
            break
        }
        '^[Oo]$'  { & explorer.exe $Path; break }
        '^\d+$'   {
            $sel = $folderInfo | Where-Object { $_.Index -eq [int]$choice }
            if ($sel) { $history.Push($Path); $Path = $sel.FullPath }
            else { Write-Host " No folder with that number." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
            break
        }
        default   { Write-Host " Unknown option." -ForegroundColor DarkGray; Start-Sleep -Seconds 1; break }
    }
}
