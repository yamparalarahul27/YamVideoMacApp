import AppKit
import Foundation

// Past and present videos in the Library: scanning a folder for projects and exports,
// the video rows an item shows, and their actions (open in Studio, play, show the files,
// open the post, copy the text). Only where things are is stored; the rest is read from
// the files when shown. See LibraryScan.swift.

/// The Scan a Folder sheet while it is up.
struct LibraryScanState: Equatable {
    var roots: [URL]
    var scanning = true
    var candidates: [LibraryScan.Candidate] = []
    /// The candidates ticked to add, by path.
    var chosen: Set<String> = []
}

/// One video an item shows: from its project file, from the Library, or both.
struct VideoRow: Identifiable, Equatable {
    var id: UUID
    var short: Bool
    var title: String
    var length: Double?
    var recording: UUID?
    /// Still in the linked project, so it can be opened in Studio.
    var inProject: Bool
    /// What the Library keeps for it: exports and posts.
    var stored: VideoPiece?
    /// Its latest export that is still on disk.
    var export: FoundExport?

    var posts: [VideoPost] { stored?.posts ?? [] }
    var exports: [VideoExport] { stored?.exports ?? [] }
}

@MainActor
extension AppModel {
    // MARK: Reading the files

    /// A project file's videos, read again only when the file changes.
    func projectSummary(_ link: ProjectLink?) -> ProjectSummary? {
        guard let link, let date = modified(link.path) else { return nil }
        if let cached = projectSummaries[link.path], cached.date == date { return cached.summary }
        guard let summary = ProjectSummary.read(link.url), summary.projectID == link.projectID else { return nil }
        projectSummaries[link.path] = (date, summary)
        return summary
    }

    /// An export's details, read again only when its file changes.
    func foundExport(_ path: String) -> FoundExport? {
        guard let date = modified(path) else { return nil }
        if let cached = exportDetails[path], cached.date == date { return cached.export }
        guard let export = FoundExport.read(URL(fileURLWithPath: path)) else { return nil }
        exportDetails[path] = (date, export)
        return export
    }

    private func modified(_ path: String) -> Date? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The videos to show for an item: every recording and Short of its project, then
    /// anything else it was exported or posted as. Long videos first.
    func videoRows(_ item: ContentItem) -> [VideoRow] {
        var rows: [VideoRow] = []
        if let summary = projectSummary(item.project) {
            for recording in summary.recordings {
                let title = recording.title.isEmpty ? (summary.recordings.count == 1 ? "The long video" : recording.name) : recording.title
                rows.append(VideoRow(id: recording.id, short: false, title: title, length: recording.duration, recording: recording.id, inProject: true))
            }
            for (index, short) in summary.shorts.enumerated() {
                rows.append(VideoRow(id: short.id, short: true, title: short.title.isEmpty ? "Short \(index + 1)" : short.title,
                                     length: short.length, recording: short.recording, inProject: true))
            }
        }
        for piece in item.videos {
            if let at = rows.firstIndex(where: { $0.id == piece.id }) {
                rows[at].stored = piece
            } else {
                rows.append(VideoRow(id: piece.id, short: piece.short, title: piece.title, length: nil, recording: piece.recording,
                                     inProject: false, stored: piece))
            }
        }
        for index in rows.indices {
            // The latest export that still has its video, or else the latest that can be read.
            let readable = rows[index].exports.reversed().compactMap { foundExport($0.json) }
            rows[index].export = readable.first { $0.video != nil } ?? readable.first
            if rows[index].length == nil { rows[index].length = rows[index].export?.length }
        }
        return rows.filter { !$0.short } + rows.filter(\.short)
    }

    // MARK: Scan a folder

