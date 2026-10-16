// Checks for logo badges. Run with ./test.sh logos
import AppKit
import AVFoundation
import Foundation

/// A square PNG of one colour, for a logo.
func logoFixture(_ name: String, red: Double, green: Double, blue: Double) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    return url
}

@MainActor func logosTests() async throws {
    print("\nLogo badges")
    let red = try logoFixture("logo-red.png", red: 1, green: 0, blue: 0)
    let blue = try logoFixture("logo-blue.png", red: 0, green: 0, blue: 1)
    func badge(_ start: Double, _ end: Double, _ logos: [(String, String?, Double)]) -> Graphic {
        gfx(.logoBadge, start, end, ["logos": .array(logos.map { logo in
            var object: [String: JSONValue] = ["image": .string(logo.0), "at": .number(logo.2)]
            if let label = logo.1 { object["label"] = .string(label) }
            return .object(object)
        })])
    }
    check(GraphicKind.logoBadge.zone == .speaker && GraphicKind.logoBadge.isPlaceable && !GraphicKind.logoBadge.hasInk,
          "a logo badge sits next to the speaker, may be moved, and has no ink look")
    let good = badge(1, 3, [(red.path, "Claude", 0), (blue.path, "Codex", 0.6)])
    check(GraphicsTrack(items: [good, gfx(.namePlate, 1, 3)]).problem(duration: 10) == nil,
          "a badge with two logos is good, and it may show with a card in the column", GraphicsTrack(items: [good]).problem(duration: 10) ?? "")
    check(GraphicsTrack(items: [gfx(.logoBadge, 1, 3)]).problem(duration: 10)?.contains("needs logos") == true, "a badge needs logos")
    check(GraphicsTrack(items: [badge(1, 3, [(red.path, nil, 0), (red.path, nil, 0), (red.path, nil, 0), (red.path, nil, 0)])])
              .problem(duration: 10)?.contains("at most 3") == true, "a badge shows at most three logos")
    check(GraphicsTrack(items: [badge(1, 3, [("logo.png", nil, 0)])]).problem(duration: 10)?.contains("absolute") == true,
          "a logo's image is an absolute path")
    check(GraphicsTrack(items: [badge(1, 3, [("/tmp/logo.gif", nil, 0)])]).problem(duration: 10)?.contains("PNG") == true,
          "a logo's image is a picture type the engine draws")
    check(GraphicsTrack(items: [badge(1, 3, [(red.path, String(repeating: "x", count: 31), 0)])]).problem(duration: 10)?.contains("30 characters") == true,
          "a logo's label is 30 characters or fewer")
    check(GraphicsTrack(items: [badge(1, 3, [(red.path, nil, 1.9)])]).problem(duration: 10)?.contains("before the badge ends") == true,
          "each logo pops in a quarter of a second or more before the badge ends")
    check(GraphicsTrack(items: [good, badge(2.5, 4, [(red.path, nil, 0)])]).problem(duration: 10)?.contains("overlap") == true,
          "two logo badges may not overlap")

    print("\nWhere a badge sits")
    equal(LogoBadge.size(good.props, compact: false), CGSize(width: 337.6 + 20 + 310, height: 132), "a badge's size follows its labels, as the CSS draws them")
    equal(LogoBadge.size(good.props, compact: false, vertical: true), CGSize(width: 337.6, height: 284), "one above the other, it is as wide as its widest logo")
    equal(LogoBadge.size(good.props, compact: true), CGSize(width: 254, height: 120), "a compact badge is the logos alone")
    let frame = CGSize(width: 1920, height: 1080), safe = GraphicPlacement.safeArea, size = CGSize(width: 222, height: 88)
    let beside = LogoSpot.place(speaker: CGRect(origin: .zero, size: frame), face: CGPoint(x: 1019, y: 472), scale: 1, frame: frame,
                                clear: safe, size: size, compact: false)
    equal(beside, LogoSpot(x: 1209, y: 472, alignX: .start, alignY: .middle, compact: false),
          "with the speaker filling the frame, the badge goes beside the face, on the side with room")
    let left = LogoSpot.place(speaker: CGRect(origin: .zero, size: frame), face: CGPoint(x: 1600, y: 472), scale: 1, frame: frame,
                              clear: safe, size: size, compact: false)
    check(left.alignX == .end && left.x == 1410, "a face near the right edge puts the badge on its left", "\(left)")
    let tie = LogoSpot.place(speaker: CGRect(x: 0, y: 1088, width: 1080, height: 832), face: CGPoint(x: 468, y: 1304), scale: 0.96,
                             frame: ShortFormat.size, clear: ShortFormat.clearArea, size: CGSize(width: 254, height: 120), compact: true)
    check(tie.alignX == .start && tie.box(size: CGSize(width: 254, height: 120)).maxX == ShortFormat.clearArea.maxX,
          "when neither side has room, the badge stays on the right of the face, kept inside the clear area", "\(tie)")
    let bubble = LogoSpot.place(speaker: CGRect(x: 40, y: 716, width: 324, height: 324), face: CGPoint(x: 200, y: 870), scale: 0.3,
                                frame: frame, clear: safe, size: size, compact: false)
    equal(bubble, LogoSpot(x: 388, y: 878, alignX: .start, alignY: .middle, compact: false), "beside the bubble, towards the middle of the frame")
    let rightBubble = LogoSpot.place(speaker: CGRect(x: 1556, y: 716, width: 324, height: 324), face: nil, scale: 0.3,
                                     frame: frame, clear: safe, size: size, compact: false)
    check(rightBubble.alignX == .end && rightBubble.x == 1532, "a bubble on the right puts the badge on its left", "\(rightBubble)")
    let foot = LogoSpot.place(speaker: CGRect(x: 40, y: 171, width: 556, height: 738), face: nil, scale: 1, frame: frame,
                              clear: safe, size: CGSize(width: 450, height: 88), compact: false)
    check(foot.alignX == .middle && foot.alignY == .end && foot.y == 881 && foot.box(size: CGSize(width: 450, height: 88)).minX == safe.minX,
          "side by side, the badge sits at the foot of the speaker's panel, kept inside the safe area", "\(foot)")

    // A recording with its screen: the speaker's place in each layout.
    let screenInfo = MediaInfo(width: 3248, height: 2008, duration: 750, videoCodec: "h264", audioCodec: nil, fps: 60, fpsExpression: "60/1", rotation: 0,
                               colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    var screen = ScreenTrack(url: URL(fileURLWithPath: "/tmp/screen.mov"), info: screenInfo, offset: 0)
    screen.crop = CGRect(x: 112, y: 76, width: 3024, height: 1784)
    screen.bubble.corner = .bottomLeft
    screen.bubble.face = CGPoint(x: 1019, y: 472)
    screen.spans = [LayoutSpan(start: 0, end: 10, layout: .speaker), LayoutSpan(start: 20, end: 30, layout: .split)]
    var talk = VideoItem(url: landscape)
    talk.info = MediaInfo(width: 1920, height: 1080, duration: 60, videoCodec: "h264", audioCodec: "aac", fps: 30, fpsExpression: "30/1", rotation: 0,
                          colorTransfer: "bt709", colorSpace: "bt709", colorRange: "tv")
    talk.crop = talk.info!.fullFrame; talk.status = .ready
    talk.screen = screen
    let inSpeaker = badge(2, 4, [(red.path, "Claude", 0)]), inScreen = badge(12, 14, [(red.path, "Claude", 0)]), inSplit = badge(22, 24, [(red.path, "Claude", 0)])
    let splitPair = badge(25, 28, [(red.path, "Claude", 0), (blue.path, "Codex", 0.5)])
    talk.graphics = GraphicsTrack(items: [inSpeaker, inScreen, inSplit, splitPair])
    let placed = talk.placedGraphics!
    func spot(_ graphic: Graphic, in track: GraphicsTrack) -> [String: JSONValue] {
        track.items.first { $0.id == graphic.id }?.props["spot"]?.object ?? [:]
    }
    check(spot(inSpeaker, in: placed)["x"]?.number == 1209 && spot(inSpeaker, in: placed)["alignX"]?.string == "start",
          "in the Speaker layout the badge is beside the face", "\(spot(inSpeaker, in: placed))")
    check(spot(inScreen, in: placed)["x"]?.number == 388 && spot(inScreen, in: placed)["y"]?.number == 878,
          "in the Screen layout it is beside the bubble", "\(spot(inScreen, in: placed))")
    check(spot(inSplit, in: placed)["alignY"]?.string == "end" && spot(inSplit, in: placed)["compact"] == .bool(false),
          "side by side it is at the foot of the speaker's panel", "\(spot(inSplit, in: placed))")
    check(spot(splitPair, in: placed)["vertical"] == .bool(true) && spot(inSplit, in: placed)["vertical"] == .bool(false),
          "two logos too wide for the speaker's panel go one above the other", "\(spot(splitPair, in: placed))")
    check(talk.graphics!.items.allSatisfy { $0.props["spot"] == nil } && talk.exportGraphics(ExportSettings()) == placed,
          "the spot is worked out for drawing and never stored; the export draws what the preview draws")

    var short = Short(start: 20, end: 50, window: CGRect(x: 700, y: 0, width: 608, height: 1080))
    short.screen = .top
    talk.shorts = [short]
    let shortTrack = talk.shortGraphics(short)!
    let shortSpot = spot(inSplit, in: shortTrack)
    let shortBox = LogoSpot(x: shortSpot["x"]?.number ?? 0, y: shortSpot["y"]?.number ?? 0,
                            alignX: LogoSpot.Edge(rawValue: shortSpot["alignX"]?.string ?? "") ?? .start,
                            alignY: LogoSpot.Edge(rawValue: shortSpot["alignY"]?.string ?? "") ?? .start, compact: true)
        .box(size: LogoBadge.size(inSplit.props, compact: true))
    check(shortTrack.items.count == 2 && shortTrack.canvas == .short(.sheet) && shortSpot["compact"] == .bool(true)
              && ShortFormat.clearArea.contains(shortBox) && shortTrack.items[0].start == 2,
          "a Short shows its own badges, the logos alone beside the face, inside YouTube's clear area", "\(shortSpot) \(shortBox)")
    check(talk.shortItem(short).exportGraphics(ExportSettings()) == shortTrack,
          "a Short's export draws the badges its viewer shows")
    let viewerTrack = talk.shortGraphics(short, recordingTime: true)!
    check(spot(inSplit, in: viewerTrack) == shortSpot && viewerTrack.items[0].start == 22,
          "the Short viewer places them the same, in recording time")

    print("\nThe engine draws the badge at its spot")
    do {
        let blank = CGImage.blank(width: 1920, height: 1080)
        let drawn = try await GraphicsSnapshot.draw(placed, duration: 60, fps: "30", time: 3, over: blank)
        let box = drawn.boxes[inSpeaker.id]
        let estimate = LogoBadge.size(inSpeaker.props, compact: false)
        check(box.map { abs($0.minX - 1209) < 1.5 && abs($0.midY - 472) < 1.5 && abs($0.width - estimate.width) < estimate.width * 0.15 } == true,
              "the preview draws the badge where the app placed it, about the size the app estimated", "\(String(describing: box)) \(estimate)")
        let stacked = try await GraphicsSnapshot.draw(placed, duration: 60, fps: "30", time: 27, over: blank).boxes[splitPair.id]
        check(stacked.map { abs($0.maxY - 881) < 1.5 && $0.height > 270 && $0.width < 360 } == true,
              "the preview draws them one above the other at the foot of the panel", "\(String(describing: stacked))")
        let early = try await GraphicsSnapshot.draw(placed, duration: 60, fps: "30", time: 1.5, over: blank)
        check(early.boxes[inSpeaker.id] == nil, "nothing shows before the badge starts")
        let both = GraphicsTrack(items: [good])
        let one = try await GraphicsSnapshot.draw(both, duration: 10, fps: "30", time: 1.3, over: blank)
        let two = try await GraphicsSnapshot.draw(both, duration: 10, fps: "30", time: 2.2, over: blank)
        check((one.boxes[good.id]?.width ?? 0) < (two.boxes[good.id]?.width ?? 0) - 100,
              "each logo pops in at its own time", "\(String(describing: one.boxes[good.id])) \(String(describing: two.boxes[good.id]))")
    }
    let nodeBinary = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    if let nodeBinary {
        let planFile = scratch.appendingPathComponent("logo-plan.json")
        try GraphicsTrack(items: [good, gfx(.namePlate, 1, 3)]).engineData(duration: 10, fps: "30").write(to: planFile)
        let script = "const g=require(process.argv[1]);const d=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));"
            + "console.log(JSON.stringify([g.zoneOf('logoBadge'), g.plan(d).units.length]))"
        let planned = try await Shell.run(nodeBinary, ["-e", script, "\(repository)/Resources/Graphics/graphics.js", planFile.path])
        equal(planned.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[\"speaker\",2]",
              "the engine knows the kind's place, and an export draws each badge as a unit of its own")
    }
    check(GraphicsRender.jobs(for: placed, fps: "30", outputWidth: 1920).count == 4, "the export renders each badge once and keeps its frames")

    print("\nFinding brands")
    let said = spokenWords([("all", 1), ("of", 1.2), ("it", 1.4), ("is", 1.6), ("html", 1.8), ("nothing", 2.2), ("is", 2.5), ("on", 2.7), ("figma.", 2.9),
                            ("Next", 4), ("we", 4.2), ("have", 4.4), ("my", 4.6), ("Apple", 4.8), ("watch", 5.1), ("and", 5.4), ("Granola.", 5.6),
                            ("I", 7), ("share", 7.2), ("with", 7.4), ("Claude", 7.6), ("or", 8.0), ("codex.", 8.2), ("Like", 9), ("Next.js", 9.3),
                            ("and", 9.6), ("my", 9.8), ("Rahnotate", 10), ("tool.", 10.4), ("So", 11), ("apple", 11.3), ("html", 12), ("again", 12.4),
                            ("on", 12.6), ("YamDrive", 12.8)], end: 13.5)
    let timeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 60)])
    let library = [LogoLibrary.Logo(name: "Claude", words: ["claude"], file: "claude.png"), LogoLibrary.Logo(name: "Codex", words: ["codex"], file: "codex.png"),
                   LogoLibrary.Logo(name: "HTML", words: ["html"], file: "html.png")]
    let mentions = BrandFinder.mentions(in: said, timeline: timeline, library: library)
    equal(mentions.map(\.name), ["HTML", "Figma", "Apple Watch", "Granola", "Claude", "Codex", "Next.js", "Rahnotate", "HTML", "YamDrive"],
          "the brands said are found: the owner's logos, the app's list and words shaped like names, but not common words")
    equal(mentions.map(\.source.rawValue), ["library", "known", "known", "known", "library", "library", "known", "guess", "library", "guess"],
          "each says where it comes from")
    check(mentions[2].text == "Apple watch" && mentions[2].start == 4.8 && mentions[4].logo?.hasSuffix("claude.png") == true,
          "a name of two words is one mention, and a library logo brings its image", "\(mentions[2]) \(mentions[4])")
    let plan = BrandFinder.plan(mentions, gap: 60, stop: 60, changes: [], taken: [])
    equal(plan.badges.count, 2, "badges are made only for names with a logo")
    check(plan.badges.first.map { abs($0.start - 1.65) < 0.001 && abs($0.end - 3.6) < 0.001 } == true,
          "a badge starts just before its name and holds 1.8 s", "\(plan.badges.first.map { "\($0.start)–\($0.end)" } ?? "")")
    let pair = plan.badges.last.map(\.props).map(LogoBadge.logos) ?? []
    check(pair.map(\.label) == ["Claude", "Codex"] && pair.map(\.at) == [0.15, 0.75] && plan.badges.last.map { abs($0.end - 10.0) < 0.001 } == true,
          "names said close together share one badge, each logo at its word", "\(pair)")
    check(plan.skipped.contains { $0.mention.name == "HTML" && $0.reason.contains("after its last badge") }
              && plan.skipped.contains { $0.mention.name == "Figma" && $0.reason == "no logo yet" },
          "a logo said again within the gap gets no new badge, and a name without a logo none", "\(plan.skipped.map(\.reason))")
    let cutShort = BrandFinder.plan(mentions, gap: 60, stop: 60, changes: [2.9], taken: [])
    check(cutShort.badges.first.map { abs($0.end - 2.9) < 0.001 } == true, "a badge ends at a layout change when that leaves it a second")
    let taken = BrandFinder.plan(mentions, gap: 60, stop: 60, changes: [], taken: [(1, 3)])
    check(taken.badges.count == 1 && taken.skipped.contains { $0.reason.contains("shows there already") }, "a place with a badge already is left as it is")
    check(BrandFinder.plan(mentions, gap: 60, stop: 9, changes: [], taken: []).badges.allSatisfy { $0.end <= 9 }, "no badge runs into the end screen")
    check(GraphicsTrack(items: plan.badges).problem(duration: 60) == nil, "suggested badges are good graphics")

    print("\nThe logo library")
    setenv("YAMVIDEO_LOGOS_DIR", scratch.appendingPathComponent("logos").path, 1)
    defer { unsetenv("YAMVIDEO_LOGOS_DIR") }
    check(LogoLibrary.load().isEmpty, "a new library is empty")
    try LogoLibrary.set(name: "Claude", image: red, words: nil)
    try LogoLibrary.set(name: "Next.js", image: blue, words: ["next.js", "nextjs"])
    try LogoLibrary.set(name: "claude", image: blue, words: ["claude", "claude code"])
    let kept = LogoLibrary.load()
    check(kept.map(\.name) == ["claude", "Next.js"] && kept[0].words == ["claude", "claude code"]
              && FileManager.default.contentsEqual(atPath: LogoLibrary.path(of: kept[0]), andPath: blue.path),
          "setting a logo keeps a copy; the same name again replaces it", "\(kept)")
    check((try? LogoLibrary.set(name: "Bad", image: URL(fileURLWithPath: "/tmp/nothing.gif"), words: nil)) == nil, "a logo must be a picture file")
    try LogoLibrary.remove(name: "CLAUDE")
    check(LogoLibrary.load().map(\.name) == ["Next.js"] && (try? LogoLibrary.remove(name: "Claude")) == nil, "removing a logo takes its file away too")

    print("\nBrands for agents")
    try LogoLibrary.set(name: "Claude", image: red, words: nil)
    var spoken = VideoItem(url: landscape)
    spoken.info = info; spoken.crop = info.fullFrame; spoken.status = .ready
    spoken.transcript = Transcript(model: "test", language: "en", words: spokenWords([("I", 0.2), ("use", 0.4), ("Claude", 0.6), ("and", 1.2),
                                                                                       ("Figma", 1.4), ("daily", 1.9)], end: 2.6))
    let agent = AppModel(recoveryURL: nil)
    agent.restore(VideoProject(clips: [ProjectClip(spoken)], settings: ExportSettings(), selection: spoken.id))
    var asking = address(agent)
    asking["method"] = "analyze"; asking["requestID"] = "logos-1"; asking["kind"] = "logos"; asking["clip"] = spoken.id.uuidString
    let job = agentResult(await agentCall(agent, asking))
    let found = (try await waitForJob(agent, job["id"] as? String ?? ""))["result"] as? [String: Any] ?? [:]
    let suggestions = found["suggestions"] as? [[String: Any]] ?? []
    check(suggestions.count == 1 && (suggestions[0]["names"] as? [String]) == ["Claude"]
              && ((found["missing"] as? [[String: Any]])?.map { $0["name"] as? String ?? "" }) == ["Figma"],
          "analyze with kind logos suggests a badge for each logo and lists the names without one", "\(found)")
    let drafted = await agentCall(agent, ["method": "preview", "clip": spoken.id.uuidString, "time": 1.0, "composed": true,
                                          "draft": [suggestions.first?["graphic"] ?? [:]]])
    check(((agentResult(drafted)["graphics"] as? [[String: Any]])?.contains { $0["kind"] as? String == "logoBadge" }) == true
              && agent.items[0].graphics == nil,
          "a preview draws draft graphics without storing them, to show the owner a plan", "\(drafted)")
    equal(agentError(await agentCall(agent, ["method": "preview", "clip": spoken.id.uuidString, "time": 1.0, "composed": true,
                                             "draft": [["kind": "logoBadge", "start": 0.5, "end": 2.0, "props": [:]]]])), "invalid_command",
          "a draft graphic is checked like a stored one")
    var adding = address(agent)
    adding["method"] = "apply"; adding["requestID"] = "logos-2"; adding["label"] = "Logo Badges"
    adding["commands"] = [["type": "addGraphic", "clipID": spoken.id.uuidString, "graphic": suggestions.first?["graphic"] ?? [:]]]
    let added = await agentCall(agent, adding)
    check(added["ok"] as? Bool == true && agent.items[0].graphics?.items.first?.kind == .logoBadge, "a suggestion is ready for addGraphic", "\(added)")
    let listed = agentResult(await agentCall(agent, ["method": "logos"]))
    check((listed["logos"] as? [[String: Any]])?.map { $0["name"] as? String ?? "" } == ["Claude", "Next.js"], "logos lists the library")
    let setting = await agentCall(agent, ["method": "setLogo", "requestID": "logos-3", "name": "Figma", "path": blue.path, "words": ["figma"]])
    check(((agentResult(setting)["logos"] as? [[String: Any]])?.count) == 3, "setLogo keeps a copy of the owner's logo", "\(setting)")
    equal(agentError(await agentCall(agent, ["method": "removeLogo", "requestID": "logos-4", "name": "Nobody"])), "not_found",
          "removing a logo that is not there is refused")
    let catalog = AgentCatalog.current
    check(catalog.methods.contains { $0.method == "setLogo" } && catalog.methods.contains { $0.method == "logos" }
              && AgentSessionInfo.analyzeKinds.contains("logos"), "the catalog lists the logo requests and the analyze kind")
}
