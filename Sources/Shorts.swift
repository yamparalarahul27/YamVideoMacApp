import CoreGraphics
import Foundation

// Shorts (graphics track, section 16 of docs/plans/graphics-track.md): a vertical 1080×1920
// version of part of a recording, made from the same edit, graphics and captions. The
// picture is a 9:16 window of the recording; the graphics engine lays the same template
// kinds out on a 9:16 canvas; captions sit in the safe area, sized for a phone. A Short
// has its own upload details. Shorts have no end screen, so the end screen is left out.

/// How panel graphics (panel title, rule, checklist) lay out in a Short. The owner picks
/// one per Short.
enum ShortPanels: String, Codable, CaseIterable, Identifiable {
    /// A frosted shade rises over the lower half; the picture lifts by an eighth.
    case sheet
    /// The whole picture frosts and dims; the panel draws large in the middle.
    case shade
    /// The picture shrinks into a frame in the top half, the panel below it.
    case split

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sheet: return "Bottom sheet"
        case .shade: return "Full shade"
        case .split: return "Split"
        }
    }
    var detail: String {
        switch self {
        case .sheet: return "A frosted shade rises over the lower half; with Move video aside on, the picture lifts by an eighth."
        case .shade: return "The whole picture frosts and dims; the panel draws large in the middle."
        case .split: return "The picture shrinks into a frame in the top half, with the panel below it."
        }
    }
}

/// Whether a Short of a recording with a screen recording shows the screen.
enum ShortScreen: String, Codable, CaseIterable, Identifiable {
    /// Only the speaker, in the Short's 9:16 window.
    case off
    /// The screen across the top and the speaker below, where the recording's layout shows
    /// the screen; the speaker alone where it shows only the speaker.
    case top

    var id: String { rawValue }
    var label: String { self == .off ? "Off" : "On top" }
}

/// What burned-in captions do while a card or panel covers the lower half of a Short.
enum ShortCaptions: String, Codable, CaseIterable, Identifiable {
    case stepUp, over, hide

    var id: String { rawValue }
    var label: String {
        switch self {
        case .stepUp: return "Step up"
        case .over: return "Stay over"
        case .hide: return "Hide"
        }
    }
    var detail: String {
        switch self {
        case .stepUp: return "Captions move up to sit just above the graphic while it shows."
        case .over: return "Captions keep their place and draw over the graphic."
        case .hide: return "Burned-in captions pause under graphics; the uploaded caption file keeps every word."
        }
    }
}

/// One Short of a recording: a stretch of the edited recording, the 9:16 part of the
/// picture it shows, how its graphics and captions lay out, and its upload details.
struct Short: Codable, Equatable, Identifiable {
    var id: UUID
    /// Edited-recording seconds.
    var start: Double
    var end: Double
    /// The 9:16 part of the picture, in source pixels like the crop; nil is the full
    /// height of the crop, centred.
    var window: CGRect?
    var title = ""
    var description = ""
    var tags: [String] = []
    /// Graphics left out of this Short.
    var hidden: [UUID] = []
    /// Graphics moved or resized on the Short's 1080×1920 canvas, by graphic.
    var placements: [UUID: GraphicTransform] = [:]
    /// Seconds into the Short of the frame used as its cover; nil until chosen.
    var cover: Double?
    var panels = ShortPanels.sheet
    var captions = ShortCaptions.stepUp
    /// How far the picture is zoomed out: nil (or 1) fills the frame; lower shows more of
    /// the picture around the window, at the top, with its bottom edge fading into a
    /// blurred copy below, down to `ShortFormat.zooms.lowerBound`, a square.
    var zoom: Double?
    /// For a recording with a screen recording: whether the Short shows the screen.
    var screen = ShortScreen.off

    init(id: UUID = UUID(), start: Double, end: Double, window: CGRect? = nil) {
        self.id = id; self.start = start; self.end = end; self.window = window
    }

