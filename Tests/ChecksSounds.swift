// Checks for sound effects on the graphics (docs/plans/sound-effects.md, part 1). Run with ./test.sh sounds
import AppKit
import AVFoundation
import Foundation

/// A short sound that ffmpeg makes from a lavfi source, so no download is needed.
private func makeSound(_ name: String, source: String, seconds: Double, filter: String? = nil) async throws -> URL {
    let url = scratch.appendingPathComponent(name)
    var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", source, "-t", String(seconds)]
    if let filter { args += ["-af", filter] }
    args += ["-c:a", "pcm_s16le", url.path]
    let result = try await Shell.run(ffmpeg, args)
    guard result.status == 0 else { throw FFmpegError(message: "sound fixture failed: \(result.stderrText)") }
    return url
}

/// A recording of `seconds` whose sound is silence, so a check hears only the cues.
private func makeQuietClip(_ name: String, seconds: Double) async throws -> URL {
    let url = scratch.appendingPathComponent(name)
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                                              "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", String(seconds),
                                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path])
    guard result.status == 0 else { throw FFmpegError(message: "quiet clip failed: \(result.stderrText)") }
    return url
}

/// The RMS level (dB) of a file's sound from `start` for `length` seconds.
private func rmsLevel(_ url: URL, start: Double, length: Double) async throws -> Double {
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-nostdin", "-ss", String(start), "-t", String(length), "-i", url.path,
                                              "-af", "astats=measure_perchannel=none:measure_overall=RMS_level", "-vn", "-f", "null", "-"])
    let line = result.stderrText.split(separator: "\n").last { $0.contains("RMS level dB") } ?? ""
    let text = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
    return text == "-inf" ? -200 : Double(text) ?? .nan
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.0005) -> Bool { abs(a - b) <= tolerance }

