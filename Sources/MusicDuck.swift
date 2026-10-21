import Foundation

// MARK: - Duck (docs/plans/background-music.md, part 2)
//
// The music goes down under speech and up in pauses. The gain points come from the words of
// the transcript (with no transcript, from the sound levels), so the music goes down before
// the first word. The preview and the export play the same points: between two points the
// volume moves in a straight line, as the preview's volume ramps do.

/// How the music of a recording ducks under speech. Version 22 onwards; nil is off.
struct MusicDuck: Codable, Equatable {
    /// How far the music goes up in a pause, in dB over its level under speech.
    var lift = MusicDuck.defaultLift

    static let defaultLift = 8.0
    static let lifts = 0.0...12.0
    /// Words closer than this are one run of speech. A longer gap lifts the music.
    static let gap = 1.5
    /// The ramp down takes `down` seconds and ends `lead` before the first word of a run.
    static let lead = 0.1
    static let down = 0.3
    /// The ramp up starts `hold` after the last word of a run and takes `up` seconds.
    static let hold = 0.4
    static let up = 0.8
    /// With no transcript, sound above this level is speech (Review Silence's threshold, dB).
    static let threshold = -40.0
    /// With no transcript, loud sound shorter than this is a click or a breath, not speech.
    static let shortestSound = 0.15

    var problem: String? {
        guard lift.isFinite, Self.lifts.contains(lift) else {
            return String(format: "The music's lift must be from %.0f to %.0f dB.", Self.lifts.lowerBound, Self.lifts.upperBound)
        }
        return nil
    }

    /// Runs of speech from spans of speech (edited seconds, in any order). Spans closer than
    /// `gap` join, and so do spans with no room between them for the two ramps.
    static func runs(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let closest = max(gap, hold + up + down + lead)
        var runs: [ClosedRange<Double>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = runs.last, span.lowerBound - last.upperBound < closest {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                runs.append(span)
            }
        }
        return runs
    }

    /// The gain points of a video of `duration`: at Level under each run of speech, and
    /// `lift` dB up before the first run, between runs and after the last run.
    func envelope(runs spans: [ClosedRange<Double>], duration: Double) -> DuckEnvelope {
        let runs = Self.runs(spans).filter { $0.upperBound > 0 && $0.lowerBound < duration }
        guard lift > 0.0005, let first = runs.first else { return DuckEnvelope(points: [DuckPoint(time: 0, lift: runs.isEmpty ? lift : 0)]) }
        var points: [DuckPoint] = []
        // Before the first word: up, unless there is no room for the ramp down.
        let firstDown = first.lowerBound - Self.lead - Self.down
        if firstDown > 0.0005 {
            points += [DuckPoint(time: 0, lift: lift), DuckPoint(time: firstDown, lift: lift),
                       DuckPoint(time: first.lowerBound - Self.lead, lift: 0)]
        } else {
            points.append(DuckPoint(time: 0, lift: 0))
        }
        for (index, run) in runs.enumerated() {
            let upFrom = run.upperBound + Self.hold
            guard upFrom < duration else { break }
            points += [DuckPoint(time: upFrom, lift: 0), DuckPoint(time: upFrom + Self.up, lift: lift)]
            if index + 1 < runs.count {
                let next = runs[index + 1].lowerBound
                points += [DuckPoint(time: next - Self.lead - Self.down, lift: lift), DuckPoint(time: next - Self.lead, lift: 0)]
            }
        }
        return DuckEnvelope(points: points)
    }
}

/// At `time` (edited seconds), the music is `lift` dB over its level.
struct DuckPoint: Equatable, Encodable {
    var time: Double
    var lift: Double
}

/// The duck as gain points, in order. Before the first point and after the last, the lift
/// holds; between two points the volume (not the dB) moves in a straight line.
struct DuckEnvelope: Equatable {
    var points: [DuckPoint]

    /// True when the lift never changes, so the duck does nothing but a fixed gain.
    var isFlat: Bool { points.allSatisfy { abs($0.lift - (points.first?.lift ?? 0)) < 0.0005 } }

    static func factor(_ lift: Double) -> Double { pow(10, lift / 20) }

    /// The volume factor at `time`.
    func factor(at time: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if time <= first.time { return Self.factor(first.lift) }
        if time >= last.time { return Self.factor(last.lift) }
        // The timeline draws the line from many times: find the two points by halves.
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let a = points[low], b = points[high]
        let k = (time - a.time) / (b.time - a.time)
        return Self.factor(a.lift) + (Self.factor(b.lift) - Self.factor(a.lift)) * k
    }

    /// The lift at `time`, in dB.
    func lift(at time: Double) -> Double { 20 * log10(max(0.000001, factor(at: time))) }

    /// The times in `range` where the volume starts or stops a change.
    func times(in range: ClosedRange<Double>) -> [Double] {
        points.map(\.time).filter { $0 > range.lowerBound && $0 < range.upperBound }
    }

