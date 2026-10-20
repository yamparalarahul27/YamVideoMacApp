import AppKit
import ImageIO
import SwiftUI

// The videos of a Library item (its long video and Shorts, exported or posted) and the
// Add Past Videos sheet. See LibraryVideos.swift for the actions.

// MARK: - Videos of an item

struct ItemVideosSection: View {
    @EnvironmentObject var model: AppModel
    let item: ContentItem

    var body: some View {
        let rows = model.videoRows(item)
        InspectorSection(heading(rows)) {
            if rows.isEmpty {
                let away = item.project.map { model.macsHolding($0.projectID) } ?? []
                Text(item.project?.exists == false
                     ? (away.isEmpty ? "The project file is not where it was. Locate it to see its videos."
                                     : "The project is on \(away.joined(separator: ", ")). Open it on that Mac to see its videos.")
                     : "No videos yet. Shorts and exports made in Studio show here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        VideoRowView(itemID: item.id, row: row, hasProject: item.project?.exists == true)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }
            if let project = item.project, project.exists {
                Button("Find Exports Near the Project…") { model.scanPastVideos([project.url.deletingLastPathComponent()]) }
                    .controlSize(.small)
                    .help("Looks in the project's folder for Export for YouTube files made before the Library knew about them")
            }
        }
    }

    private func heading(_ rows: [VideoRow]) -> String {
        let shorts = rows.filter(\.short).count, long = rows.count - shorts
        guard !rows.isEmpty else { return "Videos" }
        var parts: [String] = []
        if long > 0 { parts.append(long == 1 ? "1 long" : "\(long) long") }
        if shorts > 0 { parts.append(shorts == 1 ? "1 Short" : "\(shorts) Shorts") }
        return "Videos · " + parts.joined(separator: " · ")
    }
}

private struct VideoRowView: View {
    @EnvironmentObject var model: AppModel
    let itemID: UUID
    let row: VideoRow
    let hasProject: Bool
    @State private var addingLink = false
    @State private var link = ""

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CoverThumbnail(path: row.export?.cover, size: row.short ? CGSize(width: 36, height: 64) : CGSize(width: 64, height: 36))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !row.posts.isEmpty {
                    HStack(spacing: 5) { ForEach(Array(row.posts.enumerated()), id: \.offset) { _, post in PostChip(post: post) } }
                }
            }
            Spacer(minLength: 6)
            actions
        }
        .padding(.vertical, 8)
        .popover(isPresented: $addingLink, arrowEdge: .bottom) { linkPopover }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts = [row.short ? "Short" : "Long video"]
        if let length = row.length, length > 0 { parts.append(PublishInfo.timestamp(length)) }
        if let latest = row.exports.last {
            parts.append(row.export == nil ? "export missing" : "exported \(latest.exported.formatted(date: .abbreviated, time: .omitted))")
        } else {
            parts.append("not exported")
        }
        if !row.inProject, hasProject { parts.append("not in the project now") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if row.export?.video != nil {
                Button { model.playVideo(row) } label: { Image(systemName: "play.fill") }
                    .help("Play the exported video").accessibilityLabel("Play")
            }
            let links = row.posts.compactMap(\.link)
            if links.count == 1, let only = links.first {
                Button("Open Post") { if let url = URL(string: only) { NSWorkspace.shared.open(url) } }
                    .help("Open \(only) in your browser")
            } else if links.count > 1 {
                Menu("Open Post") {
                    ForEach(links, id: \.self) { link in
                        Button(Platform.of(link)?.label ?? link) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
                    }
                }
                .fixedSize()
            }
            Menu("Copy") {
                Button("Title") { model.copyVideoText(row, .title) }
                Button("Description") { model.copyVideoText(row, .description) }.disabled(row.export == nil)
                Button("Tags") { model.copyVideoText(row, .tags) }.disabled(row.export == nil)
                Divider()
                Button("Title, Description and Tags") { model.copyVideoText(row, .everything) }.disabled(row.export == nil)
            }
            .fixedSize()
            .help("Copy what this video was published with, to use again")
            Menu {
                Button("Open in Studio") { model.openVideoInStudio(itemID, row) }.disabled(!(row.inProject && hasProject))
                Button("Show in Finder") { model.showVideoInFinder(row) }.disabled(row.export == nil)
                Divider()
                Button("Add Post Link…") { link = ""; addingLink = true }
                if row.posts.isEmpty {
                    Button("Mark Posted") { report(model.addPost(itemID, row, link: nil)) }
                } else {
                    ForEach(Array(row.posts.enumerated()), id: \.offset) { _, post in
                        Button("Remove \(post.platform?.label ?? (post.link == nil ? "Posted" : "Post"))") { report(model.removePost(itemID, row, link: post.link)) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("More")
        }
        .controlSize(.small)
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where is \"\(row.title)\" published?").font(.callout.weight(.medium))
            TextField("Paste the link from YouTube, Instagram, X or LinkedIn", text: $link)
                .textFieldStyle(.roundedBorder).frame(width: 360)
                .onSubmit(save)
            HStack {
                Text("Nothing is read from the link. It's kept so you can open the post.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add", action: save).keyboardShortcut(.defaultAction).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func save() {
        if case .success = report(model.addPost(itemID, row, link: link)) { addingLink = false }
    }

    @discardableResult
    private func report(_ result: Result<LibraryReceipt, EditError>) -> Result<LibraryReceipt, EditError> {
        if case .failure(let error) = result { model.statusMessage = error.message }
        return result
    }
}

/// Where a video is published: the platform, opening the link on a click.
struct PostChip: View {
    let post: VideoPost

    var body: some View {
        let label = post.platform.map { "On \($0.label)" } ?? (post.link == nil ? "Posted" : "Posted elsewhere")
        if let link = post.link, let url = URL(string: link) {
            Button { NSWorkspace.shared.open(url) } label: { PostedLabel(text: label) }.buttonStyle(.plain).help(link)
        } else {
            PostedLabel(text: label).help("Posted \(post.posted.formatted(date: .abbreviated, time: .omitted))")
        }
    }
}

/// The green "On YouTube" label of something posted.
struct PostedLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.green.opacity(0.16), in: Capsule())
            .foregroundStyle(Color.green)
    }
}

/// A Short's cover or a video's thumbnail, small, read off the main thread.
struct CoverThumbnail: View {
    let path: String?
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .frame(width: size.width, height: size.height)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: "film").font(.caption).foregroundStyle(.tertiary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: path) {
                guard let path else { image = nil; return }
                image = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 200,
                          ] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Add Past Videos

struct PastVideosSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let scan = model.libraryScan ?? LibraryScanState(roots: [])
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Past Videos").font(.title3.weight(.semibold))
                Text("Found in \(scan.roots.map { $0.lastPathComponent }.joined(separator: ", ")). Nothing is copied: the Library remembers where each one is.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            Group {
                if scan.scanning {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for projects and Export for YouTube files…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scan.candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text("No YamVideo projects or Export for YouTube files here.").font(.headline)
                        Text("Choose the folder where you saved the project, or where Export for YouTube wrote its files.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(scan.candidates) { candidate in CandidateRow(candidate: candidate) }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Choose Another Folder…") { model.libraryScan = nil; DispatchQueue.main.async { model.promptForPastVideos() } }
                Spacer()
                Button("Cancel") { model.libraryScan = nil }.keyboardShortcut(.cancelAction)
                let count = scan.candidates.filter { scan.chosen.contains($0.path) && !$0.alreadyAdded }.count
                Button(count == 0 ? "Add" : "Add \(count)") { model.addChosenPastVideos() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0)
            }
            .padding(14)
        }
        .frame(width: 600, height: 480)
    }
}

