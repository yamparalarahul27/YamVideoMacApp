// Checks for background music (docs/plans/background-music.md, parts 1 and 2). Run with ./test.sh music
import AppKit
import AVFoundation
import Foundation

/// A sound file of chords that ffmpeg makes, so no download is needed.
private func makeMusic(_ name: String, seconds: Double, volume: Double = 0.2) async throws -> URL {
    let url = scratch.appendingPathComponent(name)
    let wave = "\(volume)*sin(2*PI*261.6*t)+\(volume)*sin(2*PI*329.6*t)|\(volume)*sin(2*PI*392*t)+\(volume)*sin(2*PI*523.3*t)"
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                              "-i", "aevalsrc=\(wave):s=44100:d=\(seconds)", "-c:a", "aac", url.path])
    guard result.status == 0 else { throw FFmpegError(message: "music fixture failed: \(result.stderrText)") }
    return url
}

private func piece(_ url: URL, start: Double, end: Double?, duration: Double = 6, loudness: Double = -14, from: Double = 0,
                   level: Double = -20, loop: Bool = true, fadeIn: Double = 2, fadeOut: Double = 3) -> MusicPiece {
    MusicPiece(url: url, duration: duration, loudness: loudness, start: start, end: end, from: from, level: level,
               fadeIn: fadeIn, fadeOut: fadeOut, loop: loop)
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.0005) -> Bool { abs(a - b) <= tolerance }

/// A voice of 10 s that speaks (a tone) from 0 to 2 s and from 6 to 10 s, and is silent between.
private func makeTalk(_ name: String) async throws -> URL {
    let url = scratch.appendingPathComponent(name)
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
                                              "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                                              "-f", "lavfi", "-i", "aevalsrc=0.3*sin(2*PI*440*t)*(lt(t\\,2)+gte(t\\,6)):s=48000:d=10",
                                              "-t", "10", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path])
    guard result.status == 0 else { throw FFmpegError(message: "talk fixture failed: \(result.stderrText)") }
    return url
}

/// The RMS level (dB) of a file's sound from `start` for `length` seconds.
private func soundLevel(_ url: URL, start: Double, length: Double) async throws -> Double {
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-ss", String(start), "-t", String(length), "-i", url.path,
                                              "-af", "astats=measure_perchannel=none:measure_overall=RMS_level", "-vn", "-f", "null", "-"])
    let line = result.stderrText.split(separator: "\n").last { $0.contains("RMS level dB") } ?? ""
    return Double(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? .nan
}

