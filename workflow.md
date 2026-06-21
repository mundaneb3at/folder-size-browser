---
name: folder-size-browser
description: "Interactive terminal disk-usage explorer for Windows. Opens at any root (default the C: drive), lists every sub-folder's total recursive size biggest-first with a bar chart, and lets you drill in by number to find what is eating disk space."
metadata:
  type: tool
  surface: terminal
  platform: windows
  external_dependencies: [powershell, robocopy]
---

# Folder Size Browser (AI-readable copy)

This is the AI-readable twin of [`workflow.html`](./workflow.html). Drop this file into a memory system, paste it into a chat, or feed it to an agent that needs to reproduce or extend the tool. The HTML version is the same content rendered for human eyes.

## What this does

A single PowerShell script (`FindBigFiles.ps1`) turns the terminal into a drill-down disk-usage explorer:

1. **Opens at a root** — the C: drive by default, or any path via `-Path`.
2. **Lists every sub-folder with its TOTAL size** (everything inside it, recursively), sorted biggest-first, with a `%`-of-parent column and a small bar chart.
3. **Drill down** — arrow-key the highlight onto a folder and press Enter to open it (or press its number); the same view appears one level deeper. Walk the whole drive this way to find what is eating space. Every key acts on the single keystroke — no Enter needed.

No install and no dependencies beyond what already ships with Windows (PowerShell + robocopy).

## Usage

```powershell
# Open at C:\ (default)
powershell -ExecutionPolicy Bypass -File "<path>\FindBigFiles.ps1"

# Open somewhere specific
powershell -ExecutionPolicy Bypass -File "<path>\FindBigFiles.ps1" -Path "D:\"

# Ignore the saved cache and scan everything from scratch
powershell -ExecutionPolicy Bypass -File "<path>\FindBigFiles.ps1" -Fresh
```

## Controls

| Key | Action |
|---|---|
| `Up` / `Down` | move the highlight |
| `Enter` / `Right` | open the highlighted folder (drill down) |
| `Left` / `Backspace` | up one level (to parent) |
| `1`-`9` | jump straight to that folder |
| `B` | back (previous folder visited) |
| `R` | re-scan current folder (clears cached sizes) |
| `O` | open current folder in File Explorer |
| `Esc` / `Q` | quit |

## Architecture / how sizing works

- **robocopy in list-only mode does the recursive byte-summing**, NOT `Get-ChildItem -Recurse`. `robocopy /L` walks the tree without copying anything, is far faster on large trees, and reports an exact byte total that the script parses from the summary line.
- **`/XJ` skips junctions and symlinks** — no double-counting, no infinite loops. (Plain `Get-ChildItem -Recurse` follows junctions, which is why a naive scan reported `AppData` as 0 and inflated other folders.)
- **Size cache** — a hashtable keyed by folder path, **persisted to `%LOCALAPPDATA%\FolderSizeBrowser\sizecache.json`** so re-opening the tool does not repeat the slow first scan. Folders already measured return instantly on `Back` / re-visit; on load, entries older than 14 days (or whose folder no longer exists) are dropped and re-scanned. `R` drops the current folder's cached entries to force a fresh scan; `-Fresh` ignores the saved cache entirely. Writes are best-effort (a corrupt/missing file just starts empty).
- **Progress bar** — `Write-Progress` shows which sub-folder is being sized, so a big first scan of `C:\` does not look frozen.

## File inventory

```
folder-size-browser/
├── README.md            # links to the two docs below
├── workflow.md          # this file (AI-readable)
├── workflow.html        # human visual twin
├── FindBigFiles.ps1     # the script
├── LICENSE              # public domain (Unlicense)
└── .gitattributes
```

## Failure modes to avoid

- **Never remove `/L` from the robocopy call.** It is what makes the command list-only. Without it, `robocopy <src> <src>` would attempt a real copy operation of the folder onto itself.
- **`C:\Windows` can read slightly high.** `WinSxS` uses hard-links that robocopy counts per-link. Every disk-usage tool shares this quirk; it does not affect your personal folders.
- **Don't swap robocopy back to `Get-ChildItem -Recurse` for sizing.** It is slower and follows junctions (double-count / infinite-loop risk). Avoiding that is the whole point of the robocopy engine.
- **The first scan of a huge root is not instant.** Sizing `C:\Windows` and friends takes about a minute; the progress bar proves it is working. Sizes are cached afterward, so navigating back is snappy.

## Possible extensions (ideas, not built)

These are not implemented — they are notes for anyone who wants to extend the tool.

- **Sort toggle** — add an `S` key to flip between size-descending and name order.
- **Min-size filter** — hide folders under a threshold (e.g. 100 MB) to cut clutter at the root.
- **Non-interactive snapshot** — a `-Report` switch that prints one level's table and exits (for piping / logging) instead of the interactive loop.
- **CSV export** — dump the current level's `Name,Bytes` to a file for spreadsheeting.

## Related

- Companion HTML view: [`workflow.html`](./workflow.html) — same content, designed for humans.
- Dual-artifact pattern (AI `.md` + human `.html`) borrowed from the sibling `phone-ping` project.
