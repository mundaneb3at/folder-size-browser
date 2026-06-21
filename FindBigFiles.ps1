<#
  Folder Size Browser  (FindBigFiles.ps1)
  ---------------------------------------
  An interactive terminal "file explorer" for disk usage. You start at a
  root (default C:\), see every sub-folder with its TOTAL size (everything
  inside it, recursively), sorted biggest-first with a small bar chart.
  Move the highlight with the arrow keys and press Enter to drill into a
  folder; the same view appears one level deeper. Walk the drive this way
  to hunt down what eats space.

  WHY robocopy for sizing:
    Summing a big tree with Get-ChildItem -Recurse is slow and chokes on
    junctions / permission errors (that is why AppData read as 0 before).
    robocopy in LIST-ONLY mode (/L = it copies NOTHING) walks the tree far
    faster, skips junctions with /XJ (no double-counting, no infinite
    loops), and prints an exact byte total we parse out.

  Controls (one keystroke each - NO Enter needed):
    Up / Down       move the highlight
    Enter / Right   open the highlighted folder (drill in)
    Left / Backspace  up one level (to parent)
    1-9             jump the highlight to that row
    B               back (previous folder visited)
    R re-scan this folder    O open in Explorer    Esc / Q quit

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

# Which row is highlighted (0-based). Persists across redraws.
$selectedIndex = 0