    var length: Double { end - start }
    var zoomLevel: Double { zoom ?? 1 }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, window, title, description, tags, hidden, placements, cover, panels, captions, zoom, screen
    }

    /// Missing keys keep their defaults, so a partial object is complete.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        window = try c.decodeIfPresent(CGRect.self, forKey: .window)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        hidden = try c.decodeIfPresent([UUID].self, forKey: .hidden) ?? []
        let places = try c.decodeIfPresent([String: GraphicTransform].self, forKey: .placements) ?? [:]
        placements = [:]
        for (key, value) in places {
            guard let graphic = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(forKey: .placements, in: c, debugDescription: "Placements are keyed by graphic id.")
            }
            placements[graphic] = value
        }
        cover = try c.decodeIfPresent(Double.self, forKey: .cover)
        panels = try c.decodeIfPresent(ShortPanels.self, forKey: .panels) ?? .sheet
        captions = try c.decodeIfPresent(ShortCaptions.self, forKey: .captions) ?? .stepUp
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom)
        screen = try c.decodeIfPresent(ShortScreen.self, forKey: .screen) ?? .off
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(tags, forKey: .tags)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(Dictionary(uniqueKeysWithValues: placements.map { ($0.key.uuidString, $0.value) }), forKey: .placements)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encode(panels, forKey: .panels)
        try c.encode(captions, forKey: .captions)
        try c.encodeIfPresent(zoom, forKey: .zoom)
        if screen != .off { try c.encode(screen, forKey: .screen) }
    }

    /// The window the Short shows: its own, or the full height of `crop`, centred.
    func frame(info: MediaInfo, crop: CGRect?) -> CGRect {
        window ?? ShortFormat.defaultWindow(in: (crop ?? info.fullFrame).evenClamped(in: info.fullFrame), info: info)
    }

    /// The part of the picture the Short reads: its window, or when zoomed out the window
    /// widened about its centre (as far as the crop allows), in even source pixels. The
    /// picture is drawn at the top of a taller 9:16 stage (`ShortFormat.stage(for:)`).
    func picture(info: MediaInfo, crop: CGRect?) -> CGRect {
        let window = frame(info: info, crop: crop)
        guard zoomLevel < 1 else { return window }
        let area = (crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let width = min(area.width, max(window.width, (window.width / zoomLevel / 2).rounded() * 2))
        let x = min(max(area.minX, window.midX - width / 2), area.maxX - width)
        return CGRect(x: (x / 2).rounded(.down) * 2, y: window.minY, width: width, height: window.height).intersection(info.fullFrame)
    }

    /// What the timeline and lists call it.
    func name(index: Int) -> String {
        let text = title.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Short \(index + 1)" : text
    }

    /// The first thing wrong with this Short on a recording of `duration` edited seconds, or nil.
    func problem(duration: Double, info: MediaInfo) -> String? {
        guard start.isFinite, end.isFinite else { return "A Short's start and end must be finite numbers." }
        guard start >= 0, end <= duration + 0.0005 else {
            return String(format: "A Short must lie within the edited recording (0–%.2f s).", duration)
        }
        guard length >= ShortFormat.lengths.lowerBound - 0.000001 else {
            return String(format: "A Short lasts at least %.0f s.", ShortFormat.lengths.lowerBound)
        }
        guard length <= ShortFormat.lengths.upperBound + 0.0005 else {
            return "YouTube takes Shorts of up to 3:00 (180 s); this one is \(PublishInfo.timestamp(length)) (\(String(format: "%.1f", length)) s)."
        }
        if let window {
            guard window.minX.isFinite, window.minY.isFinite, window.width.isFinite, window.height.isFinite,
                  window.width >= 16, window.height >= 16, info.fullFrame.contains(window) else {
                return "The Short's window must lie inside the \(info.width)×\(info.height) picture."
            }
            guard abs(window.width / window.height - ShortFormat.aspect) <= 0.01 else {
                return String(format: "The Short's window is 9:16 (its width is its height × 9 ÷ 16); this one is %.0f×%.0f.", window.width, window.height)
            }
        }
        if let zoom {
            guard zoom.isFinite, ShortFormat.zooms.contains(zoom) else {
                return "A Short's zoom is from \(ShortFormat.zooms.lowerBound.formatted()) (zoomed out to a square at the top) to 1 (fills the frame)."
            }
            if screen == .top, zoom < 1 - 0.000001 {
                return "A Short with the screen on top fills its canvas, so it does not zoom out: set zoom to 1."
            }
        }
        guard title.count <= 1000, description.count <= 20_000, tags.count <= 200 else {
            return "That Short's text is far longer than YouTube allows."
        }
        guard !title.contains(where: \.isNewline) else { return "A Short's title is one line." }
        for tag in tags where tag.isEmpty || tag.contains(where: { $0.isNewline || $0 == "," }) {
            return "A tag is a single phrase without commas or line breaks."
        }
        for transform in placements.values {
            if let problem = ShortFormat.placementProblem(transform) { return problem }
        }
        if let cover {
            guard cover.isFinite, cover >= 0, cover <= length + 0.0005 else {
                return String(format: "The cover is a time within the Short (0–%.2f s).", length)
            }
        }
        return nil
    }

    // MARK: Upload details

    /// What YouTube would refuse or ignore. Blocking issues stop Export for YouTube.
    func issues(graphics: GraphicsTrack?, publish: PublishInfo?) -> [PublishInfo.Issue] {
        var issues: [PublishInfo.Issue] = []
        func add(_ field: String, _ severity: PublishInfo.Severity, _ message: String) {
            issues.append(PublishInfo.Issue(field: field, severity: severity, message: message))
        }
        var details = PublishInfo()
        details.title = title; details.description = description; details.tags = tags
        for issue in details.issues(duration: length) where !["thumbnail", "chapters", "endScreen"].contains(issue.field) {
            issues.append(issue)
        }
        if length > ShortFormat.lengths.upperBound + 0.0005 {
            add("length", .blocking, "YouTube takes Shorts of up to 3:00; this one is \(PublishInfo.timestamp(length)).")
        }
        if cover == nil { add("cover", .warning, "No cover frame chosen: YouTube suggests frames, or use one you pick here.") }
        if graphics?.endScreen.map({ $0.end > start && $0.start < end }) == true {
            add("endScreen", .warning, "Shorts have no end screen, so the end screen is left out of this Short; the picture plays as recorded there.")
        }
        add("relatedVideo", .warning, "Link the Short to its long video in YouTube Studio (Related video); the upload API cannot set it.")
        return issues
    }

    /// The upload details as `PublishInfo`, for the shared text and file writers: the
    /// recording's category and language, the Short's own title, description and tags.
    func publishInfo(recording: PublishInfo?) -> PublishInfo {
        var info = PublishInfo()
        info.title = title; info.description = description; info.tags = tags
        info.category = recording?.category ?? info.category
        info.language = recording?.language ?? info.language
        info.channel = recording?.channel ?? ""
        return info
    }
}

