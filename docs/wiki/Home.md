# Media Magic

**Media Magic** is the macOS SwiftUI application in this repository. It orchestrates local video conversion using tools such as MakeMKV, HandBrake, FileBot, and Subler.

## Wiki maintenance

GitHub wikis live in a separate repository from the main tree. To keep branding aligned with the app:

1. Edit pages in the GitHub UI, **or** clone the wiki (`git clone …wiki.git`) and ensure user-facing text uses **Media Magic** and technical identifiers use **MediaMagic** (app bundle, binary, support directories) consistently with this repo.
2. Use the repository docs as the source of truth: [README](../../README.md), [BUILD_PROCESS](../BUILD_PROCESS.md), [MEDIA_MAGIC_ORCHESTRATION](../MEDIA_MAGIC_ORCHESTRATION.md).

## Artifacts

Release builds produce `MediaMagic.app`, zipped as `MediaMagic-<VERSION>+<BUILD_NUMBER>-macOS.zip`, under `builds/<VERSION>+<BUILD_NUMBER>/`.
