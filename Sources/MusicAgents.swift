import Foundation

// Background music for local agents (docs/plans/background-music.md, part 1): the wire
// commands as `EditCommand`s, and the music as `state` shows it.

extension AgentState {
    /// A recording's music as an agent needs it. Times are edited-recording seconds; `gain`
    /// is the dB the export gives the file so that it sits `level` LU under the voice.
    struct MusicState: Encodable {
        struct Play: Encodable { var at: Double; var from: Double; var length: Double; var fadeIn: Double; var fadeOut: Double }
        struct Piece: Encodable {
            var id: UUID
            var path: String
            var name: String
            var start: Double
            var end: Double
            /// True when it plays to the end of the video, also after the edit changes the length.
            var toEnd: Bool
            var from: Double
            var level: Double
            var gain: Double
            var fadeIn: Double, fadeOut: Double
            var loop: Bool
            var fileDuration: Double
            var loudness: Double
            var credit: MusicCredit
            var plays: [Play]
            var missing: Bool
        }
        /// The voice's loudness (LUFS), as measured.
        var voice: Double
        var pieces: [Piece]
    }
}

extension AppModel {
    static func musicState(_ clip: ProjectClip) -> AgentState.MusicState? {
        guard let music = clip.music else { return nil }
        let duration = clip.timeline.duration
        return AgentState.MusicState(voice: music.voice, pieces: music.pieces.map { piece in
            AgentState.MusicState.Piece(
                id: piece.id, path: piece.url.path, name: piece.name, start: piece.start, end: piece.end(in: duration),
                toEnd: piece.end == nil, from: piece.from, level: piece.level, gain: (piece.gain(voice: music.voice) * 100).rounded() / 100,
                fadeIn: piece.fadeIn, fadeOut: piece.fadeOut, loop: piece.loop, fileDuration: piece.duration, loudness: piece.loudness,
                credit: piece.credit,
                plays: piece.plays(videoDuration: duration).map { .init(at: $0.at, from: $0.from, length: $0.length, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut) },
                missing: !FileManager.default.fileExists(atPath: piece.url.path))
        })
    }

    /// The music keys of `patch` on `piece`: start, end (null: to the end), from, level,
    /// fadeIn, fadeOut, loop, credit (only its keys given change).
    static func mergedMusic(_ patch: [String: JSONValue], onto piece: MusicPiece) throws -> MusicPiece {
        let known: Set<String> = ["path", "start", "end", "from", "level", "fadeIn", "fadeOut", "loop", "credit"]
        if let unknown = patch.keys.first(where: { !known.contains($0) }) {
            throw EditError.invalid("Unknown music key \"\(unknown)\". Keys: \(known.sorted().joined(separator: ", ")).")
        }
        var piece = piece
        func number(_ key: String) throws -> Double? {
            guard let value = patch[key] else { return nil }
            guard let number = value.number, number.isFinite else { throw EditError.invalid("music.\(key) must be a number.") }
            return number
        }
        if let start = try number("start") { piece.start = start }
        if let value = patch["end"] {
            if value == .null { piece.end = nil } else { piece.end = try number("end") }
        }
        if let from = try number("from") { piece.from = from }
        if let level = try number("level") { piece.level = level }
        if let fadeIn = try number("fadeIn") { piece.fadeIn = fadeIn }
        if let fadeOut = try number("fadeOut") { piece.fadeOut = fadeOut }
        if let value = patch["loop"] {
            guard case .bool(let loop) = value else { throw EditError.invalid("music.loop must be true or false.") }
            piece.loop = loop
        }
        if let value = patch["credit"] {
            guard let credit = value.object else { throw EditError.invalid("music.credit must be an object: {licence, title, artist, source, line}.") }
            let keys: Set<String> = ["licence", "title", "artist", "source", "line"]
            if let unknown = credit.keys.first(where: { !keys.contains($0) }) {
                throw EditError.invalid("Unknown credit key \"\(unknown)\". Keys: \(keys.sorted().joined(separator: ", ")).")
            }
            if let licence = credit["licence"] {
                if licence == .null { piece.credit.licence = nil } else {
                    guard let name = licence.string, let value = MusicLicence(rawValue: name) else {
                        throw EditError.invalid("Unknown licence. Licences: \(MusicLicence.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    piece.credit.licence = value
                }
            }
            func text(_ key: String) throws -> String? {
                guard let value = credit[key] else { return nil }
                guard let text = value.string else { throw EditError.invalid("music.credit.\(key) must be text.") }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let title = try text("title") { piece.credit.title = title }
            if let artist = try text("artist") { piece.credit.artist = artist }
            if let source = try text("source") { piece.credit.source = source }
            if let line = try text("line") { piece.credit.line = line }
        }
        return piece
    }

    /// addMusic, updateMusic and removeMusic as edit commands. `measured` holds each music
    /// file's length and loudness, and `voices` the voice of a recording with no music yet.
    static func resolveMusic(_ wire: WireCommand, in document: VideoProject, measured: [String: (duration: Double, loudness: Double)],
                             voices: [UUID: Double]) throws -> EditCommand {
        guard let id = wire.clipID else { throw EditError.invalid("\(wire.type) needs clipID.") }
        guard let clip = document.clips.first(where: { $0.id == id }) else { throw EditError.notFound("No recording \(id) in this project.") }
        func current() throws -> MusicPiece {
            guard let musicID = wire.musicID else { throw EditError.invalid("\(wire.type) needs musicID.") }
            guard let piece = clip.music?.pieces.first(where: { $0.id == musicID }) else {
                throw EditError.notFound("No piece of music \(musicID) on recording \(id).")
            }
            return piece
        }
        func file(_ path: String) throws -> (url: URL, duration: Double, loudness: Double) {
            guard let found = measured[path] else { throw EditError(code: .missingMedia, message: "Could not measure \(path).") }
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL, found.duration, found.loudness)
        }
        switch wire.type {
        case "addMusic":
            guard let path = wire.path else { throw EditError.invalid("addMusic needs path, a local sound file.") }
            let sound = try file(path)
            guard let voice = clip.music?.voice ?? voices[id] else { throw EditError.invalid("Could not measure the voice of recording \(id).") }
            let duration = clip.timeline.duration
            let start = wire.start ?? 0
            var piece = MusicPiece(id: wire.musicID ?? UUID(), url: sound.url, duration: sound.duration, loudness: sound.loudness,
                                   start: start, end: wire.end.flatMap { $0 >= duration - 0.0005 ? nil : $0 })
            if wire.end == nil, let next = clip.music?.pieces.map(\.start).filter({ $0 > start }).min() { piece.end = next }
            if let patch = wire.music { piece = try mergedMusic(patch.filter { $0.key != "path" }, onto: piece) }
            return .addMusic(clip: id, piece: piece, voice: voice)
        case "updateMusic":
            guard let patch = wire.music else { throw EditError.invalid("updateMusic needs music, the keys to change.") }
            var piece = try mergedMusic(patch, onto: try current())
            if let path = patch["path"]?.string {
                let sound = try file(path)
                piece.url = sound.url; piece.duration = sound.duration; piece.loudness = sound.loudness
                if piece.from > sound.duration - Music.minimumLength { piece.from = 0 }
            }
            return .updateMusic(clip: id, piece: piece)
        case "removeMusic":
            return .removeMusic(clip: id, piece: try current().id)
        default:
            throw EditError(code: .unsupportedCapability, message: "Unknown music command \(wire.type).")
        }
    }
}
