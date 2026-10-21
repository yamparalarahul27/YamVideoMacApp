import CryptoKit
import Foundation

struct TimelineSegment: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var speed: Double = 1
    var sourceDuration: Double { max(0, end - start) }
    var duration: Double { sourceDuration / speed }

    enum CodingKeys: String, CodingKey { case id, start, end, speed }
    init(id: UUID = UUID(), start: Double, end: Double, speed: Double = 1) {
        self.id = id; self.start = start; self.end = end; self.speed = speed
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }
}

/// The same ordered source ranges drive the timeline, playback and export.
struct ClipTimeline: Equatable {
    var segments: [TimelineSegment]
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// How long the sound fades out before a cut and back in after it. A hard cut joins two
    /// waves wherever they are, so it clicks, and the room's hum steps up or down with it;
    /// 12 ms is too short to hear as a fade.
    static let jointFade = 0.012

    /// Whether the sound is cut between section `index - 1` and section `index`: the source
    /// jumps there. A section split where nothing was taken out plays on as one.
    static func cut(before index: Int, in segments: [TimelineSegment]) -> Bool {
        index > 0 && index < segments.count && abs(segments[index - 1].end - segments[index].start) > 0.0005
    }

    /// The edited times where the sound is cut, each with its fade's length: at most a
    /// quarter of the shorter section beside it.
    var audioJoints: [(time: Double, fade: Double)] {
        var joints: [(time: Double, fade: Double)] = []
        var time = 0.0
        for index in segments.indices {
            if Self.cut(before: index, in: segments) {
                joints.append((time, min(Self.jointFade, segments[index - 1].duration / 4, segments[index].duration / 4)))
            }
            time += segments[index].duration
        }
        return joints
    }

    func offset(of id: UUID) -> Double {
        var time = 0.0
        for segment in segments {
            if segment.id == id { return time }
            time += segment.duration
        }
        return time
    }

    func location(at time: Double) -> (index: Int, source: Double)? {
        guard !segments.isEmpty else { return nil }
        var remaining = min(max(0, time), duration)
        for (index, segment) in segments.enumerated() {
            if remaining < segment.duration || index == segments.count - 1 {
                return (index, segment.start + min(remaining, segment.duration) * segment.speed)
            }
            remaining -= segment.duration
        }
        return nil
    }

    func time(forSource source: Double) -> Double? {
        var offset = 0.0
        for segment in segments {
            if source >= segment.start && source < segment.end {
                return offset + (source - segment.start) / segment.speed
            }
            offset += segment.duration
        }
        return nil
    }

    mutating func split(at time: Double, fps: Double) -> UUID? {
        guard let location = location(at: time) else { return nil }
        let rate = max(1, fps)
        let source = (location.source * rate).rounded() / rate
        let segment = segments[location.index]
        let minimum = max(1, segment.speed) / rate
        guard source - segment.start >= minimum - 0.000001,
              segment.end - source >= minimum - 0.000001 else { return nil }
        let right = TimelineSegment(start: source, end: segment.end, speed: segment.speed)
        segments[location.index].end = source
        segments.insert(right, at: location.index + 1)
        return right.id
    }

    /// Anchor each zoom to the frame where it began. Removed anchors remove their zoom;
    /// surviving anchors follow their footage. Drop collisions introduced by reordering.
    func remap(_ shots: [ZoomShot], from old: ClipTimeline) -> [ZoomShot] {
        var candidates: [ZoomShot] = []
        for var shot in shots {
            guard let source = old.location(at: shot.start)?.source,
                  let start = time(forSource: source) else { continue }
            shot.start = start
            let available = duration - start - 2 * ZoomShot.ease
            guard available >= 0.2 else { continue }
            shot.hold = min(shot.hold, available)
            candidates.append(shot)
        }
        var result: [ZoomShot] = []
        for shot in candidates.sorted(by: { $0.start < $1.start }) {
            if !result.contains(where: { $0.overlaps(shot) }) { result.append(shot) }
        }
        return result
    }
}

