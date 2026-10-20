import Foundation

// MARK: - Background music (docs/plans/background-music.md, part 1)
//
// A quiet bed of music under the voice. The music sits on the edited timeline, so the
// jump cuts never cut it; each piece follows the frame where it starts when the edit
// changes, as graphics do. Its level is in LU under the voice: the app measures the
// loudness of the voice and of each file, so a loud track and a quiet track sit the same.

/// What a track's licence lets a monetised YouTube video do.
enum MusicLicence: String, Codable, CaseIterable, Identifiable {
    case audioLibrary, cc0, ccBy, pixabay, generated, own, other, ccNC, ccND, ccSA

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audioLibrary: return "YouTube Audio Library"
        case .cc0: return "CC0"
        case .ccBy: return "CC BY"
        case .pixabay: return "Pixabay"
        case .generated: return "Made with AI"
        case .own: return "My own"
        case .other: return "Other"
        case .ccNC: return "CC BY-NC"
        case .ccND: return "CC BY-ND"
        case .ccSA: return "CC BY-SA"
        }
    }

    /// Why a monetised video cannot use it, or nil when it can.
    var block: String? {
        switch self {
        case .ccNC: return "CC BY-NC does not permit commercial use, and a monetised channel is commercial use."
        case .ccND: return "CC BY-ND does not permit changes, and Creative Commons says music synced to a video is always a change."
        case .ccSA: return "CC BY-SA makes the video take the same licence, and YouTube uploads use CC BY."
        default: return nil
        }
    }
}

/// Where a track comes from and how to give credit for it. The line goes at the end of the
/// description when it is not empty.
struct MusicCredit: Codable, Equatable {
    /// Nil until the owner or an agent sets it: a warning on Export for YouTube.
    var licence: MusicLicence?
    var title = ""
    var artist = ""
    /// The page of the track, as text.
    var source = ""
    /// The credit for the description, for example "Music: Calm by Ana (CC BY 4.0)".
    var line = ""

    static let textLimit = 300

    var problem: String? {
        for (name, text) in [("title", title), ("artist", artist), ("source", source), ("credit line", line)] {
            if text.count > Self.textLimit { return "The music's \(name) is longer than \(Self.textLimit) characters." }
            if text.contains("\n") { return "The music's \(name) must be one line." }
        }
        return nil
    }
}