/// YouTube's Shorts format and the numbers the layout uses. graphics.js (`shortLayout`) has
/// the same numbers, which `./test.sh` checks.
enum ShortFormat {
    /// The canvas: design pixels of the Short, and the exported size.
    static let size = CGSize(width: 1080, height: 1920)
    /// How far a Short can zoom out: from filling the frame to a square at the top.
    static let zooms = 0.5625...1.0
    /// A zoomed-out picture's bottom edge fades into the blurred fill over this many design
    /// pixels.
    static let zoomFade = 240.0
    static let aspect = 9.0 / 16.0
    /// YouTube treats a vertical video of up to 3 minutes as a Short.
    static let lengths = 1.0...180.0
    static let defaultLength = 60.0
    static let maximumCount = 20
    /// Where YouTube's Shorts player draws over a Short on a phone: its icons along the top,
    /// the like, comment and share rail down the lower right (from `railTop`), and the
    /// channel, title and sound along the bottom fifth. YouTube publishes no numbers for
    /// Shorts; these follow measurements of the app. Google's guide for vertical ads, which
    /// also play outside Shorts, is stricter (the top 288 px and the bottom 672 px). Text
    /// and faces belong in the clear area between.
    static let furniture = (top: 240.0, bottom: 400.0, left: 48.0, right: 192.0)
    /// Where the like, comment and share rail starts down the right edge.
    static let railTop = 960.0
    static let clearArea = CGRect(x: 48, y: 240, width: 840, height: 1280)
    static let relatedVideoStep = "YouTube Studio → Content → Shorts → this Short → Related video"
    static let relatedVideoNote = "Shorts have no end screen. To send viewers to the long video, open " + relatedVideoStep
        + " and choose it; the upload API cannot set that link."

    /// A graphic may move at most a whole Short frame either way.
    static func placementProblem(_ transform: GraphicTransform) -> String? {
        guard transform.x.isFinite, transform.y.isFinite, transform.scale.isFinite else {
            return "A graphic's position and size must be finite numbers."
        }
        guard GraphicTransform.scales.contains(transform.scale) else {
            return "A graphic's scale must be from \(GraphicTransform.scales.lowerBound.formatted()) to \(GraphicTransform.scales.upperBound.formatted())."
        }
        guard abs(transform.x) <= size.width, abs(transform.y) <= size.height else {
            return "In a Short a graphic can move at most \(Int(size.width)) px across and \(Int(size.height)) px down or up."
        }
        return nil
    }

    /// The 9:16 stage a Short's picture of `size` is drawn on when it is wider than 9:16
    /// (zoomed out): as wide as the picture, with the picture at its top. Nil for a 9:16
    /// picture, which is its own stage.
    static func stage(for size: CGSize) -> CGSize? {
        guard size.height > 0, size.width / size.height > aspect * 1.02 else { return nil }
        return CGSize(width: size.width, height: (size.width / aspect / 2).rounded() * 2)
    }