/// Project files reference media; source video bytes are never changed or copied.
struct ProjectClip: Codable, Equatable {
    var id: UUID
    var url: URL
    var info: MediaInfo?
    var crop: CGRect?
    var aspectLock: CGFloat?
    var aspectLabel: String
    var blurRegions: [BlurRegion]
    var zoomShots: [ZoomShot]
    var segments: [TimelineSegment]?
    var includedInMovie: Bool?
    /// Version 3 onwards. Earlier files never stored the burned-in subtitle choice.
    var subtitles: URL?
    /// Version 4 onwards. Nil when the recording has never had its colour touched, so an
    /// untouched recording reads exactly as it did before colour existed.
    var color: ClipColorSettings?
    /// Version 5 onwards, and nil while empty, like `color`.
    var blurEffects: [VideoBlurEffect]?
    var markers: [TimelineMarker]?
    /// Version 6 onwards. Nil when the recording has no graphics.
    var graphics: GraphicsTrack?
    /// Version 8 onwards. Nil until something is written for YouTube.
    var publish: PublishInfo?
    /// Version 11 onwards. Nil until the recording is transcribed.
    var transcript: Transcript?
    /// Version 12 onwards. Nil while the recording has no Shorts.
    var shorts: [Short]?
    /// Version 14 onwards. Nil while the recording has no screen recording.
    var screen: ScreenTrack?
    /// Version 18 onwards. Changes switched off in the inspector, in a fixed order; nil
    /// while every change is on.
    var switchedOff: [SwitchableChange]?
    /// Version 20 onwards. Nil while the recording has no music.
    var music: MusicBed?
    /// Version 21 onwards. Space the timeline leaves in front of sections, in section
    /// order; nil while there is none.
    var gaps: [SectionGap]?

    init(_ item: VideoItem) {
        id = item.id; url = item.url; info = item.info; crop = item.crop
        aspectLock = item.aspectLock; aspectLabel = item.aspectLabel
        blurRegions = item.blurRegions; zoomShots = item.zoomShots; segments = item.segments
        includedInMovie = item.includedInMovie; subtitles = item.subtitles
        color = item.color.isDefault ? nil : item.color
        blurEffects = item.blurEffects.isEmpty ? nil : item.blurEffects
        markers = item.markers.isEmpty ? nil : item.markers
        graphics = item.graphics?.isEmpty == false ? item.graphics : nil
        publish = item.publish?.isEmpty == false ? item.publish : nil
        transcript = item.transcript
        shorts = item.shorts.isEmpty ? nil : item.shorts
        screen = item.screen
        switchedOff = item.switchedOff.isEmpty ? nil : item.switchedOff.sorted()
        music = item.music
        let gaps = item.gaps.sectionGaps(in: item.timeline)
        self.gaps = gaps.isEmpty ? nil : gaps
    }

    func item() -> VideoItem {
        var item = VideoItem(url: url)
        item.id = id; item.info = info; item.crop = crop
        item.aspectLock = aspectLock; item.aspectLabel = aspectLabel
        item.blurRegions = blurRegions; item.zoomShots = zoomShots; item.segments = segments
        item.includedInMovie = includedInMovie ?? true; item.subtitles = subtitles
        item.color = color ?? ClipColorSettings()
        item.blurEffects = blurEffects ?? []
        item.markers = markers ?? []
        item.graphics = graphics
        item.publish = publish
        item.transcript = transcript
        item.shorts = shorts ?? []
        item.screen = screen
        item.switchedOff = Set(switchedOff ?? [])
        item.music = music
        item.gaps = gaps?.lengths ?? [:]
        item.previewFraction = 0
        item.status = info == nil ? .probing : .ready
        return item
    }
}

/// One step in a project's history: when, who, and what the Undo menu called it.
struct ChangeLogEntry: Codable, Equatable {
    enum Kind: String, Codable { case edit, undo, redo, export }
    var date: Date
    /// "You", or the agent's name.
    var by: String
    var label: String
    var kind: Kind

    static let limit = 2000
    static let notesLimit = 50_000
}

struct VideoProject: Codable, Equatable {
    /// 1: crop, blur and zoom. 2: adds section speed. 3: adds a stable project identity
    /// and the per-recording subtitle file. 4: adds per-recording colour. 5: adds
    /// whole-frame blur effects and timeline markers. 6: adds per-recording graphics. 7: adds
    /// a graphic's move and scale on the picture. 8: adds what YouTube needs per recording.
    /// 9: adds the thumbnail maker's design. 10: adds the end screen graphic and the choice of
    /// YouTube element for each of its boxes. 11: adds the auto edit options, each recording's
    /// transcript and the captions choice. 12: adds each recording's Shorts. 13: adds a
    /// Short's zoom (zoomed out, at the top over a blurred copy). 14: adds a recording's
    /// screen recording and its layouts. 15: adds the project's Why notes and its history
    /// of changes. 16: adds the graphics style's size, for phones. 17: adds the thumbnail
    /// maker's picture size and its white frost background. 18: adds the changes a
    /// recording has switched off in the inspector. 19: adds the thumbnail's versions for
    /// YouTube's Test & Compare and the winner. 20: adds a recording's background music. 21: adds the
    /// space the timeline leaves where a section was deleted, trimmed or moved. 22: adds the
    /// music's duck, down under speech and up in pauses. Every edited
    /// project is written as the current version; older builds reject it rather than
    /// silently dropping edits.
    static let currentVersion = 22
    static let supportedVersions = 1...currentVersion

