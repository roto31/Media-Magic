# Preview release `v0.1.0+5-preview`

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+5` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version** | `5` |
| **Git tag** | `v0.1.0+5-preview` |
| **GitHub** | **Pre-release** |
| **Associated commit** | `49c1083ac4753e1b1e300dd455904516c48e21ba` (artifact packaged after `+4` landing) |
| **Minimum macOS** | `13.0` |

## Summary

Adds a **zip-packaged** macOS asset suitable for upload to GitHub Releases:

- `MediaVault-0.1.0+5-macOS.zip`

This matches the **release zip** convention documented in `docs/BUILD_PROCESS.md` (`MediaVault-<BUILD_ID>-macOS.zip`).

## Artifacts

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+5/MediaVault.app` |
| Zip (download) | `builds/0.1.0+5/MediaVault-0.1.0+5-macOS.zip` |

Historical zip size ~186 KB (compressed); expands to app bundle + metadata.

## Verification

After download:

```bash
shasum -a 256 MediaVault-0.1.0+5-macOS.zip   # compare with GitHub release notes when published
ditto -xk MediaVault-0.1.0+5-macOS.zip /tmp/mv-preview
xattr -dr com.apple.quarantine /tmp/mv-preview/MediaVault.app   # if Gatekeeper blocks
```

## Preview disclaimer

Not notarized in baseline workflow—users may need Gatekeeper override. **Always** publish as GitHub **pre-release**.

---

*Product branding migration to **Media Magic** does not change historical zip filenames until the build pipeline is updated.*