/// One piece of music on the edited timeline: a part of a file, from `start` to `end`.
struct MusicPiece: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    /// The file's length and integrated loudness (LUFS), as measured when it went on.
    var duration: Double
    var loudness: Double
    /// Edited-recording seconds. Nil `end` plays to the end of the video.
    var start: Double
    var end: Double?
    /// Where the file starts to play, in seconds of the file.
    var from: Double = 0
    /// LU under the voice.
    var level: Double = Music.defaultLevel
    var fadeIn: Double = Music.defaultFadeIn
    var fadeOut: Double = Music.defaultFadeOut
    /// Plays the file again, with a crossfade, when the piece is longer than the file.
    var loop = true
    var credit = MusicCredit()

    var name: String { credit.title.isEmpty ? url.deletingPathExtension().lastPathComponent : credit.title }

    /// Where it stops in a video of `duration`.
    func end(in duration: Double) -> Double { min(end ?? duration, duration) }

    /// The gain of the file in dB, so that it sits `level` LU under a voice of `voice` LUFS.
    func gain(voice: Double) -> Double { voice + level - loudness }

    /// The crossfade where the file plays again: 2 s, or shorter for a short file.
    var crossfade: Double {
        guard loop else { return 0 }
        return min(Music.crossfade, duration / 4, (duration - from) / 2)
    }

    /// Each play of the file, in order. A loop starts the file again from its start, with
    /// a crossfade; the last play stops at the end of the piece with the fade out.
    func plays(videoDuration: Double) -> [MusicPlay] {
        let stop = end(in: videoDuration)
        let cross = crossfade
        var plays: [MusicPlay] = []
        var at = start, offset = from
        while stop - at > 0.0005, plays.count < Music.maximumPlays {
            let available = duration - offset
            guard available > 0.0005 else { break }
            let remaining = stop - at
            let last = !loop || available >= remaining - 0.000001
            let length = last ? min(available, remaining) : available
            // A crossfade keeps its length; the piece's own fades give way to it.
            let crossIn = plays.isEmpty ? nil : cross, crossOut = last ? nil : cross
            var fadeIn = crossIn ?? self.fadeIn
            var fadeOut = crossOut ?? self.fadeOut
            if crossIn == nil, crossOut == nil, fadeIn + fadeOut > length {
                let k = length / (fadeIn + fadeOut)
                fadeIn *= k; fadeOut *= k
            } else if crossIn == nil {
                fadeIn = min(fadeIn, max(0, length - fadeOut))
            } else if crossOut == nil {
                fadeOut = min(fadeOut, max(0, length - fadeIn))
            }
            plays.append(MusicPlay(at: at, from: offset, length: length, fadeIn: fadeIn, fadeOut: fadeOut))
            if last { break }
            at += length - cross
            offset = 0
        }
        return plays
    }

    /// How many plays the piece needs at most, to refuse a loop of a tiny file.
    func playCount(videoDuration: Double) -> Int {
        let length = end(in: videoDuration) - start
        guard loop, duration - from < length else { return 1 }
        let step = max(0.001, duration - crossfade)
        return 1 + Int(((length - (duration - from)) / step).rounded(.up))
    }

    func problem(duration video: Double) -> String? {
        let name = "The music “\(self.name)”"
        guard url.isFileURL else { return "\(name) must be a local file." }
        guard duration.isFinite, duration > 0 else { return "\(name) has no length." }
        guard loudness.isFinite, Music.loudnessRange.contains(loudness) else { return "\(name) has no measured loudness." }
        guard start.isFinite, from.isFinite, level.isFinite, fadeIn.isFinite, fadeOut.isFinite, end?.isFinite ?? true else {
            return "\(name) has a time or level that is not a number."
        }
        guard start >= 0, start <= video - Music.minimumLength + 0.000001 else {
            return String(format: "%@ must start between 0 and %.2f s, at least %.0f s before the end of the video.",
                          name, max(0, video - Music.minimumLength), Music.minimumLength)
        }
        if let end {
            guard end - start >= Music.minimumLength - 0.000001 else { return String(format: "%@ must play for at least %.0f s.", name, Music.minimumLength) }
            guard end <= video + 0.001 else { return String(format: "%@ must end by the end of the video (%.2f s).", name, video) }
        }
        guard from >= 0, from <= duration - Music.minimumLength + 0.000001 else {
            return String(format: "%@ must start at least %.0f s before the end of its file (%.2f s).", name, Music.minimumLength, duration)
        }
        guard Music.levels.contains(level) else {
            return String(format: "The level of %@ must be from %.0f to %.0f LU.", self.name, Music.levels.lowerBound, Music.levels.upperBound)
        }
        guard Music.fades.contains(fadeIn), Music.fades.contains(fadeOut) else {
            return String(format: "The fades of %@ must be from 0 to %.0f s.", self.name, Music.fades.upperBound)
        }
        if loop, end(in: video) - start > duration - from {
            guard duration >= Music.minimumLoopFile else {
                return String(format: "%@ is too short to loop: a loop needs a file of %.0f s or more.", name, Music.minimumLoopFile)
            }
            guard playCount(videoDuration: video) <= Music.maximumPlays else {
                return "\(name) would play more than \(Music.maximumPlays) times. Use a longer file, or a shorter piece."
            }
        }
        return credit.problem
    }
}

/// One play of a file: at `at` on the edited timeline, `length` seconds of the file from
/// `from`, with its fades.
struct MusicPlay: Equatable {
    var at: Double
    var from: Double
    var length: Double
    var fadeIn: Double
    var fadeOut: Double
    var end: Double { at + length }
}

/// A recording's music. Version 20 onwards; nil while it has none.
struct MusicBed: Codable, Equatable {
    /// The recording's voice loudness (LUFS), as measured when the first piece went on.
    var voice: Double
    /// In order of start; they do not overlap.
    var pieces: [MusicPiece]

