import CoreGraphics
import Foundation

// Screen + speaker (docs/plans/screen-speaker.md): a screen recording synced to the
// speaker's recording, and the layouts that put the two pictures in one frame. The
// preview (`ScreenCompositor`) and the export (`FFmpeg.layoutStage`) both draw what
// `ScreenTrack.state(at:geometry:endScreen:)` gives for each frame.

/// How the speaker and the screen share the frame.
enum ScreenLayout: String, Codable, CaseIterable, Identifiable {
    /// The speaker fills the frame.
    case speaker
    /// The screen fills the frame, and the speaker is in a round bubble in a corner.
    case screen
    /// The speaker in a tall panel on the left, the screen on the right.
    case split

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speaker: return "Speaker"
        case .screen: return "Screen"
        case .split: return "Side by side"
        }
    }

    var symbol: String {
        switch self {
        case .speaker: return "person.crop.rectangle"
        case .screen: return "macwindow"
        case .split: return "rectangle.split.2x1"
        }
    }
}

/// A part of the edited recording with a layout of its own. Times are edited-recording
/// seconds and the interval is half-open, `[start, end)`, as for blur effects: two spans
/// may touch but not overlap.
struct LayoutSpan: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var layout: ScreenLayout

    static let defaultDuration = 5.0

    var duration: Double { end - start }

    func overlaps(_ other: LayoutSpan) -> Bool { start < other.end - 0.000001 && other.start < end - 0.000001 }

    func snapped(fps: Double) -> LayoutSpan {
        var span = self
        span.start = snapToFrame(start, fps: fps)
        span.end = snapToFrame(end, fps: fps)
        return span
    }

    func problem(duration timeline: Double, fps: Double) -> String? {
        guard start.isFinite, end.isFinite else { return "A layout's start and end must be finite numbers." }
        guard start >= 0, end <= timeline + 0.0005 else {
            return "A layout must lie within the edited recording (0–\(String(format: "%.2f", timeline)) s)."
        }
        guard duration >= 1 / max(1, fps) - 0.000001 else { return "A layout must last at least one frame." }
        return nil
    }
}

/// The speaker's round picture in the Screen layout.
struct SpeakerBubble: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    var corner = Corner.bottomRight
    /// The bubble's diameter as a fraction of the frame's height.
    var size = SpeakerBubble.defaultSize
    /// The speaker's face in the recording's source pixels. Nil puts the bubble on the
    /// middle of the picture, a little above the centre.
    var face: CGPoint?

    static let defaultSize = 0.3
    static let sizeRange = 0.15...0.5

    init(corner: Corner = .bottomRight, size: Double = SpeakerBubble.defaultSize, face: CGPoint? = nil) {
        self.corner = corner; self.size = size; self.face = face
    }

    enum CodingKeys: String, CodingKey { case corner, size, face }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        corner = try values.decodeIfPresent(Corner.self, forKey: .corner) ?? .bottomRight
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize
        face = try values.decodeIfPresent(CGPoint.self, forKey: .face)
    }
}

/// A screen recording shown with the speaker's recording. The speaker is the master: its
/// audio, sections and edits drive both pictures, and the screen follows its source time.
struct ScreenTrack: Codable, Equatable {
    var url: URL
    var info: MediaInfo
    /// The screen recording's time at the speaker's source time 0: screen time = speaker
    /// source time + offset.
    var offset: Double = 0
    /// The part of the screen recording to show, in its pixels; nil shows all of it.
    var crop: CGRect?
    /// The layout wherever no span says otherwise.
    var layout = ScreenLayout.screen
    /// Sorted by start; they may touch but not overlap.
    var spans: [LayoutSpan] = []
    var bubble = SpeakerBubble()
    /// Push-ins on the screen: edited-recording seconds, targets in the screen recording's
    /// pixels. Sorted and non-overlapping, like the recording's own zooms.
    var zooms: [ZoomShot] = []

    /// How long a change of layout takes, in seconds.
    static let transition = 0.4
    static let maximumOffset = 86_400.0

    init(url: URL, info: MediaInfo, offset: Double = 0) {
        self.url = url; self.info = info; self.offset = offset
    }

