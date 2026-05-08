# Lessons Learned

## 2026-05-08 — Release Upload Must Be Built-In

- Manual release uploads are error-prone and repeatedly fail due to context and
  authentication drift.
- Release packaging and GitHub upload should be part of the release build path,
  not a separate manual checklist.
- Enforcing upload in `build.sh release` creates a single reliable path from
  build completion to published release artifact.

## 2026-05-08 — Alpha Version Baseline Correction

- Alpha-stage software must start at major version `0` (for this project:
  `0.1.0`), not `1.0.0`.
- Initial version semantics need an explicit rule, not only team convention.
- Version examples in docs and defaults in source-controlled version files must
  stay aligned to avoid accidental major-version signaling.

## 2026-05-08 — Build Governance With SemVer

- Reusing a single mutable `build/` folder makes artifact provenance ambiguous.
- Immutable per-build output directories improve traceability and rollback safety.
- Storing SemVer core (`VERSION`) separately from numeric build counter
  (`BUILD_NUMBER`) keeps release intent clear while satisfying Apple bundle
  version requirements.
- Enforcing schema directly in `build.sh` prevents invalid version artifacts from
  being produced.
- Persisting the build counter only after successful builds avoids gaps caused by
  failed attempts.

## 2026-05-08 — Build Docs Must Track Pipeline Changes

- Build/distribution behavior changed from manual release steps to scripted
  sign/package/upload.
- Documentation must be updated in the same cycle as build script changes, or it
  quickly becomes inaccurate for release operations.
