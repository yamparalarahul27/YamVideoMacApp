import Foundation
import JavaScriptCore

// MARK: - Sound effects (docs/plans/sound-effects.md, part 1)
//
// Short sounds that follow the graphics: a whoosh when a section card comes in, a tap for
// each letter a link card types. The graphics engine gives the moment of each cue
// (`soundCues` in graphics.js), so a sound moves with its graphic and its motion. The
// sounds are files in the owner's sound library, at a level in LU under the voice.

/// The owner's short sounds, kept for every project in the app's own folder, with
/// sounds.json naming each one. Agents add one with `setSound` (a copy of the owner's
/// file), never by writing into the folder.
enum SoundLibrary {
    struct Sound: Codable, Equatable {
        /// What cues call it: "whoosh-1".
        var name: String
        /// The file's name in the folder.
        var file: String
        var duration: Double
        /// The loudest 400 ms (momentary loudness), in LUFS. A sound is short, so its
        /// integrated loudness says little.
        var loudness: Double
        /// The sample peak, in dBFS.
        var peak: Double
        var credit = MusicCredit()
    }

    /// A cue is short: longer files are refused.
    static let longest = 6.0
    static let fileTypes = Music.fileTypes

    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_SOUNDS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Sounds", isDirectory: true)
    }
    static var index: URL { folder.appendingPathComponent("sounds.json") }

    static func url(of sound: Sound) -> URL { folder.appendingPathComponent(sound.file) }

    /// Every sound whose file is there, by name.
    static func load() -> [Sound] {
        guard let data = try? Data(contentsOf: index),
              let sounds = try? JSONDecoder().decode([Sound].self, from: data) else { return [] }
        return sounds.filter { FileManager.default.fileExists(atPath: url(of: $0).path) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The loudest 400 ms (LUFS) and the sample peak (dBFS) of a short file, as ffmpeg
    /// measures them. The file is padded with silence, so a sound shorter than 400 ms
    /// still gets a value.
    static func measure(_ url: URL) async throws -> (duration: Double, loudness: Double, peak: Double) {
        guard Music.isMusicFile(url) else {
            throw EditError.invalid("Use a sound file: \(fileTypes.map { $0.uppercased() }.joined(separator: ", ")).")
        }
        guard let ffmpeg = FFmpeg.ffmpegPath, let ffprobe = FFmpeg.ffprobePath else { throw EditError.invalid("ffmpeg was not found.") }
        let probe = try await Shell.run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "format=duration",
                                                  "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        guard probe.status == 0, let duration = Double(probe.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration > 0.01 else { throw EditError.invalid("\(url.lastPathComponent) has no sound.") }
        guard duration <= longest else {
            throw EditError.invalid(String(format: "%@ is %.1f s. A sound is %.0f s or shorter; use music for longer files.", url.lastPathComponent, duration, longest))
        }
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0",
                                                  "-af", "apad=pad_dur=0.5,ebur128=framelog=info,volumedetect", "-vn", "-f", "null", "-"])
        try Task.checkCancellation()
        let text = result.stderrText
        let loudest = text.components(separatedBy: "M:").dropFirst()
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }.max()
        let peak = text.components(separatedBy: "max_volume:").dropFirst().first
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
        guard result.status == 0, let loudest, loudest > -70, let peak else {
            throw EditError.invalid("\(url.lastPathComponent) is silent, so it cannot be a sound.")
        }
        return (duration, loudest, peak)
    }

    /// Adds a sound, or replaces the one of the same name (without case): a copy of `file`,
    /// measured first.
    @discardableResult
    static func set(name rawName: String, file: URL, credit: MusicCredit) async throws -> Sound {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), !name.contains("\n"), name.lowercased() != SoundCues.off else {
            throw EditError.invalid("A sound's name is one line of 1 to 40 characters, and not \"off\".")
        }
        if let problem = credit.problem { throw EditError.invalid(problem) }
        let measured = try await measure(file)
        guard let bytes = try? Data(contentsOf: file), !bytes.isEmpty else { throw EditError.invalid("The sound file \(file.path) cannot be read.") }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var sounds = (try? JSONDecoder().decode([Sound].self, from: Data(contentsOf: index))) ?? []
        if let old = sounds.first(where: { $0.name.lowercased() == name.lowercased() }) {
            try? manager.removeItem(at: folder.appendingPathComponent(old.file))
            sounds.removeAll { $0.name.lowercased() == name.lowercased() }
        }
        let stem = name.map { "/:\\".contains($0) ? "-" : $0 }.reduce("") { $0 + String($1) }
        let sound = Sound(name: name, file: "\(stem).\(file.pathExtension.lowercased())", duration: measured.duration,
                          loudness: measured.loudness, peak: measured.peak, credit: credit)
        try bytes.write(to: folder.appendingPathComponent(sound.file), options: .atomic)
        sounds.append(sound)
        try write(sounds)
        return sound
    }

    static func remove(name: String) throws {
        var sounds = (try? JSONDecoder().decode([Sound].self, from: Data(contentsOf: index))) ?? []
        guard let old = sounds.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw EditError.notFound("There is no sound named \(name).")
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file))
        sounds.removeAll { $0.name.lowercased() == name.lowercased() }
        try write(sounds)
    }

    /// The credit lines of these sounds for the description, each once.
    static func creditLines(_ sounds: [Sound]) -> [String] {
        var lines: [String] = []
        for sound in sounds {
            let line = sound.credit.line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    /// What Export for YouTube says about these sounds: a licence a monetised video cannot
    /// use stops it; no licence, "other" and CC BY with no credit line are warnings.
    static func issues(_ sounds: [Sound]) -> [PublishInfo.Issue] {
        var issues: [PublishInfo.Issue] = []
        func add(_ severity: PublishInfo.Severity, _ message: String) { issues.append(.init(field: "sounds", severity: severity, message: message)) }
        for sound in sounds {
            guard let licence = sound.credit.licence else {
                add(.warning, "Set the licence of the sound “\(sound.name)”: yamvideoctl setsound with --licence.")
                continue
            }
            if let block = licence.block { add(.blocking, "Do not use the sound “\(sound.name)”: \(block)") }
            if licence == .ccBy, sound.credit.line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.warning, "CC BY needs a credit: give the credit line of the sound “\(sound.name)”.")
            }
            if licence == .other { add(.warning, "Check that the licence of the sound “\(sound.name)” permits a monetised YouTube video.") }
        }
        return issues
    }

    private static func write(_ sounds: [Sound]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(sounds.sorted { $0.name.lowercased() < $1.name.lowercased() }).write(to: index, options: .atomic)
    }
}

