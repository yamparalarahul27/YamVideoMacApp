import Foundation

// Past videos for the Library (docs/plans/distribution.md): reading project files and
// Export for YouTube folders the owner already has, and matching each export to its
// project. Nothing here copies a file; the Library keeps only where things are.

/// What a project file says about its videos, read when needed and never stored.
struct ProjectSummary: Equatable {
    struct Recording: Equatable { var id: UUID; var name: String; var title: String; var duration: Double }
    struct ShortVideo: Equatable { var id: UUID; var recording: UUID; var title: String; var length: Double }

    var projectID: UUID
    var path: String
    var recordings: [Recording]
    var shorts: [ShortVideo]

    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    /// The title for a new item made from this project: the first recording's YouTube
    /// title, or the file's name.
    var title: String {
        let titled = recordings.first { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }?.title
        return String((titled ?? name).prefix(ContentItem.titleLimit))
    }

    static func read(_ url: URL) -> ProjectSummary? {
        guard let data = try? Data(contentsOf: url), let project = try? VideoProject.decodeMigrating(from: data),
              let projectID = project.projectID else { return nil }
        return ProjectSummary(
            projectID: projectID, path: url.path,
            recordings: project.clips.map {
                .init(id: $0.id, name: $0.url.lastPathComponent, title: $0.publish?.title ?? "", duration: $0.timeline.duration)
            },
            shorts: project.clips.flatMap { clip in
                (clip.shorts ?? []).map { .init(id: $0.id, recording: clip.id, title: $0.title, length: $0.length) }
            })
    }
}

/// One Export for YouTube on disk, read from its `.youtube.json`.
struct FoundExport: Equatable {
    var json: String
    var title: String
    var description: String
    var tags: [String]
    var short: Bool
    var shortID: UUID?
    /// Written by exports from 2026-10-17 on; older ones are matched by the Short or title.
    var projectID: UUID?
    var recordingID: UUID?
    var length: Double?
    /// When the export was written: the file's date.
    var exported: Date
    var video: String?
    /// The Short's cover or the video's thumbnail.
    var cover: String?

    static func read(_ url: URL) -> FoundExport? {
        guard url.lastPathComponent.hasSuffix(".youtube.json"), let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let keys) = root,
              let title = keys["title"]?.string else { return nil }
        let folder = url.deletingLastPathComponent()
        func file(_ name: String) -> String? {
            guard case .object(let files)? = keys["files"], let file = files[name]?.string else { return nil }
            let path = folder.appendingPathComponent(file).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let tags: [String] = { if case .array(let values)? = keys["tags"] { return values.compactMap(\.string) }; return [] }()
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return FoundExport(json: url.path, title: title, description: keys["description"]?.string ?? "", tags: tags,
                           short: keys["short"] == .bool(true), shortID: keys["shortID"]?.string.flatMap(UUID.init(uuidString:)),
                           projectID: keys["projectID"]?.string.flatMap(UUID.init(uuidString:)),
                           recordingID: keys["recordingID"]?.string.flatMap(UUID.init(uuidString:)),
                           length: keys["length"]?.number, exported: date,
                           video: file("video"), cover: file("cover") ?? file("thumbnail"))
    }

    /// Everything to paste into YouTube Studio again.
    var everything: String {
        ["TITLE", title, "", "DESCRIPTION", description, "", "TAGS", tags.joined(separator: ", ")].joined(separator: "\n")
    }
}

enum LibraryScan {
    /// Something found that can be added to the Library: a project with the exports made
    /// from it, or an export whose project was not found.
    struct Candidate: Identifiable, Equatable {
        var path: String
        var title: String
        var project: ProjectSummary?
        var exports: [FoundExport]
        /// The item that already holds it, if any.
        var existing: UUID?
        /// Exports the Library does not have yet.
        var newExports: Int

        var id: String { path }
        /// Adding it would change nothing.
        var alreadyAdded: Bool { existing != nil && newExports == 0 }
    }

    static let entryLimit = 50_000

