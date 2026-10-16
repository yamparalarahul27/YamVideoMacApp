import Foundation
import UniformTypeIdentifiers

// The Library (docs/plans/distribution.md): the owner's ideas and, from later phases, their
// posts, calendar and results. It spans every project, so it lives in its own folder on
// this Mac rather than in a project file. Each idea is a content item; a project made
// from it is linked by its identity, so moving the file never breaks the link.

/// Where an item is on its way from an idea to a posted video. Worked out from the item,
/// never stored. Later phases add ready, scheduled and posted.
enum ContentStage: String, Codable, CaseIterable, Identifiable {
    case idea, inProduction

    var id: String { rawValue }
    var label: String {
        switch self {
        case .idea: return "Idea"
        case .inProduction: return "In production"
        }
    }
}

/// A project made from an idea: its identity (`VideoProject.projectID`) and where it was
/// last seen. The path follows the file when the owner opens or saves it somewhere else.
struct ProjectLink: Codable, Equatable {
    var projectID: UUID
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// One idea, and later everything made and posted from it.
struct ContentItem: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var notes = ""
    /// What the video is about, for grouping and, in phase 4, comparing. Nil is none.
    var topic: String?
    /// Web pages that inspired it, as typed: http or https.
    var links: [String] = []
    /// File names in the Library's Images folder; the files are copies, so the originals
    /// can move or go.
    var images: [String] = []
    var created: Date
    var updated: Date
    /// Nil while it is only an idea.
    var project: ProjectLink?

    init(id: UUID = UUID(), title: String, notes: String = "", topic: String? = nil, links: [String] = [],
         images: [String] = [], created: Date = Date(), project: ProjectLink? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.topic = topic; self.links = links
        self.images = images; self.created = Self.stamp(created); self.updated = self.created; self.project = project
    }

    /// Times to the whole second, as the file writes them, so an idea reads back equal.
    static func stamp(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    var stage: ContentStage { project == nil ? .idea : .inProduction }

    private enum CodingKeys: String, CodingKey { case id, title, notes, topic, links, images, created, updated, project }

    /// Missing keys keep their defaults, so a partial item is complete.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
        project = try c.decodeIfPresent(ProjectLink.self, forKey: .project)
    }
}

/// Everything in the Library, as `Library.json` stores it.
struct Library: Codable, Equatable {
    /// 1: ideas with notes, links, images, a topic and a linked project.
    static let currentVersion = 1

    var version = Library.currentVersion
    /// Counts every committed change, undo and redo, and is saved with the file, so an
    /// agent's plan from before a relaunch can never match by accident.
    var revision = 0
    var items: [ContentItem] = []

    func item(_ id: UUID?) -> ContentItem? { id.flatMap { id in items.first { $0.id == id } } }

    /// The item a project belongs to, if any.
    func item(forProject id: UUID) -> ContentItem? { items.first { $0.project?.projectID == id } }