@MainActor func musicTests() async throws {
    let song = URL(fileURLWithPath: "/tmp/song.m4a")

    print("\nMusic: the plays of a piece")
    let once = piece(song, start: 1, end: 5, loop: false).plays(videoDuration: 60)
    check(once.count == 1 && close(once[0].at, 1) && close(once[0].length, 4) && close(once[0].fadeIn, 1.6) && close(once[0].fadeOut, 2.4),
          "a piece shorter than its file plays once, and fades that do not fit share its length", "\(once)")
    let short = piece(song, start: 0, end: 20, loop: false).plays(videoDuration: 60)
    check(short.count == 1 && close(short[0].length, 6), "without a loop, the music stops at the end of its file")
    let looped = piece(song, start: 0, end: nil, duration: 6).plays(videoDuration: 14)
    check(looped.count == 3 && close(looped[1].at, 4.5) && close(looped[1].from, 0) && close(looped[1].fadeIn, 1.5)
              && close(looped[0].fadeOut, 1.5) && close(looped[2].end, 14) && close(looped[2].fadeOut, 3),
          "a loop plays the file again with a crossfade (2 s, or a quarter of a short file), and the last play stops at the end of the video",
          "\(looped)")
    let fromMiddle = piece(song, start: 0, end: 10, duration: 6, from: 4).plays(videoDuration: 60)
    check(fromMiddle.count == 3 && close(fromMiddle[0].from, 4) && close(fromMiddle[0].length, 2) && close(fromMiddle[0].fadeOut, 1)
              && close(fromMiddle[0].fadeIn, 1) && close(fromMiddle[1].from, 0) && close(fromMiddle[1].at, 1) && close(fromMiddle[2].end, 10),
          "a piece can start part way into its file; the loop then starts the file from its start", "\(fromMiddle)")
    check(close(piece(song, start: 0, end: nil, loudness: -12).gain(voice: -23), -31),
          "the gain sits the file the level's LU under the voice: voice + level − music")

    print("\nMusic: the rules")
    let bed = MusicBed(voice: -23, pieces: [piece(song, start: 0, end: 10), piece(song, start: 10, end: nil)])
    check(bed.problem(duration: 30) == nil, "two pieces that touch are fine")
    func refused(_ pieces: [MusicPiece], _ words: String, duration: Double = 30, voice: Double = -23) -> Bool {
        MusicBed(voice: voice, pieces: pieces).problem(duration: duration)?.contains(words) == true
    }
    check(refused([piece(song, start: 0, end: 12), piece(song, start: 10, end: nil)], "overlaps")
              && refused([piece(song, start: 0, end: nil), piece(song, start: 10, end: 20)], "overlaps"),
          "pieces may not overlap, and a piece to the end must be the last")
    check(refused([piece(song, start: 0, end: 10, level: -40)], "level") && refused([piece(song, start: 0, end: 10, fadeIn: 11)], "fades")
              && refused([piece(song, start: 29.5, end: nil)], "start") && refused([piece(song, start: 0, end: 0.5)], "at least")
              && refused([piece(song, start: 0, end: 31)], "end by") && refused([piece(song, start: 0, end: 10, from: 5.5)], "before the end of its file")
              && refused([piece(song, start: 0, end: 10)], "voice", voice: .nan),
          "level, fades, start, length, end, the start in the file and the voice's loudness are checked")
    check(refused([piece(song, start: 0, end: 20, duration: 3)], "too short to loop")
              && MusicBed(voice: -23, pieces: [piece(song, start: 0, end: 2.5, duration: 3)]).problem(duration: 30) == nil
              && refused([piece(song, start: 0, end: nil, duration: 5)], "more than", duration: 600),
          "a loop needs a file of 5 s or more, and at most 100 plays")
    var badCredit = piece(song, start: 0, end: 10); badCredit.credit.line = "two\nlines"
    check(refused([badCredit], "one line"), "a credit is one line")
    check(bed.room(at: 5, duration: 30) == nil && MusicBed(voice: -23, pieces: [piece(song, start: 10, end: 20)]).room(at: 2, duration: 30) == 2...10,
          "a new piece goes from the playhead to the next piece, not over one")

    print("\nMusic: the music after an edit")
    let old = ClipTimeline(segments: [TimelineSegment(start: 0, end: 30)])
    let cut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4), TimelineSegment(start: 6, end: 30)])
    let moved = cut.remap(MusicBed(voice: -23, pieces: [piece(song, start: 10, end: 20), piece(song, start: 20, end: nil)]), from: old).bed
    check(moved.map { close($0.pieces[0].start, 8) && close($0.pieces[0].end ?? 0, 18) && close($0.pieces[1].start, 18) && $0.pieces[1].end == nil } == true,
          "a cut before the music moves it earlier, with its length, and a piece to the end stays to the end", "\(String(describing: moved))")
    let startCut = cut.remap(MusicBed(voice: -23, pieces: [piece(song, start: 5, end: 12)]), from: old).bed
    check(startCut.map { close($0.pieces[0].start, 4) && close($0.pieces[0].end ?? 0, 11) } == true,
          "when the first frame of a piece goes, it starts at the next frame that stays", "\(String(describing: startCut))")
    let shorter = ClipTimeline(segments: [TimelineSegment(start: 0, end: 15)])
    let clipped = shorter.remap(MusicBed(voice: -23, pieces: [piece(song, start: 10, end: 25), piece(song, start: 25, end: nil)]), from: old)
    check(clipped.bed?.pieces.count == 1 && close(clipped.bed?.pieces[0].end ?? 0, 15) && clipped.removed.count == 1,
          "a piece whose footage is gone goes, and a piece stops at the end of the video", "\(clipped)")
    let swapped = ClipTimeline(segments: [TimelineSegment(start: 20, end: 30), TimelineSegment(start: 0, end: 20)])
    let reordered = swapped.remap(MusicBed(voice: -23, pieces: [piece(song, start: 0, end: 20), piece(song, start: 20, end: nil)]), from: old).bed
    check(reordered.map { $0.pieces.count == 2 && close($0.pieces[0].start, 0) && close($0.pieces[0].end ?? 0, 10) && close($0.pieces[1].start, 10)
              && $0.problem(duration: 30) == nil } == true,
          "after sections move, pieces that would overlap are shortened to the next one", "\(String(describing: reordered))")

    print("\nMusic: edits and the project file")
    let voiceClip = try await makeClip("music-voice.mov", size: "640x360", seconds: 10, audio: "aac")
    let voiceInfo = try await FFmpeg.probe(url: voiceClip)
    let musicFile = try await makeMusic("music-chords.m4a", seconds: 6)
    let measured = try await FFmpeg.measureMusic(musicFile)
    let voiceLoudness = try await FFmpeg.integratedLoudness(of: voiceClip)
    check(close(measured.duration, 6, 0.05) && measured.loudness < -10 && measured.loudness > -30 && voiceLoudness < 0,
          "the app measures a music file's length and loudness, and the voice's loudness", "\(measured) \(voiceLoudness)")
    do { _ = try await FFmpeg.measureMusic(voiceClip); check(false, "a video file is not music") }
    catch { check(error.localizedDescription.contains("sound file"), "a video file is not music: the error names the sound files", error.localizedDescription) }
    var item = VideoItem(url: voiceClip)
    item.info = voiceInfo; item.crop = voiceInfo.fullFrame; item.status = .ready
    let project = VideoProject(clips: [ProjectClip(item)], settings: ExportSettings(), selection: item.id)
    let first = piece(musicFile, start: 0, end: 4, duration: measured.duration, loudness: measured.loudness)
    let added = try ProjectReducer.apply([.addMusic(clip: item.id, piece: first, voice: voiceLoudness)], to: project).project
    check(added.clips[0].music?.voice == voiceLoudness && added.clips[0].music?.pieces == [first],
          "addMusic keeps the piece and the voice's loudness")
    let second = piece(musicFile, start: 4, end: nil, duration: measured.duration, loudness: measured.loudness)
    let both = try ProjectReducer.apply([.addMusic(clip: item.id, piece: second, voice: -99)], to: added).project
    check(both.clips[0].music?.voice == voiceLoudness && both.clips[0].music?.pieces.count == 2,
          "a second piece keeps the voice measured for the first")
    var louder = first; louder.level = -12
    let updated = try ProjectReducer.apply([.updateMusic(clip: item.id, piece: louder)], to: both).project
    check(updated.clips[0].music?.pieces.first?.level == -12, "updateMusic changes a piece")
    let removed = try ProjectReducer.apply([.removeMusic(clip: item.id, piece: first.id), .removeMusic(clip: item.id, piece: second.id)], to: both).project
    check(removed.clips[0].music == nil, "with no pieces left, the recording has no music")
    var overlapping = second; overlapping.start = 3
    check(reducerRefusal([.updateMusic(clip: item.id, piece: overlapping)], both) == .invalidCommand
              && reducerRefusal([.addMusic(clip: item.id, piece: first, voice: -20)], added) == .invalidCommand
              && reducerRefusal([.removeMusic(clip: item.id, piece: UUID())], added) == .notFound,
          "an overlap, the same id two times and an unknown piece are refused")
    var silent = item; silent.info?.audioCodec = nil
    check(reducerRefusal([.addMusic(clip: item.id, piece: first, voice: -20)],
                         VideoProject(clips: [ProjectClip(silent)], settings: ExportSettings(), selection: item.id)) == .invalidCommand,
          "a recording with no sound cannot have music")
    let afterCut = try ProjectReducer.apply([.splitSection(clip: item.id, at: 2), .deleteSection(clip: item.id, section: both.clips[0].timeline.segments[0].id)], to: both).project
    check(afterCut.clips[0].music?.pieces.count == 2 && close(afterCut.clips[0].music?.pieces[0].start ?? -1, 0)
              && close(afterCut.clips[0].music?.pieces[0].end ?? 0, 2) && afterCut.clips[0].music?.pieces[1].end == nil,
          "music follows the edit through the reducer", "\(String(describing: afterCut.clips[0].music))")
    let data = try JSONEncoder().encode(both)
    let reopened = try VideoProject.decodeMigrating(from: data)
    check(reopened.version == VideoProject.currentVersion && reopened.clips[0].music == both.clips[0].music, "a project saves and opens with the same music")
    var older = both; older.version = 19
    do { try older.validate(); check(false, "a version 19 file with music is refused") }
    catch { check(error.localizedDescription.contains("music"), "a version 19 file with music is refused", error.localizedDescription) }
    var olderSwitch = project; olderSwitch.version = 19; olderSwitch.clips[0].switchedOff = [.music]
    check((try? olderSwitch.validate()) == nil, "a version 19 file with music switched off is refused too")

    print("\nMusic: the switch")
    var withMusic = both.clips[0].item()
    check(withMusic.has(.music) && withMusic.exportMusic(ExportSettings())?.plays.isEmpty == false, "a recording with music exports it")
    withMusic.switchedOff = [.music]
    check(withMusic.effective.music == nil && withMusic.exportMusic(ExportSettings()) == nil, "switched off, the music is out of the player and the export")
    withMusic.switchedOff = []
    var gif = ExportSettings(); gif.format = .gif
    var mute = ExportSettings(); mute.audio = .none
    check(withMusic.exportMusic(gif) == nil && withMusic.exportMusic(mute) == nil && withMusic.asRecorded.music == nil
              && withMusic.previewing(hiding: [.music]).music == nil,
          "a GIF, an export without sound, Before and the muted Music row have no music")

    print("\nMusic: the ffmpeg graph")
    let mix = withMusic.exportMusic(ExportSettings())!
    let graph = FFmpeg.musicGraph(mix, firstInput: 3, voice: "timelinea", output: "mixa").joined(separator: ";")
    check(mix.files.count == 1 && graph.contains("[3:a:0]") && graph.contains("asplit=\(mix.plays.count)")
              && graph.contains("amix=inputs=\(mix.plays.count + 1):normalize=0:duration=first")
              && graph.contains("adelay=delays=192000S") && graph.contains("volume=\(String(format: "%.2f", first.gain(voice: voiceLoudness)))dB"),
          "each file is one input, split into its plays, each set to its gain and place, and mixed with the voice", graph)
    var normalised = ExportSettings(); normalised.audio = .normalised
    let uncut = FFmpeg.exportCommands(input: voiceClip, output: scratch.appendingPathComponent("music-out.mp4"), info: voiceInfo,
                                      crop: voiceInfo.fullFrame, settings: normalised, music: mix)
    let encode = uncut.last!.joined(separator: " ")
    check(uncut.count == 2 && uncut[0].contains(musicFile.path) && uncut[0].joined(separator: " ").contains("[mixa]loudnorm")
              && encode.contains("[timelinea]") && encode.contains("[mixa]loudnorm") && encode.contains("-map [normala]")
              && encode.contains("-i \(musicFile.path)"),
          "an uncut recording with music goes through the cut graph, and the loudness pass measures the mix", encode)
    let noMusic = FFmpeg.exportCommands(input: voiceClip, output: scratch.appendingPathComponent("music-out.mp4"), info: voiceInfo,
                                        crop: voiceInfo.fullFrame, settings: normalised)
    check(noMusic[0] == FFmpeg.loudnessArguments(input: voiceClip) && !noMusic.last!.joined(separator: " ").contains("timelinea"),
          "without music the export is as before")

    print("\nMusic: a real export")
    // A loud bed (−6 LU) makes the mix about 1 LU louder than the voice alone.
    var loud = both.clips[0].item()
    let loudPieces = loud.music!.pieces.map { piece -> MusicPiece in var piece = piece; piece.level = -6; piece.fadeIn = 0; piece.fadeOut = 0; return piece }
    loud.music?.pieces = loudPieces
    let mixedOut = scratch.appendingPathComponent("music-mixed.mp4"), plainOut = scratch.appendingPathComponent("music-plain.mp4")
    try await FFmpeg.export(input: voiceClip, output: mixedOut, info: voiceInfo, crop: voiceInfo.fullFrame, settings: ExportSettings(),
                            music: loud.exportMusic(ExportSettings())) { _ in }
    try await FFmpeg.export(input: voiceClip, output: plainOut, info: voiceInfo, crop: voiceInfo.fullFrame, settings: ExportSettings()) { _ in }
    let mixedLoudness = try await integratedLoudness(mixedOut) ?? 0, plainLoudness = try await integratedLoudness(plainOut) ?? 0
    check(mixedLoudness - plainLoudness > 0.5 && mixedLoudness - plainLoudness < 2.5,
          "the export mixes the music under the voice at its level", "\(mixedLoudness) vs \(plainLoudness)")
    let mixedSound = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration,channels,sample_rate",
                                                                "-of", "csv=p=0", mixedOut.path]).stdoutText
    let mixedVideo = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=duration",
                                                                "-of", "csv=p=0", mixedOut.path]).stdoutText
    let soundParts = mixedSound.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
    check(soundParts.count == 3 && soundParts[0] == "48000" && soundParts[1] == "2"
              && abs((Double(soundParts[2]) ?? 0) - (Double(mixedVideo.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)) < 0.1,
          "the mix is 48 kHz stereo, as long as the picture", "\(mixedSound) \(mixedVideo)")
    let normalOut = scratch.appendingPathComponent("music-normal.mp4")
    try await FFmpeg.export(input: voiceClip, output: normalOut, info: voiceInfo, crop: voiceInfo.fullFrame, settings: normalised,
                            music: withMusic.exportMusic(normalised)) { _ in }
    let normalLoudness = try await integratedLoudness(normalOut) ?? 0
    check(abs(normalLoudness + 14) < 0.6, "with Loudness on, the mix exports at -14 LUFS", "\(normalLoudness)")

    print("\nMusic: the movie")
    let movie = try MoviePlan(items: [withMusic, item], movieSettings: MovieSettings(), settings: ExportSettings())
    let movieArguments = FFmpeg.movieArguments(plan: movie, settings: ExportSettings(), output: scratch.appendingPathComponent("music-movie.mp4"))
    let movieGraph = movieArguments[movieArguments.firstIndex(of: "-filter_complex")! + 1]
    check(movieArguments.filter { $0 == "-i" }.count == 3 && movieGraph.contains("[mv0voice]") && movieGraph.contains("[2:a:0]")
              && movieGraph.contains("[ma0]") && !movieGraph.contains("m1_"),
          "the movie mixes each recording's music under its own voice", movieGraph)

    let movieOut = scratch.appendingPathComponent("music-movie.mp4")
    try await FFmpeg.exportMovie(plan: movie, settings: ExportSettings(), output: movieOut) { _ in }
    let movieSound = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration",
                                                                "-of", "csv=p=0", movieOut.path]).stdoutText
    check(abs((Double(movieSound.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) - 20) < 0.2, "the movie with music exports, as long as its recordings", movieSound)

    print("\nMusic: the preview")
    let previewItem = try await PlaybackController.makeItem(withMusic, settings: ExportSettings())
    let previewTracks = (previewItem.asset as? AVComposition)?.tracks(withMediaType: .audio) ?? []
    let musicTrack = previewTracks.last.flatMap { track in (previewItem.audioMix?.inputParameters ?? []).first { $0.trackID == track.trackID } }
    var start: Float = -1, end: Float = -1, range = CMTimeRange()
    _ = musicTrack?.getVolumeRamp(for: CMTime(seconds: 4.5, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range)
    let expected = MusicPreviewTracks.volume(both.clips[0].music!.pieces[1].gain(voice: voiceLoudness))
    check(previewTracks.count == 3 && previewItem.audioMix?.inputParameters.count == 3 && start == 0 && abs(end - expected) < 0.0001,
          "the preview plays the voice and two music tracks, and fades the music up to its gain", "\(previewTracks.count) \(start) \(end) \(expected)")
    let shortItem = try await PlaybackController.makeItem(withMusic, settings: ExportSettings(), short: Short(start: 0, end: 5))
    check((shortItem.asset as? AVComposition)?.tracks(withMediaType: .audio).count == 1, "a Short plays without the music")

    print("\nMusic: credits for YouTube")
    var credited = both.clips[0].music!
    credited.pieces[0].credit = MusicCredit(licence: .ccBy, title: "Chords", artist: "Ana", source: "https://example.com/chords", line: "Music: Chords by Ana (CC BY 4.0)")
    credited.pieces[1].credit = MusicCredit(licence: .audioLibrary, line: "Music: Chords by Ana (CC BY 4.0)")
    var details = PublishInfo(); details.title = "A video"; details.description = "About design."
    let withCredits = details.crediting(credited)
    check(withCredits.description == "About design.\n\nMusic: Chords by Ana (CC BY 4.0)" && withCredits.crediting(credited) == withCredits,
          "the credit line goes at the end of the description once, and not again when it is there")
    check(details.issues(duration: 10, music: credited).filter { $0.field == "music" }.isEmpty, "licensed music with its credit has no issues")
    var blocked = credited; blocked.pieces[0].credit.licence = .ccNC
    var unset = credited; unset.pieces[1].credit.licence = nil
    var noLine = credited; noLine.pieces[0].credit.line = ""; noLine.pieces[1].credit.line = ""
    check(details.issues(duration: 10, music: blocked).contains { $0.field == "music" && $0.severity == .blocking }
              && details.issues(duration: 10, music: unset).contains { $0.field == "music" && $0.severity == .warning && $0.message.contains("licence") }
              && details.issues(duration: 10, music: noLine).contains { $0.message.contains("CC BY needs a credit") },
          "a non-commercial licence stops the export; no licence and no CC BY credit are warnings")
    var generated = credited; generated.pieces[1].credit.licence = .generated
    let text = withCredits.uploadText(files: [], music: generated)
    check(text.contains("MUSIC\n0:00 Chords by Ana · CC BY · https://example.com/chords") && text.contains("made with AI"),
          "the text for YouTube Studio lists the music, and says when it is made with AI", text)
    let files = YouTubeExport.Files(video: scratch.appendingPathComponent("v.mp4"), captions: nil, thumbnail: nil,
                                    text: scratch.appendingPathComponent("v.txt"), json: scratch.appendingPathComponent("v.json"))
    let json = try JSONSerialization.jsonObject(with: try YouTubeExport.json(withCredits, files: files, music: credited)) as? [String: Any]
    check(((json?["music"] as? [[String: Any]])?.first?["licence"] as? String) == "ccBy", "the JSON for YouTube has the music")

    print("\nMusic: the duck")
    let joined = MusicDuck.runs([0...1, 2.2...3, 4.7...6, 8...9])
    check(joined == [0...3, 4.7...6, 8...9], "words less than 1.6 s apart (1.5 s, or too close for the two ramps) are one run", "\(joined)")
    let duck = MusicDuck(lift: 8)
    let envelope = duck.envelope(runs: [2...5, 8...10], duration: 15)
    let duckPoints = [(0.0, 8.0), (1.6, 8), (1.9, 0), (5.4, 0), (6.2, 8), (7.6, 8), (7.9, 0), (10.4, 0), (11.2, 8)]
    check(envelope.points.count == duckPoints.count && zip(envelope.points, duckPoints).allSatisfy { close($0.time, $1.0) && close($0.lift, $1.1) },
          "up before the first word, down over 0.3 s to 0.1 s before a run, up over 0.8 s from 0.4 s after it, up at the end", "\(envelope.points)")
    check(close(envelope.factor(at: 1.75), (DuckEnvelope.factor(8) + 1) / 2) && close(envelope.lift(at: 3), 0) && close(envelope.lift(at: 13), 8),
          "between two points the volume moves in a straight line")
    let early = duck.envelope(runs: [0.2...4], duration: 4.2)
    check(early.points == [DuckPoint(time: 0, lift: 0)], "speech at the start and to the end: the music stays at its level", "\(early.points)")
    check(duck.envelope(runs: [], duration: 10).points == [DuckPoint(time: 0, lift: 8)] && MusicDuck(lift: 0).envelope(runs: [2...3], duration: 10).isFlat,
          "no speech lifts all of it; a lift of 0 changes nothing")
    let expression = envelope.expression
    check(expression.contains("gte(t,1.600000)*lt(t,1.900000)*(") && expression.contains("*gte(t,11.200000)") && !expression.contains("if("),
          "the export's volume expression has one flat term for each part, with no nesting", expression)
    let words = Transcript(model: "test", language: "en", words: [
        TranscriptWord(text: "One", start: 1, end: 1.5), TranscriptWord(text: "two", start: 4.5, end: 5.5), TranscriptWord(text: "three", start: 12, end: 12.4)])
    let spoken = MusicSpeech.spans(words, timeline: ClipTimeline(segments: [TimelineSegment(start: 0, end: 5), TimelineSegment(start: 10, end: 20)]))
    check(spoken.count == 3 && close(spoken[0].lowerBound, 1) && close(spoken[0].upperBound, 1.5) && close(spoken[1].lowerBound, 4.5)
              && close(spoken[1].upperBound, 5) && close(spoken[2].lowerBound, 7) && close(spoken[2].upperBound, 7.4),
          "speech is the words still in the edit, in edited time; a word cut part way stops at the cut", "\(spoken)")
    let levels = AudioOverview(levels: (0..<120).map { index in
        let time = Double(index) * AudioOverview.interval
        return AudioLevel(time: time, decibels: time < 2 || (time >= 5 && time < 5.1) || time >= 4.0 && time < 4.05 ? -20 : -60)
    })
    let heard = MusicSpeech.spans(levels, timeline: ClipTimeline(segments: [TimelineSegment(start: 0, end: 6)]))
    check(heard.count == 1 && close(heard[0].lowerBound, 0) && close(heard[0].upperBound, 2),
          "with no transcript, speech is the sound above -40 dB; a click shorter than 0.15 s is not speech", "\(heard)")
    check(MusicBed(voice: -23, pieces: [piece(song, start: 0, end: 10)], duck: MusicDuck(lift: 13)).problem(duration: 30)?.contains("lift") == true,
          "a lift over 12 dB is refused")

    print("\nMusic: the duck in the project")
    check(added.clips[0].music?.duck == MusicDuck(), "the first piece of music turns the duck on, with a lift of 8 dB")
    let ducked = try ProjectReducer.apply([.setMusicDuck(clip: item.id, duck: MusicDuck(lift: 5))], to: both).project
    let undocked = try ProjectReducer.apply([.setMusicDuck(clip: item.id, duck: nil)], to: added).project
    let stillOff = try ProjectReducer.apply([.addMusic(clip: item.id, piece: second, voice: -99)], to: undocked).project
    check(ducked.clips[0].music?.duck?.lift == 5 && undocked.clips[0].music?.duck == nil && stillOff.clips[0].music?.duck == nil,
          "setMusicDuck changes the lift or turns the duck off, and a new piece keeps it off")
    check(reducerRefusal([.setMusicDuck(clip: item.id, duck: MusicDuck(lift: 20))], both) == .invalidCommand
              && reducerRefusal([.setMusicDuck(clip: item.id, duck: MusicDuck())], project) == .invalidCommand,
          "a lift out of range, and a duck with no music, are refused")
    let reopenedDuck = try VideoProject.decodeMigrating(from: try JSONEncoder().encode(ducked))
    check(reopenedDuck.clips[0].music?.duck?.lift == 5, "a project saves and opens with its duck")
    var olderDuck = ducked; olderDuck.version = 21
    do { try olderDuck.validate(); check(false, "a version 21 file with a duck is refused") }
    catch { check(error.localizedDescription.contains("duck"), "a version 21 file with a duck is refused", error.localizedDescription) }

    print("\nMusic: the duck in the export and the preview")
    let talk = try await makeTalk("music-talk.mov")
    let talkInfo = try await FFmpeg.probe(url: talk)
    let talkVoice = try await FFmpeg.integratedLoudness(of: talk)
    var talker = VideoItem(url: talk)
    talker.info = talkInfo; talker.crop = talkInfo.fullFrame; talker.status = .ready
    talker.transcript = Transcript(model: "test", language: "en", words: [
        TranscriptWord(text: "Hello", start: 0.2, end: 1.8), TranscriptWord(text: "again", start: 6.2, end: 9.8)])
    let bedPiece = piece(musicFile, start: 0, end: nil, duration: measured.duration, loudness: measured.loudness, level: -20, fadeIn: 0, fadeOut: 0)
    talker.music = MusicBed(voice: talkVoice, pieces: [bedPiece], duck: MusicDuck(lift: 8))
    let talkMix = talker.exportMusic(ExportSettings())
    check(talkMix?.duck.map { $0.points.count == 5 && zip($0.points.map(\.time), [0, 2.2, 3.0, 5.8, 6.1]).allSatisfy { close($0, $1) } } == true,
          "the export's mix carries the duck from the words", "\(String(describing: talkMix?.duck))")
    let duckGraph = FFmpeg.musicGraph(talkMix!, firstInput: 1, voice: "timelinea", output: "mixa").joined(separator: ";")
    check(duckGraph.contains("amix=inputs=\(talkMix!.plays.count):normalize=0:duration=longest") && duckGraph.contains("eval=frame[mubed]")
              && duckGraph.contains("[muvoice][mubed]amix=inputs=2:normalize=0:duration=first"),
          "with the duck, the plays become one bed, the expression moves it, and amix puts it under the voice", duckGraph)
    let points = MusicPreviewTracks.volumePoints(talkMix!.plays[0].play, gain: talkMix!.plays[0].gain, duck: talkMix!.duck)
    let under = points.first { close($0.time, 1) || $0.time < 2.2 }!.volume, over = points.first { close($0.time, 3.0) }!.volume
    check(abs(20 * log10(Double(over / under)) - 8) < 0.01, "the preview's volume is 8 dB higher in the pause than under speech", "\(points)")
    var flatTalker = talker; flatTalker.music?.duck = nil
    let duckedOut = scratch.appendingPathComponent("music-ducked.mp4"), flatOut = scratch.appendingPathComponent("music-flat.mp4")
    let talkSegments = [TimelineSegment(start: 0, end: talkInfo.duration)]
    try await FFmpeg.export(input: talk, output: duckedOut, info: talkInfo, crop: talkInfo.fullFrame, segments: talkSegments, settings: ExportSettings(),
                            music: talker.exportMusic(ExportSettings())) { _ in }
    try await FFmpeg.export(input: talk, output: flatOut, info: talkInfo, crop: talkInfo.fullFrame, segments: talkSegments, settings: ExportSettings(),
                            music: flatTalker.exportMusic(ExportSettings())) { _ in }
    let pauseLift = try await soundLevel(duckedOut, start: 3.5, length: 2) - soundLevel(flatOut, start: 3.5, length: 2)
    let speechLift = try await soundLevel(duckedOut, start: 0.5, length: 1) - soundLevel(flatOut, start: 0.5, length: 1)
    check(abs(pauseLift - 8) < 0.6 && abs(speechLift) < 0.3, "the export lifts the music 8 dB in the pause and leaves it under speech",
          "pause \(pauseLift) speech \(speechLift)")
    let analysis = try await MusicAnalysis.analyze(talker, info: talkInfo)
    check(analysis.speech == .transcript && analysis.runs.count == 2 && analysis.points.count == 5 && analysis.mix.map { $0.integrated < 0 } == true,
          "analyze kind music gives the runs, the points and the loudness of the mix", "\(analysis.runs) \(String(describing: analysis.mix))")

    print("\nMusic: agents")
    let agent = AppModel(recoveryURL: nil)
    agent.restore(project)
    var add = address(agent)
    add["method"] = "apply"; add["requestID"] = "music-add"; add["client"] = "Claude"
    add["commands"] = [["type": "addMusic", "clipID": item.id.uuidString, "path": musicFile.path, "start": 1,
                        "music": ["level": -22, "credit": ["licence": "audioLibrary", "title": "Chords"]]]]
    let addedByAgent = await agentCall(agent, add)
    let agentPiece = agent.items[0].music?.pieces.first
    check(addedByAgent["ok"] as? Bool == true && agentPiece?.level == -22 && agentPiece?.end == nil && agentPiece?.credit.licence == .audioLibrary
              && agentPiece.map { close($0.duration, 6, 0.05) } == true && agent.items[0].music.map { abs($0.voice - voiceLoudness) < 0.2 } == true,
          "an agent adds music: the app measures the file and the voice", "\(addedByAgent)")
    let state = (agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["music"] as? [String: Any]
    let statePiece = (state?["pieces"] as? [[String: Any]])?.first
    check(statePiece?["toEnd"] as? Bool == true && (statePiece?["plays"] as? [[String: Any]])?.count == 2 && statePiece?["gain"] is Double,
          "state shows each piece with its plays and gain", "\(String(describing: state))")
    var update = address(agent)
    update["method"] = "apply"; update["requestID"] = "music-update"; update["client"] = "Claude"
    update["commands"] = [["type": "updateMusic", "clipID": item.id.uuidString, "musicID": agentPiece!.id.uuidString,
                           "music": ["end": 8, "fadeOut": 1, "credit": ["line": "Music: Chords"]]]]
    let updatedByAgent = await agentCall(agent, update)
    let changed = agent.items[0].music?.pieces.first
    check(updatedByAgent["ok"] as? Bool == true && changed?.end == 8 && changed?.fadeOut == 1 && changed?.credit.line == "Music: Chords"
              && changed?.credit.title == "Chords",
          "updateMusic changes only the keys given", "\(updatedByAgent)")
    var wrong = address(agent)
    wrong["method"] = "apply"; wrong["requestID"] = "music-wrong"; wrong["client"] = "Claude"
    wrong["commands"] = [["type": "updateMusic", "clipID": item.id.uuidString, "musicID": agentPiece!.id.uuidString, "music": ["volume": 3]]]
    let refusedKey = await agentCall(agent, wrong)
    wrong["requestID"] = "music-licence"
    wrong["commands"] = [["type": "updateMusic", "clipID": item.id.uuidString, "musicID": agentPiece!.id.uuidString, "music": ["credit": ["licence": "free"]]]]
    let refusedLicence = await agentCall(agent, wrong)
    check(agentError(refusedKey) == "invalid_command" && agentError(refusedLicence) == "invalid_command",
          "an unknown key or licence is refused, with the ones allowed")
    var duckAgent = address(agent)
    duckAgent["method"] = "apply"; duckAgent["requestID"] = "music-duck"; duckAgent["client"] = "Claude"
    duckAgent["commands"] = [["type": "setMusicDuck", "clipID": item.id.uuidString, "music": ["lift": 6]]]
    let liftedByAgent = await agentCall(agent, duckAgent)
    let duckState = (agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["music"] as? [String: Any]
    duckAgent = address(agent)
    duckAgent["method"] = "apply"; duckAgent["requestID"] = "music-duck-off"; duckAgent["client"] = "Claude"
    duckAgent["commands"] = [["type": "setMusicDuck", "clipID": item.id.uuidString, "music": ["duck": false]]]
    let offByAgent = await agentCall(agent, duckAgent)
    let offDuck = agent.items[0].music?.duck
    duckAgent = address(agent)
    duckAgent["method"] = "apply"; duckAgent["requestID"] = "music-duck-bad"; duckAgent["client"] = "Claude"
    duckAgent["commands"] = [["type": "setMusicDuck", "clipID": item.id.uuidString, "music": ["depth": 3]]]
    let refusedDuck = await agentCall(agent, duckAgent)
    check(liftedByAgent["ok"] as? Bool == true && (duckState?["duck"] as? [String: Any])?["lift"] as? Double == 6
              && offByAgent["ok"] as? Bool == true && offDuck == nil && agentError(refusedDuck) == "invalid_command",
          "setMusicDuck sets the lift and turns the duck off; state shows it; an unknown key is refused", "\(liftedByAgent) \(String(describing: duckState))")
    var remove = address(agent)
    remove["method"] = "apply"; remove["requestID"] = "music-remove"; remove["client"] = "Claude"
    remove["commands"] = [["type": "removeMusic", "clipID": item.id.uuidString, "musicID": agentPiece!.id.uuidString]]
    let removedByAgent = await agentCall(agent, remove)
    check(removedByAgent["ok"] as? Bool == true && agent.items[0].music == nil, "removeMusic removes the piece")
    let catalog = AgentCatalog.current
    check(["addMusic", "updateMusic", "removeMusic", "setMusicDuck"].allSatisfy { type in catalog.commands.contains { $0.type == type && $0.group == "music" } },
          "the catalog has the music commands")
    let manual = (try? String(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("Resources/AgentsManual.md"), encoding: .utf8)) ?? ""
    check(manual.contains("### 4.15 Background music") && manual.contains("addMusic") && manual.contains("setMusicDuck"),
          "the Agents Manual has the music recipe, with the duck")
}
