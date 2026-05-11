// ConversionJobStore.swift
// Durable, crash-safe job store backed by a single JSON file in Application
// Support. All writes go through an `actor` so external callers can't observe
// torn state or race each other.
//
// Why JSON over SQLite:
//   - The expected dataset (paused/queued jobs) is small (typically <50).
//   - Atomic replacement via `Data.write(to:options: .atomic)` is documented
//     in Foundation and provides the all-or-nothing crash safety we need
//     (https://developer.apple.com/documentation/foundation/data/writingoptions/atomic).
//   - JSON is inspectable, diffable, and trivial to migrate by hand if a
//     future version of the app cannot read it.
//   - Linking libsqlite3 adds packaging cost (build flags, codesign rules)
//     with no observable benefit at this volume.
//
// Corruption handling: a JSON read failure quarantines the bad file to
// `jobs.json.corrupt-<timestamp>` and starts a fresh empty root. The user is
// surfaced an alert at startup so they can decide whether to look at the
// quarantined record.

import Foundation

/// Outcomes from `load()` so the caller can show a non-blocking alert when
/// state was discarded.
enum ConversionJobStoreLoadOutcome: Sendable {
    case loaded(PersistedJobStoreRoot)
    case quarantined(reason: String, quarantinedPath: String)
    case noState
}

/// Actor wrapping the JSON file so all reads and writes are serialised on a
/// single executor. The class is `Sendable` because all mutable state lives
/// inside the actor.
actor ConversionJobStore {

    // MARK: - Locations

    private let storeURL: URL
    private let storeDirectory: URL

    /// Returns the canonical store URL. Kept separate from the actor's init
    /// so tests can inject a different directory if needed.
    static func defaultStoreDirectory() -> URL {
        // ToolManager already uses Application Support; reuse the same
        // namespaced directory so the user has one place to find app state.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("MediaMagic", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    init(directory: URL = ConversionJobStore.defaultStoreDirectory()) {
        self.storeDirectory = directory
        self.storeURL = directory.appendingPathComponent("jobs.json")
    }

    // MARK: - Public API

    /// Loads the store, recovering from corruption / version mismatch by
    /// quarantining the offending file. Never throws — the caller always
    /// receives a usable outcome.
    func load() -> ConversionJobStoreLoadOutcome {
        do {
            try FileManager.default.createDirectory(
                at: storeDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return .quarantined(
                reason: "Could not create state directory: \(error.localizedDescription)",
                quarantinedPath: storeDirectory.path
            )
        }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .noState
        }

        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            return .quarantined(
                reason: "Could not read state: \(error.localizedDescription)",
                quarantinedPath: quarantineCurrent(reason: "read-failed")
            )
        }

        do {
            let decoder = JSONDecoder()
            // Must match the strategy used in `save()` below. Without this
            // the decoder defaults to `.deferredToDate` (Double seconds),
            // which fails on the ISO-8601 strings we write.
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedJobStoreRoot.self, from: data)
            if decoded.schemaVersion != ConversionJobSchema.currentVersion {
                // Unknown future version, or a stale past version we don't
                // know how to migrate. Quarantine to avoid silently running
                // jobs we can't faithfully interpret.
                return .quarantined(
                    reason: "Schema version \(decoded.schemaVersion) unsupported (expected \(ConversionJobSchema.currentVersion))",
                    quarantinedPath: quarantineCurrent(reason: "schema-\(decoded.schemaVersion)")
                )
            }
            return .loaded(decoded)
        } catch {
            return .quarantined(
                reason: "Could not parse state: \(error.localizedDescription)",
                quarantinedPath: quarantineCurrent(reason: "parse-failed")
            )
        }
    }

    /// Atomically replaces the on-disk root.
    func save(_ root: PersistedJobStoreRoot) throws {
        var sealed = root
        sealed.schemaVersion = ConversionJobSchema.currentVersion
        sealed.appBuild = ConversionJobSchema.appBuildIdentifier
        sealed.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(sealed)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: [.atomic])
    }

    /// Convenience: upsert a single job in the current root, then save.
    func upsert(_ job: PersistedJob) throws {
        var root: PersistedJobStoreRoot
        switch load() {
        case .loaded(let existing):
            root = existing
        case .noState, .quarantined:
            root = .empty()
        }
        if let idx = root.jobs.firstIndex(where: { $0.id == job.id }) {
            root.jobs[idx] = job
        } else {
            root.jobs.append(job)
        }
        try save(root)
    }

    /// Replaces all jobs in one durable write. The orchestrator uses this on
    /// every coalesced state mutation so the on-disk snapshot is always a
    /// faithful copy of in-memory truth.
    func replaceAll(_ jobs: [PersistedJob]) throws {
        var root = PersistedJobStoreRoot.empty()
        root.jobs = jobs
        try save(root)
    }

    /// Removes a job by id. No-op if not present.
    func remove(_ id: ConversionJobID) throws {
        guard case .loaded(var root) = load() else { return }
        root.jobs.removeAll { $0.id == id }
        try save(root)
    }

    /// Returns the path used for the on-disk file (for diagnostics / UI).
    nonisolated func storePath() -> String { storeURL.path }

    // MARK: - Internal helpers

    @discardableResult
    private func quarantineCurrent(reason: String) -> String {
        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            return f.string(from: Date())
        }()
        let quarantineURL = storeDirectory.appendingPathComponent(
            "jobs.json.corrupt-\(timestamp)-\(reason)"
        )
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.moveItem(at: storeURL, to: quarantineURL)
            }
        } catch {
            // If quarantining fails, fall back to deleting so we don't loop
            // on the same bad file every launch.
            try? FileManager.default.removeItem(at: storeURL)
        }
        return quarantineURL.path
    }
}