@MainActor func soundsTests() async throws {
    print("\nSounds: the engine's cues")
    let link = SoundCues.engineCues(kind: .link, props: ["url": .string("tradl.ai"), "image": .string("/tmp/x.jpg")], length: 7)
    check(link.count == 10 && near(link[0].at, 1.05) && link[0].cue == "click" && near(link[1].at, 1.3) && near(link[8].at, 1.93)
              && link[1...8].allSatisfy { $0.cue == "key" } && near(link[9].at, 2.22) && link[9].cue == "open",
          "a link card: the click, a key for each letter (0.09 s apart from 1.3 s), and the window when it has a page", "\(link)")
    let noPage = SoundCues.engineCues(kind: .link, props: ["url": .string("tradl.ai")], length: 7)
    let short = SoundCues.engineCues(kind: .link, props: ["url": .string("tradl.ai")], length: 1.2)
    check(noPage.count == 9 && !noPage.contains { $0.cue == "open" } && short.count == 1,
          "no page, no window; a cue after the graphic's end is left out")
    check(SoundCues.engineCues(kind: .sectionCard, props: [:], length: 2).map(\.cue) == ["in"]
              && SoundCues.engineCues(kind: .titleCard, props: [:], length: 5).map(\.cue) == ["in"]
              && SoundCues.engineCues(kind: .namePlate, props: [:], length: 4).isEmpty,
          "section and title cards have a cue as they come in; other kinds have none yet")

    print("\nSounds: the library")
    setenv("YAMVIDEO_SOUNDS_DIR", scratch.appendingPathComponent("sounds-library").path, 1)
    try? FileManager.default.removeItem(at: SoundLibrary.folder)
    let click = try await makeSound("sound-click.wav", source: "sine=frequency=1500:sample_rate=44100", seconds: 0.12, filter: "volume=0.5,afade=t=out:st=0.02:d=0.1")
    let whoosh = try await makeSound("sound-whoosh.wav", source: "anoisesrc=color=pink:sample_rate=44100:amplitude=0.3", seconds: 0.8,
                                     filter: "bandpass=f=1200:width_type=h:w=1600,afade=t=in:d=0.4,afade=t=out:st=0.4:d=0.4")
    let long = try await makeSound("sound-long.wav", source: "sine=frequency=440:sample_rate=44100", seconds: 7)
    let silent = try await makeSound("sound-silent.wav", source: "anullsrc=r=44100:cl=mono", seconds: 0.5)
    let clickSound = try await SoundLibrary.set(name: "click", file: click, credit: MusicCredit(licence: .cc0))
    let whooshSound = try await SoundLibrary.set(name: "whoosh-1", file: whoosh, credit: MusicCredit(licence: .own))
    check(near(clickSound.duration, 0.12, 0.01) && clickSound.loudness < -10 && clickSound.loudness > -60 && clickSound.peak < 0 && clickSound.peak > -40,
          "the app measures a sound: its length, its loudest 400 ms and its peak", "\(clickSound)")
    check(SoundLibrary.load().map(\.name) == ["click", "whoosh-1"]
              && FileManager.default.fileExists(atPath: SoundLibrary.url(of: whooshSound).path),
          "the library keeps a copy of each file, by name")
    _ = try await SoundLibrary.set(name: "Click", file: click, credit: MusicCredit(licence: .cc0))
    check(SoundLibrary.load().count == 2, "a sound of the same name (any case) replaces the old one")
    func refused(_ name: String, _ file: URL, _ words: String) async -> Bool {
        do { _ = try await SoundLibrary.set(name: name, file: file, credit: MusicCredit()); return false }
        catch { return error.localizedDescription.contains(words) }
    }
    let refusedLong = await refused("long", long, "6 s or shorter")
    let refusedSilent = await refused("quiet", silent, "silent")
    let refusedOff = await refused("off", click, "not \"off\"")
    check(refusedLong && refusedSilent && refusedOff, "a long file, a silent file and the name \"off\" are refused")
    _ = try await SoundLibrary.set(name: "spare", file: click, credit: MusicCredit())
    try SoundLibrary.remove(name: "spare")
    check(SoundLibrary.load().count == 2 && (try? SoundLibrary.remove(name: "nothing")) == nil, "removeSound removes one; an unknown name is refused")

    print("\nSounds: the cues on a recording")
    let quiet = try await makeQuietClip("sounds-quiet.mov", seconds: 16)
    let quietInfo = try await FFmpeg.probe(url: quiet)
    var item = VideoItem(url: quiet)
    item.info = quietInfo; item.crop = quietInfo.fullFrame; item.status = .ready
    item.graphics = GraphicsTrack(items: [
        Graphic(kind: .sectionCard, start: 2, end: 4, props: ["title": .string("Part one")]),
        Graphic(kind: .titleCard, start: 5, end: 8, props: ["title": .string("A title")]),
        Graphic(kind: .link, start: 8, end: 15, props: ["url": .string("ab.cd"), "image": .string("/tmp/x.jpg")]),
    ])
    item.sounds = SoundSettings(voice: -16, cues: ["link.key": "click", "titleCard.in": SoundCues.off])
    let placed = item.placedCues()
    let section = placed.first { $0.key == "sectionCard.in" }
    let expectedGain = min(-16 - 8 - whooshSound.loudness, SoundCues.peakCap - whooshSound.peak)
    check(placed.count == 9 && near(section?.at ?? -1, 2) && section?.sound == "whoosh-1" && near(section?.gain ?? 0, expectedGain, 0.01),
          "a section card's whoosh sits at its start, 8 LU under the voice (or at the peak cap)", "\(placed)")
    let keys = placed.filter { $0.key == "link.key" }
    check(keys.count == 5 && near(keys[0].at, 9.3) && keys.allSatisfy { $0.sound == "click" && !$0.missing }
              && placed.first { $0.key == "titleCard.in" }?.sound == nil
              && placed.first { $0.key == "link.click" }.map { $0.missing && $0.sound == "button-4" } == true,
          "a cue plays the sound the recording chose, nothing when off, and its default otherwise (missing here)")
    check(keys.allSatisfy { ($0.gain ?? 0) <= SoundCues.peakCap - clickSound.peak + 0.01 },
          "no cue peaks above -12 dBFS")
    var softer = item; softer.sounds?.level = -6
    check(near(softer.placedCues().first { $0.key == "sectionCard.in" }?.gain ?? 0, min(-16 - 14 - whooshSound.loudness, SoundCues.peakCap - whooshSound.peak), 0.01),
          "the sounds' level moves every cue")
    var silenced = item; silenced.sounds?.on = false
    var noGraphics = item; noGraphics.switchedOff = [.graphics]
    check(silenced.placedCues().isEmpty && noGraphics.effective.placedCues().isEmpty && item.asRecorded.placedCues().isEmpty,
          "off, graphics switched off, and Before have no cues")

    print("\nSounds: the export and the preview")
    let mix = item.exportMusic(ExportSettings())
    check(mix?.plays.isEmpty == true && mix?.cues.count == 6 && mix?.files.count == 2, "the cues with a sound join the mix, each file once",
          "\(String(describing: mix))")
    let graph = FFmpeg.musicGraph(mix!, firstInput: 1, voice: "timelinea", output: "mixa").joined(separator: ";")
    check(graph.contains("asplit=5") && graph.contains("[muk0]atrim=duration=") && graph.contains("amix=inputs=7:normalize=0:duration=first")
              && graph.contains("adelay=delays=96000S"),
          "each cue is its whole file, at its gain and place, mixed with the voice", graph)
    let cuedOut = scratch.appendingPathComponent("sounds-cued.mp4")
    try await FFmpeg.export(input: quiet, output: cuedOut, info: quietInfo, crop: quietInfo.fullFrame, settings: ExportSettings(),
                            music: item.exportMusic(ExportSettings())) { _ in }
    let atWhoosh = try await rmsLevel(cuedOut, start: 2.1, length: 0.5)
    let between = try await rmsLevel(cuedOut, start: 3.0, length: 1.5)
    let atKeys = try await rmsLevel(cuedOut, start: 9.3, length: 0.5)
    check(atWhoosh > -60 && atKeys > -60 && between < -90, "the export plays each cue at its time, and nothing between",
          "whoosh \(atWhoosh) between \(between) keys \(atKeys)")
    let previewItem = try await PlaybackController.makeItem(item, settings: ExportSettings())
    let tracks = (previewItem.asset as? AVComposition)?.tracks(withMediaType: .audio) ?? []
    check(tracks.count >= 4 && previewItem.audioMix?.inputParameters.count == tracks.count,
          "the preview puts the cues on tracks of their own, with their volumes", "\(tracks.count)")

    print("\nSounds: the project file")
    let project = VideoProject(clips: [ProjectClip(item)], settings: ExportSettings(), selection: item.id)
    var plain = project; plain.clips[0].sounds = nil
    let turnedOn = try ProjectReducer.apply([.setSounds(clip: item.id, sounds: SoundSettings(voice: -18))], to: plain).project
    check(turnedOn.clips[0].sounds?.voice == -18 && turnedOn.clips[0].sounds?.on == true, "setSounds turns the sounds on")
    check(reducerRefusal([.setSounds(clip: item.id, sounds: SoundSettings(level: 20, voice: -18))], plain) == .invalidCommand
              && reducerRefusal([.setSounds(clip: item.id, sounds: SoundSettings(voice: -18, cues: ["kineticText.word": "click"]))], plain) == .invalidCommand,
          "a level out of range and an unknown cue are refused")
    var silentItem = item; silentItem.info?.audioCodec = nil
    check(reducerRefusal([.setSounds(clip: item.id, sounds: SoundSettings(voice: -18))],
                         VideoProject(clips: [ProjectClip(silentItem)], settings: ExportSettings(), selection: item.id)) == .invalidCommand,
          "a recording with no sound cannot have sound effects")
    let reopened = try VideoProject.decodeMigrating(from: try JSONEncoder().encode(project))
    check(reopened.clips[0].sounds == project.clips[0].sounds && reopened.version == VideoProject.currentVersion,
          "a project saves and opens with its sounds")
    var older = project; older.version = 22
    do { try older.validate(); check(false, "a version 22 file with sounds is refused") }
    catch { check(error.localizedDescription.contains("sound"), "a version 22 file with sounds is refused", error.localizedDescription) }

    print("\nSounds: licences for YouTube")
    var details = PublishInfo(); details.title = "A video"; details.description = "About design."
    var credited = clickSound; credited.credit = MusicCredit(licence: .ccBy, title: "Click", artist: "Ana", line: "Sound: Click by Ana (CC BY 4.0)")
    var blocked = clickSound; blocked.credit.licence = .ccNC
    var unset = clickSound; unset.credit.licence = nil
    check(details.crediting(nil, sounds: [credited]).description.hasSuffix("Sound: Click by Ana (CC BY 4.0)")
              && details.issues(duration: 10, sounds: [blocked]).contains { $0.field == "sounds" && $0.severity == .blocking }
              && details.issues(duration: 10, sounds: [unset]).contains { $0.field == "sounds" && $0.severity == .warning },
          "a sound's credit line goes in the description; a non-commercial licence stops the export; no licence warns")
    check(item.usedSounds.map { $0.name.lowercased() } == ["whoosh-1", "click"], "the export checks the sounds the cues play, each once", "\(item.usedSounds.map(\.name))")

    print("\nSounds: agents")
    let voiced = try await makeClip("sounds-voice.mov", size: "320x180", seconds: 12, audio: "aac")
    let voicedInfo = try await FFmpeg.probe(url: voiced)
    var spoken = VideoItem(url: voiced)
    spoken.info = voicedInfo; spoken.crop = voicedInfo.fullFrame; spoken.status = .ready
    spoken.graphics = GraphicsTrack(items: [Graphic(kind: .sectionCard, start: 1, end: 3, props: ["title": .string("Part one")])])
    let agent = AppModel(recoveryURL: nil)
    agent.restore(VideoProject(clips: [ProjectClip(spoken)], settings: ExportSettings(), selection: spoken.id))
    var on = address(agent)
    on["method"] = "apply"; on["requestID"] = "sounds-on"; on["client"] = "Claude"
    on["commands"] = [["type": "setSounds", "clipID": spoken.id.uuidString, "sounds": ["on": true, "cues": ["sectionCard.in": "whoosh-1"]]]]
    let turned = await agentCall(agent, on)
    let state = (agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["sounds"] as? [String: Any]
    let stateCues = state?["cues"] as? [[String: Any]]
    check(turned["ok"] as? Bool == true && (agent.items[0].sounds?.voice ?? 0) < 0 && stateCues?.count == 1
              && stateCues?.first?["sound"] as? String == "whoosh-1" && stateCues?.first?["gain"] is Double,
          "an agent turns the sounds on: the app measures the voice; state shows each cue with its gain", "\(turned) \(String(describing: state))")
    var wrong = address(agent)
    wrong["method"] = "apply"; wrong["requestID"] = "sounds-wrong"; wrong["client"] = "Claude"
    wrong["commands"] = [["type": "setSounds", "clipID": spoken.id.uuidString, "sounds": ["cues": ["sectionCard.out": "click"]]]]
    check(agentError(await agentCall(agent, wrong)) == "invalid_command", "an unknown cue is refused, with the cues there are")
    let listed = agentResult(await agentCall(agent, ["method": "sounds"]))
    check((listed["sounds"] as? [[String: Any]])?.count == 2 && (listed["defaults"] as? [[String: Any]])?.count == SoundCues.all.count,
          "sounds lists the library and the default cues")
    let setting = await agentCall(agent, ["method": "setSound", "requestID": "sounds-set", "name": "pop", "path": click.path,
                                          "credit": ["licence": "cc0", "title": "Pop"]])
    let removing = await agentCall(agent, ["method": "removeSound", "requestID": "sounds-remove", "name": "pop"])
    check(((agentResult(setting)["sounds"] as? [[String: Any]])?.count) == 3 && ((agentResult(removing)["sounds"] as? [[String: Any]])?.count) == 2,
          "setSound keeps a measured copy; removeSound removes it", "\(setting)")
    let catalog = AgentCatalog.current
    check(catalog.commands.contains { $0.type == "setSounds" } && ["sounds", "setSound", "removeSound"].allSatisfy { name in catalog.methods.contains { $0.method == name } },
          "the catalog has setSounds and the sound library methods")
    let manual = (try? String(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("Resources/AgentsManual.md"), encoding: .utf8)) ?? ""
    check(manual.contains("### 4.19 Sound effects") && manual.contains("setSounds"), "the Agents Manual has the sound effects recipe")
    unsetenv("YAMVIDEO_SOUNDS_DIR")
}
