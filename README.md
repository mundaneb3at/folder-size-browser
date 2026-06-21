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
 >   1   215.40 GB   55%  ##########  Windows
     2    90.10 GB   23%  ####......  Program Files
     3    60.20 GB   15%  ###.......  Users
     ...

 Up/Down select   Enter open   Left/Bksp up   1-9 jump   B back   R re-scan   O explorer   Esc/Q quit
```

The `>` row is highlighted. **Arrow down** to a folder and press **Enter** to open
it — you'll see *its* biggest folders. Keep drilling until you find the culprit.
Every key acts the moment you press it; you never hit Enter to "submit".

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

## Controls

All single keystrokes — no Enter needed.

| Key | What it does |
|---|---|
| `↑` / `↓` | move the highlight |
| `Enter` or `→` | open the highlighted folder (drill down) |
| `←` or `Backspace` | up one level |
| `1`–`9` | jump straight to that folder |
| `B` | back (previous folder) |
| `R` | re-scan this folder |
| `O` | open this folder in File Explorer (to delete from there) |
| `Esc` or `Q` | quit |

## Want a visual guide?

Open **`workflow.html`** in any browser for a illustrated walkthrough.

## License

Public domain ([Unlicense](./LICENSE)) — do whatever you want with it.
