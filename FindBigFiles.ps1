<#
  Folder Size Browser  (FindBigFiles.ps1)
  ---------------------------------------
  An interactive terminal "file explorer" for disk usage. You start at a
  root (default C:\), see every sub-folder with its TOTAL size (everything
  inside it, recursively), sorted biggest-first with a small bar chart.
  Type a folder's number and press Enter to drill into it; the same view
  appears one level deeper. Walk the drive this way to hunt down what eats
  space.

  WHY robocopy for sizing:
    Summing a big tree with Get-ChildItem -Recurse is slow and chokes on
    junctions / permission errors (that is why AppData read as 0 before).
    robocopy in LIST-ONLY mode (/L = it copies NOTHING) walks the tree far
    faster, skips junctions with /XJ (no double-counting, no infinite
    loops), and prints an exact byte total we parse out.

  Controls (type the input, then press Enter):
    1, 2, 3 ...  open that folder (drill in)
    U            up one level (to parent)
    B            back (previous folder visited)
    R re-scan this folder    O open in Explorer    Q quit

  Sizes are SAVED between runs to %LOCALAPPDATA%\FolderSizeBrowser\sizecache.json,
  so re-opening the tool is instant for anything already scanned. A saved size is
  reused for up to 14 days, then re-scanned automatically. Press R to refresh a
  folder now, or launch with -Fresh to ignore the cache and scan from scratch.
#>

param(
    # Where the browser opens. Default is the whole C: drive.
    [ValidateNotNullOrEmpty()]
    [string]$Path = "C:\",
    # Run the built-in logic self-check and exit (no UI). Used to verify edits.
    [switch]$SelfTest,
    # Ignore the saved cache and scan everything from scratch.
    [switch]$Fresh
)

# Size cache: folder full path -> bytes. Makes Back / re-visits instant, and is
# SAVED to disk so re-opening the tool does not re-scan everything.
$sizeCache = @{}            # folder path -> bytes
$sizeWhen  = @{}            # folder path -> when it was measured (for staleness)

# Persistent cache file + how long (days) a saved size may be reused before re-scan.
$CacheMaxAgeDays = 14
$cacheDir  = Join-Path $env:LOCALAPPDATA 'FolderSizeBrowser'
$cacheFile = Join-Path $cacheDir 'sizecache.json'

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
    $sizeWhen[$FolderPath]  = Get-Date     # stamp so we can age it out across runs
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

# ---------------------------------------------------------------------------
# Resolve-Choice - PURE input mapping for the typed line. Given what the user
#   typed plus the number of folders, decide what to do. Side-effect-free so it
#   can be unit-tested headless (-SelfTest).
#   Returns @{ Action = 'open|up|back|rescan|explorer|quit|none|bad'; Index }
#   where Index (for 'open') is the 1-based folder number the user picked.
# ---------------------------------------------------------------------------
function Resolve-Choice {
    param([string]$Text, [int]$Count)

    $t = "$Text".Trim()
    if ($t -eq '') { return @{ Action = 'none'; Index = 0 } }

    if ($t -match '^\d+$') {
        $n = [int]$t
        if ($n -ge 1 -and $n -le $Count) { return @{ Action = 'open'; Index = $n } }
        return @{ Action = 'bad'; Index = 0 }      # number with no matching folder
    }
    switch -Regex ($t) {
        '^[Uu]$' { return @{ Action = 'up';       Index = 0 } }
        '^[Bb]$' { return @{ Action = 'back';     Index = 0 } }
        '^[Rr]$' { return @{ Action = 'rescan';   Index = 0 } }
        '^[Oo]$' { return @{ Action = 'explorer'; Index = 0 } }
        '^[Qq]$' { return @{ Action = 'quit';     Index = 0 } }
    }
    return @{ Action = 'bad'; Index = 0 }
}

# ---------------------------------------------------------------------------
# Persistent size cache - load saved folder sizes on startup, write them on the
# way out, so the slow first scan is not repeated every time the tool opens.
# ---------------------------------------------------------------------------

# True if a size measured at $At is still young enough to reuse.
function Test-EntryFresh {
    param([datetime]$At, [datetime]$Now, [int]$MaxAgeDays)
    return ($Now - $At).TotalDays -lt $MaxAgeDays
}

