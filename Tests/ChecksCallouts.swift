// Checks for callouts: a label with a line to a point on the screen recording. Run with ./test.sh callouts
import AppKit
import Foundation

@MainActor func calloutsTests() async throws {
    print("\nCallouts: the kind and its rules")
    check(GraphicKind.callout.zone == .callout && !GraphicKind.callout.isPlaceable && GraphicKind.callout.hasInk,
          "a callout has a zone of its own, stays on its point, and can be written in ink")
    func point(_ x: Double, _ y: Double) -> JSONValue { .object(["x": .number(x), "y": .number(y)]) }
    let props: [String: JSONValue] = ["text": .string("Empty state"), "point": point(1600, 900)]
    let callout = gfx(.callout, 12, 15, props)
    check(GraphicsTrack(items: [callout]).problem(duration: 60) == nil, "a callout with a text and a point is fine")
    func refused(_ graphic: Graphic, _ words: String, others: [Graphic] = []) -> Bool {
        GraphicsTrack(items: [graphic] + others).problem(duration: 60)?.contains(words) == true
    }
    var long = callout; long.props["text"] = .string("A label far too long to read")
    var wordy = callout; wordy.props["text"] = .string("one two three four five")
    var pointless = callout; pointless.props["point"] = nil
    var sideways = callout; sideways.props["side"] = .string("middle")
    var moved = callout; moved.transform = GraphicTransform(x: 10)
    check(refused(long, "28 characters") && refused(wordy, "1 to 4 words") && refused(pointless, "needs point") && refused(sideways, "auto, left")
              && refused(gfx(.callout, 12, 13, props), "1.5 to 10") && refused(gfx(.callout, 12, 23, props), "1.5 to 10") && refused(moved, "cannot be moved"),
          "a callout's text, point, side and length are checked, saying what is allowed")
    check(refused(callout, "shows alone", others: [gfx(.titleCard, 14, 18, ["title": .string("x")])])
              && refused(callout, "slides away", others: [gfx(.rule, 10, 11.5, ["title": .string("x")])])
              && refused(callout, "shows alone", others: [gfx(.callout, 14, 16, props)])
              && GraphicsTrack(items: [callout, gfx(.titleCard, 15, 18, ["title": .string("x")]), gfx(.rule, 9, 11.1, ["title": .string("x")])]).problem(duration: 60) == nil,
          "a callout shows alone: no other graphic with it, and a panel must have slid away first")

    let screenInfo = MediaInfo(width: 3248, height: 2008, duration: 750, videoCodec: "h264", audioCodec: nil, fps: 60, fpsExpression: "60/1", rotation: 0,
                               colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    let speakerInfo = MediaInfo(width: 1920, height: 1080, duration: 60, videoCodec: "h264", audioCodec: "aac", fps: 30, fpsExpression: "30/1", rotation: 0,
                                colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    var screen = ScreenTrack(url: URL(fileURLWithPath: "/tmp/screen.mov"), info: screenInfo, offset: 0)
    screen.crop = CGRect(x: 112, y: 76, width: 3024, height: 1784)
    screen.bubble.face = CGPoint(x: 960, y: 420)
    var outside = callout; outside.props["point"] = point(50, 50)
    check(GraphicsTrack(items: [callout]).calloutProblem(screen: nil)?.contains("setScreen") == true
              && GraphicsTrack(items: [callout]).calloutProblem(screen: screen) == nil
              && GraphicsTrack(items: [outside]).calloutProblem(screen: screen)?.contains("x 112–3136") == true,
          "a callout needs a screen recording, and its point on the part of it that shows")

    print("\nCallouts: the point through the layout and the zoom")
    let geometry = LayoutGeometry(track: screen, crop: speakerInfo.fullFrame)
    var inverse = true, tried = 0
    for layout in [ScreenLayout.screen, .split, .ink] {
        var track = screen; track.layout = layout
        track.zooms = [ZoomShot(start: 2, hold: 2, level: 2, target: CGPoint(x: 2000, y: 1200))]
        for time in [1.0, 2.2, 3.0] {
            guard let place = track.state(at: time, geometry: geometry, endScreen: nil).screen else { inverse = false; continue }
            let window = track.zoomWindow(at: time)
            for (u, v) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.7)] {
                let p = CGPoint(x: track.picture.minX + window.minX + u * window.width, y: track.picture.minY + window.minY + v * window.height)
                tried += 1
                guard let frame = track.framePoint(p, at: time, place: place.rect),
                      let back = track.screenPoint(frame, at: time, geometry: geometry, endScreen: nil),
                      hypot(back.x - p.x, back.y - p.y) < 0.01 else { inverse = false; continue }
            }
        }
    }
    check(inverse && tried == 27, "where a point of the screen lands is the inverse of aiming at it, in Screen, Side by side and Ink, with a zoom")

    var talk = VideoItem(url: landscape)
    talk.info = speakerInfo; talk.crop = speakerInfo.fullFrame; talk.status = .ready
    var followed = screen
    followed.zooms = [ZoomShot(start: 13, hold: 2, level: 2, target: CGPoint(x: 1000, y: 700)),
                      ZoomShot(start: 23, hold: 2, level: 2, target: CGPoint(x: 1000, y: 700))]
    followed.spans = [LayoutSpan(start: 40, end: 50, layout: .split), LayoutSpan(start: 51, end: 52, layout: .speaker),
                      LayoutSpan(start: 55, end: 58, layout: .speaker)]
    talk.screen = followed
    func at(_ place: CalloutPlace, _ t: Double) -> [Double] {
        let path = place.path
        if t <= path[0][0] { return path[0] }
        for (a, b) in zip(path, path.dropFirst()) where t <= b[0] {
            let u = (t - a[0]) / max(0.000001, b[0] - a[0])
            return a.indices.map { a[$0] + (b[$0] - a[$0]) * u }
        }
        return path[path.count - 1]
    }
    let zoomed = gfx(.callout, 12, 18, ["text": .string("Empty state"), "point": point(1000, 700)])
    let zoomedPlace = talk.calloutPlace(zoomed, short: nil, ink: false, endScreen: nil)
    let screenPlace = geometry.screenPlace(.screen)!.rect
    let before = at(zoomedPlace, 0), holding = at(zoomedPlace, 2)
    let unzoomed = CGPoint(x: screenPlace.minX + (1000 - 112) / 3024 * screenPlace.width, y: screenPlace.minY + (700 - 76) / 1784 * screenPlace.height)
    check(abs(before[1] - unzoomed.x) < 0.6 && abs(before[2] - unzoomed.y) < 0.6 && abs(holding[1] - screenPlace.midX) < 0.6 && abs(holding[2] - screenPlace.midY) < 0.6,
          "a zoom on the point moves the dot with it, to the middle of the screen", "\(before) \(holding) \(unzoomed)")
    check(zoomedPlace.side == .right && zoomedPlace.path.count > 2 && zoomedPlace.path.allSatisfy { abs($0[3] - $0[1] - Callout.reach) < 0.2 && $0[4] == $0[2] },
          "the label moves with the dot and keeps its side", "\(zoomedPlace.side) \(zoomedPlace.path.count)")
    let still = talk.calloutPlace(gfx(.callout, 30, 33, ["text": .string("Tabs"), "point": point(1000, 700)]), short: nil, ink: false, endScreen: nil)
    check(still.path.count == 2 && still.path.allSatisfy { $0[5] == 1 }, "a callout that does not move keeps two entries", "\(still.path)")
    let split = talk.calloutPlace(gfx(.callout, 39, 42, ["text": .string("Tabs"), "point": point(1000, 700)]), short: nil, ink: false, endScreen: nil)
    let splitScreen = geometry.screenPlace(.split)!.rect
    let inSplit = at(split, 2)
    check(abs(inSplit[1] - (splitScreen.minX + (1000 - 112) / 3024 * splitScreen.width)) < 0.6
              && abs(inSplit[2] - (splitScreen.minY + (700 - 76) / 1784 * splitScreen.height)) < 0.6,
          "when the layout moves the screen, the dot moves with it", "\(inSplit) \(splitScreen)")
    let covered = talk.calloutPlace(gfx(.callout, 50, 54, ["text": .string("Tabs"), "point": point(1000, 700)]), short: nil, ink: false, endScreen: nil)
    check(at(covered, 0.2)[5] == 1 && at(covered, 1.5)[5] == 0 && at(covered, 3.5)[5] == 1 && covered.path.contains { $0[5] > 0.05 && $0[5] < 0.95 }
              && covered.path.filter { $0[5] == 0 }.allSatisfy { $0[0] >= 0.99 && $0[0] <= 2.01 },
          "under the Speaker layout the callout fades out, and back in after it; the change into the Screen layout does not hide it",
          "\(covered.path.map { [$0[0], $0[5]] })")
    let left = talk.calloutPlace(gfx(.callout, 22, 28, ["text": .string("Footer"), "point": point(3000, 300)]), short: nil, ink: false, endScreen: nil)
    check(at(left, 0)[5] == 1 && at(left, 2.5)[5] == 0, "a zoom that leaves the point out hides the callout", "\(left.path.map { $0[5] })")
    let never = gfx(.callout, 55.5, 57.5, ["text": .string("Tabs"), "point": point(1000, 700)])
    talk.graphics = GraphicsTrack(items: [zoomed, never])
    check(talk.calloutPlace(never, short: nil, ink: false, endScreen: nil).hidden && AppModel.hiddenCallouts(talk) == [never.id],
          "a callout whose point never shows is marked hidden for agents")

    print("\nCallouts: where the label goes")
    func box(_ place: CalloutPlace, _ row: [Double], ink: Bool = false) -> CGRect {
        CalloutPlace.box(CGPoint(x: row[3], y: row[4]), size: Callout.labelSize(place.lines, ink: ink), side: place.side)
    }
    let bubble = geometry.speakerPlace(.screen).rect.insetBy(dx: -Callout.speakerMargin, dy: -Callout.speakerMargin)
    let crowded = talk.calloutPlace(gfx(.callout, 30, 33, ["text": .string("Buy and sell buttons"), "point": point(1606, 1530)]),
                                    short: nil, ink: false, endScreen: nil)
    check(crowded.side == .left && crowded.path.allSatisfy { !box(crowded, $0).intersects(bubble) && GraphicPlacement.safeArea.contains(box(crowded, $0)) },
          "a label that would cover the bubble goes the other way, inside the safe area", "\(crowded.side) \(box(crowded, crowded.path[0])) \(bubble)")
    var forced = gfx(.callout, 30, 33, ["text": .string("Tabs"), "point": point(1000, 700), "side": .string("up")])
    check(talk.calloutPlace(forced, short: nil, ink: false, endScreen: nil).side == .up, "side sets where the label goes")
    forced.props["side"] = .string("left")
    let forcedLeft = talk.calloutPlace(forced, short: nil, ink: false, endScreen: nil)
    check(forcedLeft.side == .left && GraphicPlacement.safeArea.contains(box(forcedLeft, forcedLeft.path[0])),
          "a label that would leave the picture is moved inside it", "\(box(forcedLeft, forcedLeft.path[0]))")

    let phoneInfo = MediaInfo(width: 1206, height: 2622, duration: 600, videoCodec: "hevc", audioCodec: nil, fps: 60, fpsExpression: "60/1", rotation: 0,
                              colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    var phone = ScreenTrack(url: URL(fileURLWithPath: "/tmp/phone.mp4"), info: phoneInfo, offset: 0)
    phone.crop = CGRect(x: 0, y: 120, width: 1206, height: 2380)
    phone.layout = .split
    var phoneTalk = talk
    phoneTalk.screen = phone
    let sheet = phoneTalk.calloutPlace(gfx(.callout, 2, 5, ["text": .string("Bottom sheet"), "point": point(900, 1562)]), short: nil, ink: false, endScreen: nil)
    let phonePlace = LayoutGeometry(track: phone, crop: speakerInfo.fullFrame).screenPlace(.split)!.rect
    check(sheet.side == .right && sheet.lines == ["Bottom", "sheet"] && abs(sheet.path[0][3] - (phonePlace.maxX + Callout.besideGap)) < 0.2
              && GraphicPlacement.safeArea.contains(box(sheet, sheet.path[0])),
          "beside a phone recording, the label goes in the free space next to it, on two lines when one does not fit", "\(sheet.lines) \(sheet.path[0]) \(phonePlace)")

    var short = Short(start: 30, end: 50, window: CGRect(x: 656, y: 0, width: 608, height: 1080))
    short.screen = .top
    talk.shorts = [short]
    let inShort = gfx(.callout, 31, 34, ["text": .string("Empty state"), "point": point(2600, 1500)])
    talk.graphics = GraphicsTrack(items: [inShort])
    let shortTrack = talk.shortGraphics(short)!
    let shortPlace = shortTrack.items.first?.props["place"]?.object
    let shortRows = shortPlace?["path"]?.array?.compactMap { $0.array?.compactMap(\.number) } ?? []
    let stackScreen = LayoutGeometry(short: talk.screen!, crop: speakerInfo.fullFrame, window: short.frame(info: speakerInfo, crop: talk.crop)).screenPlace(.screen)!.rect
    let shortLines = shortPlace?["lines"]?.array?.compactMap(\.string) ?? []
    let shortSide = CalloutPlace.Side(rawValue: shortPlace?["side"]?.string ?? "") ?? .right
    let shortBoxes = shortRows.map { CalloutPlace.box(CGPoint(x: $0[3], y: $0[4]), size: Callout.labelSize(shortLines, ink: false), side: shortSide) }
    check(!shortRows.isEmpty && shortBoxes.allSatisfy { ShortFormat.clearArea.contains($0) && $0.maxY <= stackScreen.maxY + 0.5 }
              && shortRows.allSatisfy { stackScreen.contains(CGPoint(x: $0[1], y: $0[2])) },
          "in a Short with the screen on top, the callout stays on the screen, in the clear area, above the captions", "\(shortBoxes) \(stackScreen)")
    short.screen = .off
    talk.shorts = [short]
    check(talk.shortGraphics(short)?.items.isEmpty == true, "a Short without the screen does not show callouts")

    print("\nCallouts: the engine draws them where the app placed them")
    talk.shorts = []
    let drawnCallout = gfx(.callout, 30, 34, ["text": .string("Empty state"), "point": point(1000, 700)])
    for look in [GraphicsLook.glass, .ink] {
        var item = talk
        var drawnLook = drawnCallout; drawnLook.look = look
        item.graphics = GraphicsTrack(items: [drawnLook])
        let placed = item.placedGraphics!
        let row = placed.items[0].props["place"]?.object?["path"]?.array?.first?.array?.compactMap(\.number) ?? []
        let drawn = try await GraphicsSnapshot.draw(placed, duration: 60, fps: "30", time: 31.5, over: CGImage.blank(width: 1920, height: 1080))
        let dot = rgb(drawn.image, Int(row[1].rounded()), Int(row[2].rounded()))
        let drawnBox = drawn.boxes[drawnCallout.id]
        let label = CalloutPlace.box(CGPoint(x: row[3], y: row[4]), size: Callout.labelSize(["Empty state"], ink: look == .ink), side: .right)
        check(abs(dot.0 - 245) < 30 && abs(dot.1 - 196) < 30 && abs(dot.2 - 44) < 40, "\(look.rawValue): the dot is on the point, in the accent colour", "\(dot) \(row)")
        check(drawnBox.map { $0.contains(CGPoint(x: row[1], y: row[2])) && abs($0.maxX - label.maxX) < label.width * 0.15 } == true,
              "\(look.rawValue): the label ends about where the app estimated", "\(String(describing: drawnBox)) \(label)")
        let early = try await GraphicsSnapshot.draw(placed, duration: 60, fps: "30", time: 29.5, over: CGImage.blank(width: 1920, height: 1080))
        check(early.boxes[drawnCallout.id] == nil, "\(look.rawValue): nothing shows before it starts")
    }
    check(talk.graphics?.items.allSatisfy { $0.props["place"] == nil } == true, "the place is worked out for drawing and never stored")

    print("\nCallouts: agents")
    let agent = AppModel(recoveryURL: nil)
    var bare = talk; bare.screen = nil; bare.graphics = nil
    agent.restore(VideoProject(clips: [ProjectClip(bare)], settings: ExportSettings(), selection: bare.id))
    var adding = address(agent)
    adding["method"] = "apply"; adding["requestID"] = "callouts-1"; adding["client"] = "Claude"
    let command: [String: Any] = ["type": "addGraphic", "clipID": bare.id.uuidString,
                                  "graphic": ["kind": "callout", "start": 2, "end": 4.5, "props": ["text": "Empty state", "point": ["x": 1000, "y": 700]]]]
    adding["commands"] = [command]
    let noScreen = await agentCall(agent, adding)
    check(agentError(noScreen) == "invalid_command" && "\(noScreen)".contains("setScreen"), "without a screen recording a callout is refused", "\(noScreen)")
    var withScreen = talk; withScreen.graphics = nil; withScreen.shorts = []
    agent.restore(VideoProject(clips: [ProjectClip(withScreen)], settings: ExportSettings(), selection: withScreen.id))
    adding = address(agent)
    adding["method"] = "apply"; adding["requestID"] = "callouts-2"; adding["client"] = "Claude"
    adding["commands"] = [["type": "addGraphic", "clipID": withScreen.id.uuidString,
                           "graphic": ["kind": "callout", "start": 2, "end": 4.5, "props": ["text": "Empty state", "point": ["x": 1000, "y": 700]]]]]
    let reply = await agentCall(agent, adding)
    let state = (agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["screen"] as? [String: Any]
    check(reply["ok"] as? Bool == true && agent.items[0].graphics?.items.first?.kind == .callout && (state?["hiddenCallouts"] as? [Any])?.isEmpty == true,
          "an agent adds a callout with addGraphic; state lists none hidden", "\(reply) \(state ?? [:])")
}
