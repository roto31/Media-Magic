# MediaVault orchestration, persistence, and controls

This document describes the **current** MediaVault architecture after the job-orchestration redesign. It is derived from the Swift sources under `Sources/MediaVault/`.

## Goals (what shipped)

- **Concurrent lanes**: file-based jobs and disc-based jobs schedule independently with per-lane concurrency limits.
- **Global / lane / job controls**: pause, resume, and stop at each scope; stop uses a confirmation dialog in the UI.
- **Durable job state**: jobs are persisted so the app can reconstruct paused work after relaunch (with the limitations documented below).
- **Live log UI**: separate “Process Log” window with filters and search.
- **Tool path materialization**: discovered `SublerCli` is copied into Application Support and quarantine is stripped (same pattern as managed HandBrakeCLI).

## Repository layout (Swift app)

```text
Sources/MediaVault/
  MediaVaultApp.swift          # App entry, recovery task, terminate hook
  ContentView.swift            # Lane-aware queue + run controls
  PipelineController.swift   # MainActor facade + log projection
  ConversionOrchestrator.swift  # actor: scheduling, Process I/O, persistence fan-out
  ConversionJobStore.swift     # actor: JSON atomic store under Application Support
  ConversionJobModels.swift    # Codable persisted shapes + schema version
  ToolCheckpointAdapter.swift  # Stage capability matrix (pause/resume semantics)
  ToolManager.swift            # CLI discovery / download
  RunControlView.swift         # Pause / Stop UI cluster (global, lane, job)
  LogViewerView.swift          # Process log window
  … (other existing Swift files)
```

## High-level architecture

```mermaid
flowchart LR
    subgraph UI["SwiftUI (MainActor)"]
        CV["ContentView"]
        LVV["LogViewerView"]
        RCV["RunControlView"]
    end
    subgraph Facade["PipelineController (@MainActor)"]
        PC["Published items / laneActivity / logs"]
    end
    subgraph Runtime["Swift Concurrency"]
        CO["ConversionOrchestrator (actor)"]
        CJS["ConversionJobStore (actor)"]
    end
    CV --> PC
    LVV --> PC
    RCV --> PC
    PC -->|"enqueue / pause / stop / refreshToolPaths"| CO
    CO -->|"replaceAll snapshots"| CJS
    CO -->|"AsyncStream events"| PC
    CJS -->|"~/Library/.../MediaVault/state/jobs.json"| Disk[("JSON on disk")]
```

## Lane scheduling

Default limits are defined where `PipelineController` constructs `ConversionOrchestrator` (see `MediaVaultApp.init` / `PipelineController.init`): **file lane = 2** concurrent workers, **disc lane = 1** (optical drive is typically the bottleneck).

```mermaid
flowchart TD
    QF["Queued jobs (lane=file)"] --> SF{"running file count < limit?"}
    SF -->|"Yes"| RF["Start next file job"]
    SF -->|"No"| WF["Wait for slot"]
    QD["Queued jobs (lane=disc)"] --> SD{"running disc count < limit?"}
    SD -->|"Yes"| RD["Start next disc job"]
    SD -->|"No"| WD["Wait for slot"]
```

## Job lifecycle (orchestrator)

`ManagedJob.state` drives the UI badges. Persisted records map terminal/transient states to `PersistedJobState` for disk snapshots.

```mermaid
stateDiagram-v2
    [*] --> queued
    queued --> running: slot available
    running --> pausing: user pause OR lane pause
    pausing --> paused: process stopped / parked
    running --> paused: cooperative pause mid-stage
    running --> stopping: user stop
    stopping --> stopped: SIGTERM/SIGKILL + cleanup
    running --> completed: pipeline success
    running --> failed: pipeline error
    paused --> running: resume (SIGCONT or re-queue)
    stopped --> [*]
    completed --> [*]
    failed --> [*]
```

## Sequence: enqueue → run → persist

```mermaid
sequenceDiagram
    participant U as User
    participant CV as ContentView
    participant PC as PipelineController
    participant CO as ConversionOrchestrator
    participant CJS as ConversionJobStore
    participant CLI as External CLI

    U->>CV: Convert
    CV->>PC: enqueue(sources, output, options)
    PC->>CO: enqueue (Task per source)
    CO->>CO: scheduleAvailableWork()
    CO->>CLI: runProcess (per stage)
    CLI-->>CO: stdout/stderr lines
    CO->>PC: OrchestratorEvent.state / .log
    CO->>CJS: replaceAll(jobs)
    CJS->>CJS: atomic JSON write
```

## Sequence: graceful app termination

`NSApplicationDelegate.applicationShouldTerminate` returns `.terminateLater` while the pipeline asks the orchestrator to flush state and kill children. See `MediaVaultApp.swift` / `AppDelegate`.

```mermaid
sequenceDiagram
    participant AppKit as AppKit
    participant AD as AppDelegate
    participant PC as PipelineController
    participant CO as ConversionOrchestrator

    AppKit->>AD: applicationShouldTerminate
    AD->>PC: forceTerminateForAppExit (async)
    PC->>CO: forceTerminateForAppExit
    CO->>CO: mark running jobs paused + SIGKILL children
    CO->>CO: await store.replaceAll(...)
    PC-->>AD: done
    AD->>AppKit: reply(terminate:true)
```

## Persistence model (JSON, not SQLite)

The attached historical plan mentioned SQLite; the **implemented** store is a versioned JSON document:

- Path: `~/Library/Application Support/MediaVault/state/jobs.json`
- Writer: `ConversionJobStore` uses `Data.write(..., .atomic)` for crash-safe replacement.
- Decoder uses **ISO-8601** dates to match the encoder (required for round-trip).

```mermaid
erDiagram
    PersistedJobStoreRoot ||--o{ PersistedJob : contains
    PersistedJobStoreRoot {
        int schemaVersion
        string appBuild
        datetime updatedAt
    }
    PersistedJob {
        uuid id
        string lane
        string sourcePath
        string outputDirectoryPath
        string state
        json options
        list completedStages
        string currentStage
        float currentStageProgress
    }
```

### Corruption and version mismatch

- **Parse failure / unreadable JSON**: file is moved aside to `jobs.json.corrupt-<timestamp>-<reason>`; UI receives `ConversionJobStoreLoadOutcome.quarantined`.
- **Unknown `schemaVersion`**: same quarantine path; user-facing recovery alert via `PipelineController.recoveryAlert`.

## Pause / resume / stop semantics (verified constraints)

Authoritative commentary lives in `ToolCheckpointAdapter.swift`. Summary:

- **In-session pause** uses `Process.suspend()` / `resume()` (documented as SIGSTOP/SIGCONT). Stopped processes cannot rely on PIDs after app exit.
- **HandBrake / MakeMKV** do not expose portable mid-encode checkpoint files in this integration; resuming after relaunch may **restart the active stage** from the beginning.
- **FileBot / Subler** stages are treated as **idempotent** re-runs where safe.

## Process log

- `PipelineController` appends structured `PipelineLogEntry` rows for the main window stream.
- `LogViewerView` filters by process tag and substring search.

## Optional semver “pre-release” label vs build tags

Project policy (`.cursor/rules` and `build.sh`) uses GitHub release tags of the form **`0.1.0+<BUILD_NUMBER>`**, not `v1.2.0-beta.1`.

To mark a GitHub Release as **Pre-release** while keeping that tag format, run:

```bash
MEDIAVAULT_PRERELEASE=1 ./build.sh release
```

See `docs/BUILD_PROCESS.md` for details.
