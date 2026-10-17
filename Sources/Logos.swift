import CoreGraphics
import Foundation

// Logo badges: a brand's logo next to the speaker when the speaker says the brand, in the
// long video and in its Shorts. The app finds the names in the transcript (`BrandFinder`),
// keeps the owner's logos for every project (`LogoLibrary`), and works out where the
// speaker is at each badge (`LogoSpot`), so the engine only places it and the preview and
// the export agree.

// MARK: - A badge's data

/// A logo badge's props: `logos`, one to three `{image, label, at}`, each logo popping in
/// at `at` seconds after the badge starts, and `tone` light (white chips, the default) or
/// dark. `spot` is the app's, written when the badge is drawn.
enum LogoBadge {
    static let maximumLogos = 3
    static let maximumLabel = 30
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "svg", "webp", "heic"]

    /// The first thing wrong with a logo badge's props, or nil.
    static func problem(props: [String: JSONValue], length: Double) -> String? {
        guard let logos = props["logos"]?.array, !logos.isEmpty else {
            return "A logo badge needs logos: one to \(maximumLogos) {image, label, at}."
        }
        guard logos.count <= maximumLogos else { return "A logo badge shows at most \(maximumLogos) logos." }
        for logo in logos {
            guard let object = logo.object, let image = object["image"]?.string, !image.isEmpty else {
                return "Each logo in a logo badge needs image: an absolute path to a PNG, JPEG or SVG file."
            }
            guard imageTypes.contains(URL(fileURLWithPath: image).pathExtension.lowercased()) else {
                return "A logo's image must be a PNG, JPEG, SVG, WebP or HEIC file."
            }
            if let label = object["label"] {
                guard let text = label.string, text.count <= maximumLabel, !text.contains("\n") else {
                    return "A logo's label is one line of \(maximumLabel) characters or fewer."
                }
            }
            if let at = object["at"] {
                guard let time = at.number, time < length - 0.25 + 0.000001 else {
                    return String(format: "A logo's at must be a quarter of a second or more before the badge ends (it shows for %.2f s).", length)
                }
            }
        }
        if let tone = props["tone"], tone.string != "light", tone.string != "dark" { return "A logo badge's tone is light or dark." }
        return nil
    }

    /// The logos of a badge, in order: image, label, at.
    static func logos(_ props: [String: JSONValue]) -> [(image: String, label: String?, at: Double)] {
        (props["logos"]?.array ?? []).compactMap { value in
            guard let object = value.object, let image = object["image"]?.string else { return nil }
            return (image, object["label"]?.string, max(0, object["at"]?.number ?? 0))
        }
    }

    /// The badge's size in design pixels, as graphics.css draws it: a row of chips 20 px
    /// apart (or, `vertical`, one above the other); a chip is 16 px of padding, the 100 px
    /// logo, then 20 px and the label (46 px Inter Bold, about 0.6 em a character) and
    /// 36 px; without a label, 132 px square. Compact chips (a Short's) are the 96 px logo
    /// alone, 120 px square, 14 px apart.
    static func size(_ props: [String: JSONValue], compact: Bool, vertical: Bool = false) -> CGSize {
        let logos = logos(props)
        guard !logos.isEmpty else { return .zero }
        let widths = logos.map { logo -> Double in
            if compact { return 120 }
            guard let label = logo.label, !label.isEmpty else { return 132 }
            return 16 + 100 + 20 + Double(label.count) * 27.6 + 36
        }
        let height = compact ? 120.0 : 132.0, gap = compact ? 14.0 : 20.0, count = Double(widths.count)
        if vertical { return CGSize(width: widths.max() ?? 0, height: height * count + gap * (count - 1)) }
        return CGSize(width: widths.reduce(0, +) + gap * (count - 1), height: height)
    }
}

// MARK: - Where a badge sits

