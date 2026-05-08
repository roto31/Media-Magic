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

    var body: some Scene {
        WindowGroup("MediaVault") {
            ContentView()
                .frame(minWidth: 720, minHeight: 540)
                .onAppear {
                    // Request notification permission once at launch.
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound]
                    ) { _, _ in }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { } // remove File > New
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
