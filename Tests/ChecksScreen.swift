// Checks for screen. Run with ./test.sh screen
import AppKit
import AVFoundation
import Foundation

@MainActor func screenTests() async throws {
    let (activityFile, activityClip) = try await activityFixture()
    // MARK: - Screen + speaker

    print("\nScreen layout geometry")
    let ssScreenInfo = MediaInfo(width: 3248, height: 2008, duration: 750, videoCodec: "h264", audioCodec: nil, fps: 60, fpsExpression: "60/1", rotation: 0,
                                 colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    let ssSpeakerInfo = MediaInfo(width: 1920, height: 1080, duration: 531, videoCodec: "hevc", audioCodec: "aac", fps: 29.97, fpsExpression: "30000/1001",
                                  rotation: 0, colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    var ssTrack = ScreenTrack(url: URL(fileURLWithPath: "/tmp/screen.mov"), info: ssScreenInfo, offset: 142.5)
    ssTrack.bubble.face = CGPoint(x: 900, y: 380)
    let ssGeometry = LayoutGeometry(track: ssTrack, crop: ssSpeakerInfo.fullFrame)
    let ssFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    func ssWhole(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0 == $0.rounded() } && Int(rect.width) % 2 == 0 && Int(rect.height) % 2 == 0
    }
    let ssPlaces = ScreenLayout.allCases.flatMap { [ssGeometry.speakerPlace($0).rect] + [ssGeometry.screenPlace($0)?.rect].compactMap { $0 } }
    check(ssPlaces.allSatisfy { ssWhole($0) && ssFrame.contains($0) }, "every place is in whole pixels with even sizes, inside the frame", "\(ssPlaces)")
    let ssBubble = ssGeometry.speakerPlace(.screen)
    check(ssBubble.rect.width == ssBubble.rect.height && ssBubble.radius == ssBubble.rect.width / 2 && ssBubble.rect.width == 324
              && ssBubble.rect.maxX == 1880 && ssBubble.rect.maxY == 1040,
          "the Screen layout's speaker is a circle 30 % of the frame high, 40 px from the bottom-right corner", "\(ssBubble)")
    check(ssGeometry.screenPlace(.screen).map { $0.rect == CGRect(x: 164, y: 48, width: 1592, height: 984) } == true,
          "the screen fits the frame with a 48 px margin", "\(String(describing: ssGeometry.screenPlace(.screen)))")
    let ssSplitSpeaker = ssGeometry.speakerPlace(.split).rect, ssSplitScreen = ssGeometry.screenPlace(.split)!.rect
    check(ssSplitSpeaker.height == ssSplitScreen.height && ssSplitSpeaker.minY == ssSplitScreen.minY && ssSplitSpeaker.maxX + 32 == ssSplitScreen.minX
              && ssSplitSpeaker.minX >= 40 && ssSplitScreen.maxX <= 1880,
          "side by side: the speaker's panel is as tall as the screen beside it, 32 px apart", "\(ssSplitSpeaker) \(ssSplitScreen)")
    check(ssGeometry.screenPlace(.speaker) == nil && ssGeometry.speakerPlace(.speaker).rect == ssFrame, "in Speaker the speaker fills the frame and the screen does not show")
    ssTrack.spans = [LayoutSpan(start: 10, end: 20, layout: .split), LayoutSpan(start: 20, end: 30, layout: .speaker)]
    equal(ssTrack.changes(endScreen: nil).map { "\($0.time) \($0.to.rawValue)" }, ["10.0 split", "20.0 speaker", "30.0 screen"],
          "the layout changes where a span starts or ends, to what then shows")
    var ssAspects = true, ssInside = true
    for step in 0...40 {
        let state = ssTrack.state(at: 9.8 + Double(step) * 0.0125 * 40, geometry: ssGeometry, endScreen: nil)
        let placeAspect = Double(state.speaker.rect.width / state.speaker.rect.height), windowAspect = Double(state.window.width / state.window.height)
        if abs(placeAspect - windowAspect) > 0.02 * placeAspect { ssAspects = false }
        if !CGRect(origin: .zero, size: ssGeometry.frame).contains(state.window) || !ssWhole(state.speaker.rect) { ssInside = false }
    }
    check(ssAspects, "while a change eases, the speaker's window keeps the place's shape: the picture never stretches")
    check(ssInside, "the window stays inside the picture and the place in whole pixels")
    let ssBefore = ssTrack.state(at: 9.99, geometry: ssGeometry, endScreen: nil), ssHalf = ssTrack.state(at: 10.2, geometry: ssGeometry, endScreen: nil)
    let ssAfter = ssTrack.state(at: 10.4, geometry: ssGeometry, endScreen: nil)
    check(ssBefore == ssGeometry.held(.screen) && ssAfter == ssGeometry.held(.split)
              && ssHalf.speaker.rect.width > ssBubble.rect.width && ssHalf.speaker.rect.width < ssSplitSpeaker.width,
          "a change eases over 0.4 s from its moment", "\(ssHalf.speaker)")
    let ssIntoSpeaker = ssTrack.state(at: 20.2, geometry: ssGeometry, endScreen: nil)
    check(ssIntoSpeaker.screen?.rect == ssSplitScreen && ssTrack.state(at: 20.5, geometry: ssGeometry, endScreen: nil).screen == nil,
          "going to Speaker, the screen stays where it was while the speaker grows over it")
    check(ssTrack.state(at: 25, geometry: ssGeometry, endScreen: 24.5) == ssGeometry.held(.speaker)
              && ssTrack.layout(at: 40, endScreen: 35) == .speaker && ssTrack.layout(at: 34, endScreen: 35) == .screen,
          "from the end screen's start the speaker fills the frame, so the end screen moves the speaker")
    let ssChain = ScreenTrack(url: ssTrack.url, info: ssScreenInfo)
    var ssQuick = ssChain; ssQuick.spans = [LayoutSpan(start: 1, end: 1.2, layout: .speaker)]
    let ssMid = ssQuick.state(at: 1.3, geometry: ssGeometry, endScreen: nil)
    check(ssMid.speaker.rect.width < 1920 && ssMid.speaker.rect.width > ssBubble.rect.width,
          "a change that comes while another eases starts from where that one has got to", "\(ssMid.speaker)")

    print("\nScreen recordings in projects")
    let ssTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 100)])
    let ssCut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 15), TimelineSegment(start: 25, end: 100)])
    let ssMoved = ssCut.remap([LayoutSpan(start: 30, end: 40, layout: .split), LayoutSpan(start: 18, end: 22, layout: .speaker)], from: ssTimeline, fps: 30)
    check(ssMoved.count == 1 && abs(ssMoved[0].start - 20) < 0.001 && abs(ssMoved[0].end - 30) < 0.001,
          "a layout follows the frame it starts on; one whose footage is cut away goes", "\(ssMoved)")
    let ssCovered = ScreenTrack(url: ssTrack.url, info: ssScreenInfo, offset: -5).covered(on: ssCut)
    check(ssCovered.count == 1 && abs(ssCovered[0].lowerBound - 5) < 0.001 && abs(ssCovered[0].upperBound - 90) < 0.001,
          "covered: the edited times where the screen file has footage", "\(ssCovered)")
    var ssHDR = ssScreenInfo; ssHDR.colorTransfer = "smpte2084"
    var ssRotated = ssScreenInfo; ssRotated.rotation = 90
    check(ScreenTrack(url: ssTrack.url, info: ssHDR).problem(duration: 100, speaker: ssSpeakerInfo)?.contains("HDR") == true
              && ScreenTrack(url: ssTrack.url, info: ssRotated).problem(duration: 100, speaker: ssSpeakerInfo)?.contains("rotated") == true,
          "an HDR or rotated screen recording is refused, saying why")
    var ssOverlap = ssChain; ssOverlap.spans = [LayoutSpan(start: 1, end: 5, layout: .split), LayoutSpan(start: 4, end: 8, layout: .speaker)]
    var ssLate = ssChain; ssLate.spans = [LayoutSpan(start: 90, end: 120, layout: .split)]
    var ssHuge = ssChain; ssHuge.bubble.size = 0.9
    check(ssOverlap.problem(duration: 100, speaker: ssSpeakerInfo)?.contains("overlaps") == true
              && ssLate.problem(duration: 100, speaker: ssSpeakerInfo)?.contains("within the edited recording") == true
              && ssHuge.problem(duration: 100, speaker: ssSpeakerInfo)?.contains("size") == true,
          "overlapping layouts, a layout past the end and an oversized bubble are refused")

    // A 6 s textured speaker with sound, and a 9 s screen recording of another pattern and size.
    func ssClip(_ name: String, _ source: String, seconds: Double, audio: Bool) async throws -> URL {
        let url = scratch.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", source]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:a", "aac"] }
        args += ["-t", String(seconds), "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
                 "-c:v", "prores_ks", "-profile:v", "4444", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", url.path]
        let result = try await Shell.run(ffmpeg, args)
        guard result.status == 0 else { throw FFmpegError(message: result.stderrText) }
        return url
    }
    let ssSpeakerURL = try await ssClip("ss-speaker.mov", "testsrc2=size=1280x720:rate=30", seconds: 6, audio: true)
    let ssScreenURL = try await ssClip("ss-screen.mov", "testsrc2=size=960x600:rate=30,hue=h=140", seconds: 9, audio: false)
    let ssSpeakerMedia = try await FFmpeg.probe(url: ssSpeakerURL), ssScreenMedia = try await FFmpeg.probe(url: ssScreenURL)
    var ssItem = VideoItem(url: ssSpeakerURL)
    ssItem.info = ssSpeakerMedia; ssItem.crop = ssSpeakerMedia.fullFrame; ssItem.status = .ready
    var ssLive = ScreenTrack(url: ssScreenURL, info: ssScreenMedia, offset: 1)
    ssLive.spans = [LayoutSpan(start: 2, end: 3.5, layout: .split), LayoutSpan(start: 4.5, end: 6, layout: .speaker)]

    let ssProject = VideoProject(clips: [ProjectClip(ssItem)], settings: ExportSettings(), selection: ssItem.id)
    let ssAttach = try ProjectReducer.apply([.setScreen(clip: ssItem.id, screen: ssLive)], to: ssProject)
    check(ssAttach.project.clips[0].screen == ssLive, "setScreen attaches the screen with its offset and layouts")
    let ssSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(ssAttach.project))
    check(ssSaved == ssAttach.project && ssSaved.version == VideoProject.currentVersion, "a screen and its layouts survive a project round trip")
    var ssAsThirteen = ssSaved; ssAsThirteen.version = 13
    check((try? ssAsThirteen.validate()) == nil, "a version 13 file with a screen is refused")
    check(reducerRefusal([.addLayout(clip: ssItem.id, span: LayoutSpan(start: 1, end: 2, layout: .split))], ssProject) == .invalidCommand,
          "a layout needs a screen recording first")
    let ssAdded = try ProjectReducer.apply([.addLayout(clip: ssItem.id, span: LayoutSpan(start: 0.51, end: 1.49, layout: .speaker))], to: ssAttach.project)
    let ssAddedSpan = ssAdded.project.clips[0].screen?.spans.first
    check(ssAddedSpan.map { abs($0.start - 0.5) < 0.0001 && abs($0.end - 1.5) < 0.0001 } == true && ssAdded.createdIDs.count == 1,
          "addLayout snaps to frames and reports the new id", "\(String(describing: ssAddedSpan))")
    check(reducerRefusal([.addLayout(clip: ssItem.id, span: LayoutSpan(start: 3, end: 5, layout: .speaker))], ssAttach.project) == .invalidCommand,
          "a layout that overlaps another is refused")
    let ssCutting = try ProjectReducer.apply([.replaceSections(clip: ssItem.id, sections: [TimelineSegment(start: 0, end: 4)])], to: ssAttach.project)
    check(ssCutting.removedLayouts == [ssLive.spans[1].id] && ssCutting.project.clips[0].screen?.spans.count == 1,
          "cutting a layout's footage away removes it and reports it")

    print("\nScreen layout parity")
    ssItem.screen = ssLive
    let ssExport = scratch.appendingPathComponent("ss-layout.mp4")
    var ssSettings = ExportSettings(); ssSettings.quality = 100; ssSettings.preset = "ultrafast"
    try await FFmpeg.export(input: ssSpeakerURL, output: ssExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, settings: ssSettings, screen: ssLive) { _ in }
    equal(try await frameCount(ssExport), try await frameCount(ssSpeakerURL), "the export with a screen keeps every frame of the speaker")
    let ssStage = FFmpeg.layoutStage(ssLive, geometry: LayoutGeometry(track: ssLive, crop: ssSpeakerMedia.fullFrame), duration: 9, rate: 30,
                                     rateExpression: "30", sourceRate: 30, tags: .rec709, endScreen: nil)
    let ssStageGraph = ssStage.parts.joined(separator: ";")
    var ssOpenScalers = 0
    _ = FFmpeg.rewritingScalers(ssStage.parts.dropFirst(2).joined(separator: ";")) { filter in
        if !filter.contains("threads=") { ssOpenScalers += 1 }
        return filter
    }
    check(ssStage.parts[0].contains("format=yuv444p10le,split=") && ssStageGraph.components(separatedBy: "yuv420p10le").count == 2
              && ssStageGraph.hasSuffix("format=yuv420p10le[lyout]") && ssOpenScalers == 0 && ssStageGraph.contains("threads=1"),
          "the layout runs work in one format, converted once before them and once after, and each run's scaler has one thread",
          "\(ssOpenScalers) scalers without threads")
    let ssGeo = LayoutGeometry(track: ssLive, crop: ssSpeakerMedia.fullFrame)
    var ssWorst = (whole: 0.0, speaker: 0.0, screen: 0.0)
    for frame in [15, 45, 61, 66, 90, 110, 136, 170] {
        let native = try await nativePicture(ssItem, frame: frame)
        let exported = try await ffmpegPicture(ssExport, graph: nil, frame: frame, width: 1280, height: 720)
        let state = ssLive.state(at: Double(frame) / 30, geometry: ssGeo, endScreen: nil)
        let inner = state.speaker.rect.insetBy(dx: state.speaker.rect.width * 0.2, dy: state.speaker.rect.height * 0.2)
        func region(_ rect: CGRect) -> Double {
            var total = 0.0, count = 0
            for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 3) { for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 3) {
                for channel in 0..<3 { total += abs(native.at(x, y, channel) - exported.at(x, y, channel)) }; count += 3 } }
            return total / Double(max(1, count))
        }
        ssWorst.whole = max(ssWorst.whole, meanDifference(native, exported, xs: 4..<1276))
        ssWorst.speaker = max(ssWorst.speaker, region(inner))
        if let screen = state.screen { ssWorst.screen = max(ssWorst.screen, region(screen.rect.insetBy(dx: 30, dy: 30))) }
    }
    print(String(format: "       screen layout parity: whole frame %.2f, speaker %.2f, screen %.2f of 255", ssWorst.whole, ssWorst.speaker, ssWorst.screen))
    check(ssWorst.whole < 3 && ssWorst.speaker < 3 && ssWorst.screen < 3,
          "the export draws each layout, held and while it changes, as the preview does")

    print("\nInk layout")
    let ikHeld = ssGeometry.held(.ink), ikLines = ssGeometry.screenPlace(.ink)!.rect
    let ikFace = ssGeometry.facePoint(in: ikHeld)
    check(ikHeld.ink == 1 && ikHeld.speaker.rect.maxX == 1920 && ikHeld.speaker.rect.minY == 0 && ikHeld.speaker.rect.height == 1080
              && ikHeld.window.size == ikHeld.speaker.rect.size && abs(Double(ikFace.x) - LayoutGeometry.inkFace * 1920) <= 2 && ikHeld.speaker.radius == 0,
          "Ink moves the speaker right at full size, the face at \(Int(LayoutGeometry.inkFace * 100)) % of the width", "\(ikHeld.speaker.rect) face \(ikFace)")
    check(ikLines.minX == 40 && ikLines.maxX <= LayoutGeometry.inkWidth * 1920 + 2 && ikLines.minY >= 40 && ikLines.maxY <= 1040 && ssGeometry.screenPlace(.ink)!.radius == 0
              && abs(Double(ikLines.width / ikLines.height) - 3248.0 / 2008) < 0.01,
          "Ink puts the whole screen, as large as fits, left of the speaker, with square corners", "\(ikLines)")
    check(abs(LayoutGeometry.inkShade(at: 10, width: 1920) - 0.91) < 0.0001 && LayoutGeometry.inkShade(at: LayoutGeometry.inkShadeEnd * 1920, width: 1920) == 0
              && LayoutGeometry.inkShade(at: 1100, width: 1920) > 0 && LayoutGeometry.inkShade(at: 1100, width: 1920) < 0.91
              && LayoutGeometry.inkShadeEnd * 1920 < Double(ikFace.x) - 40,
          "the shade is strong on the left and gone before the face")
    var ikMoves = ssTrack; ikMoves.spans = [LayoutSpan(start: 10, end: 20, layout: .ink)]
    let ikMid = ikMoves.state(at: 10.2, geometry: ssGeometry, endScreen: nil)
    check(ikMid.ink > 0.2 && ikMid.ink < 0.8 && ikMoves.state(at: 10.5, geometry: ssGeometry, endScreen: nil).ink == 1
              && ikMoves.state(at: 20.5, geometry: ssGeometry, endScreen: nil).ink == 0 && ikMoves.usesInk && !ssTrack.usesInk,
          "a change into Ink eases its look in over 0.4 s, and out again after", "\(ikMid.ink)")
    let ikShort = LayoutGeometry(short: ssTrack, crop: ssSpeakerInfo.fullFrame, window: ShortFormat.defaultWindow(in: ssSpeakerInfo.fullFrame, info: ssSpeakerInfo))
    check(ikShort.held(.ink) == ikShort.held(.screen), "in a Short, Ink shows as the Screen layout does: the screen on top")

    // A dark canvas with white lines and a grey box (partly keyed), and a speaker.
    let ikCanvasURL = try await ssClip("ik-canvas.mov", "color=c=0x1c1c1c:s=960x600:r=30,drawgrid=w=96:h=96:t=4:c=white,"
                                       + "drawbox=x=120:y=110:w=220:h=150:c=0x9a9a9a:t=fill,drawbox=x=500:y=300:w=180:h=120:c=0x484848:t=fill",
                                       seconds: 9, audio: false)
    let ikCanvas = try await FFmpeg.probe(url: ikCanvasURL)
    var ikLive = ScreenTrack(url: ikCanvasURL, info: ikCanvas, offset: 1)
    ikLive.spans = [LayoutSpan(start: 1, end: 3, layout: .ink), LayoutSpan(start: 4.5, end: 6, layout: .speaker)]
    var ikItem = ssItem; ikItem.screen = ikLive
    let ikExport = scratch.appendingPathComponent("ik-layout.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: ikExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, settings: ssSettings, screen: ikLive) { _ in }
    equal(try await frameCount(ikExport), try await frameCount(ssSpeakerURL), "the export with Ink keeps every frame of the speaker")
    let ikGeo = LayoutGeometry(track: ikLive, crop: ssSpeakerMedia.fullFrame)
    var ikWorst = 0.0
    for frame in [15, 34, 45, 70, 94, 120] {
        let native = try await nativePicture(ikItem, frame: frame)
        let exported = try await ffmpegPicture(ikExport, graph: nil, frame: frame, width: 1280, height: 720)
        ikWorst = max(ikWorst, meanDifference(native, exported, xs: 4..<1276))
    }
    print(String(format: "       ink layout parity: whole frame %.2f of 255", ikWorst))
    check(ikWorst < 3, "the export draws Ink, held and while it changes, as the preview does")
    let ikFrame = try await nativePicture(ikItem, frame: 70)
    let ikPlace = ikGeo.screenPlace(.ink)!.rect, ikScale = Double(ikPlace.width) / 960
    func ikAt(_ x: Double, _ y: Double) -> Double { ikFrame.at(Int(Double(ikPlace.minX) + x * ikScale), Int(Double(ikPlace.minY) + y * ikScale), 1) }
    let ikCanvasAt = ikAt(48, 48), ikLineAt = ikAt(1, 48), ikDarkBox = ikAt(590, 360), ikGreyBox = ikAt(230, 185)
    check(ikCanvasAt < 30 && ikDarkBox < 30 && ikLineAt > 180 && ikGreyBox > ikCanvasAt + 25 && ikGreyBox < ikLineAt - 40,
          "Ink keys out the dark canvas and dark shapes, keeps the white lines, and lets mid greys through in part",
          String(format: "canvas %.0f, dark box %.0f, line %.0f, grey box %.0f", ikCanvasAt, ikDarkBox, ikLineAt, ikGreyBox))

    print("\nShorts with the screen on top")
    let skWindow = ShortFormat.defaultWindow(in: ssSpeakerMedia.fullFrame, info: ssSpeakerMedia)
    let skGeo = LayoutGeometry(short: ssLive, crop: ssSpeakerMedia.fullFrame, window: skWindow)
    let skScreen = skGeo.screenPlace(.screen)!, skSpeaker = skGeo.speakerPlace(.screen)
    check(skGeo.frame == ShortFormat.size && skScreen.rect.minY == 240 && skScreen.rect.width == 1032
              && abs(Double(skScreen.rect.height / skScreen.rect.width) - Double(ssLive.picture.height / ssLive.picture.width)) < 0.01
              && skSpeaker.rect.minY == skScreen.rect.maxY + LayoutGeometry.stackCaptionBand && skSpeaker.rect.maxY == 1920 && skSpeaker.rect.width == 1080
              && skGeo.screenPlace(.split) == skScreen && skGeo.speakerPlace(.split) == skSpeaker && skGeo.screenPlace(.speaker) == nil,
          "in a Short the screen sits across the top and the speaker below it, in the screen and side by side layouts", "\(skScreen) \(skSpeaker)")
    let skHeldSpeaker = skGeo.held(.speaker), skHeldStack = skGeo.held(.screen)
    check(skHeldSpeaker.window == skWindow && skHeldSpeaker.speaker.rect == CGRect(origin: .zero, size: ShortFormat.size)
              && abs(Double(skHeldStack.window.width / skHeldStack.window.height) - Double(skSpeaker.rect.width / skSpeaker.rect.height)) < 0.01
              && ssSpeakerMedia.fullFrame.contains(skHeldStack.window) && skGeo.stackCaptionBottom == Double(skSpeaker.rect.minY) - 16,
          "the speaker layout shows the Short's own window; below the screen the window keeps its place's aspect; captions sit just above the speaker",
          "\(skHeldSpeaker.window) \(skHeldStack.window)")
    var skTimed = ssLive
    skTimed.zooms = [ZoomShot(start: 2.2, hold: 0.5, level: 2, target: CGPoint(x: 400, y: 300)),
                     ZoomShot(start: 0.1, hold: 0.2, level: 2, target: CGPoint(x: 400, y: 300))]
    let skPart = skTimed.forShort(Short(start: 1, end: 4))
    let skPartZooms = skPart.zooms.map(\.start).sorted()
    check(skPart.spans.count == 1 && abs(skPart.spans[0].start - 1) < 0.0001 && abs(skPart.spans[0].end - 2.5) < 0.0001
              && skPartZooms.count == 2 && abs(skPartZooms[0] + 0.9) < 0.0001 && abs(skPartZooms[1] - 1.2) < 0.0001 && skPart.offset == ssLive.offset,
          "in a Short's own time the screen's layouts are cut and moved, and every zoom it touches comes along, one that began before it from before 0")
    var skShort = Short(start: 0, end: 6); skShort.screen = .top
    let skCoded = try JSONDecoder().decode(Short.self, from: JSONEncoder().encode(skShort))
    let skPlain = try JSONDecoder().decode(Short.self, from: Data(#"{"start": 0, "end": 2}"#.utf8))
    var skZoomed = skShort; skZoomed.zoom = 0.75
    let skOldText = String(decoding: try JSONEncoder().encode(Short(start: 0, end: 2)), as: UTF8.self)
    check(skCoded.screen == .top && skPlain.screen == .off && !skOldText.contains("screen")
              && skZoomed.problem(duration: 6, info: ssSpeakerMedia)?.contains("zoom") == true && skShort.problem(duration: 6, info: ssSpeakerMedia) == nil,
          "a Short keeps its screen setting; an older Short reads as off; with the screen on top it does not zoom out")
    var skItem = ssItem; skItem.shorts = [skShort]
    var skOff = skShort; skOff.screen = .off
    check(skItem.shortItem(skShort).screen?.spans == ssLive.spans && skItem.shortItem(skOff).screen == nil
              && skItem.shortCaptionBottom(skShort) == skGeo.stackCaptionBottom && skItem.shortCaptionBottom(skOff) == nil,
          "a Short with the screen on top carries the screen and its caption line; one without leaves both out")

    let skOut = scratch.appendingPathComponent("short-stack.mp4")
    try await ShortExport.export(skItem, info: ssSpeakerMedia, short: skShort, settings: ssSettings, output: skOut) { _ in }
    let skMedia = try await FFmpeg.probe(url: skOut)
    let skFrames = try await frameCount(skOut)
    check(skMedia.width == 1080 && skMedia.height == 1920 && skFrames == 180,
          "a Short with the screen exports at 1080×1920 with every frame", "\(skMedia.width)×\(skMedia.height)")
    var skWorst = 0.0
    for frame in [15, 75, 141, 165] {
        let native = try await nativePicture(skItem, frame: frame, short: skShort)
        let exported = try await ffmpegPicture(skOut, graph: nil, frame: frame, width: 1080, height: 1920)
        check(native.width == 1080 && native.height == 1920, "the preview draws the Short at 1080×1920", "\(native.width)×\(native.height)")
        skWorst = max(skWorst, meanDifference(native, exported, xs: 4..<1076))
    }
    print(String(format: "       Short with the screen parity: %.2f of 255", skWorst))
    check(skWorst < 3, "the export draws the Short with the screen as the preview does: stacked, alone and while it changes")

    // A Short that starts inside a zoom keeps it, as the preview shows it: the speaker's zoom
    // and the screen's, with the screen on top and without it.
    var szItem = skItem
    szItem.zoomShots = [ZoomShot(start: 0.5, hold: 2.6, level: 1.5,
                                 target: CGPoint(x: Double(ssSpeakerMedia.width) / 2, y: Double(ssSpeakerMedia.height) / 2))]
    szItem.screen?.zooms = [ZoomShot(start: 0.4, hold: 2.8, level: 2, target: CGPoint(x: 400, y: 300))]
    var szShort = Short(start: 2, end: 5.5); szShort.screen = .top
    var szOff = szShort; szOff.screen = .off
    szItem.shorts = [szShort]
    let szCut = szItem.shortItem(szShort)
    check(szCut.zoomShots.count == 1 && abs(szCut.zoomShots[0].start + 1.5) < 0.0001
              && szCut.screen?.zooms.count == 1 && szCut.screen.map { abs($0.zooms[0].start + 1.6) < 0.0001 } == true,
          "a zoom that began before the Short comes along whole, starting before 0")
    // The preview plays the whole recording, so its frames count from the recording's start.
    let szFirst = Int((szShort.start * 30).rounded())
    // Frame 60 (2 s into the Short) is in both zooms' ease out, where the two renderers differ most.
    var szWorst = (held: 0.0, easing: 0.0)
    for (index, short) in [szShort, szOff].enumerated() {
        var item = szItem; item.shorts = [short]
        let out = scratch.appendingPathComponent("short-zoom-\(index).mp4")
        try await ShortExport.export(item, info: ssSpeakerMedia, short: short, settings: ssSettings, output: out) { _ in }
        for frame in [10, 40, 60, 90] {
            let native = try await nativePicture(item, frame: szFirst + frame, short: short)
            // Without the screen the preview draws the window at its own size; the export scales it to 1080×1920.
            let graph = native.width == 1080 ? nil : "[0:v]scale=\(native.width):\(native.height):flags=lanczos[mvout]"
            let exported = try await ffmpegPicture(out, graph: graph, frame: frame, width: native.width, height: native.height)
            let difference = meanDifference(native, exported, xs: 4..<(native.width - 4))
            if frame == 60 { szWorst.easing = max(szWorst.easing, difference) } else { szWorst.held = max(szWorst.held, difference) }
        }
    }
    print(String(format: "       Short inside a zoom parity: held %.2f, easing %.2f of 255", szWorst.held, szWorst.easing))
    check(szWorst.held < 3 && szWorst.easing < 6, "the export zooms a Short that starts inside a zoom as the preview does, with the screen and without")

    let skAgent = AppModel(recoveryURL: nil)
    var skAgentItem = ssItem; skAgentItem.shorts = []
    skAgent.restore(VideoProject(clips: [ProjectClip(skAgentItem)], settings: ExportSettings(), selection: skAgentItem.id))
    var skAdd = address(skAgent)
    skAdd["method"] = "apply"; skAdd["requestID"] = "st-add"; skAdd["client"] = "Claude"
    skAdd["commands"] = [["type": "addShort", "clipID": skAgentItem.id.uuidString, "short": ["start": 0, "end": 6, "screen": "top"]]]
    let skAdded = await agentCall(skAgent, skAdd)
    let skState = ((agentResult(await agentCall(skAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["shorts"] as? [[String: Any]])?.first
    check(skAdded["ok"] as? Bool == true && skAgent.items[0].shorts.first?.screen == .top && skState?["screen"] as? String == "top",
          "an agent adds a Short with the screen on top, and state shows it", "\(skAdded)")
    let skBare = AppModel(recoveryURL: nil)
    var skBareItem = ssItem; skBareItem.screen = nil; skBareItem.shorts = []
    skBare.restore(VideoProject(clips: [ProjectClip(skBareItem)], settings: ExportSettings(), selection: skBareItem.id))
    var skBareAdd = address(skBare)
    skBareAdd["method"] = "apply"; skBareAdd["requestID"] = "st-bare"; skBareAdd["client"] = "Claude"
    skBareAdd["commands"] = [["type": "addShort", "clipID": skBareItem.id.uuidString, "short": ["start": 0, "end": 6, "screen": "top"]]]
    let skRefused = await agentCall(skBare, skBareAdd)
    check(agentError(skRefused) == "invalid_command" && ((skRefused["error"] as? [String: Any])?["message"] as? String ?? "").contains("setScreen"),
          "a Short cannot show a screen the recording does not have", "\(skRefused)")

    print("\nStacked Shorts in YouTube's clear area")
    var skFaced = ssLive; skFaced.bubble.face = CGPoint(x: 640, y: 240)
    let skFacedGeo = LayoutGeometry(short: skFaced, crop: ssSpeakerMedia.fullFrame, window: skWindow)
    let skTarget = skFacedGeo.stackFaceTarget, skLanded = skFacedGeo.facePoint(in: skFacedGeo.held(.screen))
    check(ShortFormat.clearArea.contains(skTarget) && abs(skLanded.x - skTarget.x) <= 2 && abs(skLanded.y - skTarget.y) <= 2
              && Double(skTarget.y) > Double(skFacedGeo.speakerPlace(.screen).rect.minY),
          "below the screen the face lands inside the clear area, left of the rail and above the title", "\(skLanded) for \(skTarget)")
    var skGood = skItem; skGood.screen = skFaced
    var skCorner = skFaced; skCorner.bubble.face = CGPoint(x: 1270, y: 715)
    var skBad = skItem; skBad.screen = skCorner
    check(!skGood.shortIssues(skShort).contains { $0.field == "safeArea" }
              && skBad.shortIssues(skShort).contains { $0.field == "safeArea" && $0.severity == .warning },
          "a Short whose face cannot reach the clear area is a warning; one that does is not")
    let skWhite: CGImage = {
        let context = CGContext(data: nil, width: 1080, height: 1920, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1920))
        return context.makeImage()!
    }()
    let skDrawn = ShortFurnitureDrawing.draw(over: skWhite)!
    let skGrey = rgb(skWhite, 600, 900).0
    check(rgb(skDrawn, 300, 20).0 < skGrey - 20 && rgb(skDrawn, 300, 1890).0 < skGrey - 20 && rgb(skDrawn, 600, 900).0 == skGrey
              && (880..<920).contains { rgb(skDrawn, 48, $0).0 > skGrey + 20 },
          "YouTube's player is drawn over the frame: shaded at the top and the bottom, the clear area dashed, the middle untouched",
          "\(rgb(skDrawn, 300, 20)) \(rgb(skDrawn, 300, 1890)) \(rgb(skDrawn, 600, 900))")
    let skShortID = skAgent.items[0].shorts.first?.id.uuidString ?? ""
    let skPlainPreview = agentResult(await agentCall(skAgent, ["method": "preview", "clip": skAgentItem.id.uuidString, "short": skShortID, "time": 1, "composed": true]))
    let skFurnished = agentResult(await agentCall(skAgent, ["method": "preview", "clip": skAgentItem.id.uuidString, "short": skShortID, "time": 1,
                                                            "composed": true, "furniture": true]))
    let skPlainImage = (skPlainPreview["path"] as? String).flatMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    let skFurnishedImage = (skFurnished["path"] as? String).flatMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    check(skPlainImage.flatMap { plain in skFurnishedImage.map { rgb($0, 300, 1890).0 < rgb(plain, 300, 1890).0 } } == true,
          "an agent's preview of a Short can show YouTube's player over it")
    let ssBubbleFrame = try await nativePicture(ssItem, frame: 30)
    let ssPlainItem: VideoItem = { var plain = ssItem; plain.screen = nil; return plain }()
    let ssPlainFrame = try await nativePicture(ssPlainItem, frame: 30)
    check(meanDifference(ssBubbleFrame, ssPlainFrame, xs: 4..<1276) > 20, "with a screen the Preview shows the layout, not the speaker alone")
    let ssSpeakerFrame = try await nativePicture(ssItem, frame: 170), ssPlainSpeaker = try await nativePicture(ssPlainItem, frame: 170)
    check(meanDifference(ssSpeakerFrame, ssPlainSpeaker, xs: 4..<1276) < 2.5, "in the Speaker layout the Preview shows the speaker as without a screen",
          String(format: "%.2f", meanDifference(ssSpeakerFrame, ssPlainSpeaker, xs: 4..<1276)))

    print("\nScreen sync")
    // The screen's brightness says its frame number, modulo 50.
    let ssCoded = scratch.appendingPathComponent("ss-coded.mov")
    let ssCodedMake = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=640x400:r=30:d=9",
        "-vf", "format=yuv444p,geq=lum='16+mod(N\\,50)*4':cb=128:cr=128,format=yuv444p10le", "-c:v", "prores_ks", "-profile:v", "4444",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", ssCoded.path])
    check(ssCodedMake.status == 0, "made a screen whose brightness counts its frames", ssCodedMake.stderrText)
    let ssCodedTrack = ScreenTrack(url: ssCoded, info: try await FFmpeg.probe(url: ssCoded), offset: 0.5)
    var ssCutItem = ssItem
    ssCutItem.screen = ssCodedTrack
    ssCutItem.segments = [TimelineSegment(start: 0, end: 1.5), TimelineSegment(start: 3, end: 4, speed: 2), TimelineSegment(start: 4.5, end: 6)]
    let ssCutExport = scratch.appendingPathComponent("ss-cut.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: ssCutExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, segments: ssCutItem.segments,
                            settings: ssSettings, screen: ssCodedTrack) { _ in }
    let ssCodedPlace = LayoutGeometry(track: ssCodedTrack, crop: ssSpeakerMedia.fullFrame).screenPlace(.screen)!.rect
    func ssCodedFrame(_ picture: Picture) -> Int {
        var total = 0.0, count = 0
        for y in stride(from: Int(ssCodedPlace.minY) + 40, to: Int(ssCodedPlace.minY) + 140, by: 7) {
            for x in stride(from: Int(ssCodedPlace.minX) + 40, to: Int(ssCodedPlace.minX) + 300, by: 7) { total += picture.at(x, y, 1); count += 1 }
        }
        return Int(((total / Double(count) * 219 / 255) / 4).rounded())
    }
    let ssCutTimeline = ClipTimeline(segments: ssCutItem.segments!)
    var ssOff = (export: 0, preview: 0, apart: 0)
    for frame in stride(from: 0, to: Int(ssCutTimeline.duration * 30) - 1, by: 4) {
        let source = ssCutTimeline.location(at: Double(frame) / 30)!.source
        let expected = Int(((source + 0.5) * 30 + 0.001).rounded(.down)) % 50
        let exported = ssCodedFrame(try await ffmpegPicture(ssCutExport, graph: nil, frame: frame, width: 1280, height: 720))
        let previewed = ssCodedFrame(try await nativePicture(ssCutItem, frame: frame))
        if exported != expected { ssOff.export += 1 }
        if previewed != expected { ssOff.preview += 1 }
        if exported != previewed { ssOff.apart += 1 }
    }
    check(ssOff.export == 0 && ssOff.preview == 0 && ssOff.apart == 0,
          "through cuts and a 2× section the screen stays on the speaker's clock, in the export and the Preview", "\(ssOff)")
    // A long offset: the export seeks the screen recording, and past its end the last frame holds.
    var ssSeek = ssCodedTrack; ssSeek.offset = 4.5
    let ssSeekLayer = FFmpeg.screenLayer(ssSeek, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, segments: ssCutItem.segments,
                                         rate: 30, rateExpression: "30/1", input: 1, tags: .rec709, endScreen: nil)
    check(ssSeekLayer.seek > 2 && ssSeekLayer.input(ssCoded).contains("-noaccurate_seek"), "a long offset seeks the screen recording", "\(ssSeekLayer.seek)")
    var ssSeekItem = ssCutItem; ssSeekItem.screen = ssSeek
    let ssSeekExport = scratch.appendingPathComponent("ss-late.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: ssSeekExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, segments: ssCutItem.segments,
                            settings: ssSettings, screen: ssSeek) { _ in }
    var ssSeekOff = (export: 0, preview: 0)
    for frame in stride(from: 0, to: Int(ssCutTimeline.duration * 30) - 1, by: 5) {
        let source = ssCutTimeline.location(at: Double(frame) / 30)!.source
        let expected = Int((min(source + 4.5, ssSeek.info.duration - 1.0 / 30) * 30 + 0.001).rounded(.down)) % 50
        if ssCodedFrame(try await ffmpegPicture(ssSeekExport, graph: nil, frame: frame, width: 1280, height: 720)) != expected { ssSeekOff.export += 1 }
        if ssCodedFrame(try await nativePicture(ssSeekItem, frame: frame)) != expected { ssSeekOff.preview += 1 }
    }
    check(ssSeekOff.export == 0 && ssSeekOff.preview == 0, "with a seek, and past the screen's end, both still show the right screen frame", "\(ssSeekOff)")

    print("\nScreen recordings for agents")
    let ssAgent = AppModel(recoveryURL: nil)
    var ssAgentItem = ssItem; ssAgentItem.screen = nil; ssAgentItem.segments = nil
    ssAgent.restore(VideoProject(clips: [ProjectClip(ssAgentItem)], settings: ExportSettings(), selection: ssAgentItem.id))
    let ssClipText = ssAgentItem.id.uuidString
    @MainActor func ssApply(_ id: String, _ commands: [[String: Any]]) async -> [String: Any] {
        var request = address(ssAgent)
        request["method"] = "apply"; request["requestID"] = id; request["client"] = "Claude"; request["commands"] = commands
        return await agentCall(ssAgent, request)
    }
    let ssSet = await ssApply("ss-set", [["type": "setScreen", "clipID": ssClipText, "path": ssScreenURL.path, "offset": 1]])
    check(ssSet["ok"] as? Bool == true && ssAgent.items[0].screen?.offset == 1 && ssAgent.items[0].screen?.layout == .screen,
          "setScreen probes the file and attaches it in the screen layout", "\(ssSet)")
    let ssUpdate = await ssApply("ss-update", [["type": "updateScreen", "clipID": ssClipText,
                                                "screen": ["offset": 1.5, "layout": "split", "bubble": ["corner": "topLeft", "size": 0.25, "face": ["x": 640, "y": 300]]]]])
    let ssUpdated = ssAgent.items[0].screen
    check(ssUpdate["ok"] as? Bool == true && ssUpdated?.offset == 1.5 && ssUpdated?.layout == .split && ssUpdated?.bubble.corner == .topLeft
              && ssUpdated?.bubble.size == 0.25 && ssUpdated?.bubble.face == CGPoint(x: 640, y: 300),
          "updateScreen changes only the keys given", "\(ssUpdate)")
    let ssBadKey = await ssApply("ss-bad", [["type": "updateScreen", "clipID": ssClipText, "screen": ["zoom": 2]]])
    check(agentError(ssBadKey) == "invalid_command" && ((ssBadKey["error"] as? [String: Any])?["message"] as? String ?? "").contains("Keys"),
          "an unknown screen key is refused with the keys allowed")
    let ssPlan = await ssApply("ss-plan", [["type": "replaceLayouts", "clipID": ssClipText,
                                            "layouts": [["start": 0, "end": 1, "layout": "speaker"], ["start": 4, "end": 6, "layout": "screen"]]]])
    check(ssPlan["ok"] as? Bool == true && ssAgent.items[0].screen?.spans.map(\.layout) == [.speaker, .screen], "replaceLayouts sets every layout at once", "\(ssPlan)")
    let ssAddLayout = await ssApply("ss-add", [["type": "addLayout", "clipID": ssClipText, "layout": ["start": 2, "end": 3, "layout": "speaker"]]])
    let ssNewID = ((ssAddLayout["result"] as? [String: Any])?["createdIDs"] as? [String])?.first ?? ""
    check(ssAddLayout["ok"] as? Bool == true && ssAgent.items[0].screen?.spans.count == 3, "addLayout adds one and returns its id", "\(ssAddLayout)")
    let ssMove = await ssApply("ss-move", [["type": "updateLayout", "clipID": ssClipText, "layoutID": ssNewID, "layout": ["start": 2.5]]])
    let ssMovedSpan = ssAgent.items[0].screen?.spans.first { $0.id.uuidString == ssNewID }
    check(ssMove["ok"] as? Bool == true && ssMovedSpan.map { abs($0.start - 2.5) < 0.001 && abs($0.end - 3.5) < 0.001 } == true,
          "moving a layout's start alone keeps its length", "\(ssMove)")
    let ssState = (agentResult(await agentCall(ssAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["screen"] as? [String: Any]
    check(ssState?["offset"] as? Double == 1.5 && (ssState?["layouts"] as? [[String: Any]])?.count == 3 && ssState?["layout"] as? String == "split"
              && (ssState?["covered"] as? [[Double]])?.count == 1,
          "state shows the screen, its layouts and where its footage covers the recording", "\(ssState ?? [:])")
    let ssComposed = agentResult(await agentCall(ssAgent, ["method": "preview", "clip": ssClipText, "time": 5.5, "composed": true]))
    check((ssComposed["path"] as? String).map { FileManager.default.fileExists(atPath: $0) } == true, "a composed preview draws the layout", "\(ssComposed)")
    // A thumbnail cuts the speaker out of their own picture, also where the layout shows the screen.
    func imageDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var total = 0, count = 0
        for y in stride(from: 4, to: a.height - 4, by: max(1, a.height / 40)) { for x in stride(from: 4, to: a.width - 4, by: max(1, a.width / 60)) {
            let p = rgb(a, x, y), q = rgb(b, x, y); total += abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2); count += 3
        } }
        return Double(total) / Double(max(1, count))
    }
    let ssThumbClip = ProjectClip(ssAgent.items[0])
    var ssThumbSpeakerClip = ssThumbClip; ssThumbSpeakerClip.screen = nil
    let ssThumbFrame = try await ssAgent.thumbnailSources(ssThumbClip, at: 5.5, cutout: false).frame
    let ssThumbSpeakerFrame = try await ssAgent.composedFrame(ssThumbSpeakerClip, at: 5.5, settings: ssAgent.settings, graphics: false).image
    let ssThumbLayoutFrame = try await ssAgent.composedFrame(ssThumbClip, at: 5.5, settings: ssAgent.settings, graphics: false).image
    check(imageDifference(ssThumbFrame, ssThumbSpeakerFrame) < 2 && imageDifference(ssThumbFrame, ssThumbLayoutFrame) > 8,
          "a thumbnail's frame is the speaker's own picture, also in a part that shows the screen",
          String(format: "against the speaker %.1f, against the layout %.1f", imageDifference(ssThumbFrame, ssThumbSpeakerFrame), imageDifference(ssThumbFrame, ssThumbLayoutFrame)))
    let ssRemove = await ssApply("ss-remove", [["type": "removeLayout", "clipID": ssClipText, "layoutID": ssNewID]])
    check(ssRemove["ok"] as? Bool == true && ssAgent.items[0].screen?.spans.count == 2, "removeLayout removes one layout", "\(ssRemove)")
    let ssGone = await ssApply("ss-gone", [["type": "removeScreen", "clipID": ssClipText]])
    check(ssGone["ok"] as? Bool == true && ssAgent.items[0].screen == nil, "removeScreen removes the screen and its layouts")
    let ssNoScreen = await ssApply("ss-none", [["type": "addLayout", "clipID": ssClipText, "layout": ["start": 0, "end": 1, "layout": "split"]]])
    check(agentError(ssNoScreen) == "invalid_command" && ((ssNoScreen["error"] as? [String: Any])?["message"] as? String ?? "").contains("setScreen"),
          "a layout on a recording without a screen is refused, naming setScreen")
    let ssCatalog = AgentCatalog.current.commands.filter { $0.group == "screen" }.map(\.type)
    equal(ssCatalog, ["setScreen", "updateScreen", "removeScreen", "addLayout", "updateLayout", "removeLayout",
                      "addScreenZoom", "updateScreenZoom", "removeScreenZoom", "replaceScreenZooms", "replaceLayouts"],
          "the catalog describes the screen commands")

    print("\nScreen recordings in the app")
    let ssApp = AppModel(recoveryURL: nil)
    var ssAppItem = ssItem; ssAppItem.segments = nil; ssAppItem.screen = ssLive
    ssApp.restore(VideoProject(clips: [ProjectClip(ssAppItem)], settings: ExportSettings(), selection: ssAppItem.id))
    ssApp.setPreviewFraction(0.5 / ssAppItem.editedDuration)
    ssApp.addLayoutAtPlayhead()
    let ssAppSpan = ssApp.items[0].screen?.spans.first { abs($0.start - 0.5) < 0.001 }
    check(ssAppSpan.map { $0.layout == .speaker && abs($0.end - 2) < 0.001 } == true && ssApp.selectedLayoutID == ssAppSpan?.id,
          "Add Layout puts the other layout from the playhead up to the next one", "\(String(describing: ssApp.items[0].screen?.spans))")
    if let id = ssAppSpan?.id {
        ssApp.updateLayout(id) { $0.end = 3 }
        check(ssApp.items[0].screen?.spans.first { $0.id == id }.map { abs($0.end - 2) < 0.001 } == true, "a dragged edge stops at the next layout")
    }
    ssApp.setPreviewFraction(3 / ssAppItem.editedDuration)
    ssApp.setScreenTime(atPlayhead: 10)
    check(ssApp.items[0].screen.map { abs($0.offset - 7) < 0.0001 } == true && ssApp.screenTimeAtPlayhead.map { abs($0 - 10) < 0.0001 } == true,
          "typing the screen's time at the playhead sets the offset")
    ssApp.nudgeScreenOffset(by: -1)
    check(ssApp.items[0].screen.map { abs($0.offset - 6) < 0.0001 } == true, "the offset nudges by a second")

    print("\nScreen border and long graphs")
    let ssBordered = scratch.appendingPathComponent("ss-bordered.mov")
    let ssBorderMake = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=960x600:rate=30",
        "-t", "3", "-vf", "pad=1100:700:70:50:black", "-c:v", "libx264", "-pix_fmt", "yuv420p", ssBordered.path])
    check(ssBorderMake.status == 0, "made a screen recording with a dark border", ssBorderMake.stderrText)
    let ssBorder = try await FFmpeg.screenBorder(ssBordered, info: try await FFmpeg.probe(url: ssBordered))
    check(ssBorder.map { abs($0.minX - 70) <= 4 && abs($0.minY - 50) <= 4 && abs($0.width - 960) <= 8 && abs($0.height - 600) <= 8 } == true,
          "Crop Border finds the picture inside the dark border", "\(String(describing: ssBorder))")
    let ssNoBorder = try await FFmpeg.screenBorder(ssScreenURL, info: ssScreenMedia)
    check(ssNoBorder == nil, "a screen recording without a border is left whole", "\(String(describing: ssNoBorder))")
    let ssLong = ["-i", "in.mov", "-filter_complex", String(repeating: "null,", count: 30_000) + "null", "-map", "[v]"]
    let ssSpilled = try FFmpeg.spilledGraph(ssLong)
    let ssShortGraph = try FFmpeg.spilledGraph(["-filter_complex", "[0:v]null[v]"])
    check(ssSpilled[2] == "-/filter_complex" && (try? String(contentsOfFile: ssSpilled[3], encoding: .utf8)) == ssLong[3]
              && ssShortGraph == ["-filter_complex", "[0:v]null[v]"],
          "a very long filter graph goes to a file; a short one stays in the command")

    print("\nScalers on one thread, and exports that stop early")
    let stGraph = "[0:v]scale=640:360:flags=lanczos,format=yuv444p,scale='min(1280,iw)':-2:flags=bilinear,zscale=t=linear[a];[a]scale[b];[b]scale=320:180:threads=4,scale2ref[c]"
    let stLimited = FFmpeg.oneThreadScalers(stGraph)
    equal(stLimited, "[0:v]scale=640:360:flags=lanczos:threads=1,format=yuv444p,scale='min(1280,iw)':-2:flags=bilinear:threads=1,"
              + "zscale=t=linear[a];[a]scale=threads=1[b];[b]scale=320:180:threads=4,scale2ref[c]",
          "every scaler gets one thread; quoted commas, zscale, scale2ref and a scaler with threads stay as they are")
    equal(FFmpeg.oneThreadScalers(stLimited), stLimited, "the rewrite is done once")
    let stFew = ["-filter_complex", (0..<10).map { "scale=\(100 + 2 * $0):100" }.joined(separator: ",")]
    let stMany = ["-filter_complex", (0..<60).map { "scale=\(100 + 2 * $0):100" }.joined(separator: ",")]
    let stBounded = FFmpeg.boundedScalerThreads(stMany)[1]
    check(FFmpeg.boundedScalerThreads(stFew) == stFew && stBounded.components(separatedBy: ":threads=1").count - 1 == 44
              && stBounded.hasPrefix("scale=100:100,") && stBounded.hasSuffix("scale=218:100:threads=1"),
          "a graph with many scalers keeps threads for its first 16 only; a small graph is left alone")
    let stRun = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=1",
        "-filter_complex", FFmpeg.oneThreadScalers("[0:v]scale=160:90,format=yuv444p10le,scale,format=yuv420p[o]"), "-map", "[o]", "-f", "null", "-"])
    check(stRun.status == 0, "ffmpeg runs a graph with one-thread scalers", stRun.stderrText)
    let stShort = scratch.appendingPathComponent("short-video.mp4")
    let stMade = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=1",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", stShort.path])
    check(stMade.status == 0, "made a file whose video stops before its audio", stMade.stderrText)
    let stSeconds = await FFmpeg.videoDuration(stShort)
    check(stSeconds.map { abs($0 - 1) < 0.1 } == true, "the video's own length is read, not the file's", "\(String(describing: stSeconds))")
    check(FFmpeg.lengthProblem(video: stSeconds, expected: 3)?.contains("stopped early") == true && FFmpeg.lengthProblem(video: 2.99, expected: 3) == nil
              && FFmpeg.lengthProblem(video: nil, expected: 3) == nil,
          "an export whose video is shorter than the edit is a failure; a frame of rounding is not")

    print("\nScreen zooms")
    var zsTrack = ScreenTrack(url: URL(fileURLWithPath: "/tmp/screen.mov"), info: ssScreenInfo, offset: 0)
    zsTrack.crop = CGRect(x: 112, y: 76, width: 3024, height: 1784)
    zsTrack.zooms = [ZoomShot(start: 10, hold: 2, level: 2, target: CGPoint(x: 1600, y: 900))]
    let zsPicture = zsTrack.picture
    check(zsTrack.zoomWindow(at: 9) == CGRect(origin: .zero, size: zsPicture.size), "before a screen zoom the whole screen shows")
    let zsHeld = zsTrack.zoomWindow(at: 11)
    check(abs(zsHeld.width - zsPicture.width / 2) < 0.001 && abs(zsHeld.midX - (1600 - zsPicture.minX)) < 0.001
              && abs(zsHeld.midY - (900 - zsPicture.minY)) < 0.001,
          "while it holds, the window is the picture over the level, centred on the target", "\(zsHeld)")
    zsTrack.zooms[0].target = CGPoint(x: 3200, y: 100)
    let zsEdge = zsTrack.zoomWindow(at: 11)
    check(zsEdge.maxX <= zsPicture.width + 0.001 && zsEdge.minY >= -0.001, "a target near the edge keeps the window inside the picture", "\(zsEdge)")
    let zsEasing = zsTrack.zoomWindow(at: 10.25)
    check(zsEasing.width < zsPicture.width && zsEasing.width > zsHeld.width, "the zoom eases in", "\(zsEasing)")
    zsTrack.zooms[0].target = CGPoint(x: 1600, y: 900)
    let zsGeometry = LayoutGeometry(track: zsTrack, crop: ssSpeakerInfo.fullFrame)
    let zsPlace = zsGeometry.screenPlace(.screen)!.rect
    let zsMiddle = CGPoint(x: zsPlace.midX, y: zsPlace.midY)
    let zsUnzoomed = zsTrack.screenPoint(zsMiddle, at: 5, geometry: zsGeometry, endScreen: nil)
    let zsZoomed = zsTrack.screenPoint(zsMiddle, at: 11, geometry: zsGeometry, endScreen: nil)
    check(zsUnzoomed.map { abs($0.x - zsPicture.midX) < 1.5 && abs($0.y - zsPicture.midY) < 1.5 } == true
              && zsZoomed.map { abs($0.x - 1600) < 1.5 && abs($0.y - 900) < 1.5 } == true
              && zsTrack.screenPoint(CGPoint(x: 5, y: 5), at: 5, geometry: zsGeometry, endScreen: nil) == nil,
          "a click on the Preview maps to the screen recording through the layout and the zoom",
          "\(String(describing: zsUnzoomed)) \(String(describing: zsZoomed))")
    equal(FFmpeg.streamSize(ScreenTrack(url: zsTrack.url, info: ssScreenInfo), place: zsPlace.size), zsPlace.size, "without zooms the screen's stream is its place")
    let zsStream = FFmpeg.streamSize(zsTrack, place: zsPlace.size)
    check(zsStream.width > zsPlace.width && zsStream.width <= zsPicture.width && Int(zsStream.width) % 2 == 0,
          "with a 2× zoom the stream keeps more of the recording's own detail, never past it", "\(zsStream)")

    let zsProject = try ProjectReducer.apply([.setScreen(clip: ssItem.id, screen: ssLive)], to: ssProject).project
    let zsShot = ZoomShot(start: 1, hold: 1, level: 2, target: CGPoint(x: 480, y: 300))
    let zsAdded = try ProjectReducer.apply([.addScreenZoom(clip: ssItem.id, zoom: zsShot)], to: zsProject)
    check(zsAdded.project.clips[0].screen?.zooms == [zsShot] && zsAdded.createdIDs == [zsShot.id], "addScreenZoom adds a zoom to the screen")
    check(reducerRefusal([.addScreenZoom(clip: ssItem.id, zoom: ZoomShot(start: 1.5, hold: 1, level: 2, target: CGPoint(x: 10, y: 10)))], zsAdded.project) == .invalidCommand
              && reducerRefusal([.addScreenZoom(clip: ssItem.id, zoom: ZoomShot(start: 3, hold: 1, level: 2, target: CGPoint(x: 5000, y: 10)))], zsProject) == .invalidCommand
              && reducerRefusal([.addScreenZoom(clip: ssItem.id, zoom: zsShot)], ssProject) == .invalidCommand,
          "an overlapping screen zoom, a target off the screen recording and a zoom without a screen are refused")
    let zsCut = try ProjectReducer.apply([.replaceSections(clip: ssItem.id, sections: [TimelineSegment(start: 2.5, end: 6)])], to: zsAdded.project)
    check(zsCut.project.clips[0].screen?.zooms.isEmpty == true && zsCut.removedZooms.contains(zsShot.id),
          "a screen zoom whose footage is cut away goes, and is reported")
    let zsSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(zsAdded.project))
    check(zsSaved == zsAdded.project, "screen zooms survive a project round trip")

    // Parity on a screen recording larger than its place, as a real one is.
    let zsLargeURL = scratch.appendingPathComponent("zs-large.mp4")
    let zsLargeMake = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=2560x1600:rate=30", "-t", "6",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p", "-c:v", "libx264", "-crf", "12", "-preset", "veryfast",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", zsLargeURL.path])
    check(zsLargeMake.status == 0, "made a 2560×1600 screen recording", zsLargeMake.stderrText)
    var zsLarge = ScreenTrack(url: zsLargeURL, info: try await FFmpeg.probe(url: zsLargeURL), offset: 0.5)
    zsLarge.spans = [LayoutSpan(start: 2, end: 3.5, layout: .split)]
    zsLarge.zooms = [ZoomShot(start: 0.3, hold: 1, level: 2, target: CGPoint(x: 1860, y: 530)),
                     ZoomShot(start: 2.4, hold: 0.2, level: 3, target: CGPoint(x: 400, y: 1390))]
    var zsItem = ssItem; zsItem.screen = zsLarge; zsItem.segments = nil
    let zsExport = scratch.appendingPathComponent("zs-layout.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: zsExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, settings: ssSettings, screen: zsLarge) { _ in }
    let zsGeo = LayoutGeometry(track: zsLarge, crop: ssSpeakerMedia.fullFrame)
    var zsWorst = (held: 0.0, easing: 0.0)
    for frame in [12, 30, 45, 66, 75, 85, 110] {
        let native = try await nativePicture(zsItem, frame: frame)
        let exported = try await ffmpegPicture(zsExport, graph: nil, frame: frame, width: 1280, height: 720)
        guard let place = zsLarge.state(at: Double(frame) / 30, geometry: zsGeo, endScreen: nil).screen?.rect.insetBy(dx: 30, dy: 30) else { continue }
        var total = 0.0, count = 0
        for y in stride(from: Int(place.minY), to: Int(place.maxY), by: 3) { for x in stride(from: Int(place.minX), to: Int(place.maxX), by: 3) {
            for channel in 0..<3 { total += abs(native.at(x, y, channel) - exported.at(x, y, channel)) }; count += 3 } }
        let time = Double(frame) / 30
        let easing = zsLarge.zooms.contains { time >= $0.start && (time < $0.start + ZoomShot.ease || time > $0.end - ZoomShot.ease) && time < $0.end }
        if easing { zsWorst.easing = max(zsWorst.easing, total / Double(count)) } else { zsWorst.held = max(zsWorst.held, total / Double(count)) }
    }
    print(String(format: "       screen zoom parity: held %.2f, easing %.2f of 255", zsWorst.held, zsWorst.easing))
    check(zsWorst.held < 3.5 && zsWorst.easing < 6, "the export zooms the screen as the preview does, held and easing")
    let zsZoomedFrame = try await nativePicture(zsItem, frame: 30)
    var zsUnzoomedItem = zsItem; zsUnzoomedItem.screen?.zooms = []
    let zsPlainFrame = try await nativePicture(zsUnzoomedItem, frame: 30)
    check(meanDifference(zsZoomedFrame, zsPlainFrame, xs: 200..<1080) > 15, "a screen zoom changes the Preview's screen")
    // Cut, with a zoomed stream wider than the speaker: the two ride through the cuts in one
    // frame as wide as the wider.
    var zsCutItem = zsItem; zsCutItem.segments = [TimelineSegment(start: 0, end: 2), TimelineSegment(start: 3, end: 6)]
    check(FFmpeg.streamSize(zsLarge, place: zsGeo.screenPlace(.screen)!.rect.size).width > CGFloat(ssSpeakerMedia.width),
          "the zoomed screen's stream is wider than the speaker here")
    let zsCutExport = scratch.appendingPathComponent("zs-cut.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: zsCutExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, segments: zsCutItem.segments,
                            settings: ssSettings, screen: zsLarge) { _ in }
    equal(try await frameCount(zsCutExport), 150, "a cut export with a zoomed screen wider than the speaker keeps every edited frame")
    let zsCutNative = try await nativePicture(zsCutItem, frame: 30)
    let zsCutFrame = try await ffmpegPicture(zsCutExport, graph: nil, frame: 30, width: 1280, height: 720)
    check(meanDifference(zsCutNative, zsCutFrame, xs: 4..<1276) < 3.5, "and it matches the preview",
          String(format: "%.2f", meanDifference(zsCutNative, zsCutFrame, xs: 4..<1276)))

    print("\nScreen zoom suggestions")
    var zsSuggestItem = ssItem; zsSuggestItem.segments = nil
    var zsSuggestScreen = ScreenTrack(url: ssScreenURL, info: ssScreenMedia, offset: 1)
    zsSuggestItem.screen = zsSuggestScreen
    var zsFrames = Data()
    for i in 0..<6 { zsFrames.append(contentsOf: i == 2 ? active : still) }
    let zsProposed = ZoomAnalyzer.screenProposals(frames: zsFrames, rate: 2, start: 3, clip: zsSuggestItem)
    check(zsProposed.count == 1 && zsProposed.first.map { abs($0.shot.start - (3 + 1 - 1 - 0.35)) < 0.001 && $0.shot.level == 2
                                                           && abs($0.shot.target.x - 0.78125 * Double(ssScreenMedia.width)) < 8 } == true,
          "activity on the screen becomes a 2× screen zoom at the edited time its footage plays, aimed in screen pixels",
          "\(zsProposed.map(\.shot))")
    zsSuggestScreen.crop = CGRect(x: 0, y: 0, width: 400, height: 300)
    zsSuggestItem.screen = zsSuggestScreen
    check(ZoomAnalyzer.screenProposals(frames: zsFrames, rate: 2, start: 3, clip: zsSuggestItem).isEmpty, "activity outside the screen's crop is ignored")
    var zsActivityScreen = ScreenTrack(url: activityFile, info: activityClip.info!, offset: 0)
    zsActivityScreen.crop = nil
    zsSuggestItem.screen = zsActivityScreen
    let zsDetected = try await ZoomAnalyzer.analyzeScreen(zsSuggestItem)
    check(!zsDetected.isEmpty && zsDetected.allSatisfy { $0.shot.target.x > 200 && $0.shot.end <= zsSuggestItem.editedDuration + 0.001 },
          "Suggest Zooms reads the screen recording and aims at its activity", "\(zsDetected.map(\.shot))")

    print("\nScreen zooms for agents and in the app")
    let zsAgent = AppModel(recoveryURL: nil)
    var zsAgentItem = ssItem; zsAgentItem.segments = nil; zsAgentItem.screen = ssLive
    zsAgent.restore(VideoProject(clips: [ProjectClip(zsAgentItem)], settings: ExportSettings(), selection: zsAgentItem.id))
    @MainActor func zsApply(_ id: String, _ commands: [[String: Any]]) async -> [String: Any] {
        var request = address(zsAgent)
        request["method"] = "apply"; request["requestID"] = id; request["client"] = "Claude"; request["commands"] = commands
        return await agentCall(zsAgent, request)
    }
    let zsClipText = zsAgentItem.id.uuidString
    let zsAdd = await zsApply("zs-add", [["type": "addScreenZoom", "clipID": zsClipText, "start": 0.5, "target": ["x": 600, "y": 200]]])
    let zsAddedID = ((zsAdd["result"] as? [String: Any])?["createdIDs"] as? [String])?.first ?? ""
    check(zsAdd["ok"] as? Bool == true && zsAgent.items[0].screen?.zooms.first.map { $0.level == 2 && $0.hold == 2 } == true,
          "addScreenZoom adds a 2× zoom holding 2 s by default", "\(zsAdd)")
    let zsUpdate = await zsApply("zs-update", [["type": "updateScreenZoom", "clipID": zsClipText, "zoomID": zsAddedID, "level": 3, "hold": 1]])
    check(zsUpdate["ok"] as? Bool == true && zsAgent.items[0].screen?.zooms.first.map { $0.level == 3 && $0.hold == 1 } == true,
          "updateScreenZoom changes only the fields given", "\(zsUpdate)")
    let zsStateZooms = ((agentResult(await agentCall(zsAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["screen"] as? [String: Any])?["zooms"] as? [[String: Any]]
    check(zsStateZooms?.count == 1 && zsStateZooms?.first?["level"] as? Double == 3, "state shows the screen's zooms", "\(zsStateZooms ?? [])")
    let zsReplace = await zsApply("zs-replace", [["type": "replaceScreenZooms", "clipID": zsClipText,
                                                  "zooms": [["start": 0.2, "target": ["x": 100, "y": 100]], ["start": 3.4, "hold": 1.5, "level": 1.5, "target": ["x": 900, "y": 500]]]]])
    check(zsReplace["ok"] as? Bool == true && zsAgent.items[0].screen?.zooms.count == 2, "replaceScreenZooms sets every screen zoom at once", "\(zsReplace)")
    let zsRemoveID = zsAgent.items[0].screen?.zooms.first?.id.uuidString ?? ""
    let zsRemove = await zsApply("zs-remove", [["type": "removeScreenZoom", "clipID": zsClipText, "zoomID": zsRemoveID]])
    check(zsRemove["ok"] as? Bool == true && zsAgent.items[0].screen?.zooms.count == 1, "removeScreenZoom removes one", "\(zsRemove)")
    var zsAnalyze = address(zsAgent)
    zsAnalyze["method"] = "analyze"; zsAnalyze["requestID"] = "zs-analyze"; zsAnalyze["clip"] = zsClipText; zsAnalyze["kind"] = "screenZooms"
    let zsJobReply = await agentCall(zsAgent, zsAnalyze)
    let zsJob = agentResult(zsJobReply)
    let zsJobDone = try await waitForJob(zsAgent, zsJob["id"] as? String ?? "")
    check(zsJobDone["status"] as? String == "succeeded" && (zsJobDone["result"] as? [String: Any])?["kind"] as? String == "screenZooms",
          "analyze with kind screenZooms suggests zooms on the screen as a job", "\(zsJobReply) \(zsJobDone)")
    let zsScreenCommands = AgentCatalog.current.commands.filter { $0.group == "screen" }.map(\.type)
    check(["addScreenZoom", "updateScreenZoom", "removeScreenZoom", "replaceScreenZooms"].allSatisfy(zsScreenCommands.contains),
          "the catalog describes the screen zoom commands")

    zsAgent.setPreviewFraction(0.2 / zsAgent.items[0].editedDuration)
    zsAgent.addScreenZoomAtPlayhead()
    let zsAppShot = zsAgent.selectedScreenZoom
    check(zsAppShot.map { abs($0.start - 0.2) < 0.001 && $0.level == 2 } == true && zsAgent.inspectorFocus == .screenZoom && zsAgent.showPlayback,
          "Add Zoom puts a 2× screen zoom at the playhead, selects it and shows the Preview", "\(String(describing: zsAppShot))")
    if let shot = zsAppShot {
        zsAgent.setScreenZoomLevel(shot.id, 3)
        check(zsAgent.selectedScreenZoom?.level == 3 && zsAgent.showPlayback, "with a screen the Preview stays up after an edit, as only it shows the screen")
        let geometry = LayoutGeometry(track: zsAgent.items[0].screen!, crop: ssSpeakerMedia.fullFrame)
        zsAgent.setPreviewFraction(1.0 / zsAgent.items[0].editedDuration)
        let place = zsAgent.items[0].screen!.state(at: 1.0, geometry: geometry, endScreen: nil).screen!.rect
        let window = zsAgent.items[0].screen!.zoomWindow(at: 1.0)
        let picture = zsAgent.items[0].screen!.picture
        let expected = CGPoint(x: Double(picture.minX + window.minX) + Double(window.width) * 0.25, y: Double(picture.minY + window.minY) + Double(window.height) * 0.75)
        zsAgent.aimScreenZoom(at: CGPoint(x: place.minX + place.width * 0.25, y: place.minY + place.height * 0.75))
        let aimed = zsAgent.selectedScreenZoom?.target
        check(aimed.map { abs($0.x - expected.x) < 2 && abs($0.y - expected.y) < 2 } == true,
              "a click on the screen in the Preview aims the selected screen zoom there, through the zoom on screen", "\(String(describing: aimed)) \(expected)")
    }
    print("\nBubble shape")
    var bsTrack = ScreenTrack(url: URL(fileURLWithPath: "/tmp/screen.mov"), info: ssScreenInfo)
    let bsCircle = LayoutGeometry(track: bsTrack, crop: ssSpeakerInfo.fullFrame).speakerPlace(.screen)
    bsTrack.bubble.shape = .rounded
    let bsRounded = LayoutGeometry(track: bsTrack, crop: ssSpeakerInfo.fullFrame).speakerPlace(.screen)
    check(bsCircle.radius == bsCircle.rect.width / 2 && bsRounded.rect == bsCircle.rect && abs(bsRounded.radius - bsRounded.rect.width * 0.2) < 0.0001,
          "a rounded square is the same square as the circle, with corners 20 % of its side", "\(bsCircle) \(bsRounded)")
    bsTrack.bubble.corners = 0.35
    check(abs(LayoutGeometry(track: bsTrack, crop: ssSpeakerInfo.fullFrame).speakerPlace(.screen).radius - bsRounded.rect.width * 0.35) < 0.0001,
          "the corners follow the setting")
    bsTrack.bubble.corners = 0.2
    bsTrack.spans = [LayoutSpan(start: 0, end: 10, layout: .speaker)]
    let bsGeometry = LayoutGeometry(track: bsTrack, crop: ssSpeakerInfo.fullFrame)
    let bsHalfway = bsTrack.state(at: 10.2, geometry: bsGeometry, endScreen: nil).speaker
    check(bsHalfway.radius > 0 && bsHalfway.radius < bsRounded.radius && bsHalfway.rect.width > bsRounded.rect.width,
          "from the full frame the speaker eases into the rounded square", "\(bsHalfway)")
    var bsSharp = bsTrack; bsSharp.bubble.corners = 0.9
    check(bsSharp.problem(duration: 20, speaker: ssSpeakerInfo)?.contains("corners") == true, "corners outside 0.05–0.45 are refused")
    let bsOld = try JSONDecoder().decode(SpeakerBubble.self, from: Data(#"{"corner": "topLeft", "size": 0.25}"#.utf8))
    check(bsOld.shape == .circle && bsOld.corners == SpeakerBubble.defaultCorners && bsOld.corner == .topLeft,
          "a bubble saved before shapes reads as a circle")

    // Preview and export agree on the soft corners, and the corner of the square shows the speaker.
    var bsLive = ssLive; bsLive.bubble.shape = .rounded
    var bsItem = ssItem; bsItem.segments = nil; bsItem.screen = bsLive
    var bsCircleItem = bsItem; bsCircleItem.screen?.bubble.shape = .circle
    let bsExport = scratch.appendingPathComponent("bs-rounded.mp4")
    try await FFmpeg.export(input: ssSpeakerURL, output: bsExport, info: ssSpeakerMedia, crop: ssSpeakerMedia.fullFrame, settings: ssSettings, screen: bsLive) { _ in }
    let bsNative = try await nativePicture(bsItem, frame: 30)
    let bsExported = try await ffmpegPicture(bsExport, graph: nil, frame: 30, width: 1280, height: 720)
    let bsNativeCircle = try await nativePicture(bsCircleItem, frame: 30)
    check(meanDifference(bsNative, bsExported, xs: 4..<1276) < 3, "the export draws the rounded square as the preview does",
          String(format: "%.2f", meanDifference(bsNative, bsExported, xs: 4..<1276)))
    let bsPlace = LayoutGeometry(track: bsLive, crop: ssSpeakerMedia.fullFrame).speakerPlace(.screen).rect
    func bsCorner(_ a: Picture, _ b: Picture) -> Double {
        var total = 0.0, count = 0
        for y in Int(bsPlace.minY) + 16..<Int(bsPlace.minY) + 24 { for x in Int(bsPlace.minX) + 16..<Int(bsPlace.minX) + 24 {
            for channel in 0..<3 { total += abs(a.at(x, y, channel) - b.at(x, y, channel)) }; count += 3 } }
        return total / Double(count)
    }
    check(bsCorner(bsNative, bsExported) < 6 && bsCorner(bsNative, bsNativeCircle) > 10,
          "near a corner, inside the square but outside the circle, the speaker shows in both renderers",
          String(format: "export %.2f, circle %.2f", bsCorner(bsNative, bsExported), bsCorner(bsNative, bsNativeCircle)))

    let bsAgent = AppModel(recoveryURL: nil)
    var bsAgentItem = ssItem; bsAgentItem.segments = nil; bsAgentItem.screen = ssLive
    bsAgent.restore(VideoProject(clips: [ProjectClip(bsAgentItem)], settings: ExportSettings(), selection: bsAgentItem.id))
    var bsRequest = address(bsAgent)
    bsRequest["method"] = "apply"; bsRequest["requestID"] = "bs-1"; bsRequest["client"] = "Claude"
    bsRequest["commands"] = [["type": "updateScreen", "clipID": bsAgentItem.id.uuidString, "screen": ["bubble": ["shape": "rounded", "corners": 0.25]]]]
    let bsReply = await agentCall(bsAgent, bsRequest)
    let bsState = ((agentResult(await agentCall(bsAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["screen"] as? [String: Any])?["bubble"] as? [String: Any]
    check(bsReply["ok"] as? Bool == true && bsAgent.items[0].screen?.bubble.shape == .rounded && bsAgent.items[0].screen?.bubble.corners == 0.25
              && bsState?["shape"] as? String == "rounded" && bsState?["corners"] as? Double == 0.25,
          "an agent sets the bubble's shape and corners, and state shows them", "\(bsReply) \(bsState ?? [:])")
    bsRequest = address(bsAgent)
    bsRequest["method"] = "apply"; bsRequest["requestID"] = "bs-2"; bsRequest["client"] = "Claude"
    bsRequest["commands"] = [["type": "updateScreen", "clipID": bsAgentItem.id.uuidString, "screen": ["bubble": ["shape": "star"]]]]
    let bsStar = await agentCall(bsAgent, bsRequest)
    check(agentError(bsStar) == "invalid_command" && ((bsStar["error"] as? [String: Any])?["message"] as? String ?? "").contains("circle, rounded"),
          "an unknown shape is refused with the shapes allowed")

}
