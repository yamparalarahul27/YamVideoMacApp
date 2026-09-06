import AppKit
import SwiftUI

/// Handles files opened from Finder ("Open With…") or dropped onto the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let handled = MainActor.assumeIsolated {
                let model = AppModel.shared
                guard model.selectedItem?.info != nil, !model.isConverting else { return false }
                switch event.keyCode {
                case 49: model.togglePlayback()
                case 123: model.stepFrame(-1)
                case 124: model.stepFrame(1)
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.flushRecovery() }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }

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
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }.keyboardShortcut("n").disabled(model.isConverting)
                Button("Open Project…") { model.promptForProject() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isConverting)
                Button("Save Project") { model.saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { model.saveProject(asCopy: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoEntries.last.map { "Undo \($0.name)" } ?? "Undo") { model.undoEdit() }
                    .keyboardShortcut("z").disabled(model.undoEntries.isEmpty || model.isConverting)
                Button(model.redoEntries.last.map { "Redo \($0.name)" } ?? "Redo") { model.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.redoEntries.isEmpty || model.isConverting)
            }
            CommandMenu("Timeline") {
                Group {
                Button("Play / Pause") { model.togglePlayback() }
                Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut("b")
                Button("Trim Section Start to Playhead") { model.trimToPlayhead(start: true) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Trim Section End to Playhead") { model.trimToPlayhead(start: false) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Delete Selected Section") { model.deleteSegment() }.keyboardShortcut(.delete)
                    .disabled(model.selectedSegmentID == nil)
                }.disabled(model.selectedItem?.info == nil || model.isConverting || model.isMovieMode)
            }
            CommandGroup(after: .newItem) {
                Button("Add Videos…") { model.promptForFiles() }
                    .keyboardShortcut("o")
                Divider()
                Button(model.isMovieMode ? "Export Movie…" : "Export All") {
                    if model.isMovieMode { model.promptForMovieExport() } else { model.convertAll() }
                }
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
