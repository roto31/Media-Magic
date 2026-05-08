// PipelineController.swift
// State machine orchestrating the four-stage conversion pipeline:
//   1. MakeMKV   (Blu-ray rip)         — optional
//   2. HandBrake (transcode to .m4v)
//   3. FileBot   (rename via TheMovieDB)
//   4. SublerCli (embed metadata + cover art)
//
// Designed for streaming output capture so the UI can show live progress
// (especially for HandBrake which prints "Encoding: task 1 of 1, X.XX %").

import Foundation
import SwiftUI
import UserNotifications

// MARK: - Models

enum SourceKind: String, CaseIterable, Identifiable {
    case videoFile = "Video File"
    case dvd       = "DVD"
    case bluray    = "Blu-ray"
    var id: String { rawValue }
}

enum PipelineStage: String {
    case idle      = "Idle"
    case ripping   = "Ripping (MakeMKV)"
    case encoding  = "Encoding (HandBrake)"
    case renaming  = "Renaming (FileBot)"
    case tagging   = "Tagging (Subler)"
    case done      = "Complete"
    case failed    = "Failed"
}

struct ConversionItem: Identifiable, Equatable {
    let id = UUID()
    let sourcePath: String          // file path, /dev/diskN, or .mkv from MakeMKV
    var displayName: String         // user-facing name shown in the UI
    var stage: PipelineStage = .idle
    var stageProgress: Double = 0   // 0..1 within current stage
    var startedAt: Date?
    var finishedAt: Date?
    var finalPath: String?
    var errorMessage: String?
    var stageNote: String = ""      // free-form line shown under the progress bar

    var elapsed: TimeInterval {
        guard let start = startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(start)
    }
}

struct PipelineSummary {
    let totalCount: Int
    let succeeded: [ConversionItem]
    let failed: [ConversionItem]
    let elapsedTotal: TimeInterval
    let logFilePath: String

