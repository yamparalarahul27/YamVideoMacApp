import CryptoKit
import Foundation

// Auto edit: the choices asked before an edit (how to transcribe, how tight to cut, what to
// do with captions and loudness) stored in the project, so the owner and agents read the
// same answers, and the planning that turns them into cuts and captions. Transcripts are
// timed in source seconds, like sections; captions made from one follow the cuts.

// MARK: - Options

/// The whisper.cpp model a recording is transcribed with. Neither ships with the app; the
/// owner downloads one from Auto Edit, and nothing is fetched without that click.
enum TranscriptModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case largeV3Turbo = "large-v3-turbo-q5_0"
    case baseEnglish = "base.en"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .largeV3Turbo: return "Large v3 Turbo"
        case .baseEnglish: return "Base (English)"
        }
    }
    var detail: String {
        switch self {
        case .largeV3Turbo: return "The most accurate, in any language, and slower than Base."
        case .baseEnglish: return "Fast and small, English only. Fine for a clear voice and a quiet room."
        }
    }
    var fileName: String { "ggml-\(rawValue).bin" }
    var downloadURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    /// Checked after every download; a file that does not match is thrown away.
    var sha256: String {
        switch self {
        case .largeV3Turbo: return "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        case .baseEnglish: return "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        }
    }
    var bytes: Int64 {
        switch self {
        case .largeV3Turbo: return 574_041_195
        case .baseEnglish: return 147_964_211
        }
    }
    var sizeLabel: String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
    /// whisper.cpp's alignment-head preset for word timing (`-dtw`).
    var dtwPreset: String {
        switch self {
        case .largeV3Turbo: return "large.v3.turbo"
        case .baseEnglish: return "base.en"
        }
    }
    var englishOnly: Bool { self == .baseEnglish }
}

/// How much a recording is cut. The numbers are the ones asked about before the first
/// video: Tight takes pauses of 0.42 s or more down to about 0.22 s and cuts stumbles;
/// Natural is the silence review's own defaults.
enum CutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case tight, natural, review

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tight: return "Tight"
        case .natural: return "Natural"
        case .review: return "Review each cut"
        }
    }
    var detail: String {
        switch self {
        case .tight: return "Pauses of 0.42 s or more become about 0.22 s, and repeated words, restarts and “um”s from the transcript go."
        case .natural: return "Pauses of 0.8 s or more become 0.3 s, as the silence review does by default. Stumbles stay."
        case .review: return "The same cuts as Tight, listed for you to listen to and choose before anything is cut."
        }
    }
    var pauses: PauseRule { self == .natural ? .natural : .tight }
    var cutsStumbles: Bool { self != .natural }
}

/// When a stretch of audio counts as a pause, and how much of it stays on each side.
struct PauseRule: Equatable, Sendable {
    /// dB; the silence review's default.
    var threshold: Double
    /// The shortest pause that is cut, in seconds.
    var minimum: Double
    /// Kept at each end of a cut pause, so speech is never clipped and a breath remains.
    var padding: Double

    static let tight = PauseRule(threshold: -40, minimum: 0.42, padding: 0.11)
    static let natural = PauseRule(threshold: -40, minimum: 0.8, padding: 0.15)
}

/// What the edit does with captions.
enum CaptionUse: String, Codable, CaseIterable, Identifiable, Sendable {
    /// An SRT on the edited timeline goes up beside the video; the picture stays clean.
    case upload
    /// Drawn into the picture as well as uploaded.
    case burnIn
    case off

    var id: String { rawValue }
    var label: String {
        switch self {
        case .upload: return "SRT for upload"
        case .burnIn: return "Burn in and SRT"
        case .off: return "None"
        }
    }
    var detail: String {
        switch self {
        case .upload: return "Captions go up to YouTube beside the video, so viewers can turn them on or off."
        case .burnIn: return "Captions are drawn into the picture too, for viewers who watch without sound."
        case .off: return "No captions in exports or in Export for YouTube."
        }
    }
    var burns: Bool { self == .burnIn }
    var uploads: Bool { self != .off }
}

