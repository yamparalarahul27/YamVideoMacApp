// Checks for background music (docs/plans/background-music.md, part 1). Run with ./test.sh music
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
    check(reopened.version == 20 && reopened.clips[0].music == both.clips[0].music, "a project saves and opens with the same music (version 20)")
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
    var remove = address(agent)
    remove["method"] = "apply"; remove["requestID"] = "music-remove"; remove["client"] = "Claude"
    remove["commands"] = [["type": "removeMusic", "clipID": item.id.uuidString, "musicID": agentPiece!.id.uuidString]]
    let removedByAgent = await agentCall(agent, remove)
    check(removedByAgent["ok"] as? Bool == true && agent.items[0].music == nil, "removeMusic removes the piece")
    let catalog = AgentCatalog.current
    check(["addMusic", "updateMusic", "removeMusic"].allSatisfy { type in catalog.commands.contains { $0.type == type && $0.group == "music" } },
          "the catalog has the music commands")
    let manual = (try? String(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("Resources/AgentsManual.md"), encoding: .utf8)) ?? ""
    check(manual.contains("### 4.15 Background music") && manual.contains("addMusic"), "the Agents Manual has the music recipe")
}