    /// The largest 9:16 window in `frame`, centred, in even pixels.
    static func defaultWindow(in frame: CGRect, info: MediaInfo) -> CGRect {
        window(centre: CGPoint(x: frame.midX, y: frame.midY), height: frame.height, in: frame, info: info)
    }

    /// A 9:16 window of `height` source pixels centred as near `centre` as fits in `frame`.
    static func window(centre: CGPoint, height: Double, in frame: CGRect, info: MediaInfo) -> CGRect {
        var h = min(height, frame.height)
        var w = h * aspect
        if w > frame.width { w = frame.width; h = w / aspect }
        func even(_ value: Double) -> Double { max(16, (value / 2).rounded() * 2) }
        w = min(even(w), frame.width); h = min(even(h), frame.height)
        let x = min(max(frame.minX, centre.x - w / 2), frame.maxX - w)
        let y = min(max(frame.minY, centre.y - h / 2), frame.maxY - h)
        return CGRect(x: (x / 2).rounded(.down) * 2, y: (y / 2).rounded(.down) * 2, width: w, height: h)
            .intersection(info.fullFrame)
    }
}

/// Where graphics go on the 1080×1920 canvas. Each zone is where the template's own zone
/// (the 640×900 column, the 960×1080 panel) has its top-left corner, and its size.
struct ShortLayout: Equatable {
    struct Zone: Equatable {
        var origin: CGPoint
        var scale: Double
    }

    var panels: ShortPanels
    /// The Short's zoom: zoomed out, the face sits higher and smaller, so the cards, the
    /// bottom sheet and the captions sit lower by `drop`.
    var zoom = 1.0

    init(panels: ShortPanels, zoom: Double = 1) { self.panels = panels; self.zoom = zoom }

    /// How much lower the cards, the bottom sheet and the captions sit, zoomed out: none
    /// filling the frame, 175 design pixels for a square.
    var drop: Double { ((1 - min(1, max(ShortFormat.zooms.lowerBound, zoom))) * 400).rounded() }

    /// Cards sit in the lower middle, below the face, inside YouTube's clear area.
    static let column = Zone(origin: CGPoint(x: 72, y: 760), scale: 1.2)
    /// The bottom sheet's soft edge starts here and fades in over the style's edge.
    static let sheetTop = 700.0
    /// How far the picture lifts while a bottom sheet shows, with Move video aside on.
    static let lift = 240.0
    /// Where the picture goes in the split layout: 9:16, centred in the top half.
    static let splitFrame = CGRect(x: 333, y: 112, width: 414, height: 736)
    /// The safe-area spot: libass's MarginV 90 of 288, 600 px above the bottom.
    static let captionBottom = 1320.0

    /// The column zone, `drop` lower when zoomed out.
    var cardZone: Zone { Zone(origin: CGPoint(x: Self.column.origin.x, y: Self.column.origin.y + drop), scale: Self.column.scale) }
    /// Where the bottom sheet's soft edge starts.
    var sheetLine: Double { Self.sheetTop + drop }
    /// Where captions sit when nothing covers them.
    var captionSpot: Double { Self.captionBottom + drop }

    var panel: Zone {
        switch panels {
        case .sheet: return Zone(origin: CGPoint(x: 29, y: 717 + drop), scale: 0.9)
        case .shade: return Zone(origin: CGPoint(x: 0, y: 312), scale: 0.96)
        case .split: return Zone(origin: CGPoint(x: 53, y: 802), scale: 0.85)
        }
    }

    /// Where captions step up to (their bottom) while a graphic in `zone` shows, or nil
    /// where they are clear of it already. Zoomed out, a card sits under the face and the
    /// captions stay below it, since above it would be the face.
    func captionLine(for zone: GraphicZone) -> Double? {
        switch zone {
        case .column: return zoom < 1 ? nil : cardZone.origin.y - 24
        case .panel:
            switch panels {
            case .sheet: return sheetLine - 24
            case .shade: return nil
            case .split: return Self.splitFrame.maxY - 16
            }
        // A logo badge sits next to the face, clear of the captions.
        case .screen, .speaker: return nil
        }
    }

    /// The zone a kind draws in.
    func zone(of kind: GraphicKind) -> Zone {
        kind.zone == .panel ? panel : cardZone
    }
}

// MARK: - A Short's part of the edit

extension ClipTimeline {
    /// The sections that play from `start` to `end` (edited seconds), cut to fit: the edit
    /// of one Short. Each piece keeps its section's id and speed.
    func cut(from start: Double, to end: Double) -> ClipTimeline {
        var pieces: [TimelineSegment] = []
        var offset = 0.0
        for segment in segments {
            let from = max(start, offset), to = min(end, offset + segment.duration)
            if to - from > 0.000001 {
                pieces.append(TimelineSegment(id: segment.id, start: segment.start + (from - offset) * segment.speed,
                                              end: segment.start + (to - offset) * segment.speed, speed: segment.speed))
            }
            offset += segment.duration
        }
        return ClipTimeline(segments: pieces)
    }