/// Where a logo badge sits on its canvas, in design pixels: the point its `alignX` and
/// `alignY` edges go to. Worked out from where the layout puts the speaker at the badge.
struct LogoSpot: Equatable {
    enum Edge: String { case start, middle, end }
    var x: Double
    var y: Double
    var alignX: Edge
    var alignY: Edge
    /// Logos only, without their labels: on a Short, where the captions say the name.
    var compact: Bool
    /// The logos one above the other: side by side, when a row is wider than the panel.
    var vertical = false

    /// How far the badge's near edge stays from the middle of the speaker's face, in the
    /// speaker's source pixels: about half a head, and a gap.
    static let faceGap = 190.0
    /// How far it stays from a small speaker picture (the bubble), in design pixels.
    static let boxGap = 24.0

    var json: JSONValue {
        .object(["x": .number(x.rounded()), "y": .number(y.rounded()), "alignX": .string(alignX.rawValue),
                 "alignY": .string(alignY.rawValue), "compact": .bool(compact), "vertical": .bool(vertical)])
    }

    /// Next to the speaker, inside `clear`. `speaker` is the speaker's place on the canvas,
    /// `face` the face's middle (nil when not known) and `scale` design pixels for one of
    /// the speaker's source pixels. When the speaker fills the width, the badge goes beside
    /// the face, on the side with room; beside a small picture (the bubble), on the side
    /// towards the middle of the frame; in a tall panel (side by side), at its foot, the
    /// logos one above the other (`column`, its size that way) when a row is wider than it.
    static func place(speaker: CGRect, face: CGPoint?, scale: Double, frame: CGSize, clear: CGRect,
                      size: CGSize, column: CGSize? = nil, compact: Bool) -> LogoSpot {
        var spot: LogoSpot
        var size = size
        if Double(speaker.width) >= 0.9 * Double(frame.width) {
            let centre = face ?? CGPoint(x: speaker.midX, y: speaker.minY + speaker.height * 0.42)
            let gap = faceGap * scale
            let right = Double(clear.maxX) - (Double(centre.x) + gap), left = (Double(centre.x) - gap) - Double(clear.minX)
            // The right side, unless only the left has room, or clearly more of it: the face
            // point is the recording's average, and the speaker moves.
            let width = Double(size.width)
            spot = right >= width || (left < width && right >= left - 40)
                ? LogoSpot(x: Double(centre.x) + gap, y: Double(centre.y), alignX: .start, alignY: .middle, compact: compact)
                : LogoSpot(x: Double(centre.x) - gap, y: Double(centre.y), alignX: .end, alignY: .middle, compact: compact)
        } else if Double(speaker.width) < 0.5 * Double(frame.width), Double(speaker.height) < 0.6 * Double(frame.height) {
            spot = speaker.midX <= frame.width / 2
                ? LogoSpot(x: Double(speaker.maxX) + boxGap, y: Double(speaker.midY), alignX: .start, alignY: .middle, compact: compact)
                : LogoSpot(x: Double(speaker.minX) - boxGap, y: Double(speaker.midY), alignX: .end, alignY: .middle, compact: compact)
        } else {
            spot = LogoSpot(x: Double(speaker.midX), y: Double(speaker.maxY) - 28, alignX: .middle, alignY: .end, compact: compact)
            if let column, Double(size.width) > Double(speaker.width) - 48 { spot.vertical = true; size = column }
        }
        return spot.kept(inside: clear, size: size)
    }

    /// The box the badge takes at this spot.
    func box(size: CGSize) -> CGRect {
        func lead(_ edge: Edge, _ length: Double) -> Double { edge == .start ? 0 : edge == .middle ? length / 2 : length }
        return CGRect(x: x - lead(alignX, Double(size.width)), y: y - lead(alignY, Double(size.height)), width: size.width, height: size.height)
    }

    /// Moved as little as needed to keep the badge inside `clear`.
    func kept(inside clear: CGRect, size: CGSize) -> LogoSpot {
        let box = box(size: size)
        func shift(_ low: Double, _ high: Double, _ min: Double, _ max: Double) -> Double {
            if high - low > max - min { return min - low }
            return low < min ? min - low : high > max ? max - high : 0
        }
        var moved = self
        moved.x += shift(Double(box.minX), Double(box.maxX), Double(clear.minX), Double(clear.maxX))
        moved.y += shift(Double(box.minY), Double(box.maxY), Double(clear.minY), Double(clear.maxY))
        return moved
    }
}