# When we go up/back, remember the folder we left so the parent view can
# re-highlight it ("you came from here") instead of jumping to the top.
$comeFrom = $null

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
# Resolve-Key - PURE input mapping. Given the key the user pressed plus the
#   current row count and highlighted index, decide the next index and which
#   ACTION the loop should take. Side-effect-free on purpose, so it can be
#   unit-tested headless (-SelfTest); the real [Console]::ReadKey lives below.
#   $Key needs two members: .Key (ConsoleKey name) and .KeyChar (the char).
#   Returns @{ Action = 'move|open|up|back|rescan|explorer|quit|none'; Index }
# ---------------------------------------------------------------------------
function Resolve-Key {
    param($Key, [int]$Count, [int]$Index)

    $last = [Math]::Max(0, $Count - 1)

    switch ([string]$Key.Key) {
        'UpArrow'    { return @{ Action = 'move'; Index = [Math]::Max(0, $Index - 1) } }
        'DownArrow'  { return @{ Action = 'move'; Index = [Math]::Min($last, $Index + 1) } }
        'Enter'      { return @{ Action = 'open'; Index = $Index } }
        'RightArrow' { return @{ Action = 'open'; Index = $Index } }
        'LeftArrow'  { return @{ Action = 'up';   Index = $Index } }
        'Backspace'  { return @{ Action = 'up';   Index = $Index } }
        'Escape'     { return @{ Action = 'quit'; Index = $Index } }
    }

    # Letters / digits come through KeyChar (the .Key name varies: D3, NumPad3...).
    $c = [string]$Key.KeyChar
    if ($c -match '^[0-9]$') {
        $d = [int]$c
        if ($d -ge 1 -and $d -le $Count) { return @{ Action = 'move'; Index = $d - 1 } }
        return @{ Action = 'none'; Index = $Index }
    }
    switch -Regex ($c) {
        '^[Qq]$'   { return @{ Action = 'quit';     Index = $Index } }
        '^[Bb]$'   { return @{ Action = 'back';     Index = $Index } }
        '^[Rr]$'   { return @{ Action = 'rescan';   Index = $Index } }
        '^[Oo]$'   { return @{ Action = 'explorer'; Index = $Index } }
    }
    return @{ Action = 'none'; Index = $Index }
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
# Built-in self-check for the key mapping (the one piece of real logic).
#   Run: powershell -ExecutionPolicy Bypass -File FindBigFiles.ps1 -SelfTest
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $script:fails = 0
    function Check($name, $ok) {
        if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
        else     { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
    }
    # Fake a keystroke: only .Key (name) and .KeyChar are read by Resolve-Key.
    function Key($name, $char) { [PSCustomObject]@{ Key = $name; KeyChar = $char } }

    Check "Down 0->1"                 ((Resolve-Key (Key 'DownArrow' ([char]0)) 5 0).Index -eq 1)
    Check "Down clamps at last"       ((Resolve-Key (Key 'DownArrow' ([char]0)) 5 4).Index -eq 4)
    Check "Up clamps at 0"            ((Resolve-Key (Key 'UpArrow'   ([char]0)) 5 0).Index -eq 0)
    Check "Enter = open current"      ((Resolve-Key (Key 'Enter'  ([char]13)) 5 2).Action -eq 'open')
    Check "Right = open"              ((Resolve-Key (Key 'RightArrow' ([char]0)) 5 2).Action -eq 'open')
    Check "Left = up"                 ((Resolve-Key (Key 'LeftArrow'  ([char]0)) 5 2).Action -eq 'up')
    Check "Backspace = up"            ((Resolve-Key (Key 'Backspace'  ([char]8)) 5 2).Action -eq 'up')
    Check "Esc = quit"                ((Resolve-Key (Key 'Escape' ([char]27)) 5 2).Action -eq 'quit')
    Check "q = quit"                  ((Resolve-Key (Key 'Q' 'q') 5 2).Action -eq 'quit')
    Check "digit 3 jumps to row 3"    ((Resolve-Key (Key 'D3' '3') 5 0).Index -eq 2 -and (Resolve-Key (Key 'D3' '3') 5 0).Action -eq 'move')
    Check "digit out of range = none" ((Resolve-Key (Key 'D9' '9') 5 1).Action -eq 'none')
    Check "digit 0 = none"            ((Resolve-Key (Key 'D0' '0') 5 1).Action -eq 'none')
    Check "b = back"                  ((Resolve-Key (Key 'B' 'b') 5 0).Action -eq 'back')
    Check "r = rescan"                ((Resolve-Key (Key 'R' 'r') 5 0).Action -eq 'rescan')
    Check "o = explorer"              ((Resolve-Key (Key 'O' 'o') 5 0).Action -eq 'explorer')
    Check "unknown keeps index"       ((Resolve-Key (Key 'Z' 'z') 5 2).Action -eq 'none' -and (Resolve-Key (Key 'Z' 'z') 5 2).Index -eq 2)
    Check "Down on empty stays 0"     ((Resolve-Key (Key 'DownArrow' ([char]0)) 0 0).Index -eq 0)

    # --- persistent cache: freshness window + a save/load round-trip ---
    $now = Get-Date
    Check "fresh entry kept"          (Test-EntryFresh $now.AddDays(-1)  $now 14)
    Check "stale entry dropped"       (-not (Test-EntryFresh $now.AddDays(-30) $now 14))
    $script:cacheDir  = $env:TEMP
    $script:cacheFile = Join-Path $env:TEMP ("fsb_selftest_{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0,6)))
    $script:sizeCache = @{ 'C:\' = [int64]123; $env:TEMP = [int64]456 }
    $script:sizeWhen  = @{ 'C:\' = $now;        $env:TEMP = $now }
    Save-Cache
    $script:sizeCache = @{}; $script:sizeWhen = @{}
    $restored = Import-Cache
    Check "round-trip restored 2"     ($restored -eq 2 -and $sizeCache['C:\'] -eq 123)

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
        # so moving the highlight around (everything cached) stays flicker-free.
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
        $selectedIndex = 0
    }
    else {
        # Sort biggest-first, then number the rows so the visible index matches the keys.
        # @() keeps it an array: a 1-element Sort-Object returns a scalar whose .Count
        # is $null, which would break the clamp/highlight/open guards below.
        $folderInfo = @($folderInfo | Sort-Object Bytes -Descending)
        $n = 1
        foreach ($row in $folderInfo) { $row.Index = $n; $n++ }

        # If we just came up/back from a child, highlight that child here.
        if ($comeFrom) {
            $m = $folderInfo | Where-Object { $_.FullPath -eq $comeFrom } | Select-Object -First 1
            if ($m) { $selectedIndex = $m.Index - 1 } else { $selectedIndex = 0 }  # gone? top.
            $comeFrom = $null
        }
        # Keep the highlight in range (folder counts change as you navigate).
        if ($selectedIndex -lt 0) { $selectedIndex = 0 }
        if ($selectedIndex -gt $folderInfo.Count - 1) { $selectedIndex = $folderInfo.Count - 1 }

        # Manual table render so the selected row can be highlighted.
        # ponytail: full Clear-Host + reprint each keypress; sizes are cached so
        # it stays snappy. Upgrade to partial redraw only if flicker bothers you.
        $selRow = $selectedIndex + 1
        Write-Host ("   {0,3}  {1,11}  {2,4}  {3,-10}  {4}" -f '#', 'Size', '%', 'Chart', 'Name') -ForegroundColor DarkGray
        foreach ($row in $folderInfo) {
            # Invariant integer percent 0-100 (no culture-sensitive {N0}).
            $pct  = if ($grandTotal -gt 0) { [Math]::Min(100, [int][Math]::Round(100 * $row.Bytes / $grandTotal)) } else { 0 }
            $size = (Format-Size $row.Bytes).Trim().PadLeft(11)
            $bar  = Get-Bar $row.Bytes $maxBytes
            # Trim very long names so the highlighted row can't wrap to a second line.
            $name = if ($row.Name.Length -gt 50) { $row.Name.Substring(0, 47) + '...' } else { $row.Name }
            $marker = if ($row.Index -eq $selRow) { '>' } else { ' ' }
            $text = (" {0} {1,3}  {2}  {3,3}%  {4}  {5}" -f $marker, $row.Index, $size, $pct, $bar, $name)
            if ($row.Index -eq $selRow) {
                Write-Host $text -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $text
            }
        }
    }

    # Tell the user when they're looking at saved (possibly stale) sizes, not a fresh scan.
    if ($uncached.Count -eq 0 -and $folderInfo.Count -gt 0) {
        Write-Host " (saved sizes from an earlier scan - press R to refresh this folder)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host " Up/Down select   Enter open   Left/Bksp up   1-9 jump   B back   R re-scan   O explorer   Esc/Q quit" -ForegroundColor Cyan

    # Read ONE keystroke (no Enter). Needs a real console window; piping input or
    # running in the ISE has no key reader, so fail with a clear hint instead of
    # an ugly exception.
    try {
        $key = [Console]::ReadKey($true)
    } catch {
        Write-Host ""
        Write-Host " This tool needs a real console window." -ForegroundColor Yellow
        Write-Host " Double-click 'Run Folder Size Browser.cmd' (don't pipe input or use the ISE)." -ForegroundColor Yellow
        return
    }

    $act = Resolve-Key -Key $key -Count $folderInfo.Count -Index $selectedIndex
    switch ($act.Action) {
        'move'     { $selectedIndex = $act.Index }
        'open'     {
            if ($folderInfo.Count -gt 0) {
                $sel = $folderInfo | Where-Object { $_.Index -eq ($act.Index + 1) } | Select-Object -First 1
                if ($sel) { $history.Push($Path); $Path = $sel.FullPath; $selectedIndex = 0 }
            }
        }
        'up'       {
            $parent = Split-Path -Parent $Path
            if ($parent) { $comeFrom = $Path; $history.Push($Path); $Path = $parent }
            # no parent = already at the top of the drive: ignore
        }
        'back'     {
            if ($history.Count -gt 0) { $comeFrom = $Path; $Path = $history.Pop() }
        }
        'rescan'   {
            # Drop cached sizes for THIS folder and its sub-folders, then redraw to
            # recompute - so the parent view also refreshes this folder's total.
            [void]$sizeCache.Remove($Path)
            foreach ($row in $folderInfo) { [void]$sizeCache.Remove($row.FullPath) }
        }
        'explorer' { & explorer.exe $Path }
        'quit'     { Write-Progress -Activity 'done' -Completed; return }
        'none'     { }
    }
}
