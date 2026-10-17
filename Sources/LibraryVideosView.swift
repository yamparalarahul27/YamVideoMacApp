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
                Text(item.project?.exists == false
                     ? "The project file is not where it was. Locate it to see its videos."
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
