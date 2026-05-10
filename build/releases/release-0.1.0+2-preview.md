# Preview release `v0.1.0+2-preview`

| Field | Value |
| --- | --- |
| **Build ID** | `0.1.0+2` |
| **SemVer marketing** | `0.1.0` (Alpha) |
| **Bundle version** | `2` |
| **Git tag** | `v0.1.0+2-preview` |
| **GitHub** | **Pre-release** |
| **Representative commit** | `1a2d53b` (artifact iteration; same logical baseline as `+1`) |
| **Minimum macOS** | `13.0` |

## Summary

Incremental **preview** rebuild incrementing `CFBundleVersion` only. Use when validating reproducible builds before SemVer governance landed (`BUILD_NUMBER` discipline).

## Artifacts

| Asset | Path |
| --- | --- |
| Application bundle | `builds/0.1.0+2/MediaVault.app` |
| Zip distribution | *None* |

Binary footprint comparable to `+1` (~716 KB Mach-O in historical checkout).

## Notes

- Treat as **preview**: interchangeable with `+1` for functional smoke tests unless you rely on exact bundle version stamps for support tickets.
- Publish to GitHub Releases only as **prerelease**.

---

*Bundle display names in plist may still read **MediaVault**; rename to **Media Magic** is tracked separately from build IDs.*