    var version = VideoProject.currentVersion
    /// Persistent identity, so a local agent can never address the wrong document.
    /// Nil only in files older than version 3, until `migrated` assigns one; decoding
    /// never invents it, so validation can tell a legacy file from a damaged one.
    var projectID: UUID? = UUID()
    var clips: [ProjectClip]
    var settings: ExportSettings
    var selection: UUID?
    var movieSettings: MovieSettings?
    /// Version 11 onwards. Nil until the owner or an agent answers them.
    var autoEdit: AutoEditOptions? = nil
    /// Version 15 onwards: why the video is edited the way it is, as Markdown, written by
    /// the owner and agents. Video.md shows it.
    var notes: String? = nil
    /// Version 15 onwards: every step that changed the project, oldest first, kept apart
    /// from undo so undoing never forgets that a step happened.
    var log: [ChangeLogEntry]? = nil

    /// Reads, validates and upgrades a project file in one step. A pre-identity file gets
    /// an identity derived from its own bytes, so opening the same unsaved legacy file
    /// twice yields the same project rather than a new one each time; saving persists it.
    static func decodeMigrating(from data: Data) throws -> VideoProject {
        let decoded = try JSONDecoder().decode(VideoProject.self, from: data)
        try decoded.validate()
        return decoded.migrated(identity: UUID(deterministicFrom: data))
    }

    /// The same project at the current version. Only fields older versions lacked are
    /// filled in; nothing the file did say is changed.
    func migrated(identity: @autoclosure () -> UUID = UUID()) -> VideoProject {
        var upgraded = self
        if upgraded.projectID == nil { upgraded.projectID = identity() }
        upgraded.version = Self.currentVersion
        return upgraded
    }