# Load saved sizes, dropping anything stale or whose folder no longer exists.
# Best-effort: a missing or corrupt file just means we start empty. Returns the
# number of entries restored.
function Import-Cache {
    if (-not (Test-Path -LiteralPath $cacheFile)) { return 0 }
    $loaded = 0
    try {
        $now  = Get-Date
        $data = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($e in @($data)) {
            if (-not $e.Path) { continue }
            $at = [datetime]$e.At
            if (-not (Test-EntryFresh $at $now $CacheMaxAgeDays)) { continue }   # too old
            if (-not (Test-Path -LiteralPath $e.Path)) { continue }              # folder gone
            $sizeCache[[string]$e.Path] = [int64]$e.Bytes
            $sizeWhen[[string]$e.Path]  = $at
            $loaded++
        }
    } catch { return 0 }
    return $loaded
}

# Write the whole cache to disk as UTF-8 JSON.
# ponytail: rewrites the entire file each save - fine for a personal cache of a
# few thousand folders; switch to incremental/SQLite only if it ever gets big.
function Save-Cache {
    try {
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $rows = foreach ($k in $sizeCache.Keys) {
            [PSCustomObject]@{
                Path  = $k
                Bytes = $sizeCache[$k]
                At    = (&{ if ($sizeWhen.ContainsKey($k)) { $sizeWhen[$k] } else { Get-Date } }).ToString('o')
            }
        }
        $json = @($rows) | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($cacheFile, $json, [System.Text.Encoding]::UTF8)
    } catch { }   # caching is best-effort; never let a save error break the UI
}

