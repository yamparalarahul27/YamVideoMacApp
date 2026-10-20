import AppKit
import Foundation

/// The Media panel, the Captions track and the linked Audio track (step 4 of the Studio
/// redesign).
@MainActor func mediaTests() async throws {
    print("\nMedia panel")
    let assets: [MediaAsset] = [.namePlate, .titleCard, .kineticText, .sectionCard, .endScreen, .logo("Figma"),
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
