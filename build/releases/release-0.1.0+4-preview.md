# Preview release `v0.1.0+4-preview`

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+4` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version** | `4` |
| **Git tag** | `v0.1.0+4-preview` |
| **GitHub** | **Pre-release** |
| **Primary commit** | `49c1083ac4753e1b1e300dd455904516c48e21ba` — *Add release build 0.1.0+4 artifact* |
| **Minimum macOS** | `13.0` |

## Summary

First **release-folder snapshot** tied explicitly to repository commits alongside SemVer alpha governance (`BUILD_NUMBER`, `VERSION`). Marks the transition from “local bundle drops” to **predictable `builds/<BUILD_ID>/` layout** used by `build.sh release`.

## Artifacts

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+4/MediaVault.app` |
| Zip distribution | *None in tree for this ID* |

Mach-O size historically ~716 KB.

## Changes vs `+3`

- Build outputs aligned with documented **`build.sh`** release layout.
- Stronger traceability: artifact directory matches **SemVer build ID** string.

## Distribution

- **Always mark GitHub Release as prerelease** until GA.
- Signing expectations described in `docs/BUILD_PROCESS.md` on `main`.

---

*Parallel legacy tag `0.1.0+4` may exist; prefer **`v0.1.0+4-preview`** for prerelease semantics.*
