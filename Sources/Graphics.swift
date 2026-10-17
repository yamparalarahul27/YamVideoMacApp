import CoreGraphics
import Foundation

// MARK: - JSON values

/// Template props are data the graphics engine reads (Resources/Graphics/graphics.js).
/// They stay JSON (`JSONValue`, from AgentProtocol.swift) in the project, so a new
/// template field never needs a schema change; `GraphicsTrack.problem(duration:)`
/// checks what the app relies on.
extension JSONValue {
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    /// Every string under `key`, at any depth, passed through `transform`.
    func mappingStrings(forKey key: String, _ transform: (String) throws -> String) rethrows -> JSONValue {
        switch self {
        case .array(let values): return .array(try values.map { try $0.mappingStrings(forKey: key, transform) })
        case .object(let values):
            var mapped: [String: JSONValue] = [:]
            for (name, value) in values {
                if name == key, case .string(let text) = value { mapped[name] = .string(try transform(text)) }
                else { mapped[name] = try value.mappingStrings(forKey: key, transform) }
            }
            return .object(mapped)
        default: return self
        }
    }

    /// Visits every value with the key it sits under (nil for array elements and the root).
    func visit(key: String? = nil, _ body: (String?, JSONValue) -> Void) {
        body(key, self)
        switch self {
        case .array(let values): values.forEach { $0.visit(key: nil, body) }
        case .object(let values): values.keys.sorted().forEach { values[$0]!.visit(key: $0, body) }
        default: break
        }
    }
}

// MARK: - Graphics

/// Where a kind sits: the right-hand column over the video, the side panel, the whole
/// screen (the end screen, which moves the picture into a frame of its own), or next to
/// the speaker, wherever the layout puts them (`LogoSpot`).
enum GraphicZone: String, Codable { case column, panel, screen, speaker }

/// The template kinds of graphics engine version 1. See docs/plans/graphics-track.md.
enum GraphicKind: String, Codable, CaseIterable, Identifiable {
    case namePlate, featureList, titleCard, phoneScreens, route, link, endCard
    case panelTitle, rule, checklist
    case endScreen
    case logoBadge

    var id: String { rawValue }
    var zone: GraphicZone {
        switch self {
        case .panelTitle, .rule, .checklist: return .panel
        case .endScreen: return .screen
        case .logoBadge: return .speaker
        default: return .column
        }
    }
    /// Kinds the engine can write in ink. The others always use glass cards.
    var hasInk: Bool { zone == .panel }
    /// Whether the owner may move and resize it on the picture. The end screen's boxes sit
    /// where YouTube puts its elements, so it stays where it is.
    var isPlaceable: Bool { self != .endScreen }
    var label: String {
        switch self {
        case .namePlate: return "Name plate"
        case .featureList: return "Feature list"
        case .titleCard: return "Title card"
        case .phoneScreens: return "Phone screens"
        case .route: return "Route"
        case .link: return "Link"
        case .endCard: return "End card"
        case .panelTitle: return "Panel title"
        case .rule: return "Rule"
        case .checklist: return "Checklist"
        case .endScreen: return "End screen"
        case .logoBadge: return "Logo badge"
        }
    }
}

/// glass: cards. ink: handwriting over a soft haze. mix: panel kinds in ink, the rest glass.
enum GraphicsLook: String, Codable, CaseIterable, Identifiable {
    case glass, ink, mix
    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: return "Glass cards"
        case .ink: return "Ink"
        case .mix: return "Ink + glass"
        }
    }
}

enum PanelStyle: String, Codable, CaseIterable, Identifiable {
    case shade, solid
    var id: String { rawValue }
    var label: String { self == .shade ? "Shade" : "Solid" }
}

