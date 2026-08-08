import AppKit
import SwiftUI

/// Handles files opened from Finder ("Open With…") or dropped onto the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.addDropped(urls) }
        // Bring the existing window forward instead of leaving the drop unnoticed.
        application.activate(ignoringOtherApps: true)
        application.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct YamVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // A single window, not a WindowGroup: opening files from Finder must reuse the
        // existing window rather than stacking up duplicates of the same queue.
        Window("YamVideo", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Add Videos…") { model.promptForFiles() }
                    .keyboardShortcut("o")
                Divider()
                Button("Convert All") { model.convertAll() }
                    .keyboardShortcut("r")
                    .disabled(model.convertibleCount == 0 || model.isConverting)
                Button("Stop") { model.cancelConversion() }
                    .keyboardShortcut(".")
                    .disabled(!model.isConverting)
            }
            CommandGroup(after: .toolbar) {
                Button("Reset Crop") { model.resetCrop() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
    }
}
