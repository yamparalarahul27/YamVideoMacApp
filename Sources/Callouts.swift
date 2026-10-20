import CoreGraphics
import Foundation

// Callouts (docs/plans/callout-graphic.md): a short label with a thin line to a point on
// the screen recording, to name a UI pattern next to the element. The point is in the
// screen recording's pixels. The app works out where it lands at each frame, through the
// layout and the screen's zooms, and where the label goes (`CalloutPlace`), so the engine
// only draws it and the preview and the export agree.

enum Callout {
    static let maximumText = 28
    static let maximumWords = 4
    static let lengths = 1.5...10.0
    static let sides = ["auto", "left", "right", "up", "down"]

    /// The label's near edge from the point: across, and up or down.
    static let reach = 140.0
    static let reachDown = 110.0
    /// Beside the screen: the label's near edge from the screen's edge.
    static let besideGap = 32.0
    /// The speaker's place is kept this much larger on each side.
    static let speakerMargin = 24.0
    /// How long the callout takes to fade when its point goes out of sight or comes back.
    static let fade = 0.25

    static func text(_ props: [String: JSONValue]) -> String {
        (props["text"]?.string ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func point(_ props: [String: JSONValue]) -> CGPoint? {
        guard let point = props["point"]?.object, let x = point["x"]?.number, let y = point["y"]?.number else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The first thing wrong with a callout's props, or nil. Its place on the picture
    /// (`place`) is the app's to write, so it is not checked here.
    static func problem(props: [String: JSONValue], length: Double) -> String? {
        let text = text(props)
        guard !text.isEmpty, text.count <= maximumText, !text.contains("\n"),
              text.split(whereSeparator: \.isWhitespace).count <= maximumWords else {
            return "A callout's text is 1 to \(maximumWords) words on one line, \(maximumText) characters or fewer."
        }
        guard let point = point(props), point.x >= 0, point.y >= 0 else {
            return "A callout needs point {x, y}: the spot on the screen recording, in its pixels."
        }
        if let side = props["side"], !(side.string.map(sides.contains) ?? false) {
            return "A callout's side is auto, left, right, up or down: where its label goes from the point."
        }
        guard length >= lengths.lowerBound - 0.000001, length <= lengths.upperBound + 0.000001 else {
            return String(format: "A callout shows for %.1f to %.0f seconds.", lengths.lowerBound, lengths.upperBound)
        }
        return nil
    }

    /// The label on one line, or on two at the space nearest the middle; nil when it
    /// cannot go on `count` lines.
    static func lines(_ text: String, count: Int) -> [String]? {
        guard count == 2 else { return count == 1 ? [text] : nil }
        let spaces = text.indices.filter { text[$0] == " " }
        let middle = Double(text.count) / 2
        guard let cut = spaces.min(by: {
            abs(Double(text.distance(from: text.startIndex, to: $0)) - middle) < abs(Double(text.distance(from: text.startIndex, to: $1)) - middle)
        }) else { return nil }
        return [String(text[..<cut]), String(text[text.index(after: cut)...])]
    }

    /// The label's size in design pixels, as graphics.css draws it. Glass: Inter Bold
    /// 54 px (about 0.6 em a character), 1.15 lines, 16 px above and below, 26 px at the
    /// sides. Ink: Virgil 60 px (also about 0.6 em a character), 1.15 lines, 14 px above
    /// and below and 20 px at the sides; its soft haze spreads a little past that.
    static func labelSize(_ lines: [String], ink: Bool) -> CGSize {
        let longest = Double(lines.map(\.count).max() ?? 0), count = Double(lines.count)
        if ink { return CGSize(width: longest * 36 + 40, height: count * 69 + 28) }
        return CGSize(width: longest * 32.4 + 52, height: count * 62.1 + 32)
    }
}

/// One moment of a callout, in design pixels: where its point lands, nil while it is out
/// of sight, the screen's place, and the boxes its label stays out of (the speaker).
struct CalloutScene: Equatable {
    var anchor: CGPoint?
    var screen: CGRect
    var keepOut: [CGRect]
}

/// Where a callout is drawn over its time: the side its label takes from the point, its
/// lines, and a path of `[t, ax, ay, lx, ly, o]`: seconds after the start, the point, the
/// middle of the label's near edge (where the line meets it) and how much of the callout
/// shows, 0 to 1. The engine moves in straight lines between the entries.
struct CalloutPlace: Equatable {
    enum Side: String { case left, right, up, down }
    var side: Side
    var lines: [String]
    var path: [[Double]]

    /// Whether the callout never shows: its point stays out of sight.
    var hidden: Bool { path.allSatisfy { $0[5] <= 0 } }

    var json: JSONValue {
        .object(["side": .string(side.rawValue), "lines": .array(lines.map { .string($0) }),
                 "path": .array(path.map { .array($0.map { .number($0) }) })])
    }

    /// The label's box with its near edge's middle at `attach`.
    static func box(_ attach: CGPoint, size: CGSize, side: Side) -> CGRect {
        let w = Double(size.width), h = Double(size.height), x = Double(attach.x), y = Double(attach.y)
        switch side {
        case .right: return CGRect(x: x, y: y - h / 2, width: w, height: h)
        case .left: return CGRect(x: x - w, y: y - h / 2, width: w, height: h)
        case .up: return CGRect(x: x - w / 2, y: y - h, width: w, height: h)
        case .down: return CGRect(x: x - w / 2, y: y, width: w, height: h)
        }
    }

    /// A place for the label: on `side` of the point, or `beside` the screen's edge at the
    /// point's height.
    struct Candidate: Equatable {
        var side: Side
        var beside: Bool

        func attach(_ scene: CalloutScene, anchor: CGPoint) -> CGPoint {
            let x = Double(anchor.x), y = Double(anchor.y)
            if beside {
                return CGPoint(x: side == .right ? Double(scene.screen.maxX) + Callout.besideGap : Double(scene.screen.minX) - Callout.besideGap, y: y)
            }
            switch side {
            case .right: return CGPoint(x: x + Callout.reach, y: y)
            case .left: return CGPoint(x: x - Callout.reach, y: y)
            case .up: return CGPoint(x: x, y: y - Callout.reachDown)
            case .down: return CGPoint(x: x, y: y + Callout.reachDown)
            }
        }
    }

    /// The places to try, in order. `auto`: beside the screen where it leaves room (a
    /// phone recording side by side), then across from the point toward the middle of
    /// `clear`, the other way, above and below.
    static func candidates(side: String, anchor: CGPoint, clear: CGRect) -> [Candidate] {
        switch side {
        case "left": return [Candidate(side: .left, beside: true), Candidate(side: .left, beside: false)]
        case "right": return [Candidate(side: .right, beside: true), Candidate(side: .right, beside: false)]
        case "up": return [Candidate(side: .up, beside: false)]
        case "down": return [Candidate(side: .down, beside: false)]
        default:
            let across: [Side] = anchor.x <= clear.midX ? [.right, .left] : [.left, .right]
            return [Candidate(side: .right, beside: true), Candidate(side: .left, beside: true)]
                + across.map { Candidate(side: $0, beside: false) } + [Candidate(side: .up, beside: false), Candidate(side: .down, beside: false)]
        }
    }

    /// Lays a callout out over `times` (seconds after its start) and the `scenes` at them.
    /// The first place whose label stays inside `clear` and out of the speaker whenever the
    /// point shows wins: beside the screen on one line or two, then next to the point on
    /// one line, then on two. With none, the one that breaks these the least. At each
    /// moment the label then moves as little as needed to stay inside `clear`.
    static func make(text: String, side: String, ink: Bool, times: [Double], scenes: [CalloutScene?], clear: CGRect) -> CalloutPlace {
        let shown = scenes.indices.filter { scenes[$0]?.anchor != nil }
        guard let first = shown.first else {
            let middle = CGPoint(x: clear.midX, y: clear.midY), end = times.last ?? 0
            let row = [Double(middle.x), Double(middle.y), Double(middle.x) + Callout.reach, Double(middle.y), 0]
            return CalloutPlace(side: .right, lines: [text], path: [[0] + row, [end] + row])
        }
        // Out of sight, the callout keeps the place it last had (or first has), so it fades there.
        var filled: [(scene: CalloutScene, anchor: CGPoint)] = []
        var latest = scenes[first]!
        for scene in scenes {
            if let scene, scene.anchor != nil { latest = scene }
            filled.append((latest, latest.anchor!))
        }
        let average = CGPoint(x: shown.map { Double(filled[$0].anchor.x) }.reduce(0, +) / Double(shown.count),
                              y: shown.map { Double(filled[$0].anchor.y) }.reduce(0, +) / Double(shown.count))
        // How far a label breaks the rules over the time it shows: area outside `clear`
        // and over the speaker, in square pixels.
        func misfit(_ candidate: Candidate, _ size: CGSize) -> Double {
            var total = 0.0
            for index in shown {
                let (scene, anchor) = filled[index]
                let box = Self.box(candidate.attach(scene, anchor: anchor), size: size, side: candidate.side)
                total += area(box) - area(box.intersection(clear))
                for keep in scene.keepOut { total += area(box.intersection(keep)) }
            }
            return total
        }
        let places = candidates(side: side, anchor: average, clear: clear)
        let tries = places.filter(\.beside).flatMap { place in [(place, 1), (place, 2)] }
            + [1, 2].flatMap { count in places.filter { !$0.beside }.map { ($0, count) } }
        var best: (candidate: Candidate, lines: [String], misfit: Double)?
        for (candidate, count) in tries {
            guard let lines = Callout.lines(text, count: count) else { continue }
            let miss = misfit(candidate, Callout.labelSize(lines, ink: ink))
            if best == nil || miss < best!.misfit - 0.5 { best = (candidate, lines, miss) }
            if miss <= 0.5 { break }
        }
        let chosen = best!
        let size = Callout.labelSize(chosen.lines, ink: ink)
        let opacity = Self.opacity(times: times, shown: scenes.map { $0?.anchor != nil })
        var rows: [[Double]] = []
        for index in times.indices {
            let (scene, anchor) = filled[index]
            var attach = chosen.candidate.attach(scene, anchor: anchor)
            let box = Self.box(attach, size: size, side: chosen.candidate.side)
            attach.x += shift(Double(box.minX), Double(box.maxX), Double(clear.minX), Double(clear.maxX))
            attach.y += shift(Double(box.minY), Double(box.maxY), Double(clear.minY), Double(clear.maxY))
            rows.append([(times[index] * 1000).rounded() / 1000, round1(anchor.x), round1(anchor.y), round1(attach.x), round1(attach.y),
                         (opacity[index] * 1000).rounded() / 1000])
        }
        return CalloutPlace(side: chosen.candidate.side, lines: chosen.lines, path: simplified(rows))
    }

    /// 1 where the point shows and has for `Callout.fade` seconds; down to 0 toward each
    /// moment it does not.
    static func opacity(times: [Double], shown: [Bool]) -> [Double] {
        // The time to the nearest moment out of sight, before and after, in two passes.
        var gap = [Double](repeating: .infinity, count: times.count)
        var last: Double?
        for index in times.indices {
            if !shown[index] { last = times[index] }
            if let last { gap[index] = times[index] - last }
        }
        var following: Double?
        for index in times.indices.reversed() {
            if !shown[index] { following = times[index] }
            if let following { gap[index] = min(gap[index], following - times[index]) }
        }
        return times.indices.map { shown[$0] ? min(1, gap[$0] / Callout.fade) : 0 }
    }

    /// Without the entries a straight line between their neighbours gives to within half
    /// a pixel and 0.01 of opacity.
    static func simplified(_ rows: [[Double]]) -> [[Double]] {
        guard rows.count > 2 else { return rows }
        var kept = [rows[0]]
        var anchor = 0
        for next in 2..<rows.count {
            let a = rows[anchor], b = rows[next]
            let fits = (anchor + 1..<next).allSatisfy { index in
                let row = rows[index], u = (row[0] - a[0]) / max(0.000001, b[0] - a[0])
                return (1...5).allSatisfy { abs(a[$0] + (b[$0] - a[$0]) * u - row[$0]) <= ($0 == 5 ? 0.01 : 0.5) }
            }
            if !fits { kept.append(rows[next - 1]); anchor = next - 1 }
        }
        kept.append(rows[rows.count - 1])
        return kept
    }

    private static func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : Double(rect.width * rect.height) }
    private static func round1(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }
    private static func shift(_ low: Double, _ high: Double, _ min: Double, _ max: Double) -> Double {
        if high - low > max - min { return min - low }
        return low < min ? min - low : high > max ? max - high : 0
    }
}

extension GraphicsTrack {
    /// What a callout needs from the recording's screen: there is one, and the point is on
    /// the part of it that shows. The track alone does not know the screen.
    func calloutProblem(screen: ScreenTrack?) -> String? {
        for graphic in items where graphic.kind == .callout {
            guard let screen else { return "A callout points at the screen recording, so add one first (setScreen)." }
            guard let point = Callout.point(graphic.props) else { continue }
            let picture = screen.picture
            guard (picture.minX...picture.maxX).contains(point.x), (picture.minY...picture.maxY).contains(point.y) else {
                return "A callout's point must be on the part of the screen recording that shows: x \(Int(picture.minX))–\(Int(picture.maxX)), "
                    + "y \(Int(picture.minY))–\(Int(picture.maxY))."
            }
        }
        return nil
    }
}

extension VideoItem {
    /// `track` with each callout's place written into its props, for the 16:9 video or
    /// for `short`: where its point lands at each frame and where its label goes. A Short
    /// without the screen on top does not show callouts. A track already on a Short's
    /// canvas is already placed and comes back as it is.
    func placingCallouts(_ track: GraphicsTrack, short: Short?) -> GraphicsTrack {
        guard track.canvas == .landscape, track.items.contains(where: { $0.kind == .callout }) else { return track }
        var placed = track
        if let short, !stacksScreen(short) {
            placed.items.removeAll { $0.kind == .callout }
            return placed
        }
        // The Preview places the graphics again for each frame it shows, so a place is
        // kept until what it is worked out from changes.
        let scene = Self.calloutKey([screen.map { JSONValue.string(Self.encoded($0)) } ?? .null, crop.map { .string("\($0)") } ?? .null,
                                     .number(Double(info?.width ?? 0)), .number(Double(info?.height ?? 0)), .number(info?.fps ?? 0),
                                     track.endScreen.map { .number($0.start) } ?? .null, short.map { .string(Self.encoded($0)) } ?? .null])
        for index in placed.items.indices where placed.items[index].kind == .callout {
            let graphic = placed.items[index]
            if let short, graphic.start < short.start - 0.0005 || graphic.start >= short.end { continue }
            let ink = track.look(of: graphic) == .ink
            let key = scene + Self.calloutKey([.number(graphic.start), .number(graphic.end), .object(graphic.props), .bool(ink)])
            let place = Self.calloutPlaces.value(key) ?? {
                let made = calloutPlace(graphic, short: short, ink: ink, endScreen: track.endScreen?.start)
                Self.calloutPlaces.store(key, made)
                return made
            }()
            placed.items[index].props["place"] = place.json
        }
        return placed
    }

    /// The recording's callouts whose point never shows on the 16:9 video: over their time
    /// the layout hides the screen, or a screen zoom leaves the point out.
    var hiddenCallouts: Set<UUID> {
        guard let track = graphics else { return [] }
        return Set(placingCallouts(track, short: nil).items.filter { graphic in
            graphic.kind == .callout && (graphic.props["place"]?.object?["path"]?.array ?? []).allSatisfy { ($0.array?.last?.number ?? 0) <= 0 }
        }.map(\.id))
    }

    private static let calloutPlaces = Cache<CalloutPlace>(limit: 256)
    private static func encoded<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
    }
    private static func calloutKey(_ parts: [JSONValue]) -> String { encoded(JSONValue.array(parts)) }

    /// Where a callout is drawn, sampled at each frame of the recording (up to 60 a second).
    func calloutPlace(_ graphic: Graphic, short: Short?, ink: Bool, endScreen: Double?) -> CalloutPlace {
        let step = 1 / min(60, max(1, info?.fps ?? 30))
        let length = max(0, (short.map { min(graphic.end, $0.end) } ?? graphic.end) - graphic.start)
        var times = stride(from: 0, to: length - step / 2, by: step).map { $0 }
        times.append(length)
        let scenes = Callout.point(graphic.props).map { calloutScenes(at: times.map { graphic.start + $0 }, point: $0, short: short, endScreen: endScreen) }
            ?? times.map { _ in nil }
        let clear = short == nil ? GraphicPlacement.safeArea : ShortFormat.clearArea
        return CalloutPlace.make(text: Callout.text(graphic.props), side: graphic.props["side"]?.string ?? "auto", ink: ink,
                                 times: times, scenes: scenes, clear: clear)
    }

    /// A callout's moments at edited `times` (in order), in design pixels: where `point`
    /// (screen recording pixels) lands through the layout and the zoom, nil while the
    /// layout hides the screen, the zoom leaves the point out, or the speaker's picture is
    /// over it.
    func calloutScenes(at times: [Double], point: CGPoint, short: Short?, endScreen: Double?) -> [CalloutScene?] {
        guard let info, let screen else { return times.map { _ in nil } }
        let crop = (self.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let geometry = short.map { LayoutGeometry(short: screen, crop: crop, window: $0.frame(info: info, crop: self.crop)) }
            ?? LayoutGeometry(track: screen, crop: crop)
        let unit = short == nil ? 1920 / Double(geometry.frame.width) : 1
        func design(_ rect: CGRect) -> CGRect {
            CGRect(x: Double(rect.minX) * unit, y: Double(rect.minY) * unit, width: Double(rect.width) * unit, height: Double(rect.height) * unit)
        }
        let ending = short == nil ? endScreen : nil
        let states = screen.states(at: times, geometry: geometry, endScreen: ending)
        var held: [ScreenLayout: LayoutState] = [:]
        return times.indices.map { index in
            let time = times[index], state = states[index]
            // The layout the picture is in, or moving to, decides whether the point shows
            // and where the speaker is: a change fades the callout once, and the speaker's
            // picture sweeping past does not make it flicker.
            let layout = screen.layout(at: time, endScreen: ending)
            let rest = held[layout] ?? geometry.held(layout)
            held[layout] = rest
            guard let place = state.screen, let restPlace = rest.screen else { return CalloutScene(anchor: nil, screen: .zero, keepOut: []) }
            let keep: CGRect
            if geometry.stack != nil {
                // The speaker below the screen, and the captions' band above the speaker.
                keep = CGRect(x: 0, y: Double(place.rect.maxY), width: Double(geometry.frame.width), height: Double(geometry.frame.height) - Double(place.rect.maxY))
            } else if rest.ink >= 0.5 {
                // Ink: the lines' area is on the left; the speaker beside it.
                let left = LayoutGeometry.inkWidth * Double(geometry.frame.width)
                keep = CGRect(x: left, y: 0, width: Double(geometry.frame.width) - left, height: Double(geometry.frame.height))
            } else {
                let margin = Callout.speakerMargin / unit
                keep = rest.speaker.rect.insetBy(dx: -margin, dy: -margin)
            }
            var anchor = screen.framePoint(point, at: time, place: place.rect)
            // The speaker's picture is drawn over the screen, except the Ink lines.
            if rest.ink < 0.5, let seen = screen.framePoint(point, at: time, place: restPlace.rect), rest.speaker.rect.contains(seen) { anchor = nil }
            return CalloutScene(anchor: anchor.map { CGPoint(x: Double($0.x) * unit, y: Double($0.y) * unit) },
                                screen: design(place.rect), keepOut: [design(keep)])
        }
    }
}