struct GraphicsStyle: Codable, Equatable {
    var accent = "#F5C42C"
    var panel = PanelStyle.shade
    /// Slide the picture to the left half while a panel shows.
    var moveVideo = true
    /// Soft edge of the shade next to the speaker, in design pixels.
    var edge: Double = 170
    var look = GraphicsLook.glass
    /// How large cards and panels are drawn, for viewers on a phone: nil (or 1) as the
    /// template draws them, up to `sizes.upperBound`. Cards grow by it from the column's
    /// top-right corner, so they grow away from the frame's edge; panels grow half as much,
    /// from the panel's top-right corner, so they stay on their shade. Logo badges, the end
    /// screen and Shorts keep their own sizes. Version 16 onwards.
    var size: Double?

    static let sizes = 1.0...1.5

    init() {}

    /// Missing keys keep their defaults, so `{"look": "mix"}` is a complete style.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? accent
        panel = try c.decodeIfPresent(PanelStyle.self, forKey: .panel) ?? panel
        moveVideo = try c.decodeIfPresent(Bool.self, forKey: .moveVideo) ?? moveVideo
        edge = try c.decodeIfPresent(Double.self, forKey: .edge) ?? edge
        look = try c.decodeIfPresent(GraphicsLook.self, forKey: .look) ?? look
        size = try c.decodeIfPresent(Double.self, forKey: .size)
    }
}

