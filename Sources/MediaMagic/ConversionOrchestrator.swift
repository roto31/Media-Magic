// ConversionOrchestrator.swift
// Actor-based scheduler for conversion jobs. Handles:
//   * Concurrent execution across two lanes (file + disc) and multiple
//     workers per lane.
//   * Per-job, per-lane and global pause / resume / stop controls.
//   * Durable state via `ConversionJobStore`.
//
// Concurrency model
// -----------------
// `ConversionOrchestrator` is a Swift `actor`. All mutable state lives inside
// it, so accesses are automatically serialised on the actor's executor
// (https://developer.apple.com/documentation/swift/actor). Subprocess I/O is
// performed by detached tasks reading from `Pipe` file handles, which is
// allowed because each pipe is owned by exactly one reader task; the parsed
// progress values are then hopped back onto the actor with `await`.
//
// We chose `actor` + Swift Concurrency over `OperationQueue` / `DispatchQueue`
// because:
//   * The work is structured (each job is an async function with well-defined
//     stages); cooperative cancellation via `Task.cancel()` integrates with
//     `Process.terminate()` and our pipe readers.
//   * Cross-job state (lane counts, queued sets, persisted snapshot) must be
//     mutated atomically, which an actor expresses directly without manual
//     locks.
//   * Apple positions Swift Concurrency as the modern model and explicitly
//     recommends actors for "mutable state shared across asynchronous
//     contexts" (Swift evolution SE-0306).
//
// Process control
// ---------------
// `Foundation.Process.suspend()` and `Process.resume()` are documented to
// send `SIGSTOP` and `SIGCONT` to the child process. Per POSIX `signal(3)`
// (Apple's Darwin man page), `SIGSTOP` cannot be caught, blocked or ignored,
// so it always halts the child. `Process.terminate()` sends `SIGTERM`. For
// hard kill we drop down to `kill(pid, SIGKILL)` from `<signal.h>` via
// `Darwin`. We never assume the PID is still valid after the `Process`
// object reports `isRunning == false`.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Lifecycle state (in-memory)

/// Mirrors `PersistedJobState` but with extra transient states that are not
/// worth persisting because they only exist while the executor is alive.
enum JobLifecycleState: String, Sendable, Equatable {
    case queued
    case running
    case pausing       // pause requested, executor will honour at next safe point
    case paused
    case stopping      // stop requested, executor is winding down
    case stopped
    case completed
    case failed
}

// MARK: - Managed (in-memory) job

/// Authoritative in-memory view of a job inside the orchestrator. The store
/// snapshot is derived from this on every state change.
struct ManagedJob: Identifiable, Sendable, Equatable {
    var id: ConversionJobID
    var lane: PipelineLane
    var sourcePath: String
    var displayName: String
    var outputDirectoryPath: String
    var options: PersistedRunOptions

    var state: JobLifecycleState
    var completedStages: [PipelineStage]
    var currentStage: PipelineStage
    var currentStageProgress: Double
    var currentStageNote: String

    var errorMessage: String?
    var finalPath: String?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var pausedAt: Date?

    static func == (lhs: ManagedJob, rhs: ManagedJob) -> Bool {
        lhs.id == rhs.id
            && lhs.lane == rhs.lane
            && lhs.sourcePath == rhs.sourcePath
            && lhs.displayName == rhs.displayName
            && lhs.outputDirectoryPath == rhs.outputDirectoryPath
            && lhs.options == rhs.options
            && lhs.state == rhs.state
            && lhs.completedStages == rhs.completedStages
            && lhs.currentStage == rhs.currentStage
            && abs(lhs.currentStageProgress - rhs.currentStageProgress) < 0.0001
            && lhs.currentStageNote == rhs.currentStageNote
            && lhs.errorMessage == rhs.errorMessage
            && lhs.finalPath == rhs.finalPath
            && lhs.createdAt == rhs.createdAt
            && lhs.startedAt == rhs.startedAt
            && lhs.finishedAt == rhs.finishedAt
            && lhs.pausedAt == rhs.pausedAt
    }
}

// MARK: - Events emitted back to the UI layer

enum OrchestratorEvent: Sendable {
    case state(jobs: [ManagedJob])
    case log(jobID: ConversionJobID?, process: PipelineLogProcess, message: String, timestamp: Date)
    case jobFinished(id: ConversionJobID, success: Bool)
    case allDrained
}

// MARK: - Errors

enum OrchestratorError: Error, LocalizedError {
    case toolMissing(String)
    case sourceMissing(path: String)
    case outputDirectoryUnavailable(path: String)
    case handBrakeProducedNothing
    case makeMKVProducedNoFiles
    case nonzeroExit(stage: PipelineStage, status: Int32)
    case stopped
    case paused

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return "Required tool not available: \(name)"
        case .sourceMissing(let path):
            return "Source no longer exists at \(path)"
        case .outputDirectoryUnavailable(let path):
            return "Output directory is not writable: \(path)"
        case .handBrakeProducedNothing:
            return "HandBrake produced no output file"
        case .makeMKVProducedNoFiles:
            return "MakeMKV produced no MKV files"
        case .nonzeroExit(let stage, let status):
            return "\(stage.rawValue) exited with status \(status)"
        case .stopped:
            return "Job was stopped"
        case .paused:
            return "Job was paused"
        }
    }
}

