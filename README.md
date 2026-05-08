# Media-Magic

Media-Magic is a native macOS SwiftUI app (`MediaVault`) that orchestrates a
multi-stage conversion pipeline for movie/disc workflows:

- MakeMKV (Blu-ray only)
- HandBrakeCLI (transcode)
- FileBot (rename)
- SublerCli (metadata optimization)

The repository also includes a legacy shell + AppleScript pipeline as a
fallback path.

## Repository Layout

```text
Sources/MediaVault/
  MediaVaultApp.swift
  ContentView.swift
  PipelineController.swift
  ToolManager.swift
build.sh
MediaConversionPipeline.sh
LaunchMediaPipeline.applescript
```

## Architecture

```mermaid
flowchart TD
    User["User"] --> UI["SwiftUI ContentView"]
    UI --> Controller["PipelineController"]
    UI --> Tools["ToolManager"]
    Tools --> HB["HandBrakeCLI"]
    Tools --> Subler["SublerCli"]
    Tools --> MKV["MakeMKV (optional)"]
    Tools --> FB["FileBot (optional)"]
    Controller --> Proc["Process runner + output streaming"]
    Proc --> Log["conversion_log_YYYY-MM-DD_HH-MM-SS.txt"]
    Proc --> Notify["UNUserNotificationCenter"]
    Controller --> Summary["Run summary (success/failure)"]
```

## End-To-End Pipeline Flow

```mermaid
flowchart TD
    Start["Start conversion"] --> SourceType{"Source type"}
    SourceType -->|"Video File"| HB
    SourceType -->|"DVD (/dev/diskN)"| HB
    SourceType -->|"Blu-ray"| MKV
    MKV["MakeMKV rip (largest MKV selected)"] --> HB["HandBrakeCLI transcode (.m4v)"]
    HB --> FileBotCheck{"FileBot available?"}
    FileBotCheck -->|"Yes"| FB["FileBot rename"]
    FileBotCheck -->|"No"| SkipFB["Skip rename"]
    FB --> Subler["SublerCli optimize metadata"]
    SkipFB --> Subler
    Subler --> Done["Item complete"]
```

## Tool Orchestration Sequence

```mermaid
sequenceDiagram
    participant User
    participant UI as ContentView
    participant TM as ToolManager
    participant PC as PipelineController
    participant CLI as ExternalCLI

    User->>UI: Launch app
    UI->>TM: prepare()
    TM->>TM: Resolve/download tools
    User->>UI: Choose sources + output and press Convert
    UI->>PC: enqueue(...), run()
    loop per item
        PC->>CLI: MakeMKV (Blu-ray only)
        CLI-->>PC: streamed output
        PC->>CLI: HandBrakeCLI
        CLI-->>PC: streamed output with progress
        PC->>CLI: FileBot (if available)
        CLI-->>PC: rename output
        PC->>CLI: SublerCli
        CLI-->>PC: completion
    end
    PC-->>UI: summary + log path
```

## Error Handling And Continuation

```mermaid
flowchart TD
    ItemStart["Process item"] --> StageRun["Run next stage"]
    StageRun --> Ok{"Stage success?"}
    Ok -->|"Yes"| NextStage{"More stages?"}
    NextStage -->|"Yes"| StageRun
    NextStage -->|"No"| ItemSuccess["Mark item complete"]
    Ok -->|"No"| ItemFail["Mark item failed + show alert"]
    ItemFail --> Continue["Continue with next item"]
    ItemSuccess --> Continue
```

## Build And Run

Requirements:
- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

Commands:

```bash
chmod +x build.sh
./build.sh
./build.sh release
./build.sh release sign
open build/MediaVault.app
```

## Tool Resolution Model

- `HandBrakeCLI`:
  - Uses existing system install if present.
  - Otherwise downloads pinned release DMG and installs binary into
    `~/Library/Application Support/MediaVault/bin/`.
- `SublerCli`:
  - Resolved from common paths; if missing, app prompts install guidance.
- `MakeMKV`:
  - Required only for Blu-ray.
- `FileBot`:
  - Optional; rename stage is skipped if absent.

## CLI Stage Commands

| Stage | Command pattern |
|---|---|
| MakeMKV | `makemkvcon -r --minlength=3600 --progress=-stderr mkv disc:0 all <folder>` |
| HandBrakeCLI | `HandBrakeCLI -i <src> -o <out>.m4v --preset-import-gui --preset "Apple 2160p60 4K HEVC Surround" -v 1` |
| FileBot | `filebot -rename <file> --db TheMovieDB --format "{n} ({y})" -non-strict --action move --conflict auto` |
| SublerCli | `SublerCli -source <file> -optimize` |

## Logs And Outputs

- A run log is written to output directory:
  - `conversion_log_YYYY-MM-DD_HH-MM-SS.txt`
- The UI summary reports:
  - total items
  - succeeded/failed items
  - elapsed times
  - log file location

## Legacy Pipeline

Legacy scripts remain available:
- `MediaConversionPipeline.sh`
- `LaunchMediaPipeline.applescript`

Use this path if you prefer shell-driven dialogs or need to run without the
SwiftUI app.
