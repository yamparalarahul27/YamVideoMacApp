// Checks for covers: kinetic text and section cards. Run with ./test.sh covers
import AppKit
import AVFoundation
import Foundation

@MainActor func coversTests() async throws {
    print("\nCovers: the kinds and their rules")
    check(GraphicKind.kineticText.zone == .cover && GraphicKind.sectionCard.zone == .cover
              && !GraphicKind.kineticText.isPlaceable && !GraphicKind.sectionCard.isPlaceable && !GraphicKind.kineticText.hasInk,
          "kinetic text and section cards cover the whole picture and stay where they are")
    let spoken: [String: JSONValue] = ["words": .array([
        .object(["text": .string("every."), "at": .number(0)]), .object(["text": .string("single."), "at": .number(0.4)]),
        .object(["text": .string("*setting.*"), "at": .number(0.8)])]), "layout": .string("stack")]
    let kinetic = gfx(.kineticText, 2, 4, spoken)
    let section = gfx(.sectionCard, 10, 12.5, ["title": .string("Settings"), "kicker": .string("Part 3")])
    check(GraphicsTrack(items: [kinetic, section]).problem(duration: 60) == nil, "a kinetic text and a section card are fine")
    func refused(_ graphic: Graphic, _ words: String, others: [Graphic] = []) -> Bool {
        GraphicsTrack(items: [graphic] + others).problem(duration: 60)?.contains(words) == true
    }
    var outOfOrder = kinetic; outOfOrder.props["words"] = .array([.object(["text": .string("b"), "at": .number(1)]), .object(["text": .string("a"), "at": .number(0.5)])])
    var lateWord = kinetic; lateWord.props["words"] = .array([.object(["text": .string("late"), "at": .number(1.9)])])
    var manyWords = kinetic; manyWords.props["words"] = .array((0..<25).map { .object(["text": .string("w\($0)"), "at": .number(Double($0) * 0.05)]) })
    var noWords = kinetic; noWords.props = ["layout": .string("line")]
    var badLayout = kinetic; badLayout.props["layout"] = .string("grid")
    var badBackground = section; badBackground.props["background"] = .string("blue")
    var unsent = kinetic; unsent.props["words"] = .string("transcript")
    var moved = kinetic; moved.transform = GraphicTransform(x: 10)
    check(refused(outOfOrder, "in order") && refused(lateWord, "before it ends") && refused(manyWords, "1 to 24")
              && refused(noWords, "needs words") && refused(badLayout, "stack") && refused(badBackground, "solid")
              && refused(unsent, "\"transcript\"") && refused(moved, "cannot be moved"),
          "a kinetic text's words, layout and background are checked, saying what is allowed")
    var untitled = section; untitled.props = [:]
    let blink = gfx(.sectionCard, 10, 10.6, ["title": .string("Too quick")])
    check(refused(untitled, "needs a title") && refused(blink, "1 to 8 seconds"), "a section card needs a title and 1 to 8 seconds")
    check(refused(kinetic, "may not show with the title card", others: [gfx(.titleCard, 3, 6, ["title": .string("x")])])
              && refused(kinetic, "slides away", others: [gfx(.rule, 0, 1.5, ["title": .string("x")])])
              && GraphicsTrack(items: [kinetic, gfx(.rule, 0, 1.1, ["title": .string("x")])]).problem(duration: 60) == nil,
          "nothing else shows with a cover, and a panel must have slid away before it")

    print("\nCovers: words from the transcript, places from the edit")
    // Source 0–1 and 1.5–4 are kept; the word at 1.2 is cut, the one at 1.6 plays at 1.1.
    let cutTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 1), TimelineSegment(start: 1.5, end: 4)])
    let transcript = Transcript(model: "test", language: "en", words: [
        TranscriptWord(text: "Hello", start: 0.2, end: 0.5), TranscriptWord(text: "gone", start: 1.2, end: 1.4),
        TranscriptWord(text: "every.", start: 1.6, end: 1.9), TranscriptWord(text: "single.", start: 2.0, end: 2.3),
        TranscriptWord(text: "late", start: 3.3, end: 3.6)])
    let fromWords = KineticText.words(transcript, timeline: cutTimeline, from: 1.0, to: 2.95)
    let pairs = fromWords.compactMap { word -> (String, Double)? in
        guard let text = word.object?["text"]?.string, let at = word.object?["at"]?.number else { return nil }
        return (text, at)
    }
    check(pairs.map(\.0) == ["every.", "single."] && abs(pairs[0].1 - 0.1) < 0.001 && abs(pairs[1].1 - 0.5) < 0.001,
          "a kinetic text takes the words said over its time, each at its edited time, leaving out cut words and the last quarter second",
          "\(pairs)")
    var sectionItem = VideoItem(url: landscape)
    sectionItem.segments = [TimelineSegment(start: 0, end: 100)]
    let sectionTrack = GraphicsTrack(items: [gfx(.sectionCard, 50, 52.5, ["title": .string("B")]), gfx(.sectionCard, 10, 12.5, ["title": .string("A")])])
    let placed = sectionItem.placingSections(sectionTrack, short: nil)
    let progress = placed.items.map { $0.props["progress"]?.number ?? -1 }
    let marks = placed.items.first?.props["marks"]?.array?.compactMap(\.number) ?? []
    check(progress == [0.5, 0.1] && marks == [0.1, 0.5], "each section card gets how far into the video it starts, and where every card starts",
          "\(progress) \(marks)")
    let shortPlaced = sectionItem.placingSections(sectionTrack, short: Short(start: 40, end: 70))
    check(abs((shortPlaced.items[0].props["progress"]?.number ?? 0) - 0.3333) < 0.0001
              && shortPlaced.items[0].props["marks"]?.array?.count == 1,
          "in a Short a section card shows how far into the Short it starts")

    print("\nCovers: drawing")
    let grey = CGImage.blank(width: 1280, height: 720)
    func bright(_ image: CGImage) -> Int {
        var count = 0
        for y in stride(from: 100, to: 620, by: 4) { for x in stride(from: 100, to: 1180, by: 4) {
            let p = rgb(image, x, y); if p.0 > 200 && p.1 > 200 && p.2 > 200 { count += 1 }
        } }
        return count
    }
    let kineticTrack = GraphicsTrack(items: [kinetic])
    let early = try await GraphicsSnapshot.draw(kineticTrack, duration: 10, fps: "30", time: 2.3, over: grey)
    let late = try await GraphicsSnapshot.draw(kineticTrack, duration: 10, fps: "30", time: 3.4, over: grey)
    let corner = rgb(late.image, 20, 20), greyCorner = rgb(grey, 20, 20)
    check(corner.0 < 20 && corner.1 < 20 && corner.2 < 20 && greyCorner.0 > 40, "a solid cover is near black over the picture", "\(corner) over \(greyCorner)")
    check(bright(early.image) > 50 && bright(late.image) > bright(early.image) + 50,
          "the words come in on their times: one first, all three later", "\(bright(early.image)) then \(bright(late.image))")
    var accentFound = false
    for y in stride(from: 100, to: 620, by: 3) where !accentFound { for x in stride(from: 100, to: 1180, by: 3) {
        let p = rgb(late.image, x, y); if p.0 > 220 && p.1 > 170 && p.1 < 215 && p.2 < 90 { accentFound = true; break }
    } }
    check(accentFound, "a word between asterisks takes the accent colour")
    var dimmed = kinetic; dimmed.props["background"] = .string("dim")
    let dimShot = try await GraphicsSnapshot.draw(GraphicsTrack(items: [dimmed]), duration: 10, fps: "30", time: 3.4, over: grey)
    let dimCorner = rgb(dimShot.image, 20, 20)
    check(dimCorner.0 < greyCorner.0 - 30, "a dim cover darkens the picture", "\(dimCorner) over \(greyCorner)")
    var overlaid = kinetic; overlaid.props["background"] = .string("overlay")
    check(GraphicsTrack(items: [overlaid]).problem(duration: 60) == nil, "a cover may use the overlay background")
    let overlayShot = try await GraphicsSnapshot.draw(GraphicsTrack(items: [overlaid]), duration: 10, fps: "30", time: 3.4, over: grey)
    let overlayTop = rgb(overlayShot.image, 20, 20), overlayBottom = rgb(overlayShot.image, 20, 700)
    check(abs(overlayTop.0 - greyCorner.0) < 8 && overlayBottom.0 < greyCorner.0 - 30,
          "an overlay cover keeps the picture at the top and darkens it at the bottom", "\(overlayTop) \(overlayBottom) over \(greyCorner)")

    // The bar's fill (and its knob) in the accent: how far right it reaches, in the 1280 frame.
    func fillEnd(_ image: CGImage) -> Int {
        var right = -1
        for y in stride(from: 300, to: 700, by: 2) { for x in stride(from: 0, to: 1280, by: 2) {
            let p = rgb(image, x, y); if p.0 > 220 && p.1 > 170 && p.1 < 215 && p.2 < 90 { right = max(right, x) }
        } }
        return right
    }
    let halfway = gfx(.sectionCard, 10, 12.5, ["title": .string("Settings"), "progress": .number(0.5), "marks": .array([.number(0.25), .number(0.5), .number(0.75)])])
    let starting = try await GraphicsSnapshot.draw(GraphicsTrack(items: [halfway]), duration: 60, fps: "30", time: 10.4, over: grey)
    let filled = try await GraphicsSnapshot.draw(GraphicsTrack(items: [halfway]), duration: 60, fps: "30", time: 12.0, over: grey)
    let k = 1280.0 / 1920
    let expectedEnd = Int((260 + 0.5 * 1400 + 21) * k), startEnd = Int((260 + 0.25 * 1400 + 21) * k)
    check(abs(fillEnd(filled.image) - expectedEnd) < 12 && abs(fillEnd(starting.image) - startEnd) < 12,
          "the bar fills from the section before up to where this card starts", "\(fillEnd(starting.image)) → \(fillEnd(filled.image)), want \(startEnd) → \(expectedEnd)")

    print("\nCovers: Shorts and agents")
    let caption = Caption(start: 0, end: 4, text: "every single setting")
    let shortCover = GraphicsTrack(items: [gfx(.kineticText, 1, 2.5, ["text": .string("every single setting")])], canvas: .short(.sheet))
    let underCover = ShortCaptionLayout.layout([caption], graphics: shortCover, option: .over, size: .medium)
    check(!underCover.isEmpty && underCover.allSatisfy { $0.end <= 1.0001 || $0.start >= 2.4999 },
          "a Short's captions pause under a cover, whatever its caption option", "\(underCover.map { ($0.start, $0.end) })")

    let agent = AppModel(recoveryURL: nil)
    var spokenItem = VideoItem(url: landscape); spokenItem.info = info; spokenItem.crop = info.fullFrame
    let length = min(4, info.duration)
    spokenItem.segments = [TimelineSegment(start: 0, end: length)]
    spokenItem.transcript = Transcript(model: "test", language: "en", words: [
        TranscriptWord(text: "Your", start: 0.3, end: 0.5), TranscriptWord(text: "player,", start: 0.6, end: 0.9),
        TranscriptWord(text: "your", start: 1.0, end: 1.2), TranscriptWord(text: "VLC.", start: 1.3, end: 1.6)])
    agent.restore(VideoProject(clips: [ProjectClip(spokenItem)], settings: ExportSettings(), selection: spokenItem.id))
    var adding = address(agent)
    adding["method"] = "apply"; adding["requestID"] = "covers-1"; adding["client"] = "Claude"
    adding["commands"] = [["type": "addGraphic", "clipID": spokenItem.id.uuidString,
                           "graphic": ["kind": "kineticText", "start": 0.2, "end": 2.2, "props": ["words": "transcript"]]]]
    let reply = await agentCall(agent, adding)
    let filledWords = agent.items[0].graphics?.items.first?.props["words"]?.array?.compactMap { $0.object?["text"]?.string } ?? []
    check(reply["ok"] as? Bool == true && filledWords == ["Your", "player,", "your", "VLC."],
          "an agent's words \"transcript\" become the words said over the kinetic text's time", "\(reply) \(filledWords)")
    adding["requestID"] = "covers-2"; adding["expectedRevision"] = agent.revision
    adding["commands"] = [["type": "addGraphic", "clipID": spokenItem.id.uuidString,
                           "graphic": ["kind": "kineticText", "start": 2.5, "end": 3.5, "props": ["words": "transcript"]]]]
    check(agentError(await agentCall(agent, adding)) == "invalid_command", "with no words said over its time, it is refused")
}