/// A recording's sound effects. Version 23 onwards; nil: none.
struct SoundSettings: Codable, Equatable {
    /// Off keeps the choices, but no cue plays.
    var on = true
    /// dB added to every cue's own level.
    var level = 0.0
    /// The voice's loudness (LUFS), as measured when the sounds went on.
    var voice: Double
    /// A cue's sound by the cue's key ("sectionCard.in"): a name in the library, or "off".
    /// A cue that is not here plays its default sound.
    var cues: [String: String] = [:]

    static let levels = -12.0...6.0

    var problem: String? {
        guard level.isFinite, Self.levels.contains(level) else {
            return String(format: "The sounds' level must be from %.0f to %.0f dB.", Self.levels.lowerBound, Self.levels.upperBound)
        }
        guard voice.isFinite, Music.loudnessRange.contains(voice) else { return "The sounds have no measured loudness of the voice." }
        if let key = cues.keys.first(where: { SoundCues.cue($0) == nil }) {
            return "Unknown sound cue \"\(key)\". Cues: \(SoundCues.all.map(\.key).joined(separator: ", "))."
        }
        if cues.values.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.count > 40 }) {
            return "A cue's sound is a name in the sound library (1 to 40 characters), or \"off\"."
        }
        return nil
    }

    /// The sound a cue plays, or nil when it is off.
    func sound(for cue: SoundCues.Cue) -> String? {
        let name = cues[cue.key] ?? cue.sound
        return name.lowercased() == SoundCues.off ? nil : name
    }
}

/// The cues that have a sound, and how loud each one is.
enum SoundCues {
    /// A moment of a graphic's motion that has a sound: its default sound and its level in
    /// LU under the voice. The engine names the moment (`cue`); the key is kind.cue.
    struct Cue: Equatable {
        var kind: GraphicKind
        var cue: String
        var label: String
        var sound: String
        var level: Double
        var key: String { "\(kind.rawValue).\(cue)" }
    }

    static let off = "off"
    /// No cue peaks above this (dBFS). A click of 0.12 s has a low 400 ms loudness, so the
    /// level alone would give it too much gain.
    static let peakCap = -12.0

    /// Part 1: section cards, title cards and link cards. The defaults are the owner's
    /// kit, from the Tradl mock-up of 21 Oct 2026.
    static let all: [Cue] = [
        Cue(kind: .sectionCard, cue: "in", label: "Section card", sound: "whoosh-1", level: -8),
        Cue(kind: .titleCard, cue: "in", label: "Title card", sound: "whoosh-1", level: -11),
        Cue(kind: .link, cue: "click", label: "Link click", sound: "button-4", level: -12),
        Cue(kind: .link, cue: "key", label: "Link key", sound: "button-1", level: -12),
        Cue(kind: .link, cue: "open", label: "Link window", sound: "whoosh-2", level: -10),
    ]

    static func cue(_ key: String) -> Cue? { all.first { $0.key == key } }
    static func cue(kind: GraphicKind, _ name: String) -> Cue? { all.first { $0.kind == kind && $0.cue == name } }

