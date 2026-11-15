import AppKit
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var downloads = DownloadStore.shared
    @State private var link = ""
    @State private var kind = DownloadKind.video
    @State private var quality = DownloadQuality.fullHD
    @State private var browser = DownloadBrowser.none
    @State private var showLogin = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloads").font(.largeTitle.weight(.semibold))
                        Text("Save a video or audio link to your Mac, then bring it into your edit.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("On your Mac", systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Download from a link").font(.headline)
                    HStack {
                        TextField("Paste a YouTube, X, Instagram or other video link", text: $link)
                            .textFieldStyle(.roundedBorder).focused($linkFocused)
                            .accessibilityLabel("Video link")
                            .onSubmit { inspect() }
                            .onChange(of: link) { _, _ in downloads.clearInspection() }
                        Button("Paste") { if let value = NSPasteboard.general.string(forType: .string) { link = value.trimmingCharacters(in: .whitespacesAndNewlines); linkFocused = true } }
                        Button("Inspect") { inspect() }.disabled(link.isEmpty || downloads.isInspecting)
                    }
                    HStack(spacing: 20) {
                        Picker("Save", selection: $kind) { ForEach(DownloadKind.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 230)
                        if kind == .video { Picker("Quality", selection: $quality) { ForEach(DownloadQuality.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 220) }
                        Spacer()
                        Button { downloads.enqueue(link, kind: kind, quality: quality, browser: browser) } label: { Label("Download", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).disabled(link.isEmpty || !DownloadEngine.missingTools.isEmpty)
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(downloads.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose Folder…") { chooseFolder() }
                        Button { try? FileManager.default.createDirectory(at: downloads.destination, withIntermediateDirectories: true); NSWorkspace.shared.open(downloads.destination) } label: { Image(systemName: "arrow.up.forward.square") }.help("Open download folder in Finder")
                    }
                    DisclosureGroup("Use a browser login", isExpanded: $showLogin) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Browser", selection: $browser) { ForEach(DownloadBrowser.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 330)
                            Text("Choose a browser where you can already view the link. Its session is used locally for this download.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.font(.callout)
                    if downloads.isInspecting { HStack { ProgressView().controlSize(.small); Text("Reading the link…").foregroundStyle(.secondary) } }
                    if let info = downloads.inspection { inspection(info) }
                    if let message = downloads.message { Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if !DownloadEngine.missingTools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Download tools needed: " + DownloadEngine.missingTools.joined(separator: ", ")).font(.headline)
                            Text("Install these tools with Homebrew, then return here. Downloads run locally.").font(.callout).foregroundStyle(.secondary)
                            Text("brew install yt-dlp ffmpeg deno").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Button("Check Again") { downloads.objectWillChange.send() }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("Queue & history").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(downloads.entries.count) downloads").foregroundStyle(.secondary).font(.callout)
                }
                if downloads.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.to.line.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Your downloads will appear here").font(.headline)
                        Text("Paste a link above to get started. Finished files stay in the folder you choose.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 10) { ForEach(downloads.entries) { entry in row(entry) } }
                }
                Text("Supports sites handled by yt-dlp, including YouTube, X, Instagram, TikTok, Vimeo and direct video links. Some links require a browser login or a newer downloader.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(32).frame(maxWidth: 1080).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func inspect() { downloads.inspect(link, browser: browser) }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose Download Folder"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = downloads.destination
        if panel.runModal() == .OK, let url = panel.url { downloads.setDestination(url) }
    }
    private func inspection(_ info: DownloadInspection) -> some View {
        HStack(spacing: 14) {
            if let image = info.thumbnail {
                AsyncImage(url: image) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(width: 132, height: 74).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(info.title).font(.headline).lineLimit(2)
                HStack { if let uploader = info.uploader { Text(uploader) }; if let duration = info.duration { Text(durationText(duration)) } }.font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.top, 4)
    }
    private func row(_ entry: DownloadEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.kind == .audio ? "waveform" : "film").font(.title2).foregroundStyle(entry.phase == .completed ? Color.green : Color.secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.headline).lineLimit(2)
                    HStack { Text(URL(string: entry.source)?.host ?? ""); Text("·"); Text(entry.phase.label); if entry.phase.isActive { Text(entry.detail) } }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.phase.isActive || entry.phase == .queued { Button("Cancel") { downloads.cancel(entry.id) } }
                if [.failed, .cancelled].contains(entry.phase) { Button("Retry") { downloads.retry(entry.id) } }
                if entry.phase == .completed {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(entry.files.map { URL(fileURLWithPath: $0) }) }
                        .disabled(!entry.files.contains { FileManager.default.fileExists(atPath: $0) })
                    if entry.kind == .video { Button("Add to Studio") { model.addFiles(entry.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }); model.showModule(.studio) }
                        .disabled(model.isConverting || !entry.files.contains { FileManager.default.fileExists(atPath: $0) }) }
                }
                Menu {
                    Button("Open source link") { if let url = URL(string: entry.source) { NSWorkspace.shared.open(url) } }
                    if !entry.files.isEmpty { Button("Copy files") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(entry.files.map { NSURL(fileURLWithPath: $0) }) } }
                    Button("Remove from history") { downloads.remove(entry.id) }.disabled(entry.phase.isActive || entry.phase == .queued)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            if entry.phase.isActive {
                if let fraction = entry.progress { ProgressView(value: fraction).tint(.accentColor) }
                else { ProgressView().progressViewStyle(.linear) }
            }
            if let error = entry.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if entry.phase == .completed, let first = entry.files.first { Text(first.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private func durationText(_ seconds: Double) -> String { let s = Int(seconds); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
}