/// The owner's answers, stored per project. Nil in a project means none were saved yet,
/// and these defaults (the first video's choices) apply.
struct AutoEditOptions: Codable, Equatable, Sendable {
    var model: TranscriptModel = .largeV3Turbo
    /// A whisper language code, or "auto" to detect it.
    var language: String = "en"
    var cutStyle: CutStyle = .tight
    var captions: CaptionUse = .upload
    /// Exports normalise loudness to -14 LUFS, -1 dBTP.
    var normaliseAudio: Bool = true

    var problem: String? {
        guard Self.languages.contains(language) else {
            return "language must be \"auto\" or a whisper language code such as en, hi, te, es or fr (not \"\(language)\")."
        }
        if model.englishOnly, language != "en" {
            return "\(model.label) understands English only: choose language en, or the \(TranscriptModel.largeV3Turbo.label) model."
        }
        return nil
    }

    /// "auto" plus every language whisper knows.
    static let languages: [String] = ["auto"] + """
        en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue
        """.split(separator: " ").map(String.init)

    static func languageName(_ code: String) -> String {
        code == "auto" ? "Detect automatically" : Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: - Captions setting

extension ExportSettings {
    /// What exports and Export for YouTube do with a recording's captions. Projects that
    /// never chose keep the old behaviour: a chosen file is burned in and uploaded, and a
    /// transcript is not used for captions until captions are turned on.
    func captionUse(hasFile: Bool) -> CaptionUse { captions ?? (hasFile ? .burnIn : .off) }
}

extension VideoItem {
    /// The source-timed caption file this recording's exports use: its own caption file,
    /// or else one written from its transcript (words cut from the edit left out), or nil
    /// when captions are off.
    func captionsFile(_ settings: ExportSettings) -> URL? {
        guard settings.captionUse(hasFile: subtitles != nil).uploads else { return nil }
        if let subtitles { return subtitles }
        guard let transcript, settings.captions != nil else { return nil }
        return transcript.captionsFile(timeline: timeline)
    }

    /// The caption file burned into the picture, when captions are burned in.
    func burnedCaptions(_ settings: ExportSettings) -> URL? {
        settings.captionUse(hasFile: subtitles != nil).burns ? captionsFile(settings) : nil
    }

    /// The captions uploaded beside the video, as an SRT on the edited timeline.
    func uploadCaptionsSRT(_ settings: ExportSettings) -> String? {
        captionsFile(settings).flatMap { Captions.editedSRT($0, timeline: timeline) }
    }

    /// Whether Export for YouTube writes an SRT: there are captions, in a form that can be
    /// moved onto the edited timeline (SRT, VTT or a transcript; not ASS).
    func uploadsCaptions(_ settings: ExportSettings) -> Bool {
        captionsFile(settings).map { Captions.retimable.contains($0.pathExtension.lowercased()) } ?? false
    }

    /// Where its captions come from: "file", "transcript" or nil. Writes nothing.
    func captionsSource(_ settings: ExportSettings) -> String? {
        guard settings.captionUse(hasFile: subtitles != nil).uploads else { return nil }
        if subtitles != nil { return "file" }
        return transcript?.words.isEmpty == false && settings.captions != nil ? "transcript" : nil
    }
}

// MARK: - Transcript

/// One spoken word: its text as whisper wrote it (with punctuation) and where it is in the
/// source. `start` is whisper's word timing, which runs a little late (up to about 0.15 s);
/// cuts are moved to the quiet before a word, not trusted to the millisecond.
struct TranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct Transcript: Codable, Equatable, Sendable {
    /// The model's id, as `TranscriptModel.rawValue`, or another name for an imported one.
    var model: String
    /// The language spoken, as detected or asked for.
    var language: String
    var words: [TranscriptWord]

    var text: String { words.map(\.text).joined(separator: " ") }

    static let maximumWords = 200_000

    func problem(duration: Double) -> String? {
        guard words.count <= Self.maximumWords else { return "A transcript may hold at most \(Self.maximumWords) words." }
        var previous = 0.0
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start,
                  word.end <= duration + 1 else {
                return "Each word's start and end must be within the recording (0–\(String(format: "%.2f", duration)) s), end after start."
            }
            guard word.start >= previous - 0.000001 else { return "Words must be in the order they are spoken." }
            guard !word.text.trimmingCharacters(in: .whitespaces).isEmpty else { return "A word cannot be empty." }
            previous = word.start
        }
        return nil
    }

    /// The words still in the edit: those whose start is inside a section.
    func keptWords(_ timeline: ClipTimeline) -> [(word: TranscriptWord, segment: Int)] {
        words.compactMap { word in
            timeline.segments.firstIndex { word.start >= $0.start - 0.000001 && word.start < $0.end }.map { (word, $0) }
        }
    }

    /// Captions in source seconds from the words still in the edit: up to two lines of
    /// about 42 characters, broken at sentence ends, pauses that remain after the cuts, and
    /// wherever the edit jumps back, shown for at least 0.8 s where the next caption
    /// allows. A caption may run across a cut; moved onto the edited timeline its pieces
    /// join up again.
    func captions(timeline: ClipTimeline) -> [Caption] {
        typealias Entry = (word: TranscriptWord, segment: Int)
        let kept = keptWords(timeline)
        let offsets = timeline.segments.indices.map { index in timeline.segments[..<index].reduce(0) { $0 + $1.duration } }
        func edited(_ source: Double, in segment: Int) -> Double {
            let section = timeline.segments[segment]
            return offsets[segment] + (min(max(source, section.start), section.end) - section.start) / section.speed
        }
        var groups: [[Entry]] = []
        var current: [Entry] = []
        func length(_ group: [Entry]) -> Int { group.map(\.word.text.count).reduce(0, +) + max(0, group.count - 1) }
        for entry in kept {
            if let last = current.last, let first = current.first {
                let follows = entry.segment == last.segment
                    || (entry.segment == last.segment + 1 && timeline.segments[entry.segment].start >= timeline.segments[last.segment].end - 0.000001)
                let sentenceEnded = last.word.text.last.map { ".?!".contains($0) } ?? false
                let pause = edited(entry.word.start, in: entry.segment) - edited(last.word.end, in: last.segment) > 0.6
                let tooLong = length(current) + 1 + entry.word.text.count > 84
                    || edited(entry.word.start, in: entry.segment) - edited(first.word.start, in: first.segment) > 6
                if !follows || tooLong || pause || (sentenceEnded && length(current) >= 18) {
                    groups.append(current); current = []
                }
            }
            current.append(entry)
        }
        if !current.isEmpty { groups.append(current) }
        var result: [Caption] = []
        for (index, group) in groups.enumerated() {
            let last = group[group.count - 1]
            let start = group[0].word.start
            var end = min(timeline.segments[last.segment].end, max(last.word.end, start + 0.8))
            if index + 1 < groups.count, groups[index + 1][0].segment == last.segment {
                end = min(end, groups[index + 1][0].word.start)
            }
            result.append(Caption(start: start, end: max(end, start + 0.05), text: Self.lines(group.map(\.word.text))))
        }
        return result
    }

    /// One line, or two of about equal length when it is over 42 characters.
    static func lines(_ words: [String]) -> String {
        let line = words.joined(separator: " ")
        guard line.count > 42, words.count > 1 else { return line }
        var best = 1, bestDifference = Int.max
        for split in 1..<words.count {
            let left = words[..<split].joined(separator: " ").count, right = words[split...].joined(separator: " ").count
            if abs(left - right) < bestDifference { best = split; bestDifference = abs(left - right) }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    /// The captions as a source-timed SRT in the temporary folder, named by its content so
    /// an unchanged edit reuses the same file.
    func captionsFile(timeline: ClipTimeline) -> URL? {
        let captions = captions(timeline: timeline)
        guard !captions.isEmpty else { return nil }
        let data = Data(Captions.srt(captions).utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yamvideo-transcript-\(digest).srt")
        if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
        return url
    }
}

// MARK: - Stumbles

/// A stumble found in the transcript: what to take out, in source seconds, from the
/// start of the stumble to the start of the word that follows it.
struct Stumble: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// "um", "uh", "erm".
        case filler
        /// The same word twice: "the the".
        case repeated = "repeat"
        /// The same few words twice: "I think we, I think we should".
        case restart
        /// A word broken off: "wh- what".
        case fragment
    }
    var kind: Kind
    /// The words taken out.
    var text: String
    var start: Double
    var end: Double

    var label: String {
        switch kind {
        case .filler: return "Filler “\(text)”"
        case .repeated: return "Repeat “\(text)”"
        case .restart: return "Restart “\(text)”"
        case .fragment: return "Broken word “\(text)”"
        }
    }
}

enum StumbleFinder {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hm", "mm"]
    /// Words said twice on purpose, for emphasis or because the grammar needs it.
    static let meantTwice: Set<String> = ["had", "that", "very", "really", "bye", "no", "ha", "haha", "knock"]

    static func normalised(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }

    static func stumbles(in words: [TranscriptWord]) -> [Stumble] {
        let keys = words.map { normalised($0.text) }
        var result: [Stumble] = []
        var index = 0
        func next(_ i: Int) -> Double { i < words.count ? words[i].start : words[words.count - 1].end }
        func text(_ range: Range<Int>) -> String { words[range].map(\.text).joined(separator: " ") }
        while index < words.count {
            let key = keys[index]
            if fillers.contains(key) {
                result.append(Stumble(kind: .filler, text: text(index..<index + 1), start: words[index].start, end: next(index + 1)))
                index += 1; continue
            }
            if let last = words[index].text.last, "-—–".contains(last), index + 1 < words.count, !key.isEmpty {
                result.append(Stumble(kind: .fragment, text: text(index..<index + 1), start: words[index].start, end: next(index + 1)))
                index += 1; continue
            }
            var matched = false
            for length in stride(from: 4, through: 1, by: -1) where index + 2 * length <= words.count {
                let first = keys[index..<index + length], second = keys[index + length..<index + 2 * length]
                guard first.allSatisfy({ !$0.isEmpty }), Array(first) == Array(second) else { continue }
                if length == 1, meantTwice.contains(key) { continue }
                result.append(Stumble(kind: length == 1 ? .repeated : .restart, text: text(index..<index + length),
                                      start: words[index].start, end: words[index + length].start))
                index += length; matched = true; break
            }
            if !matched { index += 1 }
        }
        return result
    }
}

// MARK: - Planning cuts

/// Turns pauses in the audio and stumbles in the transcript into cuts on the timeline.
///
/// Quiet stretches and stumbles that touch are one cut, so "videos. [pause] Um, [pause]
/// the" loses the pause, the "um" and the pause after it in one go. Where a cut meets
/// quiet, `padding` of the quiet stays (so 0.11 s each side leaves about 0.22 s); where it
/// meets speech directly it ends at the quietest moment before the next word. Stumble
/// edges are moved to that quiet moment because whisper's word times run late. Without
/// stumbles this is exactly the silence review's own cut list.
enum CutPlanner {
    static func cuts(levels overview: AudioOverview, timeline: ClipTimeline, fps: Double,
                     rule: PauseRule, stumbles: [Stumble] = []) -> [SilenceCut] {
        let quiet = overview.quietRanges(threshold: rule.threshold)
        struct Piece { var start: Double; var end: Double; var stumble: Stumble? }
        var pieces = quiet.map { Piece(start: $0.0, end: $0.1, stumble: nil) }
        for stumble in stumbles {
            let start = overview.quietestMoment(before: stumble.start)
            let end = max(start, overview.quietestMoment(before: stumble.end))
            guard end - start > 0.02 else { continue }
            pieces.append(Piece(start: start, end: end, stumble: stumble))
        }
        pieces.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        // Spans of touching pieces. Two quiet stretches never touch (each is as long as
        // it can be), so without stumbles every span is one quiet stretch.
        struct Span {
            var start: Double, end: Double, quietStart: Bool, quietEnd: Bool
            var stumbles: [Stumble]
            /// The longest quiet stretch inside: a cut is also a pause cut when it reaches the rule's minimum.
            var longestQuiet: Double
        }
        var spans: [Span] = []
        for piece in pieces {
            let quietLength = piece.stumble == nil ? piece.end - piece.start : 0
            if var last = spans.last, (piece.stumble != nil || !last.stumbles.isEmpty)
                ? piece.start <= last.end + AudioOverview.interval * 1.2 : piece.start <= last.end {
                if piece.end > last.end { last.end = piece.end; last.quietEnd = piece.stumble == nil }
                else if piece.end == last.end, piece.stumble == nil { last.quietEnd = true }
                if let stumble = piece.stumble { last.stumbles.append(stumble) }
                last.longestQuiet = max(last.longestQuiet, quietLength)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: piece.start, end: piece.end, quietStart: piece.stumble == nil,
                                  quietEnd: piece.stumble == nil, stumbles: piece.stumble.map { [$0] } ?? [],
                                  longestQuiet: quietLength))
            }
        }

        var result: [SilenceCut] = []
        for span in spans {
            let stumbling = !span.stumbles.isEmpty
            guard stumbling || span.longestQuiet >= rule.minimum else { continue }
            let from = span.start + (span.quietStart ? rule.padding : 0)
            let to = span.end - (span.quietEnd ? rule.padding : 0)
            for segment in timeline.segments {
                let lower = max(segment.start, ceil(from * fps - 0.000001) / fps)
                let upper = min(segment.end, floor(to * fps + 0.000001) / fps)
                guard upper - lower >= max(1 / fps, stumbling ? 0.05 : 0.1) - 0.000001 else { continue }
                let head = (lower - segment.start) / segment.speed
                let tail = (segment.end - upper) / segment.speed
                guard (head < 0.000001 || head >= 1 / fps - 0.000001),
                      (tail < 0.000001 || tail >= 1 / fps - 0.000001) else { continue }
                let inside = span.stumbles.filter { $0.end > segment.start && $0.start < segment.end }
                var cut = SilenceCut(segmentID: segment.id, start: lower, end: upper,
                                     timelineStart: timeline.offset(of: segment.id) + (lower - segment.start) / segment.speed,
                                     duration: (upper - lower) / segment.speed)
                cut.stumbles = inside
                cut.pause = span.longestQuiet >= rule.minimum
                result.append(cut)
            }
        }
        return result.sorted { $0.timelineStart < $1.timelineStart }
    }
}

