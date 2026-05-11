// PipelineController.swift
// MainActor-side facade for the concurrent conversion orchestrator. Owns the
// SwiftUI `@Published` projection and translates user intent (start, pause,
// stop) into actor calls.
//
// Architecture
// ------------
// The heavy lifting lives in `ConversionOrchestrator` (an `actor`). This
// controller subscribes to the orchestrator's event stream and re-publishes
// the snapshot on MainActor so SwiftUI views can bind directly to it.
//
// Concurrency
// -----------
// `ContentView` and other views read/write through this MainActor class only.
// We never expose `Process` instances or other non-Sendable types across
// actor boundaries; everything that crosses is `Sendable` (events, snapshots,
// log entries).

import Foundation
import SwiftUI
import UserNotifications

// MARK: - Logging model (kept here so LogViewerView API doesn't change)

enum PipelineLogProcess: String, CaseIterable, Identifiable, Sendable {
    case system = "System"
    case makeMKV = "MakeMKV"
    case handBrake = "HandBrake"
    case fileBot = "FileBot"
    case fileBotScript = "FileBot Script"
    case subler = "Subler"
    case appleTVImport = "Apple TV Import"

    var id: String { rawValue }
}

struct PipelineLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let process: PipelineLogProcess
    let message: String
    let jobID: UUID?

    init(timestamp: Date, process: PipelineLogProcess, message: String, jobID: UUID? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.process = process
        self.message = message
        self.jobID = jobID
    }
}

// MARK: - Source kind / stage / lane

enum SourceKind: String, CaseIterable, Identifiable {
    case videoFile = "Video File"
    case dvd       = "DVD"
    case bluray    = "Blu-ray"
    var id: String { rawValue }
}

enum PipelineStage: String, Codable {
    case idle      = "Idle"
    case ripping   = "Ripping (MakeMKV)"
    case encoding  = "Encoding (HandBrake)"
    case renaming  = "Renaming (FileBot)"
    case fileBotScript = "FileBot script"
    case tagging   = "Tagging (Subler)"
    case done      = "Complete"
    case failed    = "Failed"
}

enum PipelineLane: String, Codable, CaseIterable, Identifiable, Sendable {
    case file = "File"
    case disc = "Disc"
    var id: String { rawValue }
}

// MARK: - UI item (derived from `ManagedJob`)

struct ConversionItem: Identifiable, Equatable, Sendable {
    /// Matches the orchestrator's `ConversionJobID.raw` so SwiftUI keeps row
    /// identity stable across snapshot deltas.
    let id: UUID
    let jobID: ConversionJobID
    let lane: PipelineLane
    let sourcePath: String
    var displayName: String
    var stage: PipelineStage
    var stageProgress: Double
    var lifecycle: JobLifecycleState
    var startedAt: Date?
    var finishedAt: Date?
    var finalPath: String?
    var errorMessage: String?
    var stageNote: String

    var elapsed: TimeInterval {
        guard let start = startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(start)
    }
}

// MARK: - Lane activity summary

struct LaneActivitySummary: Equatable, Sendable {
    var running: Int = 0
    var queued: Int = 0
    var paused: Int = 0
    var completed: Int = 0
    var failed: Int = 0
    var stopped: Int = 0

    var hasAny: Bool {
        running + queued + paused + completed + failed + stopped > 0
    }
    var isBusy: Bool {
        running > 0 || queued > 0
    }
}

// MARK: - Run options (unchanged shape from the original implementation)

struct FileBotPostScriptRunOptions: Equatable, Sendable {
    let enabled: Bool
    let descriptorId: String
    let extraArgsRaw: String
    let defBlock: String
    let inputUsesParentFolder: Bool
}

struct PipelineRunOptions: Equatable, Sendable {
    let handBrakePreset: String
    let handBrakeExtraArgs: [String]
    let fileBotDB: String
    let fileBotFormat: String
    let fileBotEpisodeOrder: String
    let fileBotApplyArtwork: Bool
    let fileBotExtraArgs: [String]
    let fileBotPostScript: FileBotPostScriptRunOptions?
    let sublerExtraArgs: [String]
    let skipFileBot: Bool
    let skipSubler: Bool
    let copyToAppleTVImport: Bool
}

// MARK: - Queued source wire format

enum PipelineQueuedWire: Equatable {
    static let bluRayRipPendingMarker = "bluray.bluray-pending"

    static func bluRayRipPendingPath(ripDirectoryPath: String) -> String {
        "\(bluRayRipPendingMarker)::\(ripDirectoryPath)"
    }

