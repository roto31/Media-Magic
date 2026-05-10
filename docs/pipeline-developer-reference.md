# Media Magic — developer reference

## High-level architecture

```text
User (osascript dialogs)
        │
        ▼
┌───────────────────────────────────────────┐
│  MediaConversionPipeline.sh (Media Magic) │
│  • init_tool_paths (Facade)              │
│  • prompt_source_flow                     │
│  • populate_sources_from_flow             │
│  • per-item: HandBrake → FileBot → Subler │
└───────────────────────────────────────────┘
        │           │            │
        ▼           ▼            ▼
   HandBrakeCLI  filebot   Subler.app / SublerCLI
```

## Conventions (do not regress)

These match `.cursor/rules/media-pipeline-shell-conventions.mdc`:

1. **Facade — `init_tool_paths`**  
   All discovery of `makemkvcon`, `HandBrakeCLI`, `FileBot`, Subler stays here. Extend candidate paths only inside this function.

2. **Chain — `_try_handbrake_encode`**  
   Ordered encode attempts (default `--preset`, then `--preset-import-gui`). Do not duplicate parallel `if HandBrakeCLI` blocks in `run_handbrake_one`.

3. **Source decoder — `populate_sources_from_flow`**  
   `prompt_source_flow` emits typed prefixes (`DVD<TAB>`, `FILES<NEWLINE>`, or plain lines). Add new source kinds by extending this function’s `case`, not by branching in `main`.

## Key functions

| Function | Responsibility |
| --- | --- |
| `resolve_first` | First existing file path from a list |
| `init_tool_paths` | Populate global tool path variables |
| `validate_for_pipeline` / `validate_makemkv` | Startup checks |
| `prompt_source_flow` | Dialogs + optional MakeMKV rip |
| `populate_sources_from_flow` | Parse flow string → `SOURCES` array |
| `run_handbrake_one` | Output path, notifications, `_try_handbrake_encode` |
| `run_filebot_rename_one` | Rename + resolve new path via temp marker |
| `subler_app_metadata` | AppleScript: open, fetch metadata, delay, save |
| `subler_optimize_cli` | Optional SublerCLI `-optimize` |
| `run_subler_stage` | Subler.app then optional CLI optimize |

## Globals / state

- `LOG_FILE`, `STAGE1_LOG` — logging; stage1 log merged into main log after output dir chosen.
- `SUCCESS_TITLES` — basenames for completion dialog.

## Bash compatibility

Target **bash 3.2** (macOS default `/bin/bash`). Avoid bash 4+–only features unless the project explicitly drops default bash.

## Changing preset or tools

- Preset: `readonly HANDBRAKE_PRESET` at top of script.
- FileBot DB: `run_filebot_rename_one` (`TheMovieDB`, `-non-strict`).
- MakeMKV args: Blu-ray block in `prompt_source_flow` (see usage.txt for flags).

## Related docs

- [pipeline-user-guide.md](pipeline-user-guide.md) — env vars and troubleshooting  
- [cursor-ai-and-repository-conventions.md](cursor-ai-and-repository-conventions.md) — Cursor rules  
