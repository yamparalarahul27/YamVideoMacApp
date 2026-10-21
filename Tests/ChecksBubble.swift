// Checks for graphics clear of the speaker's bubble (Sources/BubbleClear.swift).
import AppKit
import Foundation
import JavaScriptCore

@MainActor func bubbleTests() async throws {
    print("\nGraphics clear of the bubble")

    // The rule itself, run as the engine runs it.
    let engine = JSContext()!
    if let folder = GraphicsEngine.resources {
        engine.evaluateScript(try String(contentsOf: folder.appendingPathComponent("graphics.js"), encoding: .utf8))
    }
    func move(_ box: [Double], _ clear: [Double], _ side: String) -> [String: Double]? {
        let script = "JSON.stringify(YamGraphics.clearMove({x: \(box[0]), y: \(box[1]), w: \(box[2]), h: \(box[3])}, "
            + "{x: \(clear[0]), y: \(clear[1]), w: \(clear[2]), h: \(clear[3]), side: '\(side)'}))"
        guard let text = engine.evaluateScript(script)?.toString(), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Double]
    }
    let topRight = [1618.0, 40, 262, 262], bottomRight = [1618.0, 778, 262, 262]
    equal(engine.evaluateScript("YamGraphics.CLEAR_GAP")?.toDouble(), BubbleClear.gap, "the app and the engine leave the same gap")
    equal(move([1030, 104, 810, 279], topRight, "below"), ["x": 0, "y": 222],
          "a title card under a top-right bubble moves down, 24 px below it (the Tradl case)")
    check(move([1030, 400, 810, 279], topRight, "below") == nil, "a card clear of the bubble stays where it is")
    equal(move([1240, 104, 600, 800], bottomRight, "above"), ["x": -246, "y": 0],
          "a tall card that has no room above a bottom bubble moves beside it, towards the middle")
    equal(move([1300, 200, 540, 760], topRight, "below"), ["x": -246, "y": 0],
          "a tall card that has no room below a top bubble moves beside it")
    equal(move([100, 60, 1720, 900], topRight, "below"), ["x": 0, "y": 66],
          "a card too large for either goes down as far as the safe area lets it")

    // The app gives each column card the bubble's box while the bubble shows with it.
    let screenInfo = MediaInfo(width: 2880, height: 1800, duration: 120, videoCodec: "h264", audioCodec: nil, fps: 30, fpsExpression: "30/1", rotation: 0,
                               colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    var screen = ScreenTrack(url: URL(fileURLWithPath: "/tmp/bubble-screen.mov"), info: screenInfo, offset: 0)
    screen.bubble = SpeakerBubble(corner: .topRight, size: 0.242, shape: .rounded)
    screen.spans = [LayoutSpan(start: 0, end: 10, layout: .speaker)]
    var talk = VideoItem(url: landscape)
    talk.info = MediaInfo(width: 1920, height: 1080, duration: 60, videoCodec: "h264", audioCodec: "aac", fps: 30, fpsExpression: "30/1", rotation: 0,
                          colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    talk.crop = talk.info!.fullFrame; talk.status = .ready
    talk.screen = screen
    let tradlStyle: GraphicsStyle = { var style = GraphicsStyle(); style.size = 1.35; return style }()
    let feedback = gfx(.titleCard, 12, 16, ["kicker": .string("Tradl"), "title": .string("The feedback card"), "detail": .string("What people said")])
    let early = gfx(.titleCard, 2, 6, ["title": .string("In the speaker layout"), "clear": .object(["x": .number(0), "y": .number(0), "w": .number(1920), "h": .number(1080)])])
    let across = gfx(.namePlate, 8, 11, ["title": .string("Yamparala Rahul")])
    let logo = try logoFixture("bubble-logo.png", red: 0, green: 0.6, blue: 1)
    let badge = gfx(.logoBadge, 20, 22, ["logos": .array([.object(["image": .string(logo.path), "at": .number(0)])])])
    talk.graphics = GraphicsTrack(style: tradlStyle, items: [early, across, feedback, badge])
    equal(talk.bubbleBox(), CGRect(x: 1618, y: 40, width: 262, height: 262), "the bubble's box is in design pixels of the 1920×1080 frame")
    let placed = talk.placedGraphics!
    func clear(_ graphic: Graphic, in track: GraphicsTrack) -> [String: JSONValue]? { track.items.first { $0.id == graphic.id }?.props["clear"]?.object }
    equal(clear(feedback, in: placed), ["x": .number(1618), "y": .number(40), "w": .number(262), "h": .number(262), "side": .string("below")],
          "a card in the Screen layout gets the bubble's box, to move below it")
    check(clear(early, in: placed) == nil, "a card in the Speaker layout gets none; a box an agent wrote is removed")
    check(clear(across, in: placed) != nil, "a card that shows when the Screen layout starts gets the box")
    check(clear(badge, in: placed) == nil, "a logo badge gets none: it follows the speaker by itself")
    check(talk.graphics!.items.allSatisfy { $0.id == early.id || $0.props["clear"] == nil } && talk.exportGraphics(ExportSettings()) == placed,
          "the box is worked out for drawing and never stored; the export draws what the preview draws")
    equal(screen.bubbleTime(from: 8, to: 11, endScreen: nil), 10, "the bubble first shows at 10 s, when the Screen layout starts")
    var lowTalk = talk; lowTalk.screen?.bubble.corner = .bottomRight
    equal(clear(feedback, in: lowTalk.placedGraphics!)?["side"], .string("above"), "under a bottom bubble a card moves above it")
    var short = Short(start: 11, end: 20, window: CGRect(x: 700, y: 0, width: 608, height: 1080))
    short.screen = .top
    talk.shorts = [short]
    check(talk.shortGraphics(short)?.items.allSatisfy { $0.props["clear"] == nil } == true, "a Short's graphics get no box: its layout is its own")

    // The engine moves the card, measures where, and leaves a card the owner moved alone.
    let measured = try await GraphicsSnapshot.bounds(placed, duration: 30, fps: "30")
    let bubble = CGRect(x: 1618, y: 40, width: 262, height: 262)
    if let card = measured[feedback.id], let first = measured[early.id] {
        let home = card.placed(GraphicTransform(x: 0.0001, y: 0, scale: 1))
        check(home.intersects(bubble), "at the template's place the title card covers the bubble", "\(home)")
        let moved = card.placed(nil)
        check(!moved.intersects(bubble) && abs(moved.minY - (bubble.maxY + BubbleClear.gap)) < 1 && card.clear.width == 0,
              "the engine moves it straight down to 24 px below the bubble", "\(moved) clear \(card.clear)")
        check(first.clear == .zero, "a card in the Speaker layout does not move")
    } else {
        check(false, "the engine measures the cards", "\(measured)")
    }
    let picture = CGImage.blank(width: 1280, height: 720)
    let shot = try await GraphicsSnapshot.draw(placed, duration: 30, fps: "30", time: 15, over: picture)
    let k = 1280.0 / 1920
    if let drawn = shot.boxes[feedback.id] {
        check(drawn.minY >= (bubble.maxY + BubbleClear.gap) * k - 2 && !drawn.intersects(bubble.applying(CGAffineTransform(scaleX: k, y: k))),
              "the preview draws the card below the bubble", "\(drawn)")
    } else {
        check(false, "the preview draws the title card", "\(shot.boxes)")
    }
    var owned = placed
    let ownIndex = owned.items.firstIndex { $0.id == feedback.id }!
    owned.items[ownIndex].transform = GraphicTransform(x: 0, y: 20, scale: 1)
    let ownShot = try await GraphicsSnapshot.draw(owned, duration: 30, fps: "30", time: 15, over: picture)
    if let drawn = ownShot.boxes[feedback.id], let card = measured[feedback.id] {
        check(abs(drawn.minY - (card.content.minY + 20) * k) < 2, "the owner's own move wins: the card goes where they put it", "\(drawn) vs \(card.content)")
    } else {
        check(false, "the preview draws the moved title card", "\(ownShot.boxes)")
    }

    // state says which graphics still meet the bubble, and when.
    let agent = AppModel(recoveryURL: nil)
    var project = VideoProject(clips: [ProjectClip(talk)], settings: ExportSettings(), selection: talk.id)
    project.clips[0].shorts = nil
    agent.restore(project)
    func screenState() async -> [String: Any] {
        let clips = agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]]
        return clips?.first?["screen"] as? [String: Any] ?? [:]
    }
    let clean = await screenState()
    check((clean["overBubble"] as? [Any])?.isEmpty == true, "state: no graphic meets the bubble once the app has moved the cards", "\(clean["overBubble"] ?? "nil")")
    check((clean["bubbleBox"] as? [String: Double])?["x"] == 1618, "state gives the bubble's box")
    var request = address(agent)
    request["method"] = "apply"; request["requestID"] = "bubble-own"; request["client"] = "Claude"
    request["commands"] = [["type": "updateGraphic", "clipID": talk.id.uuidString, "graphicID": feedback.id.uuidString,
                            "graphic": ["transform": ["x": -10, "y": 20]]]]
    let ownReply = await agentCall(agent, request)
    check(ownReply["ok"] as? Bool == true, "an agent moves the card by hand", "\(ownReply)")
    let over = (await screenState())["overBubble"] as? [[String: Any]] ?? []
    check(over.count == 1 && over.first?["graphicID"] as? String == feedback.id.uuidString && over.first?["at"] as? Double == 12
              && over.first?["why"] as? String == "transform" && over.first?["start"] as? Double == 12,
          "state lists a card moved by hand onto the bubble, with its time and why the app left it", "\(over)")
    var reset = address(agent)
    reset["method"] = "apply"; reset["requestID"] = "bubble-reset"; reset["client"] = "Claude"
    reset["commands"] = [["type": "updateGraphic", "clipID": talk.id.uuidString, "graphicID": feedback.id.uuidString,
                          "graphic": ["transform": ["x": 0, "y": 0, "scale": 1]]]]
    _ = await agentCall(agent, reset)
    let again = (await screenState())["overBubble"] as? [Any]
    check(agent.items[0].graphics?.items.first { $0.id == feedback.id }?.transform == nil && again?.isEmpty == true,
          "a move back to no move at all puts the card clear of the bubble again", "\(again ?? [])")
    var panel = address(agent)
    panel["method"] = "apply"; panel["requestID"] = "bubble-panel"; panel["client"] = "Claude"
    panel["commands"] = [["type": "addGraphic", "clipID": talk.id.uuidString,
                          "graphic": ["kind": "rule", "start": 25, "end": 29,
                                      "props": ["kicker": "Phones", "title": "Text a phone can read",
                                                "points": [["text": "Larger cards", "at": 0.2]]]]]]
    let panelReply = await agentCall(agent, panel)
    let panelOver = (await screenState())["overBubble"] as? [[String: Any]] ?? []
    check(panelReply["ok"] as? Bool == true && panelOver.count == 1 && panelOver.first?["kind"] as? String == "rule"
              && panelOver.first?["why"] as? String == "panel" && (panelOver.first?["bubble"] as? [String: Double])?["x"] == 1138,
          "state lists a side panel over the bubble, where the picture has moved aside for it", "\(panelReply["ok"] ?? "") \(panelOver)")
    let noScreen = AppModel(recoveryURL: nil)
    var plain = talk; plain.screen = nil
    noScreen.restore(VideoProject(clips: [ProjectClip(plain)], settings: ExportSettings(), selection: plain.id))
    let plainClips = agentResult(await agentCall(noScreen, ["method": "state"]))["clips"] as? [[String: Any]]
    check(plainClips?.first?["screen"] is NSNull || plainClips?.first?["screen"] == nil, "without a screen recording there is no bubble to check")

    // A layout part with a bubble of its own: the base bubble is bottom right, and the part
    // from 30 to 40 s moves it to the top right.
    var parts = talk
    parts.shorts = []
    parts.screen?.bubble.corner = .bottomRight
    parts.screen?.spans = [LayoutSpan(start: 0, end: 10, layout: .speaker),
                           LayoutSpan(start: 30, end: 40, layout: .screen, bubble: SpanBubble(corner: .topRight))]
    let inBase = gfx(.titleCard, 12, 16, ["title": .string("Under the base bubble")])
    let across2 = gfx(.titleCard, 26, 34, feedback.props)
    let inPart = gfx(.titleCard, 35, 39, feedback.props)
    parts.graphics = GraphicsTrack(style: tradlStyle, items: [inBase, across2, inPart])
    let partPlaced = parts.placedGraphics!
    equal(clear(inPart, in: partPlaced)?["y"], .number(40), "a card in a part with its own bubble keeps clear of that bubble (top right)")
    equal(clear(inPart, in: partPlaced)?["side"], .string("below"), "and moves below it")
    equal(clear(inBase, in: partPlaced)?["y"], .number(778), "a card outside the part keeps clear of the base bubble (bottom right)")
    equal(clear(across2, in: partPlaced)?["y"], .number(778), "a card that starts before the part keeps clear of the bubble when it is fully in")
    equal(parts.bubblePlaces(from: 26, to: 34, endScreen: nil).map(\.time), [26, 30], "while that card shows, the bubble has two places")
    let partMeasured = try await GraphicsSnapshot.bounds(partPlaced, duration: 60, fps: "30")
    let partBubble = CGRect(x: 1618, y: 40, width: 262, height: 262)
    if let card = partMeasured[inPart.id] {
        check(!card.placed(nil).intersects(partBubble) && abs(card.placed(nil).minY - (partBubble.maxY + BubbleClear.gap)) < 1,
              "the engine moves the card below the part's bubble", "\(card.placed(nil))")
    } else {
        check(false, "the engine measures the card in the part", "\(partMeasured)")
    }
    let partAgent = AppModel(recoveryURL: nil)
    partAgent.restore(VideoProject(clips: [ProjectClip(parts)], settings: ExportSettings(), selection: parts.id))
    let partClips = agentResult(await agentCall(partAgent, ["method": "state"]))["clips"] as? [[String: Any]]
    let partOver = (partClips?.first?["screen"] as? [String: Any])?["overBubble"] as? [[String: Any]] ?? []
    check(partOver.count == 1 && partOver.first?["graphicID"] as? String == across2.id.uuidString && partOver.first?["at"] as? Double == 30
              && partOver.first?["why"] as? String == "otherBubble" && (partOver.first?["bubble"] as? [String: Double])?["y"] == 40,
          "state lists a card that meets the part's bubble but not the base one, from the part's start", "\(partOver)")

    // The manual tells agents to read the list.
    let manual = AgentsManual.text ?? ""
    check(manual.contains("overBubble") && manual.contains("props.clear"), "the Agents Manual has the bubble check")

    if case .ready = await HyperFrames.status() {
        // An export draws the card where the preview does: below the bubble.
        var exportTrack = GraphicsTrack(style: tradlStyle, items: [Graphic(id: feedback.id, kind: .titleCard, start: 0.2, end: 2.8, props: feedback.props)])
        exportTrack.items[0].props["clear"] = BubbleClear(rect: bubble, side: .below).json
        let out = scratch.appendingPathComponent("bubble-clear.mp4"), plainOut = scratch.appendingPathComponent("bubble-plain.mp4")
        try await FFmpeg.export(input: landscape, output: out, info: info, crop: info.fullFrame, settings: ExportSettings(), graphics: exportTrack) { _ in }
        try await FFmpeg.export(input: landscape, output: plainOut, info: info, crop: info.fullFrame, settings: ExportSettings()) { _ in }
        let bounds = try await GraphicsSnapshot.bounds(exportTrack, duration: 3, fps: "30")
        if let card = bounds[feedback.id] {
            let moved = card.placed(nil)
            let inside = (Int(moved.midX * k), Int((moved.minY + 30) * k))
            let inBubble = (Int(bubble.midX * k), Int(bubble.midY * k))
            let cardChanged = try await !unchanged(out, plainOut, x: inside.0, y: inside.1, at: 2.0)
            let bubbleKept = try await unchanged(out, plainOut, x: inBubble.0, y: inBubble.1, at: 2.0)
            check(cardChanged && bubbleKept, "the export draws the card below the bubble and leaves the bubble's area clear",
                  "card \(cardChanged) bubble \(bubbleKept) at \(moved)")
        } else {
            check(false, "the engine measures the exported card", "\(bounds)")
        }
    }
}
