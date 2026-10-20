// Checks for endscreen. Run with ./test.sh endscreen
import AppKit
import AVFoundation
import Foundation

@MainActor func endscreenTests() async throws {
    // MARK: - End screen

    print("\nEnd screen layout")
    let twoLeft = EndScreenLayout(videos: 2, side: .left)
    check(twoLeft.frame == CGRect(x: 96, y: 56, width: 960, height: 540) && twoLeft.scale == 0.5 && twoLeft.cards.count == 2
              && twoLeft.cards.allSatisfy { $0.minX > 1100 },
          "two video cards sit on the right, the speaker at half size on the left", "\(twoLeft)")
    let allBoxes = [twoLeft.frame, twoLeft.circle, twoLeft.text] + twoLeft.cards
    check(allBoxes.allSatisfy { CGRect(x: 0, y: 0, width: 1920, height: 1080).insetBy(dx: 80, dy: 40).contains($0.insetBy(dx: -EndScreen.margin, dy: -EndScreen.margin)) }
              && !allBoxes.enumerated().contains { i, a in allBoxes.enumerated().contains { j, b in i < j && a.insetBy(dx: -EndScreen.margin, dy: -EndScreen.margin).intersects(b) } },
          "the frame, the boxes and the text stay inside the picture and clear of each other")
    check(abs(twoLeft.cards[0].width / twoLeft.cards[0].height - 16.0 / 9) < 0.01 && twoLeft.circle.width == twoLeft.circle.height
              && twoLeft.cards[0].width == 615 && twoLeft.circle.width == 296,
          "the boxes are YouTube's elements: a 16:9 video card about 615 px wide and a 296 px circle")
    // Studio pushes an element that reaches past its element area back inside, off its box.
    let elementBoxes = [(2, EndScreenLayout.Side.left), (1, .left), (2, .right), (1, .right)].flatMap { videos, side -> [CGRect] in
        let layout = EndScreenLayout(videos: videos, side: side)
        return [layout.circle] + layout.cards
    }
    check(elementBoxes.allSatisfy { EndScreen.elementArea.insetBy(dx: 8, dy: 8).contains($0) },
          "every element box is inside YouTube's element area, with room to spare", "\(elementBoxes.filter { !EndScreen.elementArea.insetBy(dx: 8, dy: 8).contains($0) })")
    let oneRight = EndScreenLayout(props: ["videos": .number(1), "side": .string("right")])
    check(oneRight.cards.count == 1 && oneRight.cards[0].maxX < 800 && oneRight.frame.minX == 864 && oneRight.circle.maxX == 1824,
          "one video card, mirrored when the speaker sits on the right", "\(oneRight)")
    check(EndScreenLayout.problem(props: ["videos": .number(3)])?.contains("1 or 2") == true
              && EndScreenLayout.problem(props: ["side": .string("top")])?.contains("left") == true,
          "an end screen's props out of range are refused, saying what is allowed")
    if let nodeBinary {
        let script = "const g=require(process.argv[1]);console.log(JSON.stringify([[2,'left'],[1,'left'],[2,'right'],[1,'right']]"
            + ".map(([v,s])=>{const l=g.endLayout({videos:v,side:s});return [l.frame].concat([l.circle,l.text],l.cards).map(r=>[r.x,r.y,r.w,r.h])})))"
        let engine = try await Shell.run(nodeBinary, ["-e", script, "\(repository)/Resources/Graphics/graphics.js"])
        let swift = [(2, EndScreenLayout.Side.left), (1, .left), (2, .right), (1, .right)].map { videos, side -> [[Int]] in
            let layout = EndScreenLayout(videos: videos, side: side)
            return ([layout.frame, layout.circle, layout.text] + layout.cards).map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] }
        }
        let swiftJSON = String(decoding: try JSONEncoder().encode(swift), as: UTF8.self)
        equal(engine.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), swiftJSON, "the engine lays out the end screen as the app does")
    }

    print("\nEnd screen rules")
    let screenGraphic = gfx(.endScreen, 40, 60, EndScreen.defaultProps)
    check(GraphicsTrack(items: [screenGraphic]).problem(duration: 60) == nil, "an end screen over the last 20 s is fine")
    check(GraphicsTrack(items: [gfx(.endScreen, 40, 58, EndScreen.defaultProps)]).problem(duration: 60)?.contains("end where the video ends") == true,
          "an end screen must end where the video ends")
    check(GraphicsTrack(items: [gfx(.endScreen, 56, 60)]).problem(duration: 60)?.contains("5 to 20 seconds") == true
              && GraphicsTrack(items: [gfx(.endScreen, 39, 60)]).problem(duration: 60)?.contains("5 to 20 seconds") == true,
          "YouTube's window is 5 to 20 seconds, and the refusal says so")
    check(GraphicsTrack(items: [screenGraphic, gfx(.endScreen, 45, 60)]).problem(duration: 60) != nil, "a video has one end screen")
    check(GraphicsTrack(items: [gfx(.namePlate, 38, 42), screenGraphic]).problem(duration: 60)?.contains("still showing") == true,
          "nothing else may show over the end screen")
    check(GraphicsTrack(items: [gfx(.rule, 30, 39.5), screenGraphic]).problem(duration: 60)?.contains("slid away") == true
              && GraphicsTrack(items: [gfx(.rule, 30, 39.2), screenGraphic]).problem(duration: 60) == nil,
          "a panel must have slid away before the end screen starts")
    var movedScreen = screenGraphic; movedScreen.transform = GraphicTransform(x: 10)
    check(GraphicsTrack(items: [movedScreen]).problem(duration: 60)?.contains("cannot be moved") == true && !GraphicKind.endScreen.isPlaceable,
          "the end screen cannot be moved or resized on the picture")
    check(GraphicsTrack().newEndScreenSpan(duration: 60).map { $0 == (40, 60) } == true
              && GraphicsTrack(items: [gfx(.namePlate, 50, 52)]).newEndScreenSpan(duration: 60).map { $0 == (52, 60) } == true
              && GraphicsTrack(items: [gfx(.rule, 50, 55.5)]).newEndScreenSpan(duration: 60) == nil
              && GraphicsTrack().newEndScreenSpan(duration: 4) == nil,
          "a new end screen takes the last 20 s, or as much as is clear, and needs 5 s")

    // Through cuts the end screen stays on the last seconds.
    let longTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 60)])
    let screenTrack = GraphicsTrack(items: [gfx(.namePlate, 10, 14), gfx(.namePlate, 30, 35), screenGraphic])
    let cutMiddle = ClipTimeline(segments: [TimelineSegment(start: 0, end: 20), TimelineSegment(start: 25, end: 60)])
    let afterMiddle = cutMiddle.remap(screenTrack, from: longTimeline)
    let middleScreen = afterMiddle.track.endScreen
    check(middleScreen.map { abs($0.start - 35) < 0.001 && abs($0.end - 55) < 0.001 } == true && afterMiddle.track.problem(duration: 55) == nil,
          "a cut before the end screen moves it with the end", "\(String(describing: middleScreen))")
    let cutTail = ClipTimeline(segments: [TimelineSegment(start: 0, end: 50), TimelineSegment(start: 58, end: 60)])
    let afterTail = cutTail.remap(screenTrack, from: longTimeline)
    check(afterTail.track.endScreen.map { abs($0.start - 35) < 0.001 && abs($0.end - 52) < 0.001 } == true
              && afterTail.track.problem(duration: 52) == nil && afterTail.removed.isEmpty,
          "a cut inside it keeps it on the end, shortened to clear the graphic before it", "\(String(describing: afterTail.track.endScreen))")
    let cutShort = ClipTimeline(segments: [TimelineSegment(start: 0, end: 37)])
    let afterShort = cutShort.remap(screenTrack, from: longTimeline)
    check(afterShort.track.endScreen == nil && afterShort.removed.contains(screenGraphic.id),
          "an end screen without 5 clear seconds left is dropped and reported")

    let screenMotion = GraphicsMotion(GraphicsTrack(style: { var style = GraphicsStyle(); style.moveVideo = false; return style }(), items: [screenGraphic]))
    check(screenMotion?.screenProgress(at: 39.9) == 0 && abs((screenMotion?.screenProgress(at: 40.4) ?? 0) - 0.5) < 0.0001
              && screenMotion?.screenProgress(at: 40.8) == 1 && screenMotion?.screenProgress(at: 59.99) == 1 && screenMotion?.spans.isEmpty == true,
          "the speaker moves into the frame over 0.8 s and stays, whatever the panel style")
    check(screenMotion.map { $0.screenPlacement(amount: 1, size: CGSize(width: 1280, height: 720)) == (64, 37, 640, 360)
                             && $0.screenPlacement(amount: 0, size: CGSize(width: 1280, height: 720)) == (0, 0, 1280, 720) } == true,
          "in whole pixels: the end screen's frame, scaled to the picture")

    print("\nEnd screen parity")
    let screenClip = scratch.appendingPathComponent("screen.mov")
    let screenEncode = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
        "-t", "7", "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
        "-c:v", "prores_ks", "-profile:v", "4444", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-colorspace", "bt709", "-color_range", "tv", screenClip.path])
    check(screenEncode.status == 0, "made a 7 s textured clip", screenEncode.stderrText)
    let screenInfo = try await FFmpeg.probe(url: screenClip)
    let paritySpan = (start: 1.5, end: screenInfo.duration)
    let parityTrack = GraphicsTrack(items: [gfx(.rule, 0.1, 0.65), gfx(.endScreen, paritySpan.start, paritySpan.end, EndScreen.defaultProps)])
    check(parityTrack.problem(duration: screenInfo.duration) == nil, "a panel, then an end screen to the end", parityTrack.problem(duration: screenInfo.duration) ?? "")
    let parityMotion = GraphicsMotion(parityTrack)!
    var screenItem = VideoItem(url: screenClip)
    screenItem.info = screenInfo; screenItem.crop = screenInfo.fullFrame; screenItem.graphics = parityTrack
    let screenStage = try FFmpeg.moveStage(parityMotion, frame: CGSize(width: 1280, height: 720), fps: 30, fpsExpression: "30",
                                           duration: screenInfo.duration, tags: FrameTags(info: screenInfo, converted: false))
    let screenGraph = screenStage.parts.joined(separator: ";").replacingOccurrences(of: "[mvin]", with: "[0:v]")
    var screenWorst = (offset: 0, inside: 0.0, whole: 0.0)
    for frame in [47, 52, 58, 66, 90, 200] {
        let native = try await nativePicture(screenItem, frame: frame)
        let exported = try await ffmpegPicture(screenClip, graph: screenGraph, frame: frame, width: 1280, height: 720)
        let place = parityMotion.screenPlacement(amount: parityMotion.screenProgress(at: Double(frame) / 30), size: CGSize(width: 1280, height: 720))
        var best = (dx: 0, dy: 0, mean: Double.infinity)
        for dx in -3...3 { for dy in -3...3 {
            var total = 0.0, count = 0
            for y in stride(from: place.y + 8, to: place.y + place.height - 8, by: 4) { for x in stride(from: place.x + 8, to: place.x + place.width - 8, by: 4) {
                for channel in 0..<3 { total += abs(native.at(x, y, channel) - exported.at(x + dx, y + dy, channel)) }; count += 3
            } }
            if total / Double(count) < best.mean { best = (dx, dy, total / Double(count)) }
        } }
        screenWorst.offset = max(screenWorst.offset, abs(best.dx), abs(best.dy))
        screenWorst.inside = max(screenWorst.inside, best.mean)
        screenWorst.whole = max(screenWorst.whole, meanDifference(native, exported, xs: 4..<1276))
    }
    print(String(format: "       end screen parity: worst offset %d px, picture %.2f, whole frame %.2f of 255", screenWorst.offset, screenWorst.inside, screenWorst.whole))
    check(screenWorst.offset <= 2, "the exported speaker frame lands within 2 px of the preview, during the move and after")
    check(screenWorst.inside < 4 && screenWorst.whole < 3, "the scaled picture and the blurred fill match the preview",
          String(format: "picture %.2f, frame %.2f", screenWorst.inside, screenWorst.whole))
    let screenFill = try await nativePicture(screenItem, frame: 150)
    let screenSource = try await ffmpegPicture(screenClip, graph: nil, frame: 150, width: 1280, height: 720)
    check(meanDifference(screenFill, screenSource, xs: 700..<1270) > 20, "beside the frame is the blurred, darker fill, not the picture")
    // Frame 45 is the end screen's first, at 1.5 s, before the picture has begun to move.
    let beforeScreen = try await ffmpegPicture(screenClip, graph: screenGraph, frame: 45, width: 1280, height: 720)
    let beforeSource = try await ffmpegPicture(screenClip, graph: "[0:v]format=yuv420p10le[mvout]", frame: 45, width: 1280, height: 720)
    check(meanDifference(beforeScreen, beforeSource, xs: 0..<1280) < 0.05, "until the move begins the picture is left alone",
          String(format: "%.3f", meanDifference(beforeScreen, beforeSource, xs: 0..<1280)))
    let screenOut = scratch.appendingPathComponent("end-screen.mp4")
    try await FFmpeg.export(input: screenClip, output: screenOut, info: screenInfo, crop: screenInfo.fullFrame, settings: bestQuality,
                            graphics: parityTrack, drawGraphics: { job, page, frames in
                                try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
                                let clear = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                    "-i", "color=c=black@0.0:s=1920x1080,format=rgba", "-frames:v", "1", frames.appendingPathComponent("frame_000001.png").path])
                                if clear.status != 0 { throw FFmpegError(message: clear.stderrText) }
                            }) { _ in }
    let screenNative = try await nativePicture(screenItem, frame: 120)
    let screenExport = try await ffmpegPicture(screenOut, graph: nil, frame: 120, width: 1280, height: 720)
    check(meanDifference(screenNative, screenExport, xs: 70..<700) < 6, "an exported MP4 shows the speaker in the frame as the preview does",
          String(format: "%.2f", meanDifference(screenNative, screenExport, xs: 70..<700)))
    equal(try await frameCount(screenOut), try await frameCount(screenClip), "the end screen keeps every frame")
    let screenTimes = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                                               "-of", "csv=p=0", screenOut.path])
    let frameTimes = screenTimes.stdoutText.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }.sorted()
    check(frameTimes.count > 100 && zip(frameTimes, frameTimes.dropFirst()).allSatisfy { abs($1 - $0 - 1.0 / 30) < 0.002 },
          "every frame keeps its time, through the frame-by-frame move", "\(frameTimes.prefix(60))")

    print("\nEnd screen drawing")
    let blackFrame = CGImage.blank(width: 1280, height: 720)  // a plain grey-blue picture
    let drawnScreen = try await GraphicsSnapshot.draw(GraphicsTrack(items: [screenGraphic]).labellingEndScreen(nil), duration: 60, fps: "30",
                                                      time: 50, over: blackFrame)
    let k720 = 1280.0 / 1920
    let borderPixel = rgb(drawnScreen.image, Int(94 * k720), Int(400 * k720))
    let insidePixel = rgb(drawnScreen.image, Int(500 * k720), Int(400 * k720)), blankPixel = rgb(blackFrame, Int(500 * k720), Int(400 * k720))
    let cardEdge = rgb(drawnScreen.image, Int((1209 - 9) * k720), Int(340 * k720))
    check(borderPixel.0 > 180 && abs(insidePixel.0 - blankPixel.0) + abs(insidePixel.1 - blankPixel.1) + abs(insidePixel.2 - blankPixel.2) < 6,
          "a light border frames the speaker, and the picture inside stays clear", "\(borderPixel) \(insidePixel) \(blankPixel)")
    check(cardEdge.0 > 70, "the video card's box is marked", "\(cardEdge)")
    let screenBox = drawnScreen.boxes[screenGraphic.id]
    check(screenBox.map { $0.maxX > (1209 + 615) * k720 && $0.minY < 175 * k720 && $0.maxY > 908 * k720 } == true,
          "the composed drawing reports the end screen's boxes", "\(String(describing: screenBox))")
    let earlyScreen = try await GraphicsSnapshot.draw(GraphicsTrack(items: [screenGraphic]), duration: 60, fps: "30", time: 39.5, over: blackFrame)
    check(earlyScreen.boxes[screenGraphic.id] == nil, "nothing shows before it starts")

    print("\nEnd screen for YouTube")
    var screenChoices = EndScreenElements()
    screenChoices.videos = [EndScreenElements.Video(kind: .video, link: "https://youtu.be/abc123", title: "Part 2"), .init(kind: .recentUpload)]
    var screenPublish = PublishInfo(); screenPublish.title = "With an end screen"; screenPublish.endScreen = screenChoices
    let screenPlan = EndScreenPlan(graphics: GraphicsTrack(items: [screenGraphic]), publish: screenPublish, duration: 60)
    check(screenPlan.map { $0.boxes.map(\.id) == ["subscribe", "video1", "video2"] && $0.boxes[1].element == "video" && $0.boxes[1].link == "https://youtu.be/abc123"
                           && $0.boxes[2].studio == "Video → Most recent upload" && $0.start == 40 } == true,
          "the plan says which element goes in which box", "\(String(describing: screenPlan))")
    let screenText = screenPublish.uploadText(files: ["a.mp4"], endScreen: screenPlan)
    check(screenText.contains("END SCREEN") && screenText.contains("upload API cannot set end screen elements") && screenText.contains("From 0:40 to the end (20 s)")
              && screenText.contains("Subscribe: the circle at the lower left") && screenText.contains("Video → Choose specific video: the card at the upper right")
              && screenText.contains("https://youtu.be/abc123 (Part 2)"),
          "the upload text says each element and where it goes in YouTube Studio", screenText)
    check(!screenPublish.uploadText(files: []).contains("END SCREEN"), "without an end screen the text has no such section")
    let screenFiles = YouTubeExport.files(in: scratch, publish: screenPublish, fallback: "x", captions: false, unique: false)
    let screenJSON = try JSONSerialization.jsonObject(with: try YouTubeExport.json(screenPublish, files: screenFiles, endScreen: screenPlan)) as? [String: Any]
    let screenJSONPart = screenJSON?["endScreen"] as? [String: Any]
    let screenJSONBoxes = screenJSONPart?["boxes"] as? [[String: Any]] ?? []
    check(screenJSONPart?["uploadAPICanSet"] as? Bool == false && screenJSONBoxes.count == 3
              && screenJSONBoxes.allSatisfy { (($0["fraction"] as? [String: Double])?.values.allSatisfy { (0...1).contains($0) }) == true }
              && (screenJSONBoxes[0]["rect"] as? [String: Double])?["width"] == 296,
          "the JSON has the same, with each box in pixels and in fractions of the frame", "\(screenJSONPart ?? [:])")
    let shortIssues = screenPublish.issues(duration: 20, graphics: GraphicsTrack(items: [gfx(.endScreen, 5, 20)]))
    check(shortIssues.contains { $0.field == "endScreen" && $0.severity == .warning && $0.message.contains("25 s") }, "a video under 25 s gets a warning")
    var noLink = screenChoices; noLink.videos[0].link = ""
    var noLinkPublish = screenPublish; noLinkPublish.endScreen = noLink
    check(noLinkPublish.issues(duration: 60, graphics: GraphicsTrack(items: [screenGraphic])).contains { $0.field == "endScreen" && $0.message.contains("no link") }
              && screenPublish.issues(duration: 60).contains { $0.field == "endScreen" && $0.message.contains("no end screen layout") }
              && !screenPublish.issues(duration: 60, graphics: GraphicsTrack(items: [screenGraphic])).contains { $0.severity == .blocking },
          "missing links and choices without a layout are warnings, never blocking")
    let partialChoices = try JSONDecoder().decode(EndScreenElements.self, from: Data(#"{"videos": [{"kind": "playlist"}]}"#.utf8))
    check(partialChoices.circle == .subscribe && partialChoices.video(0).kind == .playlist && partialChoices.video(1).kind == .bestForViewer,
          "partial choices keep the defaults")

    print("\nEnd screens in projects and for agents")
    let screenEditor = AppModel(recoveryURL: nil)
    var longItem = VideoItem(url: screenClip); longItem.info = screenInfo; longItem.crop = screenInfo.fullFrame
    longItem.segments = [TimelineSegment(start: 0, end: screenInfo.duration)]
    screenEditor.restore(VideoProject(clips: [ProjectClip(longItem)], settings: ExportSettings(), selection: longItem.id))
    let landscapeLength = screenEditor.items[0].editedDuration
    var addScreen = address(screenEditor)
    addScreen["method"] = "apply"; addScreen["requestID"] = "screen-1"; addScreen["client"] = "Claude"
    addScreen["commands"] = [["type": "addGraphic", "clipID": longItem.id.uuidString, "graphic": ["kind": "endScreen"]]]
    let addScreenReply = await agentCall(screenEditor, addScreen)
    let addedScreen = screenEditor.items[0].graphics?.endScreen
    check(addScreenReply["ok"] as? Bool == true && addedScreen.map { abs($0.end - landscapeLength) < 0.001 && abs($0.length - min(20, landscapeLength)) < 0.001
                                                                      && $0.props["videos"]?.number == 2 } == true,
          "an agent adds an end screen with just its kind: the last seconds, with the default layout", "\(addScreenReply) \(String(describing: addedScreen))")
    let screenStateClip = (agentResult(await agentCall(screenEditor, ["method": "state"]))["clips"] as? [[String: Any]])?.first ?? [:]
    let screenState = screenStateClip["endScreen"] as? [String: Any]
    check((screenState?["boxes"] as? [[String: Any]])?.count == 3 && screenState?["uploadAPICanSet"] as? Bool == false
              && (screenState?["setIn"] as? String ?? "").contains("YouTube Studio"),
          "state shows the end screen's boxes and that YouTube Studio places them", "\(screenState ?? [:])")
    var chooseScreen = address(screenEditor)
    chooseScreen["method"] = "apply"; chooseScreen["requestID"] = "screen-2"; chooseScreen["client"] = "Claude"
    chooseScreen["commands"] = [["type": "setPublishInfo", "clipID": longItem.id.uuidString,
                                 "publish": ["endScreen": ["videos": [["kind": "video", "link": "https://youtu.be/abc123", "title": "Part 2"], ["kind": "playlist", "link": "https://www.youtube.com/playlist?list=PL1"]]]]]]
    let chooseReply = await agentCall(screenEditor, chooseScreen)
    check(chooseReply["ok"] as? Bool == true && screenEditor.items[0].publish?.endScreen?.video(1).kind == .playlist
              && screenEditor.items[0].publish?.endScreen?.circle == .subscribe,
          "an agent chooses the elements; the keys not given keep their defaults", "\(chooseReply)")
    chooseScreen["requestID"] = "screen-3"; chooseScreen["expectedRevision"] = screenEditor.revision
    chooseScreen["commands"] = [["type": "setPublishInfo", "clipID": longItem.id.uuidString, "publish": ["endScreen": ["circle": "logo"]]]]
    check(agentError(await agentCall(screenEditor, chooseScreen)) == "invalid_command", "an unknown circle element is refused")
    var moveScreen = address(screenEditor)
    moveScreen["method"] = "apply"; moveScreen["requestID"] = "screen-4"; moveScreen["client"] = "Claude"
    moveScreen["commands"] = [["type": "updateGraphic", "clipID": longItem.id.uuidString, "graphicID": addedScreen?.id.uuidString ?? "",
                               "graphic": ["transform": ["x": 40]]]]
    let moveScreenReply = await agentCall(screenEditor, moveScreen)
    check(((moveScreenReply["error"] as? [String: Any])?["message"] as? String ?? "").contains("cannot be moved"), "moving it on the picture is refused", "\(moveScreenReply)")
    moveScreen["requestID"] = "screen-5"
    moveScreen["commands"] = [["type": "updateGraphic", "clipID": longItem.id.uuidString, "graphicID": addedScreen?.id.uuidString ?? "",
                               "graphic": ["start": landscapeLength - 3]]]
    let shortScreenReply = await agentCall(screenEditor, moveScreen)
    check(((shortScreenReply["error"] as? [String: Any])?["message"] as? String ?? "").contains("5 to 20"), "a start leaving under 5 s is refused with the window", "\(shortScreenReply)")
    moveScreen["requestID"] = "screen-6"
    moveScreen["commands"] = [["type": "updateGraphic", "clipID": longItem.id.uuidString, "graphicID": addedScreen?.id.uuidString ?? "",
                               "graphic": ["start": landscapeLength - 6]]]
    let laterReply = await agentCall(screenEditor, moveScreen)
    check(laterReply["ok"] as? Bool == true && screenEditor.items[0].graphics?.endScreen.map { abs($0.length - 6) < 0.001 && abs($0.end - landscapeLength) < 0.001 } == true,
          "moving its start keeps its end at the end of the video", "\(laterReply)")
    let composedScreen = agentResult(await agentCall(screenEditor, ["method": "preview", "clip": longItem.id.uuidString,
                                                                   "time": landscapeLength - 1, "composed": true]))
    check((composedScreen["graphics"] as? [[String: Any]])?.contains { $0["kind"] as? String == "endScreen" } == true,
          "a composed preview draws the end screen and reports its boxes", "\(composedScreen)")
    let screenSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(screenEditor.project))
    check(screenSaved == screenEditor.project && screenSaved.version >= 10, "an end screen and its choices survive a version 10 round trip")
    var screenAsNine = screenSaved; screenAsNine.version = 9
    check((try? screenAsNine.validate()) == nil, "a version 9 file with an end screen is refused")
    screenEditor.selectedGraphicID = nil
    screenEditor.addEndScreen()
    check(screenEditor.items[0].graphics?.items.filter { $0.kind == .endScreen }.count == 1 && screenEditor.selectedGraphicID == addedScreen?.id,
          "End Screen in the app selects the one already there rather than adding another")

}
