# Preview release `v0.1.0+7-preview` (latest BUILD_NUMBER)

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+7` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version** | `7` |
| **Git tag** | `v0.1.0+7-preview` |
| **GitHub** | **Pre-release** |
| **Primary commit** | `54f3112d508bd0c898db464ad33bdc06d344ef56` |
| **`BUILD_NUMBER` file** | `7` (on `main` when last synced) |
| **Minimum macOS** | `13.0` |

## Summary

Current **tip preview** for the SwiftUI **MediaVault** shell on `main`: includes settings-driven pipeline behavior and ships with **dSYM** for the Mach-O binary. Use this build ID for smoke tests that must match the latest increment of **`BUILD_NUMBER`**.

## Artifacts

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+7/MediaVault.app` |
| Debug symbols | `builds/0.1.0+7/MediaVault.app/Contents/MacOS/MediaVault.dSYM/...` |
| Zip distribution | *None in tree for this ID* — run `./build.sh release` locally to produce zip + GitHub upload per `docs/BUILD_PROCESS.md` |

Mach-O ~1.59 MB (aarch64) in historical artifact tree.

## Publishing checklist (GitHub)

1. Create release titled e.g. **Media Magic `0.1.0+7` Preview**.
2. Enable **Set as a pre-release**.
3. Attach `MediaVault-0.1.0+7-macOS.zip` when produced by release script.
4. Paste summary bullets from this file + link to full docs.

## Support matrix (preview)

| Item | Status |
| --- | --- |
| Apple Silicon | Primary target |
| Intel Mac | *Best-effort / build-time dependent* |
| Notarization | Out of scope per BUILD_PROCESS baseline |
| Gatekeeper | User may need manual open / quarantine clear |

---

*When **Media Magic** rename lands in Info.plist, regenerate artifacts and duplicate notes under new bundle names.*
