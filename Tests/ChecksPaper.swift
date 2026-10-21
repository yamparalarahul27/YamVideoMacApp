// Checks for the graphics' Paper look (docs/plans/graphics-gallery.md, part 2). Run with ./test.sh paper
import AppKit
import AVFoundation
import Foundation

/// The share of `box` (pixels of `image`) that is the paper's off-white, #F7F2E7.
private func paperShare(_ image: CGImage, _ box: CGRect) -> Double {
    let bytes = rgbaBytes(image)
    let area = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var paper = 0, total = 0
    for y in stride(from: Int(area.minY), to: Int(area.maxY), by: 3) {
        for x in stride(from: Int(area.minX), to: Int(area.maxX), by: 3) {
            let i = (y * image.width + x) * 4
            total += 1
            if abs(Int(bytes[i]) - 0xF7) < 10 && abs(Int(bytes[i + 1]) - 0xF2) < 10 && abs(Int(bytes[i + 2]) - 0xE7) < 12 { paper += 1 }
        }
    }
    return Double(paper) / Double(max(1, total))
}

/// RGBA bytes of `image`, top row first.
private func rgbaBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// The first row from the top of `box` where column `x` is the paper's off-white.
private func paperTop(_ image: CGImage, _ bytes: [UInt8], x: Int, box: CGRect) -> Int? {
    for y in Int(box.minY)..<Int(box.maxY) {
        let i = (y * image.width + x) * 4
        if abs(Int(bytes[i]) - 0xF7) < 10 && abs(Int(bytes[i + 1]) - 0xF2) < 10 && abs(Int(bytes[i + 2]) - 0xE7) < 12 { return y }
    }
    return nil
}

/// The dark ink of the title in `box`: the left and right edges of pixels much darker than the paper.
private func inkSpan(_ image: CGImage, _ bytes: [UInt8], box: CGRect) -> (left: Int, right: Int)? {
    var left = Int.max, right = Int.min
    for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) {
        let i = (y * image.width + x) * 4
        if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 200 { left = min(left, x); right = max(right, x) }
    } }
    return left <= right ? (left, right) : nil
}

