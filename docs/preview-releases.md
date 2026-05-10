# Preview releases (GitHub prerelease policy)

All native **MediaVault.app** build IDs under `builds/0.1.0+N/` are **preview** quality until a stable GA is announced.

- **Human-readable notes:** [`build/releases/`](../build/releases/README.md) — one Markdown file per build plus [`manifest.json`](../build/releases/manifest.json).
- **Git tags:** `v0.1.0+N-preview` (annotated). Legacy tags `0.1.0+N` may still exist from earlier automation.
- **GitHub Releases UI:** always enable **Set as a pre-release** when uploading zip/assets.

Full build mechanics: `docs/BUILD_PROCESS.md` on branches that include `build.sh` (typically `main`).
