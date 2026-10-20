import AVFoundation
import Foundation

// The music in an export (docs/plans/background-music.md, part 1): each file is one more
// ffmpeg input, each play is cut, faded, set to its gain and put in its place, and `amix`
// adds the plays to the voice. Loudness then normalises the mix.

extension FFmpeg {
    /// Each music file as an ffmpeg input, in the order of `mix.files`.
    static func musicInputs(_ mix: MusicMix) -> [String] {
        mix.files.flatMap { ["-i", $0.path] }
    }

    /// Graph parts that read the music inputs (from `firstInput`) and `[voice]`, and write
    /// `[output]`: the voice with every play of the music under it, as long as the voice.
    static func musicGraph(_ mix: MusicMix, firstInput: Int, voice: String, output: String, prefix: String = "mu") -> [String] {
        var parts: [String] = []
        var outputs: [String] = []
        for file in mix.files.indices {
            let plays = mix.plays.indices.filter { mix.plays[$0].file == file }
            guard !plays.isEmpty else { continue }
            parts.append("[\(firstInput + file):a:0]asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asplit=\(plays.count)"
                         + plays.map { "[\(prefix)s\($0)]" }.joined())
        }
        for (index, entry) in mix.plays.enumerated() {
            let play = entry.play
            var chain = "[\(prefix)s\(index)]atrim=start=\(String(format: "%.6f", play.from)):duration=\(String(format: "%.6f", play.length)),asetpts=PTS-STARTPTS"
            if play.fadeIn > 0 { chain += ",afade=t=in:d=\(num(play.fadeIn))" }
            if play.fadeOut > 0 { chain += ",afade=t=out:st=\(num(max(0, play.length - play.fadeOut))):d=\(num(play.fadeOut))" }
            chain += ",volume=\(String(format: "%.2f", entry.gain))dB"
            chain += ",adelay=delays=\(Int((play.at * 48000).rounded()))S:all=1[\(prefix)\(index)]"
            parts.append(chain)
            outputs.append("[\(prefix)\(index)]")
        }
        parts.append("[\(voice)]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[\(prefix)voice]")
        parts.append("[\(prefix)voice]" + outputs.joined()
                     + "amix=inputs=\(outputs.count + 1):normalize=0:duration=first:dropout_transition=0[\(output)]")
        return parts
    }

    /// The loudness pass for a recording with music: the edited voice with the music under
    /// it, measured as the export plays it. (Without music, the pass measures the source.)
    static func loudnessArguments(input: URL, segments: [TimelineSegment], fpsExpression: String, music: MusicMix) -> [String] {
        var parts = timelineAudioGraph(segments: segments, fpsExpression: fpsExpression)
        parts += musicGraph(music, firstInput: 1, voice: "timelinea", output: "mixa")
        parts.append("[mixa]loudnorm=\(Loudness.filterTargets):print_format=json[measured]")
        return ["-hide_banner", "-nostdin", "-y", "-i", input.path] + musicInputs(music)
            + ["-filter_complex", parts.joined(separator: ";"), "-map", "[measured]",
               "-vn", "-f", "null", "-progress", "pipe:1", "-nostats", "-"]
    }

    /// The integrated loudness of a file's first sound track, in LUFS: `loudnorm`'s
    /// measure, as the export's loudness pass makes it.
    static func integratedLoudness(of url: URL) async throws -> Double {
        guard let ffmpeg = ffmpegPath else { throw FFmpegError(message: "ffmpeg was not found.") }
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0",
                                                  "-af", "loudnorm=\(Loudness.filterTargets):print_format=json", "-vn", "-f", "null", "-"])
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw FFmpegError(message: "Could not measure the loudness of \(url.lastPathComponent): \(result.stderrText.suffix(300))")
        }
        guard let measured = parseLoudness(result.stderrText), let value = Double(measured.inputI) else {
            throw FFmpegError(message: "\(url.lastPathComponent) is silent, so it has no loudness.")
        }
        return max(Music.loudnessRange.lowerBound, min(Music.loudnessRange.upperBound, value))
    }

    /// A music file's length in seconds, and its loudness. It must have sound and be one of
    /// `Music.fileTypes`, so the preview can play it too.
    static func measureMusic(_ url: URL) async throws -> (duration: Double, loudness: Double) {
        guard Music.isMusicFile(url) else {
            throw FFmpegError(message: "Use a sound file: \(Music.fileTypes.map { $0.uppercased() }.joined(separator: ", ")).")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw FFmpegError(message: "No file at \(url.path).") }
        guard let ffprobe = ffprobePath else { throw FFmpegError(message: "ffprobe was not found.") }
        let probe = try await Shell.run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_type:format=duration",
                                                  "-of", "default=noprint_wrappers=1", url.path])
        let lines = probe.stdoutText.split(separator: "\n")
        guard probe.status == 0, lines.contains("codec_type=audio") else {
            throw FFmpegError(message: "\(url.lastPathComponent) has no sound.")
        }
        guard let text = lines.first(where: { $0.hasPrefix("duration=") })?.dropFirst("duration=".count),
              let duration = Double(text), duration.isFinite, duration >= Music.minimumLength else {
            throw FFmpegError(message: "\(url.lastPathComponent) is shorter than \(Int(Music.minimumLength)) s.")
        }
        return (duration, try await integratedLoudness(of: url))
    }
}

