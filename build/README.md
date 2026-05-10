# Build directory

This folder holds **release metadata** for preview distributions. Compiled artifacts live under **`builds/<BUILD_ID>/`** when present on the branch that contains the SwiftUI app (see `origin/main`).

| Path | Purpose |
| --- | --- |
| **`releases/`** | Detailed release notes, manifest, and GitHub prerelease guidance for each **preview** build (`0.1.0+N`). |
| **`builds/`** (repository root, plural) | Produced by `build.sh`; contains `MediaVault.app` bundles and optional `.zip` assets per SemVer build ID. |

See **`releases/README.md`** for the full index.