extension VideoItem {
    /// The recording's graphics as the engine draws them on the 16:9 video: each logo badge
    /// with its spot next to the speaker.
    var placedGraphics: GraphicsTrack? { graphics.map { placingSections(placingLogos($0, short: nil), short: nil) } }

    /// A Short's graphics (`GraphicsTrack.forShort`), each logo badge placed next to the
    /// speaker as the Short shows them. The spots are worked out in recording time, as the
    /// Short viewer plays it, so the viewer and the export agree.
    func shortGraphics(_ short: Short, recordingTime: Bool = false) -> GraphicsTrack? {
        graphics.map { placingSections(placingLogos($0, short: short), short: short).forShort(short, recordingTime: recordingTime) }
    }

    /// `track` with a spot in each logo badge's props, for the 16:9 video or for `short`.
    /// A track already on a Short's canvas is already placed and comes back as it is.
    func placingLogos(_ track: GraphicsTrack, short: Short?) -> GraphicsTrack {
        guard track.canvas == .landscape, track.items.contains(where: { $0.kind == .logoBadge }) else { return track }
        var placed = track
        for index in placed.items.indices where placed.items[index].kind == .logoBadge {
            let graphic = placed.items[index]
            if let short, graphic.start < short.start - 0.0005 || graphic.start >= short.end { continue }
            // Where the speaker is once the badge is in.
            let time = min(graphic.end, graphic.start + 0.3)
            placed.items[index].props["spot"] = logoSpot(at: time, props: graphic.props, short: short, endScreen: track.endScreen?.start).json
        }
        return placed
    }

    /// Where a badge with `props` goes at edited `time`: next to the speaker in the layout
    /// at that moment. Without a screen recording the speaker fills the picture; without a
    /// known face the badge goes to the top right of the safe area (the clear area of a Short).
    func logoSpot(at time: Double, props: [String: JSONValue], short: Short?, endScreen: Double?) -> LogoSpot {
        let compact = short != nil
        let size = LogoBadge.size(props, compact: compact), column = LogoBadge.size(props, compact: compact, vertical: true)
        let clear = short == nil ? GraphicPlacement.safeArea : ShortFormat.clearArea
        let canvas = short == nil ? CGSize(width: 1920, height: 1080) : ShortFormat.size
        let corner = LogoSpot(x: Double(clear.maxX), y: Double(clear.minY), alignX: .end, alignY: .start, compact: compact)
        guard let info else { return corner }
        let crop = (self.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        if let short, stacksScreen(short), let screen {
            let geometry = LayoutGeometry(short: screen, crop: crop, window: short.frame(info: info, crop: self.crop))
            let state = screen.state(at: time, geometry: geometry, endScreen: nil)
            return LogoSpot.place(speaker: state.speaker.rect, face: geometry.facePoint(in: state),
                                  scale: Double(state.speaker.rect.height / state.window.height), frame: canvas, clear: clear,
                                  size: size, compact: compact)
        }
        if let short {
            // The Short shows its picture across the canvas, from the top.
            let picture = short.picture(info: info, crop: self.crop)
            let k = Double(canvas.width / picture.width)
            let place = CGRect(x: 0, y: 0, width: canvas.width, height: picture.height * k)
            let face = screen?.bubble.face.map { CGPoint(x: (Double($0.x) - Double(picture.minX)) * k, y: (Double($0.y) - Double(picture.minY)) * k) }
            guard let face, place.contains(face) else { return corner.kept(inside: clear, size: size) }
            return LogoSpot.place(speaker: place, face: face, scale: k, frame: canvas, clear: clear, size: size, compact: compact)
        }
        guard let screen else { return corner.kept(inside: clear, size: size) }
        let geometry = LayoutGeometry(track: screen, crop: crop)
        let state = screen.state(at: time, geometry: geometry, endScreen: endScreen)
        let unit = Double(canvas.width / geometry.frame.width)
        func design(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * unit, y: rect.minY * unit, width: rect.width * unit, height: rect.height * unit)
        }
        let face = geometry.facePoint(in: state)
        return LogoSpot.place(speaker: design(state.speaker.rect), face: screen.bubble.face == nil ? nil : CGPoint(x: Double(face.x) * unit, y: Double(face.y) * unit),
                              scale: unit * Double(state.speaker.rect.height / state.window.height), frame: canvas, clear: clear,
                              size: size, column: column, compact: compact)
    }
}

