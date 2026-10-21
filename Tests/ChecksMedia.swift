import AppKit
import Foundation

/// The Media panel, the Captions track and the linked Audio track (step 4 of the Studio
/// redesign).
@MainActor func mediaTests() async throws {
    print("\nMedia panel")
    let assets: [MediaAsset] = [.namePlate, .titleCard, .featureList, .checklist, .kineticText, .sectionCard, .endScreen, .logo("Figma"),
                                .blurArea, .fullFrameBlur, .zoom, .screenZoom, .marker]
    check(assets.allSatisfy { MediaAsset(dragText: $0.dragText) == $0 }, "every asset survives a drag")
    check(MediaAsset(dragText: "namePlate") == nil && MediaAsset(dragText: "hello") == nil, "a drop of other text adds nothing")

    let model = AppModel(recoveryURL: nil)
    var clip = ProjectClip(VideoItem(url: landscape))
    clip.info = info; clip.crop = info.fullFrame
    model.restore(VideoProject(clips: [clip], settings: ExportSettings(), selection: clip.id))
    model.add(.namePlate, at: 0.5)
    let plate = model.selectedItem?.graphics?.items.first
    check(plate?.kind == .namePlate && abs((plate?.start ?? 0) - 0.5) < 0.05, "a name plate goes where it is dropped")
    equal(model.selectedGraphicID, plate?.id, "and is selected, to change its words")
    let steps = model.undoEntries.count
    model.add(.marker, at: 2)
    check(model.selectedItem?.markers.contains { abs($0.time - 2) < 0.05 } == true, "a marker goes where it is dropped")
    equal(model.undoEntries.count, steps + 1, "as one undo step")
    model.add(.screenZoom)
    check(model.statusMessage?.contains("screen recording") == true, "a screen zoom needs a screen recording first")
    let library = [LogoLibrary.Logo(name: "Figma", words: ["figma"], file: "figma.png")]
    model.setPreviewFraction(0.1)
    model.addLogoBadge(named: "Figma", library: library)
    let badge = model.selectedItem?.graphics?.items.first { $0.kind == .logoBadge }
    check(badge.map { LogoBadge.logos($0.props).first?.label == "Figma" } == true, "a logo from the library adds its badge")
    model.addLogoBadge(named: "Nobody", library: library)
    check(model.statusMessage?.contains("No logo") == true, "a logo that is not in the library is refused")

    print("\nGraphics gallery")
    let samples = GallerySample.all
    // Each sample is checked as a video of its own length, as the gallery draws it (an end screen must end with the video).
    let sampleProblems = samples.compactMap { s in s.track(style: GraphicsStyle(), look: .glass).problem(duration: s.length).map { s.id + ": " + $0 } }
    check(sampleProblems.isEmpty && Set(samples.map(\.id)).count == samples.count && samples.allSatisfy { $0.beat > 0 && $0.beat < $0.length },
          "every gallery sample is a valid graphic, once, with its picture's beat inside it", sampleProblems.joined(separator: "; "))
    var pink = GraphicsStyle(); pink.accent = "#D962C0"
    let card = samples.first { $0.kind == .titleCard }!, list = samples.first { $0.kind == .checklist }!
    check(card.pictureKey(style: pink, look: .glass) == card.pictureKey(style: pink, look: .glass)
              && card.pictureKey(style: pink, look: .glass) != card.pictureKey(style: GraphicsStyle(), look: .glass)
              && list.pictureKey(style: pink, look: .glass) != list.pictureKey(style: pink, look: .ink),
          "a gallery picture is kept by its style and look, and drawn again when either changes")
    var inkStyle = GraphicsStyle(); inkStyle.look = .mix
    check(GalleryLook(style: GraphicsStyle()) == .glass && GalleryLook(style: inkStyle) == .ink
              && GalleryLook.ink.addedLook(for: .checklist, style: GraphicsStyle()) == .ink
              && GalleryLook.ink.addedLook(for: .checklist, style: inkStyle) == nil
              && GalleryLook.glass.addedLook(for: .checklist, style: inkStyle) == .glass
              && GalleryLook.ink.addedLook(for: .titleCard, style: GraphicsStyle()) == nil,
          "the gallery opens in the recording's look, and a graphic gets its own look only where the style draws it otherwise")
    let frame = GalleryPictures.size, wholeFrame = CGRect(origin: .zero, size: frame)
    let corner = GalleryPictures.framing(CGRect(x: 1000, y: 40, width: 240, height: 90), in: frame)
    let full = GalleryPictures.framing(wholeFrame, in: frame)
    check(wholeFrame.contains(corner) && corner.contains(CGRect(x: 1000, y: 40, width: 240, height: 90))
              && abs(corner.width / corner.height - 16.0 / 9) < 0.01 && corner.width < frame.width / 2 && full == wholeFrame,
          "a tile shows a card with room around it, at 16:9 and inside the frame, and a full-screen kind whole",
          "\(corner) \(full)")
    let drawn = try await GalleryPictures.draw(card, style: pink, look: .glass)
    /// How far `a` is from `b` over a region, 0–255 on average.
    func difference(_ a: CGImage, _ b: CGImage, xs: StrideTo<Int>, ys: StrideTo<Int>) -> Double {
        var total = 0.0, count = 0
        for y in ys { for x in xs {
            let p = rgb(a, x, y), q = rgb(b, x, y)
            total += Double(abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2)) / 3; count += 1
        } }
        return total / Double(max(1, count))
    }
    let under = GalleryPictures.backdrop.cropping(to: drawn.framing)!
    let w = drawn.image.width, h = drawn.image.height
    let middle = difference(drawn.image, under, xs: stride(from: w / 4, to: w * 3 / 4, by: 8), ys: stride(from: h / 3, to: h * 2 / 3, by: 6))
    let edge = difference(drawn.image, under, xs: stride(from: 2, to: w - 2, by: 8), ys: stride(from: 2, to: 8, by: 2))
    check(abs(Double(w) / Double(h) - 16.0 / 9) < 0.01 && drawn.framing.width < frame.width && middle > 8 && edge < 2,
          "the engine draws a gallery picture: the card in the middle of its tile, the backdrop at the edge",
          String(format: "%d×%d, middle %.1f, edge %.1f", w, h, middle, edge))

    let gallery = AppModel(recoveryURL: nil)
    gallery.restore(VideoProject(clips: [clip], settings: ExportSettings(), selection: clip.id))
    gallery.setPreviewFraction(0.5)
    let revision = gallery.revision
    gallery.toggleGalleryDraft(list)
    let draft = gallery.galleryDraftGraphic
    check(gallery.revision == revision && gallery.selectedItem?.graphics == nil
              && draft.map { abs($0.start + list.beat - gallery.previewTime) < 0.001 && $0.kind == .checklist } == true
              && gallery.playback.galleryDraft?.graphic == draft,
          "a click shows the sample on the Preview at the playhead, the picture moved aside for it, with no change to the project")
    gallery.galleryLook = .ink
    gallery.addFromGallery(list)
    let added = gallery.selectedItem?.graphics?.items.first
    check(added?.kind == .checklist && added?.look == .ink && gallery.galleryDraft == nil && gallery.playback.galleryDraft == nil,
          "+ adds the kind at the playhead in the gallery's look, and the look on the Preview goes away",
          "\(String(describing: added?.kind)) \(String(describing: added?.look))")

    print("\nCaptions track")
    var spoken = clip
    spoken.transcript = Transcript(model: "test", language: "en", words: [
        TranscriptWord(text: "Hello", start: 0.2, end: 0.5), TranscriptWord(text: "everyone,", start: 0.55, end: 0.9),
        TranscriptWord(text: "welcome", start: 1.0, end: 1.3), TranscriptWord(text: "back.", start: 1.35, end: 1.7),
    ])
    let captions = AppModel(recoveryURL: nil)
    captions.restore(VideoProject(clips: [spoken], settings: ExportSettings(), selection: spoken.id))
    check(!TimelineTrack.captions.isEmpty(in: captions.selectedItem!), "a transcript opens the Captions row")
    let cues = captions.selectedItem?.captionCues() ?? []
    check(!cues.isEmpty && cues.allSatisfy(\.editable), "captions from the transcript show, and can be edited")
    check(cues.first?.text.contains("Hello") == true, "with what is said")
    if let cue = cues.first {
        let words = cue.text.split(separator: " ").count
        let same = Array(repeating: "Hi", count: words).joined(separator: " ")
        let fixed = captions.selectedItem?.transcript(replacing: cue, with: same)
        check(fixed?.words.prefix(words).allSatisfy { $0.text == "Hi" } == true && fixed?.words.count == 4,
              "the same number of words keeps each word's time")
        let fewer = captions.selectedItem?.transcript(replacing: cue, with: "Hi")
        check(fewer.map { $0.words.count < 4 && $0.problem(duration: info.duration) == nil } == true,
              "fewer words share the old words' time and stay valid")
        let before = captions.undoEntries.count
        captions.setCaptionText(cue, to: "Hello everyone, welcome back")
        check(captions.selectedItem?.transcript?.words.last?.text == "back", "a caption's words fix the transcript")
        equal(captions.undoEntries.count, before + 1, "as one undo step")
        captions.undoEdit()
        equal(captions.selectedItem?.transcript?.words.last?.text, "back.", "and Undo puts them back")
    }
    let srt = scratch.appendingPathComponent("media-captions.srt")
    try "1\n00:00:00,500 --> 00:00:01,500\nFrom a file\n".write(to: srt, atomically: true, encoding: .utf8)
    var filed = spoken
    filed.subtitles = srt
    let fileCues = filed.item().captionCues()
    check(fileCues.first?.text == "From a file" && fileCues.allSatisfy { !$0.editable }, "captions from a file show as they are")

    print("\nAudio track")
    // Loud, then 1 s of quiet, then loud again.
    let levels = stride(from: 0.0, to: 3.0, by: AudioOverview.interval).map { time in
        AudioLevel(time: time, decibels: time >= 1.0 && time < 2.0 ? -70 : -18)
    }
    let overview = AudioOverview(levels: levels)
    let whole = ClipTimeline(segments: [TimelineSegment(start: 0, end: 3)])
    let pauses = overview.pauses(in: whole, fps: 30)
    check(pauses.count == 1 && pauses[0].lowerBound > 0.8 && pauses[0].upperBound < 2.2, "the quiet second shows as a pause",
          pauses.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "))
    let cut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 1), TimelineSegment(start: 2, end: 3)])
    check(overview.pauses(in: cut, fps: 30).isEmpty, "a pause that was cut is gone")
}