    var elapsedString: String { Self.format(elapsedTotal) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
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

    @Published var items: [ConversionItem] = []
    @Published var isRunning: Bool = false
    @Published var currentIndex: Int = 0
    @Published var summary: PipelineSummary?

    private let tools: ToolManager
    private var logHandle: FileHandle?
    private var logURL: URL?

    init(tools: ToolManager) {
        self.tools = tools
    }

    // MARK: - Public API

    func enqueue(sources: [String], outputDirectory: URL) {
        // Reset state for a new run.
        items = sources.map {
            let name: String
            if $0.hasPrefix("/dev/") {
                name = "DVD (\($0))"
            } else {
                name = (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            return ConversionItem(sourcePath: $0, displayName: name)
        }
        currentIndex = 0
        summary = nil
        outputDir = outputDirectory
    }

    private var outputDir: URL = FileManager.default.homeDirectoryForCurrentUser

    func run() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        openLog()
        defer { closeLog() }

        let runStart = Date()
        var succeeded: [ConversionItem] = []
        var failed: [ConversionItem] = []

        for index in items.indices {
            currentIndex = index
            items[index].startedAt = Date()
            log("============================================================")
            log("Item \(index + 1)/\(items.count): \(items[index].displayName)")
            log("Source: \(items[index].sourcePath)")
            log("============================================================")

            do {
                try await processItem(at: index)
                items[index].stage = .done
                items[index].finishedAt = Date()
                succeeded.append(items[index])
                notify(title: "Converted", body: items[index].displayName)
            } catch {
                items[index].stage = .failed
                items[index].finishedAt = Date()
                items[index].errorMessage = error.localizedDescription
                failed.append(items[index])
                log("ERROR: \(error.localizedDescription)")
                await showError(
                    title: "Conversion failed",
                    message: "Failed at \(items[index].stage.rawValue) for \(items[index].displayName):\n\n\(error.localizedDescription)\n\nContinuing with remaining items."
                )
            }
        }

        summary = PipelineSummary(
            totalCount: items.count,
            succeeded: succeeded,
            failed: failed,
            elapsedTotal: Date().timeIntervalSince(runStart),
            logFilePath: logURL?.path ?? ""
        )

        notify(title: "MediaVault complete",
               body: "\(succeeded.count) of \(items.count) succeeded in \(PipelineSummary.format(Date().timeIntervalSince(runStart)))")
    }

    // MARK: - Per-item pipeline

    private func processItem(at index: Int) async throws {
        var workingPath = items[index].sourcePath

        // Stage 1: MakeMKV (Blu-ray only)
        if workingPath.hasSuffix(".bluray-pending") {
            // The acquisition step encodes Blu-ray sources with this suffix
            // followed by the chosen rip directory after a "::" separator.
            // (See ContentView.swift's source acquisition.)
            let parts = workingPath.components(separatedBy: "::")
            guard parts.count == 2 else {
                throw NSError(domain: "MediaVault", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid Blu-ray source spec"])
            }
            let ripDir = parts[1]
            items[index].stage = .ripping
            workingPath = try await runMakeMKV(toFolder: ripDir, item: index)
        }

        // Stage 2: HandBrake
        items[index].stage = .encoding
        items[index].stageProgress = 0
        let baseName: String = {
            if workingPath.hasPrefix("/dev/") {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd_HHmmss"
                return "DVD_\(f.string(from: Date()))"
            }
            return (((workingPath as NSString).lastPathComponent) as NSString).deletingPathExtension
        }()
        let outFile = outputDir.appendingPathComponent(baseName).appendingPathExtension("m4v").path
        try await runHandBrake(source: workingPath, outFile: outFile, item: index)
        items[index].finalPath = outFile

        // Stage 3: FileBot
        items[index].stage = .renaming
        items[index].stageProgress = 0
        if tools.hasFileBot {
            let renamed = try await runFileBot(input: outFile, item: index)
            items[index].finalPath = renamed
        } else {
            items[index].stageNote = "Skipped — FileBot not installed"
            log("FileBot not available; skipping rename stage")
        }

        // Stage 4: SublerCli
        items[index].stage = .tagging
        items[index].stageProgress = 0
        try await runSublerCli(input: items[index].finalPath ?? outFile, item: index)
    }

    // MARK: - Stage runners

    private func runMakeMKV(toFolder ripFolder: String, item: Int) async throws -> String {
        guard let bin = tools.makemkvCon else {
            throw ToolError.notFound("MakeMKV (makemkvcon)")
        }
        try FileManager.default.createDirectory(
            atPath: ripFolder,
            withIntermediateDirectories: true
        )

        // makemkvcon mkv disc:0 all <folder>
        // --minlength=3600 filters out menus and short clips (< 60 min)
        // -r enables robot output for clean parseability
        // --progress=-stderr sends progress lines to stderr we can stream
        let args = [
            "-r",
            "--minlength=3600",
            "--progress=-stderr",
            "mkv", "disc:0", "all",
            ripFolder,
        ]

        items[item].stageNote = "Ripping disc — this can take 30–60 minutes"

        try await runProcess(
            launch: bin,
            args: args,
            stage: .ripping,
            item: item,
            parseLine: { line in
                // PRGV:current,total,max
                if line.hasPrefix("PRGV:") {
                    let nums = line.dropFirst(5).split(separator: ",")
                    if nums.count == 3,
                       let total = Double(nums[1]),
                       let max = Double(nums[2]),
                       max > 0 {
                        return total / max
                    }
                }
                return nil
            }
        )

        // Pick the largest .mkv produced — typically the main feature.
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: ripFolder)
        let mkvs = contents.filter { $0.hasSuffix(".mkv") }
        guard !mkvs.isEmpty else {
            throw NSError(
                domain: "MediaVault", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "MakeMKV produced no MKV files"]
            )
        }
        let largest = mkvs.max { lhs, rhs in
            let l = (try? fm.attributesOfItem(atPath: "\(ripFolder)/\(lhs)")[.size] as? NSNumber)?.intValue ?? 0
            let r = (try? fm.attributesOfItem(atPath: "\(ripFolder)/\(rhs)")[.size] as? NSNumber)?.intValue ?? 0
            return l < r
        }!
        return "\(ripFolder)/\(largest)"
    }

    private func runHandBrake(source: String, outFile: String, item: Int) async throws {
        guard let bin = tools.handbrakeCLI else {
            throw ToolError.notFound("HandBrakeCLI")
        }

        // HandBrake CLI args:
        //   -i <source>    : input (file path, /dev/diskN for DVD, or VIDEO_TS dir)
        //   -o <out>       : output .m4v
        //   --preset-import-gui : also load presets the user customized in HandBrake.app
        //   --preset "Apple 2160p60 4K HEVC Surround" : built-in 4K preset (HB 1.3+)
        //   -v 1           : enable progress lines
        let args = [
            "-i", source,
            "-o", outFile,
            "--preset-import-gui",
            "--preset", "Apple 2160p60 4K HEVC Surround",
            "-v", "1",
        ]

        items[item].stageNote = "Transcoding to Apple 4K HEVC…"

        try await runProcess(
            launch: bin,
            args: args,
            stage: .encoding,
            item: item,
            parseLine: { line in
                // "Encoding: task 1 of 1, 12.34 %"
                if let range = line.range(of: #"Encoding:.* ([0-9.]+) %"#,
                                          options: .regularExpression) {
                    let chunk = String(line[range])
                    if let pctRange = chunk.range(of: #"([0-9.]+) %"#,
                                                  options: .regularExpression) {
                        let raw = String(chunk[pctRange]).replacingOccurrences(of: " %", with: "")
                        if let pct = Double(raw) { return pct / 100.0 }
                    }
                }
                return nil
            }
        )

        guard FileManager.default.fileExists(atPath: outFile),
              let attrs = try? FileManager.default.attributesOfItem(atPath: outFile),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0 else {
            throw NSError(
                domain: "MediaVault", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "HandBrake produced no output file"]
            )
        }
    }