    func promptForPastVideos() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.yamVideoProject, .json, .folder]
        panel.prompt = "Scan"
        panel.message = "Choose a folder with your projects and Export for YouTube folders. Nothing is copied; the Library remembers where they are."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        scanPastVideos(panel.urls)
    }

    /// Looks through `roots` off the main thread and shows what was found to tick.
    func scanPastVideos(_ roots: [URL]) {
        showModule(.library)
        libraryScan = LibraryScanState(roots: roots)
        let snapshot = library
        Task {
            let found = await Task.detached(priority: .userInitiated) { LibraryScan.candidates(roots: roots, library: snapshot) }.value
            guard libraryScan?.roots == roots else { return }
            libraryScan?.candidates = found
            libraryScan?.chosen = Set(found.filter { !$0.alreadyAdded }.map(\.path))
            libraryScan?.scanning = false
        }
    }

    /// Adds the ticked candidates as one undo step and shows the first.
    func addChosenPastVideos() {
        guard let scan = libraryScan else { return }
        let chosen = scan.candidates.filter { scan.chosen.contains($0.path) && !$0.alreadyAdded }
        libraryScan = nil
        guard !chosen.isEmpty else { return }
        switch performLibrary(LibraryScan.commands(chosen), label: chosen.count == 1 ? "Add a Past Video" : "Add Past Videos") {
        case .success(let receipt):
            selectedIdeaID = receipt.createdIDs.first ?? chosen.first?.existing ?? selectedIdeaID
            let exports = chosen.reduce(0) { $0 + $1.newExports }
            statusMessage = "Added \(chosen.count) to the Library with \(exports) export\(exports == 1 ? "" : "s"). The files stay where they are."
        case .failure(let error):
            statusMessage = error.message
        }
    }

    // MARK: Actions on a video

    /// Opens the item's project in Studio with this video's recording selected, and a
    /// Short in the Short viewer.
    func openVideoInStudio(_ itemID: UUID, _ row: VideoRow) {
        guard library.item(itemID)?.project != nil else { return }
        openLinkedProject(itemID)
        guard library.item(itemID)?.project?.projectID == projectID, module == .studio else { return }
        if let recording = row.recording, items.contains(where: { $0.id == recording }) {
            if isMovieMode { setMovieMode(false) }
            listSelection.wrappedValue = recording
        }
        if row.short, let short = selectedItem?.short(row.id) { showShort(short) }
    }

    func playVideo(_ row: VideoRow) {
        guard let path = row.export?.video else { statusMessage = "This video's exported file is no longer there."; return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showVideoInFinder(_ row: VideoRow) {
        guard let path = row.export?.video ?? row.export?.json else { statusMessage = "This video's export is no longer there."; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    enum VideoText: String, CaseIterable { case title, description, tags, everything }

    /// Copies what the video was published with, as its export says.
    func copyVideoText(_ row: VideoRow, _ part: VideoText) {
        let export = row.export
        let text: String
        switch part {
        case .title: text = export?.title ?? row.title
        case .description: text = export?.description ?? ""
        case .tags: text = export?.tags.joined(separator: ", ") ?? ""
        case .everything: text = export?.everything ?? row.title
        }
        guard !text.isEmpty else { statusMessage = "This video has no \(part.rawValue) to copy."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied the \(part == .everything ? "title, description and tags" : part.rawValue) of \"\(row.title)\"."
    }

    /// The video with a post added: where it is published, or with no link, that it is.
    static func posting(_ row: VideoRow, link text: String?) throws -> VideoPiece {
        var piece = row.stored ?? VideoPiece(id: row.id, short: row.short, recording: row.recording, title: row.title)
        let link = text.map(ContentItem.normalisedLink).flatMap { $0.isEmpty ? nil : $0 }
        if let link {
            if let problem = ContentItem.linkProblem(link) { throw EditError.invalid(problem) }
            guard !piece.posts.contains(where: { $0.link == link }) else { throw EditError.invalid("\"\(row.title)\" already has that link.") }
        } else if !piece.posts.isEmpty {
            throw EditError.invalid("\"\(row.title)\" is already marked posted.")
        }
        // A link says more than a plain "posted", so it takes its place.
        piece.posts.removeAll { $0.link == nil }
        piece.posts.append(VideoPost(link: link))
        return piece
    }

    /// The video without one post, or without any when `link` is nil.
    static func unposting(_ row: VideoRow, link: String?) throws -> VideoPiece {
        guard var piece = row.stored, !piece.posts.isEmpty else { throw EditError.invalid("\"\(row.title)\" has no post to remove.") }
        if let link {
            guard piece.posts.contains(where: { $0.link == link }) else { throw EditError.notFound("\"\(row.title)\" has no post \(link).") }
            piece.posts.removeAll { $0.link == link }
        } else {
            piece.posts = []
        }
        return piece
    }

    /// Records where a video is published (or, with no link, that it is), as one undo step.
    @discardableResult
    func addPost(_ itemID: UUID, _ row: VideoRow, link text: String?) -> Result<LibraryReceipt, EditError> {
        do {
            let piece = try Self.posting(row, link: text)
            let label = piece.posts.last?.platform.map { "Posted on \($0.label)" } ?? "Mark Posted"
            return performLibrary([.putVideo(id: itemID, video: piece)], label: label)
        } catch { return .failure(error as? EditError ?? .invalid(error.localizedDescription)) }
    }

    /// Takes one post off a video, or all of them when `link` is nil.
    @discardableResult
    func removePost(_ itemID: UUID, _ row: VideoRow, link: String?) -> Result<LibraryReceipt, EditError> {
        do { return performLibrary([.putVideo(id: itemID, video: try Self.unposting(row, link: link))], label: "Remove Post") }
        catch { return .failure(error as? EditError ?? .invalid(error.localizedDescription)) }
    }

    /// After an Export for YouTube: the item made from this project gets the export, so
    /// new exports appear without a scan. An undo step like any other change.
    func noteExport(_ json: URL, origin: EditOrigin) {
        guard let export = FoundExport.read(json), let project = export.projectID, let item = library.item(forProject: project) else { return }
        let piece = LibraryScan.piece(export, in: projectSummary(item.project))
        performLibrary([.addVideos(id: item.id, videos: [piece])], label: "Exported \(export.title)", origin: origin)
    }
}