    func validate() throws {
        func reject(_ message: String) throws { throw FFmpegError(message: message) }
        guard Self.supportedVersions.contains(version) else {
            try reject(version > Self.currentVersion
                ? "This project was saved by a newer version of YamVideo."
                : "This project version is not supported."); return
        }
        if version < 3 {
            // An older schema cannot carry newer fields; a file claiming otherwise is not
            // something any build wrote, and reading it either way could lose edits.
            guard projectID == nil, clips.allSatisfy({ $0.subtitles == nil }) else {
                try reject("The project claims an older format but contains newer data."); return
            }
        } else {
            guard projectID != nil else { try reject("The project is missing its identity."); return }
        }
        if version < 4, clips.contains(where: { $0.color != nil }) {
            try reject("The project claims an older format but contains colour settings."); return
        }
        if version < 5, clips.contains(where: { $0.blurEffects != nil || $0.markers != nil }) {
            try reject("The project claims an older format but contains blur effects or markers."); return
        }
        if version < 6, clips.contains(where: { $0.graphics != nil }) {
            try reject("The project claims an older format but contains graphics."); return
        }
        if version < 7, clips.contains(where: { $0.graphics?.items.contains { $0.transform != nil } == true }) {
            try reject("The project claims an older format but contains graphics moved on the picture."); return
        }
        if version < 8, clips.contains(where: { $0.publish != nil }) {
            try reject("The project claims an older format but contains publishing details."); return
        }
        if version < 9, clips.contains(where: { $0.publish?.design != nil }) {
            try reject("The project claims an older format but contains a thumbnail design."); return
        }
        if version < 10, clips.contains(where: { $0.publish?.endScreen != nil || $0.graphics?.endScreen != nil }) {
            try reject("The project claims an older format but contains an end screen."); return
        }
        if version < 11, autoEdit != nil || settings.captions != nil || clips.contains(where: { $0.transcript != nil }) {
            try reject("The project claims an older format but contains auto edit options, a transcript or a captions choice."); return
        }
        if version < 12, clips.contains(where: { $0.shorts != nil }) {
            try reject("The project claims an older format but contains Shorts."); return
        }
        if version < 13, clips.contains(where: { $0.shorts?.contains { $0.zoom != nil } == true }) {
            try reject("The project claims an older format but contains a zoomed-out Short."); return
        }
        if version < 14, clips.contains(where: { $0.screen != nil }) {
            try reject("The project claims an older format but contains a screen recording."); return
        }
        if version < 15, notes != nil || log != nil {
            try reject("The project claims an older format but contains notes or a history of changes."); return
        }
        if version < 16, clips.contains(where: { $0.graphics?.style.size != nil }) {
            try reject("The project claims an older format but contains a graphics size."); return
        }
        if version < 17, clips.contains(where: { $0.publish?.design.map { $0.imageSize != 1 || $0.background == .frost } == true }) {
            try reject("The project claims an older format but contains a thumbnail picture size or the white frost."); return
        }
        if version < 18, clips.contains(where: { $0.switchedOff != nil }) {
            try reject("The project claims an older format but contains changes switched off."); return
        }
        if version < 19, clips.contains(where: { $0.publish?.test != nil }) {
            try reject("The project claims an older format but contains thumbnail versions for Test & Compare."); return
        }
        if version < 20, clips.contains(where: { $0.music != nil || $0.switchedOff?.contains(.music) == true }) {
            try reject("The project claims an older format but contains music."); return
        }
        if version < 21, clips.contains(where: { $0.gaps != nil }) {
            try reject("The project claims an older format but contains gaps on the timeline."); return
        }
        if version < 22, clips.contains(where: { $0.music?.duck != nil }) {
            try reject("The project claims an older format but contains a music duck."); return
        }
        if let notes, notes.count > ChangeLogEntry.notesLimit { try reject("The project's notes are longer than \(ChangeLogEntry.notesLimit) characters."); return }
        if let log, log.count > ChangeLogEntry.limit { try reject("The project's history has more than \(ChangeLogEntry.limit) steps."); return }
        if let problem = autoEdit?.problem { try reject("The project's auto edit options are invalid: \(problem)"); return }
        guard Set(clips.map(\.id)).count == clips.count else {
            try reject("The project contains duplicate clip IDs."); return
        }
        guard clips.allSatisfy({ $0.subtitles?.isFileURL ?? true }) else {
            try reject("Subtitle files must be local."); return
        }
        guard settings.quality.isFinite, (0...100).contains(settings.quality),
              settings.blurStrength.isFinite, (1...100).contains(settings.blurStrength),
              ExportSettings.presets.contains(settings.preset) else {
            try reject("The project contains invalid export settings."); return
        }
        for clip in clips {
            guard clip.url.isFileURL else { try reject("Projects must reference local media."); return }
            if let color = clip.color {
                try color.validate()
                if let info = clip.info { try color.validate(against: info) }
            }
            guard let info = clip.info else {
                guard clip.segments == nil, clip.crop == nil, clip.blurRegions.isEmpty, clip.zoomShots.isEmpty,
                      clip.blurEffects == nil, clip.markers == nil, clip.graphics == nil, clip.transcript == nil, clip.shorts == nil,
                      clip.screen == nil, clip.music == nil, clip.gaps == nil else {
                    try reject("The project is missing information required by its edits."); return
                }
                continue
            }
            guard info.width >= 16, info.height >= 16, info.duration.isFinite, info.duration > 0,
                  info.fps.isFinite, info.fps > 0 else {
                try reject("The project contains invalid media information."); return
            }
            let ranges = clip.segments ?? [TimelineSegment(start: 0, end: info.duration)]
            guard !ranges.isEmpty, Set(ranges.map(\.id)).count == ranges.count,
                  ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 &&
                      $0.end <= info.duration + 0.001 && $0.speed.isFinite && (0.25...4).contains($0.speed) &&
                      $0.duration > 0 && ($0.speed == 1 || $0.duration >= 1 / info.fps - 0.000001) }) else {
                try reject("The project contains invalid video sections."); return
            }
            if let gaps = clip.gaps {
                let sections = Set(clip.timeline.segments.map(\.id))
                guard !gaps.isEmpty, Set(gaps.map(\.section)).count == gaps.count,
                      gaps.allSatisfy({ sections.contains($0.section) && $0.length.isFinite
                          && (SectionGap.minimum...SectionGap.maximum).contains($0.length) }) else {
                    try reject("The project contains invalid gaps on the timeline."); return
                }
            }
            let orderedRanges = ranges.sorted { $0.start < $1.start }
            guard zip(orderedRanges, orderedRanges.dropFirst()).allSatisfy({ $0.end <= $1.start + 0.000001 }),
                  Set(clip.blurRegions.map(\.id)).count == clip.blurRegions.count,
                  clip.aspectLock == nil || (clip.aspectLock!.isFinite && clip.aspectLock! > 0) else {
                try reject("The project contains overlapping sections or invalid edit data."); return
            }
            let rate = info.fpsExpression.split(separator: "/")
            let validRate: Bool
            if rate.count == 2, let numerator = Int32(rate[0]), let denominator = Int32(rate[1]) {
                validRate = numerator > 0 && denominator > 0
            } else if rate.count == 1, info.fpsExpression.allSatisfy({ "0123456789.".contains($0) }),
                      let value = Double(info.fpsExpression) {
                validRate = value.isFinite && value > 0
            } else { validRate = false }
            guard validRate else {
                try reject("The project contains an invalid frame rate."); return
            }
            let duration = ClipTimeline(segments: ranges).duration
            let shots = clip.zoomShots.sorted { $0.start < $1.start }
            guard Set(shots.map(\.id)).count == shots.count,
                  shots.allSatisfy({ $0.start.isFinite && $0.hold.isFinite && $0.level.isFinite &&
                      $0.start >= 0 && $0.hold >= 0.2 && (1...10).contains($0.level) &&
                      $0.end <= duration + 0.01 && $0.target.x.isFinite && $0.target.y.isFinite }),
                  zip(shots, shots.dropFirst()).allSatisfy({ !$0.overlaps($1) }) else {
                try reject("The project contains invalid zoom timing."); return
            }
            let effects = clip.blurEffects ?? []
            guard Set(effects.map(\.id)).count == effects.count,
                  zip(effects, effects.dropFirst()).allSatisfy({ $0.start <= $1.start && !$0.overlaps($1) }) else {
                try reject("The project contains overlapping or duplicate blur effects."); return
            }
            if let problem = effects.lazy.compactMap({ $0.problem(duration: duration, fps: info.fps) }).first {
                try reject("The project contains an invalid blur effect: \(problem)"); return
            }
            let markers = clip.markers ?? []
            guard Set(markers.map(\.id)).count == markers.count else {
                try reject("The project contains duplicate markers."); return
            }
            if let problem = markers.lazy.compactMap({ $0.problem(duration: duration) }).first {
                try reject("The project contains an invalid marker: \(problem)"); return
            }
            if let graphics = clip.graphics, let problem = graphics.problem(duration: duration) {
                try reject(problem); return
            }
            if let problem = clip.transcript?.problem(duration: info.duration) {
                try reject("The project contains an invalid transcript: \(problem)"); return
            }
            if let shorts = clip.shorts, let problem = shortsProblem(shorts, duration: duration, info: info) {
                try reject("The project contains an invalid Short: \(problem)"); return
            }
            if let problem = clip.screen?.problem(duration: duration, speaker: info) {
                try reject("The project contains an invalid screen recording: \(problem)"); return
            }
            if let problem = clip.music?.problem(duration: duration) {
                try reject("The project contains invalid music: \(problem)"); return
            }
            for area in clip.blurRegions {
                let times = [area.start, area.end].compactMap { $0 }
                guard times.allSatisfy({ $0.isFinite && $0 >= 0 }), (area.start ?? 0) < (area.end ?? .infinity) else {
                    try reject("The project contains a blur area with invalid times."); return
                }
            }
            for rect in [clip.crop].compactMap({ $0 }) + clip.blurRegions.map(\.rect) {
                guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                      rect.width > 0, rect.height > 0, info.fullFrame.contains(rect) else {
                    try reject("The project contains an invalid crop or blur area."); return
                }
            }
        }
    }
}

