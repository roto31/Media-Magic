# Preview release `v0.1.0+1-preview`

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+1` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version (`CFBundleVersion`)** | `1` |
| **Git tag** | `v0.1.0+1-preview` |
| **GitHub** | **Pre-release** — enable “Set as a pre-release” |
| **Representative commit** | `1a2d53b` — *Add native SwiftUI MediaVault app and build tooling* |
| **Minimum macOS** | `13.0` (`LSMinimumSystemVersion`) |

## Summary

First native **macOS SwiftUI** shell for the media conversion workflow: live orchestration, tool path discovery (`ToolManager`), pipeline stages (`PipelineController`), and UI shell (`ContentView`). Coexists with the bash `/ bash + osascript` workflow documented in-repo.

## Artifacts (when `builds/` is checked out)

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+1/MediaVault.app` |
| Zip distribution | *None for this build ID* |

Approximate **Mach-O** size (aarch64): ~700 KB (unsigned debug-style build from historical tree).

## Behavior & scope (preview)

- **Preview quality:** APIs, UX, and external tool contracts may change without notice.
- **Signing:** Local/debug builds may be **ad hoc** or unsigned—Gatekeeper may require *Right-click → Open* or quarantine strip (`xattr`).
- **Dependencies:** Requires user-installed **MakeMKV**, **HandBrakeCLI**, **FileBot**, **Subler** per project docs.

## Upgrade / migration

No prior app bundle; first install. Configuration stored per project conventions (see app sources on `main`).

## Verification checklist

- [ ] App launches on macOS 13+ (Apple Silicon tested).
- [ ] External tools detected or explicit error surfaced.
- [ ] Pipeline run completes or surfaces per-item failure (preview UX).

---

*Media Magic product naming applies to marketing; this artifact path still uses **MediaVault** bundle identifiers from build metadata.*