    /// Every topic in use, in alphabetical order, each once whatever its case.
    var topics: [String] {
        var seen = Set<String>()
        return items.compactMap(\.topic).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The first thing that makes this not a valid Library, or nil.
    var problem: String? {
        guard Set(items.map(\.id)).count == items.count else { return "Two ideas share one ID." }
        let linked = items.compactMap(\.project?.projectID)
        guard Set(linked).count == linked.count else { return "Two ideas are linked to the same project." }
        for item in items { if let problem = item.problem { return problem } }
        return nil
    }

    /// Reads a Library file: a newer version is refused rather than half read.
    static func decode(_ data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: data)
        guard library.version <= currentVersion else {
            throw EditError.invalid("This Library was saved by a newer version of YamVideo.")
        }
        if let problem = library.problem { throw EditError.invalid(problem) }
        return library
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

// MARK: - Rules

extension ContentItem {
    static let titleLimit = 200
    static let notesLimit = 20_000
    static let topicLimit = 60
    static let linkLimit = 2048
    static let linkCount = 50
    static let imageCount = 50

    /// The first thing an idea may not hold, or nil.
    var problem: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "An idea needs a title." }
        if title.count > Self.titleLimit { return "A title is at most \(Self.titleLimit) characters; this one is \(title.count)." }
        if title.contains(where: \.isNewline) { return "A title is one line." }
        if notes.count > Self.notesLimit { return "Notes are at most \(Self.notesLimit) characters; these are \(notes.count)." }
        if let topic {
            if topic.trimmingCharacters(in: .whitespaces).isEmpty { return "A topic has words in it; leave it out for none." }
            if topic.count > Self.topicLimit { return "A topic is at most \(Self.topicLimit) characters." }
            if topic.contains(where: \.isNewline) { return "A topic is one line." }
        }
        if links.count > Self.linkCount { return "An idea holds at most \(Self.linkCount) links." }
        for link in links { if let problem = Self.linkProblem(link) { return problem } }
        if images.count > Self.imageCount { return "An idea holds at most \(Self.imageCount) images." }
        guard Set(images).count == images.count else { return "An image is listed twice." }
        for image in images where !Self.isImageName(image) { return "\(image) is not one of the Library's image files." }
        if let project, project.path.isEmpty || !project.path.hasPrefix("/") {
            return "A linked project's path is an absolute path to its .yamvideo file."
        }
        return nil
    }

    /// Why `link` is not a web address an idea can keep, or nil.
    static func linkProblem(_ link: String) -> String? {
        guard link.count <= linkLimit else { return "A link is at most \(linkLimit) characters." }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, !link.contains(where: { $0.isWhitespace }) else {
            return "\"\(link.prefix(80))\" is not a web link; links start with http:// or https://."
        }
        return nil
    }

    /// A typed link made whole: whitespace trimmed, and https:// added when only the
    /// address was typed ("youtube.com/watch?v=…").
    static func normalisedLink(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://"),
              !trimmed.contains("://") else { return trimmed }
        return "https://" + trimmed
    }

    /// The Library names its images itself: a UUID and the original's extension.
    static func isImageName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return name == url.lastPathComponent && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            && LibraryImages.extensions.contains(url.pathExtension.lowercased())
    }

    /// A topic as stored: trimmed, nil when empty, and spelled like an existing topic that
    /// differs only in case, so "ai workflow" joins "AI workflow".
    static func normalisedTopic(_ text: String?, existing: [String]) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return existing.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }
}

/// The image files ideas keep, copied into the Library's Images folder.
enum LibraryImages {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
    static let byteLimit = 25 * 1024 * 1024

    /// Why `url` cannot be added to an idea, or nil.
    static func problem(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard extensions.contains(url.pathExtension.lowercased()) else {
            return "\(name) is not an image YamVideo keeps (PNG, JPEG, HEIC, GIF, WebP, TIFF or BMP)."
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else {
            return "\(name) is not there, or is not a file."
        }
        guard (values.fileSize ?? 0) <= byteLimit else { return "\(name) is larger than 25 MB." }
        return nil
    }

    /// Copies each image into `folder` under a new name, all or none: on a problem, the
    /// copies already made are removed and the problem is thrown.
    static func copy(_ sources: [URL], into folder: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        do {
            for source in sources {
                if let problem = problem(source) { throw EditError.invalid(problem) }
                let name = UUID().uuidString + "." + source.pathExtension.lowercased()
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                names.append(name)
            }
        } catch {
            for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            throw error as? EditError ?? EditError.invalid("Could not copy the image: \(error.localizedDescription)")
        }
        return names
    }
}

// MARK: - Commands

/// One typed change to the Library. The owner's controls and agents both edit through
/// these, so there is one set of rules for a valid Library.
enum LibraryCommand: Equatable {
    case addIdea(ContentItem)
    /// Nil leaves a field as it is; a topic of `.some(nil)` clears it.
    case updateIdea(id: UUID, title: String?, notes: String?, topic: String??, links: [String]?)
    case removeIdea(id: UUID)
    /// Image files already copied into the Library.
    case addImages(id: UUID, names: [String])
    case removeImage(id: UUID, name: String)
    /// Nil unlinks.
    case linkProject(id: UUID, link: ProjectLink?)