    enum CodingKeys: String, CodingKey { case url, info, offset, crop, layout, spans, bubble, zooms }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        info = try values.decode(MediaInfo.self, forKey: .info)
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        crop = try values.decodeIfPresent(CGRect.self, forKey: .crop)
        layout = try values.decodeIfPresent(ScreenLayout.self, forKey: .layout) ?? .screen
        spans = try values.decodeIfPresent([LayoutSpan].self, forKey: .spans) ?? []
        bubble = try values.decodeIfPresent(SpeakerBubble.self, forKey: .bubble) ?? SpeakerBubble()
        zooms = try values.decodeIfPresent([ZoomShot].self, forKey: .zooms) ?? []
    }

    var name: String { url.lastPathComponent }

    /// The part of the screen recording shown, in whole, even pixels.
    var picture: CGRect { (crop ?? info.fullFrame).evenClamped(in: info.fullFrame) }

    /// The screen recording's time for a speaker source time.
    func screenTime(forSource source: Double) -> Double { source + offset }

    /// The edited times that show real screen footage; outside them the screen holds its
    /// first or last frame.
    func covered(on timeline: ClipTimeline) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var position = 0.0
        for segment in timeline.segments {
            let from = max(segment.start, -offset), to = min(segment.end, info.duration - offset)
            if to > from {
                let range = (position + (from - segment.start) / segment.speed)...(position + (to - segment.start) / segment.speed)
                if let last = ranges.last, abs(last.upperBound - range.lowerBound) < 0.0005 {
                    ranges[ranges.count - 1] = last.lowerBound...range.upperBound
                } else {
                    ranges.append(range)
                }
            }
            position += segment.duration
        }
        return ranges
    }

    /// Everything that must hold for this screen on a recording `duration` seconds long
    /// after edits, at `speaker`'s size and frame rate, or the reason it does not.
    func problem(duration: Double, speaker: MediaInfo) -> String? {
        guard url.isFileURL else { return "A screen recording must be a local file." }
        guard info.width >= 16, info.height >= 16, info.duration.isFinite, info.duration > 0, info.fps.isFinite, info.fps > 0 else {
            return "The screen recording's media information is invalid."
        }
        guard info.rotation == 0 else { return "A rotated screen recording cannot be shown with the speaker yet." }
        guard !info.isHDR else { return "The screen recording is HDR (\(info.hdrLabel ?? "HDR")). Record the screen in standard colour." }
        guard speaker.rotation == 0 else { return "The speaker's recording is rotated. A screen can only go with an unrotated recording." }
        guard offset.isFinite, abs(offset) <= Self.maximumOffset else { return "The screen's offset must be a finite number of seconds within a day." }
        if let crop {
            guard crop.minX.isFinite, crop.minY.isFinite, crop.width.isFinite, crop.height.isFinite,
                  crop.width >= 16, crop.height >= 16, info.fullFrame.contains(crop) else {
                return "The screen's crop must be at least 16 pixels and lie inside the \(info.width)×\(info.height) screen recording."
            }
        }
        guard bubble.size.isFinite, SpeakerBubble.sizeRange.contains(bubble.size) else {
            return "The bubble's size must be from \(SpeakerBubble.sizeRange.lowerBound) to \(SpeakerBubble.sizeRange.upperBound) of the frame's height."
        }
        if let face = bubble.face {
            guard face.x.isFinite, face.y.isFinite, (0...CGFloat(speaker.width)).contains(face.x), (0...CGFloat(speaker.height)).contains(face.y) else {
                return "The speaker's face must be inside the \(speaker.width)×\(speaker.height) recording."
            }
        }
        guard Set(spans.map(\.id)).count == spans.count else { return "Two layouts have the same ID." }
        if let problem = spans.lazy.compactMap({ $0.problem(duration: duration, fps: speaker.fps) }).first { return problem }
        let ordered = spans.sorted { $0.start < $1.start }
        if let pair = zip(ordered, ordered.dropFirst()).first(where: { $0.0.overlaps($0.1) }) {
            return String(format: "The layout at %.2f–%.2f s overlaps the one at %.2f–%.2f s. Layouts may touch but not overlap.",
                          pair.1.start, pair.1.end, pair.0.start, pair.0.end)
        }
        return zoomProblem(duration: duration)
    }

    /// Why the screen's zooms cannot stand, if they cannot.
    func zoomProblem(duration: Double) -> String? {
        guard Set(zooms.map(\.id)).count == zooms.count else { return "Two screen zooms have the same ID." }
        for zoom in zooms {
            guard zoom.start.isFinite, zoom.hold.isFinite, zoom.level.isFinite, zoom.target.x.isFinite, zoom.target.y.isFinite else {
                return "Screen zoom values must be finite numbers."
            }
            guard zoom.start >= 0, zoom.end <= duration + 0.001 else {
                return String(format: "A screen zoom must fit inside the edited recording (%.2f s), including its %.2f s ease in and out.", duration, ZoomShot.ease)
            }
            guard zoom.hold >= 0.2 else { return "A screen zoom must hold for at least 0.2 s." }
            guard (1...10).contains(zoom.level) else { return "A screen zoom's level must be between 1× and 10×." }
            guard (0...CGFloat(info.width)).contains(zoom.target.x), (0...CGFloat(info.height)).contains(zoom.target.y) else {
                return "A screen zoom's target must be inside the \(info.width)×\(info.height) screen recording."
            }
        }
        let ordered = zooms.sorted { $0.start < $1.start }
        if let pair = zip(ordered, ordered.dropFirst()).first(where: { $0.0.overlaps($0.1) }) {
            return String(format: "The screen zoom at %.2f s overlaps the one at %.2f s.", pair.1.start, pair.0.start)
        }
        return nil
    }

    /// The part of the screen's picture shown at an edited time, in the picture's pixels
    /// (top-left origin): all of it, or a zoom's window. The same sums as a recording's own
    /// zooms (`renderFrame`, `FFmpeg.zoomFilter`): the zoom and the aim ease in together,
    /// and the window stays inside the picture.
    func zoomWindow(at time: Double) -> CGRect {
        let size = picture.size
        guard let shot = zooms.first(where: { time >= $0.start && time < $0.end }) else { return CGRect(origin: .zero, size: size) }
        let phase = min(1, max(0, min((time - shot.start) / ZoomShot.ease, (shot.end - time) / ZoomShot.ease)))
        let ramp = phase * phase * (3 - 2 * phase)
        let zoom = 1 + (shot.level - 1) * ramp
        let w = Double(size.width), h = Double(size.height)
        let cx = w / 2 + (Double(shot.target.x - picture.minX) - w / 2) * ramp
        let cy = h / 2 + (Double(shot.target.y - picture.minY) - h / 2) * ramp
        let width = w / zoom, height = h / zoom
        return CGRect(x: max(0, min(cx - width / 2, w - width)), y: max(0, min(cy - height / 2, h - height)), width: width, height: height)
    }

    /// Where a point of the frame falls on the screen recording at an edited time, in its
    /// pixels, through the layout and any zoom; nil off the screen.
    func screenPoint(_ point: CGPoint, at time: Double, geometry: LayoutGeometry, endScreen: Double?) -> CGPoint? {
        guard let place = state(at: time, geometry: geometry, endScreen: endScreen).screen, place.rect.contains(point) else { return nil }
        let window = zoomWindow(at: time)
        let u = (point.x - place.rect.minX) / place.rect.width, v = (point.y - place.rect.minY) / place.rect.height
        return CGPoint(x: picture.minX + window.minX + u * window.width, y: picture.minY + window.minY + v * window.height)
    }

    // MARK: Layout over time

    /// The layout in force at `time`, before any easing: Speaker from the end screen's
    /// start, so the end screen moves the speaker into its frame; else the span's; else
    /// the base layout.
    func layout(at time: Double, endScreen: Double?) -> ScreenLayout {
        if let endScreen, time >= endScreen - 0.000001 { return .speaker }
        return spans.first { time >= $0.start - 0.000001 && time < $0.end - 0.000001 }?.layout ?? layout
    }

    /// Each moment the layout changes, in time order, with the layout it changes to.
    func changes(endScreen: Double?) -> [(time: Double, to: ScreenLayout)] {
        var times = spans.flatMap { [$0.start, $0.end] }
        if let endScreen { times.append(endScreen) }
        var result: [(time: Double, to: ScreenLayout)] = []
        for time in Set(times.map { ($0 * 1_000_000).rounded() / 1_000_000 }).sorted() where time > 0.000001 {
            let before = layout(at: time - 0.00001, endScreen: endScreen), after = layout(at: time, endScreen: endScreen)
            if before != after { result.append((time, after)) }
        }
        return result
    }

    /// Both pictures' places at an edited time. A change eases over `transition` seconds
    /// from its moment; a change that comes while another eases starts from where that
    /// one has got to.
    func state(at time: Double, geometry: LayoutGeometry, endScreen: Double?) -> LayoutState {
        var target = layout(at: 0, endScreen: endScreen)
        var from = geometry.held(target)
        var since: Double?
        func now(_ moment: Double) -> LayoutState {
            guard let since, moment - since < Self.transition else { return geometry.held(target) }
            return geometry.mix(from, geometry.held(target), amount: Self.ease((moment - since) / Self.transition))
        }
        for change in changes(endScreen: endScreen) where change.time <= time + 0.000001 {
            from = now(change.time)
            target = change.to
            since = change.time
        }
        return now(time)
    }

    /// Smoothstep: starts and stops gently, as zooms do.
    static func ease(_ u: Double) -> Double {
        let t = min(1, max(0, u))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Geometry

/// Where one picture goes on the frame: a whole-pixel rectangle, top-left origin, and the
/// radius of its corners. A radius of half the side makes a circle.
struct LayoutPlace: Equatable {
    var rect: CGRect
    var radius: Double
}

/// Both pictures at one moment.
struct LayoutState: Equatable {
    var speaker: LayoutPlace
    /// The part of the speaker's picture shown in `speaker`, in that picture's pixels.
    var window: CGRect
    /// Nil while the speaker covers the frame and the screen does not show.
    var screen: LayoutPlace?
}

/// The layouts' places on one frame. Sizes are design pixels of a 1920×1080 frame, scaled
/// to the real one; every place is in whole pixels with even sizes, so ffmpeg and Core
/// Image put the same pixels in the same place.
struct LayoutGeometry: Equatable {
    /// The output frame: the speaker's cropped picture.
    let frame: CGSize
    /// The screen's picture (its crop).
    let screen: CGSize
    /// The speaker's face, in the cropped picture's pixels.
    let face: CGPoint
    let bubble: SpeakerBubble

    static let screenMargin = 48.0
    static let bubbleMargin = 40.0
    static let splitMargin = 40.0
    static let splitGap = 32.0
    static let splitSpeakerWidth = 0.29
    static let cornerRadius = 16.0
    /// The bubble's window: a square this share of the picture's height, on the face.
    static let bubbleWindow = 0.6

    init(frame: CGSize, screen: CGSize, face: CGPoint, bubble: SpeakerBubble) {
        self.frame = frame; self.screen = screen; self.face = face; self.bubble = bubble
    }

    /// For a recording whose picture is `crop` of its source.
    init(track: ScreenTrack, crop: CGRect) {
        let size = crop.size
        let face = track.bubble.face.map { CGPoint(x: min(max(0, $0.x - crop.minX), size.width), y: min(max(0, $0.y - crop.minY), size.height)) }
        self.init(frame: size, screen: track.picture.size, face: face ?? CGPoint(x: size.width / 2, y: size.height * 0.42), bubble: track.bubble)
    }

    var unit: Double { min(Double(frame.width) / 1920, Double(frame.height) / 1080) }

    private static func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }

    /// The screen's place in a layout; nil in Speaker, where it does not show.
    func screenPlace(_ layout: ScreenLayout) -> LayoutPlace? {
        let w = Double(frame.width), h = Double(frame.height)
        switch layout {
        case .speaker:
            return nil
        case .screen:
            let margin = Self.screenMargin * unit
            let scale = min((w - 2 * margin) / Double(screen.width), (h - 2 * margin) / Double(screen.height))
            let width = Self.even(Double(screen.width) * scale), height = Self.even(Double(screen.height) * scale)
            return LayoutPlace(rect: CGRect(x: ((w - width) / 2).rounded(), y: ((h - height) / 2).rounded(), width: width, height: height),
                               radius: Self.cornerRadius * unit)
        case .split:
            return split.screen
        }
    }

    func speakerPlace(_ layout: ScreenLayout) -> LayoutPlace {
        let w = Double(frame.width), h = Double(frame.height)
        switch layout {
        case .speaker:
            return LayoutPlace(rect: CGRect(x: 0, y: 0, width: w, height: h), radius: 0)
        case .screen:
            let side = Self.even(bubble.size * h), margin = (Self.bubbleMargin * unit).rounded()
            let left = bubble.corner == .topLeft || bubble.corner == .bottomLeft
            let top = bubble.corner == .topLeft || bubble.corner == .topRight
            return LayoutPlace(rect: CGRect(x: left ? margin : w - margin - side, y: top ? margin : h - margin - side, width: side, height: side),
                               radius: side / 2)
        case .split:
            return split.speaker
        }
    }

    /// Side by side: the speaker's panel on the left, as tall as the screen beside it, the
    /// two centred together.
    private var split: (speaker: LayoutPlace, screen: LayoutPlace) {
        let w = Double(frame.width), h = Double(frame.height)
        let margin = Self.splitMargin * unit, gap = (Self.splitGap * unit).rounded()
        let speakerWidth = Self.even(Self.splitSpeakerWidth * w)
        let aspect = Double(screen.width) / Double(screen.height)
        var screenWidth = w - 2 * margin - gap - speakerWidth
        var screenHeight = screenWidth / aspect
        if screenHeight > h - 2 * margin { screenHeight = h - 2 * margin; screenWidth = screenHeight * aspect }
        screenWidth = Self.even(screenWidth); screenHeight = Self.even(screenHeight)
        let x = ((w - speakerWidth - gap - screenWidth) / 2).rounded(), y = ((h - screenHeight) / 2).rounded()
        let radius = Self.cornerRadius * unit
        return (LayoutPlace(rect: CGRect(x: x, y: y, width: speakerWidth, height: screenHeight), radius: radius),
                LayoutPlace(rect: CGRect(x: x + speakerWidth + gap, y: y, width: screenWidth, height: screenHeight), radius: radius))
    }

    /// The part of the speaker's picture for a place of `aspect`: `height` tall where it
    /// fits, centred on `centre`, kept inside the picture, in whole pixels.
    func window(aspect: Double, height: Double, centre: CGPoint) -> CGRect {
        let pw = Double(frame.width), ph = Double(frame.height)
        var h = min(height, ph), w = h * aspect
        if w > pw { w = pw; h = w / aspect }
        w = max(2, w.rounded()); h = max(2, h.rounded())
        let x = min(max(0, Double(centre.x) - w / 2), pw - w).rounded()
        let y = min(max(0, Double(centre.y) - h / 2), ph - h).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A layout at rest.
    func held(_ layout: ScreenLayout) -> LayoutState {
        let place = speakerPlace(layout)
        let aspect = Double(place.rect.width / place.rect.height)
        let window: CGRect
        switch layout {
        case .speaker: window = CGRect(origin: .zero, size: frame)
        case .screen: window = self.window(aspect: aspect, height: Self.bubbleWindow * Double(frame.height), centre: face)
        case .split: window = self.window(aspect: aspect, height: Double(frame.height), centre: face)
        }
        return LayoutState(speaker: place, window: window, screen: screenPlace(layout))
    }

    /// Part way from `a` to `b`. The speaker's place and corners move straight; its window
    /// keeps the place's aspect, so the picture never stretches. The screen stays where it
    /// is while the speaker covers it on one side of the change.
    func mix(_ a: LayoutState, _ b: LayoutState, amount: Double) -> LayoutState {
        let k = min(1, max(0, amount))
        if k <= 0 { return a }
        if k >= 1 { return b }
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        func rect(_ p: CGRect, _ q: CGRect) -> CGRect {
            let width = Self.even(lerp(Double(p.width), Double(q.width))), height = Self.even(lerp(Double(p.height), Double(q.height)))
            return CGRect(x: lerp(Double(p.minX), Double(q.minX)).rounded(), y: lerp(Double(p.minY), Double(q.minY)).rounded(), width: width, height: height)
        }
        let speaker = LayoutPlace(rect: rect(a.speaker.rect, b.speaker.rect), radius: lerp(a.speaker.radius, b.speaker.radius))
        let window = self.window(aspect: Double(speaker.rect.width / speaker.rect.height),
                                 height: lerp(Double(a.window.height), Double(b.window.height)),
                                 centre: CGPoint(x: lerp(Double(a.window.midX), Double(b.window.midX)), y: lerp(Double(a.window.midY), Double(b.window.midY))))
        let screen: LayoutPlace?
        switch (a.screen, b.screen) {
        case (nil, nil): screen = nil
        case (nil, let to?): screen = to
        case (let from?, nil): screen = from
        case (let from?, let to?): screen = LayoutPlace(rect: rect(from.rect, to.rect), radius: lerp(from.radius, to.radius))
        }
        return LayoutState(speaker: speaker, window: window, screen: screen)
    }
}

// MARK: - Following the footage

extension ClipTimeline {
    /// Layouts follow the frame they start on and keep their length, shortened to fit if
    /// the recording got shorter, as blur effects do. Removed footage removes the span,
    /// and a collision keeps the earlier one.
    func remap(_ spans: [LayoutSpan], from old: ClipTimeline, fps: Double) -> [LayoutSpan] {
        let frame = 1 / max(1, fps)
        var moved: [LayoutSpan] = []
        for var span in spans {
            guard let start = carry(span.start, from: old) else { continue }
            let length = span.duration
            span.start = snapToFrame(start, fps: fps)
            span.end = min(duration, span.start + length)
            guard span.duration >= frame - 0.000001 else { continue }
            moved.append(span)
        }
        var kept: [LayoutSpan] = []
        for span in moved.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) })
        where !kept.contains(where: { $0.overlaps(span) }) {
            kept.append(span)
        }
        return kept
    }
}
