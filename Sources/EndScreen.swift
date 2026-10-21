import CoreGraphics
import Foundation

// The end screen (graphics track G3, docs/plans/graphics-track.md): the last 5–20 s of a
// video, where YouTube lays its end screen elements over the picture. The speaker moves
// into a smaller frame over a blurred copy of the picture (native, like the move aside),
// and the engine draws empty, marked boxes where the elements go, so nothing covers them.
// Which element goes in which box is kept with the publish details. Placing the elements
// stays a YouTube Studio step: YouTube's upload API cannot set them.

enum EndScreen {
    /// YouTube shows end screen elements in the last 5 to 20 seconds of a video.
    static let lengths = 5.0...20.0
    /// YouTube allows an end screen only on a video at least this long.
    static let minimumVideo = 25.0
    /// How close to the end of the video an end screen must finish.
    static let endTolerance = 0.05
    /// The footprints of YouTube's elements on a 1920×1080 frame: a 16:9 video or playlist
    /// card, and the Subscribe or channel circle. YouTube does not publish them; creators'
    /// measurements agree within a few pixels, which the drawn boxes' margin covers.
    static let card = CGSize(width: 615, height: 346)
    static let circle = 296.0
    /// The drawn boxes reach this far past each footprint.
    static let margin = 10.0
    /// Where YouTube Studio lets end screen elements go on a 1920×1080 frame: the outline
    /// its End screen editor draws, measured on 17 Oct 2026. Studio pushes an element that
    /// reaches past it back inside, off its marked box.
    static let elementArea = CGRect(x: 41, y: 139, width: 1838, height: 778)
    static let studioStep = "YouTube Studio → Content → this video → Editor → End screen"
    static let apiNote = "YouTube's upload API cannot set end screen elements. After uploading, open "
        + studioStep + ", add these elements and drag each onto its marked box."

    /// The props a new end screen starts with.
    static let defaultProps: [String: JSONValue] = [
        "videos": .number(2), "side": .string("left"),
        "kicker": .string("Thanks for watching"), "title": .string("Watch one of these next"),
    ]
}

/// Where everything sits on the 1920×1080 design frame. graphics.js (`endLayout`) has the
/// same numbers, which `./test.sh` checks.
struct EndScreenLayout: Equatable {
    /// Which side the speaker's frame sits on; the video cards take the other.
    enum Side: String, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
        var label: String { self == .left ? "Speaker on the left" : "Speaker on the right" }
    }

    var videos: Int
    var side: Side
    /// Where the speaker's picture goes: 832×468, so the picture keeps its shape.
    var frame: CGRect
    /// The Subscribe circle's footprint.
    var circle: CGRect
    /// The video cards' footprints, top first.
    var cards: [CGRect]
    /// The kicker and title, beside the circle.
    var text: CGRect

    static let videoCounts = 1...2

    init(videos: Int = 2, side: Side = .left) {
        self.videos = min(2, max(1, videos))
        self.side = side
        let card = EndScreen.card, circle = EndScreen.circle
        // The circle ends inside YouTube's element area (bottom 917), so the frame sits high.
        // 832×468 (16:9), centred over the circle and the text, leaves a clear gap above the
        // circle (owner, 20 Oct 2026: the frame looked crowded on the circle).
        var frame = CGRect(x: 160, y: 92, width: 832, height: 468)
        var round = CGRect(x: 96, y: 612, width: circle, height: circle)
        var text = CGRect(x: 432, y: 612, width: 624, height: circle)
        var cards = self.videos == 2
            ? [CGRect(x: 1209, y: 162, width: card.width, height: card.height), CGRect(x: 1209, y: 556, width: card.width, height: card.height)]
            : [CGRect(x: 1209, y: 153, width: card.width, height: card.height)]
        if side == .right {
            func flip(_ rect: CGRect) -> CGRect { CGRect(x: 1920 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) }
            frame = flip(frame); round = flip(round); text = flip(text); cards = cards.map(flip)
        }
        self.frame = frame; self.circle = round; self.cards = cards; self.text = text
    }

    /// The layout an end screen's props ask for; missing values take the defaults.
    init(props: [String: JSONValue]) {
        self.init(videos: Int(props["videos"]?.number ?? 2), side: props["side"]?.string.flatMap(Side.init(rawValue:)) ?? .left)
    }

    /// The first thing wrong with an end screen's props, or nil.
    static func problem(props: [String: JSONValue]) -> String? {
        if let videos = props["videos"], !(videos.number.map { $0 == 1 || $0 == 2 } ?? false) {
            return "An end screen has 1 or 2 video boxes (videos: 1 or 2)."
        }
        if let side = props["side"], side.string.flatMap(Side.init(rawValue:)) == nil {
            return "The end screen's side is \"left\" or \"right\": where the speaker sits."
        }
        return nil
    }

    /// The picture's size in the frame, against the whole frame.
    var scale: Double { frame.width / 1920 }

    /// Where a box is, in words, for the upload text.
    func place(of rect: CGRect) -> String {
        let across = rect.midX < 640 ? "left" : rect.midX > 1280 ? "right" : "middle"
        if rect == circle { return "lower \(across)" }
        guard cards.count == 2 else { return across }
        return (rect == cards[0] ? "upper " : "lower ") + across
    }
}

