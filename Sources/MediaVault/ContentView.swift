// ContentView.swift
// SwiftUI main interface.
//
// Layout: a single window split into three sections:
//   1. Setup card: source-type segmented control, source picker, output picker
//   2. Queue: a List of ConversionItems with per-item progress bars
//   3. Footer: "Convert" button, live status bar
//
// On first launch the ToolManager prepares HandBrakeCLI / SublerCli — that
// progress is shown over a sheet that blocks the main UI until ready.

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var tools = ToolManager()
    @StateObject private var pipeline: PipelineController

    @State private var sourceKind: SourceKind = .videoFile
    @State private var pickedFiles: [URL] = []
    @State private var outputDir: URL?
    @State private var ripDir: URL?            // for Blu-ray intermediate
    @State private var dvdDevicePath: String = ""
    @State private var setupError: String?
    @State private var showSummary: Bool = false

    init() {
        let t = ToolManager()
        _tools = StateObject(wrappedValue: t)
        _pipeline = StateObject(wrappedValue: PipelineController(tools: t))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    setupCard
                    queueCard
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .task {
            // First-launch tool preparation.
            do {
                try await tools.prepare()
            } catch {
                setupError = error.localizedDescription
            }
        }
        .alert("Tool setup error",
               isPresented: Binding(
                get: { setupError != nil },
                set: { if !$0 { setupError = nil } }
               ),
               actions: {
                   Button("OK") { setupError = nil }
               },
               message: {
                   Text(setupError ?? "")
               })
        .sheet(isPresented: Binding(
            get: { pipeline.summary != nil && !pipeline.isRunning },
            set: { if !$0 { pipeline.summary = nil } }
        )) {
            if let s = pipeline.summary {
                SummaryView(summary: s) {
                    pipeline.summary = nil
                }
            }
        }
        .overlay {
            if tools.isPreparing {
                preparingOverlay
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("MediaVault")
                    .font(.system(size: 20, weight: .semibold))
                Text("Disc & video → Apple TV library")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            toolStatusIndicator
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var toolStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(toolsReady ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(toolsReady ? "Tools ready" : "Tools incomplete")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(toolStatusTooltip)
    }

    private var toolsReady: Bool {
        tools.handbrakeCLI != nil && tools.sublerCLI != nil
            && (sourceKind != .bluray || tools.hasMakeMKV)
    }

    private var toolStatusTooltip: String {
        var lines: [String] = []
        lines.append("HandBrakeCLI: \(tools.handbrakeCLI ?? "not found")")
        lines.append("SublerCli:    \(tools.sublerCLI ?? "not found")")
        lines.append("MakeMKV:      \(tools.makemkvCon ?? "not installed")")
        lines.append("FileBot:      \(tools.filebot ?? "not installed")")
        return lines.joined(separator: "\n")
    }

    // MARK: - Setup card

    private var setupCard: some View {
        GroupBox(label: Label("Source", systemImage: "tray.and.arrow.down")) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Type", selection: $sourceKind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch sourceKind {
                    case .videoFile:
                        videoFilePicker
                    case .dvd:
                        dvdPicker
                    case .bluray:
                        bluRayPicker
                    }
                }
                .padding(.top, 4)

                Divider()

                outputDirPicker
            }
            .padding(8)
        }
    }

    private var videoFilePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files")
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    pickFiles()
                }
                Spacer()
                Text(pickedFiles.isEmpty
                     ? "No files selected"
                     : "\(pickedFiles.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !pickedFiles.isEmpty {
                ForEach(pickedFiles, id: \.self) { url in
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var dvdPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disc device")
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                TextField("/dev/disk4", text: $dvdDevicePath)
                    .textFieldStyle(.roundedBorder)
                Button("Auto-detect") {
                    dvdDevicePath = autoDetectOpticalDrive() ?? ""
                }
            }
            Text("HandBrake reads DVDs directly from the device path. Use Disk Utility to confirm the device if auto-detect doesn't find it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bluRayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rip folder")
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                Button(ripDir?.lastPathComponent ?? "Choose…") {
                    pickRipDir()
                }
                Spacer()
                if let r = ripDir {
                    Text(r.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text("MakeMKV will rip the Blu-ray here, then HandBrake encodes the resulting MKV. Pick a folder with at least 60 GB free.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !tools.hasMakeMKV {
                Label("MakeMKV is not installed — install it from makemkv.com",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var outputDirPicker: some View {
        HStack {
            Text("Output to")
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Button(outputDir?.lastPathComponent ?? "Choose…") {
                pickOutputDir()
            }
            Spacer()
            if let o = outputDir {
                Text(o.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Queue card

    private var queueCard: some View {
        GroupBox(label: Label("Queue", systemImage: "list.bullet.rectangle")) {
            if pipeline.items.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 32, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                        Text("No items yet — pick sources above and press Convert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(minHeight: 80)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(pipeline.items) { item in
                        QueueRow(item: item, isCurrent: pipeline.isRunning &&
                                 pipeline.items.firstIndex(of: item) == pipeline.currentIndex)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(footerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                Task { await startConversion() }
            } label: {
                if pipeline.isRunning {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Text("Converting…").padding(.leading, 4)
                } else {
                    Image(systemName: "play.fill")
                    Text("Convert").padding(.leading, 2)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pipeline.isRunning || !canStart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var canStart: Bool {
        guard outputDir != nil, toolsReady else { return false }
        switch sourceKind {
        case .videoFile: return !pickedFiles.isEmpty
        case .dvd:       return !dvdDevicePath.isEmpty
        case .bluray:    return ripDir != nil && tools.hasMakeMKV
        }
    }

    private var footerStatus: String {
        if pipeline.isRunning {
            let i = pipeline.currentIndex + 1
            let n = pipeline.items.count
            let item = pipeline.items[pipeline.currentIndex]
            return "[\(i)/\(n)] \(item.stage.rawValue) — \(item.displayName)"
        }
        if let s = pipeline.summary {
            return "Last run: \(s.succeeded.count)/\(s.totalCount) succeeded in \(s.elapsedString)"
        }
        return tools.status
    }

    // MARK: - Preparing overlay (first-launch tool downloads)

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: tools.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 320)
                Text(tools.status)
                    .font(.callout)
                Text("First-launch setup — this only happens once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 16)
        }
    }

    // MARK: - Actions

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Add"
        panel.message = "Select one or more video files to convert"
        if panel.runModal() == .OK {
            pickedFiles = panel.urls
        }
    }

    private func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the output directory for converted files"
        if panel.runModal() == .OK {
            outputDir = panel.url
        }
    }

    private func pickRipDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose a working folder for the MakeMKV intermediate file"
        if panel.runModal() == .OK {
            ripDir = panel.url
        }
    }

    private func autoDetectOpticalDrive() -> String? {
        // diskutil list, look for "optical" media type
        let out = (try? Process.runShell("/usr/sbin/diskutil", ["list"])) ?? ""
        var currentDev: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("/dev/disk") {
                currentDev = String(line.split(separator: " ").first ?? "")
            }
            if line.lowercased().contains("optical"), let d = currentDev {
                return d
            }
        }
        return nil
    }

    private func startConversion() async {
        guard let outDir = outputDir else { return }
        let sources: [String]
        switch sourceKind {
        case .videoFile:
            sources = pickedFiles.map { $0.path }
        case .dvd:
            sources = [dvdDevicePath]
        case .bluray:
            // Encode the rip folder into the source spec; the controller
            // detects the .bluray-pending suffix and runs MakeMKV first.
            guard let rd = ripDir else { return }
            sources = ["bluray.bluray-pending::\(rd.path)"]
        }

        pipeline.enqueue(sources: sources, outputDirectory: outDir)
        await pipeline.run()
    }
}

// MARK: - Queue row

private struct QueueRow: View {
    let item: ConversionItem
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stageIcon
                Text(item.displayName)
                    .font(.system(.body, design: .default))
                Spacer()
                Text(item.stage.rawValue)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                if item.elapsed > 0 {
                    Text(PipelineSummary.format(item.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if isCurrent || item.stageProgress > 0 {
                ProgressView(value: item.stageProgress)
                    .progressViewStyle(.linear)
                    .tint(progressColor)
            }
            if !item.stageNote.isEmpty {
                Text(item.stageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = item.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var stageIcon: some View {
        switch item.stage {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
        }
    }

    private var progressColor: Color {
        switch item.stage {
        case .ripping:  return .purple
        case .encoding: return .accentColor
        case .renaming: return .orange
        case .tagging:  return .green
        default:        return .accentColor
        }
    }
}

// MARK: - Summary sheet

private struct SummaryView: View {
    let summary: PipelineSummary
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("Conversion complete")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(summary.succeeded.count) of \(summary.totalCount) files in \(summary.elapsedString)")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if !summary.succeeded.isEmpty {
                Text("Converted")
                    .font(.headline)
                ForEach(summary.succeeded) { item in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(item.displayName)
                        Spacer()
                        Text(PipelineSummary.format(item.elapsed))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !summary.failed.isEmpty {
                Divider()
                Text("Failed")
                    .font(.headline)
                ForEach(summary.failed) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(item.displayName)
                        }
                        if let err = item.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("Log:")
                    .foregroundStyle(.secondary)
                Text(summary.logFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: summary.logFilePath)]
                    )
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
