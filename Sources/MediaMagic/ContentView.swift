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

private enum BatchProfileSelection: Hashable {
    case settingsDefaults
    case custom
    case preset(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var presetStore: AutomationPresetStore
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var pipeline: PipelineController
    @Environment(\.openWindow) private var openWindow

    @State private var sourceKind: SourceKind = .videoFile
    @State private var pickedFiles: [URL] = []
    @State private var outputDir: URL?
    @State private var ripDir: URL?            // for Blu-ray intermediate
    @State private var dvdDevicePath: String = ""
    @State private var setupError: String?
    @State private var skipFileBotForRun: Bool = false
    @State private var skipSublerForRun: Bool = false
    @State private var copyToAppleTVForRun: Bool = false
    @State private var didApplySettingsDefaults: Bool = false
    @State private var batchProfile: BatchProfileSelection = .settingsDefaults
    @State private var runAuto = RunAutomationFields(
        fileBotDB: "TheMovieDB",
        fileBotFormat: "{n} ({y})",
        fileBotEpisodeOrder: "",
        fileBotApplyArtwork: false,
        fileBotExtraArgs: "-non-strict --action move --conflict auto",
        postScriptEnabled: false,
        postScriptDescriptorId: "",
        postScriptExtraArgs: "",
        postScriptDefBlock: "",
        postScriptInputIsParentFolder: false
    )
    @State private var didHydrateAutomationFields = false
    @State private var saveBatchPresetName = ""
    @State private var showSaveBatchPresetAlert = false

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
                if !didApplySettingsDefaults {
                    skipFileBotForRun = settings.defaultSkipFileBot
                    skipSublerForRun = settings.defaultSkipSubler
                    copyToAppleTVForRun = settings.defaultCopyToAppleTVImport
                    didApplySettingsDefaults = true
                }
                let shouldForce = settings.forceFirstRunSetupOnNextLaunch
                try await tools.prepare(forceFirstRunSetup: shouldForce)
                if shouldForce {
                    settings.forceFirstRunSetupOnNextLaunch = false
                }
                // Snapshot the resolved tool binary paths into the
                // orchestrator so its non-MainActor executors don't have to
                // hop the actor on every subprocess launch.
                await pipeline.refreshOrchestratorToolPaths()
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
        .alert(
            (pipeline.recoveryAlert?.title ?? ""),
            isPresented: Binding(
                get: { pipeline.recoveryAlert != nil },
                set: { if !$0 { pipeline.recoveryAlert = nil } }
            ),
            actions: {
                Button("OK") { pipeline.recoveryAlert = nil }
            },
            message: {
                Text(pipeline.recoveryAlert?.message ?? "")
            }
        )
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
                Text("Media Magic")
                    .font(.system(size: 20, weight: .semibold))
                Text("Disc & video → Apple TV library")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show Log") {
                openWindow(id: "process-log")
            }
            .buttonStyle(.bordered)
            .help("Open the live process log window")
            Button {
                NSApplication.shared.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
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
                Divider()
                automationCard
                Divider()
                runOptionsSection
            }
            .padding(8)
        }
        .onAppear {
            if !didHydrateAutomationFields {
                runAuto = RunAutomationFields(from: settings)
                didHydrateAutomationFields = true
            }
        }
        .onChange(of: batchProfile, perform: handleBatchProfileChange)
        .alert("Save batch preset", isPresented: $showSaveBatchPresetAlert) {
            TextField("Preset name", text: $saveBatchPresetName)
            Button("Save") {
                let name = saveBatchPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                presetStore.save(runAuto.asPreset(name: name))
                saveBatchPresetName = ""
            }
            Button("Cancel", role: .cancel) {
                saveBatchPresetName = ""
            }
        } message: {
            Text("Stores FileBot rename options and optional script automation for reuse.")
        }
    }

    private func handleBatchProfileChange(_ new: BatchProfileSelection) {
        switch new {
        case .settingsDefaults:
            runAuto = RunAutomationFields(from: settings)
        case .custom:
            break
        case .preset(let id):
            if let p = presetStore.preset(id: id) {
                runAuto = RunAutomationFields(from: p)
            }
        }
    }

    private var databasePickerRunAuto: Binding<FileBotDatabaseChoice> {
        Binding(
            get: { FileBotDatabaseChoice.matchingStored(runAuto.fileBotDB) },
            set: { choice in
                if choice != .custom {
                    runAuto.fileBotDB = choice.rawValue
                }
            }
        )
    }

    private var episodeOrderRunAuto: Binding<FileBotEpisodeOrder> {
        Binding(
            get: {
                if runAuto.fileBotEpisodeOrder.isEmpty { return .notSpecified }
                return FileBotEpisodeOrder(rawValue: runAuto.fileBotEpisodeOrder) ?? .notSpecified
            },
            set: { runAuto.fileBotEpisodeOrder = $0.rawValue }
        )
    }

    private var automationCard: some View {
        GroupBox(label: Label("Automation (this batch)", systemImage: "gearshape.2")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Batch profile", selection: $batchProfile) {
                    Text("Use Settings defaults").tag(BatchProfileSelection.settingsDefaults)
                    Text("Custom (fields below)").tag(BatchProfileSelection.custom)
                    ForEach(presetStore.presets) { p in
                        Text(p.name).tag(BatchProfileSelection.preset(p.id))
                    }
                }
                Text("Choose a saved preset or edit fields before Convert — same CLI parameters as FileBot.app / filebot CLI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("FileBot rename") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Database", selection: databasePickerRunAuto) {
                            ForEach(FileBotDatabaseChoice.allCases) { choice in
                                Text(choice.menuLabel).tag(choice)
                            }
                        }
                        if FileBotDatabaseChoice.matchingStored(runAuto.fileBotDB) == .custom {
                            TextField("Custom --db value", text: $runAuto.fileBotDB)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("Format (--format)", text: $runAuto.fileBotFormat)
                            .textFieldStyle(.roundedBorder)
                        Picker("Episode order (--order)", selection: episodeOrderRunAuto) {
                            ForEach(FileBotEpisodeOrder.allCases) { order in
                                Text(order.menuLabel).tag(order)
                            }
                        }
                        Toggle("Also fetch artwork files (--apply artwork)", isOn: $runAuto.fileBotApplyArtwork)
                        TextField("Extra args (space-separated)", text: $runAuto.fileBotExtraArgs)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }

                GroupBox("Optional FileBot script (after rename)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Run Groovy script via filebot -script", isOn: $runAuto.postScriptEnabled)
                        Picker("Script", selection: $runAuto.postScriptDescriptorId) {
                            Text("None").tag("")
                            ForEach(FileBotScriptLibrary.allDescriptors()) { d in
                                Text(d.title).tag(d.id)
                            }
                        }
                        .disabled(!runAuto.postScriptEnabled)
                        TextField("Extra script args (space-separated)", text: $runAuto.postScriptExtraArgs)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!runAuto.postScriptEnabled)
                        Text("--def lines (key=value per line, optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $runAuto.postScriptDefBlock)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 72)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                            .disabled(!runAuto.postScriptEnabled)
                        Toggle(
                            "Pass parent folder of the media file as script input (vs file path)",
                            isOn: $runAuto.postScriptInputIsParentFolder
                        )
                        .disabled(!runAuto.postScriptEnabled)
                    }
                    .padding(8)
                }

                HStack {
                    Button("Save batch fields as preset…") {
                        saveBatchPresetName = ""
                        showSaveBatchPresetAlert = true
                    }
                    .disabled(pipeline.isRunning)
                }
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
            Text("Multiple files are queued in order (e.g. TV episode batches).")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var runOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run options")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle("Skip FileBot for this run", isOn: $skipFileBotForRun)
            Toggle("Skip Subler for this run", isOn: $skipSublerForRun)
            Toggle("Copy completed file to Apple TV auto-import folder", isOn: $copyToAppleTVForRun)
            Text("Defaults come from Settings and can be overridden per run.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("/Users/chris/Movies/TV/Media.localized/Automatically Add To TV.localized")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Queue card

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            laneCard(.file, title: "File conversions", icon: "doc.on.doc")
            laneCard(.disc, title: "Disc conversions", icon: "opticaldisc")
        }
    }

    private func laneCard(_ lane: PipelineLane, title: String, icon: String) -> some View {
        let items = pipeline.items(on: lane)
        let activity = pipeline.laneActivity[lane] ?? LaneActivitySummary()
        return GroupBox(label: Label(title, systemImage: icon)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(laneStatusLine(activity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if activity.hasAny {
                        RunControlView(scope: .lane(lane))
                    }
                }
                if items.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "tray")
                                .font(.system(size: 22, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                            Text("No \(lane.rawValue.lowercased()) jobs queued")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 60)
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            QueueRow(item: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func laneStatusLine(_ a: LaneActivitySummary) -> String {
        var parts: [String] = []
        if a.running > 0   { parts.append("\(a.running) running") }
        if a.queued > 0    { parts.append("\(a.queued) queued") }
        if a.paused > 0    { parts.append("\(a.paused) paused") }
        if a.completed > 0 { parts.append("\(a.completed) done") }
        if a.failed > 0    { parts.append("\(a.failed) failed") }
        if a.stopped > 0   { parts.append("\(a.stopped) stopped") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if hasAnyActiveOrPausedJob {
                RunControlView(scope: .global)
            }
            Button {
                Task { await startConversion() }
            } label: {
                if pipeline.isRunning {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    Text("Add to queue").padding(.leading, 4)
                } else {
                    Image(systemName: "play.fill")
                    Text("Convert").padding(.leading, 2)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var hasAnyActiveOrPausedJob: Bool {
        pipeline.items.contains {
            switch $0.lifecycle {
            case .completed, .failed, .stopped: return false
            default: return true
            }
        }
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
        let fileBusy = pipeline.laneActivity[.file]?.isBusy ?? false
        let discBusy = pipeline.laneActivity[.disc]?.isBusy ?? false
        if fileBusy || discBusy {
            let active = pipeline.items.filter { $0.lifecycle == .running || $0.lifecycle == .pausing }
            if let first = active.first {
                let extra = active.count > 1 ? " (+\(active.count - 1) more)" : ""
                return "\(first.lane.rawValue): \(first.stage.rawValue) — \(first.displayName)\(extra)"
            }
            return "Scheduling…"
        }
        if let s = pipeline.summary {
            return "Last drain: \(s.succeeded.count)/\(s.totalCount) succeeded in \(s.elapsedString)"
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
            // Encode the rip folder into the source spec; `PipelineController` parses
            // `PipelineQueuedWire.bluRayRipPendingMarker` + `::` + rip directory before HandBrake.
            guard let rd = ripDir else { return }
            sources = ["bluray.bluray-pending::\(rd.path)"]
        }

        let postScriptOpts: FileBotPostScriptRunOptions? = {
            guard runAuto.postScriptEnabled, !runAuto.postScriptDescriptorId.isEmpty else { return nil }
            return FileBotPostScriptRunOptions(
                enabled: true,
                descriptorId: runAuto.postScriptDescriptorId,
                extraArgsRaw: runAuto.postScriptExtraArgs,
                defBlock: runAuto.postScriptDefBlock,
                inputUsesParentFolder: runAuto.postScriptInputIsParentFolder
            )
        }()

        let runOptions = PipelineRunOptions(
            handBrakePreset: settings.handBrakePreset,
            handBrakeExtraArgs: settings.args(from: settings.handBrakeExtraArgs),
            fileBotDB: runAuto.fileBotDB,
            fileBotFormat: runAuto.fileBotFormat,
            fileBotEpisodeOrder: runAuto.fileBotEpisodeOrder,
            fileBotApplyArtwork: runAuto.fileBotApplyArtwork,
            fileBotExtraArgs: settings.args(from: runAuto.fileBotExtraArgs),
            fileBotPostScript: postScriptOpts,
            sublerExtraArgs: settings.args(from: settings.sublerExtraArgs),
            skipFileBot: skipFileBotForRun,
            skipSubler: skipSublerForRun,
            copyToAppleTVImport: copyToAppleTVForRun
        )
        pipeline.enqueue(sources: sources, outputDirectory: outDir, options: runOptions)
    }
}

// MARK: - Queue row

private struct QueueRow: View {
    let item: ConversionItem

    private var isActive: Bool {
        item.lifecycle == .running || item.lifecycle == .pausing
    }

    private var isPaused: Bool {
        item.lifecycle == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stageIcon
                Text(item.displayName)
                    .font(.system(.body, design: .default))
                Spacer()
                lifecycleBadge
                if item.elapsed > 0 {
                    Text(PipelineSummary.format(item.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                RunControlView(
                    scope: .job(item.jobID, lane: item.lane, lifecycle: item.lifecycle),
                    compact: true
                )
            }
            if isActive || isPaused || item.stageProgress > 0 {
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
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
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
        case .fileBotScript:
            Image(systemName: "curlybraces").foregroundStyle(.teal)
        default:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
        }
    }

    private var lifecycleBadge: some View {
        let badge: (String, Color) = {
            switch item.lifecycle {
            case .queued:    return ("Queued", .gray)
            case .running:   return (item.stage.rawValue, .blue)
            case .pausing:   return ("Pausing", .orange)
            case .paused:    return ("Paused", .orange)
            case .stopping:  return ("Stopping", .red)
            case .stopped:   return ("Stopped", .red)
            case .completed: return ("Complete", .green)
            case .failed:    return ("Failed", .red)
            }
        }()
        return Text(badge.0)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.1.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var progressColor: Color {
        switch item.stage {
        case .ripping:  return .purple
        case .encoding: return .accentColor
        case .renaming: return .orange
        case .fileBotScript: return .teal
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