    /// Where the footage that played from `start` to `end` on `old` plays now: from the
    /// first surviving frame of it to the last. Nil when none of it survives.
    func carrySpan(_ start: Double, _ end: Double, from old: ClipTimeline) -> (start: Double, end: Double)? {
        let sources = old.cut(from: start, to: end).segments.map { ($0.start, $0.end) }
        var low = Double.infinity, high = -Double.infinity
        var offset = 0.0
        for segment in segments {
            for (from, to) in sources {
                let a = max(from, segment.start), b = min(to, segment.end)
                if b - a > 0.000001 {
                    low = min(low, offset + (a - segment.start) / segment.speed)
                    high = max(high, offset + (b - segment.start) / segment.speed)
                }
            }
            offset += segment.duration
        }
        return low < high ? (low, high) : nil
    }

    /// Shorts keep covering the same footage through cuts: a pause cut inside one makes it
    /// shorter. One whose footage is all gone, or that is left under a second, is dropped;
    /// so is one that now runs into an earlier one.
    func remap(_ shorts: [Short], from old: ClipTimeline, fps: Double) -> (shorts: [Short], removed: [UUID]) {
        var kept: [Short] = []
        var removed: [UUID] = []
        for var short in shorts.sorted(by: { $0.start < $1.start }) {
            guard let span = carrySpan(short.start, short.end, from: old) else { removed.append(short.id); continue }
            short.start = snapToFrame(span.start, fps: fps)
            short.end = min(snapToFrame(span.end, fps: fps), short.start + ShortFormat.lengths.upperBound, duration)
            if let cover = short.cover { short.cover = min(cover, short.length) }
            guard short.length >= ShortFormat.lengths.lowerBound - 0.000001,
                  !kept.contains(where: { $0.start < short.end - 0.000001 && short.start < $0.end - 0.000001 }) else {
                removed.append(short.id); continue
            }
            kept.append(short)
        }
        return (kept, removed)
    }
}

/// The first thing wrong with a recording's Shorts, or nil.
func shortsProblem(_ shorts: [Short], duration: Double, info: MediaInfo) -> String? {
    guard shorts.count <= ShortFormat.maximumCount else { return "A recording can have at most \(ShortFormat.maximumCount) Shorts." }
    guard Set(shorts.map(\.id)).count == shorts.count else { return "Two Shorts share one ID." }
    if let problem = shorts.lazy.compactMap({ $0.problem(duration: duration, info: info) }).first { return problem }
    let ordered = shorts.sorted { $0.start < $1.start }
    for (a, b) in zip(ordered, ordered.dropFirst()) where b.start < a.end - 0.000001 {
        return "Shorts of one recording may not overlap: one runs \(PublishInfo.timestamp(a.start))–\(PublishInfo.timestamp(a.end)), the next starts at \(PublishInfo.timestamp(b.start))."
    }
    return nil
}

extension GraphicsTrack {
    /// The graphics a Short shows: those that start inside it, except the end screen and
    /// any hidden in it, ending where the Short ends at the latest, with the Short's own
    /// placements, on the 9:16 canvas. Times are the Short's own from 0, or with
    /// `recordingTime` the recording's (for the app's Preview, which plays the recording).
    func forShort(_ short: Short, recordingTime: Bool = false) -> GraphicsTrack {
        let shift = recordingTime ? 0 : short.start
        var track = GraphicsTrack(style: style, items: [])
        track.canvas = .short(short.panels, zoom: short.zoomLevel)
        for graphic in items.sorted(by: { $0.start < $1.start }) {
            guard graphic.kind != .endScreen, !short.hidden.contains(graphic.id),
                  graphic.start >= short.start - 0.0005, graphic.start < short.end - Self.minimumLength + 0.000001 else { continue }
            var copy = graphic
            copy.start = max(0, graphic.start - shift)
            copy.end = min(graphic.end, short.end) - shift
            copy.transform = short.placements[graphic.id].flatMap { $0.isIdentity ? nil : $0 }
            track.items.append(copy)
        }
        return track
    }
}

extension VideoItem {
    func short(_ id: UUID?) -> Short? { id.flatMap { id in shorts.first { $0.id == id } } }

