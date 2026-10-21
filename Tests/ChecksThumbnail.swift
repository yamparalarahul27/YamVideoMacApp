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

    // Dark frost: the frame moves with the speaker as under the white frost, but the shade
    // and the speaker's own room are near black: only the cut-out speaker and the title are bright.
    var shaded = clearLeft; shaded.background = .shade
    let shadeThumb = try await ThumbnailMaker.render(shaded, sources: subjectSources, accent: "#F5C42C")
    let darkShade = rgb(shadeThumb, 30, 700), darkRoom = rgb(shadeThumb, 1270, 700)
    check([darkShade.0, darkShade.1, darkShade.2, darkRoom.0, darkRoom.1, darkRoom.2].allSatisfy { $0 < 50 }
              && redShare(shadeThumb, xs: 700..<1240) > 0.1 && redShare(shadeThumb, xs: 40..<640) < 0.02
              && brightShare(shadeThumb, xs: 40..<640) > 0.005,
          "with the dark frost, the speaker moves with their frame, their room is near black, and the title is light",
          "shade \(darkShade), room \(darkRoom), red \(redShare(shadeThumb, xs: 700..<1240)), title \(brightShare(shadeThumb, xs: 40..<640))")
    // Vivid: stronger colours on the speaker alone; the room and the title stay as they were.
    var vivid = shaded; vivid.vivid = 1.4
    let vividThumb = try await ThumbnailMaker.render(vivid, sources: subjectSources, accent: "#F5C42C")
    /// How far the speaker's red stands out from grey, on average.
    func redness(_ image: CGImage) -> Double {
        var total = 0.0, count = 0
        for y in stride(from: 300, to: 700, by: 8) { for x in stride(from: 700, to: 1240, by: 8) {
            let p = rgb(image, x, y)
            if p.0 > 150 && p.0 > p.1 + 60 { total += Double(p.0) - Double(p.1 + p.2) / 2; count += 1 }
        } }
        return total / Double(max(1, count))
    }
    let roomAfter = rgb(vividThumb, 1270, 700)
    check(redness(vividThumb) > redness(shadeThumb) + 5 && abs(roomAfter.0 - darkRoom.0) <= 2,
          "vivid makes the speaker's colours stronger and leaves the room as it was",
          String(format: "redness %.1f against %.1f, room %@ against %@", redness(vividThumb), redness(shadeThumb), "\(roomAfter)", "\(darkRoom)"))
    var tooVivid = shaded; tooVivid.vivid = 1.6
    check(tooVivid.problem?.contains("1.4") == true, "vivid above 1.4 is refused", tooVivid.problem ?? "no problem")

    print("\nPhone check")
    check(PhoneSize.homeFeed.points(1920) == 390 && Int(PhoneSize.searchList.height) == 94
              && Int(PhoneSize.searchList.pixels(PhoneCheck.letterLimits.smallest).rounded(.up)) == 103,
          "the phone sizes turn design pixels into points, and back")
    let yellow = Contrast.luminance(hex: "#F5C42C")!
    check(abs(Contrast.ratio(1, 0) - 21) < 0.01 && Contrast.ratio(yellow, 1) < 2 && Contrast.ratio(Contrast.luminance(hex: "#121417")!, yellow) > 9,
          "contrast as WCAG measures it: yellow on white is low, dark on yellow is high",
          String(format: "%.2f, %.2f", Contrast.ratio(yellow, 1), Contrast.ratio(Contrast.luminance(hex: "#121417")!, yellow)))
    let darkBehind = [Float](repeating: 0.02, count: 100)
    let busyBehind = [Float](repeating: 0.02, count: 70) + [Float](repeating: 0.9, count: 30)
    check(Contrast.ratio(text: 1, behind: darkBehind)! > 15 && Contrast.ratio(text: 1, behind: busyBehind)! < 1.2
              && Contrast.ratio(text: 0.005, behind: busyBehind)! > 1 && Contrast.ratio(text: 1, behind: []) == nil,
          "light words take the brightest part behind them, so a busy background counts against them")
    check(Contrast.split([Float](repeating: 0, count: 50) + [Float](repeating: 1, count: 20))! > 15
              && Contrast.split([Float](repeating: 0.5, count: 30) + [Float](repeating: 0.55, count: 30))! < 1.3,
          "words of unknown colour: two groups of pixels and their contrast")
    let halves = LuminanceMap(CGImage.blank(width: 1280, height: 720).drawn { context in
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 720))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 640, y: 0, width: 640, height: 720))
    })
    let leftSamples = halves.samples(in: CGRect(x: 100, y: 100, width: 600, height: 400))
    let rightSamples = halves.samples(in: CGRect(x: 1100, y: 100, width: 600, height: 400))
    check(leftSamples.count > 1000 && leftSamples.allSatisfy { $0 < 0.01 } && rightSamples.allSatisfy { $0 > 0.99 },
          "a picture's luminance is sampled in design pixels", "\(leftSamples.count) \(leftSamples.max() ?? -1) \(rightSamples.min() ?? -1)")
    let magentaSquare = CGImage.blank(width: 1280, height: 720).drawn { context in
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 200, y: 200, width: 100, height: 100))
    }
    let squareMask = LetterMask(magentaSquare)
    let squareSamples = halves.samples(in: CGRect(x: 0, y: 0, width: 960, height: 1080), outside: squareMask)
    check(squareMask.values.filter { $0 }.count == 52 * 52 && !squareMask.values[0]
              && squareSamples.count == 320 * 360 - 52 * 52,
          "the letters' mask marks magenta and the pixels round it, and samples leave them out",
          "\(squareMask.values.filter { $0 }.count) \(squareSamples.count)")
    check(PhoneCheck.wordCount(in: "Edit for the *viewer*") == 4 && PhoneCheck.wordCount(in: "3 RULES") == 2
              && PhoneCheck.wordCount(in: "SYSTEM\u{00A0}DESIGN — 2") == 3 && PhoneCheck.wordCount(in: "g Figma I built a 3") == 5,
          "words are counted without asterisks, dashes and single letters (a logo read as a letter)")
    let moved = ThumbnailLayout.Move(scale: 0.5, shift: -100, originX: 1000, originY: 1000).apply(CGRect(x: 0, y: 0, width: 100, height: 100))
    equal(moved, CGRect(x: 400, y: 500, width: 50, height: 50), "the speaker's move scales about its origin, then shifts")

    func phoneLayout(title: String = "Edit for the", accent: String = "viewer", size: Double = 170, band: String? = nil) -> ThumbnailLayout {
        let box = ThumbnailLayout.Box(CGRect(x: 1000, y: 300, width: 700, height: size))
        return ThumbnailLayout(titleSize: size, runs: [
            ThumbnailLayout.Run(kind: .title, text: title, boxes: [box], size: size, color: "#FFFFFF", background: nil),
            ThumbnailLayout.Run(kind: .accent, text: accent, boxes: [box], size: size, color: "#F5C42C", background: band)],
                               picture: nil, speaker: nil)
    }
    let bigFace = CGRect(x: 200, y: 100, width: 300, height: 400)
    let readable = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: bigFace)
    check(readable.reads && readable.words == 4 && readable.titleSize == 170, "big words, few of them, a big face: it reads", "\(readable.findings)")
    let smallTitle = PhoneCheck.make(layout: phoneLayout(size: 80), contrasts: [12, 9], face: bigFace)
    check(smallTitle.findings.count == 1 && smallTitle.findings[0].kind == .textSize && smallTitle.findings[0].level == .fails
              && smallTitle.findings[0].sizes == [.searchList] && smallTitle.findings[0].message.contains("103 px"),
          "a title of 80 px does not read in the search list, and the check says the size it needs", "\(smallTitle.findings)")
    let weakTitle = PhoneCheck.make(layout: phoneLayout(size: 110), contrasts: [12, 9], face: bigFace)
    check(weakTitle.findings.map(\.level) == [.weak] && weakTitle.findings[0].sizes == [.searchList],
          "a title of 110 px is weak in the search list only", "\(weakTitle.findings)")
    let tinyTitle = PhoneCheck.make(layout: phoneLayout(size: 30), contrasts: [12, 9], face: bigFace)
    check(tinyTitle.findings.count == 1 && tinyTitle.findings[0].sizes == PhoneSize.allCases && tinyTitle.findings[0].message.contains("search list"),
          "a problem at both sizes is one finding, with the smaller size's numbers", "\(tinyTitle.findings)")
    var tagged = phoneLayout()
    tagged.runs.insert(ThumbnailLayout.Run(kind: .tag, text: "3 RULES", boxes: [ThumbnailLayout.Box(CGRect(x: 1000, y: 200, width: 200, height: 70))],
                                           size: 46, color: "#121417", background: "#F5C42C"), at: 0)
    let taggedCheck = PhoneCheck.make(layout: tagged, contrasts: [11, 12, 9], face: bigFace)
    check(taggedCheck.findings.count == 2 && taggedCheck.findings[0].kind == .textSize && taggedCheck.findings[0].level == .weak
              && taggedCheck.findings[0].sizes == PhoneSize.allCases && taggedCheck.findings[0].message.contains("fixed size")
              && taggedCheck.findings[0].message.contains("“3 RULES” is 4 pt") && taggedCheck.findings[1].kind == .words,
          "the tag is a small label of fixed size: too small is weak, with advice to keep the words in the title", "\(taggedCheck.findings)")
    let wordy = PhoneCheck.make(layout: phoneLayout(title: "How I edit my talking head videos on a", accent: "Mac"), contrasts: [12, 9], face: bigFace)
    let someWords = PhoneCheck.make(layout: phoneLayout(title: "How I edit my", accent: "videos now"), contrasts: [12, 9], face: bigFace)
    check(wordy.findings.map(\.kind) == [.words] && wordy.findings[0].level == .fails && wordy.words == 10
              && someWords.findings.map(\.level) == [.weak] && someWords.words == 6,
          "more than 8 words do not read in 0.5 s, and 6 to 8 are weak", "\(wordy.findings) \(someWords.findings)")
    let yellowOnWhite = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 1.6], face: bigFace)
    let lowTitle = PhoneCheck.make(layout: phoneLayout(), contrasts: [3.6, 9], face: bigFace)
    check(yellowOnWhite.findings.map(\.kind) == [.contrast, .eyePath] && yellowOnWhite.findings[0].level == .fails
              && yellowOnWhite.findings[0].message.contains("“viewer”") && yellowOnWhite.findings[0].message.contains("Highlight")
              && lowTitle.findings.map(\.level) == [.weak],
          "coloured words with low contrast do not read, and the check says to turn on Highlight", "\(yellowOnWhite.findings)")
    let banded = PhoneCheck.make(layout: phoneLayout(band: "#F5C42C"), contrasts: [12, 1.6], face: bigFace)
    check(banded.findings.first?.message.contains("another accent colour") == true, "words on a band of low contrast need another accent", "\(banded.findings)")
    let smallFace = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: CGRect(x: 0, y: 0, width: 120, height: 150))
    let weakFace = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: CGRect(x: 0, y: 0, width: 160, height: 200))
    let noFace = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: nil)
    check(smallFace.findings.map(\.level) == [.fails] && smallFace.findings[0].sizes == [.searchList]
              && weakFace.findings.map(\.level) == [.weak] && noFace.findings.map(\.kind) == [.face] && noFace.findings[0].level == .weak,
          "a face of 150 px does not read in the search list, 200 px is weak, and no face is weak",
          "\(smallFace.findings) \(weakFace.findings) \(noFace.findings)")
    let allFindings = [smallTitle, weakTitle, tinyTitle, taggedCheck, wordy, someWords, yellowOnWhite, lowTitle, banded, smallFace, weakFace, noFace]
        .flatMap(\.findings)
    check(allFindings.allSatisfy { $0.summary.count <= 48 && !$0.summary.isEmpty && $0.message.count > $0.summary.count }
              && smallTitle.findings[0].summary == "Title too small: 7 pt in the search list"
              && yellowOnWhite.findings[0].summary == "Low contrast: “viewer” 1.6:1" && taggedCheck.findings[0].summary == "Tag too small: 4 pt in the search list",
          "each finding has one short line for the maker, and the full advice", "\(allFindings.map(\.summary))")
    let mixed = PhoneCheck.make(layout: phoneLayout(size: 110), contrasts: [12, 1.6], face: nil)
    check(mixed.findings.map(\.level) == [.fails, .weak, .weak] && mixed.findings.map(\.kind) == [.contrast, .textSize, .face],
          "the findings come worst first", "\(mixed.findings.map { "\($0.level) \($0.kind)" })")

    // The drawn design: the page measures its words, and a second picture leaves them out.
    var phoneDesign = thumbnailDesign
    phoneDesign.background = .solid
    let measured = try await ThumbnailMaker.measure(phoneDesign, sources: subjectSources, accent: "#F5C42C")
    let runKinds = measured.layout.runs.map(\.kind)
    let accentRun = measured.layout.runs.first { $0.kind == .accent }
    check(runKinds == [.tag, .title, .accent] && (56...170).contains(measured.layout.titleSize)
              && accentRun?.color == "#F5C42C" && accentRun?.background == nil && accentRun?.text == "viewer"
              && measured.layout.runs[0].background == "#F5C42C" && measured.layout.runs[1].color == "#FFFFFF"
              && measured.layout.runs.allSatisfy { !$0.boxes.isEmpty && $0.boxes.allSatisfy { $0.x > 960 } },
          "the page gives each run of words with its boxes, size and colours", "\(measured.layout)")
    let titleMask = LetterMask(measured.letters)
    let maskedTitle = titleMask.values.enumerated().filter { $0.element }.map { $0.offset % titleMask.width }
    check(measured.image.width == 1280 && maskedTitle.count > 800 && maskedTitle.allSatisfy { $0 > 320 }
              && LetterMask(measured.image).values.filter { $0 }.isEmpty,
          "the letters picture marks the title's letters, on the title's side, and the thumbnail has no magenta",
          "\(maskedTitle.count) \(maskedTitle.min() ?? -1)")
    let drawnCheck = PhoneCheck.make(layout: measured.layout, image: measured.image, letters: measured.letters, face: nil, frameWidth: 1280, pictureWords: [])
    check(!drawnCheck.findings.contains { $0.kind == .contrast } && drawnCheck.findings.contains { $0.kind == .face } && drawnCheck.words == 6,
          "white and yellow words on the dark plain background read; the frame has no face", "\(drawnCheck.findings)")
    var phoneWhite = phoneDesign; phoneWhite.background = .white; phoneWhite.side = .left; phoneWhite.place = .clear
    let whiteMeasured = try await ThumbnailMaker.measure(phoneWhite, sources: subjectSources, accent: "#F5C42C")
    let whiteCheck = PhoneCheck.make(layout: whiteMeasured.layout, image: whiteMeasured.image, letters: whiteMeasured.letters,
                                     face: CGRect(x: 360, y: 60, width: 120, height: 150), frameWidth: 1280, pictureWords: [])
    let speakerMove = whiteMeasured.layout.speaker
    check(whiteCheck.findings.contains { $0.kind == .contrast && $0.level == .fails && $0.message.contains("“viewer”") }
              && !whiteCheck.findings.contains { $0.kind == .contrast && $0.message.contains("title words") },
          "yellow words on white do not read; the dark title words do", "\(whiteCheck.findings)")
    check(speakerMove.map { $0.shift > 100 && $0.scale <= 1 } == true
              && whiteCheck.face.map { abs($0.minX - (speakerMove!.originX + (540 - speakerMove!.originX) * speakerMove!.scale + speakerMove!.shift)) < 0.5 } == true,
          "the face moves with the speaker, in design pixels", "\(String(describing: speakerMove)) \(String(describing: whiteCheck.face))")
    check(whiteMeasured.layout.frame == false && measured.layout.frame == false, "the page says when the frame does not show")
    var phoneFrameOnly = phoneWhite; phoneFrameOnly.cutout = false
    let frameOnly = try await ThumbnailMaker.measure(phoneFrameOnly, sources: subjectSources, accent: "#F5C42C")
    let hiddenFace = PhoneCheck.make(layout: frameOnly.layout, image: frameOnly.image, letters: frameOnly.letters,
                                     face: CGRect(x: 360, y: 60, width: 120, height: 150), frameWidth: 1280, pictureWords: [])
    var phoneDim = phoneFrameOnly; phoneDim.background = .dim
    let dimFrame = try await ThumbnailMaker.measure(phoneDim, sources: subjectSources, accent: "#F5C42C")
    let dimFace = PhoneCheck.make(layout: dimFrame.layout, image: dimFrame.image, letters: dimFrame.letters,
                                  face: CGRect(x: 360, y: 60, width: 120, height: 150), frameWidth: 1280, pictureWords: [])
    check(frameOnly.layout.speaker == nil && hiddenFace.face == nil && hiddenFace.findings.contains { $0.message.hasPrefix("The face does not show") }
              && dimFrame.layout.frame && dimFace.face == CGRect(x: 540, y: 90, width: 180, height: 225),
          "without the cut-out, a white background hides the face; a darker frame shows it where it is",
          "\(hiddenFace.findings) \(String(describing: dimFace.face))")
    var phoneMarked = phoneWhite; phoneMarked.highlight = true
    let markedMeasured = try await ThumbnailMaker.measure(phoneMarked, sources: subjectSources, accent: "#F5C42C")
    let markedCheck = PhoneCheck.make(layout: markedMeasured.layout, image: markedMeasured.image, letters: markedMeasured.letters,
                                      face: nil, frameWidth: 1280, pictureWords: [])
    check(markedMeasured.layout.runs.first { $0.kind == .accent }?.background == "#F5C42C" && !markedCheck.findings.contains { $0.kind == .contrast },
          "with Highlight the yellow band gives the dark words their contrast", "\(markedCheck.findings)")

    // Words in the picture beside the title, read with Apple Vision.
    let wordsPicture = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-words-\(UUID().uuidString).png")
    let wordsImage = CGImage.blank(width: 800, height: 300).drawn { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("BUILT IN A WEEK" as NSString).draw(at: CGPoint(x: 40, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 80, weight: .bold),
                                                                                       .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
    }
    try NSBitmapImageRep(cgImage: wordsImage).representation(using: .png, properties: [:])!.write(to: wordsPicture)
    defer { try? FileManager.default.removeItem(at: wordsPicture) }
    let readWords = PhoneCheck.words(in: wordsPicture)
    check(readWords.count == 1 && readWords[0].text.uppercased() == "BUILT IN A WEEK" && readWords[0].box.minY > 0.3 && readWords[0].box.maxY < 0.75,
          "Apple Vision reads the words in the picture and where they are", "\(readWords)")
    var phonePictured = phoneDesign; phonePictured.image = wordsPicture
    let picturedMeasured = try await ThumbnailMaker.measure(phonePictured, sources: subjectSources, accent: "#F5C42C")
    let picturedCheck = PhoneCheck.make(layout: picturedMeasured.layout, image: picturedMeasured.image, letters: picturedMeasured.letters,
                                        face: nil, frameWidth: 1280, pictureWords: readWords)
    check(picturedMeasured.layout.picture != nil && picturedCheck.words == 10
              && picturedCheck.findings.contains { $0.kind == .textSize && $0.message.contains("in the picture") }
              && !picturedCheck.findings.contains { $0.kind == .contrast },
          "the picture's words count, and their size is checked; black on white reads", "\(picturedCheck.findings)")
    let phoneSheet = PhoneCheck.phonePicture(measured.image)
    check(phoneSheet.map { $0.width == 2 * (16 * 3 + 390 + 168) && $0.height > 2 * 219 } == true, "a picture of both phone sizes, at 2 pixels for each point",
          "\(String(describing: phoneSheet?.width)) × \(String(describing: phoneSheet?.height))")

    print("\nInformation gap")
    check(InformationGap.tokens("Designers’ stories, Rahul's GLASS").map(\.stem) == ["designer", "story", "rahul", "glass"]
              && InformationGap.tokens("*10× FASTER*").map(\.text) == ["10", "FASTER"],
          "words are compared without case, plurals, possessives and asterisks")
    let agentuxGap = InformationGap.make(thumbnail: ["DESIGN ENGINEERING", "*SYSTEM\u{00A0}DESIGN*\nFOR\u{00A0}DESIGNERS",
                                                     "HOW I BUILT MY OWN Supabase Claude Figma"],
                                         title: "System design for designers: how I built my own Mobbin (Part 1)")
    check(agentuxGap.phrases == ["System design for designers", "how I built my own"] && agentuxGap.repeated == ["design", "System", "designers", "built"]
              && agentuxGap.added == ["ENGINEERING", "Supabase", "Claude", "Figma"] && agentuxGap.overlap == 0.5
              && agentuxGap.finding?.level == .weak && agentuxGap.finding?.kind == .title && agentuxGap.finding?.sizes == []
              && agentuxGap.finding?.message.contains("“System design for designers”") == true,
          "the AgentUX thumbnail repeats two phrases of its title (a run stops at the colon), and adds four words",
          "\(agentuxGap)")
    check(agentuxGap.finding?.summary == "Repeats the video title: “System design for…”", "the gap's short line cuts the phrase after a whole word",
          agentuxGap.finding?.summary ?? "none")
    let onlyRepeats = InformationGap.make(thumbnail: ["", "I REBUILT *MOBBIN*"], title: "I rebuilt Mobbin in a week")
    let addsResult = InformationGap.make(thumbnail: ["", "*10× FASTER*"], title: "I rebuilt Mobbin in a week")
    check(onlyRepeats.finding?.level == .fails && onlyRepeats.added.isEmpty && onlyRepeats.overlap == 1
              && addsResult.finding == nil && addsResult.added == ["10", "FASTER"] && addsResult.repeated.isEmpty,
          "a thumbnail that only repeats the title opens no question; a result the title does not give is fine")
    let oneWord = InformationGap.make(thumbnail: ["", "Stories"], title: "Three stories about design")
    let noTitle = InformationGap.make(thumbnail: ["", "Design systems"], title: "")
    let smallOnly = InformationGap.make(thumbnail: ["", "How I did it"], title: "How I did it")
    check(oneWord.finding?.level == .weak && noTitle.finding == nil && noTitle.added == ["Design", "systems"] && smallOnly.finding == nil,
          "one repeated word is weak; with no title or only small words there is nothing to compare")
    let splitTexts = InformationGap.make(thumbnail: ["SYSTEM", "DESIGN"], title: "System design")
    check(splitTexts.phrases.isEmpty && splitTexts.finding?.level == .fails, "a run of shared words does not go from the tag to the title")
    check(InformationGap.make(thumbnail: ["", "", "g Figma"], title: "Figma").added.isEmpty, "a single letter read in a logo is not a word the thumbnail adds")
    let designGap = InformationGap.make(ThumbnailDesign(time: 0, title: "Edit for the *viewer*"), pictureWords: ["HOW I EDIT", "TALKING HEADS"],
                                        title: "How I edit talking heads")
    check(designGap.phrases == ["How I edit talking heads"] && designGap.added == ["viewer"],
          "a design's words: its tag, its title and the picture's lines as one text", "\(designGap)")
    let gapped = PhoneCheck.make(layout: phoneLayout(size: 110), contrasts: [12, 9], face: bigFace).adding(onlyRepeats)
    check(gapped.findings.map(\.kind) == [.title, .textSize] && gapped.findings[0].level == .fails && !gapped.reads
              && PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: bigFace).adding(addsResult).reads,
          "the title's finding joins the phone check's list, worst first")
    check(picturedCheck.pictureWords.map { $0.uppercased() } == ["BUILT IN A WEEK"], "the check keeps the lines read in the picture")

    print("\nEye path")
    let readablePath = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 9], face: bigFace)
    check(readablePath.path.map(\.kind) == [.face, .accent, .title] && readablePath.path[0].pull == 400
              && !readablePath.findings.contains { $0.kind == .eyePath },
          "the eye goes to the face, then to the coloured words, then to the rest of the title", "\(readablePath.path.map(\.kind))")
    let hiddenAccent = PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 1.6], face: bigFace)
    let pathFinding = hiddenAccent.findings.first { $0.kind == .eyePath }
    check(hiddenAccent.path.map(\.kind) == [.face, .title, .accent] && pathFinding?.level == .weak && pathFinding?.sizes == []
              && pathFinding?.summary == "Eye path: “viewer” is 3rd"
              && pathFinding?.message.contains("after the face and “Edit for the”") == true,
          "coloured words of low contrast fall to 3rd, and the check says so", "\(hiddenAccent.path.map(\.kind)) \(String(describing: pathFinding))")
    check(PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 1.6], face: nil).path.map(\.kind) == [.title, .accent]
              && !PhoneCheck.make(layout: phoneLayout(), contrasts: [12, 1.6], face: nil).findings.contains { $0.kind == .eyePath },
          "without a face, 2nd is still fine")
    var bigPictureWords = phoneLayout()
    bigPictureWords.runs.append(ThumbnailLayout.Run(kind: .picture, text: "10× FASTER", boxes: [ThumbnailLayout.Box(CGRect(x: 1000, y: 600, width: 700, height: 200))],
                                                    size: 200, color: nil, background: nil))
    bigPictureWords.runs.insert(ThumbnailLayout.Run(kind: .tag, text: "3 RULES", boxes: [ThumbnailLayout.Box(CGRect(x: 1000, y: 200, width: 200, height: 70))],
                                                    size: 46, color: "#121417", background: "#F5C42C"), at: 0)
    let pictureFirst = PhoneCheck.make(layout: bigPictureWords, contrasts: [11, 12, 9, 10], face: bigFace)
    check(pictureFirst.path.map(\.kind) == [.face, .picture, .accent, .title, .tag]
              && pictureFirst.findings.contains { $0.kind == .eyePath && $0.message.contains("after the face and the picture's words") },
          "big words in the picture come before the title; the tag comes last", "\(pictureFirst.path.map(\.kind))")
    let banded2 = PhoneCheck.make(layout: phoneLayout(band: "#F5C42C"), contrasts: [12, 11], face: bigFace)
    check(banded2.path[1].kind == .accent && abs(banded2.path[1].pull - 170 * EyePath.colourPull.band) < 0.01,
          "a band of the accent pulls the eye most of all the words")
    var plainOnly = phoneLayout(); plainOnly.runs.removeLast()
    check(!PhoneCheck.make(layout: plainOnly, contrasts: [3], face: bigFace).findings.contains { $0.kind == .eyePath }
              && EyePath.ordinal(4) == "4th" && EyePath.ordinal(2) == "2nd",
          "with no words marked there is no eye path warning")
    check((try? JSONEncoder().encode(pictureFirst.path)) != nil, "the path can be sent as JSON")
    check(drawnCheck.path.first?.kind == .accent && drawnCheck.path.map(\.kind).contains(.tag)
              && drawnCheck.path.allSatisfy { $0.kind == .face || $0.box.x > 960 },
          "on a drawn design, the path has its runs on the title's side", "\(drawnCheck.path.map { "\($0.kind) \($0.box)" })")

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
    check(frostSaved == frostProject && frostSaved.version >= 17 && (try? frostSaved.validate()) != nil && (try? frostAsSixteen.validate()) == nil,
          "the frost and the picture size survive a version 17 round trip, and a version 16 file with them is refused")
    var shadeProject = designSaved
    shadeProject.clips[0].publish?.design?.background = .shade; shadeProject.clips[0].publish?.design?.vivid = 1.2
    let shadeSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(shadeProject))
    var shadeAsTwentyFour = shadeSaved; shadeAsTwentyFour.version = 24
    check(shadeSaved == shadeProject && shadeSaved.version >= 25 && (try? shadeSaved.validate()) != nil && (try? shadeAsTwentyFour.validate()) == nil,
          "the dark frost and vivid survive a version 25 round trip, and a version 24 file with them is refused")

    thumbnailer.selection = subjectItem.id
    thumbnailer.showModule(.library)
    check(thumbnailer.openThumbnailMaker() && thumbnailer.showingThumbnailMaker && thumbnailer.module == .studio,
          "Make Thumbnail… opens the maker for the selected recording, from any page, on the Studio page")
    thumbnailer.showingThumbnailMaker = false
    thumbnailer.setMovieMode(true)
    check(!thumbnailer.canMakeThumbnail && !thumbnailer.openThumbnailMaker() && !thumbnailer.showingThumbnailMaker
              && thumbnailer.statusMessage == "Make Thumbnail works in Recording mode.",
          "in Movie mode it does not open, and says why")
    thumbnailer.setMovieMode(false)
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
    tryDesign["check"] = true
    let triedCheck = agentResult(await agentCall(thumbnailer, tryDesign))
    let phoneReport = triedCheck["check"] as? [String: Any] ?? [:]
    let agentPath = phoneReport["path"] as? [[String: Any]] ?? []
    check(agentPath.first?["step"] as? Int == 1 && agentPath.first?["kind"] as? String == "accent"
              && (agentPath.first?["box"] as? [String: Any])?["width"] as? Double ?? 0 > 0,
          "with check, an agent gets the eye path in order, with boxes", "\(agentPath)")
    let phoneFindings = phoneReport["findings"] as? [[String: Any]] ?? []
    check(FileManager.default.fileExists(atPath: triedCheck["path"] as? String ?? "") && phoneReport["reads"] as? Bool == false
              && phoneFindings.contains { $0["kind"] as? String == "face" && ($0["sizes"] as? [String])?.count == 2 && $0["level"] as? String == "weak" }
              && (phoneReport["titleSize"] as? Double ?? 0) >= 56 && FileManager.default.fileExists(atPath: phoneReport["phone"] as? String ?? ""),
          "with check, an agent gets the phone check and a picture of both phone sizes", "\(phoneReport)")
    let storedGap = phoneReport["gap"] as? [String: Any] ?? [:]
    check(storedGap["title"] as? String == "Subject" && (storedGap["added"] as? [String])?.isEmpty == false
              && !phoneFindings.contains { $0["kind"] as? String == "title" },
          "the check compares the thumbnail's words with the stored video title", "\(storedGap)")
    tryDesign["videoTitle"] = "A big title for new people"
    let triedTitle = agentResult(await agentCall(thumbnailer, tryDesign))
    let triedGap = (triedTitle["check"] as? [String: Any])?["gap"] as? [String: Any] ?? [:]
    let triedFindings = (triedTitle["check"] as? [String: Any])?["findings"] as? [[String: Any]] ?? []
    check(triedGap["title"] as? String == "A big title for new people" && (triedGap["phrases"] as? [String]) == ["big title"]
              && triedFindings.contains { $0["kind"] as? String == "title" && $0["level"] as? String == "fails" && ($0["sizes"] as? [String])?.isEmpty == true }
              && thumbnailer.items[0].publish?.title == "Subject",
          "an agent tries a video title without storing it, and hears that the thumbnail only repeats it", "\(triedGap) \(triedFindings)")
    tryDesign["videoTitle"] = nil
    tryDesign["check"] = nil
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

    print("\nTest & Compare")
    var versionB = ThumbnailDesign(time: 1, title: "*3 rules*"); versionB.background = .white
    var versionC = ThumbnailDesign(time: 0.5, title: "Big *title*"); versionC.zoom = 1.3
    let imageA = URL(fileURLWithPath: savedThumbPath)
    let imageB = scratch.appendingPathComponent("subject thumbnail B.png")
    try? FileManager.default.removeItem(at: imageB)
    try FileManager.default.copyItem(at: imageA, to: imageB)
    check(ThumbnailTest(versions: []).problem != nil && ThumbnailTest(versions: [versionB, versionC, versionB]).problem != nil
              && ThumbnailTest(versions: [versionB], images: [imageA]).problem != nil
              && ThumbnailTest(versions: [versionB], winner: 1).problem?.contains("Save") == true
              && ThumbnailTest(versions: [versionB], images: [imageA, imageB], winner: 2).problem != nil
              && ThumbnailTest(versions: [versionB, versionC], images: [imageA, imageB, imageB], winner: 2).problem == nil,
          "a test has 2 or 3 versions, an image for each once saved, and a winner among them after a save")
    var noDesign = PublishInfo(); noDesign.test = ThumbnailTest(versions: [versionB])
    check(noDesign.problem?.contains("version A") == true, "a test needs version A, the design")
    var tested = PublishInfo(); tested.title = "Subject"; tested.design = ThumbnailDesign(time: 1, title: "Big *title*")
    tested.test = ThumbnailTest(versions: [versionB], images: [imageA, imageB])
    tested.thumbnail = imageA
    var marked = tested; marked.markWinner(1)
    check(tested.versions.map(\.title) == ["Big *title*", "*3 rules*"] && marked.test?.winner == 1 && marked.thumbnail == imageB,
          "the winner's picture becomes the thumbnail")
    marked.markWinner(nil)
    check(marked.test?.winner == nil && marked.thumbnail == imageB, "clearing the winner leaves the thumbnail")

    check(thumbnailer.perform([.setPublishInfo(clip: subjectItem.id, info: tested)]).isSuccess, "versions are kept with the publish details")
    let testedSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(thumbnailer.project))
    var testedAsEighteen = testedSaved; testedAsEighteen.version = 18
    check(testedSaved == thumbnailer.project && testedSaved.version >= 19 && (try? testedSaved.validate()) != nil
              && (try? testedAsEighteen.validate()) == nil && testedSaved.clips[0].publish?.test?.images == [imageA, imageB],
          "the versions survive a version 19 round trip, and a version 18 file with them is refused")
    var lateVersion = tested; lateVersion.test?.versions[0].time = 9
    check(thumbnailer.perform([.setPublishInfo(clip: subjectItem.id, info: lateVersion)]).isFailure,
          "a version's frame after the end is refused")
    _ = thumbnailer.perform([.splitSection(clip: subjectItem.id, at: 0.5)])
    let afterSplit = thumbnailer.items[0].timeline.segments
    _ = thumbnailer.perform([.deleteSection(clip: subjectItem.id, section: afterSplit[0].id)])
    check(abs((thumbnailer.items[0].publish?.test?.versions[0].time ?? 0) - 0.5) < 0.01,
          "a version's frame follows its footage when a cut removes time before it",
          "\(String(describing: thumbnailer.items[0].publish?.test?.versions[0].time))")
    thumbnailer.undo(); thumbnailer.undo()

    // Export for YouTube writes each version, and says where they go.
    let testFiles = YouTubeExport.files(in: scratch, publish: marked, fallback: "x", captions: false, unique: false)
    var winnerMarked = marked; winnerMarked.markWinner(1)
    let testJSON = try JSONSerialization.jsonObject(with: try YouTubeExport.json(winnerMarked, files: testFiles)) as? [String: Any] ?? [:]
    let testJSONVersions = (testJSON["thumbnailTest"] as? [String: Any])?["versions"] as? [[String: Any]] ?? []
    let testText = winnerMarked.uploadText(files: [], tests: testFiles.tests.map(\.lastPathComponent))
    check(testFiles.tests.map(\.lastPathComponent) == ["Subject thumbnail A.jpg", "Subject thumbnail B.jpg"]
              && testJSONVersions.map { $0["version"] as? String ?? "" } == ["A", "B"]
              && (testJSON["thumbnailTest"] as? [String: Any])?["winner"] as? String == "B"
              && testText.contains("THUMBNAIL TEST & COMPARE") && testText.contains("B: Subject thumbnail B.jpg") && testText.contains("Winner: B"),
          "Export for YouTube names a JPEG for each version, and the text and JSON list them with the winner", testText)
    for (target, source) in zip(testFiles.tests, winnerMarked.test!.images) { try YouTubeExport.writeThumbnail(source, to: target) }
    var testWidths: [Int] = []
    for file in testFiles.tests { testWidths.append((try? await FFmpeg.probe(url: file))?.width ?? 0) }
    equal(testWidths, [1280, 1280], "each version becomes a 1280×720 JPEG")
    var missingVersion = winnerMarked; missingVersion.test?.images[1] = scratch.appendingPathComponent("gone.png")
    check(missingVersion.issues(duration: 2).contains { $0.severity == .blocking && $0.message.contains("Version B") }
              && tested.issues(duration: 2).allSatisfy { $0.severity != .blocking || $0.field != "thumbnail" },
          "a version's missing picture stops Export for YouTube")
    var unsavedTest = tested; unsavedTest.test?.images = []
    check(unsavedTest.issues(duration: 2).contains { $0.severity == .warning && $0.message.contains("not saved") },
          "versions not yet saved are a warning")

    // Agents set the versions, draw each, and mark the winner.
    var setVersions = address(thumbnailer)
    setVersions["method"] = "apply"; setVersions["requestID"] = "versions-1"; setVersions["client"] = "Claude"
    setVersions["commands"] = [["type": "setPublishInfo", "clipID": subjectItem.id.uuidString,
                                "publish": ["test": ["versions": [["time": 1, "title": "*Agent* B", "background": "white"]], "images": []]]]]
    let versionsReply = await agentCall(thumbnailer, setVersions)
    check(versionsReply["ok"] as? Bool == true && thumbnailer.items[0].publish?.test?.versions.first?.title == "*Agent* B"
              && thumbnailer.items[0].publish?.test?.images.isEmpty == true,
          "an agent sets version B", "\(versionsReply)")
    var drawB = address(thumbnailer)
    drawB["method"] = "thumbnail"; drawB["clip"] = subjectItem.id.uuidString; drawB["version"] = "b"; drawB["save"] = true
    let drawnB = agentResult(await agentCall(thumbnailer, drawB))
    check(drawnB["version"] as? String == "B" && (drawnB["design"] as? [String: Any])?["title"] as? String == "*Agent* B"
              && (drawnB["savedPath"] as? String ?? "").contains("subject thumbnail B"),
          "an agent draws and saves version B, with its letter in the file's name", "\(drawnB)")
    drawB["version"] = "C"; drawB["save"] = nil
    check(((await agentCall(thumbnailer, drawB))["error"] as? [String: Any])?["message"] as? String ?? "" == "The recording has no version C. Add it with setPublishInfo: {test: {versions: [B, C]}}.",
          "a version the recording does not have is refused")
    drawB["version"] = "D"
    check(((await agentCall(thumbnailer, drawB))["error"] as? [String: Any])?["message"] as? String ?? "" == "version is A, B or C.",
          "only A, B and C are versions")
    var setImages = address(thumbnailer)
    setImages["method"] = "apply"; setImages["client"] = "Claude"; setImages["requestID"] = "versions-2"
    setImages["commands"] = [["type": "setPublishInfo", "clipID": subjectItem.id.uuidString,
                              "publish": ["test": ["images": [imageA.path, drawnB["savedPath"] as? String ?? ""]]]]]
    check((await agentCall(thumbnailer, setImages))["ok"] as? Bool == true && thumbnailer.items[0].publish?.test?.images.count == 2,
          "an agent stores the versions' images")
    var setWinner = address(thumbnailer)
    setWinner["method"] = "apply"; setWinner["client"] = "Claude"; setWinner["requestID"] = "versions-3"
    setWinner["commands"] = [["type": "setPublishInfo", "clipID": subjectItem.id.uuidString, "publish": ["test": ["winner": 1]]]]
    let winnerReply = await agentCall(thumbnailer, setWinner)
    check(winnerReply["ok"] as? Bool == true && thumbnailer.items[0].publish?.test?.winner == 1
              && thumbnailer.items[0].publish?.thumbnail?.path == drawnB["savedPath"] as? String
              && thumbnailer.items[0].publish?.test?.versions.first?.title == "*Agent* B",
          "an agent marks B the winner: its picture becomes the thumbnail, and the versions stay", "\(winnerReply)")

    // The owner marks the winner in the maker: the project's idea in the Library notes it.
    thumbnailer.loadLibrary(from: scratch.appendingPathComponent("thumb-library-\(UUID().uuidString)", isDirectory: true))
    let testIdea = ContentItem(title: "Edit for the viewer", notes: "Hook first.")
    _ = thumbnailer.performLibrary([.addIdea(testIdea), .linkProject(id: testIdea.id, link: ProjectLink(projectID: thumbnailer.projectID, path: "/tmp/x.yamvideo"))])
    thumbnailer.selection = subjectItem.id
    thumbnailer.markThumbnailWinner(0)
    let ideaNotes = thumbnailer.library.item(testIdea.id)?.notes ?? ""
    check(thumbnailer.items[0].publish?.test?.winner == 0 && thumbnailer.items[0].publish?.thumbnail == imageA
              && ideaNotes.hasPrefix("Hook first.\nThumbnail test, ") && ideaNotes.hasSuffix(": A won of 2 (“Big title”)."),
          "the owner marks A the winner: it becomes the thumbnail, and the idea's notes keep the result", ideaNotes)
    thumbnailer.markThumbnailWinner(nil)
    check(thumbnailer.items[0].publish?.test?.winner == nil && thumbnailer.library.item(testIdea.id)?.notes == ideaNotes,
          "clearing the winner adds no note")

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
    check(manualCatalog.methods.first { $0.method == "thumbnail" }.map { "\($0)".contains("\"check\"") && "\($0)".contains("homeFeed") } == true
              && manualText.contains("check: true"),
          "the catalog and the manual give the phone check")
    check(manualCatalog.methods.first { $0.method == "thumbnail" }.map { "\($0)".contains("videoTitle") && "\($0)".contains("phrases") } == true
              && manualText.contains("check.gap"),
          "the catalog and the manual give the information gap")
    check(manualCatalog.methods.first { $0.method == "thumbnail" }.map { "\($0)".contains("eyePath") && "\($0)".contains("path (where the eye goes") } == true
              && manualText.contains("check.path"),
          "the catalog and the manual give the eye path")
    let catalogJSON = String(decoding: try JSONEncoder().encode(manualCatalog), as: UTF8.self)
    check(manualCatalog.methods.first { $0.method == "thumbnail" }.map { "\($0)".contains("\"version\"") } == true
              && catalogJSON.contains("test (YouTube's Test & Compare") && manualText.contains("Test & Compare"),
          "the catalog and the manual give the versions for Test & Compare")
    check(AgentsManual.brief(ctl: "/x/yamvideoctl").contains("/x/yamvideoctl manual") && AgentsManual.brief(ctl: nil).contains("yamvideo_manual"),
          "the brief for an agent names how to read the manual")


}