    /// The gain (dB) that puts `sound` `level` LU under a voice of `voice` LUFS, with its
    /// peak at `peakCap` or lower.
    static func gain(_ sound: SoundLibrary.Sound, level: Double, voice: Double) -> Double {
        min(voice + level - sound.loudness, peakCap - sound.peak)
    }

    // The engine runs in JavaScriptCore: soundCues is pure, so it needs no page.
    private final class Engine: @unchecked Sendable {
        let lock = NSLock()
        var context: JSContext?
        var loaded = false
        var cache: [String: [(at: Double, cue: String)]] = [:]
    }
    private static let engine = Engine()

    /// The engine's cues for one graphic: `at` in seconds after the graphic starts.
    static func engineCues(kind: GraphicKind, props: [String: JSONValue], length: Double) -> [(at: Double, cue: String)] {
        guard all.contains(where: { $0.kind == kind }),
              let propsData = try? JSONEncoder().encode(props), let propsText = String(data: propsData, encoding: .utf8),
              let kindData = try? JSONEncoder().encode(kind.rawValue), let kindText = String(data: kindData, encoding: .utf8) else { return [] }
        let key = "\(kindText)|\(propsText)|\(String(format: "%.4f", length))"
        engine.lock.lock(); defer { engine.lock.unlock() }
        if let cached = engine.cache[key] { return cached }
        if !engine.loaded {
            engine.loaded = true
            if let folder = GraphicsEngine.resources, let source = try? String(contentsOf: folder.appendingPathComponent("graphics.js"), encoding: .utf8),
               let context = JSContext() {
                context.evaluateScript(source)
                engine.context = context
            }
        }
        guard let context = engine.context,
              let text = context.evaluateScript("JSON.stringify(YamGraphics.soundCues(\(kindText), \(propsText), \(length)))")?.toString(),
              let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let cues = rows.compactMap { row -> (at: Double, cue: String)? in
            guard let at = (row["at"] as? NSNumber)?.doubleValue, let cue = row["cue"] as? String else { return nil }
            return (at, cue)
        }
        if engine.cache.count > 512 { engine.cache.removeAll() }
        engine.cache[key] = cues
        return cues
    }
}

/// One cue on the edited timeline, with the sound it plays.
struct PlacedCue: Equatable, Encodable {
    /// Edited seconds.
    var at: Double
    var graphicID: UUID
    var key: String
    /// The sound's name, or nil when the cue is off.
    var sound: String?
    /// dB, or nil when the cue is off or its sound is not in the library.
    var gain: Double?
    /// The sound is named but not in the library.
    var missing: Bool
    /// The sound's file, when it is there.
    var url: URL?
    var duration: Double?

    private enum CodingKeys: String, CodingKey { case at, graphicID, key, sound, gain, missing }
}

extension VideoItem {
    /// The library sounds this recording's cues play, each once, in the order they first play.
    var usedSounds: [SoundLibrary.Sound] {
        guard sounds?.on == true, graphics != nil else { return [] }
        let library = SoundLibrary.load()
        var used: [SoundLibrary.Sound] = []
        for cue in placedCues(library: library) {
            guard let name = cue.sound, let sound = library.first(where: { $0.name.lowercased() == name.lowercased() }),
                  !used.contains(sound) else { continue }
            used.append(sound)
        }
        return used
    }

    /// Every cue of this recording's graphics, in edited seconds, with its sound and its
    /// gain. Empty while the sounds are off.
    func placedCues(library: [SoundLibrary.Sound]? = nil) -> [PlacedCue] {
        guard let sounds, sounds.on, let graphics else { return [] }
        let library = library ?? SoundLibrary.load()
        let duration = editedDuration
        var placed: [PlacedCue] = []
        for graphic in graphics.items {
            for found in SoundCues.engineCues(kind: graphic.kind, props: graphic.props, length: graphic.end - graphic.start) {
                guard let cue = SoundCues.cue(kind: graphic.kind, found.cue) else { continue }
                let at = graphic.start + found.at
                guard at >= 0, at < duration else { continue }
                let name = sounds.sound(for: cue)
                let sound = name.flatMap { name in library.first { $0.name.lowercased() == name.lowercased() } }
                placed.append(PlacedCue(at: (at * 1000).rounded() / 1000, graphicID: graphic.id, key: cue.key, sound: name,
                                        gain: sound.map { (SoundCues.gain($0, level: cue.level + sounds.level, voice: sounds.voice) * 100).rounded() / 100 },
                                        missing: name != nil && sound == nil, url: sound.map(SoundLibrary.url(of:)), duration: sound?.duration))
            }
        }
        return placed.sorted { ($0.at, $0.key) < ($1.at, $1.key) }
    }
}