    /// Project files and `.youtube.json` files at or under `roots`, skipping hidden
    /// folders and the inside of packages.
    static func files(in roots: [URL]) -> (projects: [URL], exports: [URL]) {
        var projects: [URL] = [], exports: [URL] = []
        func take(_ url: URL) {
            if url.pathExtension.lowercased() == "yamvideo" { projects.append(url) }
            else if url.lastPathComponent.hasSuffix(".youtube.json") { exports.append(url) }
        }
        var seen = 0
        for root in roots {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else { take(root); continue }
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                seen += 1
                if seen > entryLimit { break }
                take(url)
            }
        }
        func unique(_ urls: [URL]) -> [URL] {
            var paths = Set<String>()
            return urls.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }.sorted { $0.path < $1.path }
        }
        return (unique(projects), unique(exports))
    }

    /// Whether `export` was made from `project`.
    static func matches(_ export: FoundExport, _ project: ProjectSummary) -> Bool {
        if let id = export.projectID { return id == project.projectID }
        if export.short { return export.shortID.map { id in project.shorts.contains { $0.id == id } } ?? false }
        if let recording = export.recordingID { return project.recordings.contains { $0.id == recording } }
        let title = export.title.trimmingCharacters(in: .whitespaces)
        return !title.isEmpty && project.recordings.contains { $0.title.trimmingCharacters(in: .whitespaces) == title }
    }

    /// Everything under `roots` that can be added, compared with what `library` holds.
    static func candidates(roots: [URL], library: Library) -> [Candidate] {
        let (projectFiles, exportFiles) = files(in: roots)
        let projects = projectFiles.compactMap(ProjectSummary.read)
        var exports = exportFiles.compactMap(FoundExport.read)
        let recorded = Set(library.items.flatMap { $0.videos.flatMap { $0.exports.map(\.json) } })
        var result: [Candidate] = []
        for project in projects {
            let mine = exports.filter { matches($0, project) }
            exports.removeAll { export in mine.contains(export) }
            let existing = library.item(forProject: project.projectID)?.id
            result.append(Candidate(path: project.path, title: project.title, project: project, exports: mine, existing: existing,
                                    newExports: mine.filter { !recorded.contains($0.json) }.count))
        }
        for export in exports {
            let holder = library.items.first { $0.videos.contains { $0.exports.contains { $0.json == export.json } } }?.id
            result.append(Candidate(path: export.json, title: export.title, project: nil, exports: [export], existing: holder,
                                    newExports: holder == nil ? 1 : 0))
        }
        return result
    }

    /// The video an export is of. Its ID is the Short's or the recording's when they are
    /// known, so it lines up with the project; otherwise one made from the export's path.
    static func piece(_ export: FoundExport, in project: ProjectSummary?) -> VideoPiece {
        var recording = export.recordingID
        let id: UUID
        if export.short, let short = export.shortID {
            id = short
            recording = recording ?? project?.shorts.first { $0.id == short }?.recording
        } else if let known = recording ?? project.flatMap({ summary in
            summary.recordings.first { !export.title.isEmpty && $0.title == export.title }?.id ?? (summary.recordings.count == 1 ? summary.recordings[0].id : nil)
        }) {
            id = known; recording = known
        } else {
            id = UUID(deterministicFrom: Data(export.json.utf8))
        }
        return VideoPiece(id: id, short: export.short, recording: recording, title: String(export.title.prefix(ContentItem.titleLimit)),
                          exports: [VideoExport(json: export.json, exported: export.exported)])
    }

    /// The Library commands that add `candidates`: new items for new things, new exports
    /// for items that already hold their project.
    static func commands(_ candidates: [Candidate], now: Date = Date()) -> [LibraryCommand] {
        candidates.filter { !$0.alreadyAdded }.map { candidate in
            var videos: [VideoPiece] = []
            for export in candidate.exports {
                let piece = piece(export, in: candidate.project)
                if let at = videos.firstIndex(where: { $0.id == piece.id }) { videos[at] = videos[at].merged(with: piece) }
                else { videos.append(piece) }
            }
            if let existing = candidate.existing { return .addVideos(id: existing, videos: videos) }
            let created = ((try? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now)
            let link = candidate.project.map { ProjectLink(projectID: $0.projectID, path: $0.path) }
            return .addIdea(ContentItem(title: candidate.title.isEmpty ? "Untitled video" : candidate.title, created: min(created, now),
                                        project: link, videos: videos))
        }
    }
}
