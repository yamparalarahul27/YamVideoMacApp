import AppKit
import Foundation
import UniformTypeIdentifiers

/// What the Music row and the Music section do. Drags are clamped here (a piece dragged
/// into its neighbour stops at it), then go through the same strict commands agents use.
@MainActor
extension AppModel {
    var selectedMusic: MusicPiece? {
        guard let selectedMusicID else { return nil }
        return selectedItem?.music?.pieces.first { $0.id == selectedMusicID }
    }

    /// Add Music…: a sound file under the voice, from the playhead to the end of the video
    /// or to the next piece.
    func chooseMusicFile() {
        guard let item = selectedItem, item.info != nil else { statusMessage = "Select a recording first."; return }
        guard item.info?.hasAudio == true else { statusMessage = "This recording has no sound, so it cannot have music under it."; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Music.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose music to play under \(item.name). Use only music whose licence permits a monetised YouTube video."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addMusic(url)
    }

    /// Where a new piece goes at `time`: there, or at the start of the empty part after the
    /// piece that plays there.
    func musicRoom(at time: Double, in item: VideoItem) -> ClosedRange<Double>? {
        let duration = item.editedDuration
        let bed = item.music ?? MusicBed(voice: -20, pieces: [])
        if let room = bed.room(at: min(time, max(0, duration - Music.minimumLength)), duration: duration) { return room }
        let after = bed.pieces.map { $0.end(in: duration) }.filter { $0 >= time - 0.000001 }.sorted()
        return after.lazy.compactMap { bed.room(at: $0, duration: duration) }.first
    }

    func addMusic(_ url: URL, at time: Double? = nil) {
        guard let item = selectedItem, item.info?.hasAudio == true else { return }
        guard !timelineTracks.locked.contains(.music) else { statusMessage = "Music is locked. Unlock it to add music."; return }
        guard let room = musicRoom(at: time ?? previewTime, in: item) else {
            statusMessage = "The Music row has no empty part of \(Int(Music.minimumLength)) s or more after the playhead."
            return
        }
        statusMessage = item.music == nil ? "Measuring the loudness of the voice and of \(url.lastPathComponent)…" : "Measuring \(url.lastPathComponent)…"
        Task {
            do {
                let file = try await FFmpeg.measureMusic(url)
                let voice: Double
                if let known = item.music?.voice { voice = known } else { voice = try await FFmpeg.integratedLoudness(of: item.url) }
                let duration = item.editedDuration
                let piece = MusicPiece(url: url, duration: file.duration, loudness: file.loudness, start: room.lowerBound,
                                       end: room.upperBound >= duration - 0.0005 ? nil : room.upperBound)
                switch perform([.addMusic(clip: item.id, piece: piece, voice: voice)]) {
                case .success:
                    selectedMusicID = piece.id
                    statusMessage = "Added \(url.lastPathComponent), \(Int(-piece.level)) LU under the voice. Set its licence in the inspector."
                case .failure(let error): statusMessage = error.message
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Changes one piece. `live` while a slider moves or a bar is dragged: shown at once and
    /// committed as one undo step when it ends.
    func updateMusic(_ id: UUID, live: Bool = false, label: String = "Edit Music", _ change: (inout MusicPiece) -> Void) {
        guard let item = selectedItem, let original = item.music?.pieces.first(where: { $0.id == id }) else { return }
        guard !timelineTracks.locked.contains(.music) else { statusMessage = "Music is locked. Unlock it to change it."; return }
        var piece = original
        change(&piece)
        let command = EditCommand.updateMusic(clip: item.id, piece: piece)
        let key = "music-\(id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: label, [command]) { statusMessage = error.message }
            if !live { endGesture() }
            return
        }
        guard piece != original else { return }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    /// Where a piece may sit: after the piece before it, and before the piece after it or
    /// the end of the video.
    private func musicLimits(_ id: UUID, in item: VideoItem) -> ClosedRange<Double> {
        let duration = item.editedDuration
        let others = (item.music?.pieces ?? []).filter { $0.id != id }
        guard let piece = item.music?.pieces.first(where: { $0.id == id }) else { return 0...duration }
        let low = others.map { $0.end(in: duration) }.filter { $0 <= piece.start + 0.0005 }.max() ?? 0
        let high = others.map(\.start).filter { $0 >= piece.start - 0.0005 }.min() ?? duration
        return low...max(low, high)
    }

    /// Moves a piece and keeps its length, between its neighbours. A piece that plays to the
    /// end of the video keeps to the end: only its start moves.
    func moveMusic(_ id: UUID, to start: Double, live: Bool = false) {
        guard let item = selectedItem, let piece = item.music?.pieces.first(where: { $0.id == id }) else { return }
        let duration = item.editedDuration
        let limits = musicLimits(id, in: item)
        if piece.end == nil {
            setMusicStart(id, to: start, live: live, label: "Move Music")
            return
        }
        let length = piece.end(in: duration) - piece.start
        let begin = max(limits.lowerBound, min(start, limits.upperBound - length))
        updateMusic(id, live: live, label: "Move Music") { piece in
            piece.start = begin
            piece.end = begin + length
        }
    }

    /// Moves the start of a piece; its end stays.
    func setMusicStart(_ id: UUID, to start: Double, live: Bool = false, label: String = "Change Music Start") {
        guard let item = selectedItem, let piece = item.music?.pieces.first(where: { $0.id == id }) else { return }
        let limits = musicLimits(id, in: item)
        let begin = max(limits.lowerBound, min(start, piece.end(in: item.editedDuration) - Music.minimumLength))
        updateMusic(id, live: live, label: label) { $0.start = begin }
    }

    /// Moves the end of a piece. At the end of the video, the piece plays to the end, also
    /// after the edit changes the length.
    func setMusicEnd(_ id: UUID, to end: Double, live: Bool = false) {
        guard let item = selectedItem, let piece = item.music?.pieces.first(where: { $0.id == id }) else { return }
        let limits = musicLimits(id, in: item)
        let duration = item.editedDuration
        let stop = max(piece.start + Music.minimumLength, min(end, limits.upperBound))
        updateMusic(id, live: live, label: "Change Music Length") { piece in
            piece.end = stop >= duration - 0.0005 ? nil : stop
        }
    }

    /// Replace…: another file in the same place, with the same level, fades and loop.
    func replaceMusicFile(_ id: UUID) {
        guard let item = selectedItem, item.music?.pieces.contains(where: { $0.id == id }) == true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Music.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the music to use in place of this piece."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        statusMessage = "Measuring \(url.lastPathComponent)…"
        Task {
            do {
                let file = try await FFmpeg.measureMusic(url)
                updateMusic(id, label: "Replace Music") { piece in
                    piece.url = url
                    piece.duration = file.duration
                    piece.loudness = file.loudness
                    if piece.from > file.duration - Music.minimumLength { piece.from = 0 }
                    piece.credit = MusicCredit()
                }
                statusMessage = "Replaced the music with \(url.lastPathComponent). Set its licence in the inspector."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func removeSelectedMusic() {
        guard let item = selectedItem, let id = selectedMusicID else { return }
        guard !timelineTracks.locked.contains(.music) else { statusMessage = "Music is locked. Unlock it to delete."; return }
        if case .failure(let error) = perform([.removeMusic(clip: item.id, piece: id)]) { statusMessage = error.message }
        else { selectedMusicID = nil }
    }
}
