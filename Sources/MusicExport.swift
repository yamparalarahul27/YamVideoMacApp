import AVFoundation
import Foundation

// The music in an export (docs/plans/background-music.md, parts 1 and 2): each file is one
// more ffmpeg input, each play is cut, faded, set to its gain and put in its place, and
// `amix` adds the plays to the voice. With the duck, the plays first become one bed, and a
// `volume` expression moves the bed between the gain points. Loudness then normalises the mix.

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
        if let duck = mix.duck, !outputs.isEmpty {
            // Short frames (256 samples, 5 ms) so the gain moves in small steps on a ramp.
            let gain = "asetnsamples=n=256:p=0,volume='\(duck.expression)':eval=frame[\(prefix)bed]"
            parts.append(outputs.count == 1 ? outputs[0] + gain
                         : outputs.joined() + "amix=inputs=\(outputs.count):normalize=0:duration=longest:dropout_transition=0," + gain)
            parts.append("[\(prefix)voice][\(prefix)bed]amix=inputs=2:normalize=0:duration=first:dropout_transition=0[\(output)]")
            return parts
        }
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
    /// Each track's plays, `offset` seconds into the composition, with their gain (dB) and
    /// the duck of their recording.
    var plays: [CMPersistentTrackID: [(play: MusicPlay, offset: Double, gain: Double, duck: DuckEnvelope?)]] = [:]

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
            plays[track.trackID, default: []].append((entry.play, offset, entry.gain, mix.duck))
        }
    }

    /// The volume of a play at `time` (edited seconds): its gain, its fades (straight
    /// lines, as ffmpeg's `afade`) and the duck.
    static func volume(_ play: MusicPlay, gain: Double, duck: DuckEnvelope?, at time: Double) -> Float {
        var fade = 1.0
        if play.fadeIn > 0, time < play.at + play.fadeIn { fade = min(fade, max(0, (time - play.at) / play.fadeIn)) }
        if play.fadeOut > 0, time > play.end - play.fadeOut { fade = min(fade, max(0, (play.end - time) / play.fadeOut)) }
        return Float(min(1, pow(10, gain / 20) * fade * (duck?.factor(at: time) ?? 1)))
    }

    /// The points of a play's volume, at edited seconds: where a fade or the duck starts or
    /// stops a change. Where a fade and a duck ramp change together, the volume is not a
    /// straight line, so the points are 0.05 s apart there.
    static func volumePoints(_ play: MusicPlay, gain: Double, duck: DuckEnvelope?) -> [(time: Double, volume: Float)] {
        let range = play.at...play.end
        let fadeInEnd = play.at + play.fadeIn, fadeOutStart = play.end - play.fadeOut
        var times = [play.at, fadeInEnd, fadeOutStart, play.end] + (duck?.times(in: range) ?? [])
        times = times.map { min(max($0, range.lowerBound), range.upperBound) }.sorted()
        var points: [Double] = []
        for time in times where points.last.map({ time - $0 > 0.000001 }) ?? true {
            if let previous = points.last, let duck, abs(duck.factor(at: previous) - duck.factor(at: time)) > 0.000001,
               previous < fadeInEnd - 0.000001 || time > fadeOutStart + 0.000001 {
                let steps = Int(((time - previous) / 0.05).rounded(.up))
                for step in 1..<max(1, steps) { points.append(previous + (time - previous) * Double(step) / Double(steps)) }
            }
            points.append(time)
        }
        return points.map { ($0, volume(play, gain: gain, duck: duck, at: $0)) }
    }

    /// The volume ramps of one track: one ramp between each two points of each play.
    func ramp(_ parameters: AVMutableAudioMixInputParameters) {
        guard let entries = plays[parameters.trackID] else { return }
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
        // Silent until the first play: a ramp may not start where a set volume does.
        if let first = entries.first, first.offset + first.play.at > 0.0005 { parameters.setVolume(0, at: .zero) }
        // After a play, the track is empty until its next play, so it is silent there.
        for entry in entries {
            let points = Self.volumePoints(entry.play, gain: entry.gain, duck: entry.duck)
            for (a, b) in zip(points, points.dropFirst()) {
                parameters.setVolumeRamp(fromStartVolume: a.volume, toEndVolume: b.volume,
                                         timeRange: CMTimeRange(start: time(entry.offset + a.time), end: time(entry.offset + b.time)))
            }
        }
    }
}

// MARK: - The duck for agents

/// The music's duck and loudness, so an agent can check the mix without ears (analyze
/// kind music). Times are edited seconds.
struct MusicAnalysis: Encodable {
    struct Run: Encodable { var start: Double; var end: Double }
    struct Piece: Encodable { var id: UUID; var name: String; var loudness: Double; var level: Double; var gain: Double }
    /// The voice with the music under it, as the export mixes it, before Loudness.
    struct Mix: Encodable { var integrated: Double; var truePeak: Double }
    var kind = "music"
    var speech: MusicSpeech.Source
    /// Nil when the duck is off.
    var lift: Double?
    var runs: [Run]
    var points: [DuckPoint]
    /// LUFS, as measured when the first piece went on.
    var voice: Double
    var pieces: [Piece]
    var mix: Mix?

    static func analyze(_ item: VideoItem, info: MediaInfo) async throws -> MusicAnalysis {
        await MusicSpeech.prepare(item)
        guard let music = item.music else { throw FFmpegError(message: "This recording has no music.") }
        let duration = item.editedDuration
        let speech = MusicSpeech.spans(of: item)
        let envelope = item.musicDuck
        let mix = music.mix(duration: duration, duck: envelope)
        var measured: Mix?
        if !mix.isEmpty, info.hasAudio, let ffmpeg = FFmpeg.ffmpegPath {
            let args = try FFmpeg.spilledGraph(FFmpeg.loudnessArguments(input: item.url, segments: item.timeline.segments,
                                                                        fpsExpression: info.fpsExpression, music: mix))
            let result = try await Shell.run(ffmpeg, args)
            try Task.checkCancellation()
            if result.status == 0, let loudness = FFmpeg.parseLoudness(result.stderrText),
               let integrated = Double(loudness.inputI), let peak = Double(loudness.inputTP) {
                measured = Mix(integrated: integrated, truePeak: peak)
            }
        }
        func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        return MusicAnalysis(
            speech: speech.source, lift: music.duck?.lift,
            runs: MusicDuck.runs(speech.spans).filter { $0.lowerBound < duration }.map { Run(start: round($0.lowerBound), end: round(min($0.upperBound, duration))) },
            points: (envelope?.points ?? []).map { DuckPoint(time: round($0.time), lift: round($0.lift)) },
            voice: music.voice,
            pieces: music.pieces.map { Piece(id: $0.id, name: $0.name, loudness: $0.loudness, level: $0.level, gain: round($0.gain(voice: music.voice))) },
            mix: measured)
    }
}
