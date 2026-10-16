// Checks for shorts. Run with ./test.sh shorts
import AppKit
import AVFoundation
import Foundation

@MainActor func shortsTests() async throws {
    let (moveClip, moveInfo, moveTrack) = try await moveFixture()
    var subjectItem = try await subjectFixture().item
    // MARK: - Shorts

    print("\nShorts: rules")
    let shortSource = try await makeClip("short-source.mov", size: "1280x720", seconds: 12, audio: "aac")
    let shortInfo = try await FFmpeg.probe(url: shortSource)
    let defaultWindow = ShortFormat.defaultWindow(in: shortInfo.fullFrame, info: shortInfo)
    check(defaultWindow.height == 720 && abs(defaultWindow.width / defaultWindow.height - 9.0 / 16) < 0.01 && abs(defaultWindow.midX - 640) <= 2,
          "a Short's window is the full height of the picture, 9:16, centred", "\(defaultWindow)")
    let shFourK = MediaInfo(width: 3840, height: 2160, duration: 10, videoCodec: "h264", audioCodec: nil, fps: 30, fpsExpression: "30", rotation: 0)
    check(ShortFormat.defaultWindow(in: shFourK.fullFrame, info: shFourK).size == CGSize(width: 1216, height: 2160),
          "from 4K the window is 1216×2160, made 1080×1920", "\(ShortFormat.defaultWindow(in: shFourK.fullFrame, info: shFourK))")
    let nearEdge = ShortFormat.window(centre: CGPoint(x: 1270, y: 300), height: 360, in: shortInfo.fullFrame, info: shortInfo)
    check(nearEdge.maxX <= 1280 && nearEdge.height == 360 && abs(nearEdge.width / nearEdge.height - 9.0 / 16) < 0.01,
          "a tighter window near the edge stays inside the picture", "\(nearEdge)")
    check(Short(start: 1, end: 3).problem(duration: 12, info: shortInfo) == nil, "a plain Short is fine")
    check(Short(start: 0, end: 200).problem(duration: 300, info: shortInfo)?.contains("3:00") == true,
          "a Short over 3:00 is refused, saying YouTube's limit")
    check(Short(start: 1, end: 1.5).problem(duration: 12, info: shortInfo)?.contains("at least 1") == true, "a Short under a second is refused")
    check(Short(start: 1, end: 3, window: CGRect(x: 0, y: 0, width: 600, height: 720)).problem(duration: 12, info: shortInfo)?.contains("9:16") == true,
          "a window that is not 9:16 is refused, saying so")
    check(Short(start: 1, end: 3, window: CGRect(x: 1000, y: 0, width: 406, height: 720)).problem(duration: 12, info: shortInfo)?.contains("inside") == true,
          "a window outside the picture is refused")
    check(shortsProblem([Short(start: 0, end: 5), Short(start: 4, end: 8)], duration: 12, info: shortInfo)?.contains("overlap") == true,
          "Shorts of one recording may not overlap")
    let placedID = UUID()
    let partialShort = try JSONDecoder().decode(Short.self, from: Data("""
        {"start": 1, "end": 4, "placements": {"\(placedID.uuidString)": {"x": 10, "y": -20, "scale": 1.2}}}
        """.utf8))
    check(partialShort.panels == .sheet && partialShort.captions == .stepUp && partialShort.title.isEmpty && partialShort.window == nil
              && partialShort.placements[placedID] == GraphicTransform(x: 10, y: -20, scale: 1.2),
          "a partial Short keeps the defaults, and placements are keyed by graphic id")
    let encodedShort = String(decoding: try JSONEncoder().encode(partialShort), as: UTF8.self)
    check(encodedShort.contains(placedID.uuidString) && (try? JSONDecoder().decode(Short.self, from: Data(encodedShort.utf8))) == partialShort,
          "a Short round-trips", encodedShort)

    var shortItemSource = VideoItem(url: shortSource)
    shortItemSource.info = shortInfo; shortItemSource.crop = shortInfo.fullFrame; shortItemSource.status = .ready
    check(shortItemSource.newShortSpan(at: 5).map { $0 == (0, 12) } == true, "a new Short covers a whole recording under 3:00")
    var longerItem = shortItemSource
    longerItem.segments = [TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12),
                           TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12),
                           TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12),
                           TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12),
                           TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12), TimelineSegment(start: 0, end: 12),
                           TimelineSegment(start: 0, end: 12)]
    check(longerItem.newShortSpan(at: 30).map { $0 == (30, 90) } == true, "on a longer recording it is a minute from the playhead")
    longerItem.shorts = [Short(start: 60, end: 100)]
    check(longerItem.newShortSpan(at: 70).map { $0 == (100, 160) } == true && longerItem.newShortSpan(at: 20).map { $0 == (20, 60) } == true,
          "and it starts after a Short the playhead is in, and stops at the next one")

    var versionProject = VideoProject(clips: [ProjectClip({ var item = shortItemSource; item.shorts = [Short(start: 1, end: 6)]; return item }())],
                                      settings: ExportSettings(), selection: shortItemSource.id)
    let versionData = try JSONEncoder().encode(versionProject)
    check((try? VideoProject.decodeMigrating(from: versionData))?.clips[0].shorts?.first?.end == 6, "a project with Shorts round-trips as version 12")
    versionProject.version = 11
    do { try versionProject.validate(); check(false, "a version 11 project with Shorts is refused") }
    catch { check(error.localizedDescription.contains("Shorts"), "an older version claiming Shorts is refused", error.localizedDescription) }

    var zoomVersionShort = Short(start: 1, end: 6); zoomVersionShort.zoom = 0.75
    var zoomProject = VideoProject(clips: [ProjectClip({ var item = shortItemSource; item.shorts = [zoomVersionShort]; return item }())],
                                   settings: ExportSettings(), selection: shortItemSource.id)
    check((try? VideoProject.decodeMigrating(from: JSONEncoder().encode(zoomProject)))?.clips[0].shorts?.first?.zoom == 0.75,
          "a zoomed-out Short round-trips as version 13")
    zoomProject.version = 12
    do { try zoomProject.validate(); check(false, "a version 12 project with a zoomed-out Short is refused") }
    catch { check(error.localizedDescription.contains("zoomed-out"), "an older version claiming a zoomed-out Short is refused", error.localizedDescription) }

    print("\nShorts through cuts")
    let shWholeTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 12)])
    let pauseCut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4), TimelineSegment(start: 5, end: 12)])
    let shInside = pauseCut.remap([Short(start: 2, end: 8)], from: shWholeTimeline, fps: 30)
    check(shInside.shorts.first.map { $0.start == 2 && abs($0.end - 7) < 0.001 } == true && shInside.removed.isEmpty,
          "a pause cut inside a Short makes it shorter", "\(shInside)")
    let shBefore = ClipTimeline(segments: [TimelineSegment(start: 1, end: 12)]).remap([Short(start: 2, end: 8)], from: shWholeTimeline, fps: 30)
    check(shBefore.shorts.first.map { abs($0.start - 1) < 0.001 && abs($0.end - 7) < 0.001 } == true, "a cut before it moves it with its footage")
    let startCut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 1.5), TimelineSegment(start: 2.5, end: 12)])
        .remap([Short(start: 2, end: 8)], from: shWholeTimeline, fps: 30)
    check(startCut.shorts.first.map { abs($0.start - 1.5) < 0.001 && abs($0.end - 7) < 0.001 } == true,
          "a cut through its start keeps it from the first frame that is left", "\(startCut)")
    let gone = ClipTimeline(segments: [TimelineSegment(start: 0, end: 2), TimelineSegment(start: 8, end: 12)])
        .remap([Short(start: 2, end: 8)], from: shWholeTimeline, fps: 30)
    check(gone.shorts.isEmpty && gone.removed.count == 1, "a Short whose footage is all cut away is dropped and reported")
    var reducerProject = VideoProject(clips: [ProjectClip({ var item = shortItemSource; item.shorts = [Short(start: 2, end: 8)]; return item }())],
                                      settings: ExportSettings(), selection: shortItemSource.id)
    let reducerCut = try ProjectReducer.apply([.replaceSections(clip: shortItemSource.id, sections: [TimelineSegment(start: 0, end: 2), TimelineSegment(start: 8, end: 12)])],
                                              to: reducerProject)
    check(reducerCut.removedShorts.count == 1 && reducerCut.project.clips[0].shorts == nil, "cutting a Short's footage away reports it in removedShorts")
    reducerProject.clips[0].shorts = [Short(start: 2, end: 8)]

    print("\nGraphics in a Short")
    let earlyPlate = gfx(.namePlate, 0.5, 2.5), plateInShort = gfx(.namePlate, 3.0, 6.0), ruleInShort = gfx(.rule, 4.0, 7.0)
    let linkInShort = gfx(.link, 8.0, 11.5), screenAtEnd = gfx(.endScreen, 9.6, 12.0, EndScreen.defaultProps)
    let showTrack = GraphicsTrack(items: [earlyPlate, plateInShort, ruleInShort, linkInShort])
    var showShort = Short(start: 2.8, end: 9)
    showShort.hidden = [linkInShort.id]
    showShort.placements = [plateInShort.id: GraphicTransform(x: 0, y: -100, scale: 1.1)]
    let laidOut = showTrack.forShort(showShort)
    check(laidOut.items.map(\.id) == [plateInShort.id, ruleInShort.id] && abs(laidOut.items[0].start - 0.2) < 0.0001
              && laidOut.items[0].transform == GraphicTransform(x: 0, y: -100, scale: 1.1) && laidOut.items[1].transform == nil
              && laidOut.canvas == .short(.sheet),
          "a Short shows the graphics that start inside it, in its own time, with its own placements; hidden ones and earlier ones stay out")
    var clipped = Short(start: 2.8, end: 5); clipped.panels = .split
    let clippedTrack = showTrack.forShort(clipped)
    check(clippedTrack.items.count == 2 && abs(clippedTrack.items[0].end - 2.2) < 0.0001 && abs(clippedTrack.items[1].end - 2.2) < 0.0001
              && clippedTrack.canvas == .short(.split),
          "a graphic running past the Short's end ends with it")
    check(GraphicsTrack(items: [screenAtEnd]).forShort(Short(start: 6, end: 12)).items.isEmpty, "Shorts have no end screen, so it is left out")
    let laidOutData = String(decoding: try laidOut.engineData(duration: 6.2, fps: "30"), as: UTF8.self)
    check(laidOutData.contains(#""layout":{"canvas":"short","drop":0,"panels":"sheet"}"#), "the engine is told to lay them out on the 9:16 canvas", laidOutData)
    var zoomedOut = laidOut; zoomedOut.canvas = .short(.sheet, zoom: 0.75)
    check(String(decoding: try zoomedOut.engineData(duration: 6.2, fps: "30"), as: UTF8.self).contains(#""drop":100"#),
          "zoomed out, it is told how much lower the cards and the sheet sit")
    check(GraphicsRender.jobs(for: laidOut, fps: "30", outputWidth: 1080).allSatisfy { $0.unit.track.canvas == .short(.sheet) && $0.scale == 1 }
              && Set(GraphicsRender.jobs(for: laidOut, fps: "30", outputWidth: 1080).map(\.key)).isDisjoint(with: Set(GraphicsRender.jobs(for: GraphicsTrack(items: laidOut.items), fps: "30", outputWidth: 1080).map(\.key))),
          "a Short's graphics are drawn as units of their own, not reusing the 16:9 frames")

    var cutSource = shortItemSource
    cutSource.segments = [TimelineSegment(start: 0, end: 4), TimelineSegment(start: 5, end: 12)]
    cutSource.zoomShots = [ZoomShot(start: 5.0, hold: 1, level: 2, target: CGPoint(x: 640, y: 360)), ZoomShot(start: 0.2, hold: 0.5, level: 2, target: CGPoint(x: 640, y: 360))]
    cutSource.blurEffects = [VideoBlurEffect(start: 2, end: 9.5)]
    cutSource.graphics = showTrack
    cutSource.shorts = [showShort]
    let shortCut = cutSource.shortItem(showShort)
    check(abs(shortCut.editedDuration - showShort.length) < 0.001 && shortCut.segments?.count == 2 && shortCut.segments?.first?.start == 2.8
              && shortCut.crop == showShort.frame(info: shortInfo, crop: cutSource.crop),
          "a Short's edit is its part of the sections, with its window as the crop", "\(String(describing: shortCut.segments))")
    check(shortCut.zoomShots.count == 1 && abs(shortCut.zoomShots[0].start - 2.2) < 0.0001
              && shortCut.blurEffects.first.map { abs($0.start) < 0.0001 && abs($0.end - 6.2) < 0.0001 } == true
              && shortCut.publish == nil && shortCut.shorts.isEmpty && shortCut.graphics?.items.count == 2,
          "zooms inside it, its part of a blur effect and its graphics come along in its own time")

    if let nodeBinary {
        for zoom in [1.0, 0.75, 0.5625] {
            let drop = ShortLayout(panels: .sheet, zoom: zoom).drop
            let script = "const g=require(process.argv[1]);console.log(JSON.stringify(['sheet','shade','split'].map(p=>{const l=g.shortLayout(p,\(drop));"
                + "return [l.column.x,l.column.y,l.column.scale,l.panel.x,l.panel.y,l.panel.scale,l.sheetTop,l.lift,l.splitFrame.x,l.splitFrame.y,l.splitFrame.w,l.splitFrame.h,l.captionBottom,l.stage.width,l.stage.height]})))"
            let engine = try await Shell.run(nodeBinary, ["-e", script, "\(repository)/Resources/Graphics/graphics.js"])
            let swift = ShortPanels.allCases.map { panels -> [Double] in
                let layout = ShortLayout(panels: panels, zoom: zoom), column = layout.cardZone, panel = layout.panel, frame = ShortLayout.splitFrame
                return [column.origin.x, column.origin.y, column.scale, panel.origin.x, panel.origin.y, panel.scale, layout.sheetLine, ShortLayout.lift,
                        frame.minX, frame.minY, frame.width, frame.height, layout.captionSpot, ShortFormat.size.width, ShortFormat.size.height]
            }
            let parsed = (try? JSONSerialization.jsonObject(with: engine.stdout) as? [[Double]]) ?? []
            check(parsed == swift, "the engine and the app lay a Short out with the same numbers (zoom \(zoom))", engine.stdoutText)
        }
    }
    let splitLayout = ShortLayout.splitFrame
    check(abs(splitLayout.width / splitLayout.height - 9.0 / 16) < 0.001 && abs(splitLayout.midX - 540) < 1 && splitLayout.maxY < 960,
          "the split frame is 9:16, centred in the top half")
    for panels in ShortPanels.allCases {
        let zone = ShortLayout(panels: panels).panel
        let content = CGRect(x: zone.origin.x + 88 * zone.scale, y: zone.origin.y + 92 * zone.scale, width: 800 * zone.scale, height: 858 * zone.scale)
        check(content.minX >= ShortFormat.clearArea.minX - 1 && content.maxX <= ShortFormat.clearArea.maxX + 1 && content.minY >= ShortFormat.clearArea.minY,
              "\(panels.label) panels keep their content clear of YouTube's rail and top icons", "\(content)")
    }

    print("\nCaptions in a Short")
    let longCaption = Caption(start: 0, end: 4, text: "This is a much longer caption that will not fit on two short lines at all")
    let fitted = ShortCaptionLayout.fit([longCaption], size: .medium)
    let shLimit = ShortCaptionLayout.lineCharacters(.medium)
    check(fitted.count >= 2 && fitted.allSatisfy { piece in piece.text.components(separatedBy: "\n").count <= 2
              && piece.text.components(separatedBy: "\n").allSatisfy { $0.count <= shLimit } }
              && fitted.first?.start == 0 && fitted.last?.end == 4 && zip(fitted, fitted.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.000001 },
          "a long caption is shown in pieces of two short lines, sharing its time", "\(fitted)")
    check(ShortCaptionLayout.fontSize(.medium) == 72 && ShortCaptionLayout.fontSize(.large) == 90 && shLimit >= 16 && shLimit <= 22
              && Double(shLimit) * 72 * 0.6 <= ShortFormat.clearArea.width,
          "captions in a Short are sized for a phone: 72 px for Medium, about 18 characters a line, within the clear area", "\(shLimit)")
    let clearShort = ShortFormat.clearArea, furnitureShort = ShortFormat.furniture
    check(clearShort.minX == furnitureShort.left && clearShort.minY == furnitureShort.top && clearShort.maxX == 1080 - furnitureShort.right
              && clearShort.maxY == 1920 - furnitureShort.bottom && ShortLayout.captionBottom <= clearShort.maxY
              && ShortFormat.railTop > ShortLayout.splitFrame.maxY,
          "the clear area is what YouTube's Shorts player leaves, and the captions' spot is inside it", "\(clearShort)")
    check(ShortCaptionLayout.margins.left == 48 && ShortCaptionLayout.margins.right == 192,
          "captions are centred in the clear area, left of YouTube's like and share rail")
    let cardShort = GraphicsTrack(items: [gfx(.namePlate, 1, 3)], canvas: .short(.sheet))
    let spoken = [Caption(start: 0, end: 2, text: "Over the card"), Caption(start: 3.5, end: 4.5, text: "After it")]
    let stepped = ShortCaptionLayout.layout(spoken, graphics: cardShort, option: .stepUp, size: .medium)
    check(stepped.count == 3 && stepped[0].bottom == 1320 && stepped[0].end == 1 && stepped[1].bottom == ShortLayout.column.origin.y - 24
              && stepped[1].start == 1 && stepped[2].bottom == 1320,
          "with Step up, captions move above a card while it shows and come back after", "\(stepped)")
    let over = ShortCaptionLayout.layout(spoken, graphics: cardShort, option: .over, size: .medium)
    check(over.count == 2 && over.allSatisfy { $0.bottom == ShortLayout.captionBottom }, "with Stay over they keep the safe-area spot")
    let hidden = ShortCaptionLayout.layout(spoken, graphics: cardShort, option: .hide, size: .medium)
    check(hidden.count == 2 && hidden[0].end == 1 && hidden[1].start == 3.5, "with Hide they pause while the card shows", "\(hidden)")
    func panelLine(_ panels: ShortPanels) -> Double {
        ShortCaptionLayout.layout([Caption(start: 1.5, end: 2.5, text: "During the panel")],
                                  graphics: GraphicsTrack(items: [gfx(.rule, 1, 3)], canvas: .short(panels)), option: .stepUp, size: .medium).first?.bottom ?? -1
    }
    check(panelLine(.sheet) == ShortLayout.sheetTop - 24 && panelLine(.shade) == ShortLayout.captionBottom && panelLine(.split) == ShortLayout.splitFrame.maxY - 16,
          "over a bottom sheet they step above it; a full shade leaves them be; in a split they sit at the frame's foot",
          "\(panelLine(.sheet)) \(panelLine(.shade)) \(panelLine(.split))")
    print("\nCaptions in Shorts, on their own")
    var scNone = ExportSettings(), scUpload = ExportSettings(), scOff = ExportSettings(), scShortUpload = ExportSettings(), scShortOff = ExportSettings()
    scUpload.captions = .upload; scOff.captions = .off
    scShortUpload.captions = .upload; scShortUpload.shortCaptions = .upload
    scShortOff.captions = .burnIn; scShortOff.shortCaptions = .off
    check(scNone.shortCaptionUse(hasFile: false) == .off && scNone.shortCaptionUse(hasFile: true) == .burnIn
              && scUpload.shortCaptionUse(hasFile: false) == .burnIn && scOff.shortCaptionUse(hasFile: true) == .off
              && scShortUpload.shortCaptionUse(hasFile: false) == .upload && scShortOff.shortCaptionUse(hasFile: true) == .off,
          "Shorts burn captions in whenever the video has captions, unless their own setting says otherwise")
    var scItem = VideoItem(url: landscape); scItem.info = info; scItem.crop = info.fullFrame
    scItem.transcript = Transcript(model: "t", language: "en", words: spokenWords([("Hello", 0.2), ("there", 0.6), ("viewer", 1.0)], end: 1.6))
    let scShort = Short(start: 0, end: 2)
    check(scItem.burnedCaptions(scUpload) == nil && scItem.shortCaptionOverlay(scShort, settings: scUpload) != nil
              && !scItem.shortCaptions(scShort, settings: scUpload).isEmpty,
          "a video that uploads its SRT has Shorts with burned-in captions, and their SRT too")
    check(scItem.shortCaptionOverlay(scShort, settings: scShortUpload) == nil && !scItem.shortCaptions(scShort, settings: scShortUpload).isEmpty
              && scItem.shortCaptions(scShort, settings: scShortOff).isEmpty && scItem.shortCaptionOverlay(scShort, settings: scShortOff) == nil,
          "Shorts set to upload keep only the SRT; Shorts set to none have no captions")
    let scCoded = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(scShortUpload))
    let scOld = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(ExportSettings()))
    check(scCoded.shortCaptions == .upload && scOld.shortCaptions == nil && AppModel.exportSettingKeys.contains("shortCaptions"),
          "the Shorts' caption setting is saved, an older project reads as unset, and agents can set it")

    print("\nZooming a Short out")
    let zoomedLayout = ShortLayout(panels: .sheet, zoom: 0.75)
    check(ShortLayout(panels: .sheet).drop == 0 && zoomedLayout.drop == 100 && ShortLayout(panels: .sheet, zoom: 0.5625).drop == 175
              && zoomedLayout.cardZone.origin.y == 860 && zoomedLayout.panel.origin.y == 817 && zoomedLayout.sheetLine == 800 && zoomedLayout.captionSpot == 1420
              && ShortLayout(panels: .shade, zoom: 0.75).panel.origin.y == 312 && ShortLayout(panels: .sheet, zoom: 0.5625).captionSpot <= ShortFormat.clearArea.maxY,
          "zoomed out, the cards, the bottom sheet and the captions sit lower, still clear of YouTube's text; the full shade stays put")
    let zoomedCard = GraphicsTrack(items: [gfx(.namePlate, 1, 3)], canvas: .short(.sheet, zoom: 0.75))
    let zoomedSteps = ShortCaptionLayout.layout(spoken, graphics: zoomedCard, option: .stepUp, size: .medium)
    check(zoomedSteps.count == 2 && zoomedSteps.allSatisfy { $0.bottom == 1420 },
          "zoomed out, captions stay below a card, under the face, rather than step up over it", "\(zoomedSteps)")
    let zoomedSheet = ShortCaptionLayout.layout([Caption(start: 1.5, end: 2.5, text: "During the panel")],
                                                graphics: GraphicsTrack(items: [gfx(.rule, 1, 3)], canvas: .short(.sheet, zoom: 0.75)), option: .stepUp, size: .medium)
    check(zoomedSheet.first?.bottom == 776, "over the lower bottom sheet they step above it", "\(zoomedSheet)")
    let zoomedMotion = GraphicsMotion({ var track = GraphicsTrack(items: [gfx(.rule, 1, 3)], canvas: .short(.sheet, zoom: 0.75)); track.style.panel = .shade; return track }())
    check(zoomedMotion?.drop == 100 && zoomedMotion.flatMap { $0.frostRamp(for: $0.spans[0]) }.map { abs($0.from * 1920 - 800) < 0.001 } == true,
          "the frost under the lower sheet starts where it does")

    let assText = ShortCaptionLayout.ass(stepped, size: .medium)
    check(assText.contains("PlayResX: 1080") && assText.contains("PlayResY: 1920") && assText.contains("WrapStyle: 2")
              && assText.contains("Style: Short,Helvetica,85,") && assText.contains(",2,48,192,600,1\n")
              && assText.contains("Dialogue: 0,0:00:01.00,0:00:02.00,Short,,0,0,1184,,Over the card"),
          "the ASS file places each caption on the Short's own pixel grid", assText)
    let groupedWords = spokenWords([("One", 0), ("two", 0.3), ("three", 0.6), ("four", 0.9), ("five", 1.2), ("six", 1.5), ("seven", 1.8),
                                    ("eight", 2.1), ("nine", 2.4), ("ten", 2.7), ("eleven", 3.0), ("twelve", 3.3)], end: 4)
    let grouped = Transcript(model: "t", language: "en", words: groupedWords).captions(timeline: shWholeTimeline, characters: ShortCaptionLayout.groupCharacters)
    check(grouped.count >= 2 && grouped.allSatisfy { $0.text.replacingOccurrences(of: "\n", with: " ").count <= ShortCaptionLayout.groupCharacters },
          "captions from the transcript are grouped for a phone", "\(grouped.map(\.text))")

    print("\nShort panels: preview and export agree")
    for panels in ShortPanels.allCases {
        var parityShortItem = VideoItem(url: moveClip)
        parityShortItem.info = moveInfo; parityShortItem.crop = moveInfo.fullFrame; parityShortItem.status = .ready
        parityShortItem.graphics = moveTrack
        var parityShort = Short(start: 0, end: 4.5); parityShort.panels = panels
        parityShortItem.shorts = [parityShort]
        let window = parityShort.frame(info: moveInfo, crop: moveInfo.fullFrame)
        let shortCutItem = parityShortItem.shortItem(parityShort)
        let w = Int(window.width), h = Int(window.height)
        guard let motion = GraphicsMotion(shortCutItem.graphics) else { check(false, "\(panels.label): the Short's panels move the picture"); continue }
        let stage = try FFmpeg.moveStage(motion, frame: window.size, fps: 30, fpsExpression: "30", duration: 4.5, tags: FrameTags(info: moveInfo, converted: false))
        let graph = "[0:v]crop=\(w):\(h):\(Int(window.minX)):\(Int(window.minY))[cropped];"
            + stage.parts.joined(separator: ";").replacingOccurrences(of: "[mvin]", with: "[cropped]")
        var worst = (offset: 0, frame: 0.0)
        for frame in [33, 42, 57, 66, 78, 108] {
            let native = try await nativePicture(shortCutItem, frame: frame)
            let exported = try await ffmpegPicture(moveClip, graph: graph, frame: frame, width: w, height: h)
            // Lined up over the whole frame, both ways: the lift moves it up, the split shrinks it.
            var best = (offset: 0, mean: Double.infinity)
            for dy in -3...3 {
                var total = 0.0, count = 0
                for y in stride(from: 12, to: h - 12, by: 4) { for x in stride(from: 8, to: w - 8, by: 3) {
                    for channel in 0..<3 { total += abs(native.at(x, y, channel) - exported.at(x, y + dy, channel)) }; count += 3
                } }
                if total / Double(count) < best.mean { best = (dy, total / Double(count)) }
            }
            worst.offset = max(worst.offset, abs(best.offset))
            worst.frame = max(worst.frame, meanDifference(native, exported, xs: 4..<(w - 4)))
        }
        print(String(format: "       %@ parity: worst offset %d px, whole frame %.2f of 255", panels.label, worst.offset, worst.frame))
        check(worst.offset <= 2 && worst.frame < 3.5, "\(panels.label): the export moves and frosts the Short's picture as the preview does",
              String(format: "offset %d, frame %.2f", worst.offset, worst.frame))
        let still = try await ffmpegPicture(moveClip, graph: graph, frame: 15, width: w, height: h)
        let plain = try await ffmpegPicture(moveClip, graph: "[0:v]crop=\(w):\(h):\(Int(window.minX)):\(Int(window.minY)),format=yuv420p10le[mvout]",
                                            frame: 15, width: w, height: h)
        check(meanDifference(still, plain, xs: 0..<w) < 0.05, "\(panels.label): away from panels the picture is left alone")
    }
    var liftCheck = GraphicsTrack(items: [gfx(.rule, 1, 2)], canvas: .short(.sheet))
    liftCheck.style.moveVideo = false
    check(GraphicsMotion(liftCheck) == nil && GraphicsMotion(GraphicsTrack(items: [gfx(.rule, 1, 2)], canvas: .short(.shade)))?.short == .shade,
          "without Move video aside a bottom sheet leaves the picture still; a full shade always frosts it")

    print("\nA zoomed-out Short")
    var zoomCheck = Short(start: 0, end: 4.5)
    let fillWindow = zoomCheck.frame(info: moveInfo, crop: moveInfo.fullFrame)
    check(zoomCheck.picture(info: moveInfo, crop: moveInfo.fullFrame) == fillWindow && ShortFormat.stage(for: fillWindow.size) == nil,
          "a Short that fills the frame reads its window, which is its own stage")
    zoomCheck.zoom = 0.75
    let zoomPicture = zoomCheck.picture(info: moveInfo, crop: moveInfo.fullFrame)
    let zoomStageSize = ShortFormat.stage(for: zoomPicture.size)
    check(abs(zoomPicture.width - fillWindow.width / 0.75) <= 2 && zoomPicture.height == fillWindow.height && abs(zoomPicture.midX - fillWindow.midX) <= 2
              && Int(zoomPicture.minX) % 2 == 0 && Int(zoomPicture.width) % 2 == 0
              && zoomStageSize.map { $0.width == zoomPicture.width && abs($0.width / $0.height - 9.0 / 16) < 0.003
                                     && abs(zoomPicture.height / $0.height - 0.75) < 0.01 } == true,
          "zoomed out to 0.75, the window widens by a third about its centre, on a 9:16 stage a third taller than the picture",
          "\(zoomPicture) \(String(describing: zoomStageSize))")
    var shEdgeZoom = Short(start: 0, end: 4.5, window: CGRect(x: 0, y: 0, width: 406, height: 720)); shEdgeZoom.zoom = 0.5625
    let shEdgePicture = shEdgeZoom.picture(info: moveInfo, crop: moveInfo.fullFrame)
    check(shEdgePicture.minX == 0 && abs(shEdgePicture.width - 722) <= 2 && shEdgePicture.height == 720,
          "at the picture's edge it widens inwards, to a square at most", "\(shEdgePicture)")
    var badZoom = Short(start: 0, end: 4); badZoom.zoom = 0.4
    check(badZoom.problem(duration: 10, info: moveInfo)?.contains("0.5625") == true, "a zoom further out than a square is refused, saying what is allowed")
    badZoom.zoom = 0.75
    let zoomCoded = try JSONDecoder().decode(Short.self, from: JSONEncoder().encode(badZoom))
    let bareShort = try JSONDecoder().decode(Short.self, from: Data(#"{"start": 0, "end": 4}"#.utf8))
    check(badZoom.problem(duration: 10, info: moveInfo) == nil && zoomCoded.zoom == 0.75 && bareShort.zoom == nil,
          "zoom is stored, and without it a Short fills the frame")
    var zoomSource = VideoItem(url: moveClip); zoomSource.info = moveInfo; zoomSource.crop = moveInfo.fullFrame
    check(zoomSource.shortItem(zoomCheck).crop == zoomPicture, "a zoomed-out Short's export reads the widened picture")

    var zoomParityItem = VideoItem(url: moveClip)
    zoomParityItem.info = moveInfo; zoomParityItem.crop = moveInfo.fullFrame; zoomParityItem.status = .ready
    zoomParityItem.graphics = moveTrack
    var zoomParityShort = Short(start: 0, end: 4.5); zoomParityShort.zoom = 0.75; zoomParityShort.panels = .sheet
    zoomParityItem.shorts = [zoomParityShort]
    let zoomCrop = zoomParityShort.picture(info: moveInfo, crop: moveInfo.fullFrame)
    let zoomFrame = ShortFormat.stage(for: zoomCrop.size)!
    let zoomPlan = FFmpeg.graphicsPlan(zoomParityItem.shortItem(zoomParityShort).graphics, info: moveInfo, crop: zoomCrop, segments: nil,
                                       settings: ExportSettings(), converted: false, canvas: ShortFormat.size)
    let plainZoomPlan = FFmpeg.graphicsPlan(nil, info: moveInfo, crop: zoomCrop, segments: nil, settings: ExportSettings(), converted: false, canvas: ShortFormat.size)
    check(zoomPlan.move != nil && plainZoomPlan.move?.parts.last?.hasSuffix("[mvout]") == true
              && FFmpeg.graphicsPlan(nil, info: moveInfo, crop: fillWindow, segments: nil, settings: ExportSettings(), converted: false, canvas: ShortFormat.size).move == nil,
          "the export zooms a Short out with or without graphics, and leaves one that fills the frame alone")
    let zoomGraph = "[0:v]crop=\(Int(zoomCrop.width)):\(Int(zoomCrop.height)):\(Int(zoomCrop.minX)):\(Int(zoomCrop.minY))[mvin];"
        + (zoomPlan.move?.parts.joined(separator: ";") ?? "")
    let zw = Int(zoomFrame.width), zh = Int(zoomFrame.height)
    var zoomWorst = (offset: 0, frame: 0.0)
    var zoomSizes = true
    for frame in [15, 33, 45, 66, 100] {
        let native = try await nativePicture(zoomParityItem, frame: frame, short: zoomParityShort)
        let exported = try await ffmpegPicture(moveClip, graph: zoomGraph, frame: frame, width: zw, height: zh)
        zoomSizes = zoomSizes && native.width == zw && native.height == zh
        guard native.width == zw, native.height == zh else { continue }
        var best = (offset: 0, mean: Double.infinity)
        for dy in -3...3 {
            var total = 0.0, count = 0
            for y in stride(from: 12, to: zh - 12, by: 4) { for x in stride(from: 8, to: zw - 8, by: 3) {
                for channel in 0..<3 { total += abs(native.at(x, y, channel) - exported.at(x, y + dy, channel)) }; count += 3
            } }
            if total / Double(count) < best.mean { best = (dy, total / Double(count)) }
        }
        zoomWorst.offset = max(zoomWorst.offset, abs(best.offset))
        zoomWorst.frame = max(zoomWorst.frame, meanDifference(native, exported, xs: 4..<(zw - 4)))
    }
    print(String(format: "       zoomed-out parity: worst offset %d px, whole frame %.2f of 255", zoomWorst.offset, zoomWorst.frame))
    check(zoomSizes && zoomWorst.offset <= 2 && zoomWorst.frame < 3.5,
          "a zoomed-out Short: the export draws the picture at the top, the blurred fill below and the sheet's lift as the preview does",
          String(format: "sizes %@, offset %d, frame %.2f", zoomSizes ? "ok" : "differ", zoomWorst.offset, zoomWorst.frame))
    let zoomStill = try await ffmpegPicture(moveClip, graph: zoomGraph, frame: 15, width: zw, height: zh)
    /// Edges across a band of rows: second differences, which a smooth gradient has none of.
    func bandDetail(_ picture: Picture, _ rows: Range<Int>) -> Double {
        var total = 0.0, count = 0
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 6) { for x in 1..<(picture.width - 1) {
            total += abs(picture.at(x + 1, y, 1) - 2 * picture.at(x, y, 1) + picture.at(x - 1, y, 1)); count += 1
        } }
        return total / Double(max(1, count))
    }
    let pictureRows = Int(zoomCrop.height)
    let fillDetail = bandDetail(zoomStill, (pictureRows + 30)..<(zh - 10)), pictureDetail = bandDetail(zoomStill, 20..<(pictureRows - 260))
    check(fillDetail < pictureDetail * 0.25, "below the picture is the soft blurred copy", String(format: "%.3f vs %.3f", fillDetail, pictureDetail))

    print("\nExporting a Short")
    let shortStandIn = scratch.appendingPathComponent("short-stand-in.png")
    _ = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
        "-i", "color=c=black@0.0:s=1080x1920,format=rgba,geq=r='255*between(X,100,299)*between(Y,900,999)':g=0"
            + ":b='255*between(X,100,299)*between(Y,900,999)':a='255*between(X,100,299)*between(Y,900,999)'", "-frames:v", "1", shortStandIn.path])
    let shortStandInDraw: (GraphicsRender.Job, URL, URL) async throws -> Void = { job, _, frames in
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for index in 1...Int((job.unit.duration * FFmpeg.rate(job.fps)).rounded(.up)) {
            try FileManager.default.copyItem(at: shortStandIn, to: frames.appendingPathComponent(String(format: "frame_%06d.png", index)))
        }
    }
    let greySource = scratch.appendingPathComponent("grey-talk.mov")
    _ = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x606060:s=1280x720:rate=30",
                                     "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000", "-t", "8", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                     "-c:a", "aac", greySource.path])
    let greyInfo = try await FFmpeg.probe(url: greySource)
    let greySRT = scratch.appendingPathComponent("grey-talk.srt")
    try "1\n00:00:00,500 --> 00:00:03,500\nOver the card\n\n2\n00:00:04,000 --> 00:00:06,000\nAt the safe area\n".write(to: greySRT, atomically: true, encoding: .utf8)
    var greyItem = VideoItem(url: greySource)
    greyItem.info = greyInfo; greyItem.crop = greyInfo.fullFrame; greyItem.status = .ready; greyItem.subtitles = greySRT
    greyItem.graphics = GraphicsTrack(items: [gfx(.namePlate, 1.5, 3.5, ["title": .string("Card")])])
    var greyShort = Short(start: 1, end: 7)
    greyShort.title = "A Short"
    greyItem.shorts = [greyShort]
    var greySettings = ExportSettings(); greySettings.quality = 90
    let shortOut = scratch.appendingPathComponent("short.mp4")
    if await FFmpeg.supportsSubtitles() {
        try await ShortExport.export(greyItem, info: greyInfo, short: greyShort, settings: greySettings, output: shortOut, drawGraphics: shortStandInDraw) { _ in }
        let shortOutInfo = try await FFmpeg.probe(url: shortOut)
        check(shortOutInfo.width == 1080 && shortOutInfo.height == 1920 && abs(shortOutInfo.duration - 6) < 0.1,
              "a Short exports as a 1080×1920 video of its own length", "\(shortOutInfo.width)×\(shortOutInfo.height) \(shortOutInfo.duration)")
        equal(try await frameCount(shortOut), 180, "and keeps every frame of it")
        let shortAspect = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-select_streams", "v", "-show_entries", "stream=sample_aspect_ratio",
                                                                    "-of", "csv=p=0", shortOut.path])
        check(shortAspect.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1:1",
              "with square pixels, though the window is a pixel off 9:16", shortAspect.stdoutText)
        let cardOn = try await pixel(shortOut, x: 150, y: 950, at: 1.5), cardOff = try await pixel(shortOut, x: 150, y: 950, at: 0.2)
        check(isMagenta(cardOn) && !isMagenta(cardOff), "its graphics land on the 9:16 canvas while they show", "\(cardOn) \(cardOff)")
        /// The rows with white caption text in a frame.
        func whiteRows(_ image: CGImage) -> (top: Int, bottom: Int)? {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var rows: [Int] = []
            for y in stride(from: 0, to: height, by: 2) {
                var white = 0
                for x in stride(from: 300, to: min(780, width), by: 2) {
                    let i = (y * width + x) * 4
                    if bytes[i] > 235 && bytes[i + 1] > 235 && bytes[i + 2] > 235 { white += 1 }
                }
                if white >= 2 { rows.append(y) }
            }
            return rows.isEmpty ? nil : (rows.min()!, rows.max()!)
        }
        /// The columns with white caption text between `rows`.
        func whiteColumns(_ image: CGImage, rows: (top: Int, bottom: Int)) -> (left: Int, right: Int)? {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var columns: [Int] = []
            for x in 0..<width {
                for y in stride(from: rows.top, through: min(rows.bottom, height - 1), by: 2) {
                    let i = (y * width + x) * 4
                    if bytes[i] > 235 && bytes[i + 1] > 235 && bytes[i + 2] > 235 { columns.append(x); break }
                }
            }
            return columns.isEmpty ? nil : (columns.min()!, columns.max()!)
        }
        func exportedFrame(_ time: Double) async throws -> CGImage {
            let png = scratch.appendingPathComponent("short-frame-\(Int(time * 100)).png")
            _ = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(time), "-i", shortOut.path, "-frames:v", "1", png.path])
            return NSImage(contentsOf: png)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }
        let shortModel = AppModel(recoveryURL: nil)
        var captionSettings = greySettings; captionSettings.graphics = true
        var plainShortItem = greyItem; plainShortItem.graphics = nil
        let laterExport = try await exportedFrame(4.0)
        let laterPreview = try await shortModel.composedShortFrame(ProjectClip(plainShortItem), short: greyShort, at: 4.0, settings: captionSettings).image
        let exportedRows = whiteRows(laterExport), previewRows = whiteRows(laterPreview)
        check(exportedRows.map { abs($0.bottom - 1320) < 40 } == true,
              "burned-in captions sit at the safe-area spot, 600 px above the bottom", "\(String(describing: exportedRows))")
        check(exportedRows != nil && previewRows != nil && abs(exportedRows!.top - previewRows!.top) <= 14 && abs(exportedRows!.bottom - previewRows!.bottom) <= 14,
              "the Short viewer draws its captions where the export burns them", "export \(String(describing: exportedRows)), preview \(String(describing: previewRows))")
        let exportedColumns = exportedRows.flatMap { whiteColumns(laterExport, rows: $0) }
        let previewColumns = previewRows.flatMap { whiteColumns(laterPreview, rows: $0) }
        check(exportedColumns.map { $0.right <= Int(ShortFormat.clearArea.maxX) && abs(Double($0.left + $0.right) / 2 - ShortFormat.clearArea.midX) < 12 } == true,
              "burned-in captions are centred in the clear area, left of YouTube's like and share rail", "\(String(describing: exportedColumns))")
        check(exportedColumns != nil && previewColumns != nil && abs(exportedColumns!.left - previewColumns!.left) <= 14
                  && abs(exportedColumns!.right - previewColumns!.right) <= 14,
              "the Short viewer centres its captions as the export does", "export \(String(describing: exportedColumns)), preview \(String(describing: previewColumns))")
        let duringCard = whiteRows(try await exportedFrame(1.5))
        check(duringCard.map { $0.bottom < 760 && $0.bottom > 600 } == true, "while the card shows they step up above it", "\(String(describing: duringCard))")
    } else {
        print("  skip burning a Short's captions: this ffmpeg has no libass")
    }

    print("\nExport Short for YouTube")
    let shortFolder = scratch.appendingPathComponent("short-youtube", isDirectory: true)
    try FileManager.default.createDirectory(at: shortFolder, withIntermediateDirectories: true)
    var shUploadSettings = greySettings; shUploadSettings.captions = .upload
    var coverShort = greyShort; coverShort.cover = 2; coverShort.tags = ["shorts", "editing"]
    greyItem.shorts = [coverShort]
    greyItem.publish = { var info = PublishInfo(); info.title = "The long video"; return info }()
    let shortFiles = ShortExport.files(in: shortFolder, short: coverShort, index: 0, recording: greyItem, settings: shUploadSettings, unique: true)
    let coverModel = AppModel(recoveryURL: nil)
    try await ShortExport.run(greyItem, info: greyInfo, short: coverShort, settings: shUploadSettings, files: shortFiles,
                              cover: { time in try await coverModel.composedShortFrame(ProjectClip(greyItem), short: coverShort, at: time, settings: shUploadSettings).image },
                              drawGraphics: shortStandInDraw) { _ in }
    let shortText = (try? String(contentsOf: shortFiles.text, encoding: .utf8)) ?? ""
    let shortJSON = (try? JSONSerialization.jsonObject(with: Data(contentsOf: shortFiles.json)) as? [String: Any]) ?? [:]
    let coverInfo = try await FFmpeg.probe(url: shortFiles.thumbnail!)
    check(FileManager.default.fileExists(atPath: shortFiles.video.path) && shortFiles.video.lastPathComponent == "A Short.mp4"
              && shortFiles.captions.map { FileManager.default.fileExists(atPath: $0.path) } == true
              && coverInfo.width == 1080 && coverInfo.height == 1920,
          "Export Short for YouTube writes the MP4, its captions and a 1080×1920 cover", "\(shortFiles)")
    let shortSRT = (try? String(contentsOf: shortFiles.captions!, encoding: .utf8)) ?? ""
    check(shortSRT.contains("00:00:00,000 --> 00:00:02,500\nOver the card") && shortSRT.contains("00:00:03,000 --> 00:00:05,000\nAt the safe area"),
          "the SRT is timed on the Short's own timeline", shortSRT)
    check(shortText.contains("TITLE\nA Short") && shortText.contains("SHORT\nA vertical 1080×1920 Short of 0:06") && shortText.contains("RELATED VIDEO")
              && shortText.contains("The long video: The long video.") && shortText.contains("COVER: A Short cover.jpg"),
          "the upload text says it is a Short, its cover, and to link the long video in Studio", shortText)
    check(shortJSON["short"] as? Bool == true && (shortJSON["relatedVideo"] as? [String: Any])?["uploadAPICanSet"] as? Bool == false
              && (shortJSON["size"] as? [String: Double])?["height"] == 1920 && (shortJSON["tags"] as? [String]) == ["shorts", "editing"],
          "the JSON says the same for an agent", "\(shortJSON)")
    var shUntitled = coverShort; shUntitled.title = ""
    do {
        try await ShortExport.run(greyItem, info: greyInfo, short: shUntitled, settings: shUploadSettings, files: shortFiles,
                                  cover: { _ in CGImage.blank(width: 8, height: 8) }) { _ in }
        check(false, "a Short without a title is refused")
    } catch { check(error.localizedDescription.contains("title"), "a Short without a title is refused", error.localizedDescription) }
    let shShortIssues = Short(start: 0, end: 200).issues(graphics: nil, publish: nil)
    check(shShortIssues.contains { $0.field == "length" && $0.severity == .blocking } && shShortIssues.contains { $0.field == "relatedVideo" && $0.severity == .warning }
              && shShortIssues.contains { $0.field == "cover" && $0.severity == .warning },
          "issues: over 3:00 blocks; no cover and the related video only warn")

    print("\nThe Short viewer")
    let viewerModel = AppModel(recoveryURL: nil)
    viewerModel.restore(VideoProject(clips: [ProjectClip(greyItem)], settings: greySettings, selection: greyItem.id))
    viewerModel.setViewer(.short)
    check(viewerModel.showsShort && viewerModel.showPlayback && viewerModel.playback.shortID == coverShort.id && viewerModel.viewer == .short
              && viewerModel.previewTime >= coverShort.start - 0.001,
          "the viewer shows the selected Short, with the playhead inside it")
    let overlayInput = viewerModel.shortOverlay(viewerModel.items[0], info: greyInfo, short: coverShort)
    check(overlayInput.track.canvas == .short(.sheet) && abs(overlayInput.frame.width / overlayInput.frame.height - 9.0 / 16) < 0.01
              && overlayInput.captions?.items.first.map { $0.start >= coverShort.start && $0.bottom <= ShortLayout.captionBottom } == true,
          "its overlay draws on the 9:16 canvas, with the caption file's captions laid out for it in recording time")
    var uploadOnly = greySettings; uploadOnly.captions = .upload
    viewerModel.updateSettings(uploadOnly)
    check(viewerModel.shortOverlay(viewerModel.items[0], info: greyInfo, short: coverShort).captions != nil,
          "with the long video's captions uploaded only, the Short viewer still shows the Short's burned-in captions")
    uploadOnly.shortCaptions = .upload
    viewerModel.updateSettings(uploadOnly)
    check(viewerModel.shortOverlay(viewerModel.items[0], info: greyInfo, short: coverShort).captions == nil,
          "with Shorts' captions uploaded only, the Short viewer shows none, as the export burns none")
    viewerModel.updateShort(coverShort.id, label: "Short Captions") { $0.captions = .hide }
    check(viewerModel.showPlayback && viewerModel.showsShort && viewerModel.selectedItem?.shorts.first?.captions == .hide,
          "changing a Short's option keeps the Short viewer up, so it can be tried while it plays")
    viewerModel.setViewer(.preview)
    check(!viewerModel.showsShort && viewerModel.playback.shortID == nil && viewerModel.showPlayback, "Preview goes back to the 16:9 edit")

    print("\nShorts for agents")
    let shortAgent = AppModel(recoveryURL: nil)
    var agentShortSource = shortItemSource
    agentShortSource.graphics = GraphicsTrack(items: [gfx(.namePlate, 1, 3, ["title": .string("Plate")])])
    shortAgent.restore(VideoProject(clips: [ProjectClip(agentShortSource)], settings: ExportSettings(), selection: agentShortSource.id))
    @MainActor func shortApply(_ id: String, _ commands: [[String: Any]]) async -> [String: Any] {
        var request = address(shortAgent)
        request["method"] = "apply"; request["requestID"] = id; request["client"] = "Claude"; request["commands"] = commands
        return await agentCall(shortAgent, request)
    }
    let shAdded = await shortApply("short-add", [["type": "addShort", "clipID": agentShortSource.id.uuidString]])
    let addedID = (agentResult(shAdded)["createdIDs"] as? [String])?.first ?? ""
    var shortsState = ((agentResult(await agentCall(shortAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["shorts"] as? [[String: Any]]) ?? []
    check(shAdded["ok"] as? Bool == true && shortsState.count == 1 && shortsState[0]["id"] as? String == addedID && shortsState[0]["start"] as? Double == 0
              && shortsState[0]["end"] as? Double == 12 && shortsState[0]["windowSet"] as? Bool == false && shortsState[0]["height"] as? Int == 1920,
          "addShort with only the recording covers a recording under 3:00, and state shows it", "\(shAdded) \(shortsState)")
    let updated = await shortApply("short-update", [["type": "updateShort", "clipID": agentShortSource.id.uuidString, "shortID": addedID,
        "short": ["panels": "split", "captions": "hide", "title": "Agent Short", "end": 8, "window": ["x": 100, "y": 0, "width": 406, "height": 720]]]])
    shortsState = ((agentResult(await agentCall(shortAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["shorts"] as? [[String: Any]]) ?? []
    check(updated["ok"] as? Bool == true && shortsState.first?["panels"] as? String == "split" && shortsState.first?["captions"] as? String == "hide"
              && shortsState.first?["end"] as? Double == 8 && (shortsState.first?["window"] as? [String: Double])?["x"] == 100
              && (shortsState.first?["graphics"] as? [[String: Any]])?.count == 1,
          "updateShort changes only the keys given", "\(updated) \(shortsState)")
    check(shortAgent.undoTitle == "Undo Edit Short (Claude)", "each agent edit is one undo step", shortAgent.undoTitle)
    @MainActor func shortRefusal(_ id: String, _ command: [String: Any]) async -> String {
        let reply = await shortApply(id, [command])
        return ((reply["error"] as? [String: Any])?["message"] as? String) ?? "accepted"
    }
    let clipText = agentShortSource.id.uuidString
    let tooLongReply = await shortRefusal("short-bad-1", ["type": "addShort", "clipID": clipText, "short": ["start": 8.5, "end": 300]])
    let overlapReply = await shortRefusal("short-bad-2", ["type": "addShort", "clipID": clipText, "short": ["start": 2, "end": 5]])
    let keyReply = await shortRefusal("short-bad-3", ["type": "updateShort", "clipID": clipText, "shortID": addedID, "short": ["size": 2]])
    let panelsReply = await shortRefusal("short-bad-4", ["type": "updateShort", "clipID": clipText, "shortID": addedID, "short": ["panels": "sideways"]])
    let hiddenReply = await shortRefusal("short-bad-5", ["type": "updateShort", "clipID": clipText, "shortID": addedID, "short": ["hidden": [UUID().uuidString]]])
    let windowReply = await shortRefusal("short-bad-6", ["type": "updateShort", "clipID": clipText, "shortID": addedID,
                                                         "short": ["window": ["x": 0, "y": 0, "width": 720, "height": 720]]])
    check(tooLongReply.contains("0–12.00") && overlapReply.contains("overlap") && keyReply.contains("Keys: id, start")
              && panelsReply.contains("sheet, shade, split") && hiddenReply.contains("No graphic") && windowReply.contains("9:16"),
          "agents are refused with what is allowed: the recording's length, no overlap, the keys, the panel layouts, real graphics, a 9:16 window",
          [tooLongReply, overlapReply, keyReply, panelsReply, hiddenReply, windowReply].joined(separator: " | "))
    let zoomReply = await shortRefusal("short-bad-7", ["type": "updateShort", "clipID": clipText, "shortID": addedID, "short": ["zoom": 0.3]])
    let zoomApplied = await shortApply("short-zoom", [["type": "updateShort", "clipID": clipText, "shortID": addedID, "short": ["zoom": 0.75]]])
    shortsState = ((agentResult(await agentCall(shortAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["shorts"] as? [[String: Any]]) ?? []
    check(zoomReply.contains("0.5625") && zoomApplied["ok"] as? Bool == true && shortsState.first?["zoom"] as? Double == 0.75
              && (shortsState.first?["picture"] as? [String: Double])?["width"].map { $0 > 406 } == true,
          "an agent zooms a Short out with zoom, and state shows the widened picture; too far out is refused with what is allowed",
          "\(zoomReply) \(zoomApplied) \(String(describing: shortsState.first?["picture"]))")
    var previewRequest: [String: Any] = ["method": "preview", "clip": clipText, "short": addedID, "time": 1.5, "composed": true]
    let shortPreview = agentResult(await agentCall(shortAgent, previewRequest))
    check(shortPreview["width"] as? Int == 1080 && shortPreview["height"] as? Int == 1920 && shortPreview["short"] as? String == addedID
              && (shortPreview["graphics"] as? [[String: Any]])?.first?["kind"] as? String == "namePlate"
              && FileManager.default.fileExists(atPath: shortPreview["path"] as? String ?? ""),
          "preview with a short draws it 1080×1920 with its graphics' boxes", "\(shortPreview)")
    previewRequest["time"] = 99
    check(agentError(await agentCall(shortAgent, previewRequest)) == "invalid_command", "a preview time past the Short's end is refused")
    let shRevealed = agentResult(await agentCall(shortAgent, ["method": "reveal", "clip": clipText, "short": addedID, "time": 2]))
    check(shRevealed["viewer"] as? String == "short" && shRevealed["short"] as? String == addedID && abs((shRevealed["playhead"] as? Double ?? 0) - 2) < 0.05,
          "reveal with a short shows it in the Short viewer", "\(shRevealed)")
    if await FFmpeg.supportsSubtitles() {
        let agentFolder = scratch.appendingPathComponent("agent-short", isDirectory: true)
        try FileManager.default.createDirectory(at: agentFolder, withIntermediateDirectories: true)
        var exportRequest = address(shortAgent)
        exportRequest["method"] = "export"; exportRequest["requestID"] = "short-export"; exportRequest["client"] = "Claude"
        exportRequest["clip"] = clipText; exportRequest["short"] = addedID; exportRequest["youtube"] = true; exportRequest["path"] = agentFolder.path
        setenv("YAMVIDEO_GRAPHICS_CACHE", scratch.appendingPathComponent("short-agent-cache").path, 1)
        let hidePlate = await shortApply("short-hide", [["type": "updateShort", "clipID": clipText, "shortID": addedID,
                                                         "short": ["hidden": [agentShortSource.graphics!.items[0].id.uuidString]]]])
        exportRequest["expectedRevision"] = shortAgent.revision
        let exportJob = agentResult(await agentCall(shortAgent, exportRequest))
        let finished = try await waitForJob(shortAgent, exportJob["id"] as? String ?? "")
        let exportedShort = (finished["result"] as? [String: Any]) ?? [:]
        check(hidePlate["ok"] as? Bool == true && finished["status"] as? String == "succeeded" && exportedShort["height"] as? Double == 1920
              && FileManager.default.fileExists(atPath: exportedShort["path"] as? String ?? "")
              && (exportedShort["path"] as? String)?.hasSuffix("Agent Short.mp4") == true && exportedShort["cover"] != nil,
              "export with a short and youtube writes the Short's files as a job", "\(finished)")
    }
    let removed = await shortApply("short-remove", [["type": "removeShort", "clipID": clipText, "shortID": addedID]])
    check(removed["ok"] as? Bool == true && shortAgent.items[0].shorts.isEmpty, "removeShort removes it")
    let catalogShorts = AgentCatalog.current.commands.filter { $0.group == "shorts" }.map(\.type)
    check(catalogShorts == ["addShort", "updateShort", "removeShort"] && AgentCatalog.current.methods.first { $0.method == "preview" }?.fields.contains { $0.name == "short" } == true,
          "the catalog describes the Short commands and the short field")

    // The speaker: the subject on the left of the thumbnail tests' recording pulls the window to it.
    subjectItem.shorts = []
    let speakerModel = AppModel(recoveryURL: nil)
    let speakerWindow = try await speakerModel.speakerWindow(ProjectClip(subjectItem), short: Short(start: 0, end: 2))
    check(speakerWindow.map { abs($0.midX - 420) < 80 && $0.height == 720 } == true, "Centre on Speaker puts the window on the person Apple Vision finds",
          "\(String(describing: speakerWindow))")
    let speakerAgent = AppModel(recoveryURL: nil)
    speakerAgent.restore(VideoProject(clips: [ProjectClip(subjectItem)], settings: ExportSettings(), selection: subjectItem.id))
    var speakerRequest = address(speakerAgent)
    speakerRequest["method"] = "apply"; speakerRequest["requestID"] = "speaker"; speakerRequest["client"] = "Claude"
    speakerRequest["commands"] = [["type": "addShort", "clipID": subjectItem.id.uuidString, "short": ["window": "speaker"]]]
    let speakerReply = await agentCall(speakerAgent, speakerRequest)
    check(speakerReply["ok"] as? Bool == true && speakerAgent.items[0].shorts.first?.window.map { abs($0.midX - 420) < 80 } == true,
          "an agent can ask for the window on the speaker", "\(speakerReply)")

}