// MARK: - The owner's logos

/// The owner's brand logos, kept for every project in the app's own folder, with
/// logos.json naming each one and the words that say it. Agents add one with `setLogo`
/// (a copy of the owner's file), never by writing into the folder.
enum LogoLibrary {
    struct Logo: Codable, Equatable {
        /// The brand's name, as the badge's label shows it: "Next.js", "Apple Watch".
        var name: String
        /// What the speaker says for it, matched without case: ["next.js", "next js"].
        var words: [String]
        /// The image's file name in the folder.
        var file: String
    }

    static let maximumWords = 8

    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_LOGOS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Logos", isDirectory: true)
    }
    static var index: URL { folder.appendingPathComponent("logos.json") }

    static func path(of logo: Logo) -> String { folder.appendingPathComponent(logo.file).path }

    /// Every logo whose image is there, by name.
    static func load() -> [Logo] {
        guard let data = try? Data(contentsOf: index),
              let logos = try? JSONDecoder().decode([Logo].self, from: data) else { return [] }
        return logos.filter { FileManager.default.fileExists(atPath: path(of: $0)) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Adds a logo, or replaces the one of the same name (without case): a copy of `image`,
    /// said as `words` (default: the name).
    @discardableResult
    static func set(name rawName: String, image: URL, words: [String]?) throws -> Logo {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), !name.contains("\n") else { throw EditError.invalid("A logo's name is one line of 1 to 40 characters.") }
        let ext = image.pathExtension.lowercased()
        guard LogoBadge.imageTypes.contains(ext) else { throw EditError.invalid("A logo must be a PNG, JPEG, SVG, WebP or HEIC file.") }
        guard let bytes = try? Data(contentsOf: image), !bytes.isEmpty else { throw EditError.invalid("The logo file \(image.path) cannot be read.") }
        let said = (words ?? [name]).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !said.isEmpty, said.count <= maximumWords, said.allSatisfy({ $0.count <= 40 }) else {
            throw EditError.invalid("A logo needs 1 to \(maximumWords) words that say it, each 40 characters or fewer.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var logos = (try? JSONDecoder().decode([Logo].self, from: Data(contentsOf: index))) ?? []
        if let old = logos.first(where: { $0.name.lowercased() == name.lowercased() }) {
            try? manager.removeItem(at: folder.appendingPathComponent(old.file))
            logos.removeAll { $0.name.lowercased() == name.lowercased() }
        }
        let stem = name.map { "/:\\".contains($0) ? "-" : $0 }.reduce("") { $0 + String($1) }
        let logo = Logo(name: name, words: said, file: "\(stem).\(ext)")
        try bytes.write(to: folder.appendingPathComponent(logo.file), options: .atomic)
        logos.append(logo)
        try write(logos)
        return logo
    }

    static func remove(name: String) throws {
        var logos = (try? JSONDecoder().decode([Logo].self, from: Data(contentsOf: index))) ?? []
        guard let old = logos.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw EditError.notFound("There is no logo named \(name).")
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file))
        logos.removeAll { $0.name.lowercased() == name.lowercased() }
        try write(logos)
    }

    private static func write(_ logos: [Logo]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(logos.sorted { $0.name.lowercased() < $1.name.lowercased() }).write(to: index, options: .atomic)
    }
}

// MARK: - Finding brands in what is said

