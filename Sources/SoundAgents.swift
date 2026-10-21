import Foundation

// Sound effects for local agents (docs/plans/sound-effects.md, part 1): setSounds as an
// `EditCommand`, the sounds as `state` shows them, and the owner's sound library, read
// with the sounds request and changed with setSound and removeSound.

extension AgentState {
    /// A recording's sound effects as an agent needs them. Times are edited seconds.
    struct SoundsState: Encodable {
        struct Choice: Encodable {
            var key: String
            var label: String
            /// The sound it plays, or "off".
            var sound: String
            /// LU under the voice, before the sounds' own level.
            var level: Double
            var custom: Bool
        }
        var on: Bool
        /// dB added to every cue's own level.
        var level: Double
        /// The voice's loudness (LUFS), as measured.
        var voice: Double
        var choices: [Choice]
        /// Every cue on the timeline, with its graphic, sound and gain.
        var cues: [PlacedCue]
    }
}

/// One sound of the library, as agents see it.
struct AgentSound: Encodable {
    var name: String
    var path: String
    var duration: Double
    var loudness: Double
    var peak: Double
    var credit: MusicCredit
}

struct AgentSounds: Encodable {
    var folder: String
    var sounds: [AgentSound]
    /// The cues and the sound each plays when a recording does not choose another.
    var defaults: [AgentState.SoundsState.Choice]
}

extension AppModel {
    static func soundsState(_ clip: ProjectClip) -> AgentState.SoundsState? {
        guard let sounds = clip.sounds else { return nil }
        let choices = SoundCues.all.map { cue in
            AgentState.SoundsState.Choice(key: cue.key, label: cue.label, sound: sounds.sound(for: cue) ?? SoundCues.off,
                                          level: cue.level, custom: sounds.cues[cue.key] != nil)
        }
        return AgentState.SoundsState(on: sounds.on, level: sounds.level, voice: sounds.voice, choices: choices,
                                      cues: clip.item().placedCues())
    }

    static func agentSounds() -> AgentSounds {
        AgentSounds(folder: SoundLibrary.folder.path,
                    sounds: SoundLibrary.load().map {
                        AgentSound(name: $0.name, path: SoundLibrary.url(of: $0).path, duration: $0.duration,
                                   loudness: $0.loudness, peak: $0.peak, credit: $0.credit)
                    },
                    defaults: SoundCues.all.map { .init(key: $0.key, label: $0.label, sound: $0.sound, level: $0.level, custom: false) })
    }

    /// setSounds {on, level, cues}: only the keys given change. The first time, the app
    /// measures the voice (or takes the music's measure).
    static func resolveSounds(_ wire: WireCommand, in document: VideoProject, voices: [UUID: Double]) throws -> EditCommand {
        guard let id = wire.clipID else { throw EditError.invalid("setSounds needs clipID.") }
        guard let clip = document.clips.first(where: { $0.id == id }) else { throw EditError.notFound("No recording \(id) in this project.") }
        guard let patch = wire.sounds else { throw EditError.invalid("setSounds needs sounds: {on, level, cues}.") }
        let known: Set<String> = ["on", "level", "cues"]
        if let unknown = patch.keys.first(where: { !known.contains($0) }) {
            throw EditError.invalid("Unknown setSounds key \"\(unknown)\". Keys: \(known.sorted().joined(separator: ", ")).")
        }
        var sounds: SoundSettings
        if let current = clip.sounds { sounds = current } else {
            guard let voice = clip.music?.voice ?? voices[id] else { throw EditError.invalid("Could not measure the voice of recording \(id).") }
            sounds = SoundSettings(voice: voice)
        }
        if let value = patch["on"] {
            guard case .bool(let on) = value else { throw EditError.invalid("sounds.on must be true or false.") }
            sounds.on = on
        }
        if let value = patch["level"] {
            guard let level = value.number, level.isFinite else { throw EditError.invalid("sounds.level must be a number of dB.") }
            sounds.level = level
        }
        if let value = patch["cues"] {
            guard let cues = value.object else { throw EditError.invalid("sounds.cues must be an object: {\"sectionCard.in\": \"whoosh-1\"}.") }
            for (key, choice) in cues {
                guard SoundCues.cue(key) != nil else {
                    throw EditError.invalid("Unknown sound cue \"\(key)\". Cues: \(SoundCues.all.map(\.key).joined(separator: ", ")).")
                }
                if choice == .null { sounds.cues[key] = nil; continue }
                guard let name = choice.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw EditError.invalid("A cue's sound is a name in the sound library, \"off\", or null for its default.")
                }
                sounds.cues[key] = name
            }
        }
        return .setSounds(clip: id, sounds: sounds)
    }

    /// setSound: a copy of the owner's file into the library, under `name`, measured.
    func agentSetSound(_ request: AgentRequest) async -> Result<AgentSounds, EditError> {
        guard let name = request.name, let path = request.path else {
            return .failure(.invalid("setSound needs name and path (a short sound file)."))
        }
        var credit = MusicCredit()
        if let fields = request.credit {
            for (key, value) in fields {
                switch key {
                case "licence":
                    guard let text = value.string, let licence = MusicLicence(rawValue: text) else {
                        return .failure(.invalid("Unknown licence. Licences: \(MusicLicence.allCases.map(\.rawValue).joined(separator: ", "))."))
                    }
                    credit.licence = licence
                case "title": credit.title = value.string ?? ""
                case "artist": credit.artist = value.string ?? ""
                case "source": credit.source = value.string ?? ""
                case "line": credit.line = value.string ?? ""
                default: return .failure(.invalid("Unknown credit key \"\(key)\". Keys: artist, licence, line, source, title."))
                }
            }
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        do { try await SoundLibrary.set(name: name, file: url, credit: credit) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The sound could not be kept: \(error.localizedDescription)")) }
        appendEvent(.job, origin: agentOrigin(request), label: "Sound \(name) kept", clips: [])
        return .success(Self.agentSounds())
    }

    func agentRemoveSound(_ request: AgentRequest) -> Result<AgentSounds, EditError> {
        guard let name = request.name else { return .failure(.invalid("removeSound needs name.")) }
        do { try SoundLibrary.remove(name: name) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The sound could not be removed: \(error.localizedDescription)")) }
        appendEvent(.job, origin: agentOrigin(request), label: "Sound \(name) removed", clips: [])
        return .success(Self.agentSounds())
    }
}
