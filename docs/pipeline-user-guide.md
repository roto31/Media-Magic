# Media Magic — user guide

## What it does

**Media Magic** (`MediaConversionPipeline.sh`) guides you through:

1. **Source** — Video files (multi-select), DVD folder (`VIDEO_TS`), or Blu-ray rip via **MakeMKV**.
2. **Output folder** — HandBrake output, FileBot rename target, Subler processing, and **log file** location.
3. **Pipeline per source** — Encode → FileBot rename → Subler metadata (and optional SublerCLI optimize).

Output uses HandBrake preset **Apple 2160p60 4K HEVC Surround** (Apple TV–friendly `.m4v`).

## Requirements

- **macOS** (script exits on non-Darwin).
- Installed tools (script discovers standard paths; Homebrew or `/Applications`):

  | Tool | Role |
  | --- | --- |
  | **HandBrakeCLI** | Required — encode |
  | **FileBot** | Required — rename using metadata DB |
  | **Subler.app** *or* **SublerCLI** | At least one — metadata / optimize |
  | **makemkvcon** (MakeMKV) | Required only for **Blu-ray** ripping |

## How to run

```bash
chmod +x MediaConversionPipeline.sh
/path/to/MediaConversionPipeline.sh
```

Or add the repo directory to your `PATH` and run by name.

## User interface

All prompts use **native macOS UI** via `osascript` (choose folder/file, alerts, notifications). Progress uses **notifications** between stages (e.g. “Converting file 2 of 5…”).

## Workflow summary

| Step | You choose | What runs |
| --- | --- | --- |
| 1 | Disc vs files; DVD vs Blu-ray | Blu-ray: MakeMKV rips MKVs to a folder you pick |
| 2 | Output directory | Log file created here |
| 3 | — | For each source: HandBrake → FileBot → Subler |

Failures show an **alert** with stage and path; **remaining files** continue processing.

## Log file

Written in the output directory:

```text
conversion_log_YYYY-MM-DD.txt
```

MakeMKV output may be **prepended** from a temporary log if ripping ran before you chose the output folder.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `SUBLER_METADATA_WAIT` | `90` | Seconds to wait after Subler **fetch metadata** before save (async behaviour in Subler.app). Increase if metadata often incomplete. |
| `MAKEMKV_DISC_INDEX` | `0` | Physical disc index for MakeMKV (`disc:0`, `disc:1`, …). |

## Optional Terminal launcher

`LaunchMediaPipeline.applescript` starts **Terminal** and runs your script.

1. Edit `pipelineScript` to the **absolute path** of `MediaConversionPipeline.sh` on your machine.
2. Compile:

   ```bash
   osacompile -o "Media Magic.app" LaunchMediaPipeline.applescript
   ```

3. Double-click **Media Magic.app** to run.

The script itself performs all dialogs; the launcher only provides a visible transcript.

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| “Missing required tools” | Install HandBrake, FileBot, Subler; ensure binaries exist under paths in the script header or `PATH`. |
| HandBrake unknown preset | Open HandBrake GUI once so presets sync; script retries with `--preset-import-gui`. |
| Subler metadata thin or missing | Increase `SUBLER_METADATA_WAIT`; ensure Subler has automation / recent version with **Subler Automation Suite**. |
| Blu-ray rip fails | Check MakeMKV license/beta; try `MAKEMKV_DISC_INDEX=1` if multiple drives. |
| FileBot wrong title | Uses `TheMovieDB` + `-non-strict`; for TV you may need script changes (`TheMovieDB::TV`). |

## Official CLI references

Linked from comments in `MediaConversionPipeline.sh`:

- MakeMKV: https://www.makemkv.com/developers/usage.txt  
- HandBrake CLI: https://handbrake.fr/docs/en/latest/cli/cli-options.html  
- HandBrake presets: https://handbrake.fr/docs/en/latest/technical/official-presets.html  
- FileBot: https://www.filebot.net/cli.html  
- Subler: https://github.com/SublerApp/Subler  