extension AudioOverview {
    /// Stretches at or under `threshold`, in source seconds, never across unmeasured audio.
    func quietRanges(threshold: Double) -> [(Double, Double)] {
        var quiet: [(Double, Double)] = []
        var beginning: Double?
        var previousEnd = 0.0
        for level in levels {
            if level.time > previousEnd + Self.interval * 0.5, let start = beginning {
                quiet.append((start, previousEnd)); beginning = nil
            }
            if level.decibels <= threshold {
                if beginning == nil { beginning = level.time }
            } else if let start = beginning { quiet.append((start, level.time)); beginning = nil }
            previousEnd = level.time + Self.interval
        }
        if let beginning { quiet.append((beginning, previousEnd)) }
        return quiet
    }

    /// The best place to cut just before a word whisper places at `time`: the end of the
    /// quietest moment in the 0.3 s before it. whisper's times run about 0.05–0.15 s late,
    /// so of the moments within 3 dB of the quietest, the one nearest 0.08 s before `time`
    /// wins: the last of a pause, or the dip between two words said without one.
    func quietestMoment(before time: Double) -> Double {
        let from = time - 0.3, to = time + 0.06
        let window = levels.filter { $0.time >= from - 0.000001 && $0.time + Self.interval <= to + 0.000001 }
        guard let lowest = window.map(\.decibels).min() else { return time }
        let target = time - 0.08
        let chosen = window.filter { $0.decibels <= lowest + 3 }
            .min { (abs($0.time + Self.interval / 2 - target), -$0.time) < (abs($1.time + Self.interval / 2 - target), -$1.time) }!
        return chosen.time + Self.interval
    }
}
