# Media-Magic

Production-ready macOS automation script to orchestrate media conversion for Apple TV app-compatible files (`.m4v`/`.mp4`) using:

1. MakeMKV (Blu-ray rip stage)
2. HandBrakeCLI (`Apple 2160p60 4K HEVC Surround` preset)
3. FileBot (renaming)
4. SublerCLI (metadata + artwork)

## Script

- `./media_magic.sh`

## Run

```bash
chmod +x ./media_magic.sh
./media_magic.sh
```

The script uses **native macOS dialogs** (`osascript`) for:
- Source selection (Disc or Video File)
- Disc type (DVD or Blu-ray)
- Input file/folder picking
- Output folder selection
- Stage progress notifications
- Error dialogs
- Final completion summary dialog

## Tool path assumptions (absolute-path lookup)

The script validates all required tools before starting and checks common install paths:

- MakeMKV: `/Applications/MakeMKV.app/Contents/MacOS/makemkvcon`, `/opt/homebrew/bin/makemkvcon`, `/usr/local/bin/makemkvcon`
- HandBrakeCLI: `/Applications/HandBrakeCLI`, `/opt/homebrew/bin/HandBrakeCLI`, `/usr/local/bin/HandBrakeCLI`
- FileBot: `/Applications/FileBot.app/Contents/MacOS/filebot`, `/opt/homebrew/bin/filebot`, `/usr/local/bin/filebot`
- SublerCLI: `/Applications/Subler.app/Contents/MacOS/SublerCLI`, `/opt/homebrew/bin/SublerCLI`, `/usr/local/bin/SublerCLI`, `/opt/homebrew/bin/sublercli`, `/usr/local/bin/sublercli`

If any tool is missing, a native macOS error dialog lists exactly what is missing.

## Logging

A timestamped log file is written to the selected output directory:

- `conversion_log_YYYYMMDD_HHMMSS.txt`

The log captures:
- tool version checks
- command invocations
- stdout/stderr output
- exit codes
- stage timestamps

## CLI references

- MakeMKV CLI docs: https://www.makemkv.com/developers/usage.txt
- HandBrake CLI docs: https://handbrake.fr/docs/en/latest/cli/cli-options.html
- FileBot CLI docs: https://www.filebot.net/cli.html
- Subler project: https://github.com/SublerApp/Subler

## Version behavior notes

- HandBrake preset names can differ across versions. The script verifies `Apple 2160p60 4K HEVC Surround` is available via `--preset-list` before processing.
- MakeMKV drive selectors (e.g. `disc:0`) may differ by host/device mapping.
- FileBot flags and metadata DB behavior can vary by release/license mode.
- SublerCLI metadata-fetch flags can vary by build; the script attempts two common syntaxes and logs failures so local flags can be adjusted.