    /// An ffmpeg `volume` expression of `t` with `eval=frame`: one term for each part
    /// between two points, so no expression nests deeper than one `if`.
    var expression: String {
        func number(_ value: Double) -> String { String(format: "%.6f", value) }
        guard let first = points.first else { return "1" }
        guard !isFlat else { return number(Self.factor(first.lift)) }
        var terms: [String] = ["\(number(Self.factor(first.lift)))*lt(t,\(number(first.time)))"]
        for (a, b) in zip(points, points.dropFirst()) where b.time - a.time > 0.000001 {
            let from = Self.factor(a.lift), to = Self.factor(b.lift)
            let range = "gte(t,\(number(a.time)))*lt(t,\(number(b.time)))"
            if abs(to - from) < 0.000001 {
                terms.append("\(number(from))*\(range)")
            } else {
                terms.append("\(range)*(\(number(from))+\(number(to - from))*(t-\(number(a.time)))/\(number(b.time - a.time)))")
            }
        }
        let last = points.last!
        terms.append("\(number(Self.factor(last.lift)))*gte(t,\(number(last.time)))")
        return terms.joined(separator: "+")
    }
}

// MARK: - Speech in the edit

extension ClipTimeline {
    /// Source spans (seconds of the recording) as spans of the edited video. A span that
    /// crosses a cut gives one span for each section it touches.
    func editedSpans(_ spans: [(Double, Double)]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var offset = 0.0
        for segment in segments {
            defer { offset += segment.duration }
            for (start, end) in spans {
                let a = max(start, segment.start), b = min(end, segment.end)
                guard b - a > 0.000001 else { continue }
                result.append((offset + (a - segment.start) / segment.speed)...(offset + (b - segment.start) / segment.speed))
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
}

/// Where the duck finds speech: the transcript's words, or the sound levels when there is
/// no transcript.
enum MusicSpeech {
    enum Source: String, Encodable { case transcript, levels, none }

    /// The spans of speech in the edited video, from the words still in the edit.
    static func spans(_ transcript: Transcript, timeline: ClipTimeline) -> [ClosedRange<Double>] {
        timeline.editedSpans(transcript.keptWords(timeline).map { ($0.word.start, max($0.word.end, $0.word.start + 0.05)) })
    }

    /// The spans of speech in the edited video, from the sound levels: the loud parts.
    static func spans(_ overview: AudioOverview, timeline: ClipTimeline) -> [ClosedRange<Double>] {
        guard let last = overview.levels.last else { return [] }
        var loud: [(Double, Double)] = []
        var cursor = 0.0
        for quiet in overview.quietRanges(threshold: MusicDuck.threshold) {
            if quiet.0 - cursor >= MusicDuck.shortestSound { loud.append((cursor, quiet.0)) }
            cursor = max(cursor, quiet.1)
        }
        let end = last.time + AudioOverview.interval
        if end - cursor >= MusicDuck.shortestSound { loud.append((cursor, end)) }
        return timeline.editedSpans(loud)
    }

    /// The sound levels of recordings with no transcript, kept for the duck. The preview
    /// and the export read them here at once; `prepare` measures them first.
    private final class Levels: @unchecked Sendable {
        private let lock = NSLock()
        private var overviews: [URL: AudioOverview] = [:]
        subscript(url: URL) -> AudioOverview? {
            get { lock.lock(); defer { lock.unlock() }; return overviews[url.standardizedFileURL] }
            set { lock.lock(); defer { lock.unlock() }; overviews[url.standardizedFileURL] = newValue }
        }
    }
    private static let levels = Levels()

    static func cachedLevels(_ url: URL) -> AudioOverview? { levels[url] }

    /// Measures the sound levels of `item` when its duck needs them: duck on and no words.
    static func prepare(_ item: VideoItem) async {
        guard item.music?.duck != nil, item.transcript?.words.isEmpty ?? true, levels[item.url] == nil,
              let overview = try? await AudioAnalyzer.analyze(item.url) else { return }
        levels[item.url] = overview
    }

    /// Where the duck of `item` finds speech.
    static func source(of item: VideoItem) -> Source {
        if item.transcript?.words.isEmpty == false { return .transcript }
        return cachedLevels(item.url) == nil ? .none : .levels
    }

    /// The speech of `item` in the edited video, and where it comes from. With no
    /// transcript and no measured levels, all of the video is speech, so the music stays
    /// at its level and never goes up over the voice.
    static func spans(of item: VideoItem) -> (spans: [ClosedRange<Double>], source: Source) {
        let timeline = item.timeline
        if let transcript = item.transcript, !transcript.words.isEmpty { return (spans(transcript, timeline: timeline), .transcript) }
        if let overview = cachedLevels(item.url) { return (spans(overview, timeline: timeline), .levels) }
        return ([0...max(0, timeline.duration)], .none)
    }
}

extension VideoItem {
    /// The duck of this recording's music, or nil when it has no music or the duck is off.
    var musicDuck: DuckEnvelope? {
        guard let duck = music?.duck else { return nil }
        return duck.envelope(runs: MusicSpeech.spans(of: self).spans, duration: editedDuration)
    }
}