    var defaultLabel: String {
        switch self {
        case .addIdea: return "New Idea"
        case .updateIdea(_, let title, let notes, let topic, let links):
            if title != nil, notes == nil, topic == nil, links == nil { return "Rename Idea" }
            if notes != nil, title == nil, topic == nil, links == nil { return "Edit Notes" }
            if topic != nil, title == nil, notes == nil, links == nil { return "Change Topic" }
            if links != nil, title == nil, notes == nil, topic == nil { return "Change Links" }
            return "Edit Idea"
        case .removeIdea: return "Delete Idea"
        case .addImages(_, let names): return names.count == 1 ? "Add Image" : "Add Images"
        case .removeImage: return "Remove Image"
        case .linkProject(_, let link): return link == nil ? "Unlink Project" : "Link Project"
        }
    }
}

struct LibraryOutcome: Equatable {
    var library: Library
    var createdIDs: [UUID] = []
    /// Ideas that are new or different.
    var changedIDs: [UUID] = []
}

enum LibraryReducer {
    /// Applies `commands` in order, all or nothing. Every idea a command touches must be
    /// valid afterwards, and so must the whole Library. `now` stamps what changed.
    static func apply(_ commands: [LibraryCommand], to library: Library, now: Date = Date()) throws -> LibraryOutcome {
        let now = ContentItem.stamp(now)
        var outcome = LibraryOutcome(library: library)
        func index(_ id: UUID) throws -> Int {
            guard let index = outcome.library.items.firstIndex(where: { $0.id == id }) else {
                throw EditError.notFound("No idea \(id). Read the Library again.")
            }
            return index
        }
        func touched(_ id: UUID) { if !outcome.changedIDs.contains(id) { outcome.changedIDs.append(id) } }
        for command in commands {
            switch command {
            case .addIdea(var item):
                guard outcome.library.item(item.id) == nil else { throw EditError.invalid("An idea with ID \(item.id) already exists.") }
                item.topic = ContentItem.normalisedTopic(item.topic, existing: outcome.library.topics)
                item.links = item.links.map(ContentItem.normalisedLink)
                outcome.library.items.insert(item, at: 0)
                outcome.createdIDs.append(item.id)
                touched(item.id)
            case .updateIdea(let id, let title, let notes, let topic, let links):
                let i = try index(id)
                var item = outcome.library.items[i]
                if let title { item.title = title }
                if let notes { item.notes = notes }
                if let topic {
                    let others = outcome.library.items.filter { $0.id != id }.compactMap(\.topic)
                    item.topic = ContentItem.normalisedTopic(topic, existing: others)
                }
                if let links { item.links = links.map(ContentItem.normalisedLink) }
                if item != outcome.library.items[i] { item.updated = now; outcome.library.items[i] = item; touched(id) }
            case .removeIdea(let id):
                outcome.library.items.remove(at: try index(id))
                outcome.changedIDs.removeAll { $0 == id }
            case .addImages(let id, let names):
                let i = try index(id)
                guard !names.isEmpty else { continue }
                outcome.library.items[i].images += names
                outcome.library.items[i].updated = now
                touched(id)
            case .removeImage(let id, let name):
                let i = try index(id)
                guard let at = outcome.library.items[i].images.firstIndex(of: name) else {
                    throw EditError.notFound("The idea has no image \(name).")
                }
                outcome.library.items[i].images.remove(at: at)
                outcome.library.items[i].updated = now
                touched(id)
            case .linkProject(let id, let link):
                let i = try index(id)
                if let link, let other = outcome.library.item(forProject: link.projectID), other.id != id {
                    throw EditError.invalid("That project already belongs to the idea \"\(other.title)\". Unlink it there first.")
                }
                guard outcome.library.items[i].project != link else { continue }
                outcome.library.items[i].project = link
                outcome.library.items[i].updated = now
                touched(id)
            }
        }
        for id in outcome.changedIDs {
            if let problem = outcome.library.item(id)?.problem { throw EditError.invalid(problem) }
        }
        if let problem = outcome.library.problem { throw EditError.invalid(problem) }
        return outcome
    }
}