    static func bluRayRipDirectoryIfPresent(in sourcePath: String) throws -> String? {
        guard sourcePath.hasPrefix("\(bluRayRipPendingMarker)::") else { return nil }
        let dir = String(sourcePath.dropFirst(bluRayRipPendingMarker.count + 2))
        guard !dir.isEmpty else {
            throw NSError(
                domain: "MediaVault", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Blu-ray source spec"]
            )
        }
        return dir
    }
}

// MARK: - Summary (retained for SummaryView callers)

struct PipelineSummary: Equatable, Sendable {
    let totalCount: Int
    let succeeded: [ConversionItem]
    let failed: [ConversionItem]
    let elapsedTotal: TimeInterval
    let logFilePath: String

    var elapsedString: String { Self.format(elapsedTotal) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        return String(format: "%dm %02ds", m, sec)
    }
}

// MARK: - Controller

@MainActor
final class PipelineController: ObservableObject {

    // MARK: Published projection

    @Published var items: [ConversionItem] = []
    @Published var isRunning: Bool = false
    @Published var summary: PipelineSummary?
    @Published private(set) var logEntries: [PipelineLogEntry] = []
    @Published private(set) var currentLogFilePath: String = ""
    @Published private(set) var laneActivity: [PipelineLane: LaneActivitySummary] = [
        .file: LaneActivitySummary(),
        .disc: LaneActivitySummary()
    ]

    // Recovery surface (set by `applyRecoveredJobs` after load on launch).
    @Published var recoverableJobs: [PersistedJob] = []
    @Published var recoveryAlert: RecoveryAlert?

    /// Maximum log entries kept in memory; older entries are evicted to avoid
    /// runaway memory growth on day-long runs.
    private let logEntryRetention: Int = 5_000

    // MARK: Backing services

    let tools: ToolManager
    let store: ConversionJobStore
    let orchestrator: ConversionOrchestrator

    // Per-session log file handle (one combined log for all lanes, with each
    // entry tagged by process and job id).
    private var logHandle: FileHandle?
    private var logURL: URL?
    private var sessionLogOpenedAt: Date?
    private var eventForwarderTask: Task<Void, Never>?

    // MARK: Init

    init(tools: ToolManager,
         store: ConversionJobStore = ConversionJobStore(),
         laneLimits: [PipelineLane: Int] = [.file: 2, .disc: 1]) {
        self.tools = tools
        self.store = store
        self.orchestrator = ConversionOrchestrator(store: store, laneLimits: laneLimits)
        startEventForwarder()
    }

    deinit {
        eventForwarderTask?.cancel()
    }

    // MARK: - Enqueue (legacy single-batch API, multi-lane aware)

    /// Adds the given sources to the orchestrator. Each source is dispatched
    /// to the lane that matches its kind so disc rips don't block file
    /// encodes (and vice versa).
    func enqueue(sources: [String], outputDirectory: URL, options: PipelineRunOptions) {
        for source in sources {
            let lane: PipelineLane = inferLane(for: source)
            let displayName = makeDisplayName(for: source)
            let outputPath = outputDirectory.path
            Task { [orchestrator] in
                _ = await orchestrator.enqueue(
                    lane: lane,
                    sourcePath: source,
                    displayName: displayName,
                    outputDirectoryPath: outputPath,
                    options: options
                )
            }
        }
    }