    private func runFileBot(input: String, item: Int) async throws -> String {
        guard let bin = tools.filebot else { return input }

        // filebot -rename <file> --db TheMovieDB --format "{n} ({y})" -non-strict
        //         --action move --conflict auto
        let args = [
            "-rename", input,
            "--db", "TheMovieDB",
            "--format", "{n} ({y})",
            "-non-strict",
            "--action", "move",
            "--conflict", "auto",
        ]

        items[item].stageNote = "Looking up title on TheMovieDB…"
        let runStart = Date()
        let inputURL = URL(fileURLWithPath: input)
        let parentDir = inputURL.deletingLastPathComponent()

        try await runProcess(
            launch: bin,
            args: args,
            stage: .renaming,
            item: item,
            parseLine: { _ in nil } // FileBot doesn't emit numeric progress
        )

        let fm = FileManager.default
        if let dirItems = try? fm.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let candidates = dirItems.filter { url in
                let ext = url.pathExtension.lowercased()
                guard ["m4v", "mp4", "mkv"].contains(ext) else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { return false }
                guard let mod = values?.contentModificationDate else { return false }
                return mod >= runStart
            }
            if let newest = candidates.max(by: { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lm < rm
            }), fm.fileExists(atPath: newest.path) {
                return newest.path
            }
        }

        items[item].stageNote = "No rename applied (no match or already named)"
        return input
    }

    private func runSublerCli(input: String, item: Int) async throws {
        guard let bin = tools.sublerCLI else {
            throw ToolError.notFound("SublerCli")
        }

        // SublerCli -source <file> -optimize
        // Uses the filename to search TheMovieDB / iTunes, writing metadata
        // and cover art into the .m4v atoms in place.
        let args = ["-source", input, "-optimize"]

        items[item].stageNote = "Fetching cover art and metadata…"

        try await runProcess(
            launch: bin,
            args: args,
            stage: .tagging,
            item: item,
            parseLine: { _ in nil }
        )
    }

    // MARK: - Generic process runner with line-streaming

    private func runProcess(
        launch: String,
        args: [String],
        stage: PipelineStage,
        item: Int,
        parseLine: @Sendable @escaping (String) -> Double?
    ) async throws {
        log("$ \(launch) \(args.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream both pipes line-by-line into the log + parser. These tasks
        // exit naturally when the pipe reaches EOF (process closes its end).
        let outTask = streamPipe(outPipe, item: item, parseLine: parseLine)
        let errTask = streamPipe(errPipe, item: item, parseLine: parseLine)

        do {
            try proc.run()
        } catch {
            outTask.cancel()
            errTask.cancel()
            throw NSError(
                domain: "MediaVault", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not launch \(launch): \(error.localizedDescription)"]
            )
        }

        // Wait for the process on a background thread so we don't block the
        // MainActor (which would freeze the UI for hours during HandBrake).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }

        // Now that the process has exited, both pipes will EOF; let the
        // streamers finish draining any remaining buffered output.
        _ = await outTask.value
        _ = await errTask.value

        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "MediaVault", code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "\(stage.rawValue) exited with status \(proc.terminationStatus)"
                ]
            )
        }
    }

    private nonisolated func streamPipe(
        _ pipe: Pipe,
        item: Int,
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
                        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            // Compute progress on the background thread
                            // (parseLine is just regex), then hop to main
                            // actor only for the state mutation.
                            let pct = parseLine(cleaned)
                            await self?.applyLine(cleaned, progress: pct, item: item)
                        }
                    }
                }
            }
        }
    }

    private func applyLine(_ line: String, progress: Double?, item: Int) {
        log(line)
        if let pct = progress, items.indices.contains(item) {
            items[item].stageProgress = max(0, min(1, pct))
        }
    }

    // MARK: - Logging

    private func openLog() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = outputDir.appendingPathComponent("conversion_log_\(f.string(from: Date())).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        logURL = url
        log("MediaVault log started \(Date())")
    }

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - Notifications

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

    private func showError(title: String, message: String) async {
        // We're already on MainActor; NSAlert just runs synchronously here.
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }
}
