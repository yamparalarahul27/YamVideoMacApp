// Checks for publish. Run with ./test.sh publish
import AppKit
import AVFoundation
import Foundation

@MainActor func publishTests() async throws {
    // MARK: - Publishing

    print("\nPublish details")
    var publishing = PublishInfo()
    publishing.tags = ["video editing", "macOS"]
    equal(publishing.tagCharacters, 21, "tags count as YouTube counts them: quotes around a phrase, commas between")
    check(publishing.issues(duration: 120).contains { $0.field == "title" && $0.severity == .blocking }, "a video needs a title")
    publishing.title = String(repeating: "a", count: 101)
    check(publishing.issues(duration: 120).contains { $0.message.contains("100") && $0.severity == .blocking }, "a title over 100 characters is refused")
    publishing.title = "How I edit"; publishing.description = "Use <b>bold</b>"
    check(publishing.issues(duration: 120).contains { $0.field == "description" && $0.severity == .blocking }, "YouTube's banned < and > are caught")
    publishing.description = "A walk through my edit."
    publishing.tags = (0..<60).map { "tag number \($0)" }
    check(publishing.issues(duration: 120).contains { $0.field == "tags" && $0.severity == .blocking }, "tags over 500 characters are refused")
    publishing.tags = ["video editing"]
    publishing.chapters = [Chapter(time: 5, title: "Start"), Chapter(time: 30, title: "Middle"), Chapter(time: 60, title: "End")]
    check(publishing.chapterProblem(duration: 120)?.contains("0:00") == true, "chapters must start at 0:00")
    publishing.chapters = [Chapter(time: 0, title: "Intro"), Chapter(time: 30, title: "Middle")]
    check(publishing.chapterProblem(duration: 120)?.contains("at least 3") == true, "YouTube needs three chapters")
    publishing.chapters = [Chapter(time: 0, title: "Intro"), Chapter(time: 30, title: "Middle"), Chapter(time: 35, title: "Short")]
    check(publishing.chapterProblem(duration: 120)?.contains("0:30") == true, "a chapter shorter than ten seconds is named")
    publishing.chapters = [Chapter(time: 0, title: "Intro"), Chapter(time: 65, title: "Setup"), Chapter(time: 3723, title: "Late")]
    check(publishing.chapterProblem(duration: 4000) == nil, "good chapters pass")
    equal(publishing.fullDescription, "A walk through my edit.\n\n0:00 Intro\n1:05 Setup\n1:02:03 Late", "the description carries the chapters as YouTube reads them")
    check(PublishInfo.seconds(fromTimestamp: "1:05") == 65 && PublishInfo.seconds(fromTimestamp: "1:02:03") == 3723
              && PublishInfo.seconds(fromTimestamp: "42") == 42 && PublishInfo.seconds(fromTimestamp: "1:x") == nil, "chapter times read as YouTube writes them")
    check(publishing.issues(duration: 4000).contains { $0.field == "thumbnail" && $0.severity == .warning }, "no thumbnail is only a warning")
    publishing.thumbnail = scratch.appendingPathComponent("gone.png")
    check(publishing.issues(duration: 4000).contains { $0.field == "thumbnail" && $0.severity == .blocking }, "a missing thumbnail file is refused")
    equal(PublishInfo.fileStem("How I edit: part 1/2?", fallback: "x"), "How I edit part 1 2", "file names come from the title, safely")
    check(publishing.uploadText(files: ["a.mp4"]).contains("TITLE\nHow I edit") && publishing.uploadText(files: []).contains("Science & Technology (28)"),
          "the upload text has every field, with the category's number")

    let suggestionTrack = GraphicsTrack(items: [
        Graphic(kind: .panelTitle, start: 30, end: 33, props: ["title": .string("Three rules")]),
        Graphic(kind: .rule, start: 40, end: 44, props: ["title": .string("Cut the pauses"), "number": .number(1)]),
        Graphic(kind: .checklist, start: 45, end: 48, props: ["title": .string("Checklist")]),
        Graphic(kind: .namePlate, start: 1, end: 4, props: ["title": .string("Not a chapter")]),
    ])
    let suggested = PublishInfo.suggestedChapters(markers: [TimelineMarker(time: 15, label: "Setup"), TimelineMarker(time: 20, label: "")],
                                                  graphics: suggestionTrack, duration: 120)
    equal(suggested.map(\.title), ["Intro", "Setup", "Three rules", "1. Cut the pauses"],
          "chapters come from named markers and panel graphics, ten seconds apart, after an Intro")
    let earlyFirst = PublishInfo.suggestedChapters(markers: [TimelineMarker(time: 4, label: "Hello"), TimelineMarker(time: 30, label: "Next")],
                                                   graphics: nil, duration: 60)
    check(earlyFirst.first?.time == 0 && earlyFirst.first?.title == "Hello", "a chapter in the first ten seconds starts at 0:00")

    print("\nPublish details in projects")
    let publisher = AppModel(recoveryURL: nil)
    publisher.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    let publishClip = gradeOther.id
    let publishDuration = publisher.items[0].editedDuration
    var draft = PublishInfo(); draft.title = "Grade test"
    draft.chapters = [Chapter(time: 0, title: "Intro"), Chapter(time: publishDuration * 0.5, title: "Middle")]
    check(publisher.perform([.setPublishInfo(clip: publishClip, info: draft)]).isSuccess && publisher.items[0].publish?.title == "Grade test"
              && publisher.undoTitle == "Undo Publish Details", "a recording keeps its publish details as one undo step")
    var lateChapter = draft; lateChapter.chapters.append(Chapter(time: publishDuration + 5, title: "After"))
    check(publisher.perform([.setPublishInfo(clip: publishClip, info: lateChapter)]).isFailure, "a chapter after the end is refused")
    var twoLines = draft; twoLines.title = "One\nTwo"
    check(publisher.perform([.setPublishInfo(clip: publishClip, info: twoLines)]).isFailure, "a title is one line")
    let publishSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(publisher.project))
    check(publishSaved == publisher.project && publishSaved.version == VideoProject.currentVersion, "publish details survive a project round trip")
    var publishAsSeven = publishSaved; publishAsSeven.version = 7
    check((try? publishAsSeven.validate()) == nil, "a version 7 file with publish details is refused")
    let publishSection = publisher.items[0].timeline.segments[0].id
    check(publisher.perform([.trimSection(clip: publishClip, section: publishSection, start: 0.2, end: nil)]).isSuccess, "trim the start")
    let trimmedChapters = publisher.items[0].publish?.chapters ?? []
    check(trimmedChapters.first?.time == 0 && abs((trimmedChapters.last?.time ?? 0) - (publishDuration * 0.5 - 0.2)) < 0.05,
          "chapters follow their footage through a cut; the first stays at 0:00", "\(trimmedChapters.map(\.time))")
    check(publisher.perform([.setPublishInfo(clip: publishClip, info: PublishInfo())]).isSuccess && publisher.items[0].publish == nil,
          "empty publish details are stored as nothing")

    print("\nCaptions on the edited timeline")
    let captionText = """
    WEBVTT

    00:00.000 --> 00:00.800
    FIRST

    00:02.200 --> 00:02.900 align:start
    SECOND
    """
    let parsedCaptions = try Captions.parse(captionText)
    check(parsedCaptions == [Caption(start: 0, end: 0.8, text: "FIRST"), Caption(start: 2.2, end: 2.9, text: "SECOND")], "WebVTT cues are read")
    check(try Captions.parse(Captions.srt(parsedCaptions)) == parsedCaptions, "an SRT written out reads back the same")
    let cutTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.9), TimelineSegment(start: 2.1, end: 3.0)])
    let shiftedCaptions = Captions.edited(parsedCaptions, timeline: cutTimeline)
    check(shiftedCaptions.count == 2 && abs(shiftedCaptions[1].start - 1.0) < 0.0001 && abs(shiftedCaptions[1].end - 1.7) < 0.0001,
          "a caption after a cut moves earlier with its footage", "\(shiftedCaptions)")
    let reorderedCaptions = Captions.edited(parsedCaptions, timeline: ClipTimeline(segments: [TimelineSegment(start: 2.0, end: 3.0, speed: 2),
                                                                                       TimelineSegment(start: 0, end: 1.0)]))
    check(reorderedCaptions.count == 2 && reorderedCaptions[0].text == "SECOND" && abs(reorderedCaptions[0].start - 0.1) < 0.0001 && abs(reorderedCaptions[0].end - 0.45) < 0.0001
              && abs(reorderedCaptions[1].start - 0.5) < 0.0001, "captions follow reordered and sped-up sections", "\(reorderedCaptions)")
    let split = Captions.edited([Caption(start: 0.5, end: 1.5, text: "ACROSS")],
                                timeline: ClipTimeline(segments: [TimelineSegment(start: 0, end: 1.0), TimelineSegment(start: 1.0, end: 2.0)]))
    check(split == [Caption(start: 0.5, end: 1.5, text: "ACROSS")], "a caption split by a cut that lands back to back stays one")

    let driftCaptions = scratch.appendingPathComponent("drift.srt")
    try Captions.srt(parsedCaptions).write(to: driftCaptions, atomically: true, encoding: .utf8)
    let driftSegments = [TimelineSegment(start: 0, end: 0.9), TimelineSegment(start: 2.1, end: 3.0)]
    let driftArgs = FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("drift.mp4"), info: info,
                                           crop: info.fullFrame, segments: driftSegments, settings: ExportSettings(), subtitles: driftCaptions)
    let burnedPath = driftArgs.joined(separator: " ").components(separatedBy: "subtitles=").last?.components(separatedBy: ":force_style").first ?? ""
    check(burnedPath.contains("yamvideo-subs-edited") && (try? String(contentsOfFile: burnedPath, encoding: .utf8))?.contains("00:00:01,000 --> 00:00:01,700") == true,
          "a cut recording burns its captions timed on the edited video", burnedPath)
    if await FFmpeg.supportsSubtitles() {
        let withCaptions = scratch.appendingPathComponent("drift-captions.mp4"), withoutCaptions = scratch.appendingPathComponent("drift-plain.mp4")
        try await FFmpeg.export(input: landscape, output: withCaptions, info: info, crop: info.fullFrame, segments: driftSegments,
                                settings: ExportSettings(), subtitles: driftCaptions) { _ in }
        try await FFmpeg.export(input: landscape, output: withoutCaptions, info: info, crop: info.fullFrame, segments: driftSegments,
                                settings: ExportSettings()) { _ in }
        func lowerThird(_ url: URL, at time: Double) async throws -> [UInt8] {
            let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-i", url.path,
                                                      "-frames:v", "1", "-vf", "crop=1280:180:0:540", "-f", "rawvideo", "-pix_fmt", "gray", "-"])
            return [UInt8](result.stdout)
        }
        func captionDelta(_ time: Double) async throws -> Double {
            let a = try await lowerThird(withCaptions, at: time), b = try await lowerThird(withoutCaptions, at: time)
            guard a.count == b.count, !a.isEmpty else { return 0 }
            return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        let during = try await captionDelta(1.3), between = try await captionDelta(0.87)
        check(during > 1 && between < during / 4, "the second caption shows when its footage plays after the cut, not at its source time",
              String(format: "during %.2f, between %.2f", during, between))
    }

    print("\nExport for YouTube")
    let fourByThree = scratch.appendingPathComponent("thumb-source.png")
    let thumbMade = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=2048x1536",
                                                 "-frames:v", "1", fourByThree.path])
    check(thumbMade.status == 0, "made a 4:3 thumbnail source")
    let thumbOut = scratch.appendingPathComponent("thumb.jpg")
    try YouTubeExport.writeThumbnail(fourByThree, to: thumbOut)
    let thumbInfo = try await FFmpeg.probe(url: thumbOut)
    let thumbBytes = (try FileManager.default.attributesOfItem(atPath: thumbOut.path)[.size] as? NSNumber)?.intValue ?? .max
    check(thumbInfo.width == 1280 && thumbInfo.height == 720 && thumbBytes < PublishInfo.thumbnailBytes,
          "a thumbnail becomes a 1280×720 JPEG under 2 MB", "\(thumbInfo.width)×\(thumbInfo.height), \(thumbBytes) bytes")

    var youtubeItem = VideoItem(url: landscape)
    youtubeItem.info = info; youtubeItem.crop = info.fullFrame
    youtubeItem.segments = driftSegments
    youtubeItem.subtitles = driftCaptions
    var youtubeInfo = PublishInfo()
    youtubeInfo.title = "Drift test: captions/cuts"; youtubeInfo.description = "Checking the files."; youtubeInfo.tags = ["test"]
    youtubeInfo.thumbnail = fourByThree
    youtubeItem.publish = youtubeInfo
    let youtubeFolder = scratch.appendingPathComponent("youtube", isDirectory: true)
    try FileManager.default.createDirectory(at: youtubeFolder, withIntermediateDirectories: true)
    let youtubeFiles = YouTubeExport.files(in: youtubeFolder, publish: youtubeInfo, fallback: "landscape", captions: true, unique: true)
    var gifSettings = ExportSettings(); gifSettings.format = .gif
    try await YouTubeExport.run(youtubeItem, info: info, publish: youtubeInfo, settings: gifSettings, files: youtubeFiles) { _ in }
    check(youtubeFiles.video.lastPathComponent == "Drift test captions cuts.mp4" && FileManager.default.fileExists(atPath: youtubeFiles.video.path),
          "the video is an MP4 named after the title, whatever the export format", youtubeFiles.video.lastPathComponent)
    check(try await FFmpeg.probe(url: youtubeFiles.video).videoCodec == "h264", "and it is H.264")
    let uploadedCaptions = (try? String(contentsOf: youtubeFiles.captions!, encoding: .utf8)) ?? ""
    check(youtubeFiles.captions?.lastPathComponent == "Drift test captions cuts.en.srt" && uploadedCaptions.contains("00:00:01,000 --> 00:00:01,700"),
          "the captions go up as an SRT on the edited timeline, named with their language", uploadedCaptions)
    check(FileManager.default.fileExists(atPath: youtubeFiles.thumbnail!.path), "the thumbnail is written")
    let uploadText = (try? String(contentsOf: youtubeFiles.text, encoding: .utf8)) ?? ""
    check(uploadText.contains("TITLE\nDrift test: captions/cuts") && uploadText.contains("Drift test captions cuts.mp4"), "the upload text lists the fields and the files")
    let uploadJSON = (try? JSONSerialization.jsonObject(with: Data(contentsOf: youtubeFiles.json)) as? [String: Any]) ?? [:]
    check((uploadJSON["category"] as? [String: Any])?["id"] as? Double == 28 && (uploadJSON["files"] as? [String: Any])?["captions"] != nil,
          "the JSON carries the same for an agent", "\(uploadJSON)")
    check(!((try? FileManager.default.contentsOfDirectory(atPath: youtubeFolder.path)) ?? []).contains { $0.hasPrefix(".yamvideo-") },
          "no temporary file is left behind")
    var untitled = youtubeInfo; untitled.title = ""
    do {
        try await YouTubeExport.run(youtubeItem, info: info, publish: untitled, settings: ExportSettings(), files: youtubeFiles) { _ in }
        check(false, "a YouTube export without a title is refused")
    } catch {
        check(error.localizedDescription.contains("title"), "a YouTube export without a title is refused", error.localizedDescription)
    }

    print("\nPublishing for agents")
    let publishAgent = AppModel(recoveryURL: nil)
    var agentYouTubeItem = youtubeItem; agentYouTubeItem.publish = nil
    publishAgent.restore(VideoProject(clips: [ProjectClip(agentYouTubeItem)], settings: ExportSettings(), selection: agentYouTubeItem.id))
    var setPublish = address(publishAgent)
    setPublish["method"] = "apply"; setPublish["requestID"] = "publish-1"; setPublish["client"] = "Claude"
    setPublish["commands"] = [["type": "setPublishInfo", "clipID": agentYouTubeItem.id.uuidString,
                               "publish": ["title": "Agent title", "tags": ["one", "two words"], "category": "education",
                                           "chapters": [["time": 0, "title": "Intro"]], "thumbnail": thumbOut.path]]]
    let setReply = await agentCall(publishAgent, setPublish)
    check(setReply["ok"] as? Bool == true && publishAgent.items[0].publish?.category == .education
              && publishAgent.items[0].publish?.thumbnail?.path == thumbOut.path, "an agent writes the publish details", "\(setReply)")
    var patchPublish = address(publishAgent)
    patchPublish["method"] = "apply"; patchPublish["requestID"] = "publish-2"; patchPublish["client"] = "Claude"
    patchPublish["commands"] = [["type": "setPublishInfo", "clipID": agentYouTubeItem.id.uuidString, "publish": ["description": "Now with words."]]]
    _ = await agentCall(publishAgent, patchPublish)
    check(publishAgent.items[0].publish?.title == "Agent title" && publishAgent.items[0].publish?.description == "Now with words.",
          "keys an agent leaves out keep their values")
    var badPublish = address(publishAgent)
    badPublish["method"] = "apply"; badPublish["requestID"] = "publish-3"
    badPublish["commands"] = [["type": "setPublishInfo", "clipID": agentYouTubeItem.id.uuidString, "publish": ["category": "cooking"]]]
    let badPublishReply = await agentCall(publishAgent, badPublish)
    check(((badPublishReply["error"] as? [String: Any])?["message"] as? String ?? "").contains("scienceTechnology"),
          "an unknown category is refused with the list", "\(badPublishReply)")
    badPublish["requestID"] = "publish-4"
    badPublish["commands"] = [["type": "setPublishInfo", "clipID": agentYouTubeItem.id.uuidString, "publish": ["thumbnail": "/nowhere/thumb.png"]]]
    equal(agentError(await agentCall(publishAgent, badPublish)), "missing_media", "a missing thumbnail is refused as missing media")
    let publishState = (agentResult(await agentCall(publishAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first ?? [:]
    check((publishState["publish"] as? [String: Any])?["thumbnail"] as? String == thumbOut.path
              && (publishState["publishIssues"] as? [[String: Any]])?.contains { ($0["message"] as? String ?? "").contains("at least 3") } == true
              && publishState["suggestedChapters"] is [Any],
          "state shows the details as plain paths, their issues and suggested chapters", "\(publishState["publishIssues"] ?? "")")
    var youtubeExport = address(publishAgent)
    youtubeExport["method"] = "export"; youtubeExport["requestID"] = "publish-export-1"; youtubeExport["client"] = "Claude"
    youtubeExport["youtube"] = true; youtubeExport["clip"] = agentYouTubeItem.id.uuidString; youtubeExport["scope"] = "recording"
    youtubeExport["path"] = scratch.appendingPathComponent("drift.srt").path
    youtubeExport["expectedRevision"] = publishAgent.revision
    check(agentError(await agentCall(publishAgent, youtubeExport)) == "invalid_command", "a YouTube export needs a folder")
    let agentFolder = scratch.appendingPathComponent("agent-youtube", isDirectory: true)
    try FileManager.default.createDirectory(at: agentFolder, withIntermediateDirectories: true)
    youtubeExport["path"] = agentFolder.path; youtubeExport["requestID"] = "publish-export-2"
    let youtubeJob = agentResult(await agentCall(publishAgent, youtubeExport))
    let youtubeDone = try await waitForJob(publishAgent, youtubeJob["id"] as? String ?? "")
    let youtubeResult = youtubeDone["result"] as? [String: Any] ?? [:]
    check(youtubeDone["status"] as? String == "succeeded" && (youtubeResult["captions"] as? String)?.hasSuffix("Agent title.en.srt") == true
              && FileManager.default.fileExists(atPath: youtubeResult["thumbnail"] as? String ?? ""),
          "an agent exports for YouTube and gets every file's path", "\(youtubeDone)")

}
