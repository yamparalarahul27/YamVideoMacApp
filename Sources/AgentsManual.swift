import AppKit
import Foundation

/// The Agents Manual (`Resources/AgentsManual.md`): how any agent (Claude, Codex or
/// another) works with the owner in YamVideo, with a recipe for each common job. The app
/// gives it to agents with the `manual` request; `build.sh` copies it into the app.
enum AgentsManual {
    struct Reply: Encodable { var text: String; var path: String? }

    /// The app's copy, else the file in the repository (for a test run).
    static var url: URL? {
        if let bundled = Bundle.main.url(forResource: "AgentsManual", withExtension: "md") { return bundled }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentsManual.md")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    static var text: String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

    /// Opens the manual in the Mac's app for Markdown or text files.
    @MainActor
    static func open() {
        guard let url else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    /// A short brief the owner pastes into an agent's chat, so it starts the right way.
    static func brief(ctl: String?) -> String {
        let manual = ctl.map { "Run `\(AgentSetup.quoted($0)) manual` (or call the yamvideo_manual tool)" } ?? "Call the yamvideo_manual tool"
        return """
        We edit my video together in YamVideo, the editor open on this Mac. \(manual) and follow it: \
        it has the rules and a recipe for each job. Read state before you plan. Show me a plan with times \
        before a big change, and make each change one undo step with a clear label.
        """
    }
}