    func problem(duration: Double) -> String? {
        guard voice.isFinite, Music.loudnessRange.contains(voice) else { return "The music has no measured loudness of the voice." }
        guard !pieces.isEmpty else { return "The music has no pieces." }
        guard Set(pieces.map(\.id)).count == pieces.count else { return "Two pieces of music have the same ID." }
        if let problem = pieces.lazy.compactMap({ $0.problem(duration: duration) }).first { return problem }
        let ordered = pieces.sorted { $0.start < $1.start }
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.end(in: duration) > b.start + 0.001 {
            return String(format: "The music “%@” overlaps “%@” at %.2f s. Pieces of music may touch but not overlap.", a.name, b.name, b.start)
        }
        return nil
    }

    /// The piece playing at `time`, if one does.
    func piece(at time: Double, duration: Double) -> MusicPiece? {
        pieces.first { time >= $0.start && time < $0.end(in: duration) }
    }

    /// Where a new piece can go at `time`: from there to the end of the video or to the
    /// next piece. Nil when a piece plays there or there is less than the minimum.
    func room(at time: Double, duration: Double) -> ClosedRange<Double>? {
        guard piece(at: time, duration: duration) == nil else { return nil }
        let next = pieces.map(\.start).filter { $0 > time }.min() ?? duration
        guard next - time >= Music.minimumLength - 0.000001 else { return nil }
        return time...next
    }

    /// What the export and the preview play: each file once, and every play with its gain.
    func mix(duration: Double) -> MusicMix {
        var files: [URL] = []
        var plays: [MusicMix.Play] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            let index: Int
            if let found = files.firstIndex(of: piece.url) { index = found } else { files.append(piece.url); index = files.count - 1 }
            let gain = piece.gain(voice: voice)
            plays += piece.plays(videoDuration: duration).map { MusicMix.Play(file: index, play: $0, gain: gain) }
        }
        return MusicMix(files: files, plays: plays)
    }
}

/// The music as the export and the preview play it.
struct MusicMix: Equatable {
    struct Play: Equatable {
        /// The index in `files`.
        var file: Int
        var play: MusicPlay
        /// dB.
        var gain: Double
    }
    var files: [URL]
    var plays: [Play]
    var isEmpty: Bool { plays.isEmpty }
}

enum Music {
    static let levels = -30.0 ... -6.0
    static let defaultLevel = -20.0
    static let defaultFadeIn = 2.0
    static let defaultFadeOut = 3.0
    static let fades = 0.0...10.0
    static let crossfade = 2.0
    static let minimumLength = 1.0
    static let minimumLoopFile = 5.0
    static let maximumPlays = 100
    static let loudnessRange = -70.0...0.0
    /// The sound files the preview (AVFoundation) and the export (ffmpeg) both read.
    static let fileTypes = ["m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "flac", "aac"]

    static func isMusicFile(_ url: URL) -> Bool { fileTypes.contains(url.pathExtension.lowercased()) }
}

extension VideoItem {
    /// The music the export mixes in, or nil: none, switched off, or no sound.
    func exportMusic(_ settings: ExportSettings) -> MusicMix? {
        guard let music, isOn(.music), info?.hasAudio == true, settings.audio != .none, !settings.format.isAnimation else { return nil }
        let mix = music.mix(duration: editedDuration)
        return mix.isEmpty ? nil : mix
    }
}

// MARK: - The music after an edit

extension ClipTimeline {
    /// The edited time of the first frame at or after `time` (on `old`) that this timeline
    /// keeps, in the order `old` plays.
    func nextKept(_ time: Double, from old: ClipTimeline) -> Double? {
        var offset = 0.0
        for segment in old.segments {
            defer { offset += segment.duration }
            let segmentEnd = offset + segment.duration
            guard segmentEnd > time + 0.000001 else { continue }
            let low = segment.start + max(0, time - offset) * segment.speed
            var best: Double?
            for kept in segments {
                let a = max(low, kept.start), b = min(segment.end, kept.end)
                if b - a > 0.000001 { best = min(best ?? a, a) }
            }
            if let best, let mapped = self.time(forSource: best) { return mapped }
        }
        return nil
    }

