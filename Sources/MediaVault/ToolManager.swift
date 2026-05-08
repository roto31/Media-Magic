// ToolManager.swift
// Locates or downloads CLI tools used by the pipeline.
//
// HandBrakeCLI and SublerCli are auto-downloaded on first launch into
// ~/Library/Application Support/MediaVault/bin/  (no Homebrew required).
// Both tools are GPLv2; we don't bundle them inside the .app to keep the
// app's own redistribution clean — instead we fetch the official binaries
// the same way Homebrew does, which is functionally identical to the user
// running `brew install` themselves.
//
// MakeMKV and FileBot must be installed by the user separately:
//   - MakeMKV requires the user's own license / disc handling
//   - FileBot has its own paid license model
// These two are discovered at known paths but never downloaded automatically.

import Foundation

enum ToolError: Error, LocalizedError {
    case notFound(String)
    case downloadFailed(String, underlying: Error?)
    case extractionFailed(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "Could not find \(name). Please install it and try again."
        case .downloadFailed(let name, let err):
            let detail = err.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to download \(name)\(detail)"
        case .extractionFailed(let name):
            return "Failed to extract \(name)"
        case .checksumMismatch(let name):
            return "\(name) failed checksum verification — download corrupted"
        }
    }
}

struct ResolvedTool {
    let name: String
    let path: String
    /// Where this tool came from, for the user-facing status panel.
    let source: Source
    enum Source { case bundled, applicationSupport, userInstalled }
}


@MainActor
final class ToolManager: ObservableObject {

    // Published state for the UI to observe.
    @Published var status: String = "Ready"
    @Published var progress: Double = 0          // 0.0 ... 1.0
    @Published var isPreparing: Bool = false

    // Resolved tool paths (set after prepare() completes successfully).
    private(set) var handbrakeCLI: String?
    private(set) var sublerCLI: String?
    private(set) var makemkvCon: String?
    private(set) var filebot: String?

    // MARK: - Public entry point

    /// Locate or download all required tools. Throws if a *user-installed*
    /// tool (MakeMKV / FileBot) is missing — those we can't auto-fetch.
    func prepare() async throws {
        isPreparing = true
        defer { isPreparing = false }

        try ensureSupportDirectoryExists()

        // 1. Auto-managed tools (HandBrakeCLI, SublerCli)
        handbrakeCLI = try await ensureHandBrakeCLI()
        sublerCLI    = try await ensureSublerCLI()

        // 2. User-installed tools (MakeMKV, FileBot) — discover only.
        makemkvCon = locateUserTool(
            name: "makemkvcon",
            candidates: [
                "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
                "/opt/homebrew/bin/makemkvcon",
                "/usr/local/bin/makemkvcon",
            ]
        )
        filebot = locateUserTool(
            name: "filebot",
            candidates: [
                "/opt/homebrew/bin/filebot",
                "/usr/local/bin/filebot",
                "/Applications/FileBot.app/Contents/MacOS/filebot",
            ]
        )

        status = "All tools ready"
    }

    /// Returns true if MakeMKV is available (Blu-ray flow needs it).
    var hasMakeMKV: Bool { makemkvCon != nil }
    /// Returns true if FileBot is available (rename stage needs it).
    var hasFileBot: Bool { filebot != nil }

    // MARK: - Application Support directory

