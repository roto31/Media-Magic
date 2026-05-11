// ConversionJobModels.swift
// Codable types that describe a single conversion as a durable, schema-versioned
// record. Designed so the orchestrator and store agree on a single persistence
// shape that survives an app or macOS restart.
//
// Persistence rationale: a small (< few hundred) set of long-running jobs with
// human-readable state is well served by an atomically-written JSON file (see
// `ConversionJobStore`). Atomic replacement is provided by
// `Data.write(to:options: .atomic)` (Foundation), which performs the
// write-to-temp-then-rename dance documented to be safe across power loss on
// APFS. SQLite would add a runtime/library dependency without observable
// benefit at this data scale.

import Foundation

// MARK: - Schema constants

enum ConversionJobSchema {
    /// Bump only when persisted shape changes incompatibly.
    static let currentVersion: Int = 1
    /// Stored at every save so future code can detect and migrate or
    /// quarantine state that originated from a different app build.
    static let appBuildIdentifier: String = {
        let infoVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let infoBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return "\(infoVersion ?? "0.0.0")+\(infoBuild ?? "0")"
    }()
}

// MARK: - Identifier

/// Stable identifier shared by the in-memory item, the orchestrator and the
/// persisted record. Backed by `UUID` for crash-safe uniqueness.
struct ConversionJobID: Hashable, Codable, CustomStringConvertible, Sendable {
    let raw: UUID

    init() { raw = UUID() }
    init(uuid: UUID) { raw = uuid }

    var description: String { raw.uuidString }
}

// MARK: - Persisted run options
//
// Mirrors `PipelineRunOptions` / `FileBotPostScriptRunOptions` but is `Codable`
// so we can write it to disk. We keep them as separate types to avoid coupling
// persistence shape to internal struct field reordering.

struct PersistedFileBotPostScript: Codable, Hashable, Sendable {
    let enabled: Bool
    let descriptorId: String
    let extraArgsRaw: String
    let defBlock: String
    let inputUsesParentFolder: Bool
}

struct PersistedRunOptions: Codable, Hashable, Sendable {
    let handBrakePreset: String
    let handBrakeExtraArgs: [String]
    let fileBotDB: String
    let fileBotFormat: String
    let fileBotEpisodeOrder: String
    let fileBotApplyArtwork: Bool
    let fileBotExtraArgs: [String]
    let fileBotPostScript: PersistedFileBotPostScript?
    let sublerExtraArgs: [String]
    let skipFileBot: Bool
    let skipSubler: Bool
    let copyToAppleTVImport: Bool
}

// MARK: - Lifecycle state for a persisted job

/// Authoritative state recorded in the store. `running` is only valid while
/// the same process instance is alive: on relaunch any record that was
/// `running` is reinterpreted as `paused` (interrupted by app exit) so the
/// user is prompted before resuming.
enum PersistedJobState: String, Codable, Sendable {
    case queued
    case running
    case paused
    case stopped
    case completed
    case failed
}

// MARK: - Persisted Job record

struct PersistedJob: Codable, Hashable, Sendable, Identifiable {
    var id: ConversionJobID
    var lane: PipelineLane
    var sourcePath: String
    var displayName: String
    var outputDirectoryPath: String
    var options: PersistedRunOptions

    var state: PersistedJobState
    /// Stages that completed successfully and never need to be re-run on
    /// resume. Stored as `PipelineStage.rawValue` to remain stable across
    /// renames of the in-memory enum.
    var completedStages: [String]
    var currentStage: String
    var currentStageProgress: Double
    var currentStageNote: String

    var errorMessage: String?
    /// Path to the most recent output (HandBrake .m4v, post-FileBot rename, etc.).
    var finalPath: String?

    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var pausedAt: Date?

    /// Captured at the most recent persist so version-mismatched records can
    /// be quarantined rather than silently re-run with different semantics.
    var appBuildAtPersist: String
}

// MARK: - Persisted root (file format)

/// The full on-disk shape. Always written atomically; never appended to.
struct PersistedJobStoreRoot: Codable, Sendable {
    var schemaVersion: Int
    var appBuild: String
    var updatedAt: Date
    var jobs: [PersistedJob]

    static func empty() -> PersistedJobStoreRoot {
        PersistedJobStoreRoot(
            schemaVersion: ConversionJobSchema.currentVersion,
            appBuild: ConversionJobSchema.appBuildIdentifier,
            updatedAt: Date(),
            jobs: []
        )
    }
}

// MARK: - Conversion helpers

extension PersistedRunOptions {
    init(from options: PipelineRunOptions) {
        self.handBrakePreset = options.handBrakePreset
        self.handBrakeExtraArgs = options.handBrakeExtraArgs
        self.fileBotDB = options.fileBotDB
        self.fileBotFormat = options.fileBotFormat
        self.fileBotEpisodeOrder = options.fileBotEpisodeOrder
        self.fileBotApplyArtwork = options.fileBotApplyArtwork
        self.fileBotExtraArgs = options.fileBotExtraArgs
        self.fileBotPostScript = options.fileBotPostScript.map {
            PersistedFileBotPostScript(
                enabled: $0.enabled,
                descriptorId: $0.descriptorId,
                extraArgsRaw: $0.extraArgsRaw,
                defBlock: $0.defBlock,
                inputUsesParentFolder: $0.inputUsesParentFolder
            )
        }
        self.sublerExtraArgs = options.sublerExtraArgs
        self.skipFileBot = options.skipFileBot
        self.skipSubler = options.skipSubler
        self.copyToAppleTVImport = options.copyToAppleTVImport
    }

    func toRuntime() -> PipelineRunOptions {
        PipelineRunOptions(
            handBrakePreset: handBrakePreset,
            handBrakeExtraArgs: handBrakeExtraArgs,
            fileBotDB: fileBotDB,
            fileBotFormat: fileBotFormat,
            fileBotEpisodeOrder: fileBotEpisodeOrder,
            fileBotApplyArtwork: fileBotApplyArtwork,
            fileBotExtraArgs: fileBotExtraArgs,
            fileBotPostScript: fileBotPostScript.map {
                FileBotPostScriptRunOptions(
                    enabled: $0.enabled,
                    descriptorId: $0.descriptorId,
                    extraArgsRaw: $0.extraArgsRaw,
                    defBlock: $0.defBlock,
                    inputUsesParentFolder: $0.inputUsesParentFolder
                )
            },
            sublerExtraArgs: sublerExtraArgs,
            skipFileBot: skipFileBot,
            skipSubler: skipSubler,
            copyToAppleTVImport: copyToAppleTVImport
        )
    }
}