// MARK: - The music in the preview

/// The music's two audio tracks in a preview composition. The plays alternate between
/// them, so a crossfade has a track for each side.
struct MusicPreviewTracks {
    var tracks: [AVMutableCompositionTrack]
    /// Each track's plays, at composition times, with their linear volume.
    var plays: [CMPersistentTrackID: [(play: MusicPlay, offset: Double, volume: Float)]] = [:]

    init?(_ composition: AVMutableComposition) {
        let tracks = (0..<2).compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard tracks.count == 2 else { return nil }
        self.tracks = tracks
    }

    /// The volume of a gain in dB. The preview cannot play louder than the file (1); the
    /// export can.
    static func volume(_ gain: Double) -> Float { Float(min(1, pow(10, gain / 20))) }

    /// Puts each play of `mix` on the tracks, `offset` seconds into the composition.
    mutating func insert(_ mix: MusicMix, offset: Double = 0) async throws {
        // The asset is kept with its track: a track whose asset is gone cannot be inserted.
        var assets: [URL: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)] = [:]
        for url in mix.files {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw FFmpegError(message: "macOS cannot play the music \(url.lastPathComponent).")
            }
            assets[url] = (asset, track, try await track.load(.timeRange))
        }
        for (index, entry) in mix.plays.enumerated() {
            guard let source = assets[mix.files[entry.file]] else { continue }
            let track = tracks[index % 2]
            let range = CMTimeRange(start: CMTime(seconds: entry.play.from, preferredTimescale: 600_000),
                                    duration: CMTime(seconds: entry.play.length, preferredTimescale: 600_000))
            // A file's track can end a little before the length ffprobe gives (the encoder's
            // priming), and a range past its end is refused.
            let available = CMTimeRangeGetIntersection(range, otherRange: source.range)
            guard available.duration > .zero else { continue }
            let at = CMTime(seconds: offset + entry.play.at, preferredTimescale: 600_000) + available.start - range.start
            // A track takes media only up to its end: silence fills the time before the play.
            let end = track.segments.isEmpty ? .zero : track.timeRange.end
            if at > end { track.insertEmptyTimeRange(CMTimeRange(start: end, duration: at - end)) }
            try track.insertTimeRange(available, of: source.track, at: at)
            plays[track.trackID, default: []].append((entry.play, offset, Self.volume(entry.gain)))
        }
    }

    /// The volume ramps of one track: up over the fade in, the gain, and down over the fade out.
    func ramp(_ parameters: AVMutableAudioMixInputParameters) {
        guard let entries = plays[parameters.trackID] else { return }
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
        // Silent until the first play: a ramp may not start where a set volume does.
        if let first = entries.first, first.offset + first.play.at > 0.0005 { parameters.setVolume(0, at: .zero) }
        for (play, offset, volume) in entries {
            let start = offset + play.at, end = offset + play.end
            if play.fadeIn > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: time(start), duration: time(play.fadeIn)))
            } else {
                parameters.setVolume(volume, at: time(start))
            }
            if play.fadeOut > 0 {
                parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: time(end - play.fadeOut), duration: time(play.fadeOut)))
            } else {
                parameters.setVolume(0, at: time(end))
            }
        }
    }
}
