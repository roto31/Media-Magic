// MediaVaultApp.swift
// Main entry point for the MediaVault native macOS application.
//
// Architecture:
//   - SwiftUI App with a single window
//   - PipelineController manages the conversion state machine
//   - ToolManager handles CLI tool discovery/download into Application Support
//   - Each pipeline stage (MakeMKV, HandBrake, FileBot, Subler) is its own
//     async function that streams output back via a delegate.
//
// Build with: swiftc *.swift -o MediaVault -framework SwiftUI -framework AppKit
// Or: see build.sh for full .app bundle assembly.

import SwiftUI
import AppKit
import UserNotifications

@main
struct MediaVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var automationPresets = AutomationPresetStore()
    @StateObject private var tools: ToolManager
    @StateObject private var pipeline: PipelineController

    init() {
        let toolManager = ToolManager()
        let store = ConversionJobStore()
        // Lane limits chosen so concurrent file encodes don't starve a disc
        // rip (which is bottlenecked by the optical drive, not CPU). The
        // limits can be tuned later by surfacing them in `AppSettings`.
        let pipelineInstance = PipelineController(
            tools: toolManager,
            store: store,
            laneLimits: [.file: 2, .disc: 1]
        )
        _tools = StateObject(wrappedValue: toolManager)
        _pipeline = StateObject(wrappedValue: pipelineInstance)

        // Install the pipeline into the AppDelegate so we can flush state
        // and terminate child processes cleanly during shutdown.
        AppDelegate.sharedPipeline = pipelineInstance
    }

    var body: some Scene {
        WindowGroup("MediaVault") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(automationPresets)
                .environmentObject(tools)
                .environmentObject(pipeline)
                .frame(minWidth: 720, minHeight: 680)
                .onAppear {
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound]
                    ) { _, _ in }
                }
                .task {
                    // Hydrate paused / partially-completed jobs from disk.
                    // Done once per app launch.
                    let outcome = await pipeline.store.load()
                    await pipeline.applyRecovery(outcome)
                }
        }
        .windowResizability(.contentSize)
        WindowGroup("Process Log", id: "process-log") {
            LogViewerView()
                .environmentObject(pipeline)
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView(settings: settings)
                .environmentObject(automationPresets)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .help) {
                Button("FileBot CLI Guide…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.fileBotCLI)
                }
                Button("FileBot Scripts Guide…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.fileBotScripts)
                }
                Button("FileBot parameters (--def)…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.fileBotManpage)
                }
                Button("FileBot script repository…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.fileBotScriptsRepo)
                }
                Button("HandBrake CLI Guide…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.handBrakeCLI)
                }
                Button("Subler CLI Resources…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.sublerCLIResources)
                }
                Button("Subler Wiki…") {
                    MediaVaultDocumentation.open(MediaVaultDocumentation.sublerWiki)
                }
            }
        }
    }
}

private enum MediaVaultDocumentation {
    static let fileBotCLI = "https://www.filebot.net/cli.html"
    static let fileBotScripts = "https://www.filebot.net/script.html"
    static let fileBotManpage = "https://www.filebot.net/manpage.html"
    static let fileBotScriptsRepo = "https://github.com/filebot/scripts"
    static let handBrakeCLI = "https://handbrake.fr/docs/en/latest/cli/command-line-reference.html"
    static let sublerCLIResources = "https://bitbucket.org/galad87/sublercli/downloads/"
    static let sublerWiki = "https://github.com/SublerApp/Subler/wiki"

    static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static handle so SwiftUI's `App.init` can register the pipeline for
    /// shutdown cleanup. Marked `nonisolated(unsafe)` because it is only ever
    /// written once during app start and read at shutdown.
    nonisolated(unsafe) static var sharedPipeline: PipelineController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Called by AppKit before the app terminates. We return `.terminateLater`
    /// so we can asynchronously SIGKILL any child processes and flush our
    /// persistent state, then call `reply(toApplicationShouldTerminate:)` to
    /// allow the actual exit. Documented at:
    /// https://developer.apple.com/documentation/appkit/nsapplication/nsapplicationterminatereply
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let pipeline = Self.sharedPipeline else { return .terminateNow }
        Task { @MainActor in
            await pipeline.forceTerminateForAppExit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