# ---------------------------------------------------------------------------
# Built-in self-check for the input logic (the one piece of real logic).
#   Run: powershell -ExecutionPolicy Bypass -File FindBigFiles.ps1 -SelfTest
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $script:fails = 0
    function Check($name, $ok) {
        if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
        else     { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
    }

    Check "empty = none"           ((Resolve-Choice '' 5).Action -eq 'none')
    Check "3 opens folder 3"       ((Resolve-Choice '3' 5).Action -eq 'open' -and (Resolve-Choice '3' 5).Index -eq 3)
    Check "whitespace trimmed"     ((Resolve-Choice '  2 ' 5).Action -eq 'open' -and (Resolve-Choice '  2 ' 5).Index -eq 2)
    Check "12 opens folder 12"     ((Resolve-Choice '12' 28).Action -eq 'open' -and (Resolve-Choice '12' 28).Index -eq 12)
    Check "9 of 5 = bad"           ((Resolve-Choice '9' 5).Action -eq 'bad')
    Check "0 = bad"                ((Resolve-Choice '0' 5).Action -eq 'bad')
    Check "u = up"                 ((Resolve-Choice 'u' 5).Action -eq 'up')
    Check "B = back"               ((Resolve-Choice 'B' 5).Action -eq 'back')
    Check "r = rescan"             ((Resolve-Choice 'r' 5).Action -eq 'rescan')
    Check "O = explorer"           ((Resolve-Choice 'O' 5).Action -eq 'explorer')
    Check "q = quit"               ((Resolve-Choice 'q' 5).Action -eq 'quit')
    Check "x = bad"                ((Resolve-Choice 'x' 5).Action -eq 'bad')

    # --- persistent cache: freshness window + a save/load round-trip ---
    $now = Get-Date
    Check "fresh entry kept"       (Test-EntryFresh $now.AddDays(-1)  $now 14)
    Check "stale entry dropped"    (-not (Test-EntryFresh $now.AddDays(-30) $now 14))
    $script:cacheDir  = $env:TEMP
    $script:cacheFile = Join-Path $env:TEMP ("fsb_selftest_{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0,6)))
    $script:sizeCache = @{ 'C:\' = [int64]123; $env:TEMP = [int64]456 }
    $script:sizeWhen  = @{ 'C:\' = $now;        $env:TEMP = $now }
    Save-Cache
    $script:sizeCache = @{}; $script:sizeWhen = @{}
    $restored = Import-Cache
    Check "round-trip restored 2"  ($restored -eq 2 -and $sizeCache['C:\'] -eq 123)

    Write-Host ""
    if ($script:fails -eq 0) { Write-Host "ALL PASS" -ForegroundColor Green; exit 0 }
    else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
}

# Restore saved sizes so a re-open is instant for already-scanned folders.
if (-not $Fresh) { [void](Import-Cache) }

while ($true) {
    Clear-Host

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Path no longer exists: $Path" -ForegroundColor Red
        $Path = "C:\"
        Start-Sleep -Milliseconds 1500
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
    $uncached = @()
    if ($dirs) {
        # Only show the scanning banner/progress for folders we haven't sized yet,
        # so re-visiting cached folders stays instant and quiet.
        $uncached = @($dirs | Where-Object { -not $sizeCache.ContainsKey($_.FullName) })
        if ($uncached.Count -gt 0) {
            Write-Host " Scanning $($uncached.Count) folder(s)... (first scan of a big folder can take a bit)" -ForegroundColor DarkGray
        }
        $i = 0
        foreach ($d in $dirs) {
            $i++
            if (-not $sizeCache.ContainsKey($d.FullName)) {
                Write-Progress -Activity "Sizing folders in $Path" -Status "$i / $($dirs.Count): $($d.Name)" -PercentComplete (100 * $i / $dirs.Count)
            }
            $size = Get-FolderSize -FolderPath $d.FullName
            $folderInfo += [PSCustomObject]@{
                Index    = 0
                Name     = $d.Name
                Bytes    = $size
                FullPath = $d.FullName
            }
        }
        Write-Progress -Activity "Sizing folders" -Completed
        if ($uncached.Count -gt 0) { Save-Cache }   # persist the freshly-measured sizes
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
        # Sort biggest-first, then number the rows so the printed number = what you type.
        # @() keeps it an array: a 1-element Sort-Object returns a scalar whose .Count
        # is $null, which would break the count math below.
        $folderInfo = @($folderInfo | Sort-Object Bytes -Descending)
        $n = 1
        foreach ($row in $folderInfo) { $row.Index = $n; $n++ }

        # Show only as many rows as fit the window, so a long list never scrolls the
        # biggest folders off the top. Sorted biggest-first, so the top is what matters.
        # ponytail: static draw-once-per-page (no live cursor); numbers reach any folder.
        $winH = try { [Console]::WindowHeight } catch { 25 }
        if ($winH -lt 12) { $winH = 25 }
        $maxRows = [Math]::Max(5, $winH - 11)   # 11 = header/total/notes/prompt overhead
        $shown   = @($folderInfo | Select-Object -First $maxRows)

        Write-Host ("  {0,3}  {1,11}  {2,4}  {3,-10}  {4}" -f '#', 'Size', '%', 'Chart', 'Name') -ForegroundColor DarkGray
        foreach ($row in $shown) {
            # Invariant integer percent 0-100 (no culture-sensitive {N0}).
            $pct  = if ($grandTotal -gt 0) { [Math]::Min(100, [int][Math]::Round(100 * $row.Bytes / $grandTotal)) } else { 0 }
            $size = (Format-Size $row.Bytes).Trim().PadLeft(11)
            $bar  = Get-Bar $row.Bytes $maxBytes
            # Trim very long names so a row can't wrap to a second line.
            $name = if ($row.Name.Length -gt 50) { $row.Name.Substring(0, 47) + '...' } else { $row.Name }
            Write-Host ("  {0,3}  {1}  {2,3}%  {3}  {4}" -f $row.Index, $size, $pct, $bar, $name)
        }
        if ($folderInfo.Count -gt $shown.Count) {
            $hidden = $folderInfo.Count - $shown.Count
            Write-Host (" (+{0} smaller folder(s) hidden - type a number to open any)" -f $hidden) -ForegroundColor DarkGray
        }
    }

    # Tell the user when they're looking at saved (possibly stale) sizes, not a fresh scan.
    if ($uncached.Count -eq 0 -and $folderInfo.Count -gt 0) {
        Write-Host " (saved sizes from an earlier scan - press R to refresh this folder)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host " Open #, or  u=up  b=back  r=rescan  o=explorer  q=quit" -ForegroundColor Cyan
    $choice = Read-Host " >"

    $act = Resolve-Choice -Text $choice -Count $folderInfo.Count
    switch ($act.Action) {
        'open'     {
            $sel = $folderInfo | Where-Object { $_.Index -eq $act.Index } | Select-Object -First 1
            if ($sel) { $history.Push($Path); $Path = $sel.FullPath }
        }
        'up'       {
            $parent = Split-Path -Parent $Path
            if ($parent) { $history.Push($Path); $Path = $parent }
            else { Write-Host " Already at the top." -ForegroundColor DarkGray; Start-Sleep -Milliseconds 800 }
        }
        'back'     {
            if ($history.Count -gt 0) { $Path = $history.Pop() }
            else { Write-Host " No previous folder." -ForegroundColor DarkGray; Start-Sleep -Milliseconds 800 }
        }
        'rescan'   {
            # Drop cached sizes for THIS folder and its sub-folders, then redraw to
            # recompute - so the parent view also refreshes this folder's total.
            [void]$sizeCache.Remove($Path)
            foreach ($row in $folderInfo) { [void]$sizeCache.Remove($row.FullPath) }
        }
        'explorer' { & explorer.exe $Path }
        'quit'     { Write-Progress -Activity 'done' -Completed; return }
        'bad'      { Write-Host " Type a folder number or u/b/r/o/q." -ForegroundColor DarkGray; Start-Sleep -Milliseconds 800 }
        'none'     { }   # empty input = just redraw
    }
}