extension UUID {
    /// The same bytes always give the same identity: a name-based UUID (RFC 9562 version
    /// 8) built from SHA-256, used to give a legacy project file one stable identity.
    init(deterministicFrom data: Data) {
        var b = Array(SHA256.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

func timelineTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.00" }
    let centiseconds = Int((max(0, seconds) * 100).rounded())
    return String(format: "%02d:%02d.%02d", centiseconds / 6000,
                  (centiseconds / 100) % 60, centiseconds % 100)
}

// MARK: - Ruler

/// Tick spacing for the timeline ruler.
///
/// A fixed number of ticks is wrong at every magnification but one: zooming in spreads
/// the same labels further apart, so most of the visible timeline ends up with no time
/// reference at all. The interval is therefore chosen from the pixels-per-second on
/// screen, so labels stay a readable distance apart however far the timeline is zoomed.
enum TimelineRuler {
    /// Seconds between labelled ticks from half a second up, finest first.
    static let coarseIntervals: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// Below half a second the rungs are derived from the clip rather than fixed, so
    /// every label lands on a whole frame. A fixed rung is a frame count only for the
    /// frame rate it was written for: 0.04s is one frame at 25fps but 1.2 frames at
    /// 30fps, which labels frames 1, 2, 4 and skips 3.
    static func intervals(fps: Double) -> [Double] {
        let rate = fps > 0 && fps.isFinite ? fps : 30
        return [1, 2, 5, 10].map { $0 / rate }.filter { $0 < coarseIntervals[0] } + coarseIntervals
    }

    /// The closest two labels may sit, in points. The ladder steps by at most 2.5×, so
    /// the chosen spacing lands between this and roughly 200 points.
    static let minimumSpacing = 80.0

    /// Minor ticks subdivide the interval, and are drawn only when they stay this far
    /// apart. Below that they read as a grey smear rather than as ticks.
    static let minorDivisions = 5
    static let minimumMinorSpacing = 6.0

    /// The finest interval whose labels still clear `minimumSpacing`, or the coarsest
    /// available when even that is too dense to label.
    static func interval(pixelsPerSecond: Double, fps: Double) -> Double {
        let ladder = intervals(fps: fps)
        guard pixelsPerSecond > 0, pixelsPerSecond.isFinite else { return ladder[ladder.count - 1] }
        return ladder.first { $0 * pixelsPerSecond >= minimumSpacing } ?? ladder[ladder.count - 1]
    }

    /// Nil when subdividing would put the minor ticks closer than `minimumMinorSpacing`.
    static func minorInterval(_ interval: Double, pixelsPerSecond: Double) -> Double? {
        let step = interval / Double(minorDivisions)
        return step * pixelsPerSecond >= minimumMinorSpacing ? step : nil
    }

    /// Every multiple of `step` falling inside `range`, inclusive of both ends.
    static func ticks(every step: Double, in range: ClosedRange<Double>) -> [Double] {
        guard step > 0, step.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite else { return [] }
        let first = Int((range.lowerBound / step).rounded(.up))
        let last = Int((range.upperBound / step).rounded(.down))
        // A guard against a pathological zoom asking for more views than can be drawn.
        guard last >= first, last - first < 20_000 else { return [] }
        return (first...last).map { Double($0) * step }
    }

    /// Ruler labels drop the centiseconds `timelineTime` carries: at one second apart or
    /// coarser they are noise. Below a second the frame number is the only thing that
    /// distinguishes one tick from the next, so it replaces them.
    static func label(_ seconds: Double, interval: Double, fps: Double) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        if interval >= 1 {
            let total = Int(clamped.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let rate = max(1, Int((fps > 0 && fps.isFinite ? fps : 30).rounded()))
        let frames = Int((clamped * Double(rate)).rounded())
        return String(format: "%d:%02d.%02d", frames / (rate * 60), (frames / rate) % 60, frames % rate)
    }
}

// MARK: - Viewport

/// The slice of the edited timeline currently on screen.
///
/// The timeline does not scroll a wide canvas behind a window; it draws exactly the
/// visible span across the width it is given. Zooming narrows the span and panning
/// slides it, which is what lets a zoom hold a chosen moment still: there is no scroll
/// offset to chase afterwards. It also means a long recording never builds views for
/// footage that is off screen.
///
/// The row can be longer than the edit: space left where a section was deleted, trimmed
/// or moved (`gaps`). `start`, `visible` and `total` are measured along the row; every
/// time given to or taken from the viewport is edited time, which has no gaps, so the
/// rows above and below the sections line up with their footage.
struct TimelineViewport: Equatable {
    /// Length of the whole row: the edited timeline and its gaps.
    private(set) var total: Double
    /// Seconds of row spanned by the viewport's width.
    private(set) var visible: Double
    /// The place on the row at the viewport's left edge.
    private(set) var start: Double
    /// The space on the row in front of sections.
    private(set) var gaps = TimelineGapLayout()

    /// The finest zoom offered: a sixtieth of the recording across the width. At a
    /// typical pane width that is frame-level on a short clip and ten-second ticks on
    /// an hour of footage.
    static let maximumScale = 60.0

    /// The factor one press of zoom in or out applies. 1.5 crosses the whole range in
    /// about ten presses, which is fine enough to aim with and coarse enough to travel.
    static let step = 1.5

    init(total: Double, gaps: TimelineGapLayout = TimelineGapLayout()) {
        self.gaps = gaps
        self.total = max(0.001, total + gaps.total)
        visible = self.total
        start = 0
    }

    /// 1 fits the whole recording; `maximumScale` is as far in as the timeline goes.
    var scale: Double { total / visible }
    var end: Double { start + visible }
    /// The edited times at the left and right edges.
    var editedStart: Double { gaps.edited(start) }
    var editedEnd: Double { gaps.edited(end) }
    /// The edited time in the middle of the view.
    var editedMiddle: Double { gaps.edited(start + visible / 2) }

    func pixels(across width: Double) -> Double { width / visible }
    /// Points from the left edge to `time`. A time where a gap opens is the first frame
    /// after it.
    func x(of time: Double, across width: Double) -> Double { (gaps.display(time) - start) * pixels(across: width) }
    /// Points from the left edge to where something ending at `time` ends: before a gap
    /// that opens there.
    func x(ofEnd time: Double, across width: Double) -> Double { (gaps.display(time, end: true) - start) * pixels(across: width) }
    /// Points from `from` to `to`, gaps between them included.
    func width(from: Double, to: Double, across width: Double) -> Double {
        x(ofEnd: to, across: width) - x(of: from, across: width)
    }
    /// The edited time `x` points from the left edge. In a gap, that is where the
    /// sections either side of it meet.
    func time(atX x: Double, across width: Double) -> Double { gaps.edited(start + x / pixels(across: width)) }
    /// Whether `x` points from the left edge is in a gap.
    func inGap(atX x: Double, across width: Double) -> Bool { gaps.inGap(start + x / pixels(across: width)) }

    func contains(_ time: Double) -> Bool {
        let place = gaps.display(time)
        return place >= start && place <= end
    }
    /// True when any part of `from...to` is on screen, so it is worth building.
    func intersects(_ from: Double, _ to: Double) -> Bool { gaps.display(to, end: true) >= start && gaps.display(from) <= end }

    /// Follow an edit that changed the timeline's length or its gaps, holding the left edge.
    mutating func resize(total newTotal: Double, gaps newGaps: TimelineGapLayout = TimelineGapLayout()) {
        gaps = newGaps
        total = max(0.001, (newTotal.isFinite ? newTotal : 0.001) + newGaps.total)
        normalise()
    }

    /// Zoom so `anchor` (edited time) stays at the same point across the width. At the
    /// ends the window runs out of timeline to give, and the anchor drifts rather than
    /// the viewport scrolling past the recording.
    mutating func zoom(to newScale: Double, keeping anchor: Double) {
        let place = gaps.display(anchor)
        let fraction = visible > 0 ? min(1, max(0, (place - start) / visible)) : 0.5
        visible = total / min(Self.maximumScale, max(1, newScale.isFinite ? newScale : 1))
        start = place - fraction * visible
        normalise()
    }

    mutating func zoom(by factor: Double, keeping anchor: Double) {
        zoom(to: scale * factor, keeping: anchor)
    }

    /// Back to the whole recording.
    mutating func fit() {
        visible = total
        start = 0
    }

    /// Slide the window `seconds` along the row, stopping at either end.
    mutating func pan(by seconds: Double) {
        start += seconds.isFinite ? seconds : 0
        normalise()
    }

    /// Bring `time` into view without changing the zoom — how the timeline follows the
    /// playhead during playback. Already-visible times outside the margin do not move.
    mutating func reveal(_ time: Double, margin: Double = 0.12) {
        let place = gaps.display(time)
        let inset = visible * min(0.5, max(0, margin))
        if place < start + inset { start = place - inset }
        else if place > end - inset { start = place - visible + inset }
        normalise()
    }

    private mutating func normalise() {
        let span = visible.isFinite ? visible : total
        visible = min(total, max(total / Self.maximumScale, span))
        start = min(total - visible, max(0, start.isFinite ? start : 0))
    }
}

// MARK: - Snapping

/// What a dragged edge lines up with as it nears it.
///
/// The pull is a fixed distance on screen, not a time. Across a whole recording it
/// reaches a second or more; zoomed in to frames it reaches less than one, so snapping
/// fades out exactly where you are placing things by hand.
struct TimelineSnapping {
    /// What a target is. When two are equally close the earlier kind wins: the playhead
    /// is the one thing deliberately put somewhere to be lined up with.
    enum Kind: Int, Comparable {
        case playhead, sectionBoundary, zoomEdge, effectEdge, marker, timelineEnd
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Target: Equatable {
        var time: Double
        var kind: Kind
    }

    /// How close, in points, an edge comes before it is pulled in.
    static let threshold = 8.0
    /// Distances closer than this, in points, are a tie decided by `Kind`: below what
    /// a screen can show, the nearer of two is an accident of arithmetic.
    static let tie = 0.5

    let targets: [Target]

    /// Everything on the timeline as drawn. `playhead` is nil while the playhead itself
    /// is what is moving; `excluding` leaves out the zoom or effect being dragged, whose
    /// own edges travel with it.
    init(timeline: ClipTimeline, zooms: [ZoomShot], effects: [VideoBlurEffect] = [], markers: [TimelineMarker] = [],
         playhead: Double?, excluding: UUID? = nil) {
        var targets: [Target] = []
        if let playhead, playhead.isFinite { targets.append(Target(time: playhead, kind: .playhead)) }
        var offset = 0.0
        for segment in timeline.segments.dropLast() {
            offset += segment.duration
            targets.append(Target(time: offset, kind: .sectionBoundary))
        }
        for shot in zooms where shot.id != excluding {
            targets.append(Target(time: shot.start, kind: .zoomEdge))
            targets.append(Target(time: shot.end, kind: .zoomEdge))
        }
        for effect in effects where effect.id != excluding {
            targets.append(Target(time: effect.start, kind: .effectEdge))
            targets.append(Target(time: effect.end, kind: .effectEdge))
        }
        targets += markers.map { Target(time: $0.time, kind: .marker) }
        targets.append(Target(time: 0, kind: .timelineEnd))
        targets.append(Target(time: timeline.duration, kind: .timelineEnd))
        self.targets = targets
    }

    /// How far snapping reaches, in seconds, at this magnification.
    static func reach(pixelsPerSecond: Double) -> Double {
        pixelsPerSecond > 0 && pixelsPerSecond.isFinite ? threshold / pixelsPerSecond : 0
    }

    /// The target `time` is pulled to, or nil when none is within reach. `within` limits
    /// the targets to a span, inclusive of its ends.
    func target(for time: Double, pixelsPerSecond: Double, within range: ClosedRange<Double>? = nil) -> Target? {
        let reach = Self.reach(pixelsPerSecond: pixelsPerSecond)
        guard reach > 0, time.isFinite else { return nil }
        let tie = Self.tie / pixelsPerSecond
        var best: (target: Target, distance: Double)?
        for target in targets {
            if let range, target.time < range.lowerBound - 0.000001 || target.time > range.upperBound + 0.000001 { continue }
            let distance = abs(target.time - time)
            guard distance <= reach else { continue }
            if let current = best {
                let closer = distance < current.distance - tie
                let tied = abs(distance - current.distance) <= tie
                guard closer || (tied && target.kind < current.target.kind) else { continue }
            }
            best = (target, distance)
        }
        return best?.target
    }

    /// A span moved whole, such as a zoom: whichever edge is nearer a target is pulled
    /// to it, and the span keeps its length. `target` is nil when neither edge snapped.
    func snapSpan(start: Double, duration: Double, pixelsPerSecond: Double) -> (start: Double, target: Target?) {
        let leading = target(for: start, pixelsPerSecond: pixelsPerSecond)
        let trailing = target(for: start + duration, pixelsPerSecond: pixelsPerSecond)
        switch (leading, trailing) {
        case let (lead?, trail?):
            let leadDistance = abs(lead.time - start), trailDistance = abs(trail.time - (start + duration))
            let tie = Self.tie / pixelsPerSecond
            let trailWins = trailDistance < leadDistance - tie
                || (abs(trailDistance - leadDistance) <= tie && trail.kind < lead.kind)
            return trailWins ? (trail.time - duration, trail) : (lead.time, lead)
        case let (lead?, nil): return (lead.time, lead)
        case let (nil, trail?): return (trail.time - duration, trail)
        case (nil, nil): return (start, nil)
        }
    }
}

// MARK: - Section selection

/// The selected sections of one recording.
///
/// A set has no order, so anything that needs one, such as a range or a list of
/// commands, takes it from the timeline instead. The anchor is the section clicked
/// last: ⇧-click extends from it, and controls that work on one section act on it.
struct SectionSelection: Equatable {
    private(set) var ids: Set<UUID> = []
    /// One of `ids`, or nil exactly when `ids` is empty.
    private(set) var anchor: UUID?

    init() {}

    init(_ ids: Set<UUID>, anchor: UUID?) {
        self.ids = ids
        self.anchor = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? ids.min { $0.uuidString < $1.uuidString }
    }

    static func single(_ id: UUID?) -> SectionSelection {
        SectionSelection(id.map { [$0] } ?? [], anchor: id)
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// The selected sections in the order they play.
    func ordered(in timeline: ClipTimeline) -> [TimelineSegment] {
        timeline.segments.filter { ids.contains($0.id) }
    }

    /// A click: plain selects one section, ⇧ selects every section from the anchor to
    /// this one in timeline order, ⌘ adds or removes one.
    func clicking(_ id: UUID, extend: Bool, toggle: Bool, in timeline: ClipTimeline) -> SectionSelection {
        if toggle {
            guard ids.contains(id) else { return SectionSelection(ids.union([id]), anchor: id) }
            let remaining = ids.subtracting([id])
            // Losing the anchor hands it to the nearest section still selected, so the
            // next ⇧-click extends from somewhere you can see.
            let anchor = anchor == id ? nearest(to: id, among: remaining, in: timeline) : anchor
            return SectionSelection(remaining, anchor: anchor)
        }
        guard extend, let anchor,
              let from = timeline.segments.firstIndex(where: { $0.id == anchor }),
              let to = timeline.segments.firstIndex(where: { $0.id == id }) else { return .single(id) }
        let range = timeline.segments[min(from, to)...max(from, to)].map(\.id)
        return SectionSelection(Set(range), anchor: anchor)
    }

    /// Every section, keeping the anchor where there is one.
    static func all(in timeline: ClipTimeline, anchor: UUID?) -> SectionSelection {
        SectionSelection(Set(timeline.segments.map(\.id)), anchor: anchor ?? timeline.segments.first?.id)
    }

    /// Only the sections `timeline` still has; an edit may have removed some.
    func keeping(_ timeline: ClipTimeline?) -> SectionSelection {
        let present = Set(timeline?.segments.map(\.id) ?? [])
        guard !ids.isSubset(of: present) else { return self }
        let remaining = ids.intersection(present)
        return SectionSelection(remaining, anchor: anchor.flatMap { present.contains($0) ? $0 : nil }
                                ?? timeline?.segments.first { remaining.contains($0.id) }?.id)
    }

    private func nearest(to id: UUID, among candidates: Set<UUID>, in timeline: ClipTimeline) -> UUID? {
        guard let index = timeline.segments.firstIndex(where: { $0.id == id }) else { return candidates.first }
        return timeline.segments.indices
            .filter { candidates.contains(timeline.segments[$0].id) }
            .min { abs($0 - index) < abs($1 - index) }
            .map { timeline.segments[$0].id }
    }
}
