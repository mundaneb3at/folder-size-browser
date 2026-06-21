# Folder Size Browser

A tiny **Windows** tool that shows you **what's eating your disk space** — folder by
folder, biggest first — so you can hunt down the junk and clear it out. No install,
nothing to download but this, no cost.

> **It never deletes anything itself.** It only *shows you* where the space went.
> You delete what you want from File Explorer (press `O` to jump straight there).

## What it looks like

```
===== Folder Size Browser =====
 Location: C:\
 Total here: 393.0 GB   (7 folders, 2 loose files = 12.0 MB)

    #         Size     %  Chart       Name
    1   215.40 GB   55%  ##########  Windows
    2    90.10 GB   23%  ####......  Program Files
    3    60.20 GB   15%  ###.......  Users
    ...
 (+12 smaller folder(s) hidden - type a number to open any)

 Open #, or  u=up  b=back  r=rescan  o=explorer  q=quit
 > 2
```

**Type a folder's number** and press Enter to open it — you'll see *its* biggest
folders. Keep drilling until you find the culprit. The list shows the biggest folders
that fit your window; any smaller ones are summarised on the `(+N hidden)` line, and
you can still open those by typing their number.

## Get it

1. Click the green **Code** button at the top of this page → **Download ZIP**.
2. Unzip it anywhere (your Desktop is fine).

## Run it

**Double-click `Run Folder Size Browser.cmd`.** That's the whole thing.

> **First time only:** Windows SmartScreen may pop up "Windows protected your PC."
> Click **More info → Run anyway**. It's a plain text script — you can open it in
> Notepad to see exactly what it does. (It just reads folder sizes; it can't change
> or delete your files.)

The first scan of your whole C: drive takes about a minute — a progress bar means
it's working, not frozen. After that, moving around is instant.

Those sizes are **saved between runs**, so the next time you open it everything you
already scanned shows up instantly — no waiting for the big scan again. Saved sizes
are reused for up to two weeks, then re-checked automatically. Press `R` to refresh a
folder sooner (e.g. right after you delete something), or, for a full fresh scan, run
it from a terminal with `-Fresh`:

```
powershell -ExecutionPolicy Bypass -File ".\FindBigFiles.ps1" -Fresh
```

## Controls

Type your choice, then press **Enter**.

| Type | What it does |
|---|---|
| `1`, `2`, `3`… | open that folder (drill in) |
| `U` | up one level |
| `B` | back (previous folder) |
| `R` | re-scan this folder |
| `O` | open this folder in File Explorer (to delete from there) |
| `Q` | quit |

## Want a visual guide?

Open **`workflow.html`** in any browser for a illustrated walkthrough.

## License

Public domain ([Unlicense](./LICENSE)) — do whatever you want with it.