    /// Compatibility shim retained for older call sites — fan out to the
    /// orchestrator and exit (the run is event-driven from then on).
    func run() async {
        // No-op: the orchestrator schedules work as soon as items are added
        // via `enqueue`. We just open the session log so existing UI bindings
        // (`currentLogFilePath`) are populated.
        ensureSessionLog(in: items.first.map { URL(fileURLWithPath: $0.sourcePath).deletingLastPathComponent() } ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Tool path refresh (called after `ToolManager.prepare`)

    func refreshOrchestratorToolPaths() async {
        let snapshot = ConversionOrchestrator.ToolPaths(
            handbrakeCLI: tools.handbrakeCLI,
            sublerCLI: tools.sublerCLI,
            makemkvCon: tools.makemkvCon,
            filebot: tools.filebot
        )
        await orchestrator.updateToolPaths(snapshot)
    }

    // MARK: - Controls (global, lane, per-job)

    func pauseAll()   { Task { await orchestrator.pauseAll() } }
    func resumeAll()  { Task { await orchestrator.resumeAll() } }
    func stopAll()    { Task { await orchestrator.stopAll() } }

    func pauseLane(_ lane: PipelineLane)  { Task { await orchestrator.pauseLane(lane) } }
    func resumeLane(_ lane: PipelineLane) { Task { await orchestrator.resumeLane(lane) } }
    func stopLane(_ lane: PipelineLane)   { Task { await orchestrator.stopLane(lane) } }

    func pauseJob(_ id: ConversionJobID)  { Task { await orchestrator.pauseJob(id) } }
    func resumeJob(_ id: ConversionJobID) { Task { await orchestrator.resumeJob(id) } }
    func stopJob(_ id: ConversionJobID)   { Task { await orchestrator.stopJob(id) } }

    func forceTerminateForAppExit() async {
        await orchestrator.forceTerminateForAppExit()
    }

    // MARK: - Recovery API (driven by MediaVaultApp at startup)

    /// Holds info to surface a non-blocking alert (corruption / version skew).
    struct RecoveryAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Whether `applyRecovery` has already been called in this app session.
    /// SwiftUI's `.task` modifier may fire more than once (e.g. when the
    /// window is closed and reopened), so we guard against double-hydration
    /// which would inflate the queue with duplicates.
    private var didApplyRecovery: Bool = false

    /// Called once on app launch after `ConversionJobStore.load()` completes.
    func applyRecovery(_ outcome: ConversionJobStoreLoadOutcome) async {
        guard !didApplyRecovery else { return }
        didApplyRecovery = true
        switch outcome {
        case .loaded(let root):
            // Hydrate orchestrator with previously-known jobs. Anything that
            // was running is forced to paused per the orchestrator's logic.
            await orchestrator.hydrate(from: root.jobs)
            let recoverable = root.jobs.filter { $0.state == .paused || $0.state == .running }
            recoverableJobs = recoverable
            if recoverable.isEmpty == false {
                // Verify source/output exist; flag missing ones in the alert.
                let missing = recoverable.filter { !sourceLooksValid(forResume: $0) }
                if !missing.isEmpty {
                    recoveryAlert = RecoveryAlert(
                        title: "Some paused jobs cannot resume",
                        message: missingResumeMessage(missing)
                    )
                }
            }
        case .quarantined(let reason, let path):
            recoveryAlert = RecoveryAlert(
                title: "Saved state could not be loaded",
                message: "\(reason)\nThe original file was preserved at:\n\(path)"
            )
        case .noState:
            break
        }
    }

    // MARK: - Lookup helpers

    func job(with id: ConversionJobID) -> ConversionItem? {
        items.first(where: { $0.jobID == id })
    }

    func items(on lane: PipelineLane) -> [ConversionItem] {
        items.filter { $0.lane == lane }
    }

    // MARK: - Event forwarding

    private func startEventForwarder() {
        let stream = orchestrator.events
        eventForwarderTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event: event)
            }
        }
    }

    private func handle(event: OrchestratorEvent) async {
        switch event {
        case .state(let jobs):
            apply(snapshot: jobs)
        case .log(let jobID, let process, let message, let timestamp):
            appendLog(jobID: jobID, process: process, message: message, at: timestamp)
        case .jobFinished(let id, let success):
            if success {
                if let item = items.first(where: { $0.jobID == id }) {
                    notify(title: "Converted", body: item.displayName)
                }
            }
        case .allDrained:
            // Build a "final" summary covering the last drained batch.
            let succeeded = items.filter { $0.lifecycle == .completed }
            let failed = items.filter { $0.lifecycle == .failed }
            let elapsed: TimeInterval = {
                guard let start = sessionLogOpenedAt else { return 0 }
                return Date().timeIntervalSince(start)
            }()
            if !items.isEmpty {
                summary = PipelineSummary(
                    totalCount: items.count,
                    succeeded: succeeded,
                    failed: failed,
                    elapsedTotal: elapsed,
                    logFilePath: currentLogFilePath
                )
                notify(
                    title: "MediaVault drained",
                    body: "\(succeeded.count) of \(items.count) succeeded in \(PipelineSummary.format(elapsed))"
                )
            }
        }
    }

    private func apply(snapshot: [ManagedJob]) {
        let mapped = snapshot.map { job in
            ConversionItem(
                id: job.id.raw,
                jobID: job.id,
                lane: job.lane,
                sourcePath: job.sourcePath,
                displayName: job.displayName,
                stage: job.currentStage,
                stageProgress: job.currentStageProgress,
                lifecycle: job.state,
                startedAt: job.startedAt,
                finishedAt: job.finishedAt,
                finalPath: job.finalPath,
                errorMessage: job.errorMessage,
                stageNote: job.currentStageNote
            )
        }
        self.items = mapped
        self.isRunning = mapped.contains { $0.lifecycle == .running || $0.lifecycle == .pausing }

        var newLaneActivity: [PipelineLane: LaneActivitySummary] = [
            .file: LaneActivitySummary(),
            .disc: LaneActivitySummary()
        ]
        for item in mapped {
            var summary = newLaneActivity[item.lane] ?? LaneActivitySummary()
            switch item.lifecycle {
            case .queued:    summary.queued += 1
            case .running:   summary.running += 1
            case .pausing:   summary.running += 1
            case .paused:    summary.paused += 1
            case .stopping:  summary.running += 1
            case .stopped:   summary.stopped += 1
            case .completed: summary.completed += 1
            case .failed:    summary.failed += 1
            }
            newLaneActivity[item.lane] = summary
        }
        self.laneActivity = newLaneActivity
    }

    // MARK: - Log handling

    private func appendLog(
        jobID: ConversionJobID?,
        process: PipelineLogProcess,
        message: String,
        at timestamp: Date
    ) {
        // Open a session log lazily on first event so we know which output
        // directory to use (we pick any active item's directory).
        if logHandle == nil {
            if let any = items.first {
                let outDir = URL(fileURLWithPath: any.sourcePath).deletingLastPathComponent()
                ensureSessionLog(in: outDir)
            } else {
                ensureSessionLog(in: FileManager.default.homeDirectoryForCurrentUser)
            }
        }

        let entry = PipelineLogEntry(
            timestamp: timestamp,
            process: process,
            message: message,
            jobID: jobID?.raw
        )
        logEntries.append(entry)
        if logEntries.count > logEntryRetention {
            logEntries.removeFirst(logEntries.count - logEntryRetention)
        }
        if let handle = logHandle {
            let jobSuffix = jobID.map { " [\($0.raw.uuidString.prefix(8))]" } ?? ""
            let line = "[\(timestamp)] [\(process.rawValue)]\(jobSuffix) \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func ensureSessionLog(in directory: URL) {
        guard logHandle == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let now = Date()
        let url = directory.appendingPathComponent("conversion_log_\(formatter.string(from: now)).txt")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Falls through: file create will fail and we'll just lose the
            // log file (we still keep entries in-memory).
        }
        if !fm.createFile(atPath: url.path, contents: nil) {
            // Try again at the home directory as a last resort.
            let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("MediaVault_session_log.txt")
            _ = fm.createFile(atPath: fallback.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: fallback)
            logURL = fallback
            currentLogFilePath = fallback.path
            sessionLogOpenedAt = now
            return
        }
        logHandle = try? FileHandle(forWritingTo: url)
        logURL = url
        currentLogFilePath = url.path
        sessionLogOpenedAt = now
    }

    // MARK: - Helpers

    private func inferLane(for source: String) -> PipelineLane {
        if source.hasPrefix(PipelineQueuedWire.bluRayRipPendingMarker + "::") { return .disc }
        if source.hasPrefix("/dev/") { return .disc }
        return .file
    }

    private func makeDisplayName(for source: String) -> String {
        if source.hasPrefix("/dev/") {
            return "DVD (\(source))"
        }
        if source.hasPrefix(PipelineQueuedWire.bluRayRipPendingMarker + "::") {
            let dir = source.dropFirst(PipelineQueuedWire.bluRayRipPendingMarker.count + 2)
            return "Blu-ray (\((dir as NSString).lastPathComponent))"
        }
        return (((source as NSString).lastPathComponent) as NSString).deletingPathExtension
    }

    private func sourceLooksValid(forResume record: PersistedJob) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: record.outputDirectoryPath) { return false }
        if record.sourcePath.hasPrefix("/dev/") { return true }
        if record.sourcePath.hasPrefix(PipelineQueuedWire.bluRayRipPendingMarker + "::") { return true }
        return fm.fileExists(atPath: record.sourcePath)
    }

    private func missingResumeMessage(_ missing: [PersistedJob]) -> String {
        let names = missing.map { $0.displayName }.joined(separator: "\n  • ")
        return """
        The following paused jobs reference sources or output folders that no
        longer exist. They will remain paused; remove or stop them when ready.

          • \(names)
        """
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