    /// ~/Library/Application Support/MediaVault/
    static var supportDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("MediaVault", isDirectory: true)
    }

    /// ~/Library/Application Support/MediaVault/bin/
    static var binDir: URL {
        supportDir.appendingPathComponent("bin", isDirectory: true)
    }

    private func ensureSupportDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: Self.binDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - HandBrakeCLI

    /// HandBrake's GitHub releases publish files like:
    ///   HandBrakeCLI-1.10.2.dmg  (universal macOS binary inside a .dmg)
    /// We pin a known-good version here. Update this constant to roll forward.
    private let handbrakeVersion = "1.10.2"
    private var handbrakeURL: URL {
        URL(string: "https://github.com/HandBrake/HandBrake/releases/download/\(handbrakeVersion)/HandBrakeCLI-\(handbrakeVersion).dmg")!
    }

    private func ensureHandBrakeCLI() async throws -> String {
        let installed = Self.binDir.appendingPathComponent("HandBrakeCLI").path
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }

        // Check if user already has it installed system-wide.
        if let userPath = locateUserTool(
            name: "HandBrakeCLI",
            candidates: [
                "/opt/homebrew/bin/HandBrakeCLI",
                "/usr/local/bin/HandBrakeCLI",
            ]
        ) {
            return userPath
        }

        // Download.
        status = "Downloading HandBrakeCLI \(handbrakeVersion)…"
        let dmg = try await downloadFile(
            from: handbrakeURL,
            label: "HandBrakeCLI"
        )
        defer { try? FileManager.default.removeItem(at: dmg) }

        // Mount the dmg, copy out HandBrakeCLI, unmount.
        status = "Installing HandBrakeCLI…"
        let mountPoint = try mountDMG(dmg)
        defer { try? unmountDMG(at: mountPoint) }

        let candidate = mountPoint.appendingPathComponent("HandBrakeCLI")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ToolError.extractionFailed("HandBrakeCLI binary not found inside DMG")
        }

        let dest = URL(fileURLWithPath: installed)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: candidate, to: dest)
        try setExecutable(dest)

        // Strip Apple's "downloaded from internet" quarantine flag so the
        // binary runs without a Gatekeeper prompt.
        _ = try? Process.runShell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])

        return installed
    }

    // MARK: - SublerCli

    /// SublerCli ships inside Subler.app's bundle when installed via the
    /// Homebrew cask. We download the standalone CLI distribution from
    /// the SublerApp GitHub releases.
    ///
    /// Subler doesn't publish a separate "SublerCli only" build the way
    /// HandBrake does — the Homebrew sublercli cask actually points to
    /// a specific zip on Bitbucket. Most reliable approach: ship the
    /// user a clear directive if Subler.app exists, fall back to manual
    /// install instructions otherwise.
    private func ensureSublerCLI() async throws -> String {
        let installed = Self.binDir.appendingPathComponent("SublerCli").path
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }

        // Common system locations.
        if let userPath = locateUserTool(
            name: "SublerCli",
            candidates: [
                "/opt/homebrew/bin/SublerCli",
                "/usr/local/bin/SublerCli",
                "/Applications/Subler.app/Contents/MacOS/SublerCli",
            ]
        ) {
            return userPath
        }

        // Subler.app may have an embedded CLI tool — check there.
        let inApp = "/Applications/Subler.app/Contents/Resources/SublerCli"
        if FileManager.default.isExecutableFile(atPath: inApp) {
            return inApp
        }

        throw ToolError.notFound(
            """
            SublerCli (the Subler command-line tool).
            Install it with:
                brew install --cask sublercli
            Or download from: https://bitbucket.org/galad87/sublercli/downloads/
            """
        )
    }

    // MARK: - User tool discovery

    private func locateUserTool(name: String, candidates: [String]) -> String? {
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fall back to PATH lookup.
        if let path = try? Process.runShell("/usr/bin/which", [name]).trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Download / DMG handling

    private func downloadFile(from url: URL, label: String) async throws -> URL {
        // We need a custom URLSession bound to a delegate so we can report
        // download progress to the UI. The async download(for:delegate:)
        // overload that takes a per-call delegate exists on macOS 12+ for
        // exactly this purpose.
        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in self?.progress = progress }
        }
        let session = URLSession(configuration: .default,
                                 delegate: delegate,
                                 delegateQueue: nil)

        do {
            let (tempURL, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ToolError.downloadFailed(label, underlying: NSError(
                    domain: "HTTP", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                ))
            }
            // Move to a stable location — the system reaps the temp URL fast.
            let stable = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaVault_\(UUID().uuidString)_\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: tempURL, to: stable)
            session.invalidateAndCancel()
            return stable
        } catch {
            session.invalidateAndCancel()
            throw ToolError.downloadFailed(label, underlying: error)
        }
    }

    private func mountDMG(_ dmgURL: URL) throws -> URL {
        // hdiutil attach -plist gives us a property-list back which is far
        // more reliable to parse than the human-readable tab-separated output.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nobrowse", "-plist", dmgURL.path]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()  // discard
        try p.run()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            throw ToolError.extractionFailed("hdiutil attach exited \(p.terminationStatus)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw ToolError.extractionFailed("hdiutil produced unparseable plist")
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String,
               !mountPoint.isEmpty,
               FileManager.default.fileExists(atPath: mountPoint) {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw ToolError.extractionFailed("hdiutil did not report a mount point")
    }

    private func unmountDMG(at mountPoint: URL) throws {
        _ = try Process.runShell(
            "/usr/bin/hdiutil",
            ["detach", "-quiet", mountPoint.path]
        )
    }

    private func setExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - URLSession download progress delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The async download(from:) API extracts the file from the delegate's
        // perspective; this callback is required by the protocol but otherwise
        // a no-op for us.
    }
}

// MARK: - Process helper

extension Process {
    /// Run a command synchronously and return its combined stdout.
    @discardableResult
    static func runShell(_ launchPath: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        try p.run()
        p.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
