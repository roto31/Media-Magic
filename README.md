# Media-Magic

Media-Magic is a native macOS SwiftUI app (**Media Magic**) that orchestrates a
multi-stage conversion pipeline for movie/disc workflows:

- MakeMKV (Blu-ray only)
- HandBrakeCLI (transcode)
- FileBot (rename)
- SublerCli (metadata optimization)

The repository also includes a legacy shell + AppleScript pipeline as a
fallback path.

## Repository Layout

```text
Sources/MediaMagic/
  MediaMagicApp.swift
  ContentView.swift
  PipelineController.swift
  ConversionOrchestrator.swift
  ConversionJobStore.swift
  ConversionJobModels.swift
  ToolCheckpointAdapter.swift
  RunControlView.swift
  LogViewerView.swift
  ToolManager.swift
  … (additional Swift sources)
build.sh
MediaConversionPipeline.sh
LaunchMediaPipeline.applescript
docs/
  MEDIA_MAGIC_ORCHESTRATION.md   # deep-dive: lanes, persistence, diagrams
  BUILD_PROCESS.md
.github/workflows/
  media-magic.yml                 # compile-only CI on push/PR
```

## Architecture

```mermaid
flowchart TD
    User["User"] --> UI["SwiftUI ContentView + RunControlView"]
    UI --> PC["PipelineController (@MainActor)"]
    UI --> Tools["ToolManager"]
    PC --> ORCH["ConversionOrchestrator (actor)"]
    ORCH --> Store["ConversionJobStore (JSON, atomic writes)"]
    ORCH --> Proc["Foundation.Process per stage"]
    Tools --> HB["HandBrakeCLI"]
    Tools --> Subler["SublerCli"]
    Tools --> MKV["MakeMKV (optional)"]
    Tools --> FB["FileBot (optional)"]
    Proc --> Log["Session log + PipelineLogEntry stream"]
    Proc --> Notify["UNUserNotificationCenter"]
    PC --> LVV["LogViewerView (separate window)"]
    PC --> Summary["Run summary when queue drains"]
```

Full diagrams (state machine, sequences, ER sketch): [docs/MEDIA_MAGIC_ORCHESTRATION.md](docs/MEDIA_MAGIC_ORCHESTRATION.md).

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
    participant OR as ConversionOrchestrator
    participant CLI as ExternalCLI

    User->>UI: Launch app
    UI->>TM: prepare()
    TM->>TM: Resolve/download tools
    UI->>PC: refreshOrchestratorToolPaths()
    User->>UI: Choose sources + output and press Convert
    UI->>PC: enqueue(sources, output, options)
    PC->>OR: enqueue jobs (async)
    loop per running job / stage
        OR->>CLI: MakeMKV / HandBrake / FileBot / Subler
        CLI-->>OR: streamed stdout/stderr
        OR-->>PC: OrchestratorEvent.state + .log
        OR->>OR: persist snapshot (ConversionJobStore)
    end
    OR-->>PC: allDrained + summary data