private struct CandidateRow: View {
    @EnvironmentObject var model: AppModel
    let candidate: LibraryScan.Candidate

    var body: some View {
        let chosen = Binding(
            get: { model.libraryScan?.chosen.contains(candidate.path) == true },
            set: { on in
                if on { model.libraryScan?.chosen.insert(candidate.path) } else { model.libraryScan?.chosen.remove(candidate.path) }
            })
        Toggle(isOn: chosen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(candidate.alreadyAdded ? .tertiary : .secondary).lineLimit(1)
                Text(candidate.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(candidate.alreadyAdded)
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts: [String] = []
        if let project = candidate.project {
            parts.append(project.recordings.count == 1 ? "1 recording" : "\(project.recordings.count) recordings")
            if !project.shorts.isEmpty { parts.append(project.shorts.count == 1 ? "1 Short" : "\(project.shorts.count) Shorts") }
            parts.append(candidate.exports.count == 1 ? "1 export" : "\(candidate.exports.count) exports")
        } else {
            parts.append(candidate.exports.first?.short == true ? "A Short exported without its project" : "An export without its project")
        }
        if candidate.alreadyAdded { parts.append("already in your Library") }
        else if candidate.existing != nil { parts.append("in your Library; adds \(candidate.newExports) new export\(candidate.newExports == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Style.md

/// The channel's Style.md: its rules by section, and the text to edit.
struct StyleSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var commit: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Style").font(.title3.weight(.semibold))
                    Text("Your channel's editing rules. Every agent reads them before it edits, and adds one only after you say yes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(StyleDoc.sections(text).enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.name).font(.callout.weight(.semibold))
                                Text(section.rules.isEmpty ? "No rules yet" : section.rules.count == 1 ? "1 rule" : "\(section.rules.count) rules")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 180)
                Divider()
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .accessibilityLabel("Style.md")
            }
            Divider()
            HStack {
                Button("Open in Text Editor") { if let file = model.styleFile { NSWorkspace.shared.open(file) } }
                    .help("Edit Style.md in your text editor; YamVideo picks up your changes")
                Button("Show in Finder") { if let file = model.styleFile { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                Spacer()
                Text("Rules are lines starting with - under a ## heading.").font(.caption).foregroundStyle(.secondary)
                Button("Done") { save(); model.showingStyle = false }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 820, height: 600)
        .onAppear { model.refreshStyleFromDisk(); text = model.library.style }
        .onChange(of: model.library.style) { _, value in if value != text { text = value } }
        .onChange(of: text) { _, _ in
            commit?.cancel()
            commit = Task { try? await Task.sleep(nanoseconds: 700_000_000); if !Task.isCancelled { save() } }
        }
        .onDisappear { commit?.cancel(); save() }
    }

    private func save() {
        guard text != model.library.style else { return }
        if case .failure(let error) = model.performLibrary([.setStyle(text)], coalesce: "style") { model.statusMessage = error.message }
    }
}

// MARK: - Project notes

/// The open project's Why notes, saved as one undo step on Done.
struct ProjectNotesSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Project Notes").font(.title3.weight(.semibold))
                Text("Why this video is edited the way it is: the choices, the feedback, what to keep next time. Video.md shows them, and agents read them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityLabel("Project notes")
            Divider()
            HStack {
                if let file = model.videoNotesFile, FileManager.default.fileExists(atPath: file.path) {
                    Button("Open Video.md") { NSWorkspace.shared.open(file) }
                        .help("Video.md is written next to the project at every save and export")
                } else {
                    Text("Video.md is written next to the project once it is saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.showingProjectNotes = false }.keyboardShortcut(.cancelAction)
                Button("Done") { model.setProjectNotes(text); model.showingProjectNotes = false }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 460)
        .onAppear { text = model.projectNotes ?? "" }
    }
}
