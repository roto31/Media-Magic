# Media Magic

**Media Magic** is macOS automation that rips or reads media, converts with **HandBrakeCLI**, renames with **FileBot**, and embeds metadata with **Subler**—using native dialogs and notifications.

## Documentation

| Document | Audience |
| --- | --- |
| [docs/pipeline-user-guide.md](docs/pipeline-user-guide.md) | Install, run, workflow, troubleshooting |
| [docs/pipeline-developer-reference.md](docs/pipeline-developer-reference.md) | Architecture, env vars, conventions for maintainers |
| [docs/cursor-ai-and-repository-conventions.md](docs/cursor-ai-and-repository-conventions.md) | Cursor rules, skills, lessons learned |
| [LESSONS_LEARNED.md](LESSONS_LEARNED.md) | Review notes and enforced refactor decisions |
| [build/releases/README.md](build/releases/README.md) | **Preview releases** — SemVer build IDs, artifacts, Git tags (`v0.1.0+N-preview`) |

## Quick start (macOS)

1. Install **MakeMKV**, **HandBrake**, **FileBot**, and **Subler** (see user guide for paths).
2. Clone this repo and mark the script executable:

   ```bash
   chmod +x MediaConversionPipeline.sh
   ./MediaConversionPipeline.sh
   ```

3. Optional: compile `LaunchMediaPipeline.applescript` into a double-clickable app after editing `pipelineScript` (see user guide).

## Repository contents

| Item | Purpose |
| --- | --- |
| `MediaConversionPipeline.sh` | Main Media Magic pipeline (dialogs, logging, batch conversion) |
| `LaunchMediaPipeline.applescript` | Opens Terminal and runs the shell script |
| `.cursor/rules/*.mdc` | Cursor AI coding standards for this project |
| `.cursor/skills/design-pattern-decision-tree/SKILL.md` | Assistant-facing pattern decision tree |

## License

See [LICENSE](LICENSE).
