import AppKit
import SwiftUI

/// Handles files opened from Finder ("Open With…") or dropped onto the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    /// Lets local Codex/Claude sessions edit the open project; see `LocalAgentServer`.
    private var agentServer: LocalAgentServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.loadLibrary(); AppModel.shared.restoreModule() }
        startAgentBridge()
        // Keys the timeline answers to. Here rather than as menu shortcuts because a menu
        // shortcut would take ⌘A, ⌘← and ⌘→ from a text field being typed in; this
        // monitor steps aside whenever one has the focus.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let handled = MainActor.assumeIsolated {
                let model = AppModel.shared
                guard model.module == .studio, model.selectedItem?.info != nil, !model.isConverting else { return false }
                if modifiers.subtracting(.shift).isEmpty {
                    switch event.keyCode {
                    case 49: model.togglePlayback(); return true
                    case 123: model.stepFrame(-1); return true
                    case 124: model.stepFrame(1); return true
                    default: break
                    }
                }
                guard !model.isMovieMode else { return false }
                // ⌥ arrows nudge the selected graphic on the picture: 1 px, or 10 with ⇧.
                if modifiers.subtracting(.shift) == .option, model.inspectorFocus == .graphic, model.selectedGraphic != nil {
                    let step = modifiers.contains(.shift) ? 10.0 : 1.0
                    switch event.keyCode {
                    case 123: model.nudgeSelectedGraphic(dx: -step, dy: 0); return true
                    case 124: model.nudgeSelectedGraphic(dx: step, dy: 0); return true
                    case 125: model.nudgeSelectedGraphic(dx: 0, dy: step); return true
                    case 126: model.nudgeSelectedGraphic(dx: 0, dy: -step); return true
                    default: break
                    }
                }
                switch (event.keyCode, modifiers) {
                case (123, .command): model.selectAdjacentSegment(-1)
                case (124, .command): model.selectAdjacentSegment(1)
                case (115, .shift): model.movePlayheadToSelection(start: true)     // Home
                case (119, .shift): model.movePlayheadToSelection(start: false)    // End
                case (126, .shift): model.jumpToMarker(forward: false)            // Up
                case (125, .shift): model.jumpToMarker(forward: true)             // Down
                case (_, []) where event.charactersIgnoringModifiers?.lowercased() == "m": model.addMarkerAtPlayhead()
                case (_, .shift) where event.charactersIgnoringModifiers?.lowercased() == "m":
                    if model.selectedMarker == nil {
                        model.statusMessage = "Select a marker to name it; M adds one at the playhead."
                    } else {
                        model.renamingMarker = true
                    }
                case (_, .command) where event.charactersIgnoringModifiers?.lowercased() == "a": model.selectAllSegments()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func startAgentBridge() {
        let instance = UUID()
        let server = LocalAgentServer(instanceID: instance) { line in
            await AppModel.shared.handleAgentRequest(line, instanceID: instance)
        }
        do {
            try server.start()
            agentServer = server
            let artifacts = AppModel.artifactsDirectory.appendingPathComponent(instance.uuidString, isDirectory: true)
            MainActor.assumeIsolated { AppModel.shared.agentArtifactsDirectory = artifacts }
            removeStaleArtifacts(keeping: instance)
        } catch {
            // Editing never depends on the bridge; say why agents cannot connect and carry on.
            MainActor.assumeIsolated {
                AppModel.shared.statusMessage = "Local agents cannot connect: \(error.localizedDescription)"
            }
        }
    }

    /// Previews belonging to instances that are no longer running are of no use to anyone;
    /// another running instance's are left alone.
    private func removeStaleArtifacts(keeping instance: UUID) {
        let records = (try? FileManager.default.contentsOfDirectory(at: AgentProtocol.discoveryDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        let live = Set(records.map { $0.deletingPathExtension().lastPathComponent.uppercased() } + [instance.uuidString])
        let folders = (try? FileManager.default.contentsOfDirectory(at: AppModel.artifactsDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !live.contains(folder.lastPathComponent.uppercased()) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let instance = agentServer?.instanceID {
            try? FileManager.default.removeItem(at: AppModel.artifactsDirectory.appendingPathComponent(instance.uuidString))
        }
        agentServer?.stop()
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
                Button("New Project") { model.showModule(.studio); model.newProject() }.keyboardShortcut("n").disabled(model.isConverting)
                Button("New Idea") { model.newIdea() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Add Past Videos…") { model.promptForPastVideos() }
                Button("Open Project…") { model.promptForProject() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isConverting)
                Button("Save Project") { model.saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { model.saveProject(asCopy: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Project Notes…") { model.showModule(.studio); model.showingProjectNotes = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.menuUndoTitle) { model.undoEdit() }
                    .keyboardShortcut("z").disabled(!model.canUndoInModule)
                Button(model.menuRedoTitle) { model.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedoInModule)
            }
            CommandMenu("Go") {
                Button("Library") { model.showModule(.library) }.keyboardShortcut("1")
                Button("Studio") { model.showModule(.studio) }.keyboardShortcut("2")
                Divider()
                Button("Style…") { model.showingStyle = true }.keyboardShortcut("3")
            }
            CommandMenu("Timeline") {
                Group {
                Button("Play / Pause") { model.togglePlayback() }
                Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut("b")
                Button("Trim Section Start to Playhead") { model.trimToPlayhead(start: true) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Trim Section End to Playhead") { model.trimToPlayhead(start: false) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button(model.sectionSelection.count > 1 ? "Delete Selected Sections" : "Delete Selected Section") { model.deleteSegment() }
                    .keyboardShortcut(.delete)
                    .disabled(model.sectionSelection.isEmpty)
                Divider()
                Button("Zoom In") { model.zoomTimeline(in: true) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(model.viewport.scale >= TimelineViewport.maximumScale - 0.0001)
                Button("Zoom Out") { model.zoomTimeline(in: false) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.viewport.scale <= 1.0001)
                Button("Zoom to Fit") { model.zoomTimelineToFit() }
                    .keyboardShortcut("z", modifiers: .shift)
                    .disabled(model.viewport.scale <= 1.0001)
                Divider()
                Toggle("Snapping", isOn: $model.timelineSnapping)
                Divider()
                Button("Add Marker at Playhead") { model.addMarkerAtPlayhead() }
                Button("Add Blur Effect at Playhead") { model.addBlurEffect() }
                Divider()
                Button("Auto Edit…") { model.showingAutoEdit = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }.disabled(model.module != .studio || model.selectedItem?.info == nil || model.isConverting || model.isMovieMode)
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
            CommandGroup(replacing: .help) {
                Button("Agents Manual") { AgentsManual.open() }
                Button("Copy Brief for an Agent") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentsManual.brief(ctl: AgentSetup.paths?.ctl), forType: .string)
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Reset Crop") { model.resetCrop() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
    }
}