/// A name said in the recording that looks like a brand or a company.
struct BrandMention: Equatable, Encodable {
    enum Source: String, Encodable {
        /// A logo of the owner's library.
        case library
        /// A brand of the app's list, which has no logo yet.
        case known
        /// A word shaped like a name (YamDrive, Next.js, a capital in a sentence). Check it.
        case guess
    }
    var name: String
    /// The words as the transcript has them.
    var text: String
    /// Source seconds of the first word.
    var start: Double
    /// Where it plays now, in edited seconds; nil when cut.
    var time: Double?
    var source: Source
    /// The logo's image, when the library has one.
    var logo: String?
}

enum BrandFinder {
    /// Brands people often say in videos about apps and design. Each is matched without
    /// case, except those marked `capital`, which are also common words.
    static let known: [(name: String, words: [String], capital: Bool)] = [
        ("Figma", ["figma"], false), ("FigJam", ["figjam"], false), ("HTML", ["html"], false), ("CSS", ["css"], false),
        ("JavaScript", ["javascript"], false), ("TypeScript", ["typescript"], false), ("Next.js", ["next.js", "nextjs"], false),
        ("React", ["react"], true), ("React Native", ["react native"], false), ("Tailwind", ["tailwind"], false),
        ("Vercel", ["vercel"], false), ("GitHub", ["github"], false), ("YouTube", ["youtube"], false),
        ("ChatGPT", ["chatgpt", "chat gpt"], false), ("OpenAI", ["openai", "open ai"], false), ("Codex", ["codex"], false),
        ("Claude", ["claude", "claude code"], false), ("Anthropic", ["anthropic"], false), ("Gemini", ["gemini"], true),
        ("Cursor", ["cursor"], true), ("Supabase", ["supabase"], false), ("Firebase", ["firebase"], false),
        ("Xcode", ["xcode"], false), ("SwiftUI", ["swiftui"], false), ("Swift", ["swift"], true),
        ("Apple", ["apple"], true), ("Apple Watch", ["apple watch"], false), ("iPhone", ["iphone"], false),
        ("iPad", ["ipad"], false), ("Mac", ["mac"], true), ("MacBook", ["macbook"], false), ("App Store", ["app store"], false),
        ("Google", ["google"], false), ("Play Store", ["play store"], false), ("Android", ["android"], false),
        ("Granola", ["granola"], true), ("Notion", ["notion"], true), ("Linear", ["linear"], true), ("Slack", ["slack"], true),
        ("Framer", ["framer"], true), ("Webflow", ["webflow"], false), ("Expo", ["expo"], true), ("Canva", ["canva"], false),
        ("Miro", ["miro"], false), ("Loom", ["loom"], true), ("Stripe", ["stripe"], true), ("Shopify", ["shopify"], false),
        ("Instagram", ["instagram"], false), ("WhatsApp", ["whatsapp"], false), ("LinkedIn", ["linkedin"], false),
        ("Discord", ["discord"], true), ("Spotify", ["spotify"], false), ("Agentation", ["agentation"], false),
        ("DJI", ["dji"], false), ("Osmo", ["osmo"], true), ("Mobbin", ["mobbin"], false),
    ]

