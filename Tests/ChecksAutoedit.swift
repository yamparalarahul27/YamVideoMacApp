// Checks for autoedit. Run with ./test.sh autoedit
import AppKit
import AVFoundation
import Foundation

@MainActor func autoeditTests() async throws {
    // MARK: - Auto edit

    print("\nAuto edit options")
    var autoOptions = AutoEditOptions()
    check(autoOptions.problem == nil && autoOptions.model == .largeV3Turbo && autoOptions.language == "en" && autoOptions.cutStyle == .tight
              && autoOptions.captions == .upload && autoOptions.normaliseAudio,
          "the defaults are the first video's answers: Large v3 Turbo, English, Tight, SRT for upload, -14 LUFS")
    autoOptions.model = .baseEnglish; autoOptions.language = "hi"
    check(autoOptions.problem?.contains("English only") == true, "Base (English) with another language is refused, naming the fix")
    autoOptions.model = .largeV3Turbo; autoOptions.language = "xx"
    check(autoOptions.problem?.contains("whisper language code") == true, "an unknown language is refused with what is allowed")
    check(["auto", "en", "hi", "te", "ta", "yue"].allSatisfy(AutoEditOptions.languages.contains), "every whisper language can be chosen, and auto")
    equal(PauseRule.tight, PauseRule(threshold: -40, minimum: 0.42, padding: 0.11, sentencePadding: 0.20, commaPadding: 0.15),
          "Tight cuts pauses of 0.42 s or more down to about 0.22 s, 0.30 s after a comma and 0.40 s after a sentence")
    equal(CutStyle.natural.pauses, PauseRule(threshold: -40, minimum: 0.8, padding: 0.15), "Natural is the silence review's defaults")

    print("\nStumbles")
    let stumbleWords = spokenWords([("Um,", 0.1), ("the", 0.5), ("the", 0.7), ("first", 0.9), ("step", 1.2), ("is,", 1.4), ("I", 1.8), ("think", 1.9),
                                    ("we,", 2.1), ("I", 2.4), ("think", 2.5), ("we", 2.7), ("should", 2.8), ("wh-", 3.1), ("what", 3.3), ("a", 3.5),
                                    ("very", 3.6), ("very", 3.8), ("good", 4.0), ("day.", 4.2)], end: 4.6)
    let foundStumbles = StumbleFinder.stumbles(in: stumbleWords)
    equal(foundStumbles.map(\.kind), [.filler, .repeated, .restart, .fragment], "a filler, a repeat, a restart and a broken-off word are found")
    check(foundStumbles.count == 4 && foundStumbles[0].start == 0.1 && foundStumbles[0].end == 0.5, "a filler goes from its start to the next word")
    check(foundStumbles.count == 4 && foundStumbles[1].text == "the" && foundStumbles[1].start == 0.5 && foundStumbles[1].end == 0.7,
          "a repeat takes out the first of the two")
    check(foundStumbles.count == 4 && foundStumbles[2].text == "I think we," && foundStumbles[2].start == 1.8 && foundStumbles[2].end == 2.4,
          "a restart takes out the words that are said again")
    check(foundStumbles.count == 4 && foundStumbles[3].text == "wh-" && foundStumbles[3].end == 3.3, "a broken-off word goes")
    check(!foundStumbles.contains { $0.text == "very" }, "a word said twice for emphasis stays")

    print("\nPlanning cuts")
    /// Levels every 50 ms: loud inside `loud`, quiet elsewhere.
    // Speech at 0–1, an "um" at 1.9–2.2, "the the first step." at 2.4–3.5, "I think I think so." at 4.5–6.
    let talkLoud: [(Double, Double)] = [(0, 1), (1.9, 2.2), (2.4, 3.5), (4.5, 6)]
    let talkLevels = syntheticLevels(talkLoud, until: 6.5)
    let talkWords = spokenWords([("Hello", 0.1), ("there.", 0.55), ("Um,", 2.0), ("the", 2.5), ("the", 2.8), ("first", 3.05), ("step.", 3.3),
                                 ("I", 4.6), ("think", 4.8), ("I", 5.1), ("think", 5.3), ("so.", 5.6)], end: 6.0)
    let talkTranscript = Transcript(model: "base.en", language: "en", words: talkWords)
    let talkTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 6.5)])
    let naturalCuts = CutPlanner.cuts(levels: talkLevels, timeline: talkTimeline, fps: 30, rule: .natural)
    equal(spans(naturalCuts), [[1.167, 1.733], [3.667, 4.333]], "Natural cuts only pauses of 0.8 s or more, keeping 0.15 s each side, on frames")
    equal(spans(talkLevels.cuts(in: talkTimeline, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15)), spans(naturalCuts),
          "the silence review's cuts are the planner's without stumbles")
    let tightCuts = CutPlanner.cuts(levels: talkLevels, timeline: talkTimeline, fps: 30, rule: .tight,
                                    stumbles: StumbleFinder.stumbles(in: talkWords))
    equal(spans(tightCuts), [[1.133, 2.733], [3.633, 5.033], [6.133, 6.367]],
          "Tight joins a pause, an um, the pause after it and a repeat into one cut, and a pause with the restart after it into another")
    equal(tightCuts.map(\.kinds), [["filler", "repeat", "pause"], ["restart", "pause"], ["pause"]], "each cut says what it takes out")
    equal(tightCuts.first?.reason, "Filler “Um,”, Repeat “the” and pause", "in words the review list can show")
    check(tightCuts.count == 3 && abs(tightCuts[0].start - 1.0 - 0.11) < 1.0 / 30 + 0.001,
          "where a cut meets a pause, 0.11 s of it stays so the speech before is never clipped")
    check(tightCuts.count == 3 && tightCuts[0].end < 2.8 && tightCuts[0].end > 2.6,
          "where it meets speech, it ends in the moment before the next word, not at whisper's late time")
    let tightTimeline = talkTimeline.removing(tightCuts)
    let tightKept = talkTranscript.keptWords(tightTimeline).map(\.word.text)
    equal(tightKept, ["Hello", "there.", "the", "first", "step.", "I", "think", "so."], "the words left are the ones meant")
    let pauseOnly = CutPlanner.cuts(levels: syntheticLevels([(0, 1), (1.3, 2)], until: 2), timeline: ClipTimeline(segments: [TimelineSegment(start: 0, end: 2)]),
                                    fps: 30, rule: .tight)
    check(pauseOnly.isEmpty, "a 0.3 s pause is left alone by Tight")
    check(CutPlanner.cuts(levels: talkLevels, timeline: tightTimeline, fps: 30, rule: .tight, stumbles: StumbleFinder.stumbles(in: talkWords)).isEmpty,
          "planning again on the cut recording finds nothing more to cut")

    print("\nLonger breaths between sentences")
    // Speech, then a 0.8 s pause after "done.", after "well," and after "and". Cuts land on
    // frames inside the pause, so each pause can keep up to a frame more at each end.
    let breathLevels = syntheticLevels([(0, 1), (1.8, 3), (3.8, 5), (5.8, 7)], until: 7)
    let breathWords = spokenWords([("It's", 0.1), ("done.", 0.5), ("Then", 1.9), ("well,", 2.5), ("and", 4.6), ("more.", 5.9)], end: 7)
    let breathTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 7)])
    let breathCuts = CutPlanner.cuts(levels: breathLevels, timeline: breathTimeline, fps: 30, rule: .tight, words: breathWords)
    let pauses: [(Double, Double)] = [(1, 1.8), (3, 3.8), (5, 5.8)]
    let heard = zip(breathCuts, pauses).map { cut, pause in (cut.start - pause.0) + (pause.1 - cut.end) }
    check(breathCuts.count == 3 && abs(heard[0] - 0.40) < 0.07 && abs(heard[1] - 0.30) < 0.07 && abs(heard[2] - 0.22) < 0.07
              && heard[0] > heard[1] && heard[1] > heard[2],
          "Tight leaves 0.40 s after a sentence, 0.30 s after a comma and 0.22 s inside a sentence", "\(heard)")
    let plainCuts = CutPlanner.cuts(levels: breathLevels, timeline: breathTimeline, fps: 30, rule: .tight)
    let plainHeard = zip(plainCuts, pauses).map { cut, pause in (cut.start - pause.0) + (pause.1 - cut.end) }
    check(plainCuts.count == 3 && plainHeard.allSatisfy { abs($0 - 0.22) < 0.07 } && PauseRule.natural.padding(after: ".") == 0.15,
          "without the transcript every pause keeps about 0.22 s; Natural keeps its own 0.15 s each side", "\(plainHeard)")
    check(CutPlanner.cuts(levels: syntheticLevels([(0, 1), (1.45, 2)], until: 2), timeline: ClipTimeline(segments: [TimelineSegment(start: 0, end: 2)]),
                          fps: 30, rule: .tight, words: spokenWords([("done.", 0.5), ("Next", 1.5)], end: 2)).isEmpty,
          "a 0.45 s pause after a sentence is already about right, so it stays")

    print("\nSmooth joints")
    // The fixture is a 440 Hz tone: a hard cut joins the wave at another point and clicks.
    let jointSegments = [TimelineSegment(start: 0, end: 1.0), TimelineSegment(start: 1.2731, end: 2.0)]
    let joined = ClipTimeline(segments: jointSegments)
    check(joined.audioJoints.count == 1 && abs(joined.audioJoints[0].time - 1.0) < 0.0001 && joined.audioJoints[0].fade == ClipTimeline.jointFade
              && ClipTimeline(segments: [TimelineSegment(start: 0, end: 1.0), TimelineSegment(start: 1.0, end: 2.0)]).audioJoints.isEmpty,
          "the sound is cut where the source jumps, not where a section is only split")
    func samples(_ url: URL) async throws -> [Double] {
        let raw = try await Shell.run(ffmpeg, ["-v", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "-"]).stdout
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Double($0) / 32768 }
    }
    func rms(_ x: [Double], _ from: Double, _ to: Double) -> Double {
        let part = x[Int(from * 48000)..<Int(to * 48000)]
        return (part.map { $0 * $0 }.reduce(0, +) / Double(part.count)).squareRoot()
    }
    func step(_ x: [Double], _ from: Double, _ to: Double) -> Double {
        (Int(from * 48000)..<Int(to * 48000)).map { abs(x[$0] - x[$0 - 1]) }.max() ?? 0
    }
    let cutOut = scratch.appendingPathComponent("joint-cut.mp4"), splitOut = scratch.appendingPathComponent("joint-split.mp4")
    try await FFmpeg.export(input: landscape, output: cutOut, info: info, crop: info.fullFrame, segments: jointSegments, settings: ExportSettings()) { _ in }
    try await FFmpeg.export(input: landscape, output: splitOut, info: info, crop: info.fullFrame,
                            segments: [TimelineSegment(start: 0, end: 1.0), TimelineSegment(start: 1.0, end: 2.0)], settings: ExportSettings()) { _ in }
    let cutSound = try await samples(cutOut), splitSound = try await samples(splitOut)
    let steady = rms(cutSound, 0.5, 0.6)
    check(rms(cutSound, 0.997, 1.003) < steady * 0.6 && step(cutSound, 0.995, 1.005) < step(cutSound, 0.5, 0.6) * 1.5,
          "the export fades out and in at a cut: the sound dips for a moment and does not click",
          String(format: "joint %.3f of %.3f, step %.3f of %.3f", rms(cutSound, 0.997, 1.003), steady, step(cutSound, 0.995, 1.005), step(cutSound, 0.5, 0.6)))
    check(rms(splitSound, 0.997, 1.003) > rms(splitSound, 0.5, 0.6) * 0.85, "a split with nothing taken out plays on without a dip")
    var jointItem = VideoItem(url: landscape); jointItem.info = info; jointItem.segments = jointSegments
    let jointPlayer = try await PlaybackController.makeItem(jointItem, settings: ExportSettings())
    var startVolume: Float = -1, endVolume: Float = -1, rampRange = CMTimeRange.zero
    let ramped = (jointPlayer.audioMix?.inputParameters.first)?.getVolumeRamp(for: CMTime(seconds: 0.995, preferredTimescale: 600_000),
                                                                             startVolume: &startVolume, endVolume: &endVolume, timeRange: &rampRange) ?? false
    check(ramped && startVolume == 1 && endVolume == 0 && abs(rampRange.end.seconds - 1.0) < 0.0005,
          "the preview fades the sound the same way", "\(ramped) \(startVolume)→\(endVolume) \(rampRange.start.seconds)–\(rampRange.end.seconds)")

    print("\nCaptions from the transcript")
    let talkCaptions = Captions.edited(talkTranscript.captions(timeline: tightTimeline), timeline: tightTimeline)
    equal(talkCaptions.map(\.text), ["Hello there. the first step.", "I think so."],
          "captions leave out the cut words, run across a cut, and break at sentence ends")
    check(talkCaptions.count == 2 && abs(talkCaptions[0].start - 0.1) < 0.002 && abs(talkCaptions[0].end - 2.033) < 0.002
              && abs(talkCaptions[1].start - 2.1) < 0.002,
          "and land on the edited timeline as one caption per line", "\(talkCaptions)")
    check(Transcript.lines("one two three four five six seven eight nine ten eleven twelve".split(separator: " ").map(String.init)).contains("\n"),
          "a caption over 42 characters is set on two lines")
    let uncut = Captions.edited(talkTranscript.captions(timeline: talkTimeline), timeline: talkTimeline)
    check(uncut.first?.text.hasPrefix("Hello there. Um,") == true && uncut.allSatisfy { $0.end > $0.start }, "uncut, every word is captioned")

    print("\nReading whisper.cpp")
    let whisperJSON = #"""
    {"systeminfo": "test", "model": {"type": "base"}, "params": {"model": "/models/ggml-base.en.bin", "language": "en"},
     "result": {"language": "en"},
     "transcription": [
      {"offsets": {"from": 0, "to": 2720}, "text": " Hello and welcome.", "tokens": [
        {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "id": 50363, "p": 0.9, "t_dtw": -1},
        {"text": " Hello", "offsets": {"from": 50, "to": 480}, "id": 1, "p": 0.85, "t_dtw": 22},
        {"text": " and", "offsets": {"from": 480, "to": 770}, "id": 2, "p": 0.98, "t_dtw": 42},
        {"text": " wel", "offsets": {"from": 770, "to": 1000}, "id": 3, "p": 0.9, "t_dtw": 76},
        {"text": "come", "offsets": {"from": 1000, "to": 1440}, "id": 4, "p": 0.9, "t_dtw": 90},
        {"text": ".", "offsets": {"from": 2680, "to": 2720}, "id": 5, "p": 0.7, "t_dtw": 230},
        {"text": "[_TT_136]", "offsets": {"from": 2720, "to": 2720}, "id": 50500, "p": 0.05, "t_dtw": -1}]},
      {"offsets": {"from": 2720, "to": 4000}, "text": " [BLANK_AUDIO]", "tokens": [
        {"text": " [", "offsets": {"from": 2720, "to": 2800}, "t_dtw": 280}, {"text": "BL", "t_dtw": 281},
        {"text": "ANK", "t_dtw": 282}, {"text": "_AUDIO", "t_dtw": 283}, {"text": "]", "t_dtw": 284}]},
      {"offsets": {"from": 4000, "to": 6000}, "text": " Um, the the end.", "tokens": [
        {"text": " Um", "offsets": {"from": 4000, "to": 4200}, "t_dtw": 410}, {"text": ",", "t_dtw": 430},
        {"text": " the", "offsets": {"from": 4300, "to": 4500}, "t_dtw": -1}, {"text": " the", "t_dtw": 480},
        {"text": " end", "t_dtw": 520}, {"text": ".", "t_dtw": 560}]}]}
    """#
    let parsedWhisper = try Whisper.parse(Data(whisperJSON.utf8), model: "base.en", language: "en")
    equal(parsedWhisper.words.map(\.text), ["Hello", "and", "welcome.", "Um,", "the", "the", "end."],
          "words come from each segment's text, without whisper's markers or [BLANK_AUDIO]")
    equal(parsedWhisper.words.map(\.start), [0.22, 0.42, 0.76, 4.1, 4.3, 4.8, 5.2],
          "each word starts at its first token's DTW time, or whisper's own time where DTW has none")
    check(parsedWhisper.words[2].end == 2.72 && parsedWhisper.words[0].end == 0.42, "a word ends where the next starts, or at its segment's end")
    let importedWhisper = try AppModel.readTranscript(Data(whisperJSON.utf8))
    check(importedWhisper.model == "base.en" && importedWhisper.words.count == 7, "an imported whisper file names its model from the file")
    check((try? Whisper.parse(Data("{}".utf8), model: "x", language: "en")) == nil, "a file that is not whisper's JSON is refused")

    print("\nAuto edit in the app")
    let talkMovie = scratch.appendingPathComponent("talk.mov")
    let talkMade = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
        "-f", "lavfi", "-i", "aevalsrc=exprs='if(between(t,0,1)+between(t,1.9,2.2)+between(t,2.4,3.5)+between(t,4.5,6),0.5*sin(2*PI*440*t),0)':s=48000:d=6.5",
        "-t", "6.5", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", talkMovie.path])
    check(talkMade.status == 0, "made a 6.5 s recording that speaks, pauses, says um and repeats itself", talkMade.stderrText)
    let talkInfo = try await FFmpeg.probe(url: talkMovie)
    var talkItem = VideoItem(url: talkMovie)
    talkItem.info = talkInfo; talkItem.crop = talkInfo.fullFrame; talkItem.status = .ready
    let talkEditor = AppModel(recoveryURL: nil)
    talkEditor.restore(VideoProject(clips: [ProjectClip(talkItem)], settings: ExportSettings(), selection: talkItem.id))

    equal(reducerRefusal([.setTranscript(clip: talkItem.id, transcript: Transcript(model: "x", language: "en",
                                                                               words: [TranscriptWord(text: "late", start: 30, end: 31)]))],
                         talkEditor.project), .invalidCommand, "a transcript with words past the recording is refused")
    var badOptions = AutoEditOptions(); badOptions.model = .baseEnglish; badOptions.language = "fr"
    equal(reducerRefusal([.setAutoEditOptions(badOptions)], talkEditor.project), .invalidCommand, "invalid answers are refused")

    check(talkEditor.autoEdit == nil && talkEditor.autoEditOptions == AutoEditOptions(), "a project without answers uses the defaults")
    talkEditor.setAutoEditOptions { $0.model = .baseEnglish; $0.language = "te" }
    check(talkEditor.autoEdit?.model == .baseEnglish && talkEditor.autoEdit?.language == "en",
          "choosing Base (English) sets the language to English")
    talkEditor.setAutoEditOptions { $0.language = "te" }
    check(talkEditor.autoEdit?.model == .largeV3Turbo && talkEditor.autoEdit?.language == "te",
          "choosing another language with it switches to Large v3 Turbo")
    equal(talkEditor.undoTitle, "Undo Auto Edit Options", "each change to the answers is an undo step")
    talkEditor.setAutoEditOptions { $0 = AutoEditOptions() }

    talkEditor.perform([.setTranscript(clip: talkItem.id, transcript: talkTranscript)])
    let talkPlan = try await talkEditor.planAutoEdit(talkItem.id, options: talkEditor.autoEditOptions)
    check(talkPlan.cuts.count == 3 && talkPlan.cuts[0].kinds.contains("filler") && talkPlan.cuts[0].kinds.contains("repeat")
              && talkPlan.cuts[1].kinds.contains("restart"),
          "on the real recording's audio, Tight finds the um, the repeat, the restart and the pauses", "\(talkPlan.cuts.map(\.kinds))")
    check(talkPlan.settings.captions == .upload && talkPlan.settings.audio == .normalised, "and sets SRT for upload and -14 LUFS")
    let beforeAuto = talkEditor.items[0].editedDuration
    _ = talkEditor.applyAutoEdit(talkPlan)
    let afterAuto = talkEditor.items[0].editedDuration
    check(abs(beforeAuto - afterAuto - talkPlan.savedSeconds) < 0.001 && afterAuto < 4.5,
          "applying it shortens the recording by what it said", "\(beforeAuto) → \(afterAuto)")
    check(talkEditor.settings.captions == .upload && talkEditor.settings.audio == .normalised, "captions and loudness are set in the same step")
    equal(talkEditor.undoTitle, "Undo Auto Edit", "the whole auto edit is one undo step")
    let autoCaptions = talkEditor.items[0].uploadCaptionsSRT(talkEditor.settings) ?? ""
    check(autoCaptions.contains("Hello there. the first step.") && !autoCaptions.contains("Um") && !autoCaptions.contains("I think I think"),
          "the uploaded captions come from the transcript without the cut words", autoCaptions)
    check(talkEditor.items[0].burnedCaptions(talkEditor.settings) == nil, "SRT for upload burns nothing into the picture")
    talkEditor.undoEdit()
    check(abs(talkEditor.items[0].editedDuration - beforeAuto) < 0.001 && talkEditor.settings.captions == nil
              && talkEditor.items[0].transcript == talkTranscript,
          "undo puts back the sections and settings, and keeps the transcript")
    let stalePlan = talkPlan
    talkEditor.perform([.splitSection(clip: talkItem.id, at: 3)])
    if case .failure(let error) = talkEditor.applyAutoEdit(stalePlan) {
        check(error.message.contains("changed"), "a plan made before the sections changed is refused", error.message)
    } else { check(false, "a plan made before the sections changed is refused") }
    talkEditor.undoEdit()

    var reviewOptions = AutoEditOptions(); reviewOptions.cutStyle = .review; reviewOptions.captions = .burnIn
    let reviewPlan = try await talkEditor.planAutoEdit(talkItem.id, options: reviewOptions)
    check(reviewPlan.style == .review && reviewPlan.cuts.count == talkPlan.cuts.count, "Review each cut proposes Tight's cuts")
    var keptOne = reviewPlan; keptOne.cuts[0].included = false
    check(talkEditor.applyReviewedAutoEdit(keptOne) == nil && talkEditor.items[0].timeline.segments.count == 3
              && talkEditor.settings.captions == .burnIn,
          "applying a review keeps the cuts the owner unchecked, and sets burned-in captions")
    let burned = talkEditor.items[0].burnedCaptions(talkEditor.settings)
    check(burned.map { (try? String(contentsOf: $0, encoding: .utf8))?.contains("Um,") == true } == true,
          "burned-in captions come from the transcript (the kept um still captioned)")
    talkEditor.undoEdit()

    print("\nCaptions setting")
    var legacyItem = talkItem; legacyItem.subtitles = srt
    check(ExportSettings().captionUse(hasFile: true) == .burnIn && legacyItem.burnedCaptions(ExportSettings()) == srt,
          "a project that never chose keeps burning in a chosen caption file")
    var transcribedItem = talkItem; transcribedItem.transcript = talkTranscript
    check(transcribedItem.captionsFile(ExportSettings()) == nil, "and does not start captioning from a transcript on its own")
    var offSettings = ExportSettings(); offSettings.captions = .off
    check(legacyItem.captionsFile(offSettings) == nil && !legacyItem.uploadsCaptions(offSettings), "None turns a caption file off too")
    var uploadSettings = ExportSettings(); uploadSettings.captions = .upload
    check(legacyItem.captionsFile(uploadSettings) == srt && legacyItem.captionsSource(uploadSettings) == "file"
              && transcribedItem.captionsSource(uploadSettings) == "transcript",
          "a chosen caption file comes before the transcript")
    check(AppModel.exportSettingKeys.contains("captions"), "agents can set captions with setExportSettings")

    print("\nVersion 11")
    var elevenProject = talkEditor.project
    elevenProject.autoEdit = AutoEditOptions(); elevenProject.settings.captions = .upload
    let elevenRoundTrip = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(elevenProject))
    check(elevenRoundTrip == elevenProject && elevenRoundTrip.version >= 11 && elevenRoundTrip.clips[0].transcript == talkTranscript,
          "answers, a transcript and the captions choice survive a version 11 round trip")
    for (label, change) in [("answers", { (project: inout VideoProject) in project.clips[0].transcript = nil; project.settings.captions = nil }),
                            ("a transcript", { (project: inout VideoProject) in project.autoEdit = nil; project.settings.captions = nil }),
                            ("a captions choice", { (project: inout VideoProject) in project.autoEdit = nil; project.clips[0].transcript = nil })] {
        var older = elevenProject; change(&older); older.version = 10
        check((try? older.validate()) == nil, "a version 10 file with \(label) is refused")
    }

    print("\nAuto edit for agents")
    let autoAgent = AppModel(recoveryURL: nil)
    autoAgent.restore(VideoProject(clips: [ProjectClip(talkItem)], settings: ExportSettings(), selection: talkItem.id))
    let talkID = talkItem.id.uuidString
    let autoState = agentResult(await agentCall(autoAgent, ["method": "state"]))
    let autoBlock = autoState["autoEdit"] as? [String: Any] ?? [:]
    check(autoBlock["saved"] as? Bool == false && (autoBlock["options"] as? [String: Any])?["cutStyle"] as? String == "tight"
              && (autoBlock["models"] as? [[String: Any]])?.count == 2,
          "state shows the answers in effect, whether they were saved, and the models", "\(autoBlock)")
    check(((autoState["clips"] as? [[String: Any]])?.first?["captions"] as? [String: Any])?["use"] as? String == "off",
          "and each recording's captions")
    var setAnswers = address(autoAgent)
    setAnswers["method"] = "apply"; setAnswers["requestID"] = "auto-1"; setAnswers["client"] = "Claude"
    setAnswers["commands"] = [["type": "setAutoEditOptions", "autoEdit": ["cutStyle": "loose"]]]
    check(((await agentCall(autoAgent, setAnswers))["error"] as? [String: Any])?["message"] as? String == "cutStyle must be one of: tight, natural, review.",
          "an unknown cut style is refused with the allowed ones")
    setAnswers["requestID"] = "auto-2"; setAnswers["commands"] = [["type": "setAutoEditOptions", "autoEdit": ["model": "base.en", "language": "hi"]]]
    check((((await agentCall(autoAgent, setAnswers))["error"] as? [String: Any])?["message"] as? String ?? "").contains("English only"),
          "and so is Base (English) with Hindi")
    setAnswers["requestID"] = "auto-3"; setAnswers["commands"] = [["type": "setAutoEditOptions", "autoEdit": ["cutStyle": "natural", "captions": "burnIn"]]]
    let answered = await agentCall(autoAgent, setAnswers)
    check(answered["ok"] as? Bool == true && autoAgent.autoEdit?.cutStyle == .natural && autoAgent.autoEdit?.captions == .burnIn
              && autoAgent.autoEdit?.normaliseAudio == true,
          "an agent changes only the answers it names", "\(answered)")

    let transcriptFile = scratch.appendingPathComponent("talk-transcript.json")
    try JSONEncoder().encode(talkTranscript).write(to: transcriptFile)
    var importing = address(autoAgent)
    importing["method"] = "apply"; importing["requestID"] = "auto-4"; importing["client"] = "Claude"
    importing["commands"] = [["type": "importTranscript", "clipID": talkID, "path": transcriptFile.path]]
    let importedWords = await agentCall(autoAgent, importing)
    check(importedWords["ok"] as? Bool == true && autoAgent.items[0].transcript == talkTranscript, "an agent imports a transcript", "\(importedWords)")
    let summary = ((agentResult(await agentCall(autoAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["transcript"] as? [String: Any]) ?? [:]
    check(summary["words"] as? Int == 12 && summary["keptWords"] as? Int == 12, "state summarises the transcript", "\(summary)")
    let readBack = agentResult(await agentCall(autoAgent, ["method": "transcript", "clip": talkID]))
    check((readBack["words"] as? [[String: Any]])?.count == 12 && (readBack["stumbles"] as? [[String: Any]])?.map { $0["kind"] as? String ?? "" } == ["filler", "repeat", "restart"]
              && (readBack["captions"] as? [[String: Any]])?.isEmpty == false && (readBack["text"] as? String)?.hasPrefix("Hello there.") == true,
          "transcript gives the words, the stumbles and the captions", "\(readBack.keys)")
    equal(agentError(await agentCall(autoAgent, ["method": "transcript", "clip": UUID().uuidString])), "not_found", "transcript of an unknown recording is not found")
    let cutTalk = talkTimeline.removing(tightCuts)
    var cutting = address(autoAgent)
    cutting["method"] = "apply"; cutting["requestID"] = "auto-4b"; cutting["client"] = "Claude"
    cutting["commands"] = [["type": "replaceSections", "clipID": talkID, "sections": cutTalk.segments.map { ["start": $0.start, "end": $0.end] }]]
    _ = await agentCall(autoAgent, cutting)
    let cutWords = agentResult(await agentCall(autoAgent, ["method": "transcript", "clip": talkID]))["words"] as? [[String: Any]] ?? []
    check(cutWords.count == 12 && cutWords[2]["editedStart"] is NSNull && cutWords[0]["editedStart"] is Double,
          "a cut word's editedStart is null, a kept one's a time", "\(cutWords.prefix(3))")
    autoAgent.undoEdit()

    var proposing = address(autoAgent)
    proposing["method"] = "analyze"; proposing["requestID"] = "auto-5"; proposing["kind"] = "autoEdit"; proposing["clip"] = talkID; proposing["style"] = "tight"
    let proposalJob = agentResult(await agentCall(autoAgent, proposing))
    let proposal = (try await waitForJob(autoAgent, proposalJob["id"] as? String ?? ""))["result"] as? [String: Any] ?? [:]
    check(proposal["applied"] as? Bool == false && (proposal["cuts"] as? [[String: Any]])?.count == 3
              && ((proposal["cuts"] as? [[String: Any]])?.first?["reasons"] as? [String])?.contains("filler") == true
              && abs(autoAgent.items[0].editedDuration - 6.5) < 0.05,
          "analyze autoEdit proposes the cuts with their reasons and changes nothing", "\(proposal)")

    var running = address(autoAgent)
    running["method"] = "autoEdit"; running["requestID"] = "auto-6"; running["client"] = "Claude"; running["clip"] = talkID; running["style"] = "tight"
    let autoJob = agentResult(await agentCall(autoAgent, running))
    let autoDone = try await waitForJob(autoAgent, autoJob["id"] as? String ?? "")
    let autoResult = autoDone["result"] as? [String: Any] ?? [:]
    check(autoDone["status"] as? String == "succeeded" && autoResult["applied"] as? Bool == true && autoResult["transactionID"] != nil
              && autoAgent.items[0].editedDuration < 4.5 && autoAgent.settings.captions == .burnIn && autoAgent.settings.audio == .normalised,
          "autoEdit cuts, and sets the captions and loudness answers, in one step", "\(autoDone)")
    equal(autoAgent.undoTitle, "Undo Auto Edit (Claude)", "credited to the agent in the Undo menu")
    check(agentResult(await agentCall(autoAgent, ["method": "catalog"]))["methods"].map { "\($0)".contains("autoEdit") } == true,
          "the catalog describes it")
    autoAgent.undoEdit()
    running["requestID"] = "auto-7"; running["style"] = "review"
    let reviewDone = try await waitForJob(autoAgent, agentResult(await agentCall(autoAgent, running))["id"] as? String ?? "")
    check((reviewDone["result"] as? [String: Any])?["applied"] as? Bool == false && abs(autoAgent.items[0].editedDuration - 6.5) < 0.05
              && ((reviewDone["result"] as? [String: Any])?["note"] as? String ?? "").contains("Review each cut"),
          "with Review each cut nothing is cut and the cuts come back for the owner", "\(reviewDone)")

    let emptyModels = scratch.appendingPathComponent("no-models", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: true)
    let realModels = ProcessInfo.processInfo.environment["YAMVIDEO_WHISPER_DIR"]
    setenv("YAMVIDEO_WHISPER_DIR", emptyModels.path, 1)
    var transcribing = address(autoAgent)
    transcribing["method"] = "transcribe"; transcribing["requestID"] = "auto-8"; transcribing["clip"] = talkID; transcribing["model"] = "base.en"
    let noModel = await agentCall(autoAgent, transcribing)
    check(agentError(noModel) == (Whisper.cliPath == nil ? "unsupported_capability" : "unsupported_capability")
              && ((noModel["error"] as? [String: Any])?["message"] as? String ?? "").contains(Whisper.cliPath == nil ? "brew install whisper-cpp" : "Only the owner can download it"),
          "transcribe without the model is refused: only the owner can download one", "\(noModel)")
    var clearing = address(autoAgent)
    clearing["method"] = "apply"; clearing["requestID"] = "auto-9"; clearing["client"] = "Claude"
    clearing["commands"] = [["type": "clearTranscript", "clipID": talkID]]
    check((await agentCall(autoAgent, clearing))["ok"] as? Bool == true && autoAgent.items[0].transcript == nil, "an agent clears a transcript")
    running["requestID"] = "auto-10"; running["style"] = "tight"
    let needsWords = await agentCall(autoAgent, running)
    check(((needsWords["error"] as? [String: Any])?["message"] as? String ?? "").contains("need a transcript"),
          "autoEdit that needs words it cannot get says so, and how to go on without them", "\(needsWords)")
    if let realModels { setenv("YAMVIDEO_WHISPER_DIR", realModels, 1) } else { unsetenv("YAMVIDEO_WHISPER_DIR") }

    print("\nBurning in transcript captions")
    let burnEditor = AppModel(recoveryURL: nil)
    var burnItem = talkItem; burnItem.transcript = talkTranscript
    var burnSettings = ExportSettings(); burnSettings.captions = .burnIn; burnSettings.subtitleSize = .large
    burnEditor.restore(VideoProject(clips: [ProjectClip(burnItem)], settings: burnSettings, selection: burnItem.id))
    @MainActor func exportTalk(_ editor: AppModel, _ name: String, _ request: String) async throws -> URL {
        let output = scratch.appendingPathComponent(name)
        var exporting = address(editor)
        exporting["method"] = "export"; exporting["requestID"] = request; exporting["clip"] = burnItem.id.uuidString; exporting["path"] = output.path
        _ = try await waitForJob(editor, agentResult(await agentCall(editor, exporting))["id"] as? String ?? "")
        return output
    }
    /// The bottom quarter of a frame, as 8-bit RGB.
    func bottomBand(_ url: URL, at time: Double) async throws -> [UInt8] {
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(time), "-i", url.path, "-frames:v", "1",
                                                  "-vf", "crop=iw:ih/4:0:ih*3/4,format=rgb24", "-f", "rawvideo", "-"])
        return [UInt8](result.stdout)
    }
    if await FFmpeg.supportsSubtitles() {
        let withCaptions = try await exportTalk(burnEditor, "talk-captions.mp4", "burn-1")
        burnSettings.captions = .upload
        burnEditor.updateSettings(burnSettings)
        let withoutCaptions = try await exportTalk(burnEditor, "talk-clean.mp4", "burn-2")
        let a = try await bottomBand(withCaptions, at: 0.5), b = try await bottomBand(withoutCaptions, at: 0.5)
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 60 }.count
        check(a.count == b.count && a.count > 0 && changed > 500,
              "Burn in and SRT draws the transcript's captions into the picture; SRT for upload leaves it clean", "\(changed) bytes changed")
    } else {
        print("  skip burning in: this ffmpeg has no libass")
    }

    if Whisper.cliPath != nil, Whisper.hasModel(.baseEnglish) {
        print("\nTranscribing with whisper.cpp (base.en)")
        let speech = scratch.appendingPathComponent("speech.aiff")
        let said = try await Shell.run("/usr/bin/say", ["-v", "Samantha", "-o", speech.path,
            "Hello and welcome to the channel. [[slnc 900]] Um, [[slnc 200]] the first step is recording. [[slnc 1200]] I think we, I think we should start."])
        let spokenMovie = scratch.appendingPathComponent("spoken.mov")
        let muxed = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                                                 "-i", speech.path, "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", spokenMovie.path])
        if said.status == 0, muxed.status == 0 {
            let spokenInfo = try await FFmpeg.probe(url: spokenMovie)
            var spokenItem = VideoItem(url: spokenMovie); spokenItem.info = spokenInfo; spokenItem.crop = spokenInfo.fullFrame; spokenItem.status = .ready
            let whisperEditor = AppModel(recoveryURL: nil)
            whisperEditor.restore(VideoProject(clips: [ProjectClip(spokenItem)], settings: ExportSettings(), selection: spokenItem.id))
            var real = address(whisperEditor)
            real["method"] = "transcribe"; real["requestID"] = "whisper-1"; real["client"] = "Claude"; real["clip"] = spokenItem.id.uuidString; real["model"] = "base.en"
            let started = Date()
            let realJob = try await waitForJob(whisperEditor, agentResult(await agentCall(whisperEditor, real))["id"] as? String ?? "")
            let heard = whisperEditor.items[0].transcript
            check(realJob["status"] as? String == "succeeded" && (heard?.text.lowercased().contains("welcome to the channel") ?? false)
                      && heard?.words.allSatisfy({ $0.start <= spokenInfo.duration && $0.end >= $0.start }) == true,
                  "whisper.cpp transcribes the recording word by word (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)",
                  "\(realJob) \(heard?.text ?? "")")
            let heardStumbles = StumbleFinder.stumbles(in: heard?.words ?? [])
            check(heardStumbles.contains { $0.kind == .filler } && heardStumbles.contains { $0.kind == .restart },
                  "and the um and the restart are found in what it heard", "\(heardStumbles.map(\.label))")
            equal(whisperEditor.undoTitle, "Undo Transcribe (Claude)", "the words land as one undo step")
            let welcome = heard?.words.first { $0.text.lowercased().hasPrefix("welcome") }?.start ?? -1
            check(welcome > 0.4 && welcome < 1.2, "word times are close to the speech", "welcome at \(welcome)")
        } else {
            check(false, "made a spoken recording with say", said.stderrText + muxed.stderrText)
        }
    } else {
        print("  skip transcribing: no whisper-cli or base.en model (download it in Auto Edit)")
    }

}