```

## Settings And Run Overrides

The app now includes a Settings panel (`gear` button in header) with persistent
defaults, plus per-run overrides in the main Source card.

- Settings defaults (persisted in `UserDefaults`):
  - HandBrake preset + extra args
  - FileBot DB/format + extra args
  - Subler extra args
  - Default skip FileBot/Subler toggles
  - Default copy-to-Apple-TV auto-import toggle
  - Force first-run setup on next launch (re-download managed HandBrakeCLI)
- Main-window run options (override defaults for current run):
  - Skip FileBot
  - Skip Subler
  - Copy output to Apple TV auto-import folder:
    - `/Users/chris/Movies/TV/Media.localized/Automatically Add To TV.localized`

```mermaid
flowchart TD
    SettingsDefaults["Saved Settings defaults"] --> MainRun["Main window run options"]
    MainRun --> PipelineOptions["PipelineRunOptions"]
    PipelineOptions --> HBArgs["HandBrake configured args"]
    PipelineOptions --> FBArgs["FileBot configured args or skip"]
    PipelineOptions --> SublerArgs["Subler configured args or skip"]
    PipelineOptions --> AppleTVCopy["Optional copy to Apple TV import folder"]
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
# optional compatibility alias:
./build.sh release sign
open builds/<semver>+<build_number>/MediaMagic.app
```

## Build And Release Process

Release builds are now **signed-only GitHub distribution** builds:

- Build output is created under `builds/<VERSION>+<BUILD_NUMBER>/MediaMagic.app`
- App is signed with Developer ID Application identity
- App is zipped as `MediaMagic-<VERSION>+<BUILD_NUMBER>-macOS.zip`
- GitHub Release is created/updated for tag `<VERSION>+<BUILD_NUMBER>`
- Release asset is uploaded automatically (`gh release upload --clobber`)

```mermaid
flowchart TD
    StartBuild["./build.sh release"] --> Validate["Validate VERSION + BUILD_NUMBER"]
    Validate --> Compile["Compile Swift binary"]
    Compile --> WritePlist["Write Info.plist (CFBundle versions)"]
    WritePlist --> SignApp["Sign app (Developer ID Application)"]
    SignApp --> VerifySign["Verify codesign integrity"]
    VerifySign --> Package["Zip app artifact"]
    Package --> EnsureGh["Validate gh auth + git repo context"]
    EnsureGh --> ReleaseExists{"GitHub release exists?"}
    ReleaseExists -->|"No"| CreateRelease["gh release create (optional --prerelease)"]
    ReleaseExists -->|"Yes"| EditRelease["gh release edit notes (optional --prerelease)"]
    CreateRelease --> UploadAsset["Upload zip asset (--clobber)"]
    EditRelease --> UploadAsset
    UploadAsset --> DoneBuild["Release build complete"]
```

Optional pre-release flag: `MEDIA_MAGIC_PRERELEASE=1 ./build.sh release` passes `--prerelease` to `gh` while keeping the tag as `<VERSION>+<BUILD_NUMBER>` (see `docs/BUILD_PROCESS.md`).

CI: `.github/workflows/media-magic.yml` runs a **compile-only** check on push/PR; it does not replace `./build.sh release`.

Distribution note:
- This mode is signed but **not notarized**.
- Some machines may still require first-open allowance (right-click Open), or:
  - `xattr -dr com.apple.quarantine MediaMagic.app`

Detailed build documentation: `docs/BUILD_PROCESS.md`

## Versioning And Build Numbering

Media-Magic uses [Semantic Versioning 2.0.0](https://semver.org):

- `VERSION` stores SemVer core: `MAJOR.MINOR.PATCH` (example: `0.1.0`).
- `BUILD_NUMBER` stores the last successful numeric build number.
- `build.sh` increments `BUILD_NUMBER` on each successful build.
- Each build writes immutable artifacts into:
  - `builds/<MAJOR.MINOR.PATCH>+<BUILD_NUMBER>/MediaMagic.app`

For Apple bundle metadata:

- `CFBundleShortVersionString` = contents of `VERSION`
- `CFBundleVersion` = incremented numeric `BUILD_NUMBER`

Release cadence guidance:

- Alpha stage baseline:
  - Start at `0.1.0`.
  - Keep major version `0` until explicitly moving beyond Alpha.
- Increment `PATCH` for backward-compatible bug fixes.
- Increment `MINOR` for backward-compatible feature additions.
- Increment `MAJOR` for backward-incompatible changes.
- Do not modify artifacts of an existing build ID; create a new build instead.
- Every successful `release` build must upload its zipped artifact to GitHub
  Releases for the matching build tag.

## Tool Resolution Model

- `HandBrakeCLI`:
  - Uses existing system install if present.
  - Otherwise downloads pinned release DMG and installs binary into
    `~/Library/Application Support/MediaMagic/bin/`.
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
