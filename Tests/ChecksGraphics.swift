// Checks for graphics. Run with ./test.sh graphics
import AppKit
import AVFoundation
import Foundation

@MainActor func graphicsTests() async throws {
    // MARK: - Graphics

    print("\nGraphics model")
    let partialStyle = try JSONDecoder().decode(GraphicsStyle.self, from: Data(#"{"look": "mix"}"#.utf8))
    check(partialStyle.look == .mix && partialStyle.panel == .shade && partialStyle.moveVideo && partialStyle.edge == 170
              && partialStyle.accent == "#F5C42C", "a partial style keeps the defaults for every key it leaves out")
    let plate = gfx(.namePlate, 0.2, 1.4, ["title": .string("Yamparala Rahul")])
    let ruleA = gfx(.rule, 0.5, 1.5, ["title": .string("Own every asset"), "points": .array([.object(["text": .string("Yours"), "at": .number(0.4)])])])
    let ruleB = gfx(.rule, 1.9, 2.8, ["title": .string("Privacy")])
    let cleanTrack = GraphicsTrack(items: [plate, ruleA, ruleB])
    check(cleanTrack.problem(duration: 3) == nil, "column and panel graphics may overlap in time", cleanTrack.problem(duration: 3) ?? "")
    check(GraphicsTrack(items: [ruleA, gfx(.checklist, 1.2, 2)]).problem(duration: 3)?.contains("overlap") == true,
          "two panel graphics may not overlap")
    check(GraphicsTrack(items: [gfx(.link, 2, 3.5)]).problem(duration: 3) != nil, "a graphic must end inside the recording")
    check(GraphicsTrack(items: [gfx(.link, 1, 1.2)]).problem(duration: 3) != nil, "a graphic shows for at least half a second")
    check(GraphicsTrack(items: [gfx(.phoneScreens, 0, 1, ["screens": .array([.object(["image": .string("media/a.png")])])])])
              .problem(duration: 3)?.contains("absolute") == true, "images are absolute paths in a project")
    check(GraphicsTrack(items: [gfx(.rule, 0, 1, ["points": .array([.object(["at": .number(-1)])])])]).problem(duration: 3) != nil,
          "beat times inside a graphic start from 0")
    var badAccent = GraphicsTrack(items: [plate]); badAccent.style.accent = "yellow"
    check(badAccent.problem(duration: 3) != nil, "the accent must be a hex colour")

    var mixTrack = cleanTrack; mixTrack.style.look = .mix
    check(mixTrack.look(of: ruleA) == .ink && mixTrack.look(of: plate) == .glass, "mix writes panel graphics in ink and keeps cards for the rest")
    check(mixTrack.look(of: gfx(.rule, 0, 1, look: .glass)) == .glass, "one graphic can choose glass in a mix")
    var inkTrack = cleanTrack; inkTrack.style.look = .ink
    check(inkTrack.look(of: plate) == .glass, "a kind without an ink version stays glass")

    let spanTrack = GraphicsTrack(items: [gfx(.panelTitle, 0, 1), gfx(.rule, 1.5, 2), gfx(.checklist, 3.2, 4)])
    let spans = spanTrack.panelSpans()
    check(spans.count == 2 && spans[0].start == 0 && spans[0].end == 2 && spans[1].start == 3.2,
          "panel graphics closer than a second share one panel", "\(spans)")
    let nodeBinary = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    if let nodeBinary {
        let planFile = scratch.appendingPathComponent("spans.json")
        try spanTrack.engineData(duration: 4, fps: "30").write(to: planFile)
        let script = "const g=require(process.argv[1]);const d=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));"
            + "console.log(JSON.stringify(g.plan(d).spans.map(s=>[s.start,s.end])))"
        let planned = try await Shell.run(nodeBinary, ["-e", script, "\(repository)/Resources/Graphics/graphics.js", planFile.path])
        equal(planned.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[[0,2],[3.2,4]]",
              "the engine plans the same panel spans as the app")
    } else {
        print("  --   engine parity skipped (no node)")
    }

    let motionTrack = GraphicsTrack(items: [gfx(.rule, 1, 2)])
    let motion = GraphicsMotion(motionTrack)!
    let near = { (a: Double, b: Double) in abs(a - b) < 0.0001 }
    check(motion.progress(at: 0.9).amount == 0 && near(motion.progress(at: 1.4).amount, 0.5) && motion.progress(at: 1.9).amount == 1
              && near(motion.progress(at: 2.4).amount, 0.5) && motion.progress(at: 2.81).amount == 0,
          "the move aside eases in over 0.8 s from the panel's start and out from its end")
    var stayTrack = motionTrack; stayTrack.style.moveVideo = false
    check(GraphicsMotion(stayTrack) == nil && GraphicsMotion(GraphicsTrack(items: [plate])) == nil,
          "nothing moves without panels, or with the move switched off")

    print("\nGraphics in projects")
    let gfxEditor = AppModel(recoveryURL: nil)
    gfxEditor.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    let gfxClip = gradeOther.id
    check(gfxEditor.perform([.replaceGraphics(clip: gfxClip, graphics: [plate, ruleA, ruleB], style: nil)]).isSuccess,
          "a recording takes graphics")
    check(gfxEditor.perform([.addGraphic(clip: gfxClip, graphic: gfx(.checklist, 1.0, 1.8))]).isFailure,
          "an overlapping panel graphic is refused")
    check(gfxEditor.perform([.addGraphic(clip: gfxClip, graphic: gfx(.link, 1.0, 9))]).isFailure,
          "a graphic past the end is refused")
    var movedPlate = plate; movedPlate.start = 1.6; movedPlate.end = 2.6
    check(gfxEditor.perform([.updateGraphic(clip: gfxClip, graphic: movedPlate)]).isSuccess
              && gfxEditor.items[0].graphics?.items.first(where: { $0.id == plate.id })?.start == 1.6, "a graphic can move")
    check(gfxEditor.perform([.setGraphicsStyle(clip: gfxClip, style: mixTrack.style)]).isSuccess
              && gfxEditor.items[0].graphics?.style.look == .mix, "the style changes on its own")
    equal(gfxEditor.undoTitle, "Undo Graphics Style", "each change is a named undo step")

    let savedGraphics = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(gfxEditor.project))
    check(savedGraphics == gfxEditor.project && savedGraphics.version == VideoProject.currentVersion && savedGraphics.clips[0].graphics?.items.count == 3,
          "graphics survive a project round trip")
    var olderClaim = savedGraphics; olderClaim.version = 5
    check((try? olderClaim.validate()) == nil, "a version 5 file with graphics is refused")
    var olderPlain = savedGraphics.withoutLog; olderPlain.version = 5; olderPlain.clips[0].graphics = nil
    check((try? olderPlain.validate()) != nil, "a version 5 file without graphics still opens")

    // Cuts carry graphics the way they carry zooms.
    let gfxSection = gfxEditor.items[0].timeline.segments[0].id
    check(gfxEditor.perform([.trimSection(clip: gfxClip, section: gfxSection, start: 0.4, end: nil)]).isSuccess, "trim the start")
    let afterTrim = gfxEditor.items[0].graphics?.items ?? []
    check(abs((afterTrim.first { $0.id == ruleA.id }?.start ?? -1) - 0.1) < 0.001,
          "a graphic follows its footage when a cut removes time before it")
    check(afterTrim.contains { $0.id == plate.id }, "a graphic whose footage remains is kept")
    let trimReceipt = gfxEditor.perform([.trimSection(clip: gfxClip, section: gfxSection, start: 1.2, end: nil)])
    if case .success(let receipt) = trimReceipt {
        check(receipt.removedGraphics.contains(ruleA.id) && !(gfxEditor.items[0].graphics?.items.contains { $0.id == ruleA.id } ?? true),
              "a graphic whose first frame is cut away is removed and reported")
    } else { check(false, "a cut that removes a graphic's start still applies") }
    gfxEditor.undo()
    check(gfxEditor.items[0].graphics?.items.contains { $0.id == ruleA.id } == true, "Undo brings it back")

    print("\nGraphics files")
    let gfxFolder = scratch.appendingPathComponent("graphics-import", isDirectory: true)
    try FileManager.default.createDirectory(at: gfxFolder.appendingPathComponent("art"), withIntermediateDirectories: true)
    let pixelPNG = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try pixelPNG.representation(using: .png, properties: [:])!.write(to: gfxFolder.appendingPathComponent("art/phone.png"))
    let importJSON = """
    {"version":1,"style":{"look":"mix","edge":120},"items":[
     {"id":"name","kind":"namePlate","start":0.2,"end":1.2,"props":{"title":"Hello"}},
     {"id":"phone","kind":"phoneScreens","start":1.4,"end":2.4,"props":{"screens":[{"image":"art/phone.png","at":0}]}}]}
    """
    try importJSON.write(to: gfxFolder.appendingPathComponent("graphics.json"), atomically: true, encoding: .utf8)
    let imported = try GraphicsEngine.importFile(gfxFolder.appendingPathComponent("graphics.json"))
    let importedImage = imported.items.last?.props["screens"]?.array?.first?.object?["image"]?.string
    check(imported.items.count == 2 && imported.style.look == .mix && imported.style.edge == 120
              && importedImage == gfxFolder.appendingPathComponent("art/phone.png").standardizedFileURL.path,
          "an import reads the style and makes image paths absolute")
    check(imported.items[0].id == UUID(deterministicFrom: Data("name".utf8)), "a text ID becomes the same UUID every time")
    try importJSON.replacingOccurrences(of: "art/phone.png", with: "art/missing.png")
        .write(to: gfxFolder.appendingPathComponent("missing.json"), atomically: true, encoding: .utf8)
    check((try? GraphicsEngine.importFile(gfxFolder.appendingPathComponent("missing.json"))) == nil, "a missing image stops the import")
    try importJSON.replacingOccurrences(of: "namePlate", with: "hologram")
        .write(to: gfxFolder.appendingPathComponent("kind.json"), atomically: true, encoding: .utf8)
    check((try? GraphicsEngine.importFile(gfxFolder.appendingPathComponent("kind.json"))) == nil, "an unknown kind stops the import")

    if GraphicsEngine.resources != nil {
        let pageFolder = scratch.appendingPathComponent("graphics-page", isDirectory: true)
        let index = try GraphicsEngine.writePage(imported, duration: 3, fps: "30000/1001", mode: "preview", to: pageFolder)
        let page = try String(contentsOf: index, encoding: .utf8)
        let media = try FileManager.default.contentsOfDirectory(atPath: pageFolder.appendingPathComponent("media").path)
        check(page.contains("\"kind\":\"phoneScreens\"") && page.contains("\"mode\":\"preview\"") && !page.contains("{{"),
              "the page carries the graphics and the mode, with every placeholder filled")
        check(media.count == 1 && page.contains("media/\(media[0])") && !page.contains(gfxFolder.path),
              "images are copied into the page under a content name; the page names no outside path")
        check(["graphics.js", "graphics.css", "gsap.min.js", "fonts/Virgil.woff2"].allSatisfy {
            FileManager.default.fileExists(atPath: pageFolder.appendingPathComponent($0).path) }, "the engine files are next to the page")
    } else {
        check(false, "the graphics engine files are found for tests (YAMVIDEO_ROOT)")
    }

    print("\nGraphics for agents")
    let gfxAgent = AppModel(recoveryURL: nil)
    gfxAgent.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    var gfxImport = address(gfxAgent)
    gfxImport["method"] = "apply"; gfxImport["requestID"] = "graphics-1"; gfxImport["client"] = "Claude"; gfxImport["label"] = "Add the graphics"
    gfxImport["commands"] = [["type": "importGraphics", "clipID": gfxClip.uuidString, "path": gfxFolder.appendingPathComponent("graphics.json").path]]
    let gfxImported = await agentCall(gfxAgent, gfxImport)
    check(gfxImported["ok"] as? Bool == true && gfxAgent.items[0].graphics?.items.count == 2, "an agent imports a graphics file", "\(gfxImported)")
    let gfxState = (agentResult(await agentCall(gfxAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["graphics"] as? [String: Any]
    check((gfxState?["items"] as? [Any])?.count == 2 && (gfxState?["style"] as? [String: Any])?["look"] as? String == "mix",
          "state shows the graphics and their style")
    let nameID = UUID(deterministicFrom: Data("name".utf8)).uuidString
    var gfxPatch = address(gfxAgent)
    gfxPatch["method"] = "apply"; gfxPatch["requestID"] = "graphics-2"; gfxPatch["client"] = "Claude"
    gfxPatch["commands"] = [["type": "updateGraphic", "clipID": gfxClip.uuidString, "graphicID": nameID,
                             "graphic": ["start": 0.1, "props": ["title": "Yamparala Rahul"]]],
                            ["type": "setGraphicsStyle", "clipID": gfxClip.uuidString, "graphicsStyle": ["panel": "solid"]]]
    let gfxPatched = await agentCall(gfxAgent, gfxPatch)
    let patchedName = gfxAgent.items[0].graphics?.items.first { $0.id.uuidString == nameID }
    check(gfxPatched["ok"] as? Bool == true && patchedName?.start == 0.1 && abs((patchedName?.end ?? 0) - 1.1) < 0.0001
              && patchedName?.props["title"]?.string == "Yamparala Rahul",
          "an update moves a graphic with its length and replaces its props", "\(gfxPatched)")
    check(gfxAgent.items[0].graphics?.style.panel == .solid && gfxAgent.items[0].graphics?.style.look == .mix && gfxAgent.items[0].graphics?.style.edge == 120,
          "a style change touches only the keys it names")
    var gfxBad = address(gfxAgent)
    gfxBad["method"] = "apply"; gfxBad["requestID"] = "graphics-3"
    gfxBad["commands"] = [["type": "addGraphic", "clipID": gfxClip.uuidString, "graphic": ["kind": "rule", "start": 0, "end": 1,
                           "props": ["demo": ["type": "image", "image": "/nowhere/missing.png"]]]]]
    equal(agentError(await agentCall(gfxAgent, gfxBad)), "missing_media", "an agent cannot add a graphic with a missing image")

    print("\nMove aside")
    let stripes = CIImage(color: .red).cropped(to: CGRect(x: 760, y: 0, width: 40, height: 720))
        .composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)))
    let movedFrame = moveAside(stripes, size: CGSize(width: 1280, height: 720), motion: motion, time: 1.9)
    let movedImage = CIContext().createCGImage(movedFrame, from: CGRect(x: 0, y: 0, width: 1280, height: 720))!
    let movedRed = nativePixel(movedImage, x: 780 - 320, y: 360), leftBehind = nativePixel(movedImage, x: 780, y: 360)
    check(movedRed.0 > 200 && movedRed.2 < 60 && leftBehind.0 < 120,
          "fully aside, the picture sits a quarter of the width to the left", "\(movedRed) \(leftBehind)")
    let edgeFill = nativePixel(movedImage, x: 1270, y: 360)
    check(edgeFill.2 > 40 && edgeFill.2 < 245, "the space it leaves shows the darker, blurred copy, not black", "\(edgeFill)")
    let unmoved = CIContext().createCGImage(moveAside(stripes, size: CGSize(width: 1280, height: 720), motion: motion, time: 0.5),
                                            from: CGRect(x: 0, y: 0, width: 1280, height: 720))!
    check(nativePixel(unmoved, x: 780, y: 360).0 > 200, "before the panel the picture is untouched")

    // MARK: - Export with graphics

    // Drawn frames go to scratch, never to the owner's cache.
    setenv("YAMVIDEO_GRAPHICS_CACHE", scratch.appendingPathComponent("graphics-cache").path, 1)
    print("\nGraphics render units")
    let unitPlate = gfx(.namePlate, 0.3456, 4.3, ["title": .string("Plate")])
    let unitRule = gfx(.rule, 5.0, 8.0, ["title": .string("Rule one")])
    let unitList = gfx(.checklist, 8.5, 10.0, ["title": .string("List")])
    let unitLink = gfx(.link, 9.0, 12.0, ["url": .string("example.com")])
    let unitTrack = GraphicsTrack(items: [unitPlate, unitRule, unitList, unitLink])
    let units = unitTrack.renderUnits(fps: 30)
    check(units.count == 5 && units.filter { $0.id == "panel-0" }.count == 1, "one unit per graphic, and one for the shared panel", "\(units.map(\.id))")
    let plateUnit = units.first { $0.id == unitPlate.id.uuidString }
    check(plateUnit.map { abs($0.origin - 10.0 / 30) < 0.000001 && abs($0.track.items[0].start - (0.3456 - 10.0 / 30)) < 0.000001 } == true,
          "a unit starts on the frame grid, with its graphic timed from there")
    let panelUnit = units.first { $0.id == "panel-0" }
    check(panelUnit.map { $0.origin == 5 && abs($0.duration - 5.8) < 0.000001 && $0.track.items.allSatisfy(\.props.isEmpty) } == true,
          "the panel unit runs to the panel's slide out, without the graphics' text")
    let ruleUnit = units.first { $0.id == unitRule.id.uuidString }
    check(ruleUnit.map { $0.track.items.count == 2 && $0.track.items.first { $0.id == unitList.id }?.props.isEmpty == true
              && $0.track.items.first { $0.id == unitRule.id }?.props["title"]?.string == "Rule one" } == true,
          "a panel graphic keeps its panel mates, without their text")
    check(unitTrack.panelGroups().map { ($0.first!.start, $0.map(\.end).max()!) }.elementsEqual(unitTrack.panelSpans().map { ($0.start, $0.end) }, by: ==),
          "panel groups and panel spans agree")
    let ruleIndex = units.firstIndex { $0.id == unitRule.id.uuidString }, shadeIndex = units.firstIndex { $0.id == "panel-0" }
    check(ruleIndex != nil && shadeIndex != nil && shadeIndex! < ruleIndex!,
          "a panel's shade is laid under the graphic that opens it, as the preview draws it", "\(units.map(\.id))")

    let baseKeys = unitKeys(unitTrack)
    var retexted = unitTrack; retexted.items[0].props["title"] = .string("Another plate")
    let retextedKeys = unitKeys(retexted)
    check(retextedKeys.filter { baseKeys[$0.key] != $0.value }.map(\.key) == [unitPlate.id.uuidString],
          "new text draws that graphic again and nothing else")
    var shifted = unitTrack; shifted.items[0].start += 1; shifted.items[0].end += 1
    check(unitKeys(shifted)[unitPlate.id.uuidString] == baseKeys[unitPlate.id.uuidString],
          "moving a graphic by whole frames reuses its frames")
    var mateEdit = unitTrack; mateEdit.items[2].props["title"] = .string("Other list")
    let mateKeys = unitKeys(mateEdit)
    check(mateKeys[unitRule.id.uuidString] == baseKeys[unitRule.id.uuidString] && mateKeys["panel-0"] == baseKeys["panel-0"],
          "editing one panel graphic's text leaves its panel mates and the panel alone")
    var accented = unitTrack; accented.style.accent = "#FF0000"
    check(unitKeys(accented).allSatisfy { baseKeys[$0.key] != $0.value }, "a style change draws everything again")
    check(GraphicsRender.jobs(for: unitTrack, fps: "30", outputWidth: 3840).allSatisfy { $0.scale == 2 }
              && GraphicsRender.jobs(for: unitTrack, fps: "30", outputWidth: 1920).allSatisfy { $0.scale == 1 },
          "4K exports draw graphics at twice the design size")

    if let nodeBinary {
        // The engine plans the same units: compare each unit's start and end.
        let planFile = scratch.appendingPathComponent("units.json")
        try unitTrack.engineData(duration: 12, fps: "30").write(to: planFile)
        let script = "const g=require(process.argv[1]);const d=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));"
            + "console.log(JSON.stringify(g.plan(d).units.map(u=>[u.kind==='panel'?'panel':u.id,u.start,u.end])))"
        let planned = try await Shell.run(nodeBinary, ["-e", script, "\(repository)/Resources/Graphics/graphics.js", planFile.path])
        let jsUnits = (try? JSONSerialization.jsonObject(with: planned.stdout) as? [[Any]]) ?? []
        let swiftUnits = units.map { unit -> (String, Double, Double) in
            let id = unit.id == "panel-0" ? "panel" : unit.id
            let start = unit.id == "panel-0" ? unit.track.items.map(\.start).min()! : unit.track.items.first { $0.id.uuidString == unit.id }!.start
            return (id, unit.origin + start, unit.origin + unit.duration)
        }
        check(jsUnits.count == swiftUnits.count && zip(jsUnits, swiftUnits).allSatisfy { js, swift in
            (js[0] as? String) == swift.0 && abs(((js[1] as? Double) ?? -1) - swift.1) < 0.0001 && abs(((js[2] as? Double) ?? -1) - swift.2) < 0.0001
        }, "the engine lists the same units as the app", planned.stdoutText)
    }

    print("\nMove aside parity")
    // A textured 10-bit 4:4:4 Rec.709 clip, so neither renderer guesses chroma or matrix.
    let (moveClip, moveInfo, moveTrack) = try await moveFixture()
    let moveMotion = GraphicsMotion(moveTrack)!
    var moveItem = VideoItem(url: moveClip)
    moveItem.info = moveInfo; moveItem.crop = moveInfo.fullFrame; moveItem.graphics = moveTrack

    /// Encoded Rec.709 RGB, 0–255, of one frame.
    /// The horizontal offset (−4…4 px) that best lines `b` up with `a` over columns `xs`, and
    /// the mean difference there.
    let moveStage = try FFmpeg.moveStage(moveMotion, frame: CGSize(width: 1280, height: 720), fps: 30, fpsExpression: "30",
                                         duration: 4.5, tags: FrameTags(info: moveInfo, converted: false))
    let moveGraph = moveStage.parts.joined(separator: ";").replacingOccurrences(of: "[mvin]", with: "[0:v]")
    var worstOffset = 0, worstFill = 0.0, worstFrame = 0.0
    for frame in [33, 42, 57, 66, 78, 108] {
        let native = try await nativePicture(moveItem, frame: frame)
        let exported = try await ffmpegPicture(moveClip, graph: moveGraph, frame: frame, width: 1280, height: 720)
        let amount = moveMotion.progress(at: Double(frame) / 30).amount
        let shift = Int((1280 * GraphicsTrack.shiftFraction * amount).rounded())
        let placed = alignment(native, exported, xs: 40..<(1280 - shift - 260))
        worstOffset = max(worstOffset, abs(placed.offset))
        worstFill = max(worstFill, meanDifference(native, exported, xs: (1280 - shift + 4)..<1276))
        worstFrame = max(worstFrame, meanDifference(native, exported, xs: 4..<1276))
    }
    print(String(format: "       move parity: worst offset %d px, fill %.2f, whole frame %.2f of 255", worstOffset, worstFill, worstFrame))
    check(worstOffset <= 2, "the exported move lands within 2 px of the preview at six times in and out of two panels")
    check(worstFill < 3 && worstFrame < 3, "the fill, the fade and the frost match the preview",
          String(format: "fill %.2f, frame %.2f", worstFill, worstFrame))
    let untouched = try await ffmpegPicture(moveClip, graph: moveGraph, frame: 15, width: 1280, height: 720)
    let source = try await ffmpegPicture(moveClip, graph: "[0:v]format=yuv420p10le[mvout]", frame: 15, width: 1280, height: 720)
    check(meanDifference(untouched, source, xs: 0..<1280) < 0.05, "outside the panels the stage leaves the picture alone",
          String(format: "%.3f", meanDifference(untouched, source, xs: 0..<1280)))

    print("\nExport with graphics")
    // Stand-in frames: a magenta box at design (1300, 100, 200 × 100) on transparency, so the
    // overlay can be checked without HyperFrames.
    let standIn = scratch.appendingPathComponent("stand-in.png")
    let standInMade = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
        // geq, not drawbox: drawbox on a transparent canvas leaves the box's alpha at 0.
        "-i", "color=c=black@0.0:s=1920x1080,format=rgba,geq=r='255*between(X,1300,1499)*between(Y,100,199)':g=0"
            + ":b='255*between(X,1300,1499)*between(Y,100,199)':a='255*between(X,1300,1499)*between(Y,100,199)'",
        "-frames:v", "1", standIn.path])
    check(standInMade.status == 0, "made a stand-in graphic frame", standInMade.stderrText)
    let draws = DrawCount()
    let standInDraw: (GraphicsRender.Job, URL, URL) async throws -> Void = { job, page, frames in
        draws.add()
        check(FileManager.default.fileExists(atPath: page.appendingPathComponent("index.html").path), "each unit gets its own page")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let count = Int((job.unit.duration * FFmpeg.rate(job.fps)).rounded(.up))
        for index in 1...count {
            try FileManager.default.copyItem(at: standIn, to: frames.appendingPathComponent(String(format: "frame_%06d.png", index)))
        }
    }
    try? FileManager.default.removeItem(at: GraphicsRender.cache)
    let overlayTrack = GraphicsTrack(items: [gfx(.namePlate, 0.5, 1.5)])
    let overlayOut = scratch.appendingPathComponent("graphics.mp4")
    try await FFmpeg.export(input: landscape, output: overlayOut, info: info, crop: info.fullFrame, settings: ExportSettings(),
                            graphics: overlayTrack, drawGraphics: standInDraw) { _ in }
    check(draws.count == 1, "the export draws its one graphic", "\(draws.count)")
    // 1920 → 1280: the box lands at (867, 67) to (1000, 133). testsrc2 has magenta of its
    // own, so each pixel is compared with the same export made without graphics.
    let plainOut = scratch.appendingPathComponent("graphics-plain.mp4")
    try await FFmpeg.export(input: landscape, output: plainOut, info: info, crop: info.fullFrame, settings: ExportSettings()) { _ in }
    let boxPixel = try await pixel(overlayOut, x: 930, y: 100, at: 1.0)
    let beforeBox = try await unchanged(overlayOut, plainOut, x: 930, y: 100, at: 0.3)
    let afterBox = try await unchanged(overlayOut, plainOut, x: 930, y: 100, at: 1.8)
    check(isMagenta(boxPixel) && beforeBox && afterBox, "the graphic lands in its place, from its start to its end",
          "\(boxPixel) before \(beforeBox) after \(afterBox)")
    let leftOfBox = try await unchanged(overlayOut, plainOut, x: 820, y: 100, at: 1.0)
    let belowBox = try await unchanged(overlayOut, plainOut, x: 930, y: 160, at: 1.0)
    check(leftOfBox && belowBox, "and nowhere else")
    let quietFrame = try await ffmpegPicture(overlayOut, graph: nil, frame: 9, width: 1280, height: 720)
    let quietPlain = try await ffmpegPicture(plainOut, graph: nil, frame: 9, width: 1280, height: 720)
    // The encoder spends its bits a little differently once a graphic shows later on, so the
    // frames are not identical; a conversion would shift every colour the same way.
    check(colourShift(quietFrame, quietPlain) < 0.1 && meanDifference(quietFrame, quietPlain, xs: 0..<1280) < 1,
          "an untagged recording keeps its colours: graphics never convert the picture",
          String(format: "shift %.3f, mean %.3f", colourShift(quietFrame, quietPlain), meanDifference(quietFrame, quietPlain, xs: 0..<1280)))
    equal(try await frameCount(overlayOut), try await frameCount(landscape), "graphics never change the frame count")
    try await FFmpeg.export(input: landscape, output: overlayOut, info: info, crop: info.fullFrame, settings: ExportSettings(),
                            graphics: overlayTrack, drawGraphics: standInDraw) { _ in }
    check(draws.count == 1, "an unchanged graphic is not drawn again")

    // Cut and scaled: the graphic keeps its edited time and fits the smaller frame.
    var smaller = ExportSettings(); smaller.sizeLimit = .vga
    let cutSegments = [TimelineSegment(start: 1.0, end: 3.0)]
    let scaledOut = scratch.appendingPathComponent("graphics-scaled.mp4")
    try await FFmpeg.export(input: landscape, output: scaledOut, info: info, crop: info.fullFrame, segments: cutSegments, settings: smaller,
                            graphics: overlayTrack, drawGraphics: standInDraw) { _ in }
    let scaledPlain = scratch.appendingPathComponent("graphics-scaled-plain.mp4")
    try await FFmpeg.export(input: landscape, output: scaledPlain, info: info, crop: info.fullFrame, segments: cutSegments, settings: smaller) { _ in }
    let scaledOn = try await pixel(scaledOut, x: 466, y: 50, at: 1.0)
    let scaledOff = try await unchanged(scaledOut, scaledPlain, x: 466, y: 50, at: 0.3)
    check(isMagenta(scaledOn) && scaledOff, "after a cut and a downscale the graphic shows at its edited time, fitted", "\(scaledOn)")

    // The move in an export lands where the preview puts it.
    let movedOut = scratch.appendingPathComponent("graphics-moved.mp4")
    var bestQuality = ExportSettings(); bestQuality.quality = 100
    try await FFmpeg.export(input: moveClip, output: movedOut, info: moveInfo, crop: moveInfo.fullFrame, settings: bestQuality,
                            graphics: moveTrack, drawGraphics: { job, page, frames in
                                try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
                                let clear = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                    "-i", "color=c=black@0.0:s=1920x1080,format=rgba", "-frames:v", "1", frames.appendingPathComponent("frame_000001.png").path])
                                if clear.status != 0 { throw FFmpegError(message: clear.stderrText) }
                            }) { _ in }
    let movedNative = try await nativePicture(moveItem, frame: 57)
    let movedExport = try await ffmpegPicture(movedOut, graph: nil, frame: 57, width: 1280, height: 720)
    let movedPlace = alignment(movedNative, movedExport, xs: 40..<700)
    check(abs(movedPlace.offset) <= 2 && movedPlace.mean < 6, "an exported MP4 moves the picture aside as the preview does",
          String(format: "offset %d, mean %.2f", movedPlace.offset, movedPlace.mean))
    equal(try await frameCount(movedOut), try await frameCount(moveClip), "cutting the video into panel windows and joining it again keeps every frame")
    let windowed = moveStage.parts.joined(separator: ";")
    check(windowed.contains("concat=n=4") && windowed.contains("trim=start_frame=0:end_frame=29,setpts=PTS-STARTPTS,format=yuv420p10le"),
          "frames away from the panels pass straight through", String(windowed.prefix(400)))

    // GIF: both passes see the graphics; the palette stays input 1.
    var gfxGIF = ExportSettings(); gfxGIF.format = .gif
    let gfxGIFCommands = FFmpeg.exportCommands(input: landscape, output: scratch.appendingPathComponent("g.gif"), info: info,
                                               crop: info.fullFrame, settings: gfxGIF, graphics: overlayTrack)
    check(gfxGIFCommands.count == 2 && gfxGIFCommands.allSatisfy { $0.contains("-itsoffset") && $0.joined(separator: " ").contains("overlay=x=0:y=0") }
              && gfxGIFCommands[1].joined(separator: " ").contains("[1:v]paletteuse") && gfxGIFCommands[1].joined(separator: " ").contains("[2:v]scale="),
          "both GIF passes draw the graphics, and the palette stays the second input")
    var noGraphics = ExportSettings(); noGraphics.graphics = false
    var plainItem = VideoItem(url: landscape); plainItem.graphics = overlayTrack
    check(plainItem.exportGraphics(noGraphics) == nil && plainItem.exportGraphics(ExportSettings()) == overlayTrack,
          "graphics can be left out of exports")

    // Cancel while drawing: nothing half-made is left in the cache, and no file is written.
    let cancelOut = scratch.appendingPathComponent("graphics-cancel.mp4")
    let slowTrack = GraphicsTrack(items: [gfx(.namePlate, 0.5, 2.5, ["title": .string("Slow")])])
    let cancelled = Task {
        try await FFmpeg.export(input: landscape, output: cancelOut, info: info, crop: info.fullFrame, settings: ExportSettings(),
                                graphics: slowTrack, drawGraphics: { _, _, frames in
                                    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
                                    try FileManager.default.copyItem(at: standIn, to: frames.appendingPathComponent("frame_000001.png"))
                                    try await Task.sleep(nanoseconds: 5_000_000_000)
                                }) { _ in }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    cancelled.cancel()
    let cancelResult = await cancelled.result
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: GraphicsRender.cache.path)) ?? []
    check((try? cancelResult.get()) == nil && !leftovers.contains { $0.hasPrefix(".work-") } && !FileManager.default.fileExists(atPath: cancelOut.path)
              && !GraphicsRender.jobs(for: slowTrack, fps: info.fpsExpression, outputWidth: 1280)[0].isRendered,
          "cancelling while graphics draw leaves no partial frames and no file", "\(leftovers)")

    var hdrGraphicsInfo = info; hdrGraphicsInfo.colorTransfer = "smpte2084"
    var keepHDRGraphics = ExportSettings(); keepHDRGraphics.toneMapHDR = false
    check(FFmpeg.graphicsProblem(overlayTrack, info: hdrGraphicsInfo, settings: keepHDRGraphics) != nil
              && FFmpeg.graphicsProblem(overlayTrack, info: hdrGraphicsInfo, settings: ExportSettings()) == nil,
          "graphics over HDR kept as HDR are refused; tone-mapped they are fine")

    // Without HyperFrames the export says what to do instead of leaving the graphics out.
    let emptyRenderer = scratch.appendingPathComponent("no-hyperframes", isDirectory: true)
    setenv("YAMVIDEO_HYPERFRAMES_DIR", emptyRenderer.path, 1)
    if case .ready = await HyperFrames.status() { check(false, "an empty folder is not a ready renderer") }
    do {
        try await FFmpeg.export(input: landscape, output: scratch.appendingPathComponent("no-renderer.mp4"), info: info, crop: info.fullFrame,
                                settings: ExportSettings(), graphics: GraphicsTrack(items: [gfx(.link, 0.2, 1.2)])) { _ in }
        check(false, "an export with graphics and no renderer fails")
    } catch {
        check(error.localizedDescription.contains("HyperFrames") && error.localizedDescription.contains("Draw graphics"),
              "without HyperFrames the export says how to get it or leave the graphics out", error.localizedDescription)
    }
    unsetenv("YAMVIDEO_HYPERFRAMES_DIR")

    print("\nGraphics for agents in exports")
    let exportAgent = AppModel(recoveryURL: nil)
    exportAgent.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    var graphicsOff = address(exportAgent)
    graphicsOff["method"] = "apply"; graphicsOff["requestID"] = "graphics-off"; graphicsOff["client"] = "Claude"
    graphicsOff["commands"] = [["type": "setExportSettings", "settings": ["graphics": false]]]
    let offReply = await agentCall(exportAgent, graphicsOff)
    check(offReply["ok"] as? Bool == true && exportAgent.settings.graphics == false, "an agent can leave graphics out of exports", "\(offReply)")
    let exportState = agentResult(await agentCall(exportAgent, ["method": "state"]))
    check((exportState["settings"] as? [String: Any])?["graphics"] as? Bool == false, "state shows the choice")
    check((exportState["graphicsRenderer"] as? [String: Any])?["status"] is String, "state says whether graphics can be drawn", "\(exportState["graphicsRenderer"] ?? "nil")")

    if case .ready = await HyperFrames.status() {
        print("\nHyperFrames")
        let realTrack = GraphicsTrack(items: [gfx(.namePlate, 0.3, 1.8, ["kicker": .string("Test"), "title": .string("Yamparala Rahul"),
                                                                           "detail": .string("Graphics export")])])
        let realJobs = GraphicsRender.jobs(for: realTrack, fps: info.fpsExpression, outputWidth: 1280)
        for job in realJobs { try? FileManager.default.removeItem(at: job.folder) }
        let realOut = scratch.appendingPathComponent("hyperframes.mp4")
        let started = Date()
        try await FFmpeg.export(input: landscape, output: realOut, info: info, crop: info.fullFrame, settings: ExportSettings(),
                                graphics: realTrack) { _ in }
        print(String(format: "       drew and exported in %.1f s", Date().timeIntervalSince(started)))
        let frames = (try? FileManager.default.contentsOfDirectory(atPath: realJobs[0].folder.path)) ?? []
        check(frames.count >= 44, "HyperFrames draws the graphic's frames", "\(frames.count)")
        let probe = try await Shell.run(FFmpeg.ffprobePath!, ["-v", "error", "-show_entries", "stream=pix_fmt,width,height", "-of", "csv=p=0",
                                                              realJobs[0].folder.appendingPathComponent("frame_000030.png").path])
        check(probe.stdoutText.contains("1920,1080,rgba"), "with alpha, at the design size", probe.stdoutText)
        // The name plate's card sits in the right-hand column, top: design x 1240–1880.
        func cardDifference(_ time: Double) async throws -> Int {
            var total = 0
            for (x, y) in [(900, 60), (1000, 75), (1100, 60)] {
                let a = try await pixel(realOut, x: x, y: y, at: time), b = try await pixel(landscape, x: x, y: y, at: time)
                total += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
            }
            return total
        }
        let during = try await cardDifference(1.2), before = try await cardDifference(0.1)
        check(during > 60 && before < 30, "the exported video shows the card in its column while the graphic is on", "during \(during), before \(before)")
    } else {
        print("  --   HyperFrames render skipped (not downloaded)")
    }

    // MARK: - Graphics on the picture


    print("\nGraphics on the picture")
    let zoneOrigin = CGPoint(x: 1240, y: 72)
    let card = GraphicBounds(content: CGRect(x: 1240, y: 96, width: 430, height: 184), origin: zoneOrigin)
    let moved100 = GraphicTransform(x: -100, y: 40, scale: 1)
    check(card.placed(moved100) == CGRect(x: 1140, y: 136, width: 430, height: 184), "a move shifts the box by its pixels")
    let grown = GraphicTransform(x: 0, y: 0, scale: 2)
    check(card.placed(grown) == CGRect(x: 1240, y: 120, width: 860, height: 368), "a scale grows the box from its zone's top-left corner")
    check(GraphicTransform(scale: 3).problem?.contains("0.4") == true && GraphicTransform(x: 2500).problem?.contains("1920") == true
              && GraphicTransform(x: .nan).problem != nil && GraphicTransform(x: -300, y: 200, scale: 1.5).problem == nil,
          "a move or scale out of range is refused, saying what is allowed")
    check(GraphicsTrack(items: [Graphic(kind: .namePlate, start: 0, end: 1, transform: GraphicTransform(scale: 9))]).problem(duration: 3) != nil,
          "the track refuses a graphic scaled out of range")

    let noSnap = GraphicPlacement.moved(GraphicTransform(), by: CGSize(width: -1150, height: 0), bounds: card, guides: nil, tolerance: 6)
    check(noSnap.transform == GraphicTransform(x: -1150, y: 0, scale: 1) && noSnap.vertical == nil, "without guides a move goes exactly where it is dragged")
    let plateGraphic = Graphic(kind: .namePlate, start: 0, end: 1)
    let cardGuides = GraphicPlacement.guides(for: plateGraphic, bounds: card, style: GraphicsStyle())
    let safeSnap = GraphicPlacement.moved(GraphicTransform(), by: CGSize(width: -1148, height: 0), bounds: card, guides: cardGuides, tolerance: 6)
    check(safeSnap.transform.x == -1144 && safeSnap.vertical == 96, "a left edge near the safe area snaps onto it", "\(safeSnap)")
    let homeSnap = GraphicPlacement.moved(GraphicTransform(x: -300, y: 0), by: CGSize(width: 297, height: 3), bounds: card, guides: cardGuides, tolerance: 6)
    check(homeSnap.transform == GraphicTransform(), "a graphic dragged back near its own place snaps home", "\(homeSnap)")
    let centreSnap = GraphicPlacement.moved(GraphicTransform(), by: CGSize(width: -495, height: 0), bounds: card, guides: cardGuides, tolerance: 6)
    check(centreSnap.vertical == 960 && abs(card.placed(centreSnap.transform).midX - 960) < 0.5, "its centre snaps to the middle of the frame", "\(centreSnap)")
    let bigger = GraphicPlacement.resized(GraphicTransform(), corner: .bottomRight, to: CGPoint(x: 1240 + 645, y: 96 + 100),
                                          bounds: card, guides: nil, tolerance: 6)
    let biggerBox = card.placed(bigger.transform)
    check(abs(bigger.transform.scale - 1.5) < 0.001 && abs(biggerBox.minX - 1240) < 0.5 && abs(biggerBox.minY - 96) < 0.5,
          "dragging the bottom-right corner keeps the top-left corner and the shape", "\(bigger) \(biggerBox)")
    let fromTopLeft = GraphicPlacement.resized(GraphicTransform(), corner: .topLeft, to: CGPoint(x: 1670 - 215, y: 280 - 92),
                                               bounds: card, guides: nil, tolerance: 6)
    let fromTopLeftBox = card.placed(fromTopLeft.transform)
    check(abs(fromTopLeft.transform.scale - 0.5) < 0.001 && abs(fromTopLeftBox.maxX - 1670) < 0.5 && abs(fromTopLeftBox.maxY - 280) < 0.5,
          "dragging the top-left corner keeps the bottom-right corner", "\(fromTopLeft) \(fromTopLeftBox)")
    let nearFull = GraphicPlacement.resized(GraphicTransform(), corner: .bottomRight, to: CGPoint(x: 1670 + 4, y: 150),
                                            bounds: card, guides: cardGuides, tolerance: 6)
    check(nearFull.transform == GraphicTransform(), "a size close to the template's own snaps to it", "\(nearFull)")
    let tiny = GraphicPlacement.resized(GraphicTransform(), corner: .bottomRight, to: CGPoint(x: 1241, y: 97), bounds: card, guides: nil, tolerance: 6)
    check(tiny.transform.scale == GraphicTransform.scales.lowerBound, "a graphic cannot be shrunk below its smallest size")

    let placing = AppModel(recoveryURL: nil)
    placing.restore(VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id))
    let placedPlate = Graphic(kind: .namePlate, start: 0.2, end: 1.4, props: ["title": .string("Plate")])
    _ = placing.perform([.replaceGraphics(clip: gradeOther.id, graphics: [placedPlate], style: nil)])
    placing.showPlayback = true
    let undoBeforeDrag = placing.undoEntries.count
    for step in 1...5 { placing.placeGraphic(placedPlate.id, GraphicTransform(x: Double(-20 * step), y: Double(10 * step)), live: true) }
    check(placing.showPlayback, "dragging a graphic keeps Preview showing")
    placing.endGesture()
    check(placing.undoEntries.count == undoBeforeDrag + 1 && placing.undoTitle == "Undo Move Graphic on Picture"
              && placing.items[0].graphics?.items[0].transform == GraphicTransform(x: -100, y: 50),
          "a drag on the picture is one undo step", placing.undoTitle)
    placing.selectedGraphicID = placedPlate.id
    placing.nudgeSelectedGraphic(dx: 1, dy: 0)
    check(placing.items[0].graphics?.items[0].transform?.x == -99, "⌥ arrow keys nudge the graphic a pixel")
    placing.resetGraphicPlace(placedPlate.id)
    check(placing.items[0].graphics?.items[0].transform == nil, "Reset Position puts it back, stored as no transform at all")
    placing.placeGraphic(placedPlate.id, GraphicTransform(x: 0, y: 0, scale: 1))
    check(placing.items[0].graphics?.items[0].transform == nil, "the template's own place is never stored as a transform")
    placing.placeGraphic(placedPlate.id, GraphicTransform(x: -600, y: 0, scale: 1.25))
    check(placing.items[0].graphics?.items[0].transform == GraphicTransform(x: -600, y: 0, scale: 1.25), "a placement is stored")

    let placedData = String(decoding: try placing.items[0].graphics!.engineData(duration: 3, fps: "30"), as: UTF8.self)
    check(placedData.contains(#""transform":{"scale":1.25,"x":-600,"y":0}"#), "the engine gets the move and the scale", placedData)
    let placedSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(placing.project))
    check(placedSaved == placing.project && placedSaved.version == VideoProject.currentVersion, "placements survive a project round trip")
    var placedAsSix = placedSaved; placedAsSix.version = 6
    check((try? placedAsSix.validate()) == nil, "a version 6 file with placements is refused, so an older build never drops them")
    var unplacedSix = placedSaved.withoutLog; unplacedSix.version = 6; unplacedSix.clips[0].graphics?.items[0].transform = nil
    check((try? unplacedSix.validate()) != nil, "a version 6 file without placements still opens")
    let placedFile = scratch.appendingPathComponent("placed.json")
    try placedData.write(to: placedFile, atomically: true, encoding: .utf8)
    check(try GraphicsEngine.importFile(placedFile).items[0].transform == GraphicTransform(x: -600, y: 0, scale: 1.25),
          "a graphics file carries placements in and out")

    print("\nGraphics on the picture for agents")
    var placeRequest = address(placing)
    placeRequest["method"] = "apply"; placeRequest["requestID"] = "place-1"; placeRequest["client"] = "Claude"
    placeRequest["commands"] = [["type": "updateGraphic", "clipID": gradeOther.id.uuidString, "graphicID": placedPlate.id.uuidString,
                                 "graphic": ["transform": ["y": 120]]]]
    let placeReply = await agentCall(placing, placeRequest)
    check(placeReply["ok"] as? Bool == true && placing.items[0].graphics?.items[0].transform == GraphicTransform(x: -600, y: 120, scale: 1.25),
          "an agent moves a graphic; keys it leaves out keep their values", "\(placeReply)")
    var badPlace = address(placing)
    badPlace["method"] = "apply"; badPlace["requestID"] = "place-2"
    badPlace["commands"] = [["type": "updateGraphic", "clipID": gradeOther.id.uuidString, "graphicID": placedPlate.id.uuidString,
                             "graphic": ["transform": ["scale": 4]]]]
    let badPlaceReply = await agentCall(placing, badPlace)
    check(agentError(badPlaceReply) == "invalid_command" && ((badPlaceReply["error"] as? [String: Any])?["message"] as? String ?? "").contains("2.5"),
          "an agent's out-of-range scale is refused with the range", "\(badPlaceReply)")
    let placedState = (agentResult(await agentCall(placing, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["graphics"] as? [String: Any]
    let placedItem = (placedState?["items"] as? [[String: Any]])?.first
    check((placedItem?["transform"] as? [String: Any])?["y"] as? Double == 120, "state shows the placement")

    // The engine itself: measured boxes, and a placement moving the drawn graphic.
    let measuredTrack = GraphicsTrack(items: [Graphic(id: placedPlate.id, kind: .namePlate, start: 0.2, end: 1.4,
                                                      props: ["kicker": .string("Yamparala Media"), "title": .string("Yamparala Rahul"), "detail": .string("UX Design Engineer")])])
    let measured = try await GraphicsSnapshot.bounds(measuredTrack, duration: 3, fps: "30")
    let plateBox = measured[placedPlate.id]
    check(plateBox.map { $0.origin == zoneOrigin && $0.content.minX >= 1238 && $0.content.minX < 1300 && $0.content.width > 250
                         && $0.content.width < 640 && $0.content.minY > 60 && $0.content.height < 400 } == true,
          "the engine measures a name plate's card in the column", "\(String(describing: plateBox))")
    let gradeFrame = CGImage.blank(width: 1280, height: 720)
    let unplacedShot = try await GraphicsSnapshot.draw(measuredTrack, duration: 3, fps: "30", time: 1.0, over: gradeFrame)
    var placedTrack = measuredTrack; placedTrack.items[0].transform = GraphicTransform(x: -600, y: 120, scale: 1.25)
    let placedShot = try await GraphicsSnapshot.draw(placedTrack, duration: 3, fps: "30", time: 1.0, over: gradeFrame)
    if let before = unplacedShot.boxes[placedPlate.id], let after = placedShot.boxes[placedPlate.id], let plateBox {
        let expected = plateBox.placed(GraphicTransform(x: -600, y: 120, scale: 1.25))
        let k = 1280.0 / 1920
        check(abs(after.minX - expected.minX * k) < 2 && abs(after.minY - expected.minY * k) < 2 && abs(after.width - before.width * 1.25) < 2,
              "the drawn graphic lands where its placement says, at its new size", "before \(before) after \(after) expected \(expected)")
    } else {
        check(false, "the snapshot reports the graphic's box", "\(unplacedShot.boxes) \(placedShot.boxes)")
    }
    check(placedShot.image.width == 1280 && placedShot.image.height == 720, "the snapshot keeps the picture's size")

    if case .ready = await HyperFrames.status() {
        // An export draws the graphic where it was placed.
        let placedOut = scratch.appendingPathComponent("placed.mp4")
        var exportTrack = measuredTrack; exportTrack.items[0].transform = GraphicTransform(x: -600, y: 300, scale: 1)
        try await FFmpeg.export(input: landscape, output: placedOut, info: info, crop: info.fullFrame, settings: ExportSettings(),
                                graphics: exportTrack) { _ in }
        let target = plateBox.map { $0.placed(exportTrack.items[0].transform) } ?? .zero
        let k = 1280.0 / 1920
        let inside = (Int(target.midX * k), Int(target.midY * k)), home = (Int((plateBox?.content.midX ?? 0) * k), Int((plateBox?.content.midY ?? 0) * k))
        let placedPixel = try await pixel(placedOut, x: inside.0, y: inside.1, at: 1.0)
        let sourcePixel = try await pixel(landscape, x: inside.0, y: inside.1, at: 1.0)
        let homeChanged = try await unchanged(placedOut, plainOut, x: home.0, y: home.1, at: 1.0)
        check(abs(placedPixel.0 - sourcePixel.0) + abs(placedPixel.1 - sourcePixel.1) + abs(placedPixel.2 - sourcePixel.2) > 40 && homeChanged,
              "the export draws the graphic where it was placed, not where the template puts it", "\(placedPixel) vs \(sourcePixel)")
    }

    print("\nGraphics size for phones")
    var phoneStyle = GraphicsStyle(); phoneStyle.size = 1.3
    var hugeStyle = GraphicsStyle(); hugeStyle.size = 1.8
    check(GraphicsTrack(style: phoneStyle).problem(duration: 3) == nil && GraphicsTrack().problem(duration: 3) == nil
              && GraphicsTrack(style: hugeStyle).problem(duration: 3)?.contains("size") == true,
          "a graphics size from 1 to 1.5 is kept, a larger one is refused")
    let plainStyleText = String(decoding: try JSONEncoder().encode(GraphicsStyle()), as: UTF8.self)
    let plainEngine = String(decoding: try GraphicsTrack().engineData(duration: 3, fps: "30"), as: UTF8.self)
    let sizedEngine = String(decoding: try GraphicsTrack(style: phoneStyle).engineData(duration: 3, fps: "30"), as: UTF8.self)
    check(!plainStyleText.contains("size") && !plainEngine.contains("size") && sizedEngine.contains(#""size":1.3"#),
          "a style without a size stores and sends no size, so older projects draw and cache as before", plainEngine)
    var sizedProject = VideoProject(clips: [ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeOther.id)
    sizedProject.clips[0].graphics = GraphicsTrack(style: phoneStyle)
    var sizedAsFifteen = sizedProject; sizedAsFifteen.version = 15
    check((try? sizedAsFifteen.validate()) == nil && (try? sizedProject.validate()) != nil,
          "a version 15 file with a graphics size is refused; the current version keeps it")

    func styleCall(_ id: String, _ keys: [String: Any]) async -> [String: Any] {
        var request = address(gfxAgent)
        request["method"] = "apply"; request["requestID"] = id; request["client"] = "Claude"
        request["commands"] = [["type": "setGraphicsStyle", "clipID": gfxClip.uuidString, "graphicsStyle": keys]]
        return await agentCall(gfxAgent, request)
    }
    let sizeSet = await styleCall("graphics-size-1", ["size": 1.3])
    check(sizeSet["ok"] as? Bool == true && gfxAgent.items[0].graphics?.style.size == 1.3 && gfxAgent.items[0].graphics?.style.panel == .solid,
          "an agent sets the graphics size, and the other style keys stay", "\(sizeSet)")
    let sizeOne = await styleCall("graphics-size-2", ["size": 1])
    check(sizeOne["ok"] as? Bool == true && gfxAgent.items[0].graphics?.style.size == nil, "a size of 1 is stored as no size at all")
    equal(agentError(await styleCall("graphics-size-3", ["size": 2])), "invalid_command", "an agent cannot set a size above 1.5")

    // The engine: a card grows left from the column's right edge, a panel half as much.
    let sizedRuleID = UUID()
    var sizeTrack = GraphicsTrack(items: [
        Graphic(id: placedPlate.id, kind: .namePlate, start: 0.2, end: 1.4,
                props: ["kicker": .string("Yamparala Media"), "title": .string("Yamparala Rahul"), "detail": .string("UX Design Engineer")]),
        Graphic(id: sizedRuleID, kind: .rule, start: 1.6, end: 2.8,
                props: ["kicker": .string("Phones"), "title": .string("Text a phone can read"),
                        "points": .array([.object(["text": .string("Larger cards"), "at": .number(0.2)])])]),
    ])
    let unsizedBoxes = try await GraphicsSnapshot.bounds(sizeTrack, duration: 3, fps: "30")
    sizeTrack.style.size = 1.4
    let sizedBoxes = try await GraphicsSnapshot.bounds(sizeTrack, duration: 3, fps: "30")
    if let card = unsizedBoxes[placedPlate.id], let bigCard = sizedBoxes[placedPlate.id],
       let panel = unsizedBoxes[sizedRuleID], let bigPanel = sizedBoxes[sizedRuleID] {
        check(abs(bigCard.content.width - card.content.width * 1.4) < 2 && abs((1840 - bigCard.content.maxX) - (1840 - card.content.maxX) * 1.4) < 2
                  && abs((bigCard.content.minY - 72) - (card.content.minY - 72) * 1.4) < 2 && bigCard.origin == card.origin,
              "with size 1.4 a card is 1.4 times larger and grows left and down from the column's top-right corner",
              "\(card.content) → \(bigCard.content)")
        check(abs(bigPanel.content.width - panel.content.width * 1.2) < 2 && abs((1860 - bigPanel.content.maxX) - (1860 - panel.content.maxX) * 1.2) < 2,
              "a panel grows half as much, 1.2 times, from the panel's top-right corner", "\(panel.content) → \(bigPanel.content)")
        let movedBig = bigCard.placed(GraphicTransform(x: -100, y: 0, scale: 1))
        check(abs(movedBig.minX - (bigCard.content.minX - 100)) < 0.5, "a graphic's own transform applies on top of the size")
    } else {
        check(false, "the engine measures the card and the panel at both sizes", "\(unsizedBoxes) \(sizedBoxes)")
    }
    let sizedShot = try await GraphicsSnapshot.draw(sizeTrack, duration: 3, fps: "30", time: 1.0, over: CGImage.blank(width: 1280, height: 720))
    if let drawn = sizedShot.boxes[placedPlate.id], let measuredBig = sizedBoxes[placedPlate.id] {
        let k = 1280.0 / 1920
        check(abs(drawn.minX - measuredBig.content.minX * k) < 2 && abs(drawn.width - measuredBig.content.width * k) < 2,
              "the drawn card is where the measured box says", "\(drawn) vs \(measuredBig.content)")
    } else {
        check(false, "the snapshot reports the sized card's box")
    }
}
