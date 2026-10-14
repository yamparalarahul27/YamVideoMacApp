import SwiftUI

enum AppTab: String, Hashable {
    case record, export, edit
}

struct RootView: View {
    // Export ships first (Phase 1), so it's the landing tab until Record exists.
    @State private var tab: AppTab = .export

    var body: some View {
        TabView(selection: $tab) {
            RecordTabView()
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(AppTab.record)

            ExportTabView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up.on.square") }
                .tag(AppTab.export)

            EditTabView()
                .tabItem { Label("Edit", systemImage: "timeline.selection") }
                .tag(AppTab.edit)
        }
    }
}

/// Placeholder until Phase 4. The capture engine (CameraController,
/// FrameCompositor) is already in the target, waiting.
struct RecordTabView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Record", systemImage: "record.circle")
        } description: {
            Text("Coming in Phase 4: screen + iPhone camera to a perfectly synced take.\nUntil then, keep recording with QuickTime — and keep the screen audio; it's the sync reference.")
        }
    }
}

/// Placeholder until Phase 2.
struct EditTabView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Edit", systemImage: "timeline.selection")
        } description: {
            Text("Coming in Phase 2–3: timeline with trim, cut and snapping, crop, and privacy blur.")
        }
    }
}