    /// The Short as a recording of its own, for exports: its part of the edit, its window
    /// as the crop, the zooms, blur effects and graphics inside it in its own time, and
    /// no upload details (the Short has its own).
    func shortItem(_ short: Short) -> VideoItem {
        var item = self
        let timeline = self.timeline.cut(from: short.start, to: short.end)
        item.segments = timeline.segments
        if let info { item.crop = short.picture(info: info, crop: crop) }
        item.aspectLock = ShortFormat.aspect; item.aspectLabel = "9:16"
        item.zoomShots = zoomShots.filter { $0.start >= short.start - 0.0005 && $0.end <= short.end + 0.0005 }.map {
            var shot = $0; shot.start = max(0, shot.start - short.start); return shot
        }
        item.blurEffects = blurEffects.compactMap { effect in
            guard effect.end > short.start + 0.000001, effect.start < short.end - 0.000001 else { return nil }
            var moved = effect
            moved.start = max(effect.start, short.start) - short.start
            moved.end = min(effect.end, short.end) - short.start
            if moved.fadeIn + moved.fadeOut > moved.duration {
                let scale = moved.duration / max(0.000001, moved.fadeIn + moved.fadeOut)
                moved.fadeIn *= scale; moved.fadeOut *= scale
            }
            return moved
        }
        item.markers = markers.filter { $0.time >= short.start && $0.time <= short.end }.map {
            var marker = $0; marker.time -= short.start; return marker
        }
        let track = shortGraphics(short)
        item.graphics = track?.items.isEmpty == false ? track : nil
        item.screen = short.screen == .top ? screen.map { $0.forShort(short) } : nil
        item.publish = nil
        item.shorts = []
        return item
    }

    /// The Short's captions on its own timeline from 0, unsplit: its caption file moved
    /// through the edit, or its transcript in groups sized for a phone. Empty when captions
    /// are off or there are none.
    /// Whether the Short shows the screen: it asks to, and the recording has one.
    func stacksScreen(_ short: Short) -> Bool { short.screen == .top && screen != nil }

