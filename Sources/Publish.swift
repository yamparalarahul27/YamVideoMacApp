import Foundation

// Publishing a recording to YouTube (graphics track G3, docs/plans/graphics-track.md): what
// YouTube needs, kept with the recording, checked against YouTube's rules, and written out
// next to the video by Export for YouTube. The upload itself stays with the owner.

/// YouTube's video categories, by the name an agent sends; `youtubeID` is YouTube's number.
enum YouTubeCategory: String, Codable, CaseIterable, Identifiable {
    case filmAnimation, autos, music, pets, sports, travel, gaming, peopleBlogs, comedy
    case entertainment, news, howtoStyle, education, scienceTechnology, nonprofits

    var id: String { rawValue }
    var youtubeID: Int {
        switch self {
        case .filmAnimation: return 1
        case .autos: return 2
        case .music: return 10
        case .pets: return 15
        case .sports: return 17
        case .travel: return 19
        case .gaming: return 20
        case .peopleBlogs: return 22
        case .comedy: return 23
        case .entertainment: return 24
        case .news: return 25
        case .howtoStyle: return 26
        case .education: return 27
        case .scienceTechnology: return 28
        case .nonprofits: return 29
        }
    }
    var label: String {
        switch self {
        case .filmAnimation: return "Film & Animation"
        case .autos: return "Autos & Vehicles"
        case .music: return "Music"
        case .pets: return "Pets & Animals"
        case .sports: return "Sports"
        case .travel: return "Travel & Events"
        case .gaming: return "Gaming"
        case .peopleBlogs: return "People & Blogs"
        case .comedy: return "Comedy"
        case .entertainment: return "Entertainment"
        case .news: return "News & Politics"
        case .howtoStyle: return "Howto & Style"
        case .education: return "Education"
        case .scienceTechnology: return "Science & Technology"
        case .nonprofits: return "Nonprofits & Activism"
        }
    }
}

/// One chapter: a time on the edited recording and a one-line title.
struct Chapter: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var title: String

    init(id: UUID = UUID(), time: Double, title: String) { self.id = id; self.time = time; self.title = title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decode(Double.self, forKey: .time)
        title = try c.decode(String.self, forKey: .title)
    }
}