    /// Capitalised words that are not names.
    static let notNames: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "ok", "okay", "yeah", "hey", "hi", "so", "and", "but", "now", "next", "then",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "english", "god",
        "ui", "ux", "ai", "api", "url", "pdf", "json", "ascii", "sdk", "cta", "faq", "usb", "gps", "tv", "pc", "md",
    ]

    /// A word as it is matched: no case, no punctuation round it, no "'s".
    static func normal(_ text: String) -> String {
        var word = text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if word.hasSuffix("'s") || word.hasSuffix("’s") { word = String(word.dropLast(2)) }
        return word
    }

    /// Every brand name said in `words`, in order: the library's logos first, then the
    /// app's list, then words shaped like names.
    static func mentions(in words: [TranscriptWord], timeline: ClipTimeline, library: [LogoLibrary.Logo]) -> [BrandMention] {
        let normals = words.map { normal($0.text) }
        struct Phrase { var name: String; var tokens: [String]; var capital: Bool; var source: BrandMention.Source; var logo: String? }
        var phrases: [Phrase] = []
        for logo in library {
            for said in logo.words {
                phrases.append(Phrase(name: logo.name, tokens: said.split(separator: " ").map { normal(String($0)) }, capital: false,
                                      source: .library, logo: LogoLibrary.path(of: logo)))
            }
        }
        let named = Set(library.map { $0.name.lowercased() })
        for brand in known where !named.contains(brand.name.lowercased()) {
            for said in brand.words {
                phrases.append(Phrase(name: brand.name, tokens: said.split(separator: " ").map { normal(String($0)) }, capital: brand.capital,
                                      source: .known, logo: nil))
            }
        }
        // Longest first, so "apple watch" wins over "apple".
        phrases.sort { $0.tokens.count > $1.tokens.count }

        var found: [BrandMention] = []
        var index = 0
        while index < words.count {
            let first = words[index]
            var matched: (Phrase, Int)?
            for phrase in phrases where !phrase.tokens.isEmpty && index + phrase.tokens.count <= words.count {
                guard Array(normals[index..<index + phrase.tokens.count]) == phrase.tokens else { continue }
                if phrase.capital, !(first.text.trimmingCharacters(in: CharacterSet.letters.inverted).first?.isUppercase ?? false) { continue }
                matched = (phrase, phrase.tokens.count)
                break
            }
            if let (phrase, count) = matched {
                let text = words[index..<index + count].map(\.text).joined(separator: " ")
                found.append(BrandMention(name: phrase.name, text: text, start: first.start, time: timeline.time(forSource: first.start),
                                          source: phrase.source, logo: phrase.logo))
                index += count
                continue
            }
            if let guess = guessedName(at: index, in: words) {
                found.append(BrandMention(name: guess, text: first.text, start: first.start, time: timeline.time(forSource: first.start),
                                          source: .guess, logo: nil))
            }
            index += 1
        }
        return found
    }

    /// The word at `index` as a name, when it is shaped like one: a capital inside it
    /// (YamDrive, iPhone), a dotted name (Next.js, hirahul.xyz), a capitalised word inside
    /// a sentence (Rahnotate), or capitals only (ASCII), but not a common word.
    static func guessedName(at index: Int, in words: [TranscriptWord]) -> String? {
        let raw = words[index].text
        let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: ".")))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard word.count >= 3, word.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." }),
              !notNames.contains(word.lowercased()) else { return nil }
        let letters = Array(word)
        let innerCapital = letters.dropFirst().contains { $0.isUppercase } && letters.contains { $0.isLowercase }
        if innerCapital { return word }
        if let dot = word.firstIndex(of: "."), word[word.index(after: dot)...].count >= 2, word[..<dot].count >= 2 { return word }
        if letters.allSatisfy({ $0.isUppercase || $0.isNumber }), letters.contains(where: \.isLetter) { return word }
        guard letters.first?.isUppercase == true, letters.dropFirst().allSatisfy({ $0.isLowercase }) else { return nil }
        // A capital at the start of a sentence says nothing.
        guard index > 0 else { return nil }
        let before = words[index - 1].text.trimmingCharacters(in: .whitespaces)
        guard let last = before.last, !".?!".contains(last) else { return nil }
        return word
    }

    /// A suggested badge, the mentions it shows, and why other mentions have none.
    struct Plan: Equatable {
        var badges: [Graphic]
        var shown: [[BrandMention]]
        var skipped: [(mention: BrandMention, reason: String)]

        static func == (a: Plan, b: Plan) -> Bool {
            a.badges == b.badges && a.shown == b.shown && a.skipped.map(\.mention) == b.skipped.map(\.mention)
                && a.skipped.map(\.reason) == b.skipped.map(\.reason)
        }
    }

    /// How early a badge starts before its first name is said.
    static let lead = 0.15
    /// How long the last logo of a badge stays after its name.
    static let hold = 1.8
    /// Names said closer than this share a badge.
    static let together = 1.2
    static let shortest = 1.0

    /// Badges for the mentions that have a logo, timed on the words: each starts just
    /// before its name and holds 1.8 s after the last; names said within 1.2 s of each
    /// other share one (up to three logos). A logo said again within `gap` seconds of its
    /// last badge gets none. A badge ends before the next one, before a layout change
    /// when that leaves it a second, and before `stop` (the end screen or the end); it is
    /// left out where another badge shows already (`taken`).
    static func plan(_ mentions: [BrandMention], gap: Double, stop: Double, changes: [Double], taken: [(Double, Double)]) -> Plan {
        var shown: [[BrandMention]] = []
        var skipped: [(mention: BrandMention, reason: String)] = []
        var lastShown: [String: Double] = [:]
        for mention in mentions.sorted(by: { ($0.time ?? -1) < ($1.time ?? -1) }) {
            guard let time = mention.time else { skipped.append((mention, "cut from the edit")); continue }
            guard mention.logo != nil else { skipped.append((mention, "no logo yet")); continue }
            if let last = lastShown[mention.name], time - last < gap {
                skipped.append((mention, String(format: "said %.0f s after its last badge", time - last)))
                continue
            }
            if var group = shown.last, let previous = group.last?.time, time - previous <= together,
               group.count < LogoBadge.maximumLogos, !group.contains(where: { $0.name == mention.name }) {
                group.append(mention)
                shown[shown.count - 1] = group
            } else {
                shown.append([mention])
            }
            lastShown[mention.name] = time
        }
        var badges: [Graphic] = []
        var kept: [[BrandMention]] = []
        for (index, group) in shown.enumerated() {
            let first = group[0].time!, last = group[group.count - 1].time!
            let start = max(0, first - lead)
            var end = min(last + hold, stop)
            if index + 1 < shown.count { end = min(end, max(0, shown[index + 1][0].time! - lead)) }
            if let change = changes.first(where: { $0 > start + 0.000001 && $0 < end }), change - start >= shortest { end = change }
            let clash = taken.contains { $0.0 < end - 0.001 && start < $0.1 - 0.001 }
            guard end - start >= shortest - 0.000001, !clash else {
                let reason = clash ? "a logo badge shows there already" : "no room before the next badge or the end"
                skipped += group.map { ($0, reason) }
                continue
            }
            let logos: [JSONValue] = group.map { mention in
                .object(["image": .string(mention.logo!), "label": .string(mention.name),
                         "at": .number(((mention.time! - start) * 1000).rounded() / 1000)])
            }
            let id = UUID(deterministicFrom: Data("logo \(group.map(\.name).joined(separator: "+")) \(first)".utf8))
            badges.append(Graphic(id: id, kind: .logoBadge, start: (start * 1000).rounded() / 1000, end: (end * 1000).rounded() / 1000,
                                  props: ["logos": .array(logos)]))
            kept.append(group)
        }
        return Plan(badges: badges, shown: kept, skipped: skipped)
    }
}

extension VideoItem {
    /// The brands said in the kept recording and badges for those with a logo, by
    /// `BrandFinder.plan`. Nil without a transcript.
    func brandPlan(library: [LogoLibrary.Logo] = LogoLibrary.load(), gap: Double = 60) -> (mentions: [BrandMention], plan: BrandFinder.Plan)? {
        guard let transcript else { return nil }
        let mentions = BrandFinder.mentions(in: transcript.words, timeline: timeline, library: library)
        let stop = graphics?.endScreen?.start ?? editedDuration
        let changes = screen?.changes(endScreen: graphics?.endScreen?.start).map(\.time) ?? []
        let taken = (graphics?.items ?? []).filter { $0.kind == .logoBadge }.map { ($0.start, $0.end) }
        return (mentions, BrandFinder.plan(mentions, gap: gap, stop: stop, changes: changes, taken: taken))
    }
}