    /// The Short's issues: its own (`Short.issues`), and with the screen on top a warning
    /// for each layout in it that puts the speaker's face outside YouTube's clear area.
    func shortIssues(_ short: Short) -> [PublishInfo.Issue] {
        var issues = short.issues(graphics: graphics, publish: publish)
        guard stacksScreen(short), let screen, let info else { return issues }
        let crop = (self.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let geometry = LayoutGeometry(short: screen, crop: crop, window: short.frame(info: info, crop: self.crop))
        let track = screen.forShort(short)
        let shown = Set(stride(from: 0.0, to: max(0.001, short.length), by: 0.25).map { track.layout(at: $0, endScreen: nil) })
        // Room for a face round its middle: about 200×300 design pixels.
        let room = ShortFormat.clearArea.insetBy(dx: 100, dy: 150)
        for layout in ScreenLayout.allCases where shown.contains(layout) {
            let point = geometry.facePoint(in: geometry.held(layout))
            guard !room.contains(point) else { continue }
            let part = layout == .speaker ? "Where it shows only the speaker" : "Below the screen"
            issues.append(PublishInfo.Issue(field: "safeArea", severity: .warning, message:
                "\(part), the face lands at \(Int(point.x)), \(Int(point.y)), outside YouTube's clear area (48–888 across, 240–1520 down), "
                + "so the like rail or the title can cover it. Move the Short's window or the speaker's face (Screen section)."))
        }
        return issues
    }

    /// The Short's caption line, when its layout puts it somewhere other than the
    /// safe-area spot: with the screen on top, just above the speaker.
    func shortCaptionBottom(_ short: Short) -> Double? {
        guard stacksScreen(short), let screen, let info else { return nil }
        let crop = (self.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        return LayoutGeometry(short: screen, crop: crop, window: short.frame(info: info, crop: self.crop)).stackCaptionBottom
    }

    func shortCaptions(_ short: Short, settings: ExportSettings) -> [Caption] {
        guard settings.shortCaptionUse(hasFile: subtitles != nil).uploads else { return [] }
        let timeline = self.timeline.cut(from: short.start, to: short.end)
        if let subtitles {
            guard Captions.retimable.contains(subtitles.pathExtension.lowercased()),
                  let text = try? String(contentsOf: subtitles, encoding: .utf8),
                  let captions = try? Captions.parse(text) else { return [] }
            return Captions.edited(captions, timeline: timeline)
        }
        guard let transcript, settings.captions != nil || settings.shortCaptions != nil else { return [] }
        return Captions.edited(transcript.captions(timeline: timeline, characters: ShortCaptionLayout.groupCharacters), timeline: timeline)
    }
}

// MARK: - Captions in a Short

/// One caption as a Short shows it: its lines, and where its bottom sits on the 1080×1920
/// canvas. The app works these out once; the engine draws them in the Preview and libass
/// draws the same in the export, from an ASS file on the Short's own pixel grid.
struct ShortCaption: Equatable, Encodable {
    var start: Double
    var end: Double
    var lines: [String]
    var bottom: Double
}

enum ShortCaptionLayout {
    /// A transcript caption in a Short holds about this many characters, over two lines.
    static let groupCharacters = 40
    /// Pieces shorter than this are not worth showing.
    static let shortest = 0.05

    /// Caption size in pixels of the 1920-tall Short: about the size the same choice has
    /// on a 1080-tall landscape export, rather than the 133 px libass would make it.
    static func fontSize(_ size: SubtitleSize) -> Double {
        switch size {
        case .small: return 60
        case .medium: return 72
        case .large: return 90
        }
    }

    static func outline(_ size: SubtitleSize) -> Double { (fontSize(size) / 10).rounded() }

    /// libass sizes a font by its whole line (Helvetica Bold's Windows ascent and descent,
    /// 1.18 em, measured), where the engine's CSS sizes the em; and lines are that far apart.
    static let lineHeight = 1.18

    /// Captions sit centred in the clear area, left of YouTube's like and share rail.
    static let margins = (left: ShortFormat.clearArea.minX, right: ShortFormat.size.width - ShortFormat.clearArea.maxX)

    /// How many characters fit on one line of the clear area, with room each side.
    static func lineCharacters(_ size: SubtitleSize) -> Int {
        Int(((ShortFormat.clearArea.width - 40) / (fontSize(size) * 0.6)).rounded(.down))
    }

    /// Words in lines of at most `limit` characters (a longer word has a line to itself).
    static func wrap(_ text: String, limit: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            if line.isEmpty { line = word }
            else if line.count + 1 + word.count <= limit { line += " " + word }
            else { lines.append(line); line = word }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Captions in pieces of at most two lines, sharing each caption's time by characters.
    static func fit(_ captions: [Caption], size: SubtitleSize) -> [Caption] {
        let limit = lineCharacters(size)
        var result: [Caption] = []
        for caption in captions {
            let lines = wrap(caption.text, limit: limit)
            guard lines.count > 2 else { result.append(Caption(start: caption.start, end: caption.end, text: lines.joined(separator: "\n"))); continue }
            let pieces = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
            let total = Double(max(1, pieces.map { $0.joined().count }.reduce(0, +)))
            var at = caption.start
            for (index, piece) in pieces.enumerated() {
                let share = (caption.end - caption.start) * Double(piece.joined().count) / total
                let until = index == pieces.count - 1 ? caption.end : at + share
                result.append(Caption(start: at, end: until, text: piece.joined(separator: "\n")))
                at = until
            }
        }
        return result
    }

    /// Where each caption sits in a Short: at the safe-area spot, except while a card or
    /// panel covers the lower half, when the Short's option steps it up above the graphic,
    /// leaves it over it, or hides it. `graphics` are the Short's own (`forShort`).
    /// `bottom` is the caption line when the Short's layout has its own (the screen on top).
    static func layout(_ captions: [Caption], graphics: GraphicsTrack?, option: ShortCaptions, size: SubtitleSize,
                       bottom line: Double? = nil) -> [ShortCaption] {
        let layout: ShortLayout? = { if case .short(let panels, let zoom)? = graphics?.canvas { return ShortLayout(panels: panels, zoom: zoom) }; return nil }()
        // The times a graphic covers the lower half, and the line captions step up to then.
        var covers: [(start: Double, end: Double, line: Double?)] = []
        if let graphics, let layout {
            for graphic in graphics.items where graphic.kind.zone == .column {
                let line = layout.captionLine(for: .column).map { $0 + (graphic.transform?.y ?? 0) }
                covers.append((graphic.start, graphic.end, line))
            }
            for span in graphics.panelSpans() {
                covers.append((span.start, span.end + GraphicsTrack.slide, layout.captionLine(for: .panel)))
            }
        }
        var placed: [ShortCaption] = []
        for caption in fit(captions, size: size) {
            let lines = caption.text.components(separatedBy: "\n")
            // Cut at every edge of a cover inside the caption, then place each piece.
            var edges = [caption.start, caption.end]
            for cover in covers {
                for edge in [cover.start, cover.end] where edge > caption.start && edge < caption.end { edges.append(edge) }
            }
            edges = Array(Set(edges)).sorted()
            for (from, to) in zip(edges, edges.dropFirst()) where to - from >= shortest - 0.000001 {
                let middle = (from + to) / 2
                let over = covers.filter { middle >= $0.start && middle < $0.end }
                var bottom = line ?? layout?.captionSpot ?? ShortLayout.captionBottom
                if !over.isEmpty {
                    switch option {
                    case .hide: continue
                    case .over: break
                    case .stepUp: bottom = over.compactMap(\.line).min().map { min($0, bottom) } ?? bottom
                    }
                }
                if let last = placed.last, last.lines == lines, last.bottom == bottom, abs(last.end - from) < 0.000001 {
                    placed[placed.count - 1].end = to
                } else {
                    placed.append(ShortCaption(start: from, end: to, lines: lines, bottom: bottom))
                }
            }
        }
        return placed
    }

    /// The captions as an ASS file on the Short's own pixel grid: libass draws each at the
    /// size and place given, and wraps nothing itself.
    static func ass(_ captions: [ShortCaption], size: SubtitleSize) -> String {
        func stamp(_ seconds: Double) -> String {
            let centis = max(0, Int((seconds * 100).rounded()))
            return String(format: "%d:%02d:%02d.%02d", centis / 360_000, centis / 6000 % 60, centis / 100 % 60, centis % 100)
        }
        func text(_ line: String) -> String {
            line.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        }
        let height = Int(ShortFormat.size.height)
        var lines = [
            "[Script Info]", "ScriptType: v4.00+", "PlayResX: \(Int(ShortFormat.size.width))", "PlayResY: \(height)",
            "WrapStyle: 2", "ScaledBorderAndShadow: yes", "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Short,Helvetica,\(Int((fontSize(size) * lineHeight).rounded())),&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,\(Int(outline(size))),0,2,\(Int(margins.left)),\(Int(margins.right)),\(height - Int(ShortLayout.captionBottom)),1",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        ]
        for caption in captions {
            lines.append("Dialogue: 0,\(stamp(caption.start)),\(stamp(caption.end)),Short,,0,0,\(height - Int(caption.bottom.rounded())),,"
                         + caption.lines.map(text).joined(separator: "\\N"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The ASS file in the temporary folder, named by its content.
    static func assFile(_ captions: [ShortCaption], size: SubtitleSize) -> URL? {
        guard !captions.isEmpty else { return nil }
        let data = Data(ass(captions, size: size).utf8)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yamvideo-short-\(ColorCube.sha256(data).prefix(16))").appendingPathExtension("ass")
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        return url
    }
}

/// A Short's captions as the Preview's engine draws them: `YamGraphics.captions`.
struct CaptionOverlay: Equatable, Encodable {
    var size: Double
    var outline: Double
    /// The room kept each side; captions are centred between.
    var left = ShortCaptionLayout.margins.left
    var right = ShortCaptionLayout.margins.right
    var items: [ShortCaption]

    init(_ items: [ShortCaption], size: SubtitleSize) {
        self.items = items
        self.size = ShortCaptionLayout.fontSize(size)
        self.outline = ShortCaptionLayout.outline(size)
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return text.replacingOccurrences(of: "<", with: "\\u003c")
    }
}

/// Everything a Short's laid-out captions depend on, to know when to lay them out again.
struct ShortCaptionKey: Equatable {
    var clip: UUID
    var segments: [TimelineSegment]
    var short: Short
    var graphics: GraphicsTrack?
    var subtitles: URL?
    var subtitlesDate: Date?
    var transcriptWords: Int
    var transcriptModel: String?
    var captions: CaptionUse?
    var shortCaptions: CaptionUse?
    var size: SubtitleSize
}

extension VideoItem {
    /// The Short's burned-in captions as its Preview shows them, in recording time (the
    /// Preview plays the recording), or nil when none are burned in.
    func shortCaptionOverlay(_ short: Short, settings: ExportSettings) -> CaptionOverlay? {
        guard settings.shortCaptionUse(hasFile: subtitles != nil).burns else { return nil }
        let captions = shortCaptions(short, settings: settings)
        guard !captions.isEmpty else { return nil }
        let placed = ShortCaptionLayout.layout(captions, graphics: graphics?.forShort(short), option: short.captions, size: settings.subtitleSize,
                                               bottom: shortCaptionBottom(short))
        return CaptionOverlay(placed.map { var caption = $0; caption.start += short.start; caption.end += short.start; return caption },
                              size: settings.subtitleSize)
    }

    func shortCaptionKey(_ short: Short, settings: ExportSettings) -> ShortCaptionKey {
        ShortCaptionKey(clip: id, segments: timeline.segments, short: short, graphics: graphics, subtitles: subtitles,
                        subtitlesDate: subtitles.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate },
                        transcriptWords: transcript?.words.count ?? 0, transcriptModel: transcript?.model,
                        captions: settings.captions, shortCaptions: settings.shortCaptions, size: settings.subtitleSize)
    }
}
