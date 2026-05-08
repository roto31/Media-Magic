# MediaVault — Native Swift macOS App

A real native macOS application that orchestrates the four-stage video
conversion pipeline (MakeMKV → HandBrake → FileBot → SublerCli) with a
SwiftUI interface and live progress tracking.

```
Sources/MediaVault/
├── MediaVaultApp.swift      ← @main app entry, window scene
├── ContentView.swift        ← SwiftUI UI: setup card, queue, summary sheet
├── PipelineController.swift ← state machine, process orchestration, log
└── ToolManager.swift        ← tool discovery, on-demand HandBrakeCLI download

build.sh                     ← compiles to ./build/MediaVault.app
```

## What it does differently from the bash version

- **Compiled native binary.** No interpreter; one Mach-O executable inside the
  .app bundle. Boots in ~100ms.
- **Live HandBrake progress bar.** Parses `Encoding: ... 12.34 %` output in real
  time and drives an `NSProgressIndicator`. Same for MakeMKV's `PRGV:` lines.
- **Real `NSOpenPanel` and `UNUserNotificationCenter`** — not osascript
  modal dialogs. The window stays interactive throughout.
- **First-launch tool fetching.** On first run, downloads HandBrakeCLI from the
  official GitHub release into `~/Library/Application Support/MediaVault/bin/`.
  No Homebrew required for that one tool. SublerCli, MakeMKV, and FileBot are
  located if installed; the app explains how to install whichever one is
  missing.
- **Per-item error recovery.** A failure on item 2 of 5 logs the error and
  continues with items 3–5; the summary sheet at the end separates successes
  from failures.

## Why HandBrakeCLI is downloaded but the others aren't

HandBrakeCLI ships an official `.dmg` at predictable URLs on GitHub
(`https://github.com/HandBrake/HandBrake/releases/download/<version>/HandBrakeCLI-<version>.dmg`),
which makes auto-fetch trivially safe. SublerCli's distribution lives on
Bitbucket and has no stable redistribution URL pattern across versions, so the
app surfaces a clear install instruction instead. MakeMKV requires a license key
from MakeMKV.com; FileBot has its own paid licensing model. Auto-downloading
either of those would be impolite at best and a license violation at worst.

## Build

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
chmod +x build.sh
./build.sh release           # compiles ./build/MediaVault.app
open build/MediaVault.app    # or: cp -R build/MediaVault.app /Applications/
```

For a debug build with symbols: `./build.sh` (no args).
For ad-hoc codesigning: `./build.sh release sign`.

The resulting `.app` is ~1 MB. On first launch it fetches HandBrakeCLI
(~25 MB) into Application Support; every subsequent launch is instant.

## Required user-installed tools

Auto-downloaded on first launch — nothing needed:
- HandBrakeCLI

Looked up on standard paths; install separately:
- **MakeMKV** — `brew install --cask makemkv`  (needed for Blu-ray only)
- **FileBot** — `brew install --cask filebot`   (rename stage; pipeline still runs without it, just skips rename)
- **SublerCli** — `brew install --cask sublercli`

If anything's missing, the tooltip on the green/orange status indicator in the
top-right of the window shows exactly which tools were resolved and where.

## Pipeline flow

1. **Setup card** — pick source type (Video File / DVD / Blu-ray), source
   path(s), and output directory. For Blu-ray, also pick a working folder for
   the MakeMKV intermediate.
2. **Click Convert.** Each item flows through the stages it needs:
   - `Blu-ray` → MakeMKV rip → HandBrake → FileBot → Subler
   - `DVD` → HandBrake (reads `/dev/disk*` directly) → FileBot → Subler
   - `Video File` → HandBrake → FileBot → Subler
3. **Live queue** — each item shows its current stage with a colored progress
   bar. Stage colors: purple (rip), blue (encode), orange (rename), green (tag).
4. **Summary sheet** appears when the run completes, listing converted titles,
   per-item elapsed time, total elapsed time, failures (if any), and a button
   to reveal the log file in Finder.

## CLI invocations (verified syntax)

| Stage | Command |
|---|---|
| MakeMKV | `makemkvcon -r --minlength=3600 --progress=-stderr mkv disc:0 all <folder>` |
| HandBrake | `HandBrakeCLI -i <src> -o <out>.m4v --preset-import-gui --preset "Apple 2160p60 4K HEVC Surround" -v 1` |
| FileBot | `filebot -rename <file> --db TheMovieDB --format "{n} ({y})" -non-strict --action move --conflict auto` |
| SublerCli | `SublerCli -source <file> -optimize` |

References:
- [HandBrake CLI options](https://handbrake.fr/docs/en/latest/cli/cli-options.html)
- [MakeMKV CLI usage](https://www.makemkv.com/developers/usage.txt)
- [FileBot CLI](https://www.filebot.net/cli.html)
- [Subler GitHub](https://github.com/SublerApp/Subler)

## Logs

Every run writes `conversion_log_YYYY-MM-DD_HH-MM-SS.txt` into the chosen
output directory. Every CLI invocation, full stdout/stderr line-by-line, and
timestamps land in there. The summary sheet has a "reveal in Finder" button.
