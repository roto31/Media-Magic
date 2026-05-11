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

    var body: some Scene {
        WindowGroup("MediaVault") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(automationPresets)
                .frame(minWidth: 720, minHeight: 680)
                .onAppear {
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound]
                    ) { _, _ in }
                }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