/// Where a graphic sits on the picture: moved `x`, `y` design pixels from its place in the
/// template and scaled by `scale` from the top-left corner of its zone. The engine applies
/// it, so the preview and the export agree.
struct GraphicTransform: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1

    static let scales = 0.4...2.5
    /// How far a graphic may move: a whole frame either way.
    static let reach = CGSize(width: 1920, height: 1080)

    init(x: Double = 0, y: Double = 0, scale: Double = 1) { self.x = x; self.y = y; self.scale = scale }

    var isIdentity: Bool { x == 0 && y == 0 && scale == 1 }

    /// Where a design-pixel point of the template lands, for a zone whose top-left is `origin`.
    func apply(_ point: CGPoint, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + x + scale * (point.x - origin.x), y: origin.y + y + scale * (point.y - origin.y))
    }

    func apply(_ rect: CGRect, origin: CGPoint) -> CGRect {
        CGRect(origin: apply(rect.origin, origin: origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    /// The first thing out of range, or nil.
    var problem: String? {
        guard x.isFinite, y.isFinite, scale.isFinite else { return "A graphic's position and size must be finite numbers." }
        guard Self.scales.contains(scale) else {
            return "A graphic's scale must be from \(Self.scales.lowerBound.formatted()) to \(Self.scales.upperBound.formatted())."
        }
        guard abs(x) <= Self.reach.width, abs(y) <= Self.reach.height else {
            return "A graphic can move at most \(Int(Self.reach.width)) px across and \(Int(Self.reach.height)) px down or up."
        }
        return nil
    }
}

/// One timed graphic. `start` and `end` are edited-recording seconds, like zoom starts.
/// Beat times inside `props` (`at`, `…At`) are seconds after `start`.
struct Graphic: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: GraphicKind
    var start: Double
    var end: Double
    var props: [String: JSONValue]
    /// glass or ink for this graphic alone; nil follows the style.
    var look: GraphicsLook?
    /// Moved or resized on the picture; nil is the template's own place and size.
    var transform: GraphicTransform?

    init(id: UUID = UUID(), kind: GraphicKind, start: Double, end: Double,
         props: [String: JSONValue] = [:], look: GraphicsLook? = nil, transform: GraphicTransform? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
        self.props = props; self.look = look; self.transform = transform
    }

    var length: Double { end - start }
}

/// What the graphics are drawn on: the 1920×1080 video, or a Short's 1080×1920 canvas with
/// its choice of panel layout.
enum GraphicsCanvas: Equatable {
    case landscape
    /// A Short, with its panel layout and how far its picture is zoomed out.
    case short(ShortPanels, zoom: Double = 1)

    /// The design canvas, in design pixels.
    var size: CGSize { self == .landscape ? CGSize(width: 1920, height: 1080) : ShortFormat.size }
    var panels: ShortPanels? { if case .short(let panels, _) = self { return panels }; return nil }
    /// A Short's layout; nil on the 16:9 video.
    var shortLayout: ShortLayout? { if case .short(let panels, let zoom) = self { return ShortLayout(panels: panels, zoom: zoom) }; return nil }
}

/// The graphics of one recording.
struct GraphicsTrack: Codable, Equatable {
    var style = GraphicsStyle()
    var items: [Graphic] = []
    /// What they are drawn on. Never stored: a Short's graphics are made from the
    /// recording's when needed (`forShort`).
    var canvas = GraphicsCanvas.landscape

    private enum CodingKeys: String, CodingKey { case style, items }

    static let minimumLength = 0.5
    /// Panel graphics closer than this share one panel, so the shade does not flash.
    static let panelMergeGap = 1.0
    /// The panel slide and the video move both take this long.
    static let slide = 0.8
    /// The video moves left by this fraction of the frame width while a panel shows.
    static let shiftFraction = 0.25
    static let maximumPropsBytes = 64 * 1024

    init(style: GraphicsStyle = GraphicsStyle(), items: [Graphic] = [], canvas: GraphicsCanvas = .landscape) {
        self.style = style; self.items = items; self.canvas = canvas
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(GraphicsStyle.self, forKey: .style) ?? GraphicsStyle()
        items = try c.decodeIfPresent([Graphic].self, forKey: .items) ?? []
    }

    var isEmpty: Bool { items.isEmpty && style == GraphicsStyle() }

    /// The same graphics without their moves and sizes on the picture, to tell a drag apart.
    var withoutPlacement: GraphicsTrack {
        var copy = self
        for index in copy.items.indices { copy.items[index].transform = nil }
        return copy
    }

    /// glass or ink, after the style and the kind have had their say.
    func look(of graphic: Graphic) -> GraphicsLook {
        let wanted = graphic.look ?? (style.look == .mix ? (graphic.kind.zone == .panel ? .ink : .glass) : style.look)
        return wanted == .ink && graphic.kind.hasInk ? .ink : .glass
    }

    /// Merged panel intervals, the same rule as `plan()` in graphics.js.
    func panelSpans() -> [PanelSpan] {
        var spans: [PanelSpan] = []
        for graphic in items.sorted(by: { $0.start < $1.start }) where graphic.kind.zone == .panel {
            if var last = spans.last, graphic.start - last.end < Self.panelMergeGap {
                last.end = max(last.end, graphic.end)
                last.ink = last.ink && look(of: graphic) == .ink
                spans[spans.count - 1] = last
            } else {
                spans.append(PanelSpan(start: graphic.start, end: graphic.end, ink: look(of: graphic) == .ink))
            }
        }
        return spans
    }

    /// The first thing wrong with the track for a recording of `duration` seconds, or nil.
    func problem(duration: Double) -> String? {
        guard style.accent.count == 7, style.accent.hasPrefix("#"),
              style.accent.dropFirst().allSatisfy(\.isHexDigit) else {
            return "The graphics accent must be a colour like #F5C42C."
        }
        guard style.edge.isFinite, (0...400).contains(style.edge) else {
            return "The shade edge must be from 0 to 400 pixels."
        }
        if let size = style.size {
            guard size.isFinite, GraphicsStyle.sizes.contains(size) else {
                return String(format: "The graphics size must be from %.1f to %.1f.", GraphicsStyle.sizes.lowerBound, GraphicsStyle.sizes.upperBound)
            }
        }
        guard Set(items.map(\.id)).count == items.count else { return "Two graphics share one ID." }
        for graphic in items {
            let name = graphic.kind.label.lowercased()
            guard graphic.start.isFinite, graphic.end.isFinite else { return "Graphic times must be finite numbers." }
            guard graphic.start >= 0, graphic.end <= duration + 0.01 else {
                return String(format: "The %@ must fit inside the edited recording (%.2f s).", name, duration)
            }
            guard graphic.length >= Self.minimumLength - 0.000001 else {
                return String(format: "A graphic must show for at least %.1f s.", Self.minimumLength)
            }
            guard graphic.look != .mix else { return "A single graphic's look is glass or ink." }
            if let problem = graphic.transform?.problem { return problem }
            if graphic.kind == .endScreen {
                guard graphic.transform == nil else {
                    return "The end screen's boxes sit where YouTube puts its elements, so it cannot be moved or resized on the picture."
                }
                if let problem = EndScreenLayout.problem(props: graphic.props) { return problem }
            }
            if graphic.kind == .logoBadge, let problem = LogoBadge.problem(props: graphic.props, length: graphic.length) { return problem }
            let props = JSONValue.object(graphic.props)
            if let data = try? JSONEncoder().encode(props), data.count > Self.maximumPropsBytes {
                return "The \(name) has too much text or data."
            }
            var issue: String?
            props.visit { key, value in
                guard issue == nil else { return }
                switch value {
                case .string(let text):
                    if text.count > 400 { issue = "Text in the \(name) is longer than 400 characters." }
                    if key == "image", !text.hasPrefix("/") { issue = "Images in the \(name) must be absolute file paths." }
                case .number(let number):
                    if !number.isFinite { issue = "Numbers in the \(name) must be finite." }
                    if let key, key == "at" || key.hasSuffix("At"), !(0...3600).contains(number) {
                        issue = "Times inside the \(name) are seconds after its start, from 0."
                    }
                default: break
                }
            }
            if let issue { return issue }
        }
        for zone in [GraphicZone.column, .panel, .speaker] {
            let ordered = items.filter { $0.kind.zone == zone }.sorted { $0.start < $1.start }
            for (a, b) in zip(ordered, ordered.dropFirst()) where b.start < a.end - 0.001 {
                return "The \(a.kind.label.lowercased()) and the \(b.kind.label.lowercased()) overlap in the same place."
            }
        }
        return endScreenProblem(duration: duration)
    }

    /// YouTube's window for end screen elements: the last 5 to 20 seconds, with nothing
    /// else of ours on screen, so the boxes stay clear.
    private func endScreenProblem(duration: Double) -> String? {
        let screens = items.filter { $0.kind == .endScreen }
        guard let screen = screens.first else { return nil }
        guard screens.count == 1 else { return "A video has one end screen." }
        guard abs(screen.end - duration) <= EndScreen.endTolerance else {
            return String(format: "The end screen must end where the video ends (%.2f s); YouTube shows its elements in the last 5 to 20 seconds.", duration)
        }
        let lengths = EndScreen.lengths
        guard screen.length >= lengths.lowerBound - 0.001, screen.length <= lengths.upperBound + 0.001 else {
            return String(format: "YouTube's end screen lasts %.0f to %.0f seconds; this one is %.1f s.", lengths.lowerBound, lengths.upperBound, screen.length)
        }
        for graphic in items where graphic.kind != .endScreen {
            let clear = graphic.end + (graphic.kind.zone == .panel ? Self.slide : 0)
            guard clear <= screen.start + 0.001 else {
                return graphic.kind.zone == .panel
                    ? String(format: "The %@'s panel must have slid away (%.1f s after it ends) before the end screen starts at %.2f s.",
                             graphic.kind.label.lowercased(), Self.slide, screen.start)
                    : String(format: "The %@ is still showing when the end screen starts at %.2f s; nothing else may show over YouTube's end screen.",
                             graphic.kind.label.lowercased(), screen.start)
            }
        }
        return nil
    }

    /// The JSON the engine reads. Image paths are passed through `image`.
    func engineData(duration: Double, fps: String, image: (String) throws -> String = { $0 }) throws -> Data {
        var items: [JSONValue] = []
        for graphic in self.items.sorted(by: { $0.start < $1.start }) {
            var item: [String: JSONValue] = [
                "id": .string(graphic.id.uuidString), "kind": .string(graphic.kind.rawValue),
                "start": .number(graphic.start), "end": .number(graphic.end),
                "props": try JSONValue.object(graphic.props).mappingStrings(forKey: "image", image),
            ]
            if let look = graphic.look { item["look"] = .string(look.rawValue) }
            if let transform = graphic.transform, !transform.isIdentity {
                item["transform"] = .object(["x": .number(transform.x), "y": .number(transform.y), "scale": .number(transform.scale)])
            }
            items.append(.object(item))
        }
        var styleData: [String: JSONValue] = [
            "accent": .string(style.accent), "panel": .string(style.panel.rawValue),
            "moveVideo": .bool(style.moveVideo), "edge": .number(style.edge), "look": .string(style.look.rawValue),
        ]
        // Only a size above 1 goes in, so a track without one renders (and caches) as before.
        if let size = style.size, size > 1 { styleData["size"] = .number(size) }
        var root: [String: JSONValue] = [
            "version": .number(1), "duration": .number(duration), "fps": .string(fps),
            "style": .object(styleData),
            "items": .array(items),
        ]
        if let layout = canvas.shortLayout {
            root["layout"] = .object(["canvas": .string("short"), "panels": .string(layout.panels.rawValue), "drop": .number(layout.drop)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(root))
    }
}

/// A stretch of time with a side panel on screen. `ink` spans use the haze, not a panel.
struct PanelSpan: Equatable {
    var start: Double
    var end: Double
    var ink: Bool
}

extension ClipTimeline {
    /// Anchors each graphic to the frame where it begins, like zooms. A graphic whose
    /// anchor is cut away, or which no longer has room to show, is dropped; a later
    /// graphic that now collides with an earlier one in the same place is dropped too.
    func remap(_ track: GraphicsTrack, from old: ClipTimeline) -> (track: GraphicsTrack, removed: [UUID]) {
        var kept: [Graphic] = []
        var removed: [UUID] = []
        var screen: Graphic?
        for var graphic in track.items.sorted(by: { $0.start < $1.start }) {
            if graphic.kind == .endScreen, screen == nil { screen = graphic; continue }
            guard let source = old.location(at: graphic.start)?.source,
                  let start = time(forSource: source) else { removed.append(graphic.id); continue }
            let end = min(start + graphic.length, duration)
            guard end - start >= GraphicsTrack.minimumLength - 0.000001,
                  !kept.contains(where: { $0.kind.zone == graphic.kind.zone && $0.start < end - 0.001 && start < $0.end - 0.001 }) else {
                removed.append(graphic.id); continue
            }
            graphic.start = start; graphic.end = end
            kept.append(graphic)
        }
        // The end screen stays on the last seconds of the video, as long as it was, or
        // shorter when something now runs into it; dropped when under YouTube's 5 s.
        if var screen {
            var start = duration - min(screen.length, EndScreen.lengths.upperBound)
            for graphic in kept { start = max(start, graphic.end + (graphic.kind.zone == .panel ? GraphicsTrack.slide : 0)) }
            if start >= 0, duration - start >= EndScreen.lengths.lowerBound - 0.000001 {
                screen.start = start; screen.end = duration
                kept.append(screen)
            } else {
                removed.append(screen.id)
            }
        }
        var result = track
        result.items = kept
        return (result, removed)
    }
}

extension ProjectClip {
    /// The same recording without its graphics, to tell a graphics-only change apart.
    var withoutGraphics: ProjectClip { var copy = self; copy.graphics = nil; return copy }
    /// The same recording without what draws over the picture or is made from it (its
    /// graphics and Shorts), to tell a change the movie does not need apart.
    var withoutOverlays: ProjectClip { var copy = self; copy.graphics = nil; copy.shorts = nil; return copy }
}

// MARK: - The move aside, shared by the preview and the export

/// How far the picture has moved aside at an edited time: 0 in place, 1 fully moved.
/// Smoothstep over `GraphicsTrack.slide`, the same curve as the engine's video move.
struct GraphicsMotion: Equatable {
    /// Panels the picture moves aside for; none when the style keeps the picture in place.
    var spans: [PanelSpan]
    var style: GraphicsStyle
    /// The end screen: from `start` the picture moves into `frame` (design pixels of a
    /// 1920-wide frame) and stays there to the end of the video.
    var screen: ScreenMove?
    /// In a Short, the panel layout: a lift under a bottom sheet, a frost over the whole
    /// picture under a full shade, or the picture shrinking into the split frame. Nil on
    /// the 16:9 video.
    var short: ShortPanels?
    /// How much lower a zoomed-out Short's bottom sheet starts (`ShortLayout.drop`).
    var drop = 0.0

    struct ScreenMove: Equatable {
        var start: Double
        var frame: CGRect
    }

    init?(_ track: GraphicsTrack?) {
        guard let track else { return nil }
        let spans: [PanelSpan]
        switch track.canvas.panels {
        case nil, .sheet?: spans = track.style.moveVideo ? track.panelSpans() : []
        // The full shade and the split are what those layouts are, whatever the style.
        case .shade?, .split?: spans = track.panelSpans()
        }
        let screen = track.canvas == .landscape
            ? track.endScreen.map { ScreenMove(start: $0.start, frame: EndScreenLayout(props: $0.props).frame) } : nil
        guard !spans.isEmpty || screen != nil else { return nil }
        self.spans = spans; self.style = track.style; self.screen = screen; self.short = track.canvas.panels
        self.drop = track.canvas.shortLayout?.drop ?? 0
    }

    /// Design pixels on this frame: 1920 of them across the long side, on the 16:9 video
    /// and on a Short alike.
    static func unit(_ size: CGSize) -> Double { Double(max(size.width, size.height)) / 1920 }

    /// The fill behind a moved picture: the same frame, this much larger, blurred by this
    /// sigma (design pixels), then darkened and desaturated by one matrix on the encoded
    /// values, where both renderers can do exactly the same sum.
    static let fillScale = 1.3
    static let fillBlur = 36.0
    static let fillDim = 0.86
    static let fillSaturation = 0.9
    /// The moved picture's right edge fades into the fill over this many design pixels.
    static let edgeFade = 220.0
    /// Rec.709 luma weights, for the saturation step.
    static let lumaWeights = (r: 0.2126, g: 0.7152, b: 0.0722)

    static func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    func progress(at time: Double) -> (amount: Double, span: PanelSpan?) {
        let slide = GraphicsTrack.slide
        for span in spans where time >= span.start && time < span.end + slide {
            if time < span.start + slide { return (Self.smooth((time - span.start) / slide), span) }
            if time < span.end { return (1, span) }
            return (1 - Self.smooth((time - span.end) / slide), span)
        }
        return (0, nil)
    }

    /// How far the picture has moved into the end screen's frame: 0 whole, 1 in the frame.
    func screenProgress(at time: Double) -> Double {
        guard let screen, time >= screen.start else { return 0 }
        return Self.smooth(min(1, (time - screen.start) / GraphicsTrack.slide))
    }

    /// Where the picture sits in a frame of `size` pixels at `amount` of the end screen's
    /// move, top-left origin, in whole pixels: the full frame at 0, the end screen's frame
    /// at 1, scaled about the top-left corner. Both renderers use exactly these numbers.
    func screenPlacement(amount: Double, size: CGSize) -> (x: Int, y: Int, width: Int, height: Int) {
        guard let screen else { return (0, 0, Int(size.width), Int(size.height)) }
        let unit = size.width / 1920
        let scale = 1 + (screen.frame.width / 1920 - 1) * amount
        return (Int((screen.frame.minX * unit * amount).rounded()), Int((screen.frame.minY * unit * amount).rounded()),
                max(2, Int((size.width * scale).rounded())), max(2, Int((size.height * scale).rounded())))
    }

    /// Where the frost under the panel fades in, as fractions of the frame width (of its
    /// height in a Short, top to bottom). A full shade frosts everything.
    func frostRamp(for span: PanelSpan) -> (from: Double, to: Double, blur: Double)? {
        switch short {
        case nil:
            if span.ink { return (780 / 1920, 1160 / 1920, 14) }
            guard style.panel == .shade else { return nil }
            return (0.5, (960 + style.edge) / 1920, 28)
        case .sheet?:
            let top = ShortLayout.sheetTop + drop
            if span.ink { return ((top - 40) / 1920, (top + 260) / 1920, 14) }
            guard style.panel == .shade else { return nil }
            return (top / 1920, (top + style.edge) / 1920, 28)
        case .shade?:
            return (-1, -1 + 0.5 / 1920, span.ink ? 14 : 28)
        case .split?:
            return nil
        }
    }

    /// How far the picture lifts under a bottom sheet, in pixels of a frame `size` tall.
    func lift(amount: Double, size: CGSize) -> Int {
        short == .sheet ? Int((ShortLayout.lift * Self.unit(size) * amount).rounded()) : 0
    }

    /// Where the picture sits in the split layout at `amount` of its move, like
    /// `screenPlacement`: the full frame at 0, the split frame at 1, in whole pixels.
    func splitPlacement(amount: Double, size: CGSize) -> (x: Int, y: Int, width: Int, height: Int) {
        let frame = ShortLayout.splitFrame, unit = Double(size.width) / ShortFormat.size.width
        let scale = 1 + (frame.width / ShortFormat.size.width - 1) * amount
        return (Int((frame.minX * unit * amount).rounded()), Int((frame.minY * unit * amount).rounded()),
                max(2, Int((size.width * scale).rounded())), max(2, Int((size.height * scale).rounded())))
    }
}

// MARK: - The engine's files

enum GraphicsEngine {
    /// Resources/Graphics in the app bundle, or in the source tree for tests and tools.
    static var resources: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Graphics"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("graphics.js").path) { return bundled }
        if let root = ProcessInfo.processInfo.environment["YAMVIDEO_ROOT"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent("Resources/Graphics")
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("graphics.js").path) { return url }
        }
        return nil
    }

    /// Writes a page folder: the engine files, the images under content-hash names, and
    /// `index.html` from page.html. `media` adds root `<video>`/`<audio>` HTML for full mode.
    /// Returns the folder's index.html.
    static func writePage(_ track: GraphicsTrack, duration: Double, fps: String, mode: String,
                          unit: String? = nil, origin: Double? = nil, pageDuration: Double? = nil, media: String = "",
                          to folder: URL) throws -> URL {
        guard let resources else { throw FFmpegError(message: "The graphics engine files are missing from the app.") }
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        for name in ["graphics.js", "graphics.css", "gsap.min.js"] {
            try copyIfChanged(resources.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        for font in try manager.contentsOfDirectory(atPath: resources.appendingPathComponent("fonts").path) where font.hasSuffix(".woff2") {
            try copyIfChanged(resources.appendingPathComponent("fonts/\(font)"), to: folder.appendingPathComponent("fonts/\(font)"))
        }
        let json = try pageJSON(track, duration: duration, fps: fps, folder: folder)
        var options: [String: JSONValue] = ["mode": .string(mode)]
        if let unit { options["unit"] = .string(unit) }
        if let origin { options["origin"] = .number(origin) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let optionsJSON = String(decoding: try encoder.encode(JSONValue.object(options)), as: UTF8.self)
        let rate = fps.split(separator: "/").compactMap { Double($0) }
        let fpsValue = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : (rate.first ?? 30)
        var page = try String(contentsOf: resources.appendingPathComponent("page.html"), encoding: .utf8)
        let canvas = track.canvas.size
        page = page.replacingOccurrences(of: "{{MODE}}", with: mode)
            .replacingOccurrences(of: "{{WIDTH}}", with: String(Int(canvas.width)))
            .replacingOccurrences(of: "{{HEIGHT}}", with: String(Int(canvas.height)))
            .replacingOccurrences(of: "{{DURATION}}", with: String(format: "%.3f", pageDuration ?? duration))
            .replacingOccurrences(of: "{{FPS}}", with: String(Int(fpsValue.rounded())))
            .replacingOccurrences(of: "{{MEDIA}}", with: media)
            .replacingOccurrences(of: "{{JSON}}", with: json)
            .replacingOccurrences(of: "{{OPTIONS}}", with: optionsJSON)
        let index = folder.appendingPathComponent("index.html")
        try page.write(to: index, atomically: true, encoding: .utf8)
        return index
    }

    /// The engine JSON for a page in `folder`, safe to inline in HTML or pass to
    /// JavaScript. Images are copied into `folder/media` under content-hash names.
    static func pageJSON(_ track: GraphicsTrack, duration: Double, fps: String, folder: URL) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        let data = try track.engineData(duration: duration, fps: fps) { path in
            let source = URL(fileURLWithPath: path)
            guard let bytes = try? Data(contentsOf: source) else {
                throw FFmpegError(message: "A graphic's image is missing: \(source.lastPathComponent)")
            }
            let name = UUID(deterministicFrom: bytes).uuidString.lowercased().prefix(12) + "." + source.pathExtension.lowercased()
            let target = folder.appendingPathComponent("media/\(name)")
            if !manager.fileExists(atPath: target.path) { try bytes.write(to: target) }
            return "media/\(name)"
        }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func copyIfChanged(_ source: URL, to target: URL) throws {
        let manager = FileManager.default
        if let a = manager.contents(atPath: source.path), let b = manager.contents(atPath: target.path), a == b { return }
        try? manager.removeItem(at: target)
        try manager.copyItem(at: source, to: target)
    }

    /// Reads a graphics JSON file (the format Tools/Graphics uses) into a track. Image
    /// paths are made absolute against the file's folder and must exist.
    static func importFile(_ url: URL) throws -> GraphicsTrack {
        let data = try Data(contentsOf: url)
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw FFmpegError(message: "That file is not graphics data.")
        }
        var track = GraphicsTrack()
        if let style = root["style"] {
            track.style = try JSONDecoder().decode(GraphicsStyle.self, from: JSONEncoder().encode(style))
        }
        let base = url.deletingLastPathComponent()
        for value in root["items"]?.array ?? [] {
            guard let item = value.object, let kindName = item["kind"]?.string,
                  let kind = GraphicKind(rawValue: kindName),
                  let start = item["start"]?.number, let end = item["end"]?.number else {
                throw FFmpegError(message: "Each graphic needs a known kind, a start and an end.")
            }
            let idText = item["id"]?.string ?? UUID().uuidString
            let id = UUID(uuidString: idText) ?? UUID(deterministicFrom: Data(idText.utf8))
            let props = try (item["props"] ?? .object([:])).mappingStrings(forKey: "image") { path in
                let resolved = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                let standard = resolved.standardizedFileURL
                guard FileManager.default.fileExists(atPath: standard.path) else {
                    throw FFmpegError(message: "Image not found: \(path)")
                }
                return standard.path
            }
            let look = item["look"]?.string.flatMap(GraphicsLook.init(rawValue:))
            let transform = item["transform"]?.object.map { place in
                GraphicTransform(x: place["x"]?.number ?? 0, y: place["y"]?.number ?? 0, scale: place["scale"]?.number ?? 1)
            }
            track.items.append(Graphic(id: id, kind: kind, start: start, end: end, props: props.object ?? [:], look: look,
                                       transform: transform?.isIdentity == true ? nil : transform))
        }
        return track
    }
}