// MARK: - Per-job runtime context (kept off the persisted record)

private final class JobRuntime {
    var process: Process?
    var task: Task<Void, Never>?
    /// `true` if user requested pause; the executor will SIGSTOP the active
    /// process and break out at the next safe boundary.
    var pauseRequested: Bool = false
    /// `true` if user requested stop; the executor will SIGTERM and unwind.
    var stopRequested: Bool = false
    /// Latest `[MOVE] from […] to […]` destination parsed from FileBot output (this run).
    var lastFileBotMoveToPath: String?
}

// MARK: - Orchestrator

actor ConversionOrchestrator {

    /// Parses FileBot's ` [MOVE] from [A] to [B] ` line and returns `B`.
    private static func parseFileBotMoveDestination(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\[MOVE\] from \[.*\] to \[(.*)\]$"#,
            options: []
        ) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = regex.firstMatch(in: line, options: [], range: range),
              m.numberOfRanges >= 2,
              let destRange = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[destRange])
    }

    // MARK: Stored state

    private var jobs: [ConversionJobID: ManagedJob] = [:]
    private var jobOrder: [ConversionJobID] = []         // stable insertion order
    private var runtime: [ConversionJobID: JobRuntime] = [:]
    private var laneRunning: [PipelineLane: Set<ConversionJobID>] = [
        .file: [],
        .disc: []
    ]
    /// Maximum number of concurrently running jobs per lane.
    private var laneLimits: [PipelineLane: Int]
    private var paused: Set<PipelineLane> = []           // soft-pause flag per lane
    private var globalPaused: Bool = false

    /// Snapshot of resolved tool paths. Refreshed by the controller after
    /// `ToolManager.prepare()` completes. Kept inside the actor so we don't
    /// pay an `await` across the MainActor boundary on every subprocess
    /// launch.
    struct ToolPaths: Sendable {
        var handbrakeCLI: String?
        var sublerCLI: String?
        var makemkvCon: String?
        var filebot: String?
        var hasFileBot: Bool { filebot != nil }
        var hasMakeMKV: Bool { makemkvCon != nil }
    }
    private var toolPaths: ToolPaths = ToolPaths()

    private let store: ConversionJobStore

    /// Single shared AsyncStream the UI subscribes to.
    ///
    /// Marked `nonisolated` so MainActor code can subscribe without hopping
    /// through the actor. Safe because the stream is created in `init` and
    /// never mutated after.
    nonisolated let events: AsyncStream<OrchestratorEvent>
    private let eventsContinuation: AsyncStream<OrchestratorEvent>.Continuation

    // MARK: Init

    init(
        store: ConversionJobStore,
        laneLimits: [PipelineLane: Int] = [.file: 2, .disc: 1]
    ) {
        self.store = store
        self.laneLimits = laneLimits

        var continuation: AsyncStream<OrchestratorEvent>.Continuation!
        self.events = AsyncStream<OrchestratorEvent> { c in continuation = c }
        self.eventsContinuation = continuation
    }

    // MARK: - Public API: configuration

    func setLaneLimit(_ lane: PipelineLane, _ limit: Int) {
        laneLimits[lane] = max(1, limit)
        scheduleAvailableWork()
    }

    /// Refresh the snapshot of resolved tool binary paths. The MainActor
    /// `ToolManager` calls this after `prepare()` completes so the actor can
    /// run subprocesses without needing to bounce to MainActor on every
    /// stage launch.
    func updateToolPaths(_ paths: ToolPaths) {
        self.toolPaths = paths
        scheduleAvailableWork()
    }

    // MARK: - Public API: enqueue

    /// Adds a job to the queue. Multiple jobs in the same lane will run
    /// concurrently up to `laneLimits[lane]`.
    func enqueue(
        lane: PipelineLane,
        sourcePath: String,
        displayName: String,
        outputDirectoryPath: String,
        options: PipelineRunOptions
    ) -> ConversionJobID {
        let id = ConversionJobID()
        let job = ManagedJob(
            id: id,
            lane: lane,
            sourcePath: sourcePath,
            displayName: displayName,
            outputDirectoryPath: outputDirectoryPath,
            options: PersistedRunOptions(from: options),
            state: .queued,
            completedStages: [],
            currentStage: .idle,
            currentStageProgress: 0,
            currentStageNote: "",
            errorMessage: nil,
            finalPath: nil,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            pausedAt: nil
        )
        jobs[id] = job
        jobOrder.append(id)
        runtime[id] = JobRuntime()
        persistAndEmit()
        scheduleAvailableWork()
        return id
    }

    /// Restores jobs loaded from disk on launch. Anything that was `running`
    /// is forced to `paused` because there's no way to reattach to the prior
    /// child process.
    func hydrate(from persisted: [PersistedJob]) {
        for record in persisted {
            // An app exit while the executor was inside a stage cannot
            // produce a faithful "running" restoration because we no longer
            // own the child process. Force such records to `paused` so the
            // user must explicitly resume them; the active stage will then
            // restart from its beginning per `ToolCheckpointAdapter`.
            let lifecycle: JobLifecycleState = {
                switch record.state {
                case .queued:    return .queued
                case .running:   return .paused
                case .paused:    return .paused
                case .stopped:   return .stopped
                case .completed: return .completed
                case .failed:    return .failed
                }
            }()

            let job = ManagedJob(
                id: record.id,
                lane: record.lane,
                sourcePath: record.sourcePath,
                displayName: record.displayName,
                outputDirectoryPath: record.outputDirectoryPath,
                options: record.options,
                state: lifecycle,
                completedStages: record.completedStages.compactMap { PipelineStage(rawValue: $0) },
                currentStage: PipelineStage(rawValue: record.currentStage) ?? .idle,
                currentStageProgress: record.currentStageProgress,
                currentStageNote: record.currentStageNote,
                errorMessage: record.errorMessage,
                finalPath: record.finalPath,
                createdAt: record.createdAt,
                startedAt: record.startedAt,
                finishedAt: record.finishedAt,
                pausedAt: record.pausedAt ?? Date()
            )
            jobs[record.id] = job
            jobOrder.append(record.id)
            runtime[record.id] = JobRuntime()
        }
        persistAndEmit()
    }

    // MARK: - Public API: pause / resume / stop

    func pauseJob(_ id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        switch job.state {
        case .running:
            runtime[id]?.pauseRequested = true
            if let p = runtime[id]?.process, p.isRunning {
                // Documented as SIGSTOP under the hood.
                _ = p.suspend()
            }
            job.state = .pausing
            job.pausedAt = Date()
            jobs[id] = job
        case .queued:
            job.state = .paused
            job.pausedAt = Date()
            jobs[id] = job
        default:
            break
        }
        persistAndEmit()
    }

    func resumeJob(_ id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        switch job.state {
        case .paused, .pausing:
            // If the underlying process is still alive (in-session pause),
            // SIGCONT it. Otherwise we'll restart the active stage when the
            // executor runs.
            if let p = runtime[id]?.process, p.isRunning {
                _ = p.resume()
                runtime[id]?.pauseRequested = false
                job.state = .running
                jobs[id] = job
            } else {
                runtime[id]?.pauseRequested = false
                job.state = .queued
                jobs[id] = job
                scheduleAvailableWork()
            }
        case .stopped, .failed:
            // "Resume" of a terminal state means re-queue: the active stage
            // resumes from the last completed stage boundary.
            job.state = .queued
            job.errorMessage = nil
            job.currentStageProgress = 0
            jobs[id] = job
            scheduleAvailableWork()
        default:
            break
        }
        persistAndEmit()
    }

    func pauseLane(_ lane: PipelineLane) {
        paused.insert(lane)
        for id in jobsInLane(lane) {
            pauseJob(id)
        }
        persistAndEmit()
    }

    func resumeLane(_ lane: PipelineLane) {
        paused.remove(lane)
        for id in jobsInLane(lane) {
            resumeJob(id)
        }
        scheduleAvailableWork()
    }

    func pauseAll() {
        globalPaused = true
        for lane in PipelineLane.allCases { paused.insert(lane) }
        for id in jobOrder { pauseJob(id) }
    }

    func resumeAll() {
        globalPaused = false
        paused.removeAll()
        for id in jobOrder { resumeJob(id) }
        scheduleAvailableWork()
    }

    func stopJob(_ id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        switch job.state {
        case .running, .pausing, .paused, .queued:
            runtime[id]?.stopRequested = true
            terminateRunningProcess(id: id, hardKillAfter: .seconds(3))
            job.state = .stopping
            jobs[id] = job
        default:
            break
        }
        persistAndEmit()
    }

    func stopLane(_ lane: PipelineLane) {
        for id in jobsInLane(lane) {
            stopJob(id)
        }
    }

    func stopAll() {
        for id in jobOrder { stopJob(id) }
    }

    // Returns the set of jobs that currently match the predicate.
    func currentSnapshot() -> [ManagedJob] {
        jobOrder.compactMap { jobs[$0] }
    }

    /// Hard-terminates everything in-flight without UI confirmation, marking
    /// each running job as paused first so that the resume flow on next
    /// launch can offer to restart the interrupted stage. Called from
    /// `applicationShouldTerminate` so we don't leave orphaned children.
    func forceTerminateForAppExit() async {
        let now = Date()
        for id in jobOrder {
            guard var job = jobs[id] else { continue }
            switch job.state {
            case .running, .pausing:
                job.state = .paused
                job.pausedAt = now
                jobs[id] = job
            default:
                break
            }
        }
        for (_, rt) in runtime {
            if let p = rt.process, p.isRunning {
                let pid = p.processIdentifier
                // SIGKILL is unblockable per POSIX `signal(3)` and is the only
                // way to reliably terminate a process that has been STOPPED
                // (SIGSTOP'd) by a prior pause request. Plain `terminate()`
                // (SIGTERM) gets queued behind the SIGSTOP and may never
                // deliver before the kernel reparents us to launchd.
                #if canImport(Darwin)
                _ = kill(pid, SIGKILL)
                #else
                p.terminate()
                #endif
            }
        }
        // Write a final snapshot synchronously (via `await`) before yielding
        // back to the caller, which is responsible for calling
        // `NSApp.reply(toApplicationShouldTerminate:)` only after this
        // returns. Disk I/O is bounded; we don't need a timeout here.
        let snapshot = jobOrder.compactMap { jobs[$0] }
        let persisted = snapshot.map(toPersisted)
        do {
            try await store.replaceAll(persisted)
        } catch {
            // Best-effort: we can't surface UI at shutdown; the user can
            // still recover from the previous snapshot on next launch.
        }
    }

    // MARK: - Scheduling

    /// Pumps the queue: while a lane has free worker slots and a queued job,
    /// start the next one. Idempotent — safe to call after any state change.
    private func scheduleAvailableWork() {
        for lane in PipelineLane.allCases {
            guard !globalPaused, !paused.contains(lane) else { continue }
            let limit = laneLimits[lane] ?? 1
            while (laneRunning[lane]?.count ?? 0) < limit {
                guard let nextID = pickNextQueuedJob(on: lane) else { break }
                startJob(nextID)
            }
        }
    }

    private func pickNextQueuedJob(on lane: PipelineLane) -> ConversionJobID? {
        for id in jobOrder {
            guard let job = jobs[id] else { continue }
            if job.lane == lane && job.state == .queued {
                return id
            }
        }
        return nil
    }

    private func startJob(_ id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        job.state = .running
        if job.startedAt == nil { job.startedAt = Date() }
        jobs[id] = job
        laneRunning[job.lane]?.insert(id)
        persistAndEmit()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeJob(id)
        }
        runtime[id]?.task = task
    }

    // MARK: - Executor

    /// Drives a single job through its remaining stages. Updates state on
    /// every event and surfaces errors as `.failed`. Honors pause/stop flags
    /// at safe points.
    private func executeJob(_ id: ConversionJobID) async {
        defer {
            if var job = jobs[id] {
                laneRunning[job.lane]?.remove(id)
                if job.state == .running { job.state = .completed }
                jobs[id] = job
            }
            runtime[id]?.process = nil
            scheduleAvailableWork()
            persistAndEmit()
            if allTerminal() {
                eventsContinuation.yield(.allDrained)
            }
        }

        guard let initial = jobs[id] else { return }
        let outputDir = URL(fileURLWithPath: initial.outputDirectoryPath, isDirectory: true)

        // Source / output preflight — fail fast and clearly.
        let fm = FileManager.default
        if !fm.fileExists(atPath: initial.outputDirectoryPath) {
            failJob(id, error: .outputDirectoryUnavailable(path: initial.outputDirectoryPath))
            return
        }
        // Disc sources are device paths, e.g. `/dev/disk4` or the Blu-ray
        // marker — those don't need to exist as ordinary files.
        let isDiscSource = initial.sourcePath.hasPrefix("/dev/")
            || initial.sourcePath.hasPrefix(PipelineQueuedWire.bluRayRipPendingMarker + "::")
        if !isDiscSource && !fm.fileExists(atPath: initial.sourcePath) {
            failJob(id, error: .sourceMissing(path: initial.sourcePath))
            return
        }

        do {
            try await runStages(id: id, outputDir: outputDir)
            markJobCompleted(id)
        } catch let err as OrchestratorError {
            switch err {
            case .stopped:
                if var job = jobs[id] {
                    job.state = .stopped
                    job.finishedAt = Date()
                    jobs[id] = job
                }
            case .paused:
                if var job = jobs[id] {
                    job.state = .paused
                    job.pausedAt = Date()
                    jobs[id] = job
                }
            default:
                failJob(id, error: err)
            }
        } catch {
            failJob(id, error: .nonzeroExit(stage: jobs[id]?.currentStage ?? .idle, status: -1))
            if var job = jobs[id] {
                job.errorMessage = error.localizedDescription
                jobs[id] = job
            }
        }
    }

    /// Iterates the pipeline stages, skipping any already marked completed
    /// (idempotent stages re-run for free; mid-stage tools restart from zero
    /// per `ToolCheckpointAdapter`).
    private func runStages(id: ConversionJobID, outputDir: URL) async throws {
        guard let snapshot = jobs[id] else { return }
        let runOptions = snapshot.options.toRuntime()

        // --- Stage: MakeMKV (only for Blu-ray jobs) ---
        var workingPath = snapshot.sourcePath
        if let ripDir = try PipelineQueuedWire.bluRayRipDirectoryIfPresent(in: workingPath),
           !isStageComplete(.ripping, in: id) {
            try await beginStage(.ripping, on: id, note: "Ripping disc — this can take 30–60 minutes")
            workingPath = try await runMakeMKV(id: id, ripFolder: ripDir)
            markStageComplete(.ripping, on: id)
        } else if let ripDir = try PipelineQueuedWire.bluRayRipDirectoryIfPresent(in: workingPath) {
            // We've already ripped; pick the largest mkv as before.
            workingPath = (try pickLargestMKV(in: ripDir)) ?? workingPath
        }

        // --- Stage: HandBrake ---
        let outFile: String = {
            let baseName: String
            if workingPath.hasPrefix("/dev/") {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd_HHmmss"
                baseName = "DVD_\(f.string(from: Date()))"
            } else {
                baseName = (((workingPath as NSString).lastPathComponent) as NSString).deletingPathExtension
            }
            return outputDir.appendingPathComponent(baseName).appendingPathExtension("m4v").path
        }()

        if !isStageComplete(.encoding, in: id) {
            try await beginStage(.encoding, on: id, note: "Transcoding to Apple 4K HEVC…")
            try await runHandBrake(id: id, source: workingPath, outFile: outFile, options: runOptions)
            markStageComplete(.encoding, on: id)
        }
        updateFinalPath(id, path: outFile)

        var mediaPath = outFile

        // --- Stage: FileBot rename ---
        if !runOptions.skipFileBot, toolPaths.hasFileBot, !isStageComplete(.renaming, in: id) {
            try await beginStage(.renaming, on: id, note: "Looking up metadata (\(runOptions.fileBotDB))…")
            mediaPath = try await runFileBot(id: id, input: mediaPath, options: runOptions)
            markStageComplete(.renaming, on: id)
            updateFinalPath(id, path: mediaPath)
        } else if runOptions.skipFileBot {
            markStageComplete(.renaming, on: id)
            log(id, .fileBot, "FileBot skipped by run option")
        } else if !toolPaths.hasFileBot {
            markStageComplete(.renaming, on: id)
            log(id, .fileBot, "FileBot not available; skipping rename stage")
        }

        // --- Stage: FileBot post-rename script (optional) ---
        if let ps = runOptions.fileBotPostScript,
           ps.enabled,
           !ps.descriptorId.isEmpty,
           toolPaths.hasFileBot,
           !isStageComplete(.fileBotScript, in: id) {
            try await beginStage(.fileBotScript, on: id, note: "FileBot script (\(ps.descriptorId))…")
            try await runFileBotScript(id: id, input: mediaPath, postScript: ps)
            markStageComplete(.fileBotScript, on: id)
        }

        // --- Stage: Subler tag ---
        if !runOptions.skipSubler, !isStageComplete(.tagging, in: id) {
            try await beginStage(.tagging, on: id, note: "Fetching cover art and metadata…")
            try await runSubler(id: id, input: mediaPath, options: runOptions)
            markStageComplete(.tagging, on: id)
        }

        // --- Post-stage: copy to Apple TV auto-import if requested ---
        if runOptions.copyToAppleTVImport {
            let copied = try copyToAppleTVAutoImport(sourcePath: jobs[id]?.finalPath ?? mediaPath)
            updateFinalPath(id, path: copied)
            log(id, .appleTVImport, "Copied to Apple TV auto-import: \(copied)")
        }
    }

    // MARK: - Stage runners

    private func runMakeMKV(id: ConversionJobID, ripFolder: String) async throws -> String {
        guard let bin = toolPaths.makemkvCon else {
            throw OrchestratorError.toolMissing("MakeMKV (makemkvcon)")
        }
        try FileManager.default.createDirectory(atPath: ripFolder, withIntermediateDirectories: true)
        let args = ["-r", "--minlength=3600", "--progress=-stderr", "mkv", "disc:0", "all", ripFolder]
        try await runProcess(
            id: id,
            launchPath: bin,
            arguments: args,
            stage: .ripping,
            logProcess: .makeMKV,
            parseLine: { line in
                if line.hasPrefix("PRGV:") {
                    let nums = line.dropFirst(5).split(separator: ",")
                    if nums.count == 3,
                       let total = Double(nums[1]),
                       let maximum = Double(nums[2]),
                       maximum > 0 {
                        return total / maximum
                    }
                }
                return nil
            }
        )
        guard let largest = try pickLargestMKV(in: ripFolder) else {
            throw OrchestratorError.makeMKVProducedNoFiles
        }
        return largest
    }

    private func pickLargestMKV(in ripFolder: String) throws -> String? {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: ripFolder)
        let mkvs = contents.filter { $0.hasSuffix(".mkv") }
        guard !mkvs.isEmpty else { return nil }
        let largest = mkvs.max { lhs, rhs in
            let l = (try? fm.attributesOfItem(atPath: "\(ripFolder)/\(lhs)")[.size] as? NSNumber)?.intValue ?? 0
            let r = (try? fm.attributesOfItem(atPath: "\(ripFolder)/\(rhs)")[.size] as? NSNumber)?.intValue ?? 0
            return l < r
        }
        return largest.map { "\(ripFolder)/\($0)" }
    }

    private func runHandBrake(
        id: ConversionJobID,
        source: String,
        outFile: String,
        options: PipelineRunOptions
    ) async throws {
        guard let bin = toolPaths.handbrakeCLI else {
            throw OrchestratorError.toolMissing("HandBrakeCLI")
        }
        let baseArgs = [
            "-i", source,
            "-o", outFile,
            "--preset-import-gui",
            "--preset", options.handBrakePreset,
            "-v", "1"
        ]
        try await runProcess(
            id: id,
            launchPath: bin,
            arguments: baseArgs + options.handBrakeExtraArgs,
            stage: .encoding,
            logProcess: .handBrake,
            parseLine: { line in
                if let range = line.range(of: #"Encoding:.* ([0-9.]+) %"#, options: .regularExpression) {
                    let chunk = String(line[range])
                    if let pctRange = chunk.range(of: #"([0-9.]+) %"#, options: .regularExpression) {
                        let raw = String(chunk[pctRange]).replacingOccurrences(of: " %", with: "")
                        if let pct = Double(raw) { return pct / 100.0 }
                    }
                }
                return nil
            }
        )
        let fm = FileManager.default
        guard fm.fileExists(atPath: outFile),
              let attrs = try? fm.attributesOfItem(atPath: outFile),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0 else {
            throw OrchestratorError.handBrakeProducedNothing
        }
    }

    private func runFileBot(
        id: ConversionJobID,
        input: String,
        options: PipelineRunOptions
    ) async throws -> String {
        guard let bin = toolPaths.filebot else { return input }
        var args: [String] = [
            "-rename", input,
            "--db", options.fileBotDB,
            "--format", options.fileBotFormat
        ]
        if !options.fileBotEpisodeOrder.isEmpty {
            args.append(contentsOf: ["--order", options.fileBotEpisodeOrder])
        }
        if options.fileBotApplyArtwork {
            args.append(contentsOf: ["--apply", "artwork"])
        }
        args.append(contentsOf: options.fileBotExtraArgs)

        let parentDir = URL(fileURLWithPath: input).deletingLastPathComponent()
        let inputURL = URL(fileURLWithPath: input)
        let inputSize: Int64 = {
            guard let v = try? inputURL.resourceValues(forKeys: [.fileSizeKey]),
                  let n = v.fileSize else { return -1 }
            return Int64(n)
        }()

        runtime[id]?.lastFileBotMoveToPath = nil

        try await runProcess(
            id: id,
            launchPath: bin,
            arguments: args,
            stage: .renaming,
            logProcess: .fileBot,
            parseLine: { _ in nil }
        )

        let fm = FileManager.default
        // FileBot `--action move` preserves the file's mtime from HandBrake, which
        // is before the moment we started FileBot — `mod >= runStart` matched nothing.
        if fm.fileExists(atPath: input) {
            return input
        }

        if let hint = runtime[id]?.lastFileBotMoveToPath,
           fm.fileExists(atPath: hint) {
            return hint
        }

        if let dirItems = try? fm.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            let candidates = dirItems.filter { url in
                let ext = url.pathExtension.lowercased()
                guard ["m4v", "mp4", "mkv"].contains(ext) else { return false }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      values.contentModificationDate != nil else {
                    return false
                }
                return true
            }
            let sizeMatched: [URL] = {
                guard inputSize > 0 else { return [] }
                return candidates.filter { url in
                    guard let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
                    let s = Int64(sz)
                    let delta = abs(s - inputSize)
                    let threshold = max(5_242_880, inputSize / 20)
                    return delta <= threshold
                }
            }()
            let pool = sizeMatched.isEmpty ? candidates : sizeMatched
            if let newest = pool.max(by: { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lm < rm
            }), fm.fileExists(atPath: newest.path) {
                return newest.path
            }
        }
        return input
    }

    private func runFileBotScript(
        id: ConversionJobID,
        input: String,
        postScript: FileBotPostScriptRunOptions
    ) async throws {
        guard let bin = toolPaths.filebot else { return }
        let inputPath = postScript.inputUsesParentFolder
            ? (input as NSString).deletingLastPathComponent
            : input
        let args = try FileBotScriptLibrary.scriptProcessArguments(
            descriptorId: postScript.descriptorId,
            inputMediaPath: inputPath,
            extraArgsRaw: postScript.extraArgsRaw,
            defBlock: postScript.defBlock
        )
        try await runProcess(
            id: id,
            launchPath: bin,
            arguments: args,
            stage: .fileBotScript,
            logProcess: .fileBotScript,
            parseLine: { _ in nil }
        )
    }

    private func runSubler(
        id: ConversionJobID,
        input: String,
        options: PipelineRunOptions
    ) async throws {
        guard let bin = toolPaths.sublerCLI else {
            throw OrchestratorError.toolMissing("SublerCli")
        }
        let args = ["-source", input, "-optimize"] + options.sublerExtraArgs
        try await runProcess(
            id: id,
            launchPath: bin,
            arguments: args,
            stage: .tagging,
            logProcess: .subler,
            parseLine: { _ in nil }
        )
    }

    private func copyToAppleTVAutoImport(sourcePath: String) throws -> String {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath:
            "/Users/chris/Movies/TV/Media.localized/Automatically Add To TV.localized",
            isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        var destinationURL = dest.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: destinationURL.path) {
            let base = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            var idx = 1
            repeat {
                destinationURL = dest.appendingPathComponent("\(base)_\(idx)").appendingPathExtension(ext)
                idx += 1
            } while fm.fileExists(atPath: destinationURL.path)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    // MARK: - Process runner (per-stage, instrumented, pause/stop-aware)

    /// Generic process runner: streams stdout+stderr, parses progress, honours
    /// stop and pause requests. Throws `OrchestratorError.stopped` /`.paused`
    /// so the caller can unwind cleanly.
    private func runProcess(
        id: ConversionJobID,
        launchPath: String,
        arguments: [String],
        stage: PipelineStage,
        logProcess: PipelineLogProcess,
        parseLine: @Sendable @escaping (String) -> Double?
    ) async throws {
        log(id, logProcess, "$ \(launchPath) \(arguments.joined(separator: " "))")

        // Cooperative cancellation check before launching.
        if runtime[id]?.stopRequested == true { throw OrchestratorError.stopped }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Capture process before launch so cancel arrives via runtime map.
        runtime[id]?.process = proc

        // Per-job, per-process pipe readers. These tasks publish parsed lines
        // back to the actor via `acceptLine`; we never mutate state from the
        // background context directly.
        let outTask = streamPipe(outPipe, id: id, logProcess: logProcess, parseLine: parseLine)
        let errTask = streamPipe(errPipe, id: id, logProcess: logProcess, parseLine: parseLine)

        do {
            try proc.run()
        } catch {
            outTask.cancel()
            errTask.cancel()
            runtime[id]?.process = nil
            throw OrchestratorError.nonzeroExit(stage: stage, status: -1)
        }

        // Wait off the actor's executor so we don't starve other jobs.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }
        _ = await outTask.value
        _ = await errTask.value
        runtime[id]?.process = nil

        // After process exits, classify outcome.
        if runtime[id]?.stopRequested == true {
            throw OrchestratorError.stopped
        }
        if runtime[id]?.pauseRequested == true {
            // SIGSTOP'd process may have been forcibly terminated by us when
            // the app quit. Treat the job as paused so on resume we re-run
            // the active stage from the beginning per the capability table.
            runtime[id]?.pauseRequested = false
            throw OrchestratorError.paused
        }
        if proc.terminationStatus != 0 {
            throw OrchestratorError.nonzeroExit(stage: stage, status: proc.terminationStatus)
        }
    }

    private nonisolated func streamPipe(
        _ pipe: Pipe,
        id: ConversionJobID,
        logProcess: PipelineLogProcess,
        parseLine: @Sendable @escaping (String) -> Double?
    ) -> Task<Void, Never> {
        Task.detached { [weak self] in
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    if let line = String(data: lineData, encoding: .utf8) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let pct = parseLine(trimmed)
                            await self?.acceptLine(
                                trimmed,
                                progress: pct,
                                id: id,
                                logProcess: logProcess
                            )
                        }
                    }
                }
            }
            // EOF: many CLIs print errors without a trailing newline; those bytes
            // would otherwise never reach `acceptLine` (hypothesis H9).
            if !buffer.isEmpty {
                let tail = String(decoding: buffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    let pct = parseLine(tail)
                    await self?.acceptLine(tail, progress: pct, id: id, logProcess: logProcess)
                }
            }
        }
    }

    /// Called by pipe readers on the actor's executor.
    private func acceptLine(
        _ line: String,
        progress: Double?,
        id: ConversionJobID,
        logProcess: PipelineLogProcess
    ) {
        log(id, logProcess, line)
        if logProcess == .fileBot, let dest = Self.parseFileBotMoveDestination(line) {
            runtime[id]?.lastFileBotMoveToPath = dest
        }
        if let pct = progress, var job = jobs[id] {
            job.currentStageProgress = max(0, min(1, pct))
            jobs[id] = job
            persistAndEmit()
        }
    }

    // MARK: - Stage bookkeeping

    private func isStageComplete(_ stage: PipelineStage, in id: ConversionJobID) -> Bool {
        jobs[id]?.completedStages.contains(stage) ?? false
    }

    private func beginStage(
        _ stage: PipelineStage,
        on id: ConversionJobID,
        note: String
    ) async throws {
        if runtime[id]?.stopRequested == true { throw OrchestratorError.stopped }
        if runtime[id]?.pauseRequested == true { throw OrchestratorError.paused }
        guard var job = jobs[id] else { return }
        job.currentStage = stage
        job.currentStageProgress = 0
        job.currentStageNote = note
        jobs[id] = job
        persistAndEmit()
    }

    private func markStageComplete(_ stage: PipelineStage, on id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        if !job.completedStages.contains(stage) {
            job.completedStages.append(stage)
        }
        job.currentStageProgress = 1
        jobs[id] = job
        persistAndEmit()
    }

    private func updateFinalPath(_ id: ConversionJobID, path: String) {
        guard var job = jobs[id] else { return }
        job.finalPath = path
        jobs[id] = job
        persistAndEmit()
    }

    private func markJobCompleted(_ id: ConversionJobID) {
        guard var job = jobs[id] else { return }
        job.state = .completed
        job.currentStage = .done
        job.finishedAt = Date()
        job.errorMessage = nil
        jobs[id] = job
        eventsContinuation.yield(.jobFinished(id: id, success: true))
        persistAndEmit()
    }

    private func failJob(_ id: ConversionJobID, error: OrchestratorError) {
        guard var job = jobs[id] else { return }
        job.state = .failed
        job.currentStage = .failed
        job.finishedAt = Date()
        job.errorMessage = error.localizedDescription
        jobs[id] = job
        log(id, .system, "ERROR: \(error.localizedDescription)")
        eventsContinuation.yield(.jobFinished(id: id, success: false))
        persistAndEmit()
    }

    // MARK: - Helpers

    private func jobsInLane(_ lane: PipelineLane) -> [ConversionJobID] {
        jobOrder.filter { (jobs[$0]?.lane ?? .file) == lane }
    }

    private func allTerminal() -> Bool {
        for id in jobOrder {
            switch jobs[id]?.state {
            case .completed, .failed, .stopped, .paused, .none:
                continue
            default:
                return false
            }
        }
        return true
    }

    /// Sends SIGTERM (and after a grace period, SIGKILL) to the child process
    /// associated with `id`, if any.
    private func terminateRunningProcess(id: ConversionJobID, hardKillAfter grace: DispatchTimeInterval) {
        guard let proc = runtime[id]?.process, proc.isRunning else { return }
        proc.terminate() // SIGTERM per Foundation docs
        let pid = proc.processIdentifier
        // Fallback hard-kill if the child ignores SIGTERM (some build of the
        // tool may install a handler that delays exit).
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            #if canImport(Darwin)
            // `kill(2)` with SIGKILL is unblockable per POSIX; ignore EPERM
            // (process exited already).
            _ = kill(pid, SIGKILL)
            #endif
        }
    }

    // MARK: - Persistence + UI fan-out

    /// Persist the current snapshot and emit a UI state event.
    private func persistAndEmit() {
        let snapshot = jobOrder.compactMap { jobs[$0] }
        eventsContinuation.yield(.state(jobs: snapshot))
        let persisted = snapshot.map(toPersisted)
        Task.detached(priority: .utility) { [store] in
            // Detached so persistence I/O doesn't stall the actor for the
            // duration of disk write.
            do {
                try await store.replaceAll(persisted)
            } catch {
                // Swallow: persistence failure shouldn't crash the run. We
                // still have in-memory truth; the user-facing alert at
                // launch surfaces persistent corruption.
            }
        }
    }

    private nonisolated func toPersisted(_ job: ManagedJob) -> PersistedJob {
        PersistedJob(
            id: job.id,
            lane: job.lane,
            sourcePath: job.sourcePath,
            displayName: job.displayName,
            outputDirectoryPath: job.outputDirectoryPath,
            options: job.options,
            state: persistedState(for: job.state),
            completedStages: job.completedStages.map { $0.rawValue },
            currentStage: job.currentStage.rawValue,
            currentStageProgress: job.currentStageProgress,
            currentStageNote: job.currentStageNote,
            errorMessage: job.errorMessage,
            finalPath: job.finalPath,
            createdAt: job.createdAt,
            updatedAt: Date(),
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            pausedAt: job.pausedAt,
            appBuildAtPersist: ConversionJobSchema.appBuildIdentifier
        )
    }

    private nonisolated func persistedState(for state: JobLifecycleState) -> PersistedJobState {
        switch state {
        case .queued:    return .queued
        case .running:   return .running
        case .pausing:   return .paused
        case .paused:    return .paused
        case .stopping:  return .stopped
        case .stopped:   return .stopped
        case .completed: return .completed
        case .failed:    return .failed
        }
    }

    // MARK: - Logging fan-out

    private func log(_ id: ConversionJobID, _ logProcess: PipelineLogProcess, _ message: String) {
        eventsContinuation.yield(.log(jobID: id, process: logProcess, message: message, timestamp: Date()))
    }
}
