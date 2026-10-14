import AppKit
import SwiftUI

/// The toolbar's "Local agents" item. Editing never needs it: it reports who has
/// connected, holds the pause switch, and lists what changed recently.
struct AgentsToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label {
                Text(model.agentsPaused ? "Agents paused" : "Local agents")
            } icon: {
                Image(systemName: model.agentsPaused ? "pause.circle" : "person.2")
                    .overlay(alignment: .topTrailing) {
                        if recentlyActive && !model.agentsPaused {
                            Circle().fill(Color.green).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .labelStyle(.titleAndIcon)
        .help(model.agentsPaused ? "Agent edits are paused" : "Local Codex or Claude sessions editing this project")
        .accessibilityLabel(model.agentsPaused ? "Local agents, paused" : "Local agents")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AgentActivityView().environmentObject(model)
        }
    }

    private var recentlyActive: Bool {
        model.agentClients.contains { Date().timeIntervalSince($0.lastSeen) < 120 }
    }
}

/// Copyable commands that register the YamVideo MCP server with Claude Code or Codex.
/// They are only offered when this build sits next to its `yamvideoctl` and the adapter,
/// and are never written into either client's configuration by the app.
enum AgentSetup {
    static var paths: (ctl: String, server: String)? {
        let build = Bundle.main.bundleURL.deletingLastPathComponent()
        let ctl = build.appendingPathComponent("yamvideoctl").path
        let server = build.deletingLastPathComponent().appendingPathComponent("Tools/AgentBridge/server.mjs").path
        guard FileManager.default.isExecutableFile(atPath: ctl), FileManager.default.fileExists(atPath: server) else { return nil }
        return (ctl, server)
    }

    static func claudeCommand(ctl: String, server: String) -> String {
        "claude mcp add yamvideo -s user -e YAMVIDEO_CLIENT=Claude -e YAMVIDEO_CTL=\(quoted(ctl)) -- node \(quoted(server))"
    }

    static func codexCommand(ctl: String, server: String) -> String {
        "codex mcp add yamvideo --env YAMVIDEO_CLIENT=Codex --env YAMVIDEO_CTL=\(quoted(ctl)) -- node \(quoted(server))"
    }

    /// Single-quoted for the shell, so paths with spaces paste correctly.
    static func quoted(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AgentActivityView: View {
    @EnvironmentObject var model: AppModel
    @State private var showActivity = true
    @State private var showSetup: Bool?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local agents").font(.headline)
                Spacer()
                Toggle("Allow agent edits", isOn: Binding(get: { !model.agentsPaused }, set: { model.agentsPaused = !$0 }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            Text(model.agentsPaused
                 ? "Agents can still read this project, but their edits are refused until you allow them again."
                 : "Codex or Claude sessions on this Mac can edit this project. Each change is an ordinary undo step, credited to the agent.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            if model.agentClients.isEmpty {
                Text("No agent has connected yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.agentClients) { client in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Date().timeIntervalSince(client.lastSeen) < 120 ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(client.name).fontWeight(.medium)
                            Text(client.lastAction).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(client.lastSeen, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            DisclosureGroup("Connect an agent", isExpanded: Binding(
                get: { showSetup ?? model.agentClients.isEmpty }, set: { showSetup = $0 })) {
                setup.padding(.top, 6)
            }
            .font(.callout)

            DisclosureGroup("Recent activity", isExpanded: $showActivity) {
                if model.recentActivity.isEmpty {
                    Text("Nothing yet.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.recentActivity.prefix(12), id: \.sequence) { event in
                                activityRow(event)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 240)
                }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 400)
    }

    @ViewBuilder
    private var setup: some View {
        if let paths = AgentSetup.paths {
            VStack(alignment: .leading, spacing: 8) {
                Text("Copy a command, paste it into Terminal, then start a new session in that app. Run npm ci in Tools/AgentBridge once first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    copyButton("Copy for Claude Code", AgentSetup.claudeCommand(ctl: paths.ctl, server: paths.server))
                    copyButton("Copy for Codex", AgentSetup.codexCommand(ctl: paths.ctl, server: paths.server))
                }
                Text("Scripts can use \(paths.ctl) directly.")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else {
            Text("Connect Claude Code or Codex with the YamVideo MCP server or yamvideoctl. Tools/AgentBridge/README.md in the YamVideo source explains how.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyButton(_ title: String, _ command: String) -> some View {
        Button(copied == title ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = title
        }
        .controlSize(.small)
        .help(command)
    }

    private func activityRow(_ event: EditEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: event.origin.isHuman ? "person" : "sparkles")
                .foregroundStyle(event.origin.isHuman ? Color.secondary : Color.accentColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(event.origin.label) · \(verb(event))\(event.label)").lineLimit(2)
                Text("Revision \(event.revision) · ").font(.caption).foregroundStyle(.secondary)
                    + Text(event.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let clip = event.clips.first, model.items.contains(where: { $0.id == clip }) {
                Button("Reveal") { model.revealClip(clip) }.controlSize(.small)
            }
            // Only the step on top can be undone without undoing something newer first.
            if event.kind == .edit, let transaction = event.transactionID,
               model.undoEntries.last?.transactionID == transaction, !model.isConverting {
                Button("Undo") { model.undoEdit() }.controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func verb(_ event: EditEvent) -> String {
        switch event.kind {
        case .undo: return "Undid "
        case .redo: return "Redid "
        default: return ""
        }
    }
}

@MainActor
extension AppModel {
    /// Shows a recording because the person asked to from the activity list.
    func revealClip(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if isMovieMode { setMovieMode(false) }
        listSelection.wrappedValue = id
    }
}