/// Which YouTube element goes in each box of the end screen, kept with the publish details.
/// Missing keys keep their defaults, so a partial object from an agent is complete.
struct EndScreenElements: Codable, Equatable {
    /// What fills the circle.
    enum Circle: String, Codable, CaseIterable, Identifiable {
        case subscribe, channel
        var id: String { rawValue }
        var label: String { self == .subscribe ? "Subscribe" : "Another channel" }
    }

    /// What fills a video box: YouTube's video element in one of its three modes, or a playlist.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case bestForViewer, recentUpload, video, playlist
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bestForViewer: return "Best for viewer"
            case .recentUpload: return "Most recent upload"
            case .video: return "A chosen video"
            case .playlist: return "A playlist"
            }
        }
        /// The choice as YouTube Studio names it.
        var studio: String {
            switch self {
            case .bestForViewer: return "Video → Best for viewer"
            case .recentUpload: return "Video → Most recent upload"
            case .video: return "Video → Choose specific video"
            case .playlist: return "Playlist"
            }
        }
        /// Whether the owner has to say which one.
        var needsLink: Bool { self == .video || self == .playlist }
    }

    struct Video: Codable, Equatable {
        var kind = Kind.bestForViewer
        /// For a chosen video or a playlist: its YouTube link.
        var link = ""
        /// For a chosen video or a playlist: its title, to recognise it in Studio.
        var title = ""

        init(kind: Kind = .bestForViewer, link: String = "", title: String = "") { self.kind = kind; self.link = link; self.title = title }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .bestForViewer
            link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        }

        /// What the preview writes in the box.
        var label: String {
            guard kind.needsLink else { return kind.label }
            let name = title.trimmingCharacters(in: .whitespaces)
            return (kind == .video ? "Video" : "Playlist") + (name.isEmpty ? "" : ": " + name)
        }
    }

    var circle = Circle.subscribe
    /// For another channel: its link or @handle.
    var channel = ""
    /// For another channel: the message YouTube shows with it.
    var message = ""
    /// One per video box, top first. A missing one is Best for viewer.
    var videos: [Video] = [Video(kind: .bestForViewer), Video(kind: .recentUpload)]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EndScreenElements()
        circle = try c.decodeIfPresent(Circle.self, forKey: .circle) ?? defaults.circle
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? defaults.channel
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? defaults.message
        videos = try c.decodeIfPresent([Video].self, forKey: .videos) ?? defaults.videos
    }

    /// The choice for video box `index` (0 is the top one).
    func video(_ index: Int) -> Video { videos.indices.contains(index) ? videos[index] : Video() }

    var circleLabel: String {
        guard circle == .channel else { return "Subscribe" }
        let name = channel.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Channel" : "Channel: " + name
    }

    /// The first thing an edit may not store, or nil.
    var problem: String? {
        guard videos.count <= 2 else { return "An end screen has at most 2 video boxes." }
        for text in [channel, message] + videos.flatMap({ [$0.link, $0.title] }) {
            guard text.count <= 300, !text.contains(where: \.isNewline) else {
                return "End screen links, titles and the channel message are one line of at most 300 characters."
            }
        }
        return nil
    }

    /// What YouTube would not accept, as warnings: placing the elements is a Studio step.
    func issues(layout: EndScreenLayout) -> [String] {
        var issues: [String] = []
        for index in 0..<layout.cards.count {
            let video = video(index)
            let name = layout.cards.count == 1 ? "The video box" : "Video box \(index + 1)"
            guard video.kind.needsLink else { continue }
            let link = video.link.trimmingCharacters(in: .whitespaces)
            if link.isEmpty {
                issues.append("\(name) is set to \(video.kind.label.lowercased()) but has no link.")
            } else if !Self.isYouTubeLink(link) {
                issues.append("\(name)'s link is not a YouTube link: \(link)")
            }
        }
        if circle == .channel, channel.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("The circle is set to another channel but names none.")
        }
        return issues
    }

    static func isYouTubeLink(_ text: String) -> Bool {
        guard let host = URL(string: text.hasPrefix("http") ? text : "https://" + text)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

// MARK: - The end screen of a recording

extension GraphicsTrack {
    /// The recording's end screen, if it has one.
    var endScreen: Graphic? { items.first { $0.kind == .endScreen } }

    /// Where a new end screen goes: the last 20 s, or as much of them as is clear of the
    /// other graphics (a panel's slide away included), when that is at least 5 s.
    func newEndScreenSpan(duration: Double) -> (start: Double, end: Double)? {
        var start = max(0, duration - EndScreen.lengths.upperBound)
        for graphic in items where graphic.kind != .endScreen {
            start = max(start, graphic.end + (graphic.kind.zone == .panel ? Self.slide : 0))
        }
        guard duration - start >= EndScreen.lengths.lowerBound - 0.000001 else { return nil }
        return (start, duration)
    }

    /// The same graphics with the end screen's boxes labelled with what goes in them, for
    /// the preview. The export draws the boxes without labels, as YouTube's elements cover them.
    func labellingEndScreen(_ elements: EndScreenElements?) -> GraphicsTrack {
        guard let index = items.firstIndex(where: { $0.kind == .endScreen }) else { return self }
        let choices = elements ?? EndScreenElements()
        let layout = EndScreenLayout(props: items[index].props)
        var copy = self
        copy.items[index].props["guides"] = .object([
            "circle": .string(choices.circleLabel),
            "cards": .array((0..<layout.cards.count).map { .string(choices.video($0).label) }),
        ])
        return copy
    }
}

/// What goes where on a recording's end screen, and when: for the upload files and agents.
struct EndScreenPlan: Equatable {
    struct Box: Equatable {
        /// subscribe, video1 or video2.
        var id: String
        /// The element's kind: subscribe, channel, bestForViewer, recentUpload, video or playlist.
        var element: String
        /// The element as YouTube Studio names it.
        var studio: String
        var label: String
        var place: String
        /// The footprint in design pixels of a 1920×1080 frame.
        var rect: CGRect
        var link: String?
        var title: String?
    }

    var graphic: UUID
    var start: Double
    var end: Double
    var layout: EndScreenLayout
    var boxes: [Box]

    init?(graphics: GraphicsTrack?, publish: PublishInfo?, duration: Double) {
        guard let screen = graphics?.endScreen else { return nil }
        let choices = publish?.endScreen ?? EndScreenElements()
        let layout = EndScreenLayout(props: screen.props)
        self.layout = layout
        graphic = screen.id
        start = screen.start
        end = min(screen.end, duration)
        let circle = choices.circle == .subscribe
            ? Box(id: "subscribe", element: "subscribe", studio: "Subscribe", label: "Subscribe", place: layout.place(of: layout.circle),
                  rect: layout.circle)
            : Box(id: "subscribe", element: "channel", studio: "Channel", label: choices.circleLabel, place: layout.place(of: layout.circle),
                  rect: layout.circle, link: choices.channel, title: choices.message.isEmpty ? nil : choices.message)
        boxes = [circle] + layout.cards.enumerated().map { index, rect in
            let video = choices.video(index)
            return Box(id: "video\(index + 1)", element: video.kind.rawValue, studio: video.kind.studio, label: video.label,
                       place: layout.place(of: rect), rect: rect,
                       link: video.kind.needsLink ? video.link : nil, title: video.kind.needsLink && !video.title.isEmpty ? video.title : nil)
        }
    }

    var length: Double { end - start }

    /// The upload text's END SCREEN section.
    var uploadLines: [String] {
        var lines = ["END SCREEN", EndScreen.apiNote,
                     "From \(PublishInfo.timestamp(start)) to the end (\(String(format: "%.0f", length.rounded())) s)."]
        for box in boxes {
            var line = "- \(box.studio): the \(box.id == "subscribe" ? "circle" : "card") at the \(box.place)"
            line += String(format: " (left %.1f %%, top %.1f %%, %.1f %% wide)", box.rect.minX / 19.2, box.rect.minY / 10.8, box.rect.width / 19.2)
            if let link = box.link, !link.isEmpty { line += ": \(link)" }
            if let title = box.title { line += " (\(title))" }
            lines.append(line)
        }
        return lines
    }

    /// The same for an agent: times, and each box in design pixels and in fractions of the frame.
    var json: JSONValue {
        func rect(_ r: CGRect, across: Double = 1, down: Double = 1) -> JSONValue {
            func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
            return .object(["x": .number(round(r.minX / across)), "y": .number(round(r.minY / down)),
                            "width": .number(round(r.width / across)), "height": .number(round(r.height / down))])
        }
        return .object([
            "graphicID": .string(graphic.uuidString), "start": .number(start), "end": .number(end), "length": .number(length),
            "startTimestamp": .string(PublishInfo.timestamp(start)),
            "videos": .number(Double(layout.videos)), "side": .string(layout.side.rawValue),
            "speakerFrame": rect(layout.frame),
            "setIn": .string(EndScreen.studioStep), "uploadAPICanSet": .bool(false), "note": .string(EndScreen.apiNote),
            "boxes": .array(boxes.map { box in
                var object: [String: JSONValue] = [
                    "box": .string(box.id), "element": .string(box.element), "studio": .string(box.studio),
                    "label": .string(box.label), "place": .string(box.place),
                    "rect": rect(box.rect), "fraction": rect(box.rect, across: 1920, down: 1080),
                ]
                if let link = box.link { object["link"] = .string(link) }
                if let title = box.title { object["title"] = .string(title) }
                return .object(object)
            }),
        ])
    }
}