    /// Each piece follows the frame where it starts, as graphics do; if that frame is gone,
    /// it starts at the next frame that stays. It keeps its length, shortened to the next
    /// piece and the end of the video; a piece that no longer has room goes.
    func remap(_ bed: MusicBed, from old: ClipTimeline) -> (bed: MusicBed?, removed: [UUID]) {
        var moved: [MusicPiece] = []
        var removed: [UUID] = []
        for var piece in bed.pieces {
            guard let start = nextKept(piece.start, from: old) else { removed.append(piece.id); continue }
            if let end = piece.end { piece.end = start + (end - piece.start) }
            piece.start = start
            moved.append(piece)
        }
        moved.sort { $0.start < $1.start }
        var kept: [MusicPiece] = []
        for (index, var piece) in moved.enumerated() {
            let next = index + 1 < moved.count ? moved[index + 1].start : nil
            if let end = piece.end { piece.end = min(end, next ?? duration) } else if let next { piece.end = next }
            guard piece.end(in: duration) - piece.start >= Music.minimumLength - 0.000001 else { removed.append(piece.id); continue }
            kept.append(piece)
        }
        guard !kept.isEmpty else { return (nil, removed) }
        var result = bed
        result.pieces = kept
        return (result, removed)
    }
}

// MARK: - Credits for YouTube

extension MusicBed {
    /// The credit lines for the description, each once, in the order the pieces play.
    var creditLines: [String] {
        var lines: [String] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            let line = piece.credit.line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    /// What Export for YouTube says about the music: a licence a monetised video cannot use
    /// or a file that is gone stops it; no licence or no credit line is a warning.
    var issues: [PublishInfo.Issue] {
        var issues: [PublishInfo.Issue] = []
        func add(_ severity: PublishInfo.Severity, _ message: String) { issues.append(.init(field: "music", severity: severity, message: message)) }
        for piece in pieces {
            if !FileManager.default.fileExists(atPath: piece.url.path) {
                add(.blocking, "The music file \(piece.url.lastPathComponent) is no longer there.")
            }
            guard let licence = piece.credit.licence else {
                add(.warning, "Set the licence of the music “\(piece.name)”, so the export can give its credit.")
                continue
            }
            if let block = licence.block { add(.blocking, "Do not use the music “\(piece.name)”: \(block)") }
            if licence == .ccBy, piece.credit.line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.warning, "CC BY needs a credit: give the credit line of the music “\(piece.name)”.")
            }
            if licence == .other { add(.warning, "Check that the licence of the music “\(piece.name)” permits a monetised YouTube video.") }
        }
        return issues
    }

    /// The MUSIC section of the text file for YouTube Studio.
    var uploadLines: [String] {
        var lines = ["MUSIC"]
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            let credit = piece.credit
            var line = "\(PublishInfo.timestamp(piece.start)) \(piece.name)"
            if !credit.artist.isEmpty { line += " by \(credit.artist)" }
            line += " · " + (credit.licence?.label ?? "licence not set")
            if !credit.source.isEmpty { line += " · " + credit.source }
            lines.append(line)
        }
        if pieces.contains(where: { $0.credit.licence == .generated }) {
            lines.append("Some music is made with AI. YouTube asks you to tell when AI music is the main focus of a video (Altered or synthetic content). A quiet bed is not the main focus; decide in YouTube Studio.")
        }
        return lines
    }

    var json: JSONValue {
        .array(pieces.sorted(by: { $0.start < $1.start }).map { piece in
            .object(["name": .string(piece.name), "file": .string(piece.url.lastPathComponent), "start": .number(piece.start),
                     "licence": piece.credit.licence.map { .string($0.rawValue) } ?? .null, "title": .string(piece.credit.title),
                     "artist": .string(piece.credit.artist), "source": .string(piece.credit.source), "line": .string(piece.credit.line)])
        })
    }
}

extension PublishInfo {
    /// The details as uploaded with this music: each credit line at the end of the
    /// description, unless the description has it.
    func crediting(_ music: MusicBed?) -> PublishInfo {
        let missing = (music?.creditLines ?? []).filter { !description.contains($0) }
        guard !missing.isEmpty else { return self }
        var copy = self
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.description = (body.isEmpty ? "" : body + "\n\n") + missing.joined(separator: "\n")
        return copy
    }
}