@MainActor func paperTests() async throws {
    print("\nPaper: the look rules")
    var paperStyle = GraphicsStyle(); paperStyle.look = .paper
    let paperTrack = GraphicsTrack(style: paperStyle)
    let cardKinds = GraphicKind.allCases.filter(\.hasPaper)
    check(Set(cardKinds) == [.namePlate, .titleCard, .sectionCard, .panelTitle], "the card kinds have the Paper look", "\(cardKinds)")
    check(cardKinds.allSatisfy { paperTrack.look(of: gfx($0, 0, 1)) == .paper }
              && GraphicKind.allCases.filter { !$0.hasPaper }.allSatisfy { paperTrack.look(of: gfx($0, 0, 1)) == .glass },
          "a Paper style draws the card kinds on paper and keeps the other kinds glass")
    check(GraphicsTrack().look(of: gfx(.titleCard, 0, 1, look: .paper)) == .paper && GraphicsTrack().look(of: gfx(.rule, 0, 1, look: .paper)) == .glass
              && paperTrack.look(of: gfx(.titleCard, 0, 1, look: .glass)) == .glass && paperTrack.look(of: gfx(.panelTitle, 0, 1, look: .ink)) == .ink,
          "one graphic can choose Paper, a kind without it stays glass, and a graphic's own look wins over the style")
    let paperSpans = GraphicsTrack(style: paperStyle, items: [gfx(.panelTitle, 0, 1)]).panelSpans()
    check(paperSpans.count == 1 && !paperSpans[0].ink, "a paper panel title keeps the panel's shade, not the ink haze")
    let labelled = gfx(.titleCard, 0.2, 2.8, ["kicker": .string("The best feature"), "title": .string("Codex"),
                                               "detail": .string("Computer Use"), "label": .string("most powerful feature")], look: .paper)
    var longLabel = labelled; longLabel.props["label"] = .string(String(repeating: "x", count: PaperLook.labelLimit + 1))
    var twoLines = labelled; twoLines.props["label"] = .string("one\ntwo")
    var numberLabel = labelled; numberLabel.props["label"] = .number(3)
    check(GraphicsTrack(items: [labelled]).problem(duration: 3) == nil
              && GraphicsTrack(items: [longLabel]).problem(duration: 3)?.contains("\(PaperLook.labelLimit) characters") == true
              && GraphicsTrack(items: [twoLines]).problem(duration: 3)?.contains("one line") == true
              && GraphicsTrack(items: [numberLabel]).problem(duration: 3) != nil,
          "a paper label is one line of \(PaperLook.labelLimit) characters or fewer")

    var paperProject = VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id)
    paperProject.clips[0].graphics = GraphicsTrack(style: paperStyle, items: [labelled])
    let savedPaper = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(paperProject))
    check(savedPaper == paperProject && savedPaper.version == VideoProject.currentVersion && VideoProject.currentVersion >= 26
              && savedPaper.clips[0].graphics?.style.look == .paper && savedPaper.clips[0].graphics?.items[0].props["label"]?.string == "most powerful feature",
          "the Paper look and a label survive a project round trip")
    var paperAs25 = savedPaper; paperAs25.version = 25
    var oneAs25 = savedPaper; oneAs25.version = 25; oneAs25.clips[0].graphics?.style.look = .glass
    var plainAs25 = oneAs25; plainAs25.clips[0].graphics?.items[0].look = nil
    check((try? paperAs25.validate()) == nil && (try? oneAs25.validate()) == nil && (try? plainAs25.validate()) != nil,
          "a version 25 file in the Paper look, for the style or one graphic, is refused; without it the file opens")

    print("\nPaper: the engine and the app agree")
    if let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        var cases: [JSONValue] = [], expected: [String] = []
        for kind in GraphicKind.allCases { for own in [nil] + GraphicsLook.allCases.filter({ $0 != .mix }) { for styleLook in GraphicsLook.allCases {
            var graphic: [String: JSONValue] = ["kind": .string(kind.rawValue)]
            if let own { graphic["look"] = .string(own.rawValue) }
            cases.append(.object(["graphic": .object(graphic), "style": .object(["look": .string(styleLook.rawValue)])]))
            var style = GraphicsStyle(); style.look = styleLook
            expected.append(GraphicsTrack(style: style).look(of: gfx(kind, 0, 1, look: own)).rawValue)
        } } }
        let casesFile = scratch.appendingPathComponent("paper-looks.json")
        try JSONEncoder().encode(JSONValue.array(cases)).write(to: casesFile)
        let script = "const g=require(process.argv[1]);const cases=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));"
            + "const accents=['#F5C42C','#D962C0','#3A6FF7','#FFFFFF','#000000','#7BE0B0','#808080','#FF7A00'];"
            + "console.log(JSON.stringify({kinds:g.PAPER_KINDS.slice().sort(),looks:cases.map(c=>g.lookOf(c.graphic,c.style)),"
            + "kicker:Math.min(...accents.map(a=>{const p=g.paperColours(a);return g.contrast(p.kicker,p.card)})),"
            + "sticker:Math.min(...accents.map(a=>{const p=g.paperColours(a);return g.contrast(p.sticker,p.stickerInk)}))}))"
        let ran = try await Shell.run(node, ["-e", script, "\(repository)/Resources/Graphics/graphics.js", casesFile.path])
        let answer = (try? JSONSerialization.jsonObject(with: Data(ran.stdoutText.utf8))) as? [String: Any] ?? [:]
        check((answer["kinds"] as? [String]) == cardKinds.map(\.rawValue).sorted(), "the engine draws the same kinds on paper as the app says", ran.stdoutText + ran.stderrText)
        let looks = answer["looks"] as? [String] ?? []
        let mismatch = zip(looks, expected).enumerated().first { $0.element.0 != $0.element.1 }
        check(looks.count == expected.count && mismatch == nil,
              "the engine picks the same look as the app for every kind, own look and style look (\(expected.count) cases)",
              mismatch.map { "case \($0.offset): engine \($0.element.0), app \($0.element.1)" } ?? "\(looks.count) of \(expected.count)")
        check(((answer["kicker"] as? Double) ?? 0) >= 4.5 && ((answer["sticker"] as? Double) ?? 0) >= 3,
              "the eyebrow reads on the paper (4.5:1 or more) and the label on its sticker (3:1 or more) for light, dark and mid accents",
              "kicker \(answer["kicker"] ?? "nil"), sticker \(answer["sticker"] ?? "nil")")
    } else {
        print("  --   engine look parity skipped (no node)")
    }

    print("\nPaper: fonts")
    let engine = URL(fileURLWithPath: repository).appendingPathComponent("Resources/Graphics")
    let css = try String(contentsOf: engine.appendingPathComponent("graphics.css"), encoding: .utf8)
    let thirdParty = try String(contentsOf: engine.appendingPathComponent("THIRD-PARTY.md"), encoding: .utf8)
    let fontFiles = try FileManager.default.contentsOfDirectory(atPath: engine.appendingPathComponent("fonts").path).sorted()
    let paperFonts = ["Fraunces-900-latin.woff2", "Fraunces-700-italic-latin.woff2"]
    check(paperFonts.allSatisfy(fontFiles.contains) && fontFiles.contains("Fraunces-OFL.txt")
              && paperFonts.allSatisfy(thirdParty.contains) && thirdParty.contains("Fraunces-OFL.txt"),
          "Fraunces is bundled with its licence, and THIRD-PARTY.md lists it", "\(fontFiles)")
    let cssFonts = css.components(separatedBy: "url(\"fonts/").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
    check(fontFiles.filter { $0.hasSuffix(".woff2") }.allSatisfy(cssFonts.contains) && cssFonts.allSatisfy(fontFiles.contains),
          "every bundled font has its @font-face, and every @font-face has its file", "\(cssFonts)")
    let pageFolder = scratch.appendingPathComponent("paper-page", isDirectory: true)
    _ = try GraphicsEngine.writePage(GraphicsTrack(style: paperStyle, items: [labelled]), duration: 3, fps: "30", mode: "unit", unit: labelled.id.uuidString,
                                     origin: 0, to: pageFolder)
    check(paperFonts.allSatisfy { FileManager.default.fileExists(atPath: pageFolder.appendingPathComponent("fonts/\($0)").path) },
          "an export page carries the Paper fonts, so HyperFrames in Chrome draws them without the Mac's fonts")

    print("\nPaper: the engine draws it")
    let cardID = UUID()
    let card = Graphic(id: cardID, kind: .titleCard, start: 0.2, end: 3.2, props: ["kicker": .string("Feedback 1"), "title": .string("Use the space"),
                                                                                  "detail": .string("A wider strategy panel"), "label": .string("best feature")], look: .paper)
    var bare = card; bare.props["label"] = nil
    let cardTrack = GraphicsTrack(items: [card])
    let measuredCard = try await GraphicsSnapshot.bounds(cardTrack, duration: 4, fps: "30")[cardID]
    let measuredBare = try await GraphicsSnapshot.bounds(GraphicsTrack(items: [bare]), duration: 4, fps: "30")[cardID]
    guard let cardBox = measuredCard, let bareBox = measuredBare else {
        check(false, "the engine measures the paper card", "\(String(describing: measuredCard)) \(String(describing: measuredBare))"); return
    }
    check(bareBox.origin == CGPoint(x: 1240, y: 72) && bareBox.content.minX >= 1236 && bareBox.content.maxX <= 1880
              && bareBox.content.minY > 72 && bareBox.content.width > 560,
          "a paper title card sits in the column, its tape and its tilt inside it", "\(bareBox.content)")
    check(cardBox.content.maxY > bareBox.content.maxY + 30 && abs(cardBox.content.minY - bareBox.content.minY) < 1,
          "the label hangs below the card", "\(bareBox.content) → \(cardBox.content)")
    let backdrop = CGImage.blank(width: 1920, height: 1080)
    func shot(_ track: GraphicsTrack, _ time: Double) async throws -> CGImage {
        try await GraphicsSnapshot.draw(track, duration: 4, fps: "30", time: time, over: backdrop).image
    }
    let settled = try await shot(cardTrack, 1.6)
    let paperSettled = paperShare(settled, bareBox.content)
    let settledBytes = rgbaBytes(settled)
    let card80 = bareBox.content.insetBy(dx: 80, dy: 0)
    if let leftTop = paperTop(settled, settledBytes, x: Int(card80.minX), box: bareBox.content),
       let rightTop = paperTop(settled, settledBytes, x: Int(card80.maxX), box: bareBox.content) {
        check(leftTop - rightTop >= 4 && leftTop - rightTop < 30, "the card has a small tilt to the left", "top edge \(leftTop) → \(rightTop)")
    } else {
        check(false, "the card's top edge is found on the paper")
    }
    check(paperSettled > 0.45, "the card is the paper's off-white once it has come in", String(format: "%.2f", paperSettled))
    let early = paperShare(try await shot(cardTrack, 0.25), bareBox.content)
    let leaving = paperShare(try await shot(cardTrack, 2.95), bareBox.content)
    let lastFrame = try await shot(cardTrack, 3.2 - 1.0 / 30)
    let lastShare = paperShare(lastFrame, cardBox.content)
    check(early < paperSettled * 0.8 && leaving < paperSettled * 0.5 && lastShare < 0.005,
          "the card drops in, and goes out smoothly: on its last frame nothing of it is left",
          String(format: "start %.2f, settled %.2f, leaving %.2f, last frame %.3f", early, paperSettled, leaving, lastShare))

    // The other card kinds: each draws on paper, and is gone on its last frame.
    let others: [(Graphic, Double)] = [
        (Graphic(kind: .namePlate, start: 0, end: 3, props: ["kicker": .string("Yamparala Media"), "title": .string("Yamparala Rahul"),
                                                            "detail": .string("UX Design Engineer")], look: .paper), 1.6),
        (Graphic(kind: .sectionCard, start: 0, end: 2.5, props: ["kicker": .string("Part 3"), "title": .string("Backtest results"),
                                                               "background": .string("overlay"), "marks": .array([.number(0.3)]), "progress": .number(0.3)], look: .paper), 1.5),
        (Graphic(kind: .panelTitle, start: 0, end: 3, props: ["kicker": .string("Three fixes"), "title": .string("What I would change"),
                                                             "count": .number(3)], look: .paper), 2.2),
    ]
    for (graphic, beat) in others {
        let track = GraphicsTrack(items: [graphic])
        let box = try await GraphicsSnapshot.bounds(track, duration: 4, fps: "30")[graphic.id]?.content ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let shown = paperShare(try await shot(track, beat), box), gone = paperShare(try await shot(track, graphic.end - 1.0 / 30), box)
        check(shown > (graphic.kind == .sectionCard ? 0.12 : 0.4) && gone < 0.005,
              "a paper \(graphic.kind.label.lowercased()) draws on paper and is gone on its last frame", String(format: "%.2f → %.3f", shown, gone))
    }
    let glassTrack = GraphicsTrack(items: [gfx(.titleCard, 0.2, 3.2, card.props, look: .glass), gfx(.featureList, 0.2, 3.2, look: .paper)])
    check(paperShare(try await shot(glassTrack, 1.6), CGRect(x: 1240, y: 72, width: 640, height: 900)) < 0.005,
          "a glass title card and a feature list asked for paper stay glass")

    print("\nPaper: agents")
    let agent = AppModel(recoveryURL: nil)
    agent.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    let clipID = gradeOther.id.uuidString
    func apply(_ id: String, _ commands: [[String: Any]]) async -> [String: Any] {
        var request = address(agent)
        request["method"] = "apply"; request["requestID"] = id; request["client"] = "Claude"; request["commands"] = commands
        return await agentCall(agent, request)
    }
    let added = await apply("paper-1", [["type": "addGraphic", "clipID": clipID, "graphic": [
        "kind": "titleCard", "start": 0.2, "end": 2.8, "look": "paper",
        "props": ["kicker": "The best feature", "title": "Codex", "detail": "Computer Use", "label": "most powerful feature"]]]])
    let addedCard = agent.items[0].graphics?.items.first
    check(added["ok"] as? Bool == true && addedCard?.look == .paper && addedCard?.props["label"]?.string == "most powerful feature",
          "an agent adds a title card in Paper with a label", "\(added)")
    let styled = await apply("paper-2", [["type": "setGraphicsStyle", "clipID": clipID, "graphicsStyle": ["look": "paper"]]])
    check(styled["ok"] as? Bool == true && agent.items[0].graphics?.style.look == .paper, "an agent sets the style's look to paper", "\(styled)")
    let paperState = (agentResult(await agentCall(agent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["graphics"] as? [String: Any]
    let stateItem = (paperState?["items"] as? [[String: Any]])?.first
    check((paperState?["style"] as? [String: Any])?["look"] as? String == "paper" && stateItem?["look"] as? String == "paper"
              && (stateItem?["props"] as? [String: Any])?["label"] as? String == "most powerful feature",
          "state shows the Paper look and the label")
    let cleared = await apply("paper-3", [["type": "updateGraphic", "clipID": clipID, "graphicID": addedCard?.id.uuidString ?? "", "graphic": ["look": ""]]])
    check(cleared["ok"] as? Bool == true && agent.items[0].graphics?.items.first?.look == nil
              && agent.items[0].graphics.map { $0.look(of: $0.items[0]) } == .paper,
          "look \"\" goes back to the style's choice, here Paper")
    let wood = await apply("paper-4", [["type": "updateGraphic", "clipID": clipID, "graphicID": addedCard?.id.uuidString ?? "", "graphic": ["look": "wood"]]])
    let woodStyle = await apply("paper-5", [["type": "setGraphicsStyle", "clipID": clipID, "graphicsStyle": ["look": "wood"]]])
    let tooLong = await apply("paper-6", [["type": "updateGraphic", "clipID": clipID, "graphicID": addedCard?.id.uuidString ?? "",
                                           "graphic": ["props": ["title": "Codex", "label": String(repeating: "x", count: 40)]]]])
    func message(_ reply: [String: Any]) -> String { (reply["error"] as? [String: Any])?["message"] as? String ?? "" }
    check(agentError(wood) == "invalid_command" && message(wood).contains("\"paper\"")
              && agentError(woodStyle) == "invalid_command" && message(woodStyle).contains("paper")
              && agentError(tooLong) == "invalid_command" && message(tooLong).contains("\(PaperLook.labelLimit)"),
          "an unknown look or a long label is refused, saying what is allowed", message(wood) + " | " + message(woodStyle) + " | " + message(tooLong))
    let catalog = AgentCatalog.current
    let addGraphic = catalog.commands.first { $0.type == "addGraphic" }.map { "\($0)" } ?? ""
    let setStyle = catalog.commands.first { $0.type == "setGraphicsStyle" }.map { "\($0)" } ?? ""
    check(addGraphic.contains("paper") && addGraphic.contains("label") && setStyle.contains("glass|ink|mix|paper"),
          "the catalog tells agents about the Paper look and the label")
    let manual = (try? String(contentsOf: URL(fileURLWithPath: repository).appendingPathComponent("Resources/AgentsManual.md"), encoding: .utf8)) ?? ""
    check(manual.contains("`look: \"paper\"`") && manual.contains("`label`"), "the Agents Manual has the Paper look")

    print("\nPaper: the gallery")
    check(GalleryLook(style: paperStyle) == .paper && GalleryLook.allCases.map(\.label) == ["Glass", "Ink", "Paper"],
          "the gallery's Look switch has Paper, and opens in it for a Paper style")
    check(GalleryLook.paper.graphicLook(for: .titleCard) == .paper && GalleryLook.paper.graphicLook(for: .checklist) == .glass
              && GalleryLook.paper.graphicLook(for: .featureList) == nil && GalleryLook.glass.graphicLook(for: .titleCard) == .glass
              && GalleryLook.ink.graphicLook(for: .namePlate) == .glass && GalleryLook.ink.graphicLook(for: .panelTitle) == .ink,
          "each look names the look of every kind that has more than one, so the recording's style never changes a tile")
    check(GalleryLook.paper.addedLook(for: .titleCard, style: GraphicsStyle()) == .paper && GalleryLook.paper.addedLook(for: .titleCard, style: paperStyle) == nil
              && GalleryLook.glass.addedLook(for: .titleCard, style: paperStyle) == .glass && GalleryLook.paper.addedLook(for: .featureList, style: GraphicsStyle()) == nil
              && GalleryLook.paper.name(for: .featureList) == "Glass" && GalleryLook.paper.name(for: .sectionCard) == "Paper",
          "+ gives a card its own Paper look only where the style draws it otherwise, and the bar names the look a kind shows in")
    let titleSample = GallerySample.all.first { $0.kind == .titleCard }!
    let paperProblems = GallerySample.all.compactMap { s in s.track(style: GraphicsStyle(), look: .paper).problem(duration: s.length).map { s.id + ": " + $0 } }
    check(paperProblems.isEmpty && titleSample.props(for: .paper)["label"] != nil && titleSample.props(for: .glass)["label"] == nil
              && titleSample.pictureKey(style: GraphicsStyle(), look: .paper) != titleSample.pictureKey(style: GraphicsStyle(), look: .glass),
          "every sample is valid in Paper, the title card's shows a label, and each look has its own picture", paperProblems.joined(separator: "; "))
    let paperTile = try await GalleryPictures.draw(titleSample, style: GraphicsStyle(), look: .paper)
    let glassTile = try await GalleryPictures.draw(titleSample, style: GraphicsStyle(), look: .glass)
    let wholeTile = { (image: CGImage) in CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    check(paperShare(paperTile.image, wholeTile(paperTile.image)) > 0.15 && paperShare(glassTile.image, wholeTile(glassTile.image)) < 0.005,
          "the gallery draws the title card's tile on paper in Paper, and in glass in Glass",
          String(format: "%.2f, %.3f", paperShare(paperTile.image, wholeTile(paperTile.image)), paperShare(glassTile.image, wholeTile(glassTile.image))))
    let gallery = AppModel(recoveryURL: nil)
    gallery.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    gallery.setPreviewFraction(0.2)
    gallery.galleryLook = .paper
    gallery.toggleGalleryDraft(titleSample)
    let paperDraft = gallery.galleryDraftGraphic
    check(paperDraft?.look == .paper && paperDraft?.props["label"] != nil && gallery.selectedItem?.graphics == nil,
          "a click shows the title card in Paper on the Preview, with its label, and changes nothing")
    gallery.addFromGallery(titleSample)
    let paperAdded = gallery.selectedItem?.graphics?.items.first
    check(paperAdded?.kind == .titleCard && paperAdded?.look == .paper && gallery.selectedItem?.graphics.map { $0.look(of: paperAdded!) } == .paper,
          "+ adds the title card in Paper", "\(String(describing: paperAdded?.look))")

    // The preview draws in WebKit and the export in HyperFrames' Chrome, which has no Mac
    // fonts: both must draw the same card with the bundled fonts.
    if case .ready = await HyperFrames.status() {
        print("\nPaper: preview and export")
        var parityTrack = GraphicsTrack(items: [card])
        parityTrack.style.accent = "#D962C0"
        let jobs = GraphicsRender.jobs(for: parityTrack, fps: "30", outputWidth: 1920)
        for job in jobs { try? FileManager.default.removeItem(at: job.folder) }
        let node = try await HyperFrames.findNode().get()
        try await GraphicsRender.render(jobs, progress: { _ in }) { job, page, frames in
            try await HyperFrames.render(page: page, to: frames, fps: job.fps, scale: job.scale, node: node)
        }
        guard let job = jobs.first else { check(false, "the paper card has a render unit"); return }
        // WebKit and Chrome smooth edges a little differently, so the check looks for layout:
        // the frames line up best with no shift, only edge pixels differ much, and the title's
        // ink (its font) has the same width.
        var worstMean = 0.0, worstEdges = 0.0, worstInk = 0, shifted = false
        for time in [0.9, 1.6, 2.5] {
            let index = Int(((time - job.unit.origin) * 30).rounded()) + 1
            let file = job.folder.appendingPathComponent(String(format: "frame_%06d.png", index))
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                check(false, "HyperFrames drew frame \(index) of the paper card"); continue
            }
            let exported = backdrop.drawn { $0.draw(frame, in: CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height)) }
            let preview = try await GraphicsSnapshot.draw(parityTrack, duration: 4, fps: "30", time: time, over: backdrop).image
            let a = rgbaBytes(preview), b = rgbaBytes(exported)
            let box = cardBox.content.insetBy(dx: -8, dy: -8).integral
            func compare(shift: Int) -> (mean: Double, edges: Double) {
                var total = 0.0, far = 0, count = 0
                for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 2) { for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 2) {
                    let i = (y * preview.width + x) * 4, j = (y * preview.width + x + shift) * 4
                    let d = (0..<3).reduce(0.0) { $0 + abs(Double(a[i + $1]) - Double(b[j + $1])) } / 3
                    total += d; count += 1
                    if d > 48 { far += 1 }
                } }
                return (total / Double(max(1, count)), Double(far) / Double(max(1, count)))
            }
            let still = compare(shift: 0)
            shifted = shifted || [-2, -1, 1, 2].contains { compare(shift: $0).mean <= still.mean }
            worstMean = max(worstMean, still.mean); worstEdges = max(worstEdges, still.edges)
            // The title's ink, a band across the card's middle: its width shows the font.
            let title = CGRect(x: bareBox.content.minX + 20, y: bareBox.content.minY + 110, width: bareBox.content.width - 40, height: 90)
            if let p = inkSpan(preview, a, box: title), let e = inkSpan(exported, b, box: title) {
                worstInk = max(worstInk, abs(p.left - e.left), abs(p.right - e.right))
            } else {
                worstInk = 999
            }
        }
        print(String(format: "       paper parity: mean %.2f of 255 over the card, %.1f%% edge pixels apart, title ink within %d px",
                     worstMean, worstEdges * 100, worstInk))
        check(!shifted && worstEdges < 0.05 && worstMean < 6 && worstInk <= 2,
              "the export draws the paper card as the preview does: the same fonts, tilt, tape and label, in the same place",
              String(format: "shifted %@, mean %.2f, edges %.3f, ink %d px", shifted ? "yes" : "no", worstMean, worstEdges, worstInk))
    } else {
        print("  --   paper preview and export parity skipped (HyperFrames not downloaded)")
    }
}
