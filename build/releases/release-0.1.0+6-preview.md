# Preview release `v0.1.0+6-preview`

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+6` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version** | `6` |
| **Git tag** | `v0.1.0+6-preview` |
| **GitHub** | **Pre-release** |
| **Primary commit** | `54f3112d508bd0c898db464ad33bdc06d344ef56` — *Add settings-driven pipeline controls and align docs/diagrams* |
| **Minimum macOS** | `13.0` |

## Summary

Introduces **settings-driven pipeline controls** in the SwiftUI app (`AppSettings` integration, UI wiring per `ContentView` / `PipelineController`). Binary size increases versus earlier ~700 KB builds due to additional symbols and features.

Debug **`dSYM`** bundle is included under the app path for crash symbolication:

- `MediaVault.app/Contents/MacOS/MediaVault.dSYM`

## Artifacts

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+6/MediaVault.app` |
| Debug symbols | `builds/0.1.0+6/MediaVault.app/Contents/MacOS/MediaVault.dSYM/...` |
| Zip distribution | *None in tree for this ID* |

Approximate Mach-O size ~1.56 MB (aarch64).

## Highlights (functional preview)

- User-adjustable pipeline-related settings persisted via app settings model.
- Documentation/diagram alignment for architecture (see commit message).

## Risks (preview)

- Settings persistence format may evolve—reset prefs between previews if QA sees migration issues.

---

*Tagged **`v0.1.0+6-preview`** — prerelease only.*
