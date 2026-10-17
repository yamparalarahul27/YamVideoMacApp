// Checks for thumbnail. Run with ./test.sh thumbnail
import AppKit
import AVFoundation
import Foundation

@MainActor func thumbnailTests() async throws {
    // MARK: - Thumbnails

    print("\nThumbnail design")
    var thumbDesign = ThumbnailDesign(time: 1, title: "Edit for the *viewer*")
    check(thumbDesign.problem == nil, "a plain design is fine")
    var longTitle = thumbDesign; longTitle.title = String(repeating: "x", count: 91)
    var fourLines = thumbDesign; fourLines.title = "a\nb\nc\nd"
    var longTag = thumbDesign; longTag.tag = String(repeating: "t", count: 25)
    var badAccent2 = thumbDesign; badAccent2.accent = "gold"
    var bigZoom = thumbDesign; bigZoom.zoom = 2
    var wideOutline = thumbDesign; wideOutline.outlineWidth = 20
    var bigPicture = thumbDesign; bigPicture.imageSize = 2
    check([longTitle, fourLines, longTag, badAccent2, bigZoom, wideOutline, bigPicture].allSatisfy { $0.problem != nil }
              && bigZoom.problem!.contains("1.6") && longTitle.problem!.contains("90") && wideOutline.problem!.contains("16")
              && bigPicture.problem!.contains("1.6"),
          "a design out of range is refused, saying what is allowed")
    let partialDesign = try JSONDecoder().decode(ThumbnailDesign.self, from: Data(#"{"title": "Hi", "image": "~/x.png"}"#.utf8))
    check(partialDesign.cutout && partialDesign.background == .dim && partialDesign.side == .auto && partialDesign.place == .frame
              && partialDesign.outlineWidth == 9 && !partialDesign.highlight && partialDesign.imageSize == 1
              && partialDesign.image?.path.hasPrefix("/") == true,
          "a partial design keeps the defaults, and an image path is a plain path")

    // A frame with a clear subject on the left: a head and a body on grey.
    let subject = try await subjectFixture()
    let subjectFrame = subject.frame
    let subjectClip = subject.clip
    let subjectImage = NSImage(contentsOf: subjectFrame)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let subjectCut = try SpeakerCutout.cut(subjectImage)
    check(subjectCut.map { $0.box.minX > 150 && $0.box.maxX < 700 && $0.box.minY > 20 && $0.box.maxY > 600 } == true,
          "Apple Vision cuts the subject out, and its box is found", "\(String(describing: subjectCut?.box))")
    let plainFrame = CGImage.blank(width: 640, height: 360)
    check(try SpeakerCutout.cut(plainFrame) == nil, "a frame with nothing in front has no cut-out")

    var thumbnailDesign = ThumbnailDesign(time: 0, title: "Edit for the *viewer*")
    thumbnailDesign.tag = "3 rules"
    let subjectSources = ThumbnailMaker.Sources(frame: subjectImage, cutout: subjectCut)
    let madeThumb = try await ThumbnailMaker.render(thumbnailDesign, sources: subjectSources, accent: "#F5C42C")
    check(madeThumb.width == 1280 && madeThumb.height == 720, "a thumbnail is 1280×720")
    check(brightShare(madeThumb, xs: 660..<1240) > 0.04 && brightShare(madeThumb, xs: 660..<1240) > 2 * brightShare(madeThumb, xs: 40..<640),
          "the title goes on the side away from the speaker", String(format: "right %.3f, left %.3f", brightShare(madeThumb, xs: 660..<1240), brightShare(madeThumb, xs: 40..<640)))
    let litSpeaker = rgb(madeThumb, 420, 440)
    check(litSpeaker.0 > 190 && litSpeaker.1 < 100, "the cut-out speaker stays bright on the darker background", "\(litSpeaker)")
    var noCut = thumbnailDesign; noCut.cutout = false
    let dimThumb = try await ThumbnailMaker.render(noCut, sources: subjectSources, accent: "#F5C42C")
    check(rgb(dimThumb, 420, 440).0 < 140, "without the cut-out the whole frame is darker", "\(rgb(dimThumb, 420, 440))")
    var tagFound = false
    for y in stride(from: 100, to: 400, by: 4) where !tagFound { for x in stride(from: 650, to: 1100, by: 4) {
        let p = rgb(madeThumb, x, y); if p.0 > 220 && p.1 > 170 && p.1 < 215 && p.2 < 90 { tagFound = true; break }
    } }
    check(tagFound, "the tag and the *accent* words use the accent colour")
    var leftText = thumbnailDesign; leftText.side = .left
    let leftThumb = try await ThumbnailMaker.render(leftText, sources: subjectSources, accent: "#F5C42C")
    check(brightShare(leftThumb, xs: 40..<640) > 2 * brightShare(leftThumb, xs: 700..<1240), "the title can be put on the left",
          String(format: "left %.3f, right %.3f", brightShare(leftThumb, xs: 40..<640), brightShare(leftThumb, xs: 700..<1240)))

    // The clear place: the speaker moves away from the title, so nothing overlaps.
    let subjectHead = subjectCut.flatMap { SpeakerCutout.headBox($0.image, box: $0.box) }
    check(subjectHead.map { $0.minX > 280 && $0.maxX < 560 && $0.minY < 80 && $0.maxY < 260 } == true,
          "the head is the top part of the cut-out", "\(String(describing: subjectHead))")
    var clearLeft = leftText; clearLeft.place = .clear; clearLeft.background = .solid; clearLeft.outline = false
    let clearThumb = try await ThumbnailMaker.render(clearLeft, sources: subjectSources, accent: "#F5C42C")
    // Row by row, the title's white and accent pixels stay left of the speaker's red ones.
    let clearRows = rowOverlaps(clearThumb)
    check(rowOverlaps(leftThumb).rows > 3 && clearRows.rows == 0 && clearRows.red > 40 && clearRows.text > 10,
          "with the clear place, a speaker under the title moves to the far side, clear of it",
          "before \(rowOverlaps(leftThumb)), after \(clearRows)")
    let subjectBands = subjectCut.map { SpeakerCutout.bands($0.image, box: $0.box) } ?? []
    check(subjectBands.count >= 20 && subjectBands.first!.width < subjectBands[subjectBands.count / 2].width,
          "the outline bands are narrow at the head and wide at the body", "\(subjectBands.map { Int($0.width) })")
    check(rgb(clearThumb, 1276, 160).0 < 120, "the speaker's head stays inside the picture", "\(rgb(clearThumb, 1276, 160))")
    var clearRight = thumbnailDesign; clearRight.place = .clear; clearRight.background = .solid
    let clearRightThumb = try await ThumbnailMaker.render(clearRight, sources: subjectSources, accent: "#F5C42C")
    check(redShare(clearRightThumb, xs: 200..<600) > 0.15 && redShare(clearRightThumb, xs: 700..<1240) == 0,
          "a speaker already clear of the title stays on their side")

    // The outline's width, the white background and the highlight.
    var thinRight = clearRight; thinRight.outlineWidth = 3
    let thinRightThumb = try await ThumbnailMaker.render(thinRight, sources: subjectSources, accent: "#F5C42C")
    check(whiteNear(thinRightThumb) > 0 && Double(whiteNear(thinRightThumb)) < 0.6 * Double(whiteNear(clearRightThumb)),
          "a narrower outline draws less white round the speaker", "\(whiteNear(thinRightThumb)) against \(whiteNear(clearRightThumb))")
    var whiteDesign = clearLeft; whiteDesign.background = .white
    let whiteThumb = try await ThumbnailMaker.render(whiteDesign, sources: subjectSources, accent: "#F5C42C")
    var markedDesign = whiteDesign; markedDesign.highlight = true
    let markedThumb = try await ThumbnailMaker.render(markedDesign, sources: subjectSources, accent: "#F5C42C")
    let whiteCorner = rgb(whiteThumb, 1270, 8)
    check(whiteCorner.0 > 245 && whiteCorner.1 > 245 && whiteCorner.2 > 245 && titleColours(whiteThumb).dark > 50,
          "a white background, with the title in dark text", "\(whiteCorner), \(titleColours(whiteThumb))")
    check(titleColours(markedThumb).accent > titleColours(whiteThumb).accent + 100 && titleColours(markedThumb).dark > titleColours(whiteThumb).dark,
          "with highlight, the *accent* words are dark text on a band of the accent", "\(titleColours(markedThumb)) against \(titleColours(whiteThumb))")

    // The picture's size: imageSize grows its box, and the title gets smaller to make room.
    let blueRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 340, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: blueRep)
    NSColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 520, height: 340).fill()
    NSGraphicsContext.restoreGraphicsState()
    let bluePicture = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-picture-\(UUID().uuidString).png")
    try blueRep.representation(using: .png, properties: [:])!.write(to: bluePicture)
    defer { try? FileManager.default.removeItem(at: bluePicture) }
    // The blue pixels, and the rows where the blue reaches the speaker's red.
    func blue(_ image: CGImage) -> (count: Int, overlaps: Int) {
        var count = 0, overlaps = 0
        for y in stride(from: 0, to: 720, by: 4) {
            var blueRight = -1, redLeft = Int.max
            for x in stride(from: 0, to: 1280, by: 4) {
                let p = rgb(image, x, y)
                if p.2 > 180 && p.0 < 80 && p.1 < 120 { count += 1; blueRight = max(blueRight, x) }
                if p.0 > 180 && p.1 < 110 && p.2 < 110 { redLeft = min(redLeft, x) }
            }
            if blueRight >= 0 && redLeft <= blueRight + 20 { overlaps += 1 }
        }
        return (count, overlaps)
    }
    var pictured = clearLeft; pictured.image = bluePicture
    var bigPictured = pictured; bigPictured.imageSize = 1.6
    let picturedThumb = try await ThumbnailMaker.render(pictured, sources: subjectSources, accent: "#F5C42C")
    let bigPicturedThumb = try await ThumbnailMaker.render(bigPictured, sources: subjectSources, accent: "#F5C42C")
    let smallBlue = blue(picturedThumb), bigBlue = blue(bigPicturedThumb)
    check(smallBlue.count > 500 && Double(bigBlue.count) > 2 * Double(smallBlue.count)
              && bigBlue.overlaps == 0 && rowOverlaps(bigPicturedThumb).rows == 0,
          "imageSize 1.6 draws the picture larger, and the speaker stays clear of it and of the title",
          "\(smallBlue) against \(bigBlue), \(rowOverlaps(bigPicturedThumb))")

    // White frost: the frame moves with the speaker to the far side; the title side is a white shade.
    var frosted = clearLeft; frosted.background = .frost
    let frostThumb = try await ThumbnailMaker.render(frosted, sources: subjectSources, accent: "#F5C42C")
    let frostShade = rgb(frostThumb, 30, 700), frostFrame = rgb(frostThumb, 1270, 700)
    check(frostShade.0 > 215 && frostShade.1 > 215 && frostShade.2 > 215 && frostFrame.0 < 200
              && redShare(frostThumb, xs: 700..<1240) > 0.1 && redShare(frostThumb, xs: 40..<640) < 0.02
              && titleColours(frostThumb).dark > 50,
          "with the white frost, the speaker and their frame move to the far side, and the title is dark on a white shade",
          "shade \(frostShade), frame \(frostFrame), red \(redShare(frostThumb, xs: 700..<1240)) / \(redShare(frostThumb, xs: 40..<640))")

    print("\nThumbnails in projects and for agents")
    var subjectItem = subject.item
    let thumbnailer = AppModel(recoveryURL: nil)
    thumbnailer.restore(VideoProject(clips: [ProjectClip(subjectItem)], settings: ExportSettings(), selection: subjectItem.id))
    var withDesign = PublishInfo(); withDesign.title = "Subject"; withDesign.design = ThumbnailDesign(time: 1, title: "Big *title*")
    check(thumbnailer.perform([.setPublishInfo(clip: subjectItem.id, info: withDesign)]).isSuccess, "a design is kept with the publish details")
    var lateDesign = withDesign; lateDesign.design?.time = 9
    check(thumbnailer.perform([.setPublishInfo(clip: subjectItem.id, info: lateDesign)]).isFailure, "a frame after the end is refused")
    let designSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(thumbnailer.project))
    check(designSaved == thumbnailer.project && designSaved.version >= 9, "the design survives a version 9 round trip")
    var designAsEight = designSaved; designAsEight.version = 8
    check((try? designAsEight.validate()) == nil, "a version 8 file with a design is refused")
    var frostProject = designSaved
    frostProject.clips[0].publish?.design?.background = .frost; frostProject.clips[0].publish?.design?.imageSize = 1.4
    let frostSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(frostProject))
    var frostAsSixteen = frostSaved; frostAsSixteen.version = 16
    check(frostSaved == frostProject && frostSaved.version == 17 && (try? frostSaved.validate()) != nil && (try? frostAsSixteen.validate()) == nil,
          "the frost and the picture size survive a version 17 round trip, and a version 16 file with them is refused")

    var designPatch = address(thumbnailer)
    designPatch["method"] = "apply"; designPatch["requestID"] = "design-1"; designPatch["client"] = "Claude"
    designPatch["commands"] = [["type": "setPublishInfo", "clipID": subjectItem.id.uuidString, "publish": ["design": ["tag": "New", "zoom": 1.2, "place": "clear"]]]]
    let designReply = await agentCall(thumbnailer, designPatch)
    check(designReply["ok"] as? Bool == true && thumbnailer.items[0].publish?.design?.tag == "New"
              && thumbnailer.items[0].publish?.design?.title == "Big *title*" && thumbnailer.items[0].publish?.design?.zoom == 1.2
              && thumbnailer.items[0].publish?.design?.place == .clear,
          "an agent changes some of the design's keys and keeps the rest", "\(designReply)")
    var tryDesign = address(thumbnailer)
    tryDesign["method"] = "thumbnail"; tryDesign["clip"] = subjectItem.id.uuidString; tryDesign["design"] = ["background": "solid"]
    let tried = agentResult(await agentCall(thumbnailer, tryDesign))
    check(FileManager.default.fileExists(atPath: tried["path"] as? String ?? "") && tried["speakerFound"] as? Bool == true
              && (tried["design"] as? [String: Any])?["background"] as? String == "solid" && tried["savedPath"] == nil
              && thumbnailer.items[0].publish?.design?.background == .dim,
          "an agent tries a design and looks at it without changing anything", "\(tried)")
    tryDesign["design"] = nil; tryDesign["save"] = true
    let savedThumb = agentResult(await agentCall(thumbnailer, tryDesign))
    let savedThumbPath = savedThumb["savedPath"] as? String ?? ""
    check(savedThumbPath.hasPrefix(scratch.path) && savedThumbPath.contains("subject thumbnail") && FileManager.default.fileExists(atPath: savedThumbPath),
          "with save, the thumbnail is saved next to the recording", savedThumbPath)
    check((try? await FFmpeg.probe(url: URL(fileURLWithPath: savedThumbPath)))?.width == 1280, "at 1280×720")
    var badDesign = address(thumbnailer)
    badDesign["method"] = "thumbnail"; badDesign["clip"] = subjectItem.id.uuidString; badDesign["design"] = ["zoom": 3]
    check(((await agentCall(thumbnailer, badDesign))["error"] as? [String: Any])?["message"] as? String ?? "" == "The speaker's size is from 1 to 1.6.",
          "a design out of range is refused before anything is drawn")
    badDesign["design"] = ["outlineWidth": 30]
    check(((await agentCall(thumbnailer, badDesign))["error"] as? [String: Any])?["message"] as? String ?? "" == "The outline's width is from 2 to 16 pixels.",
          "an outline too wide is refused")

    print("\nSuggest Frames")
    let smiling = face([CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.35, y: 0.28), CGPoint(x: 0.45, y: 0.25), CGPoint(x: 0.55, y: 0.28),
                        CGPoint(x: 0.65, y: 0.35), CGPoint(x: 0.45, y: 0.40)])
    let talking = face([CGPoint(x: 0.35, y: 0.27), CGPoint(x: 0.42, y: 0.23), CGPoint(x: 0.5, y: 0.22), CGPoint(x: 0.58, y: 0.23),
                        CGPoint(x: 0.65, y: 0.27), CGPoint(x: 0.5, y: 0.40)])
    let blinking = face([CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.35, y: 0.28), CGPoint(x: 0.45, y: 0.25), CGPoint(x: 0.55, y: 0.28),
                         CGPoint(x: 0.65, y: 0.35), CGPoint(x: 0.45, y: 0.40)], eyeHeight: 0.008)
    let turned = face([CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.35, y: 0.28), CGPoint(x: 0.45, y: 0.25), CGPoint(x: 0.55, y: 0.28),
                       CGPoint(x: 0.65, y: 0.35), CGPoint(x: 0.45, y: 0.40)], nose: 0.56)
    check(smiling.map { $0.smile > 0.8 && $0.eyes > 0.8 && $0.facing > 0.95 } == true && talking.map { $0.smile < 0.1 } == true,
          "a wide mouth with its corners up is a smile; a narrow open mouth is not", "\(String(describing: smiling)) \(String(describing: talking))")
    check(blinking.map { $0.eyes < 0.15 && $0.score < 0.4 * smiling!.score } == true && turned.map { $0.facing < 0.1 && $0.score < smiling!.score } == true,
          "closed eyes rule a frame out, and a face turned away scores lower")
    check(FaceLook.measure(lips: [], leftEye: [], rightEye: [], nose: [], quality: 1, face: .zero) == nil, "a face without landmarks is not measured")

    let framesTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 10), TimelineSegment(start: 20, end: 30)])
    check(FrameAnalyzer.edited(5, in: framesTimeline) == 5 && FrameAnalyzer.edited(25, in: framesTimeline) == 15
              && FrameAnalyzer.edited(15, in: framesTimeline) == nil && FrameAnalyzer.edited(9.95, in: framesTimeline) == nil
              && FrameAnalyzer.edited(20.05, in: framesTimeline) == nil,
          "a source time maps to its edited time; cut footage and frames next to a cut are left out")
    equal(FrameAnalyzer.pick([(1, 0.9), (2, 0.95), (5, 0.5), (9, 0.8)], count: 3, spacing: 3), [1, 3, 2],
          "the best moments are picked first, at least the spacing apart")

    let framesFolder = scratch.appendingPathComponent("frames-test", isDirectory: true)
    let nearFrames = try await FrameAnalyzer.frames(["-ss", "0.5", "-t", "1", "-i", subjectClip.path, "-an", "-vf", "fps=10,scale=320:-2,showinfo"],
                                                    into: framesFolder, start: 0.5)
    check(nearFrames.count >= 9 && abs((nearFrames.first?.source ?? 0) - 0.5) < 0.06 && abs(nearFrames[min(5, nearFrames.count - 1)].source - 1.0) < 0.06
              && nearFrames.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
          "frames are read with their source times", "\(nearFrames.map(\.source))")
    let keyFrames = try await FrameAnalyzer.frames(["-skip_frame", "nokey", "-i", subjectClip.path, "-an", "-vf", "showinfo", "-fps_mode", "passthrough"],
                                                   into: framesFolder.appendingPathComponent("keys"))
    check(keyFrames.first.map { abs($0.source) < 0.01 } == true, "key frames are read with their times", "\(keyFrames.map(\.source))")
    check(try await FrameAnalyzer.analyze(subjectItem).isEmpty, "a recording with no face gives no suggestions")

    var framesRequest = address(thumbnailer)
    framesRequest["method"] = "analyze"; framesRequest["kind"] = "thumbnailFrames"; framesRequest["clip"] = subjectItem.id.uuidString
    framesRequest["requestID"] = "frames-1"
    let framesStarted = agentResult(await agentCall(thumbnailer, framesRequest))
    let framesJob = try await waitForJob(thumbnailer, framesStarted["id"] as? String ?? "")
    let framesResult = framesJob["result"] as? [String: Any] ?? [:]
    check(framesJob["status"] as? String == "succeeded" && framesResult["kind"] as? String == "thumbnailFrames"
              && (framesResult["suggestions"] as? [Any])?.isEmpty == true && (framesResult["note"] as? String)?.contains("no face") == true,
          "an agent asks for thumbnail frames as a job, and hears when there is no face", "\(framesJob)")
    framesRequest["requestID"] = "frames-2"; framesRequest["limit"] = 30
    check(((await agentCall(thumbnailer, framesRequest))["error"] as? [String: Any])?["message"] as? String == "limit for thumbnailFrames is from 1 to 20.",
          "too many frames is refused")

    print("\nAgents Manual")
    let manualReply = agentResult(await agentCall(thumbnailer, ["method": "manual"]))
    let manualText = manualReply["text"] as? String ?? ""
    check(manualText.hasPrefix("# YamVideo Agents Manual") && manualText.contains("thumbnailFrames") && manualText.contains("revision_conflict")
              && FileManager.default.fileExists(atPath: manualReply["path"] as? String ?? ""),
          "an agent reads the Agents Manual from the app", String(manualText.prefix(80)))
    let manualCatalog = AgentCatalog.current
    check(manualCatalog.methods.first?.method == "manual" && manualCatalog.workflow.first?.contains("manual") == true
              && AppModel.agentMethods.contains("manual"),
          "the catalog sends agents to the manual first")
    check(manualCatalog.methods.first { $0.method == "analyze" }.map { "\($0)".contains("thumbnailFrames") } == true,
          "the catalog lists thumbnailFrames")
    check(AgentsManual.brief(ctl: "/x/yamvideoctl").contains("/x/yamvideoctl manual") && AgentsManual.brief(ctl: nil).contains("yamvideo_manual"),
          "the brief for an agent names how to read the manual")


}
