import SwiftUI

/// The Sounds section of the Audio tab: short sounds on the graphics' motion, from the
/// owner's sound library (docs/plans/sound-effects.md, part 1).
struct SoundsSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    @State private var library: [SoundLibrary.Sound] = []

    var body: some View {
        let sounds = item.sounds
        InspectorSection("Sounds", isOn: Binding(get: { sounds?.on == true }, set: { model.setSoundsOn($0) })) {
            if let sounds, sounds.on {
                HStack(spacing: 6) {
                    Text("Level").font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    Slider(value: Binding(get: { sounds.level }, set: { level in model.setSoundsLevel(level.rounded(), live: true) }),
                           in: SoundSettings.levels, onEditingChanged: { editing in if !editing { model.endGesture() } })
                        .accessibilityLabel("Sound effects level")
                    Text(String(format: "%+.0f dB", sounds.level)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .help("Louder or softer than each cue's own level. 0 dB is the plan's level: a whoosh 8 LU under the voice.")
                ForEach(SoundCues.all, id: \.key) { cue in
                    Picker(cue.label, selection: Binding(get: { sounds.cues[cue.key] ?? "" },
                                                         set: { model.setSoundCue(cue.key, $0.isEmpty ? nil : $0) })) {
                        Text("Default · \(cue.sound)").tag("")
                        Text("Off").tag(SoundCues.off)
                        ForEach(library.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                    .help("The sound for this moment of the graphic. Default: \(cue.sound), \(Int(-cue.level)) LU under the voice.")
                }
                let missing = Set(item.placedCues(library: library).filter(\.missing).compactMap(\.sound))
                if !missing.isEmpty {
                    Label("Not in the library", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("These sounds are not in the sound library, so their cues are silent: \(missing.sorted().joined(separator: ", ")).")
                }
            } else {
                Text("A whoosh on cards, taps on the link card.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Short sounds that follow the graphics. Use only sounds whose licence permits a monetised YouTube video.")
            }
        }
        .task { library = SoundLibrary.load() }
    }
}

@MainActor
extension AppModel {
    /// The Sounds switch. The first time, the app measures the voice (or takes the music's).
    func setSoundsOn(_ on: Bool) {
        guard let item = selectedItem else { return }
        if var sounds = item.sounds {
            guard sounds.on != on else { return }
            sounds.on = on
            if case .failure(let error) = perform([.setSounds(clip: item.id, sounds: sounds)], label: on ? "Sounds On" : "Sounds Off") {
                statusMessage = error.message
            }
            return
        }
        guard on else { return }
        guard item.info?.hasAudio == true else { statusMessage = "This recording has no sound, so it cannot have sound effects."; return }
        statusMessage = "Measuring the loudness of the voice…"
        Task {
            do {
                let voice: Double
                if let known = item.music?.voice { voice = known } else { voice = try await FFmpeg.integratedLoudness(of: item.url) }
                switch perform([.setSounds(clip: item.id, sounds: SoundSettings(voice: voice))], label: "Sounds On") {
                case .success: statusMessage = SoundLibrary.load().isEmpty ? "Sounds on. Add sounds to the library first: yamvideoctl setsound." : "Sounds on."
                case .failure(let error): statusMessage = error.message
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// The sound of one cue: a name in the library, "off", or nil for its default.
    func setSoundCue(_ key: String, _ name: String?) {
        guard let item = selectedItem, var sounds = item.sounds, sounds.cues[key] != name else { return }
        sounds.cues[key] = name
        if case .failure(let error) = perform([.setSounds(clip: item.id, sounds: sounds)], label: "Sound Cue") { statusMessage = error.message }
    }

    /// The Level slider. `live` while it moves: one undo step when it ends.
    func setSoundsLevel(_ level: Double, live: Bool = false) {
        guard let item = selectedItem, var sounds = item.sounds else { return }
        sounds.level = level
        let command = EditCommand.setSounds(clip: item.id, sounds: sounds)
        let key = "sounds-level-\(item.id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: "Sounds Level", [command]) { statusMessage = error.message }
            if !live { endGesture() }
            return
        }
        if case .failure(let error) = perform([command], label: "Sounds Level") { statusMessage = error.message }
    }
}