/// What YouTube needs for one recording. Missing keys keep their defaults, so a partial
/// object from an agent is complete.
struct PublishInfo: Codable, Equatable {
    var title = ""
    var description = ""
    var tags: [String] = []
    var category = YouTubeCategory.scienceTechnology
    /// Times are edited-recording seconds, carried through cuts like markers.
    var chapters: [Chapter] = []
    /// A local image. Export for YouTube makes it 1280×720 and under 2 MB.
    var thumbnail: URL?
    /// The captions' language (BCP 47, like "en"), for the subtitle file's name.
    var language = "en"
    /// The channel name, shown in the preview only.
    var channel = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case title, description, tags, category, chapters, thumbnail, language, channel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PublishInfo()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? defaults.description
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? defaults.tags
        category = try c.decodeIfPresent(YouTubeCategory.self, forKey: .category) ?? defaults.category
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? defaults.chapters
        // A plain path (as agents and the project write it) or a file URL.
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail).map { text in
            text.hasPrefix("file:") ? (URL(string: text) ?? URL(fileURLWithPath: text))
                : URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? defaults.channel
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(tags, forKey: .tags)
        try c.encode(category, forKey: .category)
        try c.encode(chapters, forKey: .chapters)
        try c.encodeIfPresent(thumbnail?.path, forKey: .thumbnail)
        try c.encode(language, forKey: .language)
        try c.encode(channel, forKey: .channel)
    }

    var isEmpty: Bool { self == PublishInfo() }

    // MARK: YouTube's rules

    static let titleLimit = 100
    static let descriptionLimit = 5000
    static let tagsLimit = 500
    static let chapterMinimum = 10.0
    static let chapterCount = 3
    static let thumbnailBytes = 2 * 1024 * 1024
    static let thumbnailSize = (width: 1280, height: 720)

    /// Tags as YouTube counts them: each tag, a comma between tags, and two quotes around a
    /// tag with a space in it.
    var tagCharacters: Int {
        guard !tags.isEmpty else { return 0 }
        return tags.reduce(0) { $0 + $1.count + ($1.contains(" ") ? 2 : 0) } + tags.count - 1
    }

    /// The first thing an edit may not store, or nil. YouTube's own limits are issues, not
    /// refusals, so a draft can be over them while it is written.
    var problem: String? {
        guard title.count <= 1000, description.count <= 20_000, tags.count <= 200, chapters.count <= 200 else {
            return "That publish text is far longer than YouTube allows."
        }
        guard !title.contains(where: \.isNewline) else { return "A title is one line." }
        for tag in tags where tag.isEmpty || tag.contains(where: { $0.isNewline || $0 == "," }) {
            return "A tag is a single phrase without commas or line breaks."
        }
        for chapter in chapters {
            guard chapter.time.isFinite, chapter.time >= 0 else { return "Chapter times are seconds of the edited recording, from 0." }
            guard !chapter.title.contains(where: \.isNewline), chapter.title.count <= 100 else {
                return "A chapter title is one line of at most 100 characters."
            }
        }
        guard Set(chapters.map(\.id)).count == chapters.count else { return "Two chapters share one ID." }
        guard language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            return "The language is a code like en or en-GB."
        }
        if let thumbnail, !thumbnail.isFileURL { return "The thumbnail must be a local image." }
        return nil
    }

    /// Whether an issue stops Export for YouTube, or only warns.
    enum Severity: String, Codable { case blocking, warning }

    struct Issue: Equatable, Codable {
        var field: String
        var severity: Severity
        var message: String
    }

    /// Everything YouTube would refuse or ignore, for a recording `duration` seconds long.
    func issues(duration: Double) -> [Issue] {
        var issues: [Issue] = []
        func add(_ field: String, _ severity: Severity, _ message: String) { issues.append(Issue(field: field, severity: severity, message: message)) }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { add("title", .blocking, "Add a title.") }
        if title.count > Self.titleLimit { add("title", .blocking, "The title is \(title.count) characters; YouTube allows \(Self.titleLimit).") }
        if title.contains("<") || title.contains(">") { add("title", .blocking, "YouTube does not allow < or > in a title.") }
        if fullDescription.count > Self.descriptionLimit {
            add("description", .blocking, "The description with its chapters is \(fullDescription.count) characters; YouTube allows \(Self.descriptionLimit).")
        }
        if description.contains("<") || description.contains(">") { add("description", .blocking, "YouTube does not allow < or > in a description.") }
        if tagCharacters > Self.tagsLimit {
            add("tags", .blocking, "The tags come to \(tagCharacters) characters as YouTube counts them; it allows \(Self.tagsLimit).")
        }
        if let problem = chapterProblem(duration: duration) { add("chapters", .warning, problem) }
        if thumbnail == nil {
            add("thumbnail", .warning, "No thumbnail: YouTube will pick a frame.")
        } else if let thumbnail, !FileManager.default.fileExists(atPath: thumbnail.path) {
            add("thumbnail", .blocking, "The thumbnail \(thumbnail.lastPathComponent) is no longer there.")
        }
        return issues
    }

    /// Why YouTube would not show these chapters, or nil when it will (or there are none).
    func chapterProblem(duration: Double) -> String? {
        guard !chapters.isEmpty else { return nil }
        let ordered = chapters.sorted { $0.time < $1.time }
        if ordered[0].time > 0.0005 { return "The first chapter must start at 0:00." }
        if ordered.count < Self.chapterCount { return "YouTube needs at least \(Self.chapterCount) chapters to show them." }
        if let blank = ordered.first(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "The chapter at \(Self.timestamp(blank.time)) has no title."
        }
        for (a, b) in zip(ordered, ordered.dropFirst() + [Chapter(time: duration, title: "")]) where b.time - a.time < Self.chapterMinimum - 0.0005 {
            return "The chapter at \(Self.timestamp(a.time)) is shorter than \(Int(Self.chapterMinimum)) s; YouTube turns chapters off then."
        }
        if let late = ordered.last(where: { $0.time > duration + 0.0005 }) {
            return "The chapter at \(Self.timestamp(late.time)) is after the end of the video."
        }
        return nil
    }

    /// The description as uploaded: the text, then the chapters, one per line.
    var fullDescription: String {
        let lines = chapters.sorted { $0.time < $1.time }.map { "\(Self.timestamp($0.time)) \($0.title)" }
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else { return body }
        return (body.isEmpty ? "" : body + "\n\n") + lines.joined(separator: "\n")
    }

    /// "0:00", "1:05", "1:02:03", as YouTube writes chapter times. Whole seconds, rounded down.
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int((seconds + 0.0005).rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1:05", "1:02:03" or "65" in seconds; nil for anything else.
    static func seconds(fromTimestamp text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Double($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Chapters from the edit

    /// Chapters made from what the edit already names: markers with labels, and the titles
    /// of panel and title graphics. The first starts at 0:00 ("Intro" when nothing else
    /// does), and any that would be shorter than ten seconds are left out.
    static func suggestedChapters(markers: [TimelineMarker], graphics: GraphicsTrack?, duration: Double) -> [Chapter] {
        var candidates: [(time: Double, title: String)] = markers.compactMap { marker in
            let label = marker.label.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : (marker.time, label)
        }
        for graphic in graphics?.items ?? [] {
            let title = graphic.props["title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else { continue }
            switch graphic.kind {
            case .panelTitle, .checklist, .titleCard:
                candidates.append((graphic.start, title))
            case .rule:
                let number = graphic.props["number"]?.number.map { "\(Int($0)). " } ?? ""
                candidates.append((graphic.start, number + title))
            default:
                break
            }
        }
        candidates.sort { $0.time < $1.time }
        var chapters: [Chapter] = []
        for candidate in candidates {
            let title = String(candidate.title.prefix(100))
            if chapters.isEmpty {
                chapters.append(candidate.time < chapterMinimum ? Chapter(time: 0, title: title) : Chapter(time: 0, title: "Intro"))
                if candidate.time < chapterMinimum { continue }
            }
            guard candidate.time - chapters[chapters.count - 1].time >= chapterMinimum,
                  duration - candidate.time >= chapterMinimum else { continue }
            chapters.append(Chapter(time: candidate.time, title: title))
        }
        return chapters
    }

    // MARK: Files

    /// A file name from the title: no path separators or characters Finder and YouTube
    /// dislike, at most 80 characters.
    static func fileStem(_ title: String, fallback: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = title.components(separatedBy: banned).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        let stem = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return stem.isEmpty ? fallback : stem
    }

    /// The text file Export for YouTube writes: everything to paste into YouTube Studio.
    func uploadText(files: [String]) -> String {
        var lines = ["TITLE", title, "", "DESCRIPTION", fullDescription, "", "TAGS", tags.joined(separator: ", "), "",
                     "CATEGORY", "\(category.label) (\(category.youtubeID))", "", "LANGUAGE", language]
        if !files.isEmpty { lines += ["", "FILES"] + files }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension ClipTimeline {
    /// Chapters stay on their frame through cuts, and go with it when it is cut away. The
    /// first one stays at 0:00, where YouTube needs it.
    func remap(_ chapters: [Chapter], from old: ClipTimeline) -> [Chapter] {
        chapters.compactMap { chapter in
            if chapter.time <= 0.0005 { return chapter }
            guard let time = carry(chapter.time, from: old) else { return nil }
            var moved = chapter
            moved.time = time
            return moved
        }
        .sorted { $0.time < $1.time }
    }
}
