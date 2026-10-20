import SwiftUI

/// The Music section of the Audio tab: the pieces under the voice, and Add Music.
struct MusicSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem

    var body: some View {
        let pieces = item.music?.pieces ?? []
        let duration = item.editedDuration
        InspectorSection("Music", isOn: changeSwitch(.music, item, model)) {
            if pieces.isEmpty {
                Text("Quiet music under your voice.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Use only music whose licence permits a monetised YouTube video.")
            }
            ForEach(pieces) { piece in
                Button { model.selectedMusicID = piece.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note").foregroundStyle(.mint)
                        Text(piece.name).lineLimit(1).truncationMode(.middle)
                        if piece.credit.licence == nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("No licence set")
                        }
                        Spacer(minLength: 4)
                        Text("\(timelineTime(piece.start))–\(timelineTime(piece.end(in: duration)))")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select it to set its level, fades and licence")
            }
            Button { model.chooseMusicFile() } label: { Label("Add Music…", systemImage: "plus") }
                .disabled(item.info?.hasAudio != true)
                .help("Add a sound file under the voice, at the playhead. It plays to the end of the video or to the next piece.")
        }
    }
}

/// The selected piece of music: its level under the voice, its fades and loop, and where it
/// comes from.
struct MusicInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let piece: MusicPiece

    var body: some View {
        let duration = item.editedDuration
        InspectorSection(piece.name) {
            Text("\(timelineTime(piece.start))–\(timelineTime(piece.end(in: duration)))"
                 + (piece.end == nil ? " · to the end" : "") + " · file \(formatDuration(piece.duration))")
                .font(.caption).foregroundStyle(.secondary)
            row("Level", value: "\(Int(piece.level.rounded())) LU", help: "How loud the music is under the voice. −20 LU is quiet; −10 LU is loud.") {
                Slider(value: Binding(get: { piece.level }, set: { level in
                    model.updateMusic(piece.id, live: true, label: "Music Level") { $0.level = level.rounded() }
                }), in: Music.levels, onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Music level under the voice")
            }
            row("Fade in", value: String(format: "%.1f s", piece.fadeIn), help: "How long the music takes to come up at its start") {
                Slider(value: Binding(get: { piece.fadeIn }, set: { fade in
                    model.updateMusic(piece.id, live: true, label: "Music Fade In") { $0.fadeIn = (fade * 2).rounded() / 2 }
                }), in: Music.fades, onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Music fade in")
            }
            row("Fade out", value: String(format: "%.1f s", piece.fadeOut), help: "How long the music takes to go at its end") {
                Slider(value: Binding(get: { piece.fadeOut }, set: { fade in
                    model.updateMusic(piece.id, live: true, label: "Music Fade Out") { $0.fadeOut = (fade * 2).rounded() / 2 }
                }), in: Music.fades, onEditingChanged: { editing in if !editing { model.endGesture() } })
                    .accessibilityLabel("Music fade out")
            }
            Toggle("Loop", isOn: Binding(get: { piece.loop }, set: { loop in model.updateMusic(piece.id, label: "Music Loop") { $0.loop = loop } }))
                .help("Play the file again, with a \(Int(Music.crossfade)) s crossfade, when the piece is longer than the file")
            Divider()
            Picker("Licence", selection: Binding(get: { piece.credit.licence }, set: { licence in
                model.updateMusic(piece.id, label: "Music Licence") { $0.credit.licence = licence }
            })) {
                Text("Not set").tag(MusicLicence?.none)
                ForEach(MusicLicence.allCases) { Text($0.label).tag(MusicLicence?.some($0)) }
            }
            .help("Where the music comes from. Export for YouTube gives the credit, and stops a licence that a monetised video cannot use.")
            if let block = piece.credit.licence?.block {
                Label("Not allowed", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red).help(block)
            } else if piece.credit.licence == nil {
                Label("Set the licence", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Export for YouTube warns until the licence is set.")
            }
            PublishTextField(placeholder: "Credit", value: piece.credit.line, axis: .horizontal) { text in
                model.updateMusic(piece.id, label: "Music Credit") { $0.credit.line = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .help("The line for the description, for example “Music: Calm by Ana (CC BY 4.0)”. Export for YouTube adds it.")
            PublishTextField(placeholder: "Source", value: piece.credit.source, axis: .horizontal) { text in
                model.updateMusic(piece.id, label: "Music Source") { $0.credit.source = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .help("The page of the track. Keep it as proof of the licence.")
            HStack {
                Button("Replace…") { model.replaceMusicFile(piece.id) }
                    .help("Use another file in the same place, with the same level and fades")
                Button("Remove", role: .destructive) { model.removeSelectedMusic() }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func row<Control: View>(_ label: String, value: String, help: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            control()
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .help(help)
    }
}
